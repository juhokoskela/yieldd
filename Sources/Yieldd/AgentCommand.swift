import ArgumentParser
import Foundation
import OSLog

private let agentLogger = Logger(subsystem: "dev.yieldd", category: "agent")

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Run the configured local agent."
    )

    mutating func run() throws {
        do {
            let store = try AgentConfigurationStore()
            let configuration = try store.load()
            try configuration.requireExecutables()
            try withRunnerOwnership(in: store.directory) { leaseStore in
                try AppleContainerSystem(
                    containerURL: configuration.containerURL,
                    executor: ProcessExecutor()
                ).start()
                try runRunnerService(
                    repositories: configuration.repositories,
                    leaseStore: leaseStore,
                    containerURL: configuration.containerURL,
                    ghURL: configuration.ghURL,
                    output: .agentLog
                )
            }
        } catch {
            agentLogger.error("Local agent failed: \(describeError(error), privacy: .public)")
            throw error
        }
    }
}

private extension RunnerServiceOutput {
    static let agentLog = RunnerServiceOutput(
        info: { agentLogger.notice("\($0, privacy: .public)") },
        warning: { agentLogger.warning("\($0, privacy: .public)") },
        error: { agentLogger.error("\($0, privacy: .public)") },
        stopInstruction: ""
    )
}
