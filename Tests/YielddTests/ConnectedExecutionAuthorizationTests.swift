import Foundation
import Testing
@testable import Yieldd

private let authorizationOffer = try! ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
    runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")

@Test
func executionAuthorizationRenewsForLongJobsWithoutATotalDeadline() throws {
    var now: TimeInterval = 0
    var renewals = 0
    let authorization = ConnectedExecutionAuthorization(renew: { offer, check in
        #expect(offer == authorizationOffer)
        try check()
        renewals += 1
        return .active
    }, checkCancellation: {}, currentTime: { now })
    authorization.start(authorizationOffer)
    for _ in 0..<2_880 {
        try authorization.check()
        now += 30
    }
    #expect(renewals == 2_880)
    #expect(now == 24 * 60 * 60)
}

@Test(arguments: [ConnectedRunnerError.transport, .http(503, request: "POST /v1/renew (linux ARM64 slot 0)")])
func executionAuthorizationExpiresOfflineWithoutGuestInput(_ failure: ConnectedRunnerError) throws {
    var now: TimeInterval = 0
    let authorization = ConnectedExecutionAuthorization(renew: { _, _ in throw failure },
        checkCancellation: {}, currentTime: { now })
    authorization.start(authorizationOffer)
    for _ in 0..<60 { try authorization.check(); now += 5 }
    #expect(throws: ConnectedExecutionError.expired) { try authorization.check() }
    authorization.stop()
    try authorization.check()
}

@Test
func executionAuthorizationChecksDeadlineDuringRenewalAndDoesNotRevive() throws {
    var now: TimeInterval = 0
    var requests = 0
    let authorization = ConnectedExecutionAuthorization(renew: { _, check in
        requests += 1
        now = 300
        try check()
        Issue.record("Expired request must be cancelled")
        return .active
    }, checkCancellation: {}, currentTime: { now })
    authorization.start(authorizationOffer)
    #expect(throws: ConnectedExecutionError.expired) { try authorization.check() }
    #expect(throws: ConnectedExecutionError.expired) { try authorization.check() }
    #expect(requests == 1)
}

@Test
func executionAuthorizationAnchorsGraceBeforeNetworkDelay() throws {
    var now: TimeInterval = 0
    var requests = 0
    let authorization = ConnectedExecutionAuthorization(renew: { _, _ in
        requests += 1
        if requests == 1 { now = 250; return .active }
        throw ConnectedRunnerError.transport
    }, checkCancellation: {}, currentTime: { now })
    authorization.start(authorizationOffer)
    try authorization.check()
    now = 299
    try authorization.check()
    now = 300
    #expect(throws: ConnectedExecutionError.expired) { try authorization.check() }
}

@Test
func executionAuthorizationRevocationLatchesUntilCleanupAndNextAssignment() throws {
    var permitted = false
    let authorization = ConnectedExecutionAuthorization(renew: { _, _ in permitted ? .active : .revoked }, checkCancellation: {})
    authorization.start(authorizationOffer)
    #expect(throws: ConnectedExecutionError.revoked) { try authorization.check() }
    permitted = true
    #expect(throws: ConnectedExecutionError.revoked) { try authorization.check() }
    authorization.stop()
    try authorization.check()
    authorization.start(authorizationOffer)
    try authorization.check()
}

@Test
func executionAuthorizationPreservesCancellationAndPermanentErrors() {
    let cancelled = ConnectedExecutionAuthorization(renew: { _, _ in throw CancellationError() }, checkCancellation: {})
    cancelled.start(authorizationOffer)
    #expect(throws: CancellationError.self) { try cancelled.check() }
    #expect(cancelled.failure == nil)
    let error = ConnectedRunnerError.http(401, request: "POST /v1/renew (linux ARM64 slot 0)")
    let rejected = ConnectedExecutionAuthorization(renew: { _, _ in throw error }, checkCancellation: {})
    rejected.start(authorizationOffer)
    #expect(throws: error) { try rejected.check() }
    #expect(rejected.failure == nil)
}

@Test
func executionAuthorizationInterruptsAHostOwnedProcessWhileGuestCommandIsStuck() throws {
    var now: TimeInterval = 0
    let authorization = ConnectedExecutionAuthorization(renew: { _, _ in
        now = 300
        throw ConnectedRunnerError.transport
    }, checkCancellation: {}, currentTime: { now })
    authorization.start(authorizationOffer)
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 3,
        outputCapture: .tail(maxBytes: 1024))
    do {
        _ = try ProcessExecutor(checkCancellation: authorization.check).execute(request)
        Issue.record("A stuck guest command outlived its authorization")
    } catch let ProcessExecutionError.cancelled(_, _, underlying) {
        #expect(underlying as? ConnectedExecutionError == .expired)
    }
    #expect(authorization.failure == .expired)
}

@Test(arguments: [true, false])
func nativeCacheWaitsForGitHubSuccessBeforeOrAfterListenerExit(successBeforeExit: Bool) throws {
    var now: TimeInterval = 0
    var renewals = 0
    let authorization = ConnectedExecutionAuthorization(renew: { _, check in
        try check()
        renewals += 1
        return renewals == 2 ? .jobSucceeded : .active
    }, checkCancellation: {}, currentTime: { now })
    authorization.start(authorizationOffer, pendingNativeSave: { true })
    if successBeforeExit {
        try authorization.check()
        now = 30
        try authorization.check()
    }
    #expect(try authorization.confirmNativeSave { now += $0 })
    #expect(renewals == 2)
    now = ConnectedExecutionAuthorization.offlineGrace
    #expect(throws: ConnectedExecutionError.expired) { try authorization.check() }
}

@Test
func nativeCacheRejectsRevocationAndBoundsMissingCompletion() throws {
    var now: TimeInterval = 0
    let revoked = ConnectedExecutionAuthorization(renew: { _, _ in .revoked }, checkCancellation: {})
    revoked.start(authorizationOffer, pendingNativeSave: { true })
    #expect(try !revoked.confirmNativeSave { _ in Issue.record("unexpected retry") })

    let offline = ConnectedExecutionAuthorization(renew: { _, _ in throw ConnectedRunnerError.transport },
        checkCancellation: {}, currentTime: { now })
    offline.start(authorizationOffer, pendingNativeSave: { true })
    #expect(try !offline.confirmNativeSave { now += $0 })
    #expect(now == 30)
}

@Test
func successfulCompletionDoesNotExtendGuestExecutionWithoutPendingSave() throws {
    let authorization = ConnectedExecutionAuthorization(renew: { _, _ in .jobSucceeded }, checkCancellation: {})
    authorization.start(authorizationOffer)
    #expect(throws: ConnectedExecutionError.revoked) { try authorization.check() }
}
