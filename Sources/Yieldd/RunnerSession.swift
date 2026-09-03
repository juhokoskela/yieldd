import Foundation

protocol RunnerSessionRunning {
    func run(id: RunnerID, repository: GitHubRepository) throws
}

struct EphemeralRunnerSession: RunnerSessionRunning {
    static let configurationTimeout: TimeInterval = 5 * 60
    static let jobOutputTailBytes = 1_024 * 1_024
    static let maximumRecoveryRetryDelay: TimeInterval = 30

    let backend: any RunnerBackend
    let github: any GitHubRunnerManaging
    private let memoryAdmission: RunnerMemoryAdmission
    private let jobTimeout: TimeInterval?
    private let checkCancellation: () throws -> Void
    private let recoveryWait: (TimeInterval) throws -> Void
    private let stateChanged: (RunnerSessionState) -> Void
    private let leaseStore: RunnerLeaseStore?

    init(
        backend: any RunnerBackend,
        github: any GitHubRunnerManaging,
        memoryAdmission: RunnerMemoryAdmission,
        jobTimeout: TimeInterval? = nil,
        checkCancellation: @escaping () throws -> Void = {},
        recoveryWait: @escaping (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:),
        stateChanged: @escaping (RunnerSessionState) -> Void = { _ in },
        leaseStore: RunnerLeaseStore? = nil
    ) {
        if let jobTimeout {
            precondition(jobTimeout.isFinite && jobTimeout > 0)
        }
        self.backend = backend
        self.github = github
        self.memoryAdmission = memoryAdmission
        self.jobTimeout = jobTimeout
        self.checkCancellation = checkCancellation
        self.recoveryWait = recoveryWait
        self.stateChanged = stateChanged
        self.leaseStore = leaseStore
    }

    func run(id: RunnerID, repository: GitHubRepository) throws {
        stateChanged(.preparing(id))
        try checkCancellation()

        var lifecycle: RunnerLifecycle?
        var operationFailure: (any Error)?
        do {
            let reservation = try memoryAdmission.acquire(
                checkCancellation: checkCancellation,
                onBlocked: { stateChanged(.waitingForMemory(id)) }
            )
            lifecycle = .beforeMachine(reservation)
            let registrationToken = try github.createRegistrationToken(for: repository)
            try checkCancellation()
            try leaseStore?.save(RunnerLease(runnerID: id, repository: repository))
            lifecycle = .machineMayExist(reservation)
            try backend.create(id: id, memory: reservation.allocation)
            try checkCancellation()
            lifecycle = .runnerRegistrationMayExist(reservation)
            try backend.exec(
                ["yieldd-configure-runner", repository.fullName, id.value],
                standardInput: Data("\(registrationToken)\n".utf8),
                timeout: Self.configurationTimeout,
                on: id
            )
            try checkCancellation()
            stateChanged(.waitingForJob(id))
            lifecycle = .runnerMayBeRunning(reservation)
            try backend.exec(
                ["yieldd-runner-control", "run"],
                timeout: jobTimeout,
                outputCapture: .tail(maxBytes: Self.jobOutputTailBytes),
                as: .root,
                on: id
            )
            lifecycle = .runnerRegistrationMayExist(reservation)
        } catch {
            operationFailure = error
        }

        stateChanged(.cleaningUp(id))
        var cleanupFailures: [RunnerSessionCleanupFailure] = []
        if let cleanupLifecycle = lifecycle?.cleanupLifecycle {
            cleanupFailures = cleanup(
                lifecycle: cleanupLifecycle,
                id: id,
                repository: repository
            )
        }
        if let lifecycle,
           !cleanupFailures.contains(where: { $0.step == .machine }) {
            memoryAdmission.release(lifecycle.reservation)
        }
        if operationFailure == nil, isDeferredGitHubCleanup(cleanupFailures) {
            cleanupFailures = try retryDeferredGitHubCleanup(
                cleanupFailures,
                id: id,
                repository: repository
            )
        }

        if lifecycle?.leaseExists == true, cleanupFailures.isEmpty {
            clearLeaseAfterCleanup(id: id)
        }
        if leaseStore != nil, isDeferredGitHubCleanup(cleanupFailures) {
            throw RunnerSessionError.cleanupDeferred(
                id,
                operation: operationFailure
            )
        }

        if let operationFailure {
            guard !cleanupFailures.isEmpty else {
                throw operationFailure
            }
            throw RunnerSessionError.operationAndCleanupFailed(
                operation: operationFailure,
                cleanup: cleanupFailures
            )
        }
        guard cleanupFailures.isEmpty else {
            throw RunnerSessionError.cleanupFailed(cleanupFailures)
        }
    }

    func recoverAbandonedRunners() throws -> [RunnerID] {
        guard let leaseStore else {
            return []
        }

        let leases = try leaseStore.load()
        var recovered: Set<RunnerID> = []
        var deferredCleanup: [(
            lease: RunnerLease,
            failures: [RunnerSessionCleanupFailure]
        )] = []
        var recoveryFailures: [RunnerSessionCleanupFailure] = []

        for lease in leases {
            let failures = cleanup(
                lifecycle: RunnerCleanupLifecycle.runnerMayBeRunning,
                id: lease.runnerID,
                repository: lease.repository
            )

            if failures.isEmpty {
                clearLeaseAfterCleanup(id: lease.runnerID)
                recovered.insert(lease.runnerID)
            } else if isDeferredGitHubCleanup(failures) {
                deferredCleanup.append((lease, failures))
            } else {
                recoveryFailures.append(contentsOf: failures)
            }
        }

        for deferred in deferredCleanup {
            let failures = try retryDeferredGitHubCleanup(
                deferred.failures,
                id: deferred.lease.runnerID,
                repository: deferred.lease.repository
            )
            if failures.isEmpty {
                clearLeaseAfterCleanup(id: deferred.lease.runnerID)
                recovered.insert(deferred.lease.runnerID)
            } else {
                recoveryFailures.append(contentsOf: failures)
            }
        }

        guard recoveryFailures.isEmpty else {
            throw RunnerSessionError.cleanupFailed(recoveryFailures)
        }
        return leases.compactMap { lease in
            recovered.contains(lease.runnerID) ? lease.runnerID : nil
        }
    }

    private func retryDeferredGitHubCleanup(
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
            retryDelay = min(retryDelay * 2, Self.maximumRecoveryRetryDelay)
        }
        return failures
    }

    private func clearLeaseAfterCleanup(id: RunnerID) {
        guard let leaseStore else {
            return
        }
        do {
            try leaseStore.clear(id)
        } catch {
            stateChanged(.leaseCleanupFailed(id, reason: describeError(error)))
        }
    }

    private func cleanup(
        lifecycle: RunnerCleanupLifecycle,
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

    private func cleanupFailure(
        step: RunnerSessionCleanupStep,
        operation: () throws -> Void
    ) -> RunnerSessionCleanupFailure? {
        switch Result<Void, any Error>(catching: { try operation() }) {
        case .success:
            return nil
        case let .failure(error):
            return RunnerSessionCleanupFailure(step: step, error: error)
        }
    }

    private func isDeferredGitHubCleanup(
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
}

private enum RunnerLifecycle {
    case beforeMachine(RunnerMemoryReservation)
    case machineMayExist(RunnerMemoryReservation)
    case runnerRegistrationMayExist(RunnerMemoryReservation)
    case runnerMayBeRunning(RunnerMemoryReservation)

    var reservation: RunnerMemoryReservation {
        switch self {
        case let .beforeMachine(reservation),
             let .machineMayExist(reservation),
             let .runnerRegistrationMayExist(reservation),
             let .runnerMayBeRunning(reservation):
            reservation
        }
    }

    var cleanupLifecycle: RunnerCleanupLifecycle? {
        switch self {
        case .beforeMachine:
            nil
        case .machineMayExist:
            .machineMayExist
        case .runnerRegistrationMayExist:
            .runnerRegistrationMayExist
        case .runnerMayBeRunning:
            .runnerMayBeRunning
        }
    }

    var leaseExists: Bool {
        cleanupLifecycle != nil
    }
}

private enum RunnerCleanupLifecycle {
    case machineMayExist
    case runnerRegistrationMayExist
    case runnerMayBeRunning
}

enum RunnerSessionState: Equatable {
    case preparing(RunnerID)
    case waitingForMemory(RunnerID)
    case waitingForJob(RunnerID)
    case waitingForGitHubCleanup(RunnerID, retryDelay: TimeInterval)
    case cleaningUp(RunnerID)
    case leaseCleanupFailed(RunnerID, reason: String)
}

struct RunnerSessionCleanupFailure {
    let step: RunnerSessionCleanupStep
    let error: any Error
}

enum RunnerSessionCleanupStep: String, Equatable {
    case githubRunner = "GitHub runner"
    case machine
    case runnerProcess = "runner process"
}

enum RunnerSessionError: Error {
    case cleanupFailed([RunnerSessionCleanupFailure])
    case cleanupDeferred(RunnerID, operation: (any Error)?)
    case operationAndCleanupFailed(operation: any Error, cleanup: [RunnerSessionCleanupFailure])
}

extension RunnerSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .cleanupFailed(cleanup):
            "Runner cleanup failed: \(describe(cleanup))"
        case let .cleanupDeferred(id, operation):
            if let operation {
                "Runner session failed: \(describeError(operation)). GitHub cleanup for \(id.value) is deferred while the runner remains busy."
            } else {
                "GitHub cleanup for \(id.value) is deferred while the runner remains busy."
            }
        case let .operationAndCleanupFailed(operation, cleanup):
            "Runner session failed: \(describeError(operation)). Cleanup also failed: \(describe(cleanup))"
        }
    }

    private func describe(_ failures: [RunnerSessionCleanupFailure]) -> String {
        failures.map { failure in
            "\(failure.step.rawValue): \(describeError(failure.error))"
        }.joined(separator: "; ")
    }
}
