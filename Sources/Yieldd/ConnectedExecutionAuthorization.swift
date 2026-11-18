import Foundation

enum FinalJobResult: String, Decodable { case pending, succeeded, unavailable }

enum ExecutionRenewal { case active, jobSucceeded, revoked }

// Owned by one connected slot. Backend operations check this on that slot's worker.
final class ConnectedExecutionAuthorization {
    static let offlineGrace: TimeInterval = 5 * 60
    private static let completionWait: TimeInterval = 30
    private let renew: (ConnectedOffer, () throws -> Void) throws -> ExecutionRenewal
    private let jobResult: (ConnectedOffer, () throws -> Void) throws -> FinalJobResult
    private let checkCancellation: () throws -> Void
    private let currentTime: () -> TimeInterval
    private enum GuestPhase { case executing, detaching, finished }
    private var guestPhase = GuestPhase.finished
    private var offer: ConnectedOffer?
    private var deadline: TimeInterval = 0
    private var listenerExitDeadline = TimeInterval.infinity
    private var pendingNativeSave: () -> Bool = { false }
    private var jobSucceeded = false
    private var nextRenewal: TimeInterval = 0
    private(set) var failure: ConnectedExecutionError?

    init(renew: @escaping (ConnectedOffer, () throws -> Void) throws -> ExecutionRenewal,
         jobResult: @escaping (ConnectedOffer, () throws -> Void) throws -> FinalJobResult,
         checkCancellation: @escaping () throws -> Void,
         currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.renew = renew
        self.jobResult = jobResult
        self.checkCancellation = checkCancellation
        self.currentTime = currentTime
    }

    func start(_ offer: ConnectedOffer, pendingNativeSave: @escaping () -> Bool = { false }) {
        guestPhase = .executing
        self.pendingNativeSave = pendingNativeSave
        jobSucceeded = false
        listenerExitDeadline = .infinity
        self.offer = offer
        failure = nil
        nextRenewal = currentTime()
        deadline = nextRenewal + Self.offlineGrace
    }

    func beginNativeCacheDetach() throws {
        // A late listener exit cannot reopen an expired or revoked assignment.
        try checkDeadline()
        guestPhase = .detaching
        listenerExitDeadline = .infinity
        try check()
    }

    // Destruction must proceed even when permission to execute guest commands has ended.
    func endGuestExecution() { guestPhase = .finished }

    func confirmNativeSave(wait: (TimeInterval) throws -> Void) throws -> Bool {
        guard let offer, guestPhase == .finished else { return false }
        let until = currentTime() + Self.completionWait
        var retryDelay: TimeInterval = 2
        func checkResultDeadline() throws {
            try checkDeadline()
            if currentTime() >= until { throw CancellationError() }
        }
        while !jobSucceeded {
            do {
                try checkResultDeadline()
                let result = try jobResult(offer, checkResultDeadline)
                try checkResultDeadline()
                switch result {
                case .succeeded: jobSucceeded = true
                case .unavailable: return false
                case .pending: break
                }
            } catch is CancellationError {
                try checkDeadline()
                guard currentTime() >= until else { throw CancellationError() }
                return false
            } catch where isTransientConnectedFailure(error) {
                // The listener can exit before its completion event reaches the coordinator.
            } catch where !isCancellation(error) {
                // A failed result lookup rules out publishing this disk. Shutdown still wins.
                try checkDeadline()
                return false
            }
            if !jobSucceeded {
                let remaining = until - currentTime()
                guard remaining > 0 else { return false }
                try wait(min(retryDelay, remaining))
                retryDelay = min(retryDelay * 2, 8)
            }
        }
        try checkDeadline()
        return true
    }

    func stop() { endGuestExecution(); offer = nil; failure = nil; pendingNativeSave = { false } }

    func check() throws {
        guard guestPhase != .finished else { try checkCancellation(); return }
        try checkDeadline()
        guard let offer, currentTime() >= nextRenewal else { return }
        let requestedAt = currentTime()
        do {
            switch try renew(offer, checkDeadline) {
            case .jobSucceeded where guestPhase == .detaching || pendingNativeSave():
                try checkDeadline()
                jobSucceeded = true
                if guestPhase == .executing { listenerExitDeadline = currentTime() + Self.completionWait }
                nextRenewal = .infinity
                return
            case .revoked, .jobSucceeded:
                failure = .revoked
                throw ConnectedExecutionError.revoked
            case .active: break
            }
            try checkDeadline()
            // A delayed response must not extend the grace by its network latency.
            deadline = requestedAt + Self.offlineGrace
            nextRenewal = requestedAt + 30
        } catch where isTransientConnectedFailure(error) {
            nextRenewal = currentTime() + 5
            try checkDeadline()
        }
    }

    private func checkDeadline() throws {
        try checkCancellation()
        guard offer != nil else { return }
        let now = currentTime()
        if now >= deadline { failure = .expired }
        else if now >= listenerExitDeadline { failure = .listenerExitTimedOut }
        if let failure { throw failure }
    }
}

enum ConnectedExecutionError: Error, Equatable, LocalizedError {
    case expired, revoked, listenerExitTimedOut

    var errorDescription: String? {
        switch self {
        case .expired: "No execution authorization was renewed for five minutes."
        case .revoked: "The coordinator ended execution authorization."
        case .listenerExitTimedOut: "The guest listener did not exit within 30 seconds of GitHub reporting job success."
        }
    }
}
