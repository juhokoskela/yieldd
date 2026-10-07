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

    @Option(name: .long, help: "Maximum minutes for the listener, or job execution with --routing-label, up to 1440.")
    var timeout = 120

    @Option(name: .long, help: "Run only a job targeting this unique yieldd-request- label.")
    var routingLabel: String? = nil

    @Option(name: .long, help: "Maximum minutes to pick up a reserved job; requires --routing-label.")
    var pickupTimeout: Int? = nil

    @OptionGroup
    var machine: RunnerMachineOptions

    mutating func validate() throws {
        guard timeout > 0 else {
            throw ValidationError("--timeout must be greater than zero.")
        }
        guard timeout <= Self.maximumTimeoutMinutes else {
            throw ValidationError("--timeout must not exceed \(Self.maximumTimeoutMinutes) minutes.")
        }
        _ = try assignment()
    }

    func assignment() throws -> RunnerAssignment? {
        guard let routingLabel else {
            guard pickupTimeout == nil else { throw ValidationError("--pickup-timeout requires --routing-label.") }
            return nil
        }
        guard (1...Self.maximumTimeoutMinutes).contains(pickupTimeout ?? 5) else {
            throw ValidationError("--pickup-timeout must be between 1 and 1440 minutes.")
        }
        do {
            return try RunnerAssignment(routingLabel: routingLabel, pickupTimeout: TimeInterval(pickupTimeout ?? 5) * 60)
        } catch {
            throw ValidationError(describeError(error))
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
        let assignment = try assignment()
        let startupDeadline = assignment.map { _ in RunnerStartupDeadline(checkCancellation: signalMonitor.check) }
        let check = startupDeadline.map { $0.check } ?? signalMonitor.check
        let locator = ExecutableLocator()
        let executor = ProcessExecutor(checkCancellation: check)
        let backend = try machine.makeBackend(
            leaseStore: leaseStore, executor: executor,
            checkCancellation: check, wait: signalMonitor.wait
        )
        let github = GitHubRunnerClient(
            ghURL: try locator.locate("gh"),
            executor: executor
        )
        let stateChanged: (RunnerSessionState) -> Void = { state in
            switch state {
            case let .waitingForMemory(id):
                print("Runner \(id.value) is waiting for available host memory.")
            case .waitingForGitHubCleanup, .leaseCleanupFailed:
                reportRunnerRecoveryState(state)
            case .listenerStarted, .jobStarted, .listenerExited, .executionStopped, .capacityReleased, .cleanupCompleted:
                reportRunnerServiceState(state, platform: backend.platform, output: .terminal)
            case .preparing, .waitingForJob, .cleaningUp:
                break
            }
        }
        let session = EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: RunnerMemoryAdmission(),
            jobTimeout: TimeInterval(timeout) * 60,
            checkCancellation: check,
            recoveryWait: signalMonitor.wait,
            stateChanged: stateChanged,
            leaseStore: leaseStore,
            assignment: assignment,
            startupDeadline: startupDeadline
        )

        let recovery = RunnerRecovery(
            linuxBackend: {
                try AppleContainerBackend(containerURL: try locator.locate("container"), executor: executor, stateDirectory: leaseStore.directory)
            },
            github: github, leaseStore: leaseStore,
            recoveryWait: signalMonitor.wait, checkCancellation: signalMonitor.check,
            stateChanged: stateChanged
        )
        for recoveredID in try recovery.run() {
            print("Cleaned up abandoned runner \(recoveredID.value).")
        }

        let id = backend.platform.makeTestRunnerID()
        print("Starting ephemeral runner \(id.value) for \(repository.fullName).")
        print("Waiting for one job labeled '\(routingLabel ?? backend.platform.runnerLabel)'.")

        try session.run(id: id, repository: repository)
        print("Runner job completed and cleanup passed.")
    }
}
