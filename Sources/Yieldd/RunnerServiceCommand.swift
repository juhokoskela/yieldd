import ArgumentParser
import Foundation

struct RunnerServiceOutput: Sendable {
    let info: @Sendable (String) -> Void
    let warning: @Sendable (String) -> Void
    let error: @Sendable (String) -> Void

    static let terminal = RunnerServiceOutput(
        info: { print($0) },
        warning: { writeToStandardError("Warning: \($0)\n") },
        error: { writeToStandardError("\($0)\n") }
    )
}

struct RunnerServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Continuously run ephemeral GitHub Actions runners."
    )

    @Argument(help: "Repositories in owner/name form. Repeat a repository to give it another runner slot.")
    var repositories: [String]

    mutating func validate() throws {
        guard repositories.count <= RunnerPool.maximumSlots else {
            throw ValidationError("serve supports at most \(RunnerPool.maximumSlots) runner slots.")
        }
    }

    mutating func run() throws {
        let repositories = try repositories.map(GitHubRepository.init)
        let locator = ExecutableLocator()
        let containerURL = try locator.locate("container")
        let ghURL = try locator.locate("gh")
        let stop = try RunnerPoolStop.monitoringSignals()
        defer { print("Stopping yieldd.") }
        print("Press Ctrl+C to stop.")
        try withRunnerOwnership { leaseStore in
            try runRunnerService(
                repositories: repositories,
                leaseStore: leaseStore,
                containerURL: containerURL,
                ghURL: ghURL,
                stop: stop,
                output: .terminal
            )
        }
    }
}

func runRunnerService(
    repositories: [GitHubRepository],
    leaseStore: RunnerLeaseStore,
    containerURL: URL,
    ghURL: URL,
    stop: RunnerPoolStop,
    output: RunnerServiceOutput
) throws {
    let sessionStateChanged: @Sendable (RunnerSessionState) -> Void = { state in
        switch state {
        case let .preparing(id):
            output.info("Preparing ephemeral runner \(id.value).")
        case let .waitingForJob(id):
            output.info("Runner \(id.value) is waiting for one job labeled 'yieldd'.")
        case let .waitingForGitHubCleanup(id, retryDelay):
            output.info(githubCleanupRetryMessage(id: id, delay: retryDelay))
        case let .cleaningUp(id):
            output.info("Cleaning up runner \(id.value).")
        case let .leaseCleanupFailed(id, reason):
            output.warning("Could not clear runner lease for \(id.value): \(reason)")
        }
    }
    let makeSession: @Sendable () -> EphemeralRunnerSession = {
        makeRunnerSession(
            leaseStore: leaseStore,
            containerURL: containerURL,
            ghURL: ghURL,
            stop: stop,
            stateChanged: sessionStateChanged
        )
    }

    do {
        for recoveredID in try makeSession().recoverAbandonedRunners() {
            output.info("Cleaned up abandoned runner \(recoveredID.value).")
        }
    } catch {
        guard isCancellation(error) else {
            throw error
        }
        return
    }

    let slot = repositories.count == 1 ? "slot" : "slots"
    let names = repositories.map(\.fullName).joined(separator: ", ")
    output.info("Serving \(repositories.count) ephemeral runner \(slot) for \(names).")

    try RunnerPool(stop: stop) { repository, stop in
        try RunnerService(
            session: makeSession(),
            makeRunnerID: {
                RunnerID(value: "yieldd-\(UUID().uuidString.lowercased())")
            },
            checkForStop: stop.check,
            waitUntilStopped: stop.wait,
            stateChanged: { state in
                switch state {
                case let .backingOff(failures, delay):
                    let unit = delay == 1 ? "second" : "seconds"
                    output.info("Runner slot for \(repository.fullName) failed \(failures) time(s); retrying in \(Int(delay)) \(unit).")
                case let .cleanupDeferred(id):
                    output.info("GitHub cleanup for \(id.value) is deferred until GitHub releases its active job.")
                }
            },
            sessionFailed: { error in
                if !isCancellation(error) {
                    output.error("Runner session for \(repository.fullName) failed: \(describeError(error))")
                }
            }
        ).run(repository: repository)
    }.run(repositories: repositories)
}

func makeRunnerSession(
    leaseStore: RunnerLeaseStore,
    containerURL: URL,
    ghURL: URL,
    stop: RunnerPoolStop,
    stateChanged: @escaping (RunnerSessionState) -> Void
) -> EphemeralRunnerSession {
    let executor = ProcessExecutor(
        checkCancellation: stop.check,
        maximumExecutionDeadline: stop.executionDeadline
    )
    return EphemeralRunnerSession(
        backend: AppleContainerBackend(
            containerURL: containerURL,
            executor: executor
        ),
        github: GitHubRunnerClient(
            ghURL: ghURL,
            executor: executor
        ),
        checkCancellation: stop.check,
        recoveryWait: stop.wait,
        stateChanged: stateChanged,
        leaseStore: leaseStore
    )
}

func githubCleanupRetryMessage(id: RunnerID, delay: TimeInterval) -> String {
    let unit = delay == 1 ? "second" : "seconds"
    return "GitHub still considers runner \(id.value) busy; retrying cleanup in \(Int(delay)) \(unit)."
}

func isCancellation(_ error: any Error) -> Bool {
    if error is SignalInterruption || error is CancellationError {
        return true
    }
    if let error = error as? ProcessExecutionError {
        switch error {
        case .cancelled, .executionDeadlineExceeded:
            return true
        default:
            break
        }
    }
    return false
}

func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}
