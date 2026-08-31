import Foundation

protocol RunnerSessionRunning {
    func run(id: RunnerID, repository: GitHubRepository) throws
}

struct EphemeralRunnerSession: RunnerSessionRunning {
    static let image = MachineTestRunner.image
    static let configurationTimeout: TimeInterval = 5 * 60

    let backend: any RunnerBackend
    let github: any GitHubRunnerManaging
    private let jobTimeout: TimeInterval?
    private let dockerReadiness: DockerReadiness
    private let checkCancellation: () throws -> Void
    private let stateChanged: (RunnerSessionState) -> Void

    init(
        backend: any RunnerBackend,
        github: any GitHubRunnerManaging,
        jobTimeout: TimeInterval? = nil,
        dockerInfoAttempts: Int = 30,
        retryDelay: TimeInterval = 1,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        checkCancellation: @escaping () throws -> Void = {},
        stateChanged: @escaping (RunnerSessionState) -> Void = { _ in }
    ) {
        if let jobTimeout {
            precondition(jobTimeout.isFinite && jobTimeout > 0)
        }
        self.backend = backend
        self.github = github
        self.jobTimeout = jobTimeout
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

        var runnerRegistrationMayExist = false
        let operation: Result<Void, any Error>
        do {
            try backend.create(id: id, image: Self.image)
            try checkCancellation()
            _ = try dockerReadiness.wait(on: id)
            try checkCancellation()
            runnerRegistrationMayExist = true
            _ = try backend.exec(
                ["yieldd-configure-runner", repository.fullName, id.value],
                standardInput: Data("\(registrationToken)\n".utf8),
                timeout: Self.configurationTimeout,
                on: id
            )
            try checkCancellation()
            stateChanged(.waitingForJob(id))
            _ = try backend.exec(
                ["/opt/actions-runner/run.sh"],
                standardInput: nil,
                timeout: jobTimeout,
                on: id
            )
            operation = .success(())
        } catch {
            operation = .failure(error)
        }

        stateChanged(.cleaningUp(id))
        var cleanupFailures: [RunnerSessionCleanupFailure] = []
        if runnerRegistrationMayExist {
            do {
                try github.removeRunners(named: id.value, from: repository)
            } catch {
                cleanupFailures.append(RunnerSessionCleanupFailure(step: .githubRunner, error: error))
            }
        }

        do {
            try backend.destroy(id)
        } catch {
            cleanupFailures.append(RunnerSessionCleanupFailure(step: .machine, error: error))
        }

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
            "Runner session failed: \(describe(operation)). Cleanup also failed: \(describe(cleanup))"
        }
    }

    private func describe(_ failures: [RunnerSessionCleanupFailure]) -> String {
        failures.map { failure in
            "\(failure.step.rawValue): \(describe(failure.error))"
        }.joined(separator: "; ")
    }

    private func describe(_ error: any Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
