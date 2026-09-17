import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

private let connectedOffer = try! ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
    runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")

private func connectedJIT(settings: [String: Any]? = nil) throws -> String {
    let value = settings ?? ["AgentName": connectedOffer.runner, "WorkFolder": "_work", "Ephemeral": "True"]
    let runner = try JSONSerialization.data(withJSONObject: value).base64EncodedString()
    return try JSONEncoder().encode([".runner": runner, ".credentials": "e30="]).base64EncodedString()
}

@Test
func connectedJITAcceptsUpstreamRepresentationsWithoutAliases() throws {
    try validateConnectedJIT(connectedJIT(), runner: connectedOffer.runner)
    try validateConnectedJIT(connectedJIT(settings: ["agentName": connectedOffer.runner, "workFolder": "_work", "ephemeral": true]), runner: connectedOffer.runner)
    for fields: [String: Any] in [
        ["AgentName": "other", "WorkFolder": "_work", "Ephemeral": "True"],
        ["AgentName": connectedOffer.runner, "WorkFolder": "../escape", "Ephemeral": "True"],
        ["AgentName": connectedOffer.runner, "WorkFolder": "_work", "Ephemeral": 1],
        ["AgentName": connectedOffer.runner, "agentName": "other", "WorkFolder": "_work", "Ephemeral": "True"],
    ] {
        #expect(throws: ConnectedRunnerError.invalidJIT) { try validateConnectedJIT(connectedJIT(settings: fields), runner: connectedOffer.runner) }
    }
}

@Test(arguments: ["not-base64", "oversized", "e30="])
func connectedJITRejectsInvalidPayloads(_ kind: String) {
    let input = kind == "oversized" ? String(repeating: "x", count: 1_024 * 1_024 + 1) : kind
    #expect(throws: ConnectedRunnerError.invalidJIT) { try validateConnectedJIT(input, runner: connectedOffer.runner) }
}

@Test(arguments: ["http://example.com", "https://user:pass@example.com", "https://example.com/path", "https://example.com?token=x", "https://example.com#x", "file:///tmp/test"])
func connectedCLIRejectsUnsafeServerOrigins(_ value: String) {
    #expect(throws: ConnectedRunnerError.invalidServer) { try ConnectedHTTPClient.serverURL(value) }
}

@Test
func connectedCLIValidatesIdentityAndAcceptsLocalTesting() throws {
    _ = try ConnectedHTTPClient.serverURL("https://coordinator.example.com")
    _ = try ConnectedHTTPClient.serverURL("http://127.0.0.1:8787")
    var command = try ConnectCommand.parse(["--server", "https://example.com", "--device-id", connectedOffer.owner])
    try command.validate()
    command.deviceID = "other"
    #expect(throws: ValidationError.self) { try command.validate() }
    #expect(throws: ConnectedRunnerError.invalidToken) { try ConnectedHTTPClient.validateToken("too-short") }
}

@Test
func connectedJournalIsPrivateBeforePublicationAndLoadableImmediatelyAfter() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let lease = ConnectedLease(server: "https://example.com/", deviceID: connectedOffer.owner, offer: connectedOffer)
    var store = fixture.store
    let publish = store.publish
    var published = false
    store.publish = { source, destination in
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try JSONDecoder().decode(ConnectedLease.self, from: Data(contentsOf: source)) == lease)
        #expect(try fixture.store.load() == nil)
        try publish(source, destination)
        #expect(try fixture.store.load() == lease)
        published = true
        throw TestFailure.runnerJob
    }
    #expect(throws: TestFailure.runnerJob) { try store.save(lease) }
    #expect(published)
    #expect(try fixture.store.load() == lease)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["connected-runner.json"])
}

@Test
func connectedJournalFailedPublicationPreservesPreviousLease() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let previous = ConnectedLease(server: "https://old.example.com/", deviceID: connectedOffer.owner, offer: connectedOffer)
    let replacement = ConnectedLease(server: "https://new.example.com/", deviceID: connectedOffer.owner, offer: connectedOffer)
    var store = fixture.store
    try store.save(previous)
    store.publish = { _, _ in throw TestFailure.runnerJob }
    #expect(throws: TestFailure.runnerJob) { try store.save(replacement) }
    #expect(try fixture.store.load() == previous)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["connected-runner.json"])
    try fixture.store.save(replacement)
    #expect(try fixture.store.load() == replacement)
}

@Test
func connectedRunnerPersistsBeforeAcceptanceAndAcknowledgesAfterDestruction() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    var acknowledged = false
    let runner = fixture.runner(backend: backend, accept: { offer in
        #expect(try fixture.store.load()?.offer == offer)
        return try connectedJIT()
    }, complete: { _ throws in
        #expect(backend.destroyed)
        #expect(try fixture.store.load() != nil)
        acknowledged = true
    })
    try runner.run(connectedOffer, memory: .constrained)
    #expect(acknowledged)
    #expect(try fixture.store.load() == nil)
    #expect(backend.configuration == ["yieldd-configure-runner", "--jit"])
    let delivered = try #require(backend.payload.flatMap { String(data: $0, encoding: .utf8) })
    try validateConnectedJIT(String(delivered.dropLast()), runner: connectedOffer.runner)
}

@Test(arguments: ["accept", "configure", "run", "cancel"])
func connectedRunnerCleansUpBeforePropagatingFailure(_ stage: String) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend(failure: stage == "configure" ? .configure : stage == "run" ? .run : nil)
    var acknowledged = false
    let runner = fixture.runner(backend: backend, accept: { _ in
        if stage == "accept" { throw TestFailure.runnerJob }
        return try connectedJIT()
    }, complete: { _ in acknowledged = true }, check: {
        if stage == "cancel" { throw CancellationError() }
    })
    if stage == "cancel" {
        #expect(throws: CancellationError.self) { try runner.run(connectedOffer, memory: .full) }
    } else {
        #expect(throws: TestFailure.runnerJob) { try runner.run(connectedOffer, memory: .full) }
    }
    #expect(backend.destroyed && acknowledged)
    #expect(try fixture.store.load() == nil)
}

@Test(arguments: ["destroy", "acknowledge"])
func connectedRunnerRetainsUnconfirmedCleanupAndNeverReexecutesOnRestart(_ stage: String) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend(failure: stage == "destroy" ? .destroy : nil)
    var acknowledgements = 0
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() }, complete: { _ in
        acknowledgements += 1
        throw TestFailure.githubCleanup
    })
    #expect(throws: stage == "destroy" ? TestFailure.machineCleanup : .githubCleanup) {
        try runner.run(connectedOffer, memory: .full)
    }
    #expect(acknowledgements == (stage == "destroy" ? 0 : 1))
    #expect(try fixture.store.load() != nil)
    let recoveredBackend = ConnectedBackend()
    let restarted = fixture.runner(backend: recoveredBackend, accept: { _ in
        Issue.record("Recovery must not request credentials")
        return ""
    }, complete: { _ in #expect(recoveredBackend.destroyed) })
    try restarted.recover()
    #expect(recoveredBackend.creates == 0)
    #expect(try fixture.store.load() == nil)
}

@Test
func standaloneCommandsCannotBypassConnectedRecovery() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    try fixture.store.save(ConnectedLease(server: "https://example.com/", deviceID: connectedOffer.owner, offer: connectedOffer))
    #expect(throws: ConnectedRunnerError.recoveryRequired) {
        try withRunnerOwnership(in: fixture.directory) { _ in Issue.record("Standalone recovery would bypass the coordinator") }
    }
    let wrongIdentity = ConnectedRunner(backend: ConnectedBackend(), store: fixture.store, server: "https://another.example/",
        deviceID: connectedOffer.owner, accept: { _ in "" }, complete: { _ in Issue.record("Wrong coordinator") }, checkCancellation: {}, wait: { _ in })
    #expect(throws: ConnectedRunnerError.identityChanged) { try wrongIdentity.recover() }
}

@Test
func expiredConnectedOfferReleasesItsJournalWithoutCreatingAGuest() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    var acknowledged = false
    let runner = fixture.runner(backend: backend, accept: { _ in throw ConnectedRunnerError.http(410) },
        complete: { _ in acknowledged = true })
    try runner.run(connectedOffer, memory: .full)
    #expect(backend.creates == 0 && backend.destroyed && acknowledged)
    #expect(try fixture.store.load() == nil)
}

@Test
func connectedRunnerPreservesCancellationWhenCleanupAlsoFails() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let runner = fixture.runner(backend: ConnectedBackend(failure: .destroy), accept: { _ in "" },
        complete: { _ in Issue.record("Guest destruction did not succeed") }, check: { throw CancellationError() })
    do {
        try runner.run(connectedOffer, memory: .full)
        Issue.record("Expected operation and cleanup errors")
    } catch let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) {
        #expect(operation is CancellationError)
        #expect(cleanup.map(\.step) == [.machine])
        #expect(cleanup.first?.error as? TestFailure == .machineCleanup)
    }
    #expect(try fixture.store.load() != nil)
}

@Test(arguments: ["recover", "poll", "run"])
func connectedClientRetriesOnlyThroughRecovery(_ stage: String) throws {
    var events: [String] = []
    var failed = false
    var polls = 0
    let reservation = RunnerMemoryReservation(allocation: .full, bytes: 1)
    #expect(throws: TestFailure.runnerJob) {
        try runConnectedClient(checkCancellation: {}, recover: {
            events.append("recover")
            if stage == "recover", !failed { failed = true; throw ConnectedRunnerError.transport }
        }, acquire: { events.append("acquire"); return reservation }, release: { _ in events.append("release") }, poll: {
            polls += 1
            events.append("poll")
            if polls > 1 { throw TestFailure.runnerJob }
            if stage == "poll" { throw ConnectedRunnerError.http(503) }
            return connectedOffer
        }, run: { _, _, release in
            events.append("run")
            release()
            if stage == "run" { throw ConnectedRunnerError.transport }
        }, wait: { _ in events.append("wait") }, retrying: {})
    }
    #expect(events.filter { $0 == "acquire" }.count == events.filter { $0 == "release" }.count)
    #expect(events.filter { $0 == "run" }.count == (stage == "poll" ? 0 : 1))
    if stage != "recover" {
        let firstPoll = try #require(events.firstIndex(of: "poll"))
        let lastPoll = try #require(events.lastIndex(of: "poll"))
        #expect(events[(firstPoll + 1)..<lastPoll].contains("recover"))
    }
}

@Test
func connectedClientBoundsEmptyPollsAndReleasesBeforeWaiting() throws {
    var released = false
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: {}, recover: {}, acquire: {
            RunnerMemoryReservation(allocation: .full, bytes: 1)
        }, release: { _ in #expect(!released); released = true }, poll: { nil }, run: { _, _, _ in
            Issue.record("Empty polls must not execute")
        }, wait: { delay in
            #expect(delay == 1)
            #expect(released)
            throw CancellationError()
        }, retrying: { Issue.record("Cancellation is not retryable") })
    }
}

@Test
func connectedClientRecoversTransientCleanupBeforeReportingPermanentOperationFailure() throws {
    var recoveryCalls = 0
    var polls = 0
    #expect(throws: TestFailure.runnerJob) {
        try runConnectedClient(checkCancellation: {}, recover: {
            recoveryCalls += 1
            if recoveryCalls == 2 { throw ConnectedRunnerError.http(503) }
        }, acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in }, poll: {
            polls += 1
            return connectedOffer
        }, run: { _, _, _ in
            throw RunnerSessionError.operationAndCleanupFailed(operation: TestFailure.runnerJob,
                cleanup: [.init(step: .githubRunner, error: ConnectedRunnerError.transport)])
        }, wait: { _ in }, retrying: {})
    }
    #expect(recoveryCalls == 3)
    #expect(polls == 1)
}

@Test
func connectedRecoveryReportsIdentityLossAndRequiresExactOperatorConfirmation() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    try fixture.store.save(ConnectedLease(server: "https://EXAMPLE.com:443/", deviceID: connectedOffer.owner, offer: connectedOffer))
    let backend = ConnectedBackend()
    let runner = fixture.runner(backend: backend, accept: { _ in Issue.record("Recovery must not accept"); return "" },
        complete: { _ in throw ConnectedRunnerError.http(409) })
    #expect(throws: ConnectedRunnerError.confirmationMismatch) { try runner.recover(confirmRegistrationRemoved: "wrong") }
    #expect(!backend.destroyed)
    #expect(throws: ConnectedRunnerError.registrationReconciliationRequired(connectedOffer.runner)) { try runner.recover() }
    #expect(try fixture.store.load() != nil)
    try runner.recover(confirmRegistrationRemoved: connectedOffer.runner)
    #expect(backend.destroyed)
    #expect(try fixture.store.load() == nil)
    #expect(throws: ConnectedRunnerError.confirmationMismatch) { try runner.recover(confirmRegistrationRemoved: connectedOffer.runner) }
}

@Test
func connectedOperatorConfirmationCannotBypassFailedGuestDestruction() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    try fixture.store.save(ConnectedLease(server: "https://example.com/", deviceID: connectedOffer.owner, offer: connectedOffer))
    let runner = fixture.runner(backend: ConnectedBackend(failure: .destroy), accept: { _ in "" }, complete: { _ in })
    #expect(throws: TestFailure.machineCleanup) { try runner.recover(confirmRegistrationRemoved: connectedOffer.runner) }
    #expect(try fixture.store.load() != nil)
}

@Test
func connectedCapacityReportFollowsActualRelease() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    var released = false
    var reported = false
    var runner = fixture.runner(backend: ConnectedBackend(), accept: { _ in try connectedJIT() }, complete: { _ in })
    runner.stateChanged = { state in
        if state == .capacityReleased(RunnerID(value: connectedOffer.runner)) { #expect(released); reported = true }
    }
    try runner.run(connectedOffer, memory: .full, releaseCapacity: { released = true })
    #expect(reported)
}

@Test
func connectedOfferDecodingEnforcesConstructionInvariants() throws {
    var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(connectedOffer)) as? [String: String])
    fields["architecture"] = "x64"
    #expect(throws: ConnectedRunnerError.invalidOffer) {
        try JSONDecoder().decode(ConnectedOffer.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}

@Test(arguments: ["HTTPS://EXAMPLE.com", "https://example.com:443", "https://example.com/"])
func connectedServerOriginsHaveCanonicalIdentity(_ value: String) throws {
    #expect(try ConnectedHTTPClient.serverURL(value).absoluteString == "https://example.com/")
}

@Test
func connectedInvalidServerUsesCLIValidationError() throws {
    var command = try ConnectCommand.parse(["--server", "https://example.com", "--device-id", connectedOffer.owner])
    command.server = "http://example.com"
    #expect(throws: ValidationError.self) { try command.validate() }
}

private struct ConnectedFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var store: ConnectedRunnerStore { ConnectedRunnerStore(directory: directory) }
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func runner(backend: ConnectedBackend, accept: @escaping (ConnectedOffer) throws -> String,
                complete: @escaping (ConnectedOffer) throws -> Void, check: @escaping () throws -> Void = {}) -> ConnectedRunner {
        ConnectedRunner(backend: backend, store: store, server: "https://example.com/", deviceID: connectedOffer.owner,
                        accept: accept, complete: complete, checkCancellation: check, wait: { _ in })
    }
}

private final class ConnectedBackend: RunnerBackend {
    enum Failure { case configure, run, destroy }
    let platform = RunnerPlatform.linux
    let failure: Failure?
    var creates = 0
    var destroyed = false
    var configuration: [String] = []
    var payload: Data?
    init(failure: Failure? = nil) { self.failure = failure }
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws { creates += 1 }
    func exec(_ arguments: [String], standardInput: Data?, timeout: TimeInterval?, outputCapture: ProcessOutputCapture,
              as user: RunnerGuestUser, on id: RunnerID) throws -> ProcessResult {
        if arguments.first == "yieldd-configure-runner" {
            configuration = arguments
            payload = standardInput
            if failure == .configure { throw TestFailure.runnerJob }
        }
        if failure == .run, arguments.last == "start" { throw TestFailure.runnerJob }
        if arguments.last == "status" { return processResult(stdout: #"{"phase":"exited","jobStarted":true,"exitStatus":0}"#) }
        return processResult()
    }
    func stopRunner(on id: RunnerID) throws { Issue.record("Guest destruction must bound connected cleanup") }
    func destroy(_ id: RunnerID) throws {
        if failure == .destroy { throw TestFailure.machineCleanup }
        destroyed = true
    }
}
