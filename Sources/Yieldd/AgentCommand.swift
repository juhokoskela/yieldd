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

    @Argument(help: "Repositories in owner/name form. Repeat a repository to give it another runner slot.")
    var repositories: [String]

    @Flag(name: .long, help: .hidden)
    var preflightOnly = false

    mutating func validate() throws {
        guard repositories.count <= RunnerPool.maximumSlots else {
            throw ValidationError("The local agent supports at most \(RunnerPool.maximumSlots) runner slots.")
        }
        _ = try repositories.map(GitHubRepository.init)
    }

    mutating func run() throws {
        let locator = ExecutableLocator()
        try run(locateExecutable: locator.locate)
    }

    func run(locateExecutable: (String) throws -> URL) throws {
        let configuration = try AgentConfiguration(
            repositories: repositories.map(GitHubRepository.init),
            containerURL: locateExecutable("container"),
            ghURL: locateExecutable("gh")
        )
        guard !preflightOnly else {
            return
        }

        let service = try localAgentService()
        try installAgent(
            configuration: configuration,
            store: AgentConfigurationStore(),
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
                try AppleContainerSystem(
                    containerURL: configuration.containerURL,
                    executor: ProcessExecutor(
                        checkCancellation: stop.check,
                        maximumExecutionDeadline: stop.executionDeadline
                    )
                ).start()
                try runRunnerService(
                    configuration: RunnerServiceConfiguration(repositories: configuration.repositories),
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
        let recovery = makeRunnerRecovery(
            leaseStore: leaseStore,
            resolveContainer: { configuration.containerURL },
            ghURL: configuration.ghURL,
            stop: stop,
            executor: ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline),
            stateChanged: { reportRunnerRecoveryState($0) }
        )
        for id in try recovery.run() {
            print("Cleaned up abandoned runner \(id.value).")
        }
    }
}

private extension RunnerServiceOutput {
    static let agentLog = RunnerServiceOutput(
        info: { agentLogger.notice("\($0, privacy: .public)") },
        warning: { agentLogger.warning("\($0, privacy: .public)") },
        error: { agentLogger.error("\($0, privacy: .public)") }
    )
}
