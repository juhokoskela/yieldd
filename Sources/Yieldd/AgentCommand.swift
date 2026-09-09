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
            AgentStatusCommand.self,
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
            try MacOSVirtualizationProbeClone.validateTemplate(at: templateURL)
            try MacOSGuestSSH.validateTemplate(at: templateURL)
        } catch {
            throw ValidationError(describeError(error))
        }
    }

    mutating func run() throws {
        try withRunnerOwnership { leaseStore in
            let signalMonitor = try SignalMonitor(
                signals: [SIGINT, SIGTERM, SIGHUP]
            )
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

            try MacOSVirtualizationProbe().run(
                templateURL: templateURL,
                cloneRootURL: leaseStore.directory
                    .appendingPathComponent("macos-probes", isDirectory: true),
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

    func run(locateExecutable: (String) throws -> URL, stateDirectory: URL? = nil) throws {
        let slots = try runners.serviceConfiguration()
        let configuration = try AgentConfiguration(
            repositories: slots.slots.filter { $0.platform == .linux }.map(\.repository),
            macOSRepositories: slots.slots.filter { $0.platform == .macOS }.map(\.repository),
            macOSTemplateURL: slots.macOSTemplateURL,
            containerURL: slots.requiresLinux ? locateExecutable("container") : nil,
            ghURL: locateExecutable("gh")
        )
        let directory = try stateDirectory ?? yielddApplicationSupportDirectory()
        if let templateURL = configuration.runners.macOSTemplateURL {
            try validateRunnerServiceTemplate(templateURL, stateDirectory: directory, executor: ProcessExecutor())
        }
        let admission = RunnerMemoryAdmission()
        for slot in configuration.runners.slots {
            try admission.validateCapacity(reserving: slot.platform.memoryReservationBytes)
        }
        guard !preflightOnly else {
            // Machine-readable result consumed by install-local-agent.sh.
            print(configuration.runners.requiresLinux ? "linux" : "macos")
            return
        }

        let service = try localAgentService()
        try installAgent(
            configuration: configuration,
            store: AgentConfigurationStore(directory: directory),
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
        try reportAgentStatus(
            store: AgentConfigurationStore(),
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
        try await uninstallAgent(
            store: store,
            service: service,
            recover: {
                try recoverAgentRunners(store: store)
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
            let configuration = try store.load()
            try configuration.requireExecutables()
            try withRunnerOwnership(in: store.directory) { leaseStore in
                let executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
                if let templateURL = configuration.runners.macOSTemplateURL {
                    try validateRunnerServiceTemplate(templateURL, stateDirectory: store.directory, executor: executor)
                }
                try startAgentContainerIfNeeded(configuration: configuration, leaseStore: leaseStore, executor: executor)
                try runRunnerService(
                    configuration: configuration.runners,
                    leaseStore: leaseStore,
                    containerURL: configuration.containerURL,
                    ghURL: configuration.ghURL,
                    stop: stop,
                    output: .agentLog
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

private func recoverAgentRunners(store: AgentConfigurationStore) throws {
    try withRunnerOwnership(in: store.directory) { leaseStore in
        if try leaseStore.load().isEmpty {
            try MacOSRunnerCloneStore(stateDirectory: leaseStore.directory).removeUnleased(keeping: [])
            return
        }

        let configuration = try store.load()
        try configuration.requireExecutables()
        let stop = try RunnerPoolStop.monitoringSignals()
        try startAgentContainerIfNeeded(
            configuration: configuration, leaseStore: leaseStore, executor: ProcessExecutor(checkCancellation: stop.check)
        )
        let recovery = makeRunnerRecovery(
            leaseStore: leaseStore,
            containerURL: configuration.containerURL,
            ghURL: configuration.ghURL,
            stop: stop,
            stateChanged: { reportRunnerRecoveryState($0) }
        )
        for id in try recovery.run() {
            print("Cleaned up abandoned runner \(id.value).")
        }
    }
}

func startAgentContainerIfNeeded(
    configuration: AgentConfiguration, leaseStore: RunnerLeaseStore, executor: any ProcessExecuting
) throws {
    let hasLinuxLease = try leaseStore.load().contains { $0.platform == .linux }
    guard configuration.runners.requiresLinux || hasLinuxLease else { return }
    let containerURL: URL
    do {
        containerURL = try configuration.containerURL ?? ExecutableLocator().locate("container")
    } catch {
        if isCancellation(error) { throw error }
        throw RunnerRecoveryError.linuxBackendUnavailable(error)
    }
    try AppleContainerSystem(containerURL: containerURL, executor: executor).start()
}

private extension RunnerServiceOutput {
    static let agentLog = RunnerServiceOutput(
        info: { agentLogger.notice("\($0, privacy: .public)") },
        warning: { agentLogger.warning("\($0, privacy: .public)") },
        error: { agentLogger.error("\($0, privacy: .public)") }
    )
}
