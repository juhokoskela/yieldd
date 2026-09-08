import Foundation

// Run only while holding runner ownership, before any new session can provision a VM.
struct RunnerRecovery {
    private let linuxBackend: () throws -> any RunnerBackend
    private let leaseStore: RunnerLeaseStore
    private let clones: MacOSRunnerCloneStore
    private let cleanup: RunnerCleanup
    private let checkCancellation: () throws -> Void

    init(
        linuxBackend: @escaping () throws -> any RunnerBackend,
        github: any GitHubRunnerManaging,
        leaseStore: RunnerLeaseStore,
        recoveryWait: @escaping (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:),
        checkCancellation: @escaping () throws -> Void = {},
        stateChanged: @escaping (RunnerSessionState) -> Void = { _ in }
    ) {
        self.linuxBackend = linuxBackend
        self.leaseStore = leaseStore
        clones = MacOSRunnerCloneStore(stateDirectory: leaseStore.directory)
        self.checkCancellation = checkCancellation
        cleanup = RunnerCleanup(github: github, recoveryWait: recoveryWait, stateChanged: stateChanged, leaseStore: leaseStore)
    }

    func run() throws -> [RunnerID] {
        try checkCancellation()
        let leases = try leaseStore.load()
        var deferredCleanup: [(
            lease: RunnerLease,
            failures: [RunnerSessionCleanupFailure]
        )] = []
        var recoveryFailures: [RunnerSessionCleanupFailure] = []

        do {
            try clones.removeUnleased(keeping: Set(leases.map(\.runnerID)), checkCancellation: checkCancellation)
        } catch {
            if isCancellation(error) { throw error }
            recoveryFailures.append(RunnerSessionCleanupFailure(step: .machine, error: error))
        }

        for lease in leases {
            let failures: [RunnerSessionCleanupFailure]
            switch lease.platform {
            case .linux:
                do {
                    failures = cleanup.run(
                        lifecycle: .runnerMayBeRunning, backend: try linuxBackend(),
                        id: lease.runnerID, repository: lease.repository
                    )
                } catch {
                    if isCancellation(error) { throw error }
                    failures = [RunnerSessionCleanupFailure(
                        step: .machine, error: RunnerRecoveryError.linuxBackendUnavailable(error)
                    )]
                }
            case .macOS:
                failures = cleanup.removeRegistrationAndClone(
                    id: lease.runnerID, repository: lease.repository, clones: clones
                )
            }

            if failures.isEmpty {
                cleanup.clearLeaseAfterCleanup(id: lease.runnerID)
            } else if cleanup.isDeferredGitHubCleanup(failures) {
                deferredCleanup.append((lease, failures))
            } else {
                recoveryFailures.append(contentsOf: failures)
            }
        }

        for deferred in deferredCleanup {
            let failures = try cleanup.retryDeferredGitHubCleanup(
                deferred.failures,
                id: deferred.lease.runnerID,
                repository: deferred.lease.repository
            )
            if failures.isEmpty {
                cleanup.clearLeaseAfterCleanup(id: deferred.lease.runnerID)
            } else {
                recoveryFailures.append(contentsOf: failures)
            }
        }

        guard recoveryFailures.isEmpty else {
            throw RunnerSessionError.cleanupFailed(recoveryFailures)
        }
        return leases.map(\.runnerID)
    }
}

enum RunnerRecoveryError: Error, LocalizedError {
    case linuxBackendUnavailable(any Error)

    var errorDescription: String? {
        switch self {
        case let .linuxBackendUnavailable(error):
            "Linux lease recovery requires Apple Container. Restore the container executable and retry recovery: \(describeError(error))"
        }
    }
}
