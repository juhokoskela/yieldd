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
            AgentPauseCommand.self,
            AgentReclaimCommand.self,
            AgentResumeCommand.self,
            AgentDrainCommand.self,
            AgentUninstallCommand.self,
            AgentRunCommand.self,
        ]
    )
}

struct AgentStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show local agent registration, configuration, and active runners."
    )

    @Flag(name: .long, help: "Print a versioned JSON report for the connected agent.")
    var json = false

    mutating func run() throws {
        let report = try connectedAgentStatus(registration: AgentRegistrationState(localAgentService().status()),
                                              directory: yielddApplicationSupportDirectory())
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print(renderAgentStatus(report))
        }
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

        let store = try ConnectedAgentStore(directory: yielddApplicationSupportDirectory())
        try await uninstallConnectedAgent(store: store, credentials: .keychain, service: service) { configuration, token in
            try recoverConnectedAgent(configuration: configuration, token: token, directory: store.directory,
                stop: RunnerPoolStop.monitoringSignals())
        }
        print("Agent unregistered and configuration removed.")
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
        defer { agentLogger.notice("Stopping yieldd.") }
        var stateDirectory: URL?
        do {
            let store = try ConnectedAgentStore(directory: yielddApplicationSupportDirectory())
            stateDirectory = store.directory
            guard let connected = try store.load() else { throw AgentError.connectedConfigurationRequired }
            let control = ConnectedAgentControl(directory: store.directory, configuration: connected)
            let stop = try RunnerPoolStop.monitoringSignals(shutdownTimeout: Self.shutdownTimeout, onStop: control.stopping)
            let endpoint = AgentControlEndpoint(control: control)
            endpoint.start()
            defer { endpoint.stop() }
            try runConnectedService(server: connected.server, deviceID: connected.deviceID,
                loadToken: {
                    try prepareConnectedAgentKeychain()
                    return try ConnectedAgentCredentials.keychain.load(connected.credentialAccount)
                },
                platforms: connected.platforms, template: connected.template, stop: stop, stateDirectory: store.directory,
                resolveContainer: connected.resolveContainer, output: .agentLog, control: control)
        } catch where isCancellation(error) {
            return
        } catch {
            if let stateDirectory, FileManager.default.fileExists(atPath: ConnectedAgentStore(directory: stateDirectory).file.path) {
                // Diagnostic history is best effort and never changes recovery obligations.
                try? AgentFailureStore(directory: stateDirectory).save(AgentReportedError(message: describeError(error)))
            }
            agentLogger.error("Local agent failed: \(describeError(error), privacy: .public)")
            throw error
        }
    }
}

extension RunnerServiceOutput {
    static let agentLog = RunnerServiceOutput(
        info: { agentLogger.notice("\($0, privacy: .public)") },
        warning: { agentLogger.warning("\($0, privacy: .public)") },
        error: { agentLogger.error("\($0, privacy: .public)") }
    )
}
