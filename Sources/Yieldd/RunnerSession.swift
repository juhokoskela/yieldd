import Foundation

enum RunnerSessionState: Equatable {
    case listenerStarted(RunnerID)
    case jobStarted(RunnerID)
    case listenerExited(RunnerID, status: Int32)
    case executionStopped(RunnerID, reason: String)
    case capacityReleased(RunnerID)
    case cleanupCompleted(RunnerID)
}

struct RunnerSessionCleanupFailure {
    let step: RunnerSessionCleanupStep
    let error: any Error
}

enum RunnerSessionCleanupStep: String, Equatable {
    case githubRunner = "GitHub runner"
    case machine
    case network = "network relay"
    case runnerProcess = "runner process"
    case leaseRecord = "lease record"
}

enum RunnerSessionError: Error {
    case cleanupFailed([RunnerSessionCleanupFailure])
    case operationAndCleanupFailed(operation: any Error, cleanup: [RunnerSessionCleanupFailure])
}

extension RunnerSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .cleanupFailed(cleanup):
            "Runner cleanup failed: \(describe(cleanup))"
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
