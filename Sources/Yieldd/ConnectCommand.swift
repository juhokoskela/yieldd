import ArgumentParser
import Foundation
import os

enum ConnectedPlatform: String, ExpressibleByArgument, Sendable {
    case linux, macos

    var runnerPlatform: RunnerPlatform { self == .linux ? .linux : .macOS }
}

struct ConnectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "connect", abstract: "Offer on-demand Linux containers or macOS VMs to a coordinator.")

    @Option(name: .long, help: "Coordinator HTTPS origin. Loopback HTTP is allowed for local tests.")
    var server: String

    @Option(name: .long, help: "Lowercase device UUID configured on the coordinator.")
    var deviceID: String

    @Option(name: .long, help: "Platform to offer: linux or macos. Repeat for both. Defaults to linux.")
    var platform: [ConnectedPlatform] = []

    @Option(name: .long, help: "Absolute macOS template bundle path. Required when offering macos.")
    var macosTemplate: String?

    @Option(name: .long, help: "After manually removing this exact GitHub runner registration, destroy its local guest, clear the matching journal, and exit. Use only when original coordinator recovery is impossible.")
    var confirmRegistrationRemoved: String?

    var platforms: [RunnerPlatform] { (platform.isEmpty ? [.linux] : platform).map(\.runnerPlatform) }

    mutating func validate() throws {
        do { _ = try ConnectedHTTPClient.serverURL(server) } catch { throw ValidationError(describeError(error)) }
        guard UUID(uuidString: deviceID)?.uuidString.lowercased() == deviceID else {
            throw ValidationError("--device-id must be a lowercase UUID.")
        }
        guard Set(platform.map(\.rawValue)).count == platform.count else { throw ValidationError("Specify each platform only once.") }
        if let macosTemplate, !macosTemplate.hasPrefix("/") { throw ValidationError("--macos-template must be an absolute path.") }
        if confirmRegistrationRemoved == nil, platforms.contains(.macOS) != (macosTemplate != nil) {
            throw ValidationError("--platform macos and --macos-template must be supplied together.")
        }
    }

    mutating func run() throws {
        let serverURL = try ConnectedHTTPClient.serverURL(server)
        let token = ProcessInfo.processInfo.environment["YIELDD_CLIENT_TOKEN"] ?? ""
        if confirmRegistrationRemoved == nil { try ConnectedHTTPClient.validateToken(token) }
        let stop = try RunnerPoolStop.monitoringSignals()
        do {
            try runConnectedService(server: serverURL, deviceID: deviceID, token: token,
                platforms: platforms, template: macosTemplate.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() },
                confirmation: confirmRegistrationRemoved, stop: stop)
        } catch where isCancellation(error) {
            print("Stopped. Any unfinished connected assignment remains recorded for recovery.")
        }
    }
}

func runConnectedService(
    server serverURL: URL, deviceID: String, token: String, platforms: [RunnerPlatform], template: URL?,
    confirmation: String? = nil, stop: RunnerPoolStop, stateDirectory: URL? = nil,
    resolveContainer: () throws -> URL = { try ExecutableLocator().locate("container") },
    output: RunnerServiceOutput = .terminal, control: ConnectedAgentControl? = nil
) throws {
    try runConnectedService(
        server: serverURL, deviceID: deviceID, loadToken: { token }, platforms: platforms, template: template,
        confirmation: confirmation, stop: stop, stateDirectory: stateDirectory,
        resolveContainer: resolveContainer, output: output, control: control
    )
}

func runConnectedService(
    server serverURL: URL, deviceID: String, loadToken: () throws -> String, platforms: [RunnerPlatform], template: URL?,
    confirmation: String? = nil, stop: RunnerPoolStop, stateDirectory: URL? = nil,
    resolveContainer: () throws -> URL = { try ExecutableLocator().locate("container") },
    output: RunnerServiceOutput = .terminal, control: ConnectedAgentControl? = nil
) throws {
    try MacOSVirtualMachineLifecycle.requireSupportedHost()
    try withRunnerOwnership(in: stateDirectory, connected: true) { leaseStore in
        if let installed = try ConnectedAgentStore(directory: leaseStore.directory).load() {
            try installed.requireIdentity(server: serverURL, deviceID: deviceID)
        }
        if let template {
            try RunnerStorage.required(in: leaseStore.directory).validateTemplateLocation(template)
        }
        let directory = leaseStore.directory
        let ownershipDescriptor = leaseStore.ownershipDescriptor
        // Destroy any orphaned local guests while holding runner ownership BEFORE requiring
        // Keychain credentials so a locked Keychain cannot leave an abandoned guest burning CPU,
        // and another active yieldd process's guest is never touched.
        let locallyDestroyed = try destroyLocalConnectedGuests(
            leaseStore: leaseStore, server: serverURL, deviceID: deviceID,
            confirmation: confirmation, stop: stop,
            resolveContainer: resolveContainer, output: output, control: control
        )
        let token = try loadToken()
        // Recover every persisted platform, even if it is no longer enabled.
        // macOS recovery removes abandoned clones without requiring the template.
        try recoverConnectedPlatforms(directory: directory, server: serverURL, deviceID: deviceID,
                                      token: token, confirmation: confirmation, stop: stop,
                                      alreadyDestroyed: locallyDestroyed,
                                      resolveContainer: resolveContainer, output: output, control: control)
        control?.starting()
        if confirmation != nil {
            output.info("Local guest destroyed and connected journal cleared after operator-confirmed registration removal.")
            return
        }
        let startupExecutor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
        try removeUnleasedRunnerFiles(in: directory, ownershipDescriptor: ownershipDescriptor,
                                     executor: startupExecutor, checkCancellation: stop.check)
        let storage = try RunnerStorage.required(in: directory)
        try storage.validate(stateDirectory: directory, executor: startupExecutor)
        try RunnerNetwork.requireRelay()
        let memory = RunnerMemoryAdmission()
        for platform in platforms { try memory.validateCapacity(reserving: platform.memoryReservationBytes) }
        if let template {
            try storage.validateMacOS(template: template, clones: storage.clonesURL)
            try MacOSVirtualizationBackend.validateTemplate(at: template)
            try VirtualizationEntitlement.requireCurrentProcess()
        }
        let cachePolicy = try loadJobCachePolicy(in: directory)
        let backends = try platforms.map { platform -> RunnerSlotBackend in
            switch platform {
            case .linux:
                let container = try resolveContainer()
                try AppleContainerBackend.requireNetworkSupport(containerURL: container, executor: startupExecutor)
                try AppleContainerSystem(containerURL: container, executor: startupExecutor, stateDirectory: directory).start()
                try storage.validateContainer(containerExecutable: container, executor: startupExecutor)
                return .linux(containerURL: container)
            case .macOS:
                guard let template else { throw ValidationError("A macOS worker requires a template.") }
                return .macOS(templateURL: template)
            }
        }
        let slots = connectedWorkers(backends: backends, memory: memory) { platform, count in
            output.info("Offering up to \(count) \(platform.rawValue) workers. All platforms compete for the same memory budget; idle workers reserve no RAM.")
        }
        let archiveService: ArchiveCacheService?
        if let policy = cachePolicy {
            do {
                archiveService = try ArchiveCacheService.start(storage: storage, stateDirectory: directory,
                    policy: policy, ownershipDescriptor: ownershipDescriptor, stop: stop)
            } catch {
                let message = "Local archive cache unavailable; continuing without local cache: \(describeError(error))"
                output.warning(message)
                control?.recordError(message)
                archiveService = nil
            }
        } else {
            archiveService = nil
        }
        defer { archiveService?.stop() }
        let cacheSocket = archiveService?.socketURL
        let powerMonitor = SystemPowerMonitor(
            onWillSleep: { control?.handleSystemWillSleep() },
            onDidWake: { control?.handleSystemDidWake() }
        )
        _ = powerMonitor.start()
        defer { powerMonitor.stop() }
        control?.configure(workers: slots, memory: memory)
        control?.markReady()
        if control?.isPaused == true { output.info("Connected agent is paused. New jobs will wait until admission resumes.") }
        try RunnerPool(stop: stop).run(slots: slots) { worker, stop in
            let workerID = worker.id
            let platform = worker.backend.platform
            let client = ConnectedHTTPClient(server: serverURL, deviceID: deviceID, token: token,
                                             platform: platform, slot: worker.slot, checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline,
                connectionChanged: { state, error in control?.connection(worker: workerID, state: state, error: error) })
            let authorization = ConnectedExecutionAuthorization(
                renewWithMetadata: client.renewWithMetadata,
                checkCancellation: stop.check,
                initialOfflineGrace: ConnectedExecutionAuthorization.preStartOfflineGrace,
                onWorkflowRunID: { control?.recordWorkflowRun(worker: workerID, runID: $0) }
            )
            let executor = ProcessExecutor(checkCancellation: authorization.check, maximumExecutionDeadline: stop.executionDeadline)
            let network = try RunnerNetwork(stateDirectory: directory, platform: platform, cacheSocket: cacheSocket)
            let backend: any RunnerBackend
            let severNetworkHandler: @Sendable (RunnerID, DispatchTime) -> Void
            let applyCPUQuotaHandler: @Sendable (Int, RunnerID) -> Void
            switch worker.backend {
            case let .linux(containerURL):
                let linuxBackend = try AppleContainerBackend(containerURL: containerURL, executor: executor,
                    stateDirectory: directory, ownershipDescriptor: ownershipDescriptor, network: network,
                    checkCancellation: authorization.check, maximumExecutionDeadline: stop.executionDeadline,
                    dockerReadiness: DockerReadiness(wait: stop.wait, checkCancellation: authorization.check))
                backend = linuxBackend
                severNetworkHandler = { linuxBackend.severNetwork($0, deadline: $1) }
                applyCPUQuotaHandler = { cpus, id in try? linuxBackend.applyCPUQuota(cpus, on: id) }
            case let .macOS(templateURL):
                let macBackend = try MacOSVirtualizationBackend(stateDirectory: directory, templateURL: templateURL,
                    cloneRootURL: RunnerStorage.cloneRoot(in: directory),
                    executor: executor, network: network, checkCancellation: authorization.check, wait: stop.wait,
                    maximumExecutionDeadline: stop.executionDeadline)
                backend = macBackend
                severNetworkHandler = { macBackend.severNetwork($0, deadline: $1) }
                applyCPUQuotaHandler = { _, _ in }
            }
            let store = ConnectedRunnerStore(directory: directory, platform: platform, slot: worker.slot)
            let runner = ConnectedRunner(backend: backend, store: store,
                server: serverURL.absoluteString, deviceID: deviceID, accept: client.accept, complete: client.complete,
                authorization: authorization, wait: stop.wait, localCache: cacheSocket != nil,
                stateChanged: {
                    control?.session(worker: workerID, state: $0)
                    reportRunnerServiceState($0, output: output)
                },
                initialLinuxCPUs: { control?.effectiveLinuxCPUs ?? AppleContainerBackend.virtualCPUs },
                onWarning: { output.warning($0) })
            let activeRunnerID = OSAllocatedUnfairLock<RunnerID?>(initialState: nil)
            control?.registerSlotHandler(worker: workerID, handler: AgentSlotControlHandler(
                abort: { reason, expected in authorization.abort(reason: reason, expectedRunner: expected) },
                severNetwork: { deadline in
                    if let id = activeRunnerID.withLock({ $0 }) {
                        severNetworkHandler(id, deadline)
                    }
                },
                applyCPUQuota: { cpus in
                    if let id = activeRunnerID.withLock({ $0 }) {
                        applyCPUQuotaHandler(cpus, id)
                    }
                }
            ))
            defer { control?.unregisterSlotHandler(worker: workerID) }
            let slotReservation = ConnectedSlotReservation()
            var platformBackoff: TimeInterval = 5
            while true {
                try stop.check()
                do {
                    try runConnectedClient(checkCancellation: stop.check, recover: {
                        control?.update(worker: workerID, phase: .recovering)
                        try runner.recover()
                        output.info("Connected \(platform.rawValue) ARM64 slot \(worker.slot) ready. Idle polling reserves no RAM and starts no guest.")
                    }, acquire: {
                        try memory.tryAcquire(reserving: platform.memoryReservationBytes)
                    }, release: memory.release, prepareToPoll: {
                        try archiveService?.ensureRunning()
                    }, poll: {
                        control?.update(worker: workerID, phase: .idle)
                        return try client.poll()
                    }, decline: client.decline, run: { offer, allocation, release in
                        let id = RunnerID(value: offer.runner)
                        activeRunnerID.withLock { $0 = id }
                        authorization.prepare(runner: offer.runner)
                        defer {
                            authorization.stop()
                            activeRunnerID.withLock { $0 = nil }
                        }
                        control?.assign(worker: workerID, offer: offer)
                        output.info("Accepting local \(platform.rawValue) runner \(offer.runner) for \(offer.repository).")
                        try runner.run(offer, memory: allocation, releaseCapacity: release)
                        platformBackoff = 5
                    }, wait: stop.wait, retrying: { error in
                        output.info("Retrying \(platform.rawValue) slot \(worker.slot) in five seconds: \(describeError(error))")
                    }, available: {
                        memory.isAvailable(reserving: platform.memoryReservationBytes)
                    }, blocked: {
                        control?.update(worker: workerID, phase: .waitingForMemory)
                        output.info("Waiting for host memory for \(platform.rawValue). Local capacity is not being advertised; hosted fallback remains available.")
                    }, paused: { !(control?.canPoll(platform: platform) ?? true) }, beginAssignment: {
                        control?.beginAssignment(worker: workerID, platform: platform) ?? true
                    }, finishAssignment: {
                        control?.finishAssignment(worker: workerID)
                    }, slotReservation: slotReservation)
                    return
                } catch where isCancellation(error) {
                    throw error
                } catch where isFatalConnectedServiceError(error) {
                    throw error
                } catch {
                    // Contain platform/pre-start errors (e.g., macOS 2-VM limit) to this slot
                    // instead of tearing down healthy sibling slots across the pool.
                    // If no persisted lease remains, release assignment/memory immediately before backing off.
                    if (try? store.load()) == nil {
                        slotReservation.release(using: memory.release)
                        control?.finishAssignment(worker: workerID)
                    }
                    let message = "Paused \(platform.rawValue) slot \(worker.slot) for \(Int(platformBackoff))s after error: \(describeError(error))"
                    output.warning(message)
                    control?.connection(worker: workerID, state: .retrying, error: message)
                    try stop.wait(for: platformBackoff)
                    platformBackoff = min(60, platformBackoff * 2)
                }
            }
        }
    }
}

struct ConnectedWorker: Sendable {
    let backend: RunnerSlotBackend
    let slot: Int
    var id: String { backend.platform.connectedWorkerID(slot: slot) }
}

extension RunnerPlatform {
    func connectedWorkerID(slot: Int) -> String { "\(rawValue)-\(slot)" }
}

func connectedWorkers(backends: [RunnerSlotBackend], memory: RunnerMemoryAdmission,
                      report: (RunnerPlatform, Int) -> Void) -> [ConnectedWorker] {
    backends.flatMap { backend in
        let count = memory.connectedWorkerCount(for: backend.platform)
        report(backend.platform, count)
        return (0..<count).map { ConnectedWorker(backend: backend, slot: $0) }
    }
}

private func isFatalConnectedServiceError(_ error: any Error) -> Bool {
    if let connected = error as? ConnectedRunnerError {
        switch connected {
        case .previousVersionState, .invalidState, .identityChanged, .registrationReconciliationRequired,
             .confirmationMismatch, .http(401, _, _), .http(403, _, _):
            return true
        default:
            return false
        }
    }
    return false
}
