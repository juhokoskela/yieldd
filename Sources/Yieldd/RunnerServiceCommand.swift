import ArgumentParser
import Foundation

struct RunnerServiceCommand: ParsableCommand {
    static let maximumSlots = 16

    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Continuously run ephemeral GitHub Actions runners."
    )

    @Argument(help: "Repositories in owner/name form. Repeat a repository to give it another runner slot.")
    var repositories: [String]

    mutating func validate() throws {
        guard repositories.count <= Self.maximumSlots else {
            throw ValidationError("serve supports at most \(Self.maximumSlots) runner slots.")
        }
    }

    mutating func run() throws {
        let repositories = try repositories.map(GitHubRepository.init)
        try withRunnerOwnership { leaseStore in
            try run(repositories: repositories, leaseStore: leaseStore)
        }
    }

    private func run(repositories: [GitHubRepository], leaseStore: RunnerLeaseStore) throws {
        let signalMonitor = try SignalMonitor()
        let stop = RunnerPoolStop(checkExternal: signalMonitor.check)
        let locator = ExecutableLocator()
        let containerURL = try locator.locate("container")
        let ghURL = try locator.locate("gh")
        let sessionStateChanged: @Sendable (RunnerSessionState) -> Void = { state in
            switch state {
            case let .preparing(id):
                print("Preparing ephemeral runner \(id.value).")
            case let .waitingForJob(id):
                print("Runner \(id.value) is waiting for one job labeled 'yieldd'.")
            case let .waitingForGitHubCleanup(id, retryDelay):
                let unit = retryDelay == 1 ? "second" : "seconds"
                print("GitHub still considers runner \(id.value) busy; retrying cleanup in \(Int(retryDelay)) \(unit).")
            case let .cleaningUp(id):
                print("Cleaning up runner \(id.value).")
            case let .leaseCleanupFailed(id, reason):
                writeToStandardError("Warning: Could not clear runner lease for \(id.value): \(reason)\n")
            }
        }
        let makeSession: @Sendable () -> EphemeralRunnerSession = {
            let executor = ProcessExecutor(checkCancellation: stop.check)
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
                stateChanged: sessionStateChanged,
                leaseStore: leaseStore
            )
        }

        do {
            for recoveredID in try makeSession().recoverAbandonedRunners() {
                print("Cleaned up abandoned runner \(recoveredID.value).")
            }
        } catch {
            guard isCancellation(error) else {
                throw error
            }
            print("Stopping yieldd.")
            return
        }

        let slot = repositories.count == 1 ? "slot" : "slots"
        let names = repositories.map(\.fullName).joined(separator: ", ")
        print("Serving \(repositories.count) ephemeral runner \(slot) for \(names). Press Ctrl+C to stop.")
        defer { print("Stopping yieldd.") }

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
                        print("Runner slot for \(repository.fullName) failed \(failures) time(s); retrying in \(Int(delay)) \(unit).")
                    case let .cleanupDeferred(id):
                        print("GitHub cleanup for \(id.value) is deferred until GitHub releases its active job.")
                    }
                },
                sessionFailed: { error in
                    if !isCancellation(error) {
                        writeToStandardError("Runner session for \(repository.fullName) failed: \(describeError(error))\n")
                    }
                }
            ).run(repository: repository)
        }.run(repositories: repositories)
    }
}

func isCancellation(_ error: any Error) -> Bool {
    if error is SignalInterruption || error is CancellationError {
        return true
    }
    if case ProcessExecutionError.cancelled = error {
        return true
    }
    return false
}

func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}
