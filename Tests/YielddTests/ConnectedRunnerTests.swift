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

@Test(arguments: [false, true])
func connectedRunnerKeepsPickupDeadlineWithoutLimitingExecution(started: Bool) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    backend.statuses = [
        "{\"phase\":\"listening\",\"jobStarted\":\(started)}",
        #"{"phase":"exited","jobStarted":true,"exitStatus":0}"#,
    ]
    var now: TimeInterval = 0
    var acknowledged = false
    var runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() },
        complete: { _ in acknowledged = true }, wait: { _ in now += 24 * 60 * 60 })
    runner.currentTime = { now }
    if started {
        try runner.run(connectedOffer, memory: .constrained)
        #expect(backend.statuses.isEmpty)
    } else {
        #expect(throws: RunnerAssignmentError.pickupTimedOut) { try runner.run(connectedOffer, memory: .constrained) }
        #expect(backend.statuses.count == 1)
    }
    #expect(now == 24 * 60 * 60)
    #expect(backend.destroyed && acknowledged)
    #expect(try fixture.store.load() == nil)
}

@Test(arguments: ["success", "accept", "run", "cancel", "destroy", "acknowledge"])
func connectedRunnerHoldsSleepAssertionThroughCleanup(_ stage: String) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let id = RunnerID(value: "yieldd-bootstrap-\(UUID().uuidString.lowercased())")
    let offer = try ConnectedOffer(owner: connectedOffer.owner, runner: id.value,
        repository: connectedOffer.repository, platform: "linux", architecture: "arm64")
    let backend = ConnectedBackend(failure: stage == "run" ? .run : stage == "destroy" ? .destroy : nil)
    backend.onOperation = { try expectRunnerPreventsIdleSleep(id) }
    let runner = fixture.runner(backend: backend, accept: { _ in
        try expectRunnerPreventsIdleSleep(id)
        if stage == "accept" { throw TestFailure.runnerJob }
        return try connectedJIT(settings: ["AgentName": id.value, "WorkFolder": "_work", "Ephemeral": "True"])
    }, complete: { _ in
        try expectRunnerPreventsIdleSleep(id)
        if stage == "acknowledge" { throw TestFailure.githubCleanup }
    }, check: {
        try expectRunnerPreventsIdleSleep(id)
        if stage == "cancel" { throw CancellationError() }
    })
    #expect(try runnerSleepAssertions(id).isEmpty)
    switch stage {
    case "success": try runner.run(offer, memory: .constrained)
    case "cancel": #expect(throws: CancellationError.self) { try runner.run(offer, memory: .constrained) }
    case "destroy": #expect(throws: TestFailure.machineCleanup) { try runner.run(offer, memory: .constrained) }
    case "acknowledge": #expect(throws: TestFailure.githubCleanup) { try runner.run(offer, memory: .constrained) }
    default: #expect(throws: TestFailure.runnerJob) { try runner.run(offer, memory: .constrained) }
    }
    #expect(try runnerSleepAssertions(id).isEmpty)
}

@Test(arguments: [false, true])
func connectedRecoveryReleasesSleepAssertionAfterDestruction(_ fail: Bool) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let id = RunnerID(value: "yieldd-bootstrap-\(UUID().uuidString.lowercased())")
    let offer = try ConnectedOffer(owner: connectedOffer.owner, runner: id.value,
        repository: connectedOffer.repository, platform: "linux", architecture: "arm64")
    try fixture.store.save(ConnectedLease(server: "https://example.com/", deviceID: connectedOffer.owner, offer: offer))
    let backend = ConnectedBackend(failure: fail ? .destroy : nil)
    backend.onOperation = { try expectRunnerPreventsIdleSleep(id) }
    let runner = fixture.runner(backend: backend, accept: { _ in throw TestFailure.unexpectedBackendCall },
        complete: { _ in try expectRunnerPreventsIdleSleep(id) })
    if fail {
        #expect(throws: TestFailure.machineCleanup) { try runner.recover() }
    } else {
        try runner.recover()
    }
    #expect(try runnerSleepAssertions(id).isEmpty)
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

@Test(arguments: [".env", ".path", ".runner_migrated", "../outside", "invalid-encoding", "missing-credentials"])
func connectedJITRejectsUnexpectedFiles(_ input: String) throws {
    let data = try #require(Data(base64Encoded: connectedJIT()))
    var files = try JSONDecoder().decode([String: String].self, from: data)
    if input == "missing-credentials" {
        files.removeValue(forKey: ".credentials")
    } else if input == "invalid-encoding" {
        files[".credentials"] = "not-base64"
    } else {
        files[input] = Data("untrusted".utf8).base64EncodedString()
    }
    let payload = try JSONEncoder().encode(files).base64EncodedString()
    #expect(throws: ConnectedRunnerError.invalidJIT) { try validateConnectedJIT(payload, runner: connectedOffer.runner) }
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
    var releases = 0
    if stage == "cancel" {
        #expect(throws: CancellationError.self) {
            try runner.run(connectedOffer, memory: .full, releaseCapacity: { releases += 1 })
        }
    } else {
        #expect(throws: TestFailure.runnerJob) {
            try runner.run(connectedOffer, memory: .full, releaseCapacity: { releases += 1 })
        }
    }
    #expect(releases == 1)
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
func connectedClientRetainsCapacityWhenGuestDestructionFails() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend(failure: .destroy)
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() },
        complete: { _ in Issue.record("Guest destruction must succeed before acknowledgement") })
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 24 * gib, readMemoryPressure: { .normal })
    var held: RunnerMemoryReservation?
    var releases = 0
    #expect(throws: TestFailure.machineCleanup) {
        try runConnectedClient(checkCancellation: {}, recover: { try runner.recover() }, acquire: {
            held = try memory.tryAcquire(reserving: 12 * gib)
            return held
        }, release: { reservation in
            releases += 1
            memory.release(reservation)
        }, poll: { connectedOffer }, run: { offer, allocation, release in
            try runner.run(offer, memory: allocation, releaseCapacity: release)
        }, wait: { _ in Issue.record("A permanent destruction failure must escape") }, retrying: {})
    }
    #expect(backend.creates == 1 && !backend.destroyed)
    #expect(releases == 0)
    #expect(try fixture.store.load() != nil)
    let competing = try memory.tryAcquire(reserving: 8 * gib)
    #expect(competing == nil)
    if let competing { memory.release(competing) }
    if releases == 0, let held { memory.release(held) }
}

@Test
func connectedClientRetainsCapacityUntilRecoverySucceeds() throws {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 24 * gib, readMemoryPressure: { .normal })
    var recoveries = 0
    var polls = 0
    var releases = 0
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: {}, recover: {
            recoveries += 1
            guard recoveries > 1 else { return }
            #expect(!memory.isAvailable(reserving: 8 * gib))
            if recoveries == 2 { throw ConnectedRunnerError.http(503) }
        }, acquire: { try memory.tryAcquire(reserving: 12 * gib) }, release: {
            releases += 1
            memory.release($0)
        }, poll: {
            polls += 1
            if polls == 2 {
                #expect(memory.isAvailable(reserving: 8 * gib))
                throw CancellationError()
            }
            return connectedOffer
        }, run: { _, _, _ in throw ConnectedRunnerError.transport }, wait: { _ in }, retrying: {})
    }
    #expect(recoveries == 3 && polls == 2 && releases == 1)
}

@Test
func connectedRunnerReleasesCapacityWhenJournalPublicationFails() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    var store = fixture.store
    store.publish = { _, _ in throw TestFailure.runnerJob }
    let runner = ConnectedRunner(backend: backend, store: store, server: "https://example.com/",
        deviceID: connectedOffer.owner, accept: { _ in throw TestFailure.unexpectedBackendCall },
        complete: { _ in Issue.record("Journal publication failed before acceptance") },
        checkCancellation: {}, wait: { _ in })
    var releases = 0
    #expect(throws: TestFailure.runnerJob) {
        try runner.run(connectedOffer, memory: .full, releaseCapacity: { releases += 1 })
    }
    #expect(releases == 1 && backend.creates == 0)
}

@Test
func connectedClientBoundsEmptyPollsWithoutReservingMemory() throws {
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: {}, recover: {}, acquire: {
            Issue.record("Idle polling must not acquire RAM")
            return nil
        }, release: { _ in Issue.record("No reservation to release") }, poll: { nil }, run: { _, _, _ in
            Issue.record("Empty polls must not execute")
        }, wait: { delay in
            #expect(delay == 1)
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

@Test(arguments: [RunnerPlatform.linux, .macOS])
func connectedPlatformsExecuteJITAndRetainIndependentJournals(_ platform: RunnerPlatform) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let offer = try ConnectedOffer(owner: connectedOffer.owner, runner: connectedOffer.runner,
        repository: connectedOffer.repository, platform: platform == .linux ? "linux" : "macos", architecture: "arm64")
    let backend = ConnectedBackend()
    backend.platform = platform
    let store = ConnectedRunnerStore(directory: fixture.directory, platform: platform)
    var acknowledged = false
    let runner = ConnectedRunner(backend: backend, store: store, server: "https://example.com/",
        deviceID: offer.owner, accept: { accepted in
            #expect(try store.load()?.offer == accepted)
            return try connectedJIT()
        }, complete: { accepted in
            #expect(backend.destroyed)
            #expect(accepted.runnerPlatform == platform)
            acknowledged = true
        }, checkCancellation: {}, wait: { _ in })
    try runner.run(offer, memory: .full)
    #expect(backend.creates == 1 && acknowledged)
    #expect(backend.configuration == ["yieldd-configure-runner", "--jit"])
    #expect(try store.load() == nil)
}

@Test
func connectedRunnerRejectsWrongPlatformBeforeAcceptance() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let mac = try ConnectedOffer(owner: connectedOffer.owner, runner: connectedOffer.runner,
        repository: connectedOffer.repository, platform: "macos", architecture: "arm64")
    let runner = fixture.runner(backend: ConnectedBackend(), accept: { _ in
        Issue.record("Wrong platform was accepted"); return ""
    }, complete: { _ in Issue.record("Wrong platform was acknowledged") })
    var releases = 0
    #expect(throws: ConnectedRunnerError.invalidOffer) {
        try runner.run(mac, memory: .full, releaseCapacity: { releases += 1 })
    }
    #expect(releases == 1)
    #expect(try fixture.store.load() == nil)
}

@Test
func connectedMacOSRecoveryNeedsNoTemplateAndDoesNotClearLinuxJournal() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let mac = try ConnectedOffer(owner: connectedOffer.owner,
        runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())", repository: connectedOffer.repository,
        platform: "macos", architecture: "arm64")
    let macStore = ConnectedRunnerStore(directory: fixture.directory, platform: .macOS)
    try macStore.save(ConnectedLease(server: "https://example.com", deviceID: mac.owner, offer: mac))
    try fixture.store.save(ConnectedLease(server: "https://example.com", deviceID: mac.owner, offer: connectedOffer))
    let clones = MacOSRunnerCloneStore(stateDirectory: fixture.directory)
    let bundle = try clones.bundleURL(for: RunnerID(value: mac.runner))
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try recoverConnectedPlatforms(directory: fixture.directory, server: URL(string: "https://example.com/")!,
        deviceID: mac.owner, token: "", confirmation: mac.runner, stop: RunnerPoolStop())
    #expect(!FileManager.default.fileExists(atPath: bundle.path))
    #expect(try macStore.load() == nil)
    #expect(try fixture.store.load()?.offer == connectedOffer)
}

@Test
func standaloneCommandsCannotSweepOutstandingMacOSConnectedClone() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let offer = try ConnectedOffer(owner: connectedOffer.owner, runner: connectedOffer.runner,
        repository: connectedOffer.repository, platform: "macos", architecture: "arm64")
    try ConnectedRunnerStore(directory: fixture.directory, platform: .macOS)
        .save(ConnectedLease(server: "https://example.com", deviceID: offer.owner, offer: offer))
    #expect(throws: ConnectedRunnerError.recoveryRequired) {
        try withRunnerOwnership(in: fixture.directory) { _ in Issue.record("Standalone command bypassed macOS recovery") }
    }
}

@Test(arguments: [false, true])
func connectedClientDoesNotAcceptWithoutCapacity(available: Bool) throws {
    var polls = 0
    var acquisitions = 0
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: {}, recover: {}, acquire: {
            #expect(polls == 1)
            acquisitions += 1
            return nil
        }, release: { _ in Issue.record("No reservation to release") }, poll: {
            polls += 1
            return connectedOffer
        }, run: { _, _, _ in Issue.record("No capacity was reserved") }, wait: { delay in
            #expect(delay == 1)
            throw CancellationError()
        }, retrying: { Issue.record("Not a coordinator failure") }, available: { available })
    }
    #expect(polls == (available ? 1 : 0))
    #expect(acquisitions == polls)
}

@Test(arguments: [RunnerPlatform.linux, .macOS])
func connectedIdlePollingDoesNotConsumeEitherPlatformsMemory(_ platform: RunnerPlatform) throws {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 24 * gib, readMemoryPressure: { .normal })
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: {}, recover: {}, acquire: {
            try memory.tryAcquire(reserving: platform.memoryReservationBytes)
        }, release: memory.release, poll: {
            let all = try #require(try memory.tryAcquire(reserving: 18 * gib))
            memory.release(all)
            return nil
        }, run: { _, _, _ in Issue.record("No offer") }, wait: { _ in throw CancellationError() },
        retrying: {}, available: { memory.isAvailable(reserving: platform.memoryReservationBytes) })
    }
}

@Test
func connectedPlatformsShareActualReservationsWithoutIdleStarvation() throws {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 24 * gib, readMemoryPressure: { .normal })
    for first in [RunnerPlatform.linux, .macOS] {
        let other: RunnerPlatform = first == .linux ? .macOS : .linux
        #expect(memory.isAvailable(reserving: first.memoryReservationBytes))
        #expect(memory.isAvailable(reserving: other.memoryReservationBytes))
        let held = try #require(try memory.tryAcquire(reserving: first.memoryReservationBytes))
        #expect(try memory.tryAcquire(reserving: other.memoryReservationBytes) == nil)
        memory.release(held)
        let next = try #require(try memory.tryAcquire(reserving: other.memoryReservationBytes))
        memory.release(next)
    }
    let larger = RunnerMemoryAdmission(physicalMemoryBytes: 32 * gib, readMemoryPressure: { .normal })
    let linux = try #require(try larger.tryAcquire(reserving: RunnerPlatform.linux.memoryReservationBytes))
    let mac = try #require(try larger.tryAcquire(reserving: RunnerPlatform.macOS.memoryReservationBytes))
    larger.release(linux)
    larger.release(mac)
}

@Test
func connectedCLIRequiresExplicitPlatformsAndAbsoluteTemplate() throws {
    let base = ["--server", "https://example.com", "--device-id", connectedOffer.owner]
    #expect(try ConnectCommand.parse(base).platforms == [.linux])
    #expect(try ConnectCommand.parse(base + ["--platform", "macos", "--macos-template", "/VM.bundle"]).platforms == [.macOS])
    #expect(try ConnectCommand.parse(base + ["--platform", "linux", "--platform", "macos", "--macos-template", "/VM.bundle"]).platforms == [.linux, .macOS])
    for (args, message) in [
        (["--platform", "macos"], "--platform macos and --macos-template must be supplied together."),
        (["--macos-template", "/VM.bundle"], "--platform macos and --macos-template must be supplied together."),
        (["--platform", "macos", "--macos-template", "relative.bundle"], "--macos-template must be an absolute path."),
        (["--platform", "linux", "--platform", "linux"], "Specify each platform only once.")
    ] {
        do {
            _ = try ConnectCommand.parse(base + args)
            Issue.record("Expected platform validation failure")
        } catch {
            #expect(ConnectCommand.message(for: error) == message)
        }
    }
}

private struct ConnectedFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var store: ConnectedRunnerStore { ConnectedRunnerStore(directory: directory) }
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func runner(backend: ConnectedBackend, accept: @escaping (ConnectedOffer) throws -> String,
                complete: @escaping (ConnectedOffer) throws -> Void, check: @escaping () throws -> Void = {},
                wait: @escaping (TimeInterval) throws -> Void = { _ in }) -> ConnectedRunner {
        ConnectedRunner(backend: backend, store: store, server: "https://example.com/", deviceID: connectedOffer.owner,
                        accept: accept, complete: complete, checkCancellation: check, wait: wait)
    }
}

private final class ConnectedBackend: RunnerBackend {
    enum Failure { case configure, run, destroy }
    var platform = RunnerPlatform.linux
    let failure: Failure?
    var creates = 0
    var destroyed = false
    var configuration: [String] = []
    var payload: Data?
    var onOperation: () throws -> Void = {}
    var statuses = [#"{"phase":"exited","jobStarted":true,"exitStatus":0}"#]
    init(failure: Failure? = nil) { self.failure = failure }
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws { try onOperation(); creates += 1 }
    func exec(_ arguments: [String], standardInput: Data?, timeout: TimeInterval?, outputCapture: ProcessOutputCapture,
              as user: RunnerGuestUser, on id: RunnerID) throws -> ProcessResult {
        try onOperation()
        if arguments.first == "yieldd-configure-runner" {
            configuration = arguments
            payload = standardInput
            if failure == .configure { throw TestFailure.runnerJob }
        }
        if failure == .run, arguments.last == "start" { throw TestFailure.runnerJob }
        if arguments.last == "status" {
            guard !statuses.isEmpty else { throw TestFailure.unexpectedBackendCall }
            return processResult(stdout: statuses.removeFirst())
        }
        return processResult()
    }
    func stopRunner(on id: RunnerID) throws { Issue.record("Guest destruction must bound connected cleanup") }
    func destroy(_ id: RunnerID) throws {
        try onOperation()
        if failure == .destroy { throw TestFailure.machineCleanup }
        destroyed = true
    }
}
