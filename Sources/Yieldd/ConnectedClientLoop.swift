import Foundation

func runConnectedClient(
    checkCancellation: () throws -> Void,
    recover: () throws -> Void,
    acquire: () throws -> RunnerMemoryReservation?,
    release: @escaping (RunnerMemoryReservation) -> Void,
    poll: () throws -> ConnectedOffer?,
    run: (ConnectedOffer, RunnerMemoryAllocation, () -> Void) throws -> Void,
    wait: (TimeInterval) throws -> Void,
    retrying: () -> Void,
    available: () -> Bool = { true },
    blocked: () -> Void = {}
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
    var reportedBlocked = false
    while true {
        try checkCancellation()
        do {
            guard available() else {
                if !reportedBlocked { blocked(); reportedBlocked = true }
                try wait(1)
                continue
            }
            reportedBlocked = false
            guard let offer = try poll() else { try wait(1); continue }
            // Polling advertises a snapshot, not a reservation. Another slot can win
            // capacity before an offer arrives; leave that offer unaccepted.
            guard let reservation = try acquire() else { try wait(1); continue }
            var released = false
            func releaseOnce() {
                guard !released else { return }
                released = true
                release(reservation)
            }
            defer { releaseOnce() }
            try run(offer, reservation.allocation, releaseOnce)
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
