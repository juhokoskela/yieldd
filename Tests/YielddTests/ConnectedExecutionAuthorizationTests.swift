import Foundation
import Testing
@testable import Yieldd

private let authorizationOffer = try! ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
    runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")

// Tests without native saves should never need the final-result endpoint.
extension ConnectedExecutionAuthorization {
    convenience init(renew: @escaping (ConnectedOffer, () throws -> Void) throws -> ExecutionRenewal,
                     checkCancellation: @escaping () throws -> Void,
                     currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.init(renew: renew, jobResult: { _, _ in throw TestFailure.unexpectedBackendCall },
                  checkCancellation: checkCancellation, currentTime: currentTime)
    }
}

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
    var resultQueries = 0
    let authorization = ConnectedExecutionAuthorization(renew: { _, check in
        try check()
        renewals += 1
        return renewals == 2 ? .jobSucceeded : .active
    }, jobResult: { _, check in
        try check()
        resultQueries += 1
        return resultQueries == 2 ? .succeeded : .pending
    }, checkCancellation: {}, currentTime: { now })
    authorization.start(authorizationOffer, pendingNativeSave: { true })
    if successBeforeExit {
        try authorization.check()
        now = 30
        try authorization.check()
    }
    try authorization.beginNativeCacheDetach()
    authorization.endGuestExecution()
    #expect(try authorization.confirmNativeSave { now += $0 })
    #expect(renewals == (successBeforeExit ? 2 : 1))
    #expect(resultQueries == (successBeforeExit ? 0 : 2))
    now = ConnectedExecutionAuthorization.offlineGrace
    #expect(throws: ConnectedExecutionError.expired) { try authorization.confirmNativeSave { _ in } }
}

@Test
func nativeCacheRejectsRevocationAndBoundsMissingCompletion() throws {
    var now: TimeInterval = 0
    let revoked = ConnectedExecutionAuthorization(renew: { _, _ in throw TestFailure.unexpectedBackendCall },
        jobResult: { _, _ in .unavailable }, checkCancellation: {})
    revoked.start(authorizationOffer, pendingNativeSave: { true })
    revoked.endGuestExecution()
    #expect(try !revoked.confirmNativeSave { _ in Issue.record("unexpected retry") })

    var attempts: [TimeInterval] = []
    let offline = ConnectedExecutionAuthorization(renew: { _, _ in throw TestFailure.unexpectedBackendCall }, jobResult: { _, _ in
        attempts.append(now)
        throw ConnectedRunnerError.transport
    },
        checkCancellation: {}, currentTime: { now })
    offline.start(authorizationOffer, pendingNativeSave: { true })
    offline.endGuestExecution()
    #expect(try !offline.confirmNativeSave { now += $0 })
    #expect(now == 30)
    #expect(attempts == [0, 2, 6, 14, 22])
}

@Test
func shutdownDuringForbiddenCacheResultLookupStillCancelsTheWorker() throws {
    var stopped = false
    let authorization = ConnectedExecutionAuthorization(renew: { _, _ in throw TestFailure.unexpectedBackendCall },
        jobResult: { _, _ in
            stopped = true
            throw ConnectedRunnerError.http(403, request: "POST /v1/job-result (linux ARM64 slot 0)")
        }, checkCancellation: { if stopped { throw CancellationError() } })
    authorization.start(authorizationOffer, pendingNativeSave: { true })
    authorization.endGuestExecution()
    #expect(throws: CancellationError.self) {
        try authorization.confirmNativeSave { _ in Issue.record("unexpected retry") }
    }
}

@Test
func successfulCompletionDoesNotExtendGuestExecutionWithoutPendingSave() throws {
    let authorization = ConnectedExecutionAuthorization(renew: { _, _ in .jobSucceeded }, checkCancellation: {})
    authorization.start(authorizationOffer)
    #expect(throws: ConnectedExecutionError.revoked) { try authorization.check() }
}

@Test(arguments: [true, false])
func terminalSuccessBoundsOnlyTheWaitForListenerExit(cleanExitInTime: Bool) throws {
    var now: TimeInterval = 0
    var result = ExecutionRenewal.active
    let authorization = ConnectedExecutionAuthorization(renew: { _, _ in result }, checkCancellation: {},
                                                       currentTime: { now })
    authorization.start(authorizationOffer, pendingNativeSave: { true })
    try authorization.check()
    now = 30
    result = .jobSucceeded
    try authorization.check()
    now = 59
    try authorization.check()
    if cleanExitInTime {
        try authorization.beginNativeCacheDetach()
        now = 299
        try authorization.check()
        now = 300
        #expect(throws: ConnectedExecutionError.expired) { try authorization.check() }
    } else {
        now = 60
        #expect(throws: ConnectedExecutionError.listenerExitTimedOut) { try authorization.check() }
        #expect(throws: ConnectedExecutionError.listenerExitTimedOut) { try authorization.beginNativeCacheDetach() }
    }
}
