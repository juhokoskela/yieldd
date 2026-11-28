import Foundation

final class ConnectedSlotReservation {
    var reservation: RunnerMemoryReservation?

    func release(using release: (RunnerMemoryReservation) -> Void) {
        guard let held = reservation else { return }
        reservation = nil
        release(held)
    }
}

func runConnectedClient(
    checkCancellation: () throws -> Void,
    recover: () throws -> Void,
    acquire: () throws -> RunnerMemoryReservation?,
    release: @escaping (RunnerMemoryReservation) -> Void,
    prepareToPoll: () throws -> Void = {},
    poll: () throws -> ConnectedOffer?,
    decline: (ConnectedOffer) throws -> Void,
    run: (ConnectedOffer, RunnerMemoryAllocation, () -> Void) throws -> Void,
    wait: (TimeInterval) throws -> Void,
    retrying: (any Error) -> Void,
    available: () -> Bool = { true },
    blocked: () -> Void = {},
    paused: () -> Bool = { false },
    beginAssignment: () -> Bool = { true },
    beginOfferAssignment: ((ConnectedOffer) -> Bool)? = nil,
    finishAssignment: () -> Void = {},
    slotReservation: ConnectedSlotReservation = ConnectedSlotReservation()
) throws {
    func releaseCapacity() {
        slotReservation.release(using: release)
    }
    func recoverWithRetry() throws {
        while true {
            try checkCancellation()
            do {
                try recover()
                releaseCapacity()
                finishAssignment()
                return
            } catch where isTransientConnectedFailure(error) {
                retrying(error)
                try wait(5)
            }
        }
    }
    try recoverWithRetry()
    var reportedBlocked = false
    while true {
        try checkCancellation()
        do {
            if paused() { try wait(1); continue }
            guard available() else {
                if !reportedBlocked { blocked(); reportedBlocked = true }
                try wait(1)
                continue
            }
            reportedBlocked = false
            do {
                try prepareToPoll()
            } catch where !isCancellation(error) {
                retrying(error)
                try wait(5)
                continue
            }
            guard let offer = try poll() else { try wait(1); continue }
            // Polling advertises a snapshot, not a reservation. Another slot can win
            // capacity before an offer arrives; decline without accepting credentials.
            guard let reservation = try acquire() else {
                try decline(offer)
                try wait(1)
                continue
            }
            slotReservation.reservation = reservation
            guard beginOfferAssignment?(offer) ?? beginAssignment() else {
                releaseCapacity()
                try decline(offer)
                try wait(1)
                continue
            }
            try run(offer, reservation.allocation, releaseCapacity)
            finishAssignment()
        } catch {
            if case let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) = error,
               !isCancellation(operation), cleanup.allSatisfy({ isTransientConnectedFailure($0.error) }) {
                try recoverWithRetry()
                if !isTransientConnectedFailure(operation), !isContainedConnectedFailure(operation) { throw operation }
                continue
            }
            guard isTransientConnectedFailure(error) else { throw error }
            retrying(error)
            try wait(5)
            // Never retry acceptance or execution. Reconcile the recorded assignment first.
            try recoverWithRetry()
        }
    }
}

func isTransientConnectedFailure(_ error: any Error) -> Bool {
    if let error = error as? ConnectedRunnerError {
        switch error {
        case .transport, .http(429, _, _), .http(500, _, _), .http(502, _, _), .http(503, _, _), .http(504, _, _): return true
        case .http(409, _, "one poll per worker slot"): return true
        default: return false
        }
    }
    if case let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) = error {
        return isTransientConnectedFailure(operation) && cleanup.allSatisfy { isTransientConnectedFailure($0.error) }
    }
    return false
}
