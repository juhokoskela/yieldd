import Foundation

struct ConnectedAuthorizationRenewal: Equatable, Sendable {
    let shouldContinue: Bool
    let workflowRunID: Int64?

    init(shouldContinue: Bool, workflowRunID: Int64? = nil) {
        self.shouldContinue = shouldContinue
        self.workflowRunID = workflowRunID
    }
}

// Owned by one connected slot. Backend operations check this on that slot's worker.
// Thread-safe for cross-thread reclaim / sleep revocation signals.
final class ConnectedExecutionAuthorization: @unchecked Sendable {
    static let preStartOfflineGrace: TimeInterval = 60
    static let offlineGrace: TimeInterval = 5 * 60
    private let lock = NSLock()
    private let renew: (ConnectedOffer, () throws -> Void) throws -> ConnectedAuthorizationRenewal
    private let checkCancellation: () throws -> Void
    private let currentTime: () -> TimeInterval
    private let initialOfflineGrace: TimeInterval
    private let onWorkflowRunID: (Int64) -> Void
    private var offer: ConnectedOffer?
    private var jobStarted = false
    private var deadline: TimeInterval = 0
    private var nextRenewal: TimeInterval = 0
    private var storedFailure: ConnectedExecutionError?

    var failure: ConnectedExecutionError? {
        lock.withLock { storedFailure }
    }

    convenience init(renew: @escaping (ConnectedOffer, () throws -> Void) throws -> Bool,
                     checkCancellation: @escaping () throws -> Void,
                     currentTime: @escaping () -> TimeInterval = continuousMonotonicSeconds,
                     initialOfflineGrace: TimeInterval = ConnectedExecutionAuthorization.offlineGrace,
                     onWorkflowRunID: @escaping (Int64) -> Void = { _ in }) {
        self.init(
            renewWithMetadata: { offer, check in
                ConnectedAuthorizationRenewal(shouldContinue: try renew(offer, check))
            },
            checkCancellation: checkCancellation,
            currentTime: currentTime,
            initialOfflineGrace: initialOfflineGrace,
            onWorkflowRunID: onWorkflowRunID
        )
    }

    init(renewWithMetadata renew: @escaping (ConnectedOffer, () throws -> Void) throws -> ConnectedAuthorizationRenewal,
         checkCancellation: @escaping () throws -> Void,
         currentTime: @escaping () -> TimeInterval = continuousMonotonicSeconds,
         initialOfflineGrace: TimeInterval = ConnectedExecutionAuthorization.offlineGrace,
         onWorkflowRunID: @escaping (Int64) -> Void = { _ in }) {
        self.renew = renew
        self.checkCancellation = checkCancellation
        self.currentTime = currentTime
        self.initialOfflineGrace = initialOfflineGrace
        self.onWorkflowRunID = onWorkflowRunID
    }

    func start(_ offer: ConnectedOffer) {
        let now = currentTime()
        lock.withLock {
            self.offer = offer
            jobStarted = false
            storedFailure = nil
            nextRenewal = now
            deadline = now + initialOfflineGrace
        }
    }

    func markJobStarted() {
        let now = currentTime()
        lock.withLock {
            guard offer != nil, !jobStarted else { return }
            jobStarted = true
            // Once a job has started, widen offline grace to the full 5 minutes.
            deadline = max(deadline, now + Self.offlineGrace)
        }
    }

    func stop() {
        lock.withLock {
            offer = nil
            jobStarted = false
            storedFailure = nil
        }
    }

    /// Aborts the currently running assignment on this slot. If `expectedRunner` is supplied,
    /// returns `false` if the slot is idle or has moved on to a different runner UUID.
    @discardableResult
    func abort(reason: ConnectedExecutionError, expectedRunner: String? = nil) -> Bool {
        lock.withLock {
            guard let offer else { return false }
            if let expectedRunner, offer.runner != expectedRunner { return false }
            if storedFailure == nil { storedFailure = reason }
            return true
        }
    }

    func check() throws {
        try checkDeadline()
        let activeOffer: ConnectedOffer? = lock.withLock {
            guard let offer, currentTime() >= nextRenewal else { return nil }
            return offer
        }
        guard let offer = activeOffer else { return }
        let requestedAt = currentTime()
        do {
            let renewal = try renew(offer, checkDeadline)
            if let runID = renewal.workflowRunID, runID > 0 {
                onWorkflowRunID(runID)
            }
            guard renewal.shouldContinue else {
                lock.withLock { if storedFailure == nil { storedFailure = .revoked } }
                throw lock.withLock { storedFailure } ?? ConnectedExecutionError.revoked
            }
            try checkDeadline()
            lock.withLock {
                // A delayed response must not extend the grace by its network latency.
                let grace = jobStarted ? Self.offlineGrace : initialOfflineGrace
                deadline = requestedAt + grace
                nextRenewal = requestedAt + 30
            }
        } catch where isTransientConnectedFailure(error) {
            lock.withLock { nextRenewal = currentTime() + 5 }
            try checkDeadline()
        }
    }

    private func checkDeadline() throws {
        try checkCancellation()
        let currentFailure: ConnectedExecutionError? = lock.withLock {
            guard offer != nil else { return nil }
            if storedFailure == nil, currentTime() >= deadline {
                storedFailure = .expired
            }
            return storedFailure
        }
        if let currentFailure { throw currentFailure }
    }
}

enum ConnectedExecutionError: Error, Equatable, LocalizedError {
    case expired, revoked, reclaimed, sleepInterrupted

    var errorDescription: String? {
        switch self {
        case .expired: "No execution authorization was renewed before the offline grace expired."
        case .revoked: "The coordinator ended execution authorization."
        case .reclaimed: "Stopped locally because the Mac owner reclaimed compute."
        case .sleepInterrupted: "Stopped locally because the Mac entered system sleep."
        }
    }
}
