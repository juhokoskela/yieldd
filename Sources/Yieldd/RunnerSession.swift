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

        var runnerRegistrationMayExist = false
        var runnerMayBeRunning = false
        let operation: Result<Void, any Error>
        do {
            try backend.create(id: id, image: Self.image)
            try checkCancellation()
            _ = try dockerReadiness.wait(on: id)
            try checkCancellation()
            let memoryAllocation: RunnerMemoryAllocation = readMemoryPressure()
                .permitsFullRunnerMemory ? .full : .constrained
            _ = try backend.setMemoryAllocation(memoryAllocation, on: id)
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
            runnerMayBeRunning = true
            _ = try backend.exec(
                ["yieldd-runner-control", "run"],
                standardInput: nil,
                timeout: jobTimeout,
                as: .root,
                on: id
            )
            operation = .success(())
        } catch {
            operation = .failure(error)
        }

        stateChanged(.cleaningUp(id))
        var cleanupFailures: [RunnerSessionCleanupFailure] = []
        var runnerStopped = !runnerMayBeRunning
        var runnerStopFailure: RunnerSessionCleanupFailure?
        if runnerMayBeRunning {
            do {
                try backend.stopRunner(on: id)
                runnerStopped = true
            } catch {
                runnerStopFailure = RunnerSessionCleanupFailure(step: .runnerProcess, error: error)
            }
        }

        func removeGitHubRunner() {
            guard runnerRegistrationMayExist else {
                return
            }
            do {
                try github.removeRunners(named: id.value, from: repository)
            } catch {
                cleanupFailures.append(RunnerSessionCleanupFailure(step: .githubRunner, error: error))
            }
        }

        if runnerStopped {
            removeGitHubRunner()
        }

        var machineDestroyed = false
        var machineFailure: RunnerSessionCleanupFailure?
        do {
            try backend.destroy(id)
            machineDestroyed = true
        } catch {
            machineFailure = RunnerSessionCleanupFailure(step: .machine, error: error)
        }

        if !runnerStopped, machineDestroyed {
            removeGitHubRunner()
        } else if !runnerStopped, let runnerStopFailure {
            cleanupFailures.append(runnerStopFailure)
        }
        if let machineFailure {
            cleanupFailures.append(machineFailure)
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
