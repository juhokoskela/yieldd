import ArgumentParser
import Foundation

struct RunnerTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runner-test",
        abstract: "Run one GitHub Actions job on a temporary runner machine."
    )

    @Argument(help: "Repository in owner/name form.")
    var repository: String

    @Option(name: .long, help: "Maximum number of minutes to wait for a job.")
    var timeout = 120

    mutating func validate() throws {
        guard timeout > 0 else {
            throw ValidationError("--timeout must be greater than zero.")
        }
    }

    mutating func run() throws {
        let repository = try GitHubRepository(repository)
        let signalMonitor = try SignalMonitor()
        let locator = ExecutableLocator()
        let executor = ProcessExecutor(checkCancellation: signalMonitor.check)
        let backend = AppleContainerBackend(
            containerURL: try locator.locate("container"),
            executor: executor
        )
        let github = GitHubRunnerClient(
            ghURL: try locator.locate("gh"),
            executor: executor
        )
        let id = RunnerID(value: "yieldd-test-\(UUID().uuidString.lowercased())")

        print("Starting ephemeral runner \(id.value) for \(repository.fullName).")
        print("Waiting for one job labeled 'yieldd'.")

        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            jobTimeout: TimeInterval(timeout) * 60,
            checkCancellation: signalMonitor.check
        ).run(
            id: id,
            repository: repository
        )
        print("Runner job completed and cleanup passed.")
    }
}
