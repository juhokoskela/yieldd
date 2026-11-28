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
// Thread-safe for cross-thread reclaim / sleep revocation signals and serialized renewals.
final class ConnectedExecutionAuthorization: @unchecked Sendable {
    static let preStartOfflineGrace: TimeInterval = 60
    static let offlineGrace: TimeInterval = 5 * 60
    private let lock = NSLock()
    private let renewalLock = NSLock()
    private let renew: (ConnectedOffer, () throws -> Void) throws -> ConnectedAuthorizationRenewal
    private let checkCancellation: () throws -> Void
    private let currentTime: () -> TimeInterval
    private let initialOfflineGrace: TimeInterval
    private let onWorkflowRunID: (Int64) -> Void
    private var generation: UInt64 = 0
    private var admittedRunner: String?
    private var offer: ConnectedOffer?
    private var jobStarted = false
    private var lastAuthorizedAt: TimeInterval = 0
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

    /// Registers an admitted runner UUID before `/accept` runs so reclaim, abort, or sleep
    /// arriving during credential acceptance latches cleanly and blocks guest creation.
    func prepare(runner: String) {
        lock.withLock {
            if admittedRunner == runner && offer == nil { return }
            generation &+= 1
            admittedRunner = runner
            offer = nil
            jobStarted = false
            storedFailure = nil
        }
    }

    func start(_ offer: ConnectedOffer) {
        let now = currentTime()
        lock.withLock {
            let preserveLatchedFailure = admittedRunner == offer.runner
            if !preserveLatchedFailure {
                generation &+= 1
                storedFailure = nil
            }
            admittedRunner = offer.runner
            self.offer = offer
            jobStarted = false
            lastAuthorizedAt = now
            nextRenewal = now
            deadline = now + initialOfflineGrace
        }
    }

    func markJobStarted() {
        lock.withLock {
            guard offer != nil, !jobStarted else { return }
            jobStarted = true
            // Anchor the widened post-start grace strictly to the last successful
            // coordinator grant so guest-reported state can never extend past 5 minutes.
            deadline = max(deadline, lastAuthorizedAt + Self.offlineGrace)
        }
    }

    func stop() {
        lock.withLock {
            generation &+= 1
            admittedRunner = nil
            offer = nil
            jobStarted = false
            storedFailure = nil
        }
    }

    /// Aborts the currently admitted or running assignment on this slot. If `expectedRunner`
    /// is supplied, returns `false` if the slot is idle or has moved on to another runner UUID.
    @discardableResult
    func abort(reason: ConnectedExecutionError, expectedRunner: String? = nil) -> Bool {
        lock.withLock {
            guard let currentRunner = offer?.runner ?? admittedRunner else { return false }
            if let expectedRunner, currentRunner != expectedRunner { return false }
            if storedFailure == nil { storedFailure = reason }
            return true
        }
    }

    func check() throws {
        try checkDeadline()
        let pending: (offer: ConnectedOffer, generation: UInt64)? = lock.withLock {
            guard let offer, currentTime() >= nextRenewal else { return nil }
            return (offer, generation)
        }
        guard let pending else { return }
        try renewalLock.withLock {
            try checkDeadline()
            let stillPending = lock.withLock {
                self.generation == pending.generation && self.offer == pending.offer && currentTime() >= nextRenewal
            }
            guard stillPending else { return }
            let requestedAt = currentTime()
            do {
                let renewal = try renew(pending.offer) { [self] in
                    try checkDeadline(for: pending.generation)
                }
                let runIDToReport: Int64? = try lock.withLock { () -> Int64? in
                    guard self.generation == pending.generation, self.offer == pending.offer else {
                        return nil
                    }
                    guard renewal.shouldContinue else {
                        if storedFailure == nil { storedFailure = .revoked }
                        throw storedFailure ?? ConnectedExecutionError.revoked
                    }
                    if currentTime() >= deadline {
                        if storedFailure == nil { storedFailure = .expired }
                    }
                    if let currentFailure = storedFailure { throw currentFailure }
                    // A delayed response must not extend the grace by its network latency.
                    lastAuthorizedAt = requestedAt
                    let grace = jobStarted ? Self.offlineGrace : initialOfflineGrace
                    deadline = requestedAt + grace
                    nextRenewal = requestedAt + 30
                    if let runID = renewal.workflowRunID, runID > 0 { return runID }
                    return nil
                }
                if let runIDToReport {
                    onWorkflowRunID(runIDToReport)
                }
            } catch where isTransientConnectedFailure(error) {
                lock.withLock {
                    guard self.generation == pending.generation, self.offer == pending.offer else { return }
                    nextRenewal = currentTime() + 5
                }
                try checkDeadline(for: pending.generation)
            }
        }
    }

    private func checkDeadline(for expectedGeneration: UInt64? = nil) throws {
        try checkCancellation()
        let currentFailure: ConnectedExecutionError? = lock.withLock {
            if let expectedGeneration, self.generation != expectedGeneration {
                return nil
            }
            guard offer != nil || admittedRunner != nil else { return nil }
            if offer != nil, storedFailure == nil, currentTime() >= deadline {
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
