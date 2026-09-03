import Foundation

struct RunnerService {
    private let session: any RunnerSessionRunning
    private let makeRunnerID: () -> RunnerID
    private let checkForStop: () throws -> Void
    private let waitUntilStopped: (TimeInterval) throws -> Void
    private let stateChanged: (RunnerServiceState) -> Void
    private let sessionFailed: (any Error) -> Void
    private let initialBackoff: TimeInterval
    private let maximumBackoff: TimeInterval

    init(
        session: any RunnerSessionRunning,
        makeRunnerID: @escaping () -> RunnerID,
        checkForStop: @escaping () throws -> Void,
        waitUntilStopped: @escaping (TimeInterval) throws -> Void,
        initialBackoff: TimeInterval = 1,
        maximumBackoff: TimeInterval = 30,
        stateChanged: @escaping (RunnerServiceState) -> Void = { _ in },
        sessionFailed: @escaping (any Error) -> Void = { _ in }
    ) {
        precondition(initialBackoff.isFinite && initialBackoff > 0)
        precondition(maximumBackoff.isFinite && maximumBackoff >= initialBackoff)
        self.session = session
        self.makeRunnerID = makeRunnerID
        self.checkForStop = checkForStop
        self.waitUntilStopped = waitUntilStopped
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        self.stateChanged = stateChanged
        self.sessionFailed = sessionFailed
    }

    func run(repository: GitHubRepository) throws {
        var consecutiveFailures = 0
        var backoff = initialBackoff

        while true {
            if try stopRequested(by: checkForStop) {
                return
            }

            do {
                try session.run(id: makeRunnerID(), repository: repository)
                consecutiveFailures = 0
                backoff = initialBackoff
            } catch {
                if let id = (error as? RunnerSessionError)?.deferredRunnerIDAfterInterruption {
                    stateChanged(.cleanupDeferred(id))
                    return
                }

                sessionFailed(error)
                if error.hasRunnerSessionCleanupFailure {
                    throw error
                }

                if try stopRequested(by: checkForStop) {
                    return
                }

                consecutiveFailures += 1
                stateChanged(.backingOff(failures: consecutiveFailures, delay: backoff))
                if try stopRequested(by: { try waitUntilStopped(backoff) }) {
                    return
                }
                backoff = min(backoff * 2, maximumBackoff)
            }
        }
    }

    private func stopRequested(by operation: () throws -> Void) throws -> Bool {
        do {
            try operation()
            return false
        } catch {
            guard isCancellation(error) else {
                throw error
            }
            return true
        }
    }
}

private extension RunnerSessionError {
    var deferredRunnerIDAfterInterruption: RunnerID? {
        guard case let .cleanupDeferred(id, operation?) = self else {
            return nil
        }
        return isCancellation(operation) ? id : nil
    }
}

private extension Error {
    var hasRunnerSessionCleanupFailure: Bool {
        guard let error = self as? RunnerSessionError else {
            return false
        }
        return switch error {
        case .cleanupFailed, .cleanupDeferred, .operationAndCleanupFailed:
            true
        }
    }
}

enum RunnerServiceState: Equatable {
    case backingOff(failures: Int, delay: TimeInterval)
    case cleanupDeferred(RunnerID)
}
