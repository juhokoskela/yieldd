import ArgumentParser
import Foundation

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
    try MacOSVirtualMachineLifecycle.requireSupportedHost()
    try withRunnerOwnership(in: stateDirectory, connected: true) { leaseStore in
        if let installed = try ConnectedAgentStore(directory: leaseStore.directory).load() {
            try installed.requireIdentity(server: serverURL, deviceID: deviceID)
        }
        guard try leaseStore.load().isEmpty else {
            throw ValidationError("Run recover to clean up standalone runner leases before connecting.")
        }
        if let template {
            try RunnerStorage.required(in: leaseStore.directory).validateTemplateLocation(template)
        }
        let directory = leaseStore.directory
        // Recover every persisted platform, even if it is no longer enabled.
        // macOS recovery removes abandoned clones without requiring the template.
        try recoverConnectedPlatforms(directory: directory, server: serverURL, deviceID: deviceID,
                                      token: token, confirmation: confirmation, stop: stop,
                                      resolveContainer: resolveContainer, output: output)
        if confirmation != nil {
            output.info("Local guest destroyed and connected journal cleared after operator-confirmed registration removal.")
            return
        }
        try removeUnleasedRunnerFiles(in: directory, keeping: [], checkCancellation: stop.check)
        let storage = try RunnerStorage.required(in: directory)
        try storage.validate(stateDirectory: directory)
        try RunnerNetwork.requireRelay()
        let memory = RunnerMemoryAdmission()
        for platform in platforms { try memory.validateCapacity(reserving: platform.memoryReservationBytes) }
        if let template {
            try storage.validateMacOS(template: template, clones: storage.clonesURL)
            try MacOSVirtualizationBackend.validateTemplate(at: template)
            try VirtualizationEntitlement.requireCurrentProcess()
        }
        let backends = try platforms.map { platform -> RunnerSlotBackend in
            switch platform {
            case .linux:
                let container = try resolveContainer()
                try AppleContainerBackend.requireNetworkSupport(containerURL: container, executor: ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline))
                try AppleContainerSystem(containerURL: container, executor: ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline), stateDirectory: directory).start()
                try storage.validateContainer(containerExecutable: container)
                return .linux(containerURL: container)
            case .macOS:
                guard let template else { throw RunnerServiceConfigurationError.templatePairRequired }
                return .macOS(templateURL: template)
            }
        }
        let slots = connectedWorkers(backends: backends, memory: memory) { platform, count in
            output.info("Offering up to \(count) \(platform.rawValue) workers. All platforms compete for the same memory budget; idle workers reserve no RAM.")
        }
        control?.markReady()
        if control?.snapshot.paused == true { output.info("Connected agent is paused. Run agent resume after maintenance.") }
        try RunnerPool(stop: stop).run(slots: slots) { worker, stop in
            let workerID = "\(worker.backend.platform.rawValue)-\(worker.slot)"
            let platform = worker.backend.platform
            let client = ConnectedHTTPClient(server: serverURL, deviceID: deviceID, token: token,
                                             platform: platform, slot: worker.slot, checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
            let authorization = ConnectedExecutionAuthorization(renew: client.renew, checkCancellation: stop.check)
            let executor = ProcessExecutor(checkCancellation: authorization.check, maximumExecutionDeadline: stop.executionDeadline)
            let backend: any RunnerBackend
            switch worker.backend {
            case let .linux(containerURL):
                backend = try AppleContainerBackend(containerURL: containerURL, executor: executor,
                    stateDirectory: directory,
                    checkCancellation: authorization.check, maximumExecutionDeadline: stop.executionDeadline,
                    dockerReadiness: DockerReadiness(wait: stop.wait, checkCancellation: authorization.check))
            case let .macOS(templateURL):
                backend = try MacOSVirtualizationBackend(stateDirectory: directory, templateURL: templateURL,
                    cloneRootURL: RunnerStorage.cloneRoot(in: directory),
                    executor: executor, checkCancellation: authorization.check, wait: stop.wait,
                    maximumExecutionDeadline: stop.executionDeadline)
            }
            let runner = ConnectedRunner(backend: backend, store: ConnectedRunnerStore(directory: directory, platform: platform, slot: worker.slot),
                server: serverURL.absoluteString, deviceID: deviceID, accept: client.accept, complete: client.complete,
                authorization: authorization, wait: stop.wait,
                stateChanged: { reportRunnerServiceState($0, platform: platform, output: output) })
            try runConnectedClient(checkCancellation: stop.check, recover: {
                try runner.recover()
                output.info("Connected \(platform.rawValue) ARM64 slot \(worker.slot) ready. Idle polling reserves no RAM and starts no guest.")
            }, acquire: {
                try memory.tryAcquire(reserving: platform.memoryReservationBytes)
            }, release: memory.release, poll: client.poll, decline: client.decline, run: { offer, allocation, release in
                output.info("Accepting local \(platform.rawValue) runner \(offer.runner) for \(offer.repository).")
                try runner.run(offer, memory: allocation, releaseCapacity: release)
            }, wait: stop.wait, retrying: { error in
                output.info("Retrying \(platform.rawValue) slot \(worker.slot) in five seconds: \(describeError(error))")
            }, available: {
                memory.isAvailable(reserving: platform.memoryReservationBytes)
            }, blocked: {
                output.info("Waiting for host memory for \(platform.rawValue). Local capacity is not being advertised; hosted fallback remains available.")
            }, paused: { control?.snapshot.paused ?? false }, beginAssignment: {
                control?.beginAssignment(worker: workerID) ?? true
            }, finishAssignment: {
                control?.finishAssignment(worker: workerID)
            })
        }
    }
}

struct ConnectedWorker: Sendable {
    let backend: RunnerSlotBackend
    let slot: Int
}

func connectedWorkers(backends: [RunnerSlotBackend], memory: RunnerMemoryAdmission,
                      report: (RunnerPlatform, Int) -> Void) -> [ConnectedWorker] {
    backends.flatMap { backend in
        let count = memory.connectedWorkerCount(for: backend.platform)
        report(backend.platform, count)
        return (0..<count).map { ConnectedWorker(backend: backend, slot: $0) }
    }
}
