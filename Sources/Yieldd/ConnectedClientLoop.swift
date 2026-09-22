import Foundation

func runConnectedClient(
    checkCancellation: () throws -> Void,
    recover: () throws -> Void,
    acquire: () throws -> RunnerMemoryReservation?,
    release: @escaping (RunnerMemoryReservation) -> Void,
    poll: () throws -> ConnectedOffer?,
    decline: (ConnectedOffer) throws -> Void,
    run: (ConnectedOffer, RunnerMemoryAllocation, () -> Void) throws -> Void,
    wait: (TimeInterval) throws -> Void,
    retrying: () -> Void,
    available: () -> Bool = { true },
    blocked: () -> Void = {}
) throws {
    var heldReservation: RunnerMemoryReservation?
    func releaseCapacity() {
        guard let reservation = heldReservation else { return }
        heldReservation = nil
        release(reservation)
    }
    func recoverWithRetry() throws {
        while true {
            try checkCancellation()
            do {
                try recover()
                releaseCapacity()
                return
            } catch where isTransientConnectedFailure(error) {
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
            // capacity before an offer arrives; decline without accepting credentials.
            guard let reservation = try acquire() else {
                try decline(offer)
                try wait(1)
                continue
            }
            heldReservation = reservation
            try run(offer, reservation.allocation, releaseCapacity)
        } catch {
            if case let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) = error,
               !isCancellation(operation), cleanup.allSatisfy({ isTransientConnectedFailure($0.error) }) {
                try recoverWithRetry()
                if !isTransientConnectedFailure(operation), !(operation is ConnectedExecutionError) { throw operation }
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
