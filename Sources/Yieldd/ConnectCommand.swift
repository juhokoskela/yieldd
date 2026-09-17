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
                    try MacOSVirtualizationBackend.validateTemplateLocation(template,
                        cloneRootURL: MacOSRunnerCloneStore(stateDirectory: leaseStore.directory).rootURL)
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
                let memory = RunnerMemoryAdmission()
                for platform in platforms { try memory.validateCapacity(reserving: platform.memoryReservationBytes) }
                if let template {
                    try MacOSVirtualizationBackend.validateTemplate(at: template)
                    try VirtualizationEntitlement.requireCurrentProcess()
                }
                let slots = try platforms.map { platform -> RunnerSlotBackend in
                    switch platform {
                    case .linux:
                        let container = try ExecutableLocator().locate("container")
                        try AppleContainerSystem(containerURL: container, executor: ProcessExecutor(checkCancellation: stop.check)).start()
                        return .linux(containerURL: container)
                    case .macOS:
                        guard let template else { throw RunnerServiceConfigurationError.templatePairRequired }
                        return .macOS(templateURL: template)
                    }
                }
                try RunnerPool(stop: stop).run(slots: slots) { slot, stop in
                    let platform = slot.platform
                    let executor = ProcessExecutor(checkCancellation: stop.check)
                    let backend: any RunnerBackend
                    switch slot {
                    case let .linux(containerURL):
                        backend = AppleContainerBackend(containerURL: containerURL, executor: executor,
                            dockerReadiness: DockerReadiness(wait: stop.wait, checkCancellation: stop.check))
                    case let .macOS(templateURL):
                        backend = try MacOSVirtualizationBackend(templateURL: templateURL,
                            cloneRootURL: MacOSRunnerCloneStore(stateDirectory: directory).rootURL,
                            executor: executor, checkCancellation: stop.check, wait: stop.wait)
                    }
                    let client = ConnectedHTTPClient(server: serverURL, deviceID: deviceID, token: token,
                                                     platform: platform, checkCancellation: stop.check)
                    let runner = ConnectedRunner(backend: backend, store: ConnectedRunnerStore(directory: directory, platform: platform),
                        server: serverURL.absoluteString, deviceID: deviceID, accept: client.accept, complete: client.complete,
                        checkCancellation: stop.check, wait: stop.wait,
                        stateChanged: { reportRunnerServiceState($0, platform: platform, output: .terminal) })
                    try runConnectedClient(checkCancellation: stop.check, recover: {
                        try runner.recover()
                        print("Connected \(platform.rawValue) ARM64 slot ready. Idle polling reserves no RAM and starts no guest.")
                    }, acquire: {
                        try memory.tryAcquire(reserving: platform.memoryReservationBytes)
                    }, release: memory.release, poll: client.poll, run: { offer, allocation, release in
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
