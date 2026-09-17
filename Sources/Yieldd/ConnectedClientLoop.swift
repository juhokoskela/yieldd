import Foundation

func runConnectedClient(
    checkCancellation: () throws -> Void,
    recover: () throws -> Void,
    acquire: () throws -> RunnerMemoryReservation,
    release: @escaping (RunnerMemoryReservation) -> Void,
    poll: () throws -> ConnectedOffer?,
    run: (ConnectedOffer, RunnerMemoryAllocation, () -> Void) throws -> Void,
    wait: (TimeInterval) throws -> Void,
    retrying: () -> Void
) throws {
    func recoverWithRetry() throws {
        while true {
            try checkCancellation()
            do { try recover(); return } catch where isTransientConnectedFailure(error) {
                retrying()
                try wait(5)
            }
        }
    }
    try recoverWithRetry()
    while true {
        try checkCancellation()
        do {
            let reservation = try acquire()
            var released = false
            func releaseOnce() {
                guard !released else { return }
                released = true
                release(reservation)
            }
            defer { releaseOnce() }
            if let offer = try poll() {
                try run(offer, reservation.allocation, releaseOnce)
            } else {
                releaseOnce()
                try wait(1)
            }
        } catch {
            if case let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) = error,
               !isCancellation(operation), cleanup.allSatisfy({ isTransientConnectedFailure($0.error) }) {
                try recoverWithRetry()
                if !isTransientConnectedFailure(operation) { throw operation }
                continue
            }
            guard isTransientConnectedFailure(error) else { throw error }
            retrying()
            try wait(5)
            // Never retry acceptance or execution. Reconcile the recorded assignment first.
            try recoverWithRetry()
        }
    }
}

func isTransientConnectedFailure(_ error: any Error) -> Bool {
    if let error = error as? ConnectedRunnerError {
        switch error {
        case .transport, .http(429), .http(500), .http(502), .http(503), .http(504): return true
        default: return false
        }
    }
    if case let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) = error {
        return isTransientConnectedFailure(operation) && cleanup.allSatisfy { isTransientConnectedFailure($0.error) }
    }
    return false
}
