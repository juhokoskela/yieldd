import Foundation

protocol RunnerSessionRunning {
    func run(id: RunnerID, repository: GitHubRepository) throws
}

struct EphemeralRunnerSession: RunnerSessionRunning {
    static let configurationTimeout: TimeInterval = 5 * 60
    static let jobOutputTailBytes = 1_024 * 1_024

    let backend: any RunnerBackend
    let github: any GitHubRunnerManaging
    private let memoryAdmission: RunnerMemoryAdmission
    private let jobTimeout: TimeInterval?
    private let checkCancellation: () throws -> Void
    private let cleanup: RunnerCleanup
    private let stateChanged: (RunnerSessionState) -> Void
    private let leaseStore: RunnerLeaseStore?
    private let assignment: RunnerAssignment?
    private let wait: (TimeInterval) throws -> Void
    private let startupDeadline: RunnerStartupDeadline?

    init(
        backend: any RunnerBackend,
        github: any GitHubRunnerManaging,
        memoryAdmission: RunnerMemoryAdmission,
        jobTimeout: TimeInterval? = nil,
        checkCancellation: @escaping () throws -> Void = {},
        recoveryWait: @escaping (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:),
        stateChanged: @escaping (RunnerSessionState) -> Void = { _ in },
        leaseStore: RunnerLeaseStore? = nil,
        assignment: RunnerAssignment? = nil,
        startupDeadline: RunnerStartupDeadline? = nil
    ) {
        if let jobTimeout {
            precondition(jobTimeout.isFinite && jobTimeout > 0)
        }
        self.backend = backend
        self.github = github
        self.memoryAdmission = memoryAdmission
        self.jobTimeout = jobTimeout
        self.checkCancellation = checkCancellation
        cleanup = RunnerCleanup(github: github, recoveryWait: recoveryWait, stateChanged: stateChanged, leaseStore: leaseStore)
        self.stateChanged = stateChanged
        self.leaseStore = leaseStore
        self.assignment = assignment
        wait = recoveryWait
        self.startupDeadline = startupDeadline
    }

    func run(id: RunnerID, repository: GitHubRepository) throws {
        stateChanged(.preparing(id))
        try checkCancellation()

        var reservation: RunnerMemoryReservation?
        var lifecycle: RunnerCleanupLifecycle?
        var operationFailure: (any Error)?
        do {
            let acquiredReservation = try memoryAdmission.acquire(
                reserving: backend.platform.memoryReservationBytes,
                checkCancellation: checkCancellation,
                onBlocked: { stateChanged(.waitingForMemory(id)) }
            )
            reservation = acquiredReservation
            startupDeadline?.begin()
            let registrationToken = try github.createRegistrationToken(for: repository)
            try checkCancellation()
            lifecycle = .machineMayExist
            try leaseStore?.save(RunnerLease(runnerID: id, repository: repository, platform: backend.platform))
            try backend.create(id: id, memory: acquiredReservation.allocation)
            try checkCancellation()
            lifecycle = .runnerRegistrationMayExist
            try backend.exec(
                ["yieldd-configure-runner", repository.fullName, id.value]
                    + (assignment.map { [$0.routingLabel] } ?? []),
                standardInput: Data("\(registrationToken)\n".utf8),
                timeout: Self.configurationTimeout,
                on: id
            )
            try checkCancellation()
            startupDeadline?.end()
            stateChanged(.waitingForJob(id))
            lifecycle = .runnerMayBeRunning
            if let assignment {
                try ReservedRunnerJob(
                    backend: backend, checkCancellation: checkCancellation,
                    wait: wait, stateChanged: stateChanged
                ).run(id: id, pickupTimeout: assignment.pickupTimeout, executionTimeout: jobTimeout)
            } else {
                try backend.exec(
                    ["yieldd-runner-control", "run"], timeout: jobTimeout,
                    outputCapture: .tail(maxBytes: Self.jobOutputTailBytes), as: .root, on: id
                )
            }
            lifecycle = .runnerRegistrationMayExist
        } catch {
            operationFailure = error
        }
        startupDeadline?.end()

        var cleanupFailures: [RunnerSessionCleanupFailure] = []
        if let lifecycle {
            stateChanged(.cleaningUp(id))
            cleanupFailures = cleanup.run(
                lifecycle: lifecycle,
                backend: backend,
                id: id,
                repository: repository
            )
        }
        if let reservation,
           !cleanupFailures.contains(where: { $0.step == .machine }) {
            memoryAdmission.release(reservation)
            if assignment != nil { stateChanged(.capacityReleased(id)) }
        }
        if operationFailure == nil, cleanup.isDeferredGitHubCleanup(cleanupFailures) {
            cleanupFailures = try cleanup.retryDeferredGitHubCleanup(
                cleanupFailures,
                id: id,
                repository: repository
            )
        }

        if lifecycle != nil, cleanupFailures.isEmpty {
            cleanup.clearLeaseAfterCleanup(id: id)
            if assignment != nil { stateChanged(.cleanupCompleted(id)) }
        }
        if leaseStore != nil, cleanup.isDeferredGitHubCleanup(cleanupFailures) {
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
}

enum RunnerCleanupLifecycle {
    case machineMayExist
    case runnerRegistrationMayExist
    case runnerMayBeRunning
}

enum RunnerSessionState: Equatable {
    case listenerStarted(RunnerID)
    case jobStarted(RunnerID)
    case listenerExited(RunnerID, status: Int32)
    case capacityReleased(RunnerID)
    case cleanupCompleted(RunnerID)
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
    case leaseRecord = "lease record"
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
