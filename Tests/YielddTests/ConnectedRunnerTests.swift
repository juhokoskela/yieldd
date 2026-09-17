import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

private let connectedOffer = ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
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
    #expect(backend.configuration == ["yieldd-configure-runner", "--jit", connectedOffer.runner])
    let delivered = try #require(backend.payload.flatMap { String(data: $0, encoding: .utf8) })
    try validateConnectedJIT(String(delivered.dropLast()), runner: connectedOffer.runner)
}

@Test(arguments: ["accept", "configure", "run", "cancel"])
func connectedRunnerCleansUpBeforePropagatingFailure(_ stage: String) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend(failure: stage)
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
    let backend = ConnectedBackend(failure: stage)
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
    let runner = fixture.runner(backend: ConnectedBackend(failure: "destroy"), accept: { _ in "" },
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

private struct ConnectedFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var store: ConnectedRunnerStore { ConnectedRunnerStore(directory: directory) }
    init() throws { _ = try RunnerLeaseStore(directory: directory) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func runner(backend: ConnectedBackend, accept: @escaping (ConnectedOffer) throws -> String,
                complete: @escaping (ConnectedOffer) throws -> Void, check: @escaping () throws -> Void = {}) -> ConnectedRunner {
        ConnectedRunner(backend: backend, store: store, server: "https://example.com/", deviceID: connectedOffer.owner,
                        accept: accept, complete: complete, checkCancellation: check, wait: { _ in })
    }
}

private final class ConnectedBackend: RunnerBackend {
    let platform = RunnerPlatform.linux
    let failure: String
    var creates = 0
    var destroyed = false
    var configuration: [String] = []
    var payload: Data?
    init(failure: String = "") { self.failure = failure }
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws { creates += 1 }
    func exec(_ arguments: [String], standardInput: Data?, timeout: TimeInterval?, outputCapture: ProcessOutputCapture,
              as user: RunnerGuestUser, on id: RunnerID) throws -> ProcessResult {
        if arguments.first == "yieldd-configure-runner" {
            configuration = arguments
            payload = standardInput
            if failure == "configure" { throw TestFailure.runnerJob }
        }
        if failure == "run", arguments.last == "start" { throw TestFailure.runnerJob }
        if arguments.last == "status" { return processResult(stdout: #"{"phase":"exited","jobStarted":true,"exitStatus":0}"#) }
        return processResult()
    }
    func stopRunner(on id: RunnerID) throws { Issue.record("Guest destruction must bound connected cleanup") }
    func destroy(_ id: RunnerID) throws {
        if failure == "destroy" { throw TestFailure.machineCleanup }
        destroyed = true
    }
}
