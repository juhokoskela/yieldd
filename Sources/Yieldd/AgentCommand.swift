import ArgumentParser
import Darwin
import Foundation
import OSLog

private let agentLogger = Logger(subsystem: "dev.yieldd", category: "agent")

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Manage the installed local agent.",
        subcommands: [
            AgentInstallCommand.self,
            AgentInstallConnectedCommand.self,
            AgentStatusCommand.self,
            AgentPauseCommand.self,
            AgentResumeCommand.self,
            AgentDrainCommand.self,
            AgentUninstallCommand.self,
            AgentRunCommand.self,
            AgentVirtualizationProbeCommand.self,
        ]
    )
}

struct AgentVirtualizationProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "virtualization-probe",
        abstract: "Run the packaged macOS virtualization probe.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden)
    var hold = false

    @Argument(help: "macOS VM template bundle. The probe boots a disposable copy-on-write clone.")
    var bundlePath: String

    mutating func validate() throws {
        do {
            try MacOSVirtualizationBackend.validateTemplate(at: templateURL)
        } catch {
            throw ValidationError(describeError(error))
        }
    }

    mutating func run() throws {
        try withRunnerOwnership { leaseStore in
            let signalMonitor = try SignalMonitor()
            let memoryAdmission = RunnerMemoryAdmission()
            let reservation = try memoryAdmission.acquire(
                reserving: MacOSVirtualMachineLifecycle.memoryBytes,
                checkCancellation: signalMonitor.check,
                onBlocked: {
                    print("Virtualization probe is waiting for available host memory.")
                }
            )
            defer { memoryAdmission.release(reservation) }
            let guestConnection = MacOSGuestConnection(
                ssh: MacOSGuestSSH(
                    templateURL: templateURL,
                    executor: ProcessExecutor(checkCancellation: signalMonitor.check)
                )
            )

            try validateRunnerServiceTemplate(templateURL, stateDirectory: leaseStore.directory)
            try removeUnleasedRunnerFiles(in: leaseStore.directory, keeping: Set(leaseStore.load().map(\.runnerID)))
            try MacOSVirtualizationProbe(stateDirectory: leaseStore.directory).run(
                templateURL: templateURL,
                cloneRootURL: RunnerStorage.required(in: leaseStore.directory).probesURL,
                memory: reservation.allocation,
                hold: hold,
                checkCancellation: signalMonitor.check,
                wait: signalMonitor.wait,
                waitUntilGuestReady: { macAddress, timeout in
                    let address = try guestConnection.waitUntilReady(
                        macAddress: macAddress,
                        timeout: timeout,
                        checkCancellation: signalMonitor.check,
                        wait: signalMonitor.wait
                    )
                    print("macOS guest \(address) is ready over SSH.")
                },
                started: {
                    if hold {
                        print("macOS virtual machine started without a window. Press Ctrl+C to stop it.")
                    } else {
                        print("macOS virtual machine started without a window.")
                    }
                }
            )
            print("macOS virtualization probe passed and the VM was force-stopped.")
        }
    }

    private var templateURL: URL {
        URL(fileURLWithPath: bundlePath).standardizedFileURL
    }
}

struct AgentInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Configure and enable the local agent."
    )

    @OptionGroup
    var runners: RunnerServiceOptions

    @Flag(name: .long, help: .hidden)
    var preflightOnly = false

    mutating func run() throws {
        let locator = ExecutableLocator()
        try run(locateExecutable: locator.locate)
    }

    func run(
        locateExecutable: (String) throws -> URL,
        stateDirectory: URL? = nil,
        memoryAdmission: RunnerMemoryAdmission = RunnerMemoryAdmission(),
        loadStorage: ((URL) throws -> RunnerStorage?)? = nil,
        relayURL: URL = RunnerNetwork.bundledRelayURL,
        executor: any ProcessExecuting = ProcessExecutor()
    ) throws {
        let slots = try runners.serviceConfiguration()
        try memoryAdmission.validateCapacity(reserving: slots.memoryReservationBytes)
        let configuration = try AgentConfiguration.resolve(runners: slots, locateExecutable: locateExecutable)
        let store = try AgentConfigurationStore(directory: stateDirectory)
        let storage = try (loadStorage ?? { try RunnerStorage.validated(in: $0) })(store.directory)
        if slots.requiresLinux, let storage { try storage.validatePath(storage.containerURL) }
        if let templateURL = configuration.runners.macOSTemplateURL {
            if let storage { try storage.validateMacOS(template: templateURL, clones: storage.clonesURL) }
            try validateRunnerServiceTemplate(templateURL, stateDirectory: store.directory)
        }
        try RunnerNetwork.requireRelay(at: relayURL)
        if slots.requiresLinux, let container = configuration.containerURL {
            try AppleContainerBackend.requireNetworkSupport(containerURL: container, executor: executor)
        }
        guard !preflightOnly else {
            // Machine-readable result consumed by install-local-agent.sh.
            print(configuration.runners.requiresLinux ? "linux" : "macos")
            return
        }

        guard try ConnectedAgentStore(directory: store.directory).load() == nil else { throw AgentError.configurationChanged }
        let service = try localAgentService()
        try installAgent(
            configuration: configuration,
            store: store,
            service: service
        )
        print(registrationStatusDescription(service.status()))
    }
}

struct AgentStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show local agent registration, configuration, and active runners."
    )

    mutating func run() throws {
        let store = try AgentConfigurationStore()
        if let connected = try ConnectedAgentStore(directory: store.directory).load() {
            let service = try localAgentService()
            print(registrationStatusDescription(service.status()))
            print("Connected coordinator: \(connected.server.absoluteString)")
            print("Device: \(connected.deviceID)")
            print("Platforms: \(connected.platforms.map(\.rawValue).joined(separator: ", "))")
            print("Configuration and cleanup records do not establish live health.")
            return
        }
        try reportAgentStatus(
            store: store,
            service: localAgentService(),
            output: { print($0) }
        )
    }
}

struct AgentUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Disable the local agent and remove its configuration."
    )

    mutating func run() async throws {
        let service = try localAgentService()
        if service.status() == .notFound {
            writeToStandardError(
                "Warning: macOS could not resolve the local agent registration; attempting cleanup anyway.\n"
            )
        }

        let store = try AgentConfigurationStore()
        let connectedStore = ConnectedAgentStore(directory: store.directory)
        if try connectedStore.load() != nil {
            try await uninstallConnectedAgent(store: connectedStore, credentials: .keychain, service: service) { configuration, token in
                try recoverConnectedAgent(configuration: configuration, token: token, directory: store.directory,
                    stop: RunnerPoolStop.monitoringSignals())
            }
            print("Connected agent unregistered and configuration removed.")
            return
        }
        try await uninstallAgent(
            store: store,
            service: service,
            recover: {
                let stop = try RunnerPoolStop.monitoringSignals()
                try recoverAgentRunners(store: store, stop: stop, executor: ProcessExecutor(checkCancellation: stop.check))
            }
        )
        print("Local agent unregistered and configuration removed.")
    }
}

struct AgentRunCommand: ParsableCommand {
    static let shutdownTimeout: TimeInterval = 50

    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the configured local agent.",
        shouldDisplay: false
    )

    mutating func run() throws {
        let stop = try RunnerPoolStop.monitoringSignals(
            shutdownTimeout: Self.shutdownTimeout
        )
        defer { agentLogger.notice("Stopping yieldd.") }
        do {
            let store = try AgentConfigurationStore()
            if let connected = try ConnectedAgentStore(directory: store.directory).load() {
                let control = ConnectedAgentControl(directory: store.directory)
                let endpoint = AgentControlEndpoint(control: control)
                endpoint.start()
                defer { endpoint.stop() }
                let token = try ConnectedAgentCredentials.keychain.load(connected.credentialAccount)
                try runConnectedService(server: connected.server, deviceID: connected.deviceID, token: token,
                    platforms: connected.platforms, template: connected.template, stop: stop, stateDirectory: store.directory,
                    resolveContainer: connected.resolveContainer, output: .agentLog, control: control)
                return
            }
            let configuration = try store.load()
            try configuration.requireGitHubCLI()
            try withRunnerOwnership(in: store.directory) { leaseStore in
                let executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
                try runRunnerService(
                    configuration: configuration.runners,
                    leaseStore: leaseStore,
                    containerURL: configuration.containerURL,
                    ghURL: configuration.ghURL,
                    stop: stop,
                    output: .agentLog,
                    prepareContainer: agentContainerPreparation(configuration: configuration, executor: executor, stateDirectory: store.directory)
                )
            }
        } catch where isCancellation(error) {
            return
        } catch {
            agentLogger.error("Local agent failed: \(describeError(error), privacy: .public)")
            throw error
        }
    }
}

func recoverAgentRunners(store: AgentConfigurationStore, stop: RunnerPoolStop, executor: any ProcessExecuting,
                         makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil) throws {
    try withRunnerOwnership(in: store.directory) { leaseStore in
        if try leaseStore.load().isEmpty {
            try removeUnleasedRunnerFiles(in: leaseStore.directory, keeping: [], makeCloneStore: makeCloneStore)
            return
        }

        let configuration = try store.load()
        let recovery = makeRunnerRecovery(
            leaseStore: leaseStore,
            resolveContainer: agentContainerPreparation(configuration: configuration, executor: executor, stateDirectory: store.directory),
            ghURL: configuration.ghURL,
            stop: stop,
            executor: executor,
            makeCloneStore: makeCloneStore,
            stateChanged: { reportRunnerRecoveryState($0) }
        )
        for id in try recovery.run() {
            print("Cleaned up abandoned runner \(id.value).")
        }
    }
}

func agentContainerPreparation(
    configuration: AgentConfiguration, executor: any ProcessExecuting, stateDirectory: URL
) -> () throws -> URL {
    // Startup and recovery call this synchronously, before concurrent runner slots begin.
    var prepared: Result<URL, any Error>?
    return {
        if let prepared { return try prepared.get() }
        let result = Result {
            guard let url = configuration.containerURL else { throw AgentConfigurationError.containerPathNotRecorded }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw AgentConfigurationError.executableUnavailable(path: url.path)
            }
            try AppleContainerSystem(containerURL: url, executor: executor, stateDirectory: stateDirectory).start()
            return url
        }
        prepared = result
        return try result.get()
    }
}

extension RunnerServiceOutput {
    static let agentLog = RunnerServiceOutput(
        info: { agentLogger.notice("\($0, privacy: .public)") },
        warning: { agentLogger.warning("\($0, privacy: .public)") },
        error: { agentLogger.error("\($0, privacy: .public)") }
    )
}
