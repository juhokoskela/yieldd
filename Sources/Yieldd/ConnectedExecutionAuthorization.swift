import Foundation

enum ExecutionRenewal { case active, jobSucceeded, revoked }

// Owned by one connected slot. Backend operations check this on that slot's worker.
final class ConnectedExecutionAuthorization {
    static let offlineGrace: TimeInterval = 5 * 60
    private let renew: (ConnectedOffer, () throws -> Void) throws -> ExecutionRenewal
    private let checkCancellation: () throws -> Void
    private let currentTime: () -> TimeInterval
    private var offer: ConnectedOffer?
    private var deadline: TimeInterval = 0
    private var pendingNativeSave: () -> Bool = { false }
    private var jobSucceeded = false
    private var nextRenewal: TimeInterval = 0
    private(set) var failure: ConnectedExecutionError?

    init(renew: @escaping (ConnectedOffer, () throws -> Void) throws -> ExecutionRenewal,
         checkCancellation: @escaping () throws -> Void,
         currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.renew = renew
        self.checkCancellation = checkCancellation
        self.currentTime = currentTime
    }

    func start(_ offer: ConnectedOffer, pendingNativeSave: @escaping () -> Bool = { false }) {
        self.pendingNativeSave = pendingNativeSave
        jobSucceeded = false
        self.offer = offer
        failure = nil
        nextRenewal = currentTime()
        deadline = nextRenewal + Self.offlineGrace
    }

    // A ready-to-save disk still needs the final job result after all post steps.
    // Waiting for it must not renew execution or consume the disk unmount timeout.
    func confirmNativeSave(wait: (TimeInterval) throws -> Void) throws -> Bool {
        guard let offer, pendingNativeSave() else { return false }
        nextRenewal = .infinity
        let until = currentTime() + 30
        func checkResultDeadline() throws {
            try checkDeadline()
            if currentTime() >= until { throw CompletionWaitExpired() }
        }
        while !jobSucceeded {
            do {
                try checkResultDeadline()
                let result = try renew(offer, checkResultDeadline)
                try checkResultDeadline()
                switch result {
                case .jobSucceeded: jobSucceeded = true
                case .revoked: return false
                case .active: break
                }
            } catch is CompletionWaitExpired {
                return false
            } catch where isTransientConnectedFailure(error) {
                // The listener can exit before its completion event reaches the coordinator.
            }
            if !jobSucceeded { try wait(1) }
        }
        try checkDeadline()
        return true
    }

    private struct CompletionWaitExpired: Error {}

    func stop() { offer = nil; failure = nil; pendingNativeSave = { false } }

    func check() throws {
        try checkDeadline()
        guard let offer, currentTime() >= nextRenewal else { return }
        let requestedAt = currentTime()
        do {
            switch try renew(offer, checkDeadline) {
            case .jobSucceeded where pendingNativeSave():
                try checkDeadline()
                jobSucceeded = true
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
        if currentTime() >= deadline { failure = .expired }
        if let failure { throw failure }
    }
}

enum ConnectedExecutionError: Error, Equatable, LocalizedError {
    case expired, revoked

    var errorDescription: String? {
        switch self {
        case .expired: "No execution authorization was renewed for five minutes."
        case .revoked: "The coordinator ended execution authorization."
        }
    }
}
