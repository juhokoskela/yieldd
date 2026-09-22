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
        try MacOSVirtualMachineLifecycle.requireSupportedHost()
        let platforms = platforms
        let template = macosTemplate.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        let deviceID = deviceID
        let confirmation = confirmRegistrationRemoved
        do {
            try withRunnerOwnership(connected: true) { leaseStore in
                guard try leaseStore.load().isEmpty else {
                    throw ValidationError("Run recover to clean up standalone runner leases before connecting.")
                }
                if let template {
                    try RunnerStorage.required(in: leaseStore.directory).validateTemplateLocation(template)
                }
                let stop = try RunnerPoolStop.monitoringSignals()
                let directory = leaseStore.directory
                // Recover every persisted platform, even if it is no longer enabled.
                // macOS recovery removes abandoned clones without requiring the template.
                try recoverConnectedPlatforms(directory: directory, server: serverURL, deviceID: deviceID,
                                              token: token, confirmation: confirmation, stop: stop)
                if confirmation != nil {
                    print("Local guest destroyed and connected journal cleared after operator-confirmed registration removal.")
                    return
                }
                if template != nil {
                    try removeUnleasedMacOSClones(in: directory, keeping: [], checkCancellation: stop.check)
                }
                let storage = try RunnerStorage.required(in: directory)
                try storage.validate(stateDirectory: directory)
                let memory = RunnerMemoryAdmission()
                for platform in platforms { try memory.validateCapacity(reserving: platform.memoryReservationBytes) }
                if let template {
                    try storage.validateMacOS(template: template, clones: storage.clonesURL)
                    try MacOSVirtualizationBackend.validateTemplate(at: template)
                    try VirtualizationEntitlement.requireCurrentProcess()
                    try MacOSRunnerNetwork.requireRelay()
                }
                let backends = try platforms.map { platform -> RunnerSlotBackend in
                    switch platform {
                    case .linux:
                        let container = try ExecutableLocator().locate("container")
                        try AppleContainerSystem(containerURL: container, executor: ProcessExecutor(checkCancellation: stop.check), stateDirectory: directory).start()
                        try storage.validateContainer(containerExecutable: container)
                        return .linux(containerURL: container)
                    case .macOS:
                        guard let template else { throw RunnerServiceConfigurationError.templatePairRequired }
                        return .macOS(templateURL: template)
                    }
                }
                let slots = connectedWorkers(backends: backends, memory: memory) { platform, count in
                    print("Offering up to \(count) \(platform.rawValue) workers. All platforms compete for the same memory budget; idle workers reserve no RAM.")
                }
                try RunnerPool(stop: stop).run(slots: slots) { worker, stop in
                    let platform = worker.backend.platform
                    let client = ConnectedHTTPClient(server: serverURL, deviceID: deviceID, token: token,
                                                     platform: platform, slot: worker.slot, checkCancellation: stop.check)
                    let authorization = ConnectedExecutionAuthorization(renew: client.renew, checkCancellation: stop.check)
                    let executor = ProcessExecutor(checkCancellation: authorization.check)
                    let backend: any RunnerBackend
                    switch worker.backend {
                    case let .linux(containerURL):
                        backend = AppleContainerBackend(containerURL: containerURL, executor: executor,
                            stateDirectory: directory,
                            dockerReadiness: DockerReadiness(wait: stop.wait, checkCancellation: authorization.check))
                    case let .macOS(templateURL):
                        backend = try MacOSVirtualizationBackend(stateDirectory: directory, templateURL: templateURL,
                            cloneRootURL: RunnerStorage.cloneRoot(in: directory),
                            executor: executor, checkCancellation: authorization.check, wait: stop.wait)
                    }
                    let runner = ConnectedRunner(backend: backend, store: ConnectedRunnerStore(directory: directory, platform: platform, slot: worker.slot),
                        server: serverURL.absoluteString, deviceID: deviceID, accept: client.accept, complete: client.complete,
                        authorization: authorization, wait: stop.wait,
                        stateChanged: { reportRunnerServiceState($0, platform: platform, output: .terminal) })
                    try runConnectedClient(checkCancellation: stop.check, recover: {
                        try runner.recover()
                        print("Connected \(platform.rawValue) ARM64 slot \(worker.slot) ready. Idle polling reserves no RAM and starts no guest.")
                    }, acquire: {
                        try memory.tryAcquire(reserving: platform.memoryReservationBytes)
                    }, release: memory.release, poll: client.poll, decline: client.decline, run: { offer, allocation, release in
                        print("Accepting local \(platform.rawValue) runner \(offer.runner) for \(offer.repository).")
                        try runner.run(offer, memory: allocation, releaseCapacity: release)
                    }, wait: stop.wait, retrying: {
                        print("Coordinator request failed; retrying in five seconds. Outstanding \(platform.rawValue) cleanup must finish before new work.")
                    }, available: {
                        memory.isAvailable(reserving: platform.memoryReservationBytes)
                    }, blocked: {
                        print("Waiting for host memory for \(platform.rawValue). Local capacity is not being advertised; hosted fallback remains available.")
                    })
                }
            }
        } catch where isCancellation(error) {
            print("Stopped. Any unfinished connected assignment remains recorded for recovery.")
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
