import Foundation

protocol RunnerSessionRunning {
    func run(id: RunnerID, repository: GitHubRepository) throws
}

struct EphemeralRunnerSession: RunnerSessionRunning {
    static let image = MachineTestRunner.image
    static let configurationTimeout: TimeInterval = 5 * 60
    static let memoryConfigurationTimeout: TimeInterval = 30
    static let jobOutputTailBytes = 1_024 * 1_024

    let backend: any RunnerBackend
    let github: any GitHubRunnerManaging
    private let jobTimeout: TimeInterval?
    private let dockerReadiness: DockerReadiness
    private let readMemoryPressure: () -> HostMemoryPressure
    private let checkCancellation: () throws -> Void
    private let stateChanged: (RunnerSessionState) -> Void

    init(
        backend: any RunnerBackend,
        github: any GitHubRunnerManaging,
        jobTimeout: TimeInterval? = nil,
        dockerInfoAttempts: Int = 30,
        retryDelay: TimeInterval = 1,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        readMemoryPressure: @escaping () -> HostMemoryPressure = HostMemoryPressure.current,
        checkCancellation: @escaping () throws -> Void = {},
        stateChanged: @escaping (RunnerSessionState) -> Void = { _ in }
    ) {
        if let jobTimeout {
            precondition(jobTimeout.isFinite && jobTimeout > 0)
        }
        self.backend = backend
        self.github = github
        self.jobTimeout = jobTimeout
        self.readMemoryPressure = readMemoryPressure
        self.checkCancellation = checkCancellation
        self.stateChanged = stateChanged
        dockerReadiness = DockerReadiness(
            backend: backend,
            attempts: dockerInfoAttempts,
            retryDelay: retryDelay,
            sleep: sleep,
            checkCancellation: checkCancellation
        )
    }

    func run(id: RunnerID, repository: GitHubRepository) throws {
        stateChanged(.preparing(id))
        let registrationToken = try github.createRegistrationToken(for: repository)
        try checkCancellation()

        var lifecycle = RunnerLifecycle.machineMayExist
        let operation = Result<Void, any Error> {
            try backend.create(id: id, image: Self.image)
            try checkCancellation()
            try dockerReadiness.wait(on: id)
            try checkCancellation()
            let memoryAllocation: RunnerMemoryAllocation = readMemoryPressure()
                .permitsFullRunnerMemory ? .full : .constrained
            _ = try backend.setMemoryAllocation(
                memoryAllocation,
                timeout: Self.memoryConfigurationTimeout,
                on: id
            )
            try checkCancellation()
            lifecycle = .runnerRegistrationMayExist
            _ = try backend.exec(
                ["yieldd-configure-runner", repository.fullName, id.value],
                standardInput: Data("\(registrationToken)\n".utf8),
                timeout: Self.configurationTimeout,
                on: id
            )
            try checkCancellation()
            stateChanged(.waitingForJob(id))
            lifecycle = .runnerMayBeRunning
            _ = try backend.exec(
                ["yieldd-runner-control", "run"],
                timeout: jobTimeout,
                outputCapture: .tail(maxBytes: Self.jobOutputTailBytes),
                as: .root,
                on: id
            )
            lifecycle = .runnerStopped
        }

        stateChanged(.cleaningUp(id))
        let cleanupFailures = cleanup(
            lifecycle: lifecycle,
            id: id,
            repository: repository
        )

        switch operation {
        case .success where cleanupFailures.isEmpty:
            return
        case .success:
            throw RunnerSessionError.cleanupFailed(cleanupFailures)
        case let .failure(error) where cleanupFailures.isEmpty:
            throw error
        case let .failure(error):
            throw RunnerSessionError.operationAndCleanupFailed(
                operation: error,
                cleanup: cleanupFailures
            )
        }
    }

    private func cleanup(
        lifecycle: RunnerLifecycle,
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
        case .runnerRegistrationMayExist, .runnerStopped:
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
}

private enum RunnerLifecycle {
    case machineMayExist
    case runnerRegistrationMayExist
    case runnerMayBeRunning
    case runnerStopped
}

enum RunnerSessionState: Equatable {
    case preparing(RunnerID)
    case waitingForJob(RunnerID)
    case cleaningUp(RunnerID)
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
    case operationAndCleanupFailed(operation: any Error, cleanup: [RunnerSessionCleanupFailure])
}

extension RunnerSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .cleanupFailed(cleanup):
            "Runner job completed, but cleanup failed: \(describe(cleanup))"
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
