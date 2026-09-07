import Foundation

struct RunnerCleanup {
    static let maximumRetryDelay: TimeInterval = 30

    let github: any GitHubRunnerManaging
    let recoveryWait: (TimeInterval) throws -> Void
    let stateChanged: (RunnerSessionState) -> Void
    let leaseStore: RunnerLeaseStore?

    func retryDeferredGitHubCleanup(
        _ initialFailures: [RunnerSessionCleanupFailure],
        id: RunnerID,
        repository: GitHubRepository
    ) throws -> [RunnerSessionCleanupFailure] {
        var failures = initialFailures
        var retryDelay: TimeInterval = 1
        while isDeferredGitHubCleanup(failures) {
            stateChanged(.waitingForGitHubCleanup(id, retryDelay: retryDelay))
            try recoveryWait(retryDelay)
            failures = [cleanupFailure(step: .githubRunner) {
                try github.removeRunners(named: id.value, from: repository)
            }].compactMap { $0 }
            retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
        }
        return failures
    }

    func clearLeaseAfterCleanup(id: RunnerID) {
        guard let leaseStore else {
            return
        }
        do {
            try leaseStore.clear(id)
        } catch {
            stateChanged(.leaseCleanupFailed(id, reason: describeError(error)))
        }
    }

    func run(
        lifecycle: RunnerCleanupLifecycle,
        backend: any RunnerBackend,
        id: RunnerID,
        repository: GitHubRepository
    ) -> [RunnerSessionCleanupFailure] {
        let removeRunner = {
            cleanupFailure(step: .githubRunner) {
                try github.removeRunners(named: id.value, from: repository)
            }
        }
        let destroyMachine = {
            cleanupFailure(step: .machine) {
                try backend.destroy(id)
            }
        }

        switch lifecycle {
        case .machineMayExist:
            return [destroyMachine()].compactMap { $0 }
        case .runnerRegistrationMayExist:
            return [removeRunner(), destroyMachine()].compactMap { $0 }
        case .runnerMayBeRunning:
            if let stopFailure = cleanupFailure(step: .runnerProcess, operation: {
                try backend.stopRunner(on: id)
            }) {
                if let machineFailure = destroyMachine() {
                    return [stopFailure, machineFailure]
                }
                return [removeRunner()].compactMap { $0 }
            }
            return [removeRunner(), destroyMachine()].compactMap { $0 }
        }
    }

    func cleanupFailure(
        step: RunnerSessionCleanupStep,
        operation: () throws -> Void
    ) -> RunnerSessionCleanupFailure? {
        do {
            try operation()
            return nil
        } catch {
            return RunnerSessionCleanupFailure(step: step, error: error)
        }
    }

    func isDeferredGitHubCleanup(
        _ failures: [RunnerSessionCleanupFailure]
    ) -> Bool {
        guard failures.count == 1,
              failures[0].step == .githubRunner,
              let error = failures[0].error as? GitHubRunnerClientError,
              case .runnerBusy = error else {
            return false
        }
        return true
    }

    func removeRegistrationAndClone(
        id: RunnerID,
        repository: GitHubRepository,
        clones: MacOSRunnerCloneStore
    ) -> [RunnerSessionCleanupFailure] {
        [
            cleanupFailure(step: .githubRunner) {
                try github.removeRunners(named: id.value, from: repository)
            },
            cleanupFailure(step: .machine) { try clones.remove(id) },
        ].compactMap { $0 }
    }
}
