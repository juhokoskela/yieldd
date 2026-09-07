import ArgumentParser
import Foundation

struct RunnerTestCommand: ParsableCommand {
    static let maximumTimeoutMinutes = 24 * 60

    static let configuration = CommandConfiguration(
        commandName: "runner-test",
        abstract: "Run one GitHub Actions job on a temporary runner machine."
    )

    @Argument(help: "Repository in owner/name form.")
    var repository: String

    @Option(name: .long, help: "Maximum number of minutes to wait for a job, up to 1440.")
    var timeout = 120

    mutating func validate() throws {
        guard timeout > 0 else {
            throw ValidationError("--timeout must be greater than zero.")
        }
        guard timeout <= Self.maximumTimeoutMinutes else {
            throw ValidationError("--timeout must not exceed \(Self.maximumTimeoutMinutes) minutes.")
        }
    }

    mutating func run() throws {
        let repository = try GitHubRepository(repository)
        try withRunnerOwnership { leaseStore in
            try run(repository: repository, leaseStore: leaseStore)
        }
    }

    private func run(repository: GitHubRepository, leaseStore: RunnerLeaseStore) throws {
        let signalMonitor = try SignalMonitor()
        let locator = ExecutableLocator()
        let executor = ProcessExecutor(checkCancellation: signalMonitor.check)
        let backend = AppleContainerBackend(
            containerURL: try locator.locate("container"),
            executor: executor,
            dockerReadiness: DockerReadiness(
                wait: signalMonitor.wait,
                checkCancellation: signalMonitor.check
            )
        )
        let github = GitHubRunnerClient(
            ghURL: try locator.locate("gh"),
            executor: executor
        )
        let stateChanged: (RunnerSessionState) -> Void = { state in
            switch state {
            case let .waitingForMemory(id):
                print("Runner \(id.value) is waiting for available host memory.")
            case let .waitingForGitHubCleanup(id, retryDelay):
                print(githubCleanupRetryMessage(id: id, delay: retryDelay))
            case let .leaseCleanupFailed(id, reason):
                writeToStandardError("Warning: Could not clear runner lease for \(id.value): \(reason)\n")
            case .preparing, .waitingForJob, .cleaningUp:
                break
            }
        }
        let session = EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: RunnerMemoryAdmission(),
            jobTimeout: TimeInterval(timeout) * 60,
            checkCancellation: signalMonitor.check,
            recoveryWait: signalMonitor.wait,
            stateChanged: stateChanged,
            leaseStore: leaseStore
        )

        let recovery = RunnerRecovery(
            linuxBackend: backend, github: github, leaseStore: leaseStore,
            recoveryWait: signalMonitor.wait, checkCancellation: signalMonitor.check,
            stateChanged: stateChanged
        )
        for recoveredID in try recovery.run() {
            print("Cleaned up abandoned runner \(recoveredID.value).")
        }

        let id = RunnerID(value: "yieldd-test-\(UUID().uuidString.lowercased())")
        print("Starting ephemeral runner \(id.value) for \(repository.fullName).")
        print("Waiting for one job labeled 'yieldd'.")

        try session.run(id: id, repository: repository)
        print("Runner job completed and cleanup passed.")
    }
}
