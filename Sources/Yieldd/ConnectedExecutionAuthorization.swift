import Foundation

// Owned by one connected slot. Backend operations check this on that slot's worker.
final class ConnectedExecutionAuthorization {
    static let offlineGrace: TimeInterval = 5 * 60
    private let renew: (ConnectedOffer, () throws -> Void) throws -> Bool
    private let checkCancellation: () throws -> Void
    private let currentTime: () -> TimeInterval
    private var offer: ConnectedOffer?
    private var deadline: TimeInterval = 0
    private var nextRenewal: TimeInterval = 0
    private(set) var failure: ConnectedExecutionError?

    init(renew: @escaping (ConnectedOffer, () throws -> Void) throws -> Bool,
         checkCancellation: @escaping () throws -> Void,
         currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.renew = renew
        self.checkCancellation = checkCancellation
        self.currentTime = currentTime
    }

    func start(_ offer: ConnectedOffer) {
        self.offer = offer
        failure = nil
        nextRenewal = currentTime()
        deadline = nextRenewal + Self.offlineGrace
    }

    func stop() { offer = nil; failure = nil }

    func check() throws {
        try checkDeadline()
        guard let offer, currentTime() >= nextRenewal else { return }
        let requestedAt = currentTime()
        do {
            guard try renew(offer, checkDeadline) else {
                failure = .revoked
                throw ConnectedExecutionError.revoked
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
