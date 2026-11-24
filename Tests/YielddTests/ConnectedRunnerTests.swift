import ArgumentParser
import Foundation
import Synchronization
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
func connectedRunnerDestroysGuestAfterOfflineGraceDespiteGuestStatus(started: Bool) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    backend.statuses = [
        "{\"phase\":\"listening\",\"jobStarted\":\(started)}",
        #"{"phase":"exited","jobStarted":true,"exitStatus":0}"#,
    ]
    var now: TimeInterval = 0
    var acknowledged = false
    var stopped = false
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() },
        complete: { _ in acknowledged = true }, wait: { _ in now += 300 },
        renew: { _, _ in throw ConnectedRunnerError.transport }, currentTime: { now })
    runner.stateChanged = { if case .executionStopped = $0 { stopped = true } }
    try runner.run(connectedOffer, memory: .constrained)
    #expect(backend.statuses.count == 1)
    #expect(stopped && now == 300)
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

@Test
func connectedRunnerRevocationCannotReleaseCapacityWhenDestructionFails() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend(failure: .destroy)
    var now: TimeInterval = 0
    backend.statuses = [#"{"phase":"listening","jobStarted":true}"#]
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() },
        complete: { _ in Issue.record("Destruction must precede acknowledgement") },
        wait: { _ in now += 30 }, renew: { _, _ in now == 0 }, currentTime: { now })
    var releases = 0
    do {
        try runner.run(connectedOffer, memory: .full, releaseCapacity: { releases += 1 })
        Issue.record("Expected destruction failure")
    } catch let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) {
        #expect(operation as? ConnectedExecutionError == .revoked)
        #expect(cleanup.count == 1 && cleanup.first?.step == .machine)
        #expect(cleanup.first?.error as? TestFailure == .machineCleanup)
    }
    #expect(releases == 0 && backend.creates == 1)
    #expect(try fixture.store.load() != nil)
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
    #expect(backend.destroyed == (stage != "accept" && stage != "cancel"))
    #expect(acknowledged)
    #expect(try fixture.store.load() == nil)
}

@Test(arguments: ConnectedFailureKind.allCases)
func connectedRunnerContainsFailureOnlyAfterJobStartAndConfirmedCleanup(_ kind: ConnectedFailureKind) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    if kind == .listener {
        backend.statuses = [#"{"phase":"listening","jobStarted":true}"#, #"{"phase":"exited","jobStarted":true,"exitStatus":1}"#]
    } else {
        backend.failAfterJobStart(kind.error)
    }
    var events: [RunnerSessionState] = []
    var releases = 0
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() }, complete: { _ throws in
        #expect(backend.destroyed && releases == 1)
        #expect(try fixture.store.load() != nil)
    }, wait: { #expect($0 == 2) })
    runner.stateChanged = { events.append($0) }
    try runner.run(connectedOffer, memory: .full, releaseCapacity: { releases += 1 })
    #expect(backend.destroyed && releases == 1)
    #expect(try fixture.store.load() == nil)
    #expect(events.contains(.executionStopped(RunnerID(value: connectedOffer.runner),
                                             reason: describeError(kind.error))))
    #expect(events.last == .cleanupCompleted(RunnerID(value: connectedOffer.runner)))
}

@Test(arguments: ["destroy", "acknowledge", "journal"])
func connectedGuestFailureDoesNotHideCleanupFailure(_ stage: String) throws {
    let fixture = try ConnectedFixture()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        fixture.remove()
    }
    let backend = ConnectedBackend(failure: stage == "destroy" ? .destroy : nil)
    backend.failAfterJobStart(ConnectedFailureKind.timeout.error)
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() }, complete: { _ in
        if stage == "acknowledge" { throw ConnectedRunnerError.http(403, request: "POST /v1/complete (linux ARM64 slot 0)") }
        if stage == "journal" {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        }
    }, wait: { #expect($0 == 2) })
    var releases = 0
    do {
        try runner.run(connectedOffer, memory: .full, releaseCapacity: { releases += 1 })
        Issue.record("Cleanup failure must stop the worker")
    } catch let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) {
        let failure = try #require(operation as? ConnectedAssignmentFailure)
        #expect(describeError(failure.underlying) == describeError(ConnectedFailureKind.timeout.error))
        #expect(cleanup.map(\.step) == [stage == "destroy" ? .machine : stage == "acknowledge" ? .githubRunner : .leaseRecord])
    }
    #expect(releases == (stage == "destroy" ? 0 : 1))
    #expect(ConnectedRunnerStore.hasRecovery(in: fixture.directory))
    #expect(try fixture.store.load()?.offer == connectedOffer)
}

@Test
func connectedGuestFailureWaitsForAcknowledgementBeforePollingAnotherAssignment() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    backend.failAfterJobStart(ConnectedFailureKind.timeout.error)
    let next = try ConnectedOffer(owner: connectedOffer.owner,
        runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())", repository: connectedOffer.repository,
        platform: "linux", architecture: "arm64")
    var acknowledgements = 0
    var polls = 0
    var releases = 0
    var retries = 0
    let runner = fixture.runner(backend: backend, accept: { offer in
        try connectedJIT(settings: ["AgentName": offer.runner, "WorkFolder": "_work", "Ephemeral": true])
    }, complete: { _ in
        acknowledgements += 1
        if acknowledgements == 1 { throw ConnectedRunnerError.transport }
        if acknowledgements == 2 { throw ConnectedRunnerError.http(503, request: "POST /v1/complete (linux ARM64 slot 0)") }
    }, wait: { #expect($0 == 2) })
    #expect(throws: ConnectedLoopTestStop.finished) {
        try runConnectedClient(checkCancellation: {}, recover: { try runner.recover() },
            acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in releases += 1 }, poll: {
                polls += 1
                if polls == 1 { return connectedOffer }
                #expect(acknowledgements >= 3)
                #expect(try fixture.store.load() == nil)
                if polls == 2 {
                    backend.statusFailure = nil
                    backend.statuses = [#"{"phase":"exited","jobStarted":true,"exitStatus":0}"#]
                    return next
                }
                throw ConnectedLoopTestStop.finished
            }, decline: { _ in Issue.record("Unexpected decline") }, run: { offer, memory, release in
                try runner.run(offer, memory: memory, releaseCapacity: release)
            }, wait: { #expect($0 == 5) }, retrying: { _ in retries += 1 })
    }
    #expect(polls == 3 && backend.creates == 2 && releases == 2 && acknowledgements == 4 && retries == 1)
    #expect(backend.destroys == 2)
    #expect(try fixture.store.load() == nil)
}

@Test
func connectedGuestTimeoutDoesNotCancelHealthySibling() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let directory = fixture.directory
    let overlap = ConnectedWorkerOverlap(expected: 2)
    let cleaned = DispatchSemaphore(value: 0)
    let continued = Mutex(false)
    let siblingFinished = Mutex(false)
    let offers = try (0..<2).map { slot in
        try ConnectedOffer(owner: connectedOffer.owner, runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())",
            repository: connectedOffer.repository, platform: "linux", architecture: "arm64", slot: slot)
    }
    try RunnerPool(stop: RunnerPoolStop()).run(slots: offers) { offer, stop in
        defer { if offer.slot == 0 { cleaned.signal() } }
        let backend = ConnectedBackend()
        backend.onStatus = { [unowned backend] in
            guard backend.statusPolls == 2 else { return }
            try overlap.arrive(check: {})
            if offer.slot == 1 {
                try #require(cleaned.wait(timeout: .now() + 5) == .success)
                try stop.check()
            }
        }
        if offer.slot == 0 { backend.failAfterJobStart(ConnectedFailureKind.timeout.error) }
        else { backend.statuses.insert(#"{"phase":"listening","jobStarted":true}"#, at: 0) }
        let store = ConnectedRunnerStore(directory: directory, slot: offer.slot)
        let runner = ConnectedRunner(backend: backend, store: store, server: "https://example.com/",
            deviceID: offer.owner, accept: { accepted in
                try connectedJIT(settings: ["AgentName": accepted.runner, "WorkFolder": "_work", "Ephemeral": true])
            }, complete: { _ in #expect(backend.destroyed) },
            authorization: .init(renew: { _, _ in true }, checkCancellation: stop.check),
            wait: { #expect($0 == 2); try stop.check() })
        var polled = false
        do {
            try runConnectedClient(checkCancellation: stop.check, recover: { try runner.recover() },
                acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in }, poll: {
                    if polled {
                        #expect(try store.load() == nil)
                        if offer.slot == 0 { continued.withLock { $0 = true }; cleaned.signal() }
                        throw ConnectedLoopTestStop.finished
                    }
                    polled = true
                    return offer
                }, decline: { _ in Issue.record("Unexpected decline") }, run: { offer, memory, release in
                    try runner.run(offer, memory: memory, releaseCapacity: release)
                    if offer.slot == 1 { siblingFinished.withLock { $0 = true } }
                }, wait: { _ in Issue.record("Unexpected client backoff") }, retrying: { _ in Issue.record("Unexpected retry") })
        } catch ConnectedLoopTestStop.finished {}
        try stop.check()
        #expect(backend.creates == 1 && backend.destroyed)
    }
    #expect(continued.withLock { $0 })
    #expect(siblingFinished.withLock { $0 })
    #expect(!ConnectedRunnerStore.hasRecovery(in: directory))
}

private enum ConnectedLoopTestStop: Error { case finished }

enum ConnectedFailureKind: CaseIterable {
    case timeout, exit, signal, status, relay, stoppedVM, failedVM, listener

    var error: any Error {
        let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/container"),
            arguments: ["machine", "run", "--", "yieldd-runner-control", "status"], timeout: 10)
        switch self {
        case .exit: return ProcessExecutionError.nonZeroExit(request: request, result: processResult(status: 1))
        case .signal: return ProcessExecutionError.terminatedBySignal(request: request, result: processResult(status: 9))
        case .status: return RunnerAssignmentError.invalidStatus
        case .relay: return RunnerNetworkRelayError.exited(status: 1)
        case .stoppedVM: return MacOSVirtualizationProbeError.stoppedUnexpectedly
        case .failedVM: return MacOSVirtualizationProbeError.virtualMachineFailed(POSIXError(.EIO))
        case .listener: return RunnerAssignmentError.listenerFailed(1, output: "")
        case .timeout: return ProcessExecutionError.timedOut(request: request, result: processResult())
        }
    }
}

@Test(arguments: ["startup", "cancel", "host"])
func connectedAssignmentIsolationPreservesFatalFailures(_ stage: String) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/container"), arguments: [])
    let failure: any Error
    switch stage {
    case "cancel": failure = ProcessExecutionError.cancelled(request: request, result: processResult(), underlying: CancellationError())
    case "host": failure = ProcessExecutionError.launchFailed(request: request, underlying: POSIXError(.ENOENT))
    default: failure = ConnectedFailureKind.timeout.error
    }
    if stage == "startup" { backend.configurationFailure = failure }
    else { backend.failAfterJobStart(failure) }
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() }, complete: { _ in }, wait: { #expect($0 == 2) })
    let error = try #require(#expect(throws: (any Error).self) { try runner.run(connectedOffer, memory: .full) })
    #expect(describeError(error) == describeError(failure))
    #expect(backend.destroyed)
    #expect(try fixture.store.load() == nil)
}

enum ConnectedPreJobFailure: CaseIterable {
    case start, transport, pickup, noJob, listener, status, stoppedVM
}

@Test(arguments: ConnectedPreJobFailure.allCases)
func connectedPreJobFailuresStopPollingInsteadOfReacceptingDemand(_ stage: ConnectedPreJobFailure) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    var now: TimeInterval = 0
    let expected: any Error
    switch stage {
    case .start:
        expected = ConnectedFailureKind.timeout.error
        backend.startFailure = expected
    case .transport:
        expected = ConnectedFailureKind.timeout.error
        backend.statusFailure = expected
    case .pickup:
        expected = RunnerAssignmentError.pickupTimedOut
        backend.statuses = Array(repeating: #"{"phase":"listening","jobStarted":false}"#, count: 2)
        backend.onStatus = { [unowned backend] in now = backend.statusPolls == 1 ? 290 : 301 }
    case .noJob, .listener:
        let exitStatus = stage == .listener ? 1 : 0
        backend.statuses = ["{\"phase\":\"exited\",\"jobStarted\":false,\"exitStatus\":\(exitStatus)}"]
        expected = stage == .listener ? RunnerAssignmentError.listenerFailed(1, output: "") : RunnerAssignmentError.exitedWithoutJob
    case .stoppedVM:
        expected = MacOSVirtualizationProbeError.stoppedUnexpectedly
        backend.statusFailure = expected
    case .status:
        expected = RunnerAssignmentError.invalidStatus
        backend.statuses = ["invalid status"]
    }
    var acknowledged = false
    var waits: [TimeInterval] = []
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() }, complete: { _ in acknowledged = true },
        wait: { waits.append($0) }, currentTime: { now })
    var polls = 0
    let error = try #require(#expect(throws: (any Error).self) {
        try runConnectedClient(checkCancellation: {}, recover: { try runner.recover() },
            acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in }, poll: {
                polls += 1
                if polls > 1 { throw ConnectedLoopTestStop.finished }
                return connectedOffer
            }, decline: { _ in Issue.record("Unexpected decline") }, run: { offer, memory, release in
                try runner.run(offer, memory: memory, releaseCapacity: release)
            }, wait: { _ in Issue.record("Unexpected client backoff") }, retrying: { _ in Issue.record("Unexpected retry") })
    })
    #expect(describeError(error) == describeError(expected))
    #expect(polls == 1 && backend.destroyed && acknowledged)
    #expect(waits == (stage == .pickup ? [0.5, 0] : []))
    #expect(try fixture.store.load() == nil)
}

@Test
func connectedPermanentRenewalErrorIsNotContainedAfterJobStart() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    backend.statuses.insert(#"{"phase":"listening","jobStarted":true}"#, at: 0)
    var now: TimeInterval = 0
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() }, complete: { _ in },
        wait: { #expect($0 == 2) }, renew: { _, _ in
            if now >= 30 { throw ConnectedRunnerError.http(401, request: "POST /v1/renew (linux ARM64 slot 0)") }
            return true
        }, currentTime: { now })
    let authorization = runner.authorization
    backend.onStatus = { [unowned backend] in
        if backend.statusPolls == 2 { now = 31; try authorization.check() }
    }
    #expect(throws: ConnectedRunnerError.http(401, request: "POST /v1/renew (linux ARM64 slot 0)")) { try runner.run(connectedOffer, memory: .full) }
    #expect(backend.destroyed)
    #expect(try fixture.store.load() == nil)
}

@Test(arguments: [ConnectedExecutionError.expired, .revoked])
func connectedAuthorizationFailureTakesPrecedenceOverCancelledGuestCommand(_ expected: ConnectedExecutionError) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    backend.statuses.insert(#"{"phase":"listening","jobStarted":true}"#, at: 0)
    var now: TimeInterval = 0
    var events: [RunnerSessionState] = []
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() }, complete: { _ in },
        wait: { #expect($0 == 2) }, renew: { _, _ in now == 0 }, currentTime: { now })
    runner.stateChanged = { events.append($0) }
    let authorization = runner.authorization
    backend.onStatus = { [unowned backend] in
        guard backend.statusPolls == 2 else { return }
        now = expected == .expired ? 301 : 31
        do {
            try authorization.check()
            Issue.record("Expected execution authorization to end")
        } catch {
            let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/container"), arguments: [])
            throw ProcessExecutionError.cancelled(request: request, result: processResult(), underlying: error)
        }
    }
    try runner.run(connectedOffer, memory: .full)
    #expect(events.contains(.executionStopped(RunnerID(value: connectedOffer.runner), reason: describeError(expected))))
    #expect(backend.destroyed)
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
        deviceID: connectedOffer.owner, accept: { _ in "" }, complete: { _ in Issue.record("Wrong coordinator") },
        authorization: .init(renew: { _, _ in true }, checkCancellation: {}), wait: { _ in })
    #expect(throws: ConnectedRunnerError.identityChanged) { try wrongIdentity.recover() }
}

@Test
func expiredConnectedOfferReleasesItsJournalWithoutCreatingAGuest() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    var acknowledged = false
    let runner = fixture.runner(backend: backend, accept: { _ in throw ConnectedRunnerError.http(410, request: "POST /v1/accept (linux ARM64 slot 0)") },
        complete: { _ in acknowledged = true })
    try runner.run(connectedOffer, memory: .full)
    #expect(backend.creates == 0 && !backend.destroyed && acknowledged)
    #expect(try fixture.store.load() == nil)
}

@Test
func expiredConnectedOfferCanPollAgainAfterTransientAcknowledgementFailure() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    var acknowledgements = 0
    var polls = 0
    var releases = 0
    let runner = fixture.runner(backend: backend, accept: { _ in throw ConnectedRunnerError.http(410, request: "POST /v1/accept (linux ARM64 slot 0)") },
        complete: { _ in
            acknowledgements += 1
            if acknowledgements == 1 { throw ConnectedRunnerError.transport }
        })
    #expect(throws: ConnectedLoopTestStop.finished) {
        try runConnectedClient(checkCancellation: {}, recover: { try runner.recover() },
            acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in releases += 1 }, poll: {
                polls += 1
                if polls == 2 {
                    #expect(acknowledgements == 2 && releases == 1)
                    #expect(try fixture.store.load() == nil)
                    throw ConnectedLoopTestStop.finished
                }
                return connectedOffer
            }, decline: { _ in Issue.record("Unexpected decline") }, run: { offer, memory, release in
                try runner.run(offer, memory: memory, releaseCapacity: release)
            }, wait: { _ in Issue.record("Unexpected backoff") }, retrying: { _ in Issue.record("Unexpected retry") })
    }
    #expect(polls == 2 && backend.creates == 0)
}

@Test
func connectedRunnerPreservesCancellationWhenCleanupAlsoFails() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let runner = fixture.runner(backend: ConnectedBackend(failure: .destroy), accept: { _ in "" },
        complete: { _ in throw TestFailure.githubCleanup }, check: { throw CancellationError() })
    do {
        try runner.run(connectedOffer, memory: .full)
        Issue.record("Expected operation and cleanup errors")
    } catch let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) {
        #expect(operation is CancellationError)
        #expect(cleanup.map(\.step) == [.githubRunner])
        #expect(cleanup.first?.error as? TestFailure == .githubCleanup)
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
            if stage == "poll" { throw ConnectedRunnerError.http(503, request: "POST /v1/poll (linux ARM64 slot 0)") }
            return connectedOffer
        }, decline: { _ in Issue.record("Unexpected capacity decline") }, run: { _, _, release in
            events.append("run")
            release()
            if stage == "run" { throw ConnectedRunnerError.transport }
        }, wait: { _ in events.append("wait") }, retrying: { _ in })
    }
    #expect(events.filter { $0 == "acquire" }.count == events.filter { $0 == "release" }.count)
    #expect(events.filter { $0 == "run" }.count == (stage == "poll" ? 0 : 1))
    if stage != "recover" {
        let firstPoll = try #require(events.firstIndex(of: "poll"))
        let lastPoll = try #require(events.lastIndex(of: "poll"))
        #expect(events[(firstPoll + 1)..<lastPoll].contains("recover"))
    }
}

@Test(arguments: ["one poll per worker slot", "coordinator queue identity does not match; retain local recovery state", ""])
func connectedClientRetriesConfirmedPollContentionWithoutRetryingIdentityConflicts(_ reason: String) throws {
    let failure = ConnectedRunnerError.http(409, request: "POST /v1/poll (linux ARM64 slot 0)",
        reason: reason.isEmpty ? nil : reason)
    let shouldRetry = reason == "one poll per worker slot"
    var events: [String] = []
    var polls = 0
    do {
        try runConnectedClient(checkCancellation: {}, recover: { events.append("recover") },
            acquire: { Issue.record("Polling must not reserve memory"); return nil },
            release: { _ in Issue.record("No memory was reserved") }, poll: {
                events.append("poll")
                polls += 1
                if polls == 1 { throw failure }
                throw ConnectedLoopTestStop.finished
            }, decline: { _ in Issue.record("No offer was returned") },
            run: { _, _, _ in Issue.record("No offer was returned") }, wait: {
                #expect($0 == 5)
                events.append("wait")
            }, retrying: { error in
                #expect(error as? ConnectedRunnerError == failure)
                events.append("retry")
            })
        Issue.record("Expected polling to stop")
    } catch {
        if shouldRetry {
            #expect(error is ConnectedLoopTestStop)
        } else {
            #expect(error as? ConnectedRunnerError == failure)
        }
    }
    #expect(events == (shouldRetry ? ["recover", "poll", "retry", "wait", "recover", "poll"] : ["recover", "poll"]))
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
        }, poll: { connectedOffer }, decline: { _ in Issue.record("Unexpected capacity decline") }, run: { offer, allocation, release in
            try runner.run(offer, memory: allocation, releaseCapacity: release)
        }, wait: { _ in Issue.record("A permanent destruction failure must escape") }, retrying: { _ in })
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
            if recoveries == 2 { throw ConnectedRunnerError.http(503, request: "POST /v1/complete (linux ARM64 slot 0)") }
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
        }, decline: { _ in Issue.record("Unexpected capacity decline") }, run: { _, _, _ in throw ConnectedRunnerError.transport }, wait: { _ in }, retrying: { _ in })
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
        authorization: .init(renew: { _, _ in true }, checkCancellation: {}), wait: { _ in })
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
        }, release: { _ in Issue.record("No reservation to release") }, poll: { nil }, decline: { _ in Issue.record("Unexpected capacity decline") }, run: { _, _, _ in
            Issue.record("Empty polls must not execute")
        }, wait: { delay in
            #expect(delay == 1)
            throw CancellationError()
        }, retrying: { _ in Issue.record("Cancellation is not retryable") })
    }
}

@Test
func connectedClientRecoversTransientCleanupBeforeReportingPermanentOperationFailure() throws {
    var recoveryCalls = 0
    var polls = 0
    #expect(throws: TestFailure.runnerJob) {
        try runConnectedClient(checkCancellation: {}, recover: {
            recoveryCalls += 1
            if recoveryCalls == 2 { throw ConnectedRunnerError.http(503, request: "POST /v1/complete (linux ARM64 slot 0)") }
        }, acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in }, poll: {
            polls += 1
            return connectedOffer
        }, decline: { _ in Issue.record("Unexpected capacity decline") }, run: { _, _, _ in
            throw RunnerSessionError.operationAndCleanupFailed(operation: TestFailure.runnerJob,
                cleanup: [.init(step: .githubRunner, error: ConnectedRunnerError.transport)])
        }, wait: { _ in }, retrying: { _ in })
    }
    #expect(recoveryCalls == 3)
    #expect(polls == 1)
}

@Test
func connectedStartupFailureIsReportedBeforeCleanupRetries() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let backend = ConnectedBackend()
    let failure = ConnectedFailureKind.timeout.error
    backend.statusFailure = failure
    var events: [String] = []
    var acknowledgements = 0
    let runner = fixture.runner(backend: backend, accept: { _ in try connectedJIT() }, complete: { _ in
        events.append("complete")
        acknowledgements += 1
        if acknowledgements < 3 { throw ConnectedRunnerError.http(503, request: "POST /v1/complete (linux ARM64 slot 0)") }
    })
    runner.stateChanged = {
        if case let .executionStopped(_, reason) = $0 {
            #expect(reason == describeError(failure))
            events.append("failure")
        }
    }
    var polls = 0
    #expect(throws: ProcessExecutionError.self) {
        try runConnectedClient(checkCancellation: {}, recover: { try runner.recover() },
            acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in }, poll: {
                polls += 1
                guard polls == 1 else { throw TestFailure.unexpectedBackendCall }
                return connectedOffer
            }, decline: { _ in Issue.record("Unexpected decline") }, run: { offer, memory, release in
                try runner.run(offer, memory: memory, releaseCapacity: release)
            }, wait: { #expect($0 == 5); events.append("wait") }, retrying: { _ in events.append("retry") })
    }
    #expect(events == ["failure", "complete", "complete", "retry", "wait", "complete"])
    #expect(try fixture.store.load() == nil)
}

@Test
func connectedWorkerRecoveryRetainsJournalWhenCoordinatorIdentityIsLost() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    try fixture.store.save(ConnectedLease(server: "https://EXAMPLE.com:443/", deviceID: connectedOffer.owner, offer: connectedOffer))
    let backend = ConnectedBackend()
    let runner = fixture.runner(backend: backend, accept: { _ in Issue.record("Recovery must not accept"); return "" },
        complete: { _ in throw ConnectedRunnerError.http(409, request: "POST /v1/complete (linux ARM64 slot 0)",
            reason: "coordinator queue identity does not match; retain local recovery state") })
    #expect(throws: ConnectedRunnerError.registrationReconciliationRequired(connectedOffer.runner)) { try runner.recover() }
    #expect(try fixture.store.load() != nil)
    #expect(backend.destroyed)
}

@Test
func connectedCapacityReportFollowsActualRelease() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    var released = false
    var reported = false
    let runner = fixture.runner(backend: ConnectedBackend(), accept: { _ in try connectedJIT() }, complete: { _ in })
    runner.stateChanged = { state in
        if state == .capacityReleased(RunnerID(value: connectedOffer.runner)) { #expect(released); reported = true }
    }
    try runner.run(connectedOffer, memory: .full, releaseCapacity: { released = true })
    #expect(reported)
}

@Test
func connectedOfferDecodingEnforcesConstructionInvariants() throws {
    var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(connectedOffer)) as? [String: Any])
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

@Test(arguments: [RunnerPlatform.linux, .macOS], [false, true])
func connectedPlatformsExecuteJITAndRetainIndependentJournals(_ platform: RunnerPlatform, localCache: Bool) throws {
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
        }, authorization: .init(renew: { _, _ in true }, checkCancellation: {}), wait: { _ in }, localCache: localCache)
    try runner.run(offer, memory: .full)
    #expect(backend.creates == 1 && acknowledged)
    #expect(backend.configuration == ["yieldd-configure-runner", "--jit"] + (localCache ? ["--local-cache"] : []))
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

@Test(arguments: [false, true], [0, 1, 15])
func connectedMacOSRecoveryNeedsNoTemplateAndDoesNotClearLinuxJournal(badNetworkDirectory: Bool, slot: Int) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let mac = try ConnectedOffer(owner: connectedOffer.owner,
        runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())", repository: connectedOffer.repository,
        platform: "macos", architecture: "arm64", slot: slot)
    let macStore = ConnectedRunnerStore(directory: fixture.directory, platform: .macOS, slot: slot)
    try macStore.save(ConnectedLease(server: "https://example.com", deviceID: mac.owner, offer: mac))
    try fixture.store.save(ConnectedLease(server: "https://example.com", deviceID: mac.owner, offer: connectedOffer))
    let clones = testCloneStores(in: fixture.directory)(.runners)
    let bundle = try clones.bundleURL(for: RunnerID(value: mac.runner))
    let networks = try RunnerNetworkDirectories(stateDirectory: fixture.directory)
    defer { try? FileManager.default.removeItem(at: networks.rootURL) }
    let socketDirectory = try networks.create(for: RunnerID(value: mac.runner))
    try Data("stale socket".utf8).write(to: socketDirectory.appendingPathComponent("n"))
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    #expect(throws: ConnectedRunnerError.confirmationMismatch) {
        try recoverConnectedPlatforms(directory: fixture.directory, server: URL(string: "https://example.com/")!,
            deviceID: mac.owner, token: "", confirmation: "wrong", stop: RunnerPoolStop(), makeCloneStore: testCloneStores(in: fixture.directory))
    }
    #expect(FileManager.default.fileExists(atPath: bundle.path))
    if badNetworkDirectory {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: socketDirectory.path)
        #expect(throws: RunnerSessionError.self) {
            try recoverConnectedPlatforms(directory: fixture.directory, server: URL(string: "https://example.com/")!,
                deviceID: mac.owner, token: "", confirmation: mac.runner, stop: RunnerPoolStop(), makeCloneStore: testCloneStores(in: fixture.directory))
        }
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
        #expect(try macStore.load()?.offer == mac)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory.path)
    }
    try recoverConnectedPlatforms(directory: fixture.directory, server: URL(string: "https://example.com/")!,
        deviceID: mac.owner, token: "", confirmation: mac.runner, stop: RunnerPoolStop(), makeCloneStore: testCloneStores(in: fixture.directory))
    #expect(!FileManager.default.fileExists(atPath: bundle.path))
    #expect(!FileManager.default.fileExists(atPath: socketDirectory.path))
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
    var declined = 0
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: {}, recover: {}, acquire: {
            #expect(polls == 1)
            acquisitions += 1
            return nil
        }, release: { _ in Issue.record("No reservation to release") }, poll: {
            polls += 1
            return connectedOffer
        }, decline: { offer in
            #expect(offer == connectedOffer)
            declined += 1
        }, run: { _, _, _ in Issue.record("No capacity was reserved") }, wait: { delay in
            #expect(delay == 1)
            throw CancellationError()
        }, retrying: { _ in Issue.record("Not a coordinator failure") }, available: { available })
    }
    #expect(polls == (available ? 1 : 0))
    #expect(acquisitions == polls)
    #expect(declined == polls)
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
        }, decline: { _ in Issue.record("Unexpected capacity decline") }, run: { _, _, _ in Issue.record("No offer") }, wait: { _ in throw CancellationError() },
        retrying: { _ in }, available: { memory.isAvailable(reserving: platform.memoryReservationBytes) })
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

@Test(arguments: [RunnerPlatform.linux, .macOS])
func connectedWorkersOverlapWithinSharedMemoryAndKeepIndependentJournals(_ platform: RunnerPlatform) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: (platform == .linux ? 48 : 24) * gib,
                                       readMemoryPressure: { .normal })
    let count = memory.connectedWorkerCount(for: platform)
    #expect(count == (platform == .linux ? 3 : 2))
    let overlap = ConnectedWorkerOverlap(expected: count)
    let directory = fixture.directory
    let offers = try (0..<count).map { slot in
        try ConnectedOffer(owner: connectedOffer.owner, runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())",
                           repository: connectedOffer.repository, platform: platform == .linux ? "linux" : "macos",
                           architecture: "arm64", slot: slot)
    }
    try RunnerPool(stop: RunnerPoolStop()).run(slots: offers) { offer, _ in
        let store = ConnectedRunnerStore(directory: directory, platform: platform, slot: offer.slot)
        let backend = ConnectedBackend()
        backend.platform = platform
        var reachedBarrier = false
        backend.onOperation = { [unowned backend] in
            if backend.creates == 1 && !reachedBarrier {
                reachedBarrier = true
                try overlap.arrive { () throws -> Void in
                    #expect(!memory.isAvailable(reserving: platform.memoryReservationBytes))
                    for other in offers {
                        let journal = ConnectedRunnerStore(directory: directory, platform: platform, slot: other.slot)
                        #expect(try journal.load()?.offer == other)
                    }
                }
            }
        }
        let runner = ConnectedRunner(backend: backend, store: store, server: "https://example.com/",
            deviceID: offer.owner, accept: { accepted in
                try connectedJIT(settings: ["AgentName": accepted.runner, "WorkFolder": "_work", "Ephemeral": true])
            }, complete: { completed in
                #expect(backend.destroyed)
                #expect(completed == offer)
            }, authorization: .init(renew: { _, _ in true }, checkCancellation: {}), wait: { _ in })
        var polled = false
        do {
            try runConnectedClient(checkCancellation: {}, recover: { try runner.recover() }, acquire: {
                try memory.tryAcquire(reserving: platform.memoryReservationBytes)
            }, release: memory.release, poll: {
                if polled { throw CancellationError() }
                polled = true
                return offer
            }, decline: { _ in Issue.record("Unexpected capacity decline") }, run: { offer, allocation, release in
                try runner.run(offer, memory: allocation, releaseCapacity: release)
            }, wait: { _ in throw TestFailure.runnerJob }, retrying: { _ in
                Issue.record("No retry expected")
            })
        } catch is CancellationError {}
        #expect(backend.creates == 1 && backend.destroyed && reachedBarrier)
        #expect(try store.load() == nil)
    }
    let all = try #require(try memory.tryAcquire(reserving: UInt64(count) * platform.memoryReservationBytes))
    memory.release(all)
    #expect(!ConnectedRunnerStore.hasRecovery(in: directory))
}

@Test(arguments: [RunnerPlatform.linux, .macOS])
func connectedWorkerJournalsRejectCrossSlotWritesAndBlockStandaloneRecovery(_ platform: RunnerPlatform) throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    let offer = try ConnectedOffer(owner: connectedOffer.owner, runner: connectedOffer.runner,
        repository: connectedOffer.repository, platform: platform == .linux ? "linux" : "macos",
        architecture: "arm64", slot: 15)
    let lease = ConnectedLease(server: "https://example.com/", deviceID: connectedOffer.owner, offer: offer)
    let wrong = ConnectedRunnerStore(directory: fixture.directory, platform: platform)
    #expect(throws: ConnectedRunnerError.invalidState) { try wrong.save(lease) }
    let store = ConnectedRunnerStore(directory: fixture.directory, platform: platform, slot: 15)
    try store.save(lease)
    #expect(ConnectedRunnerStore.hasRecovery(in: fixture.directory))
    #expect(throws: ConnectedRunnerError.recoveryRequired) {
        try withRunnerOwnership(in: fixture.directory) { _ in Issue.record("High slot bypassed recovery") }
    }
    // A renamed journal cannot be loaded as another worker's assignment.
    try FileManager.default.copyItem(at: store.file, to: wrong.file)
    #expect(throws: ConnectedRunnerError.invalidState) { try wrong.load() }
    #expect(try store.load() == lease)
}

@Test(arguments: [-1, 16])
func connectedOffersRejectOutOfRangeWorkerSlots(_ slot: Int) {
    #expect(throws: ConnectedRunnerError.invalidOffer) {
        try ConnectedOffer(owner: connectedOffer.owner, runner: connectedOffer.runner,
                           repository: connectedOffer.repository, platform: "linux", architecture: "arm64", slot: slot)
    }
}

@Test
func connectedWorkerPlanUsesMemoryBudgetAndStablePlatformSlots() {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    for (physical, linux, mac) in [(16, 1, 1), (24, 1, 2), (48, 3, 2), (1024, 16, 2)] {
        let memory = RunnerMemoryAdmission(physicalMemoryBytes: UInt64(physical) * gib, readMemoryPressure: { .normal })
        #expect(memory.connectedWorkerCount(for: .linux) == linux)
        #expect(memory.connectedWorkerCount(for: .macOS) == mac)
        var reports: [(RunnerPlatform, Int)] = []
        let workers = connectedWorkers(backends: [.linux(containerURL: URL(fileURLWithPath: "/container")),
                                                   .macOS(templateURL: URL(fileURLWithPath: "/template"))], memory: memory) {
            reports.append(($0, $1))
        }
        #expect(workers.filter { $0.backend.platform == .linux }.map(\.slot) == Array(0..<linux))
        #expect(workers.filter { $0.backend.platform == .macOS }.map(\.slot) == Array(0..<mac))
        #expect(reports.map(\.0) == [.linux, .macOS])
        #expect(reports.map(\.1) == [linux, mac])
    }
}

@Test
func connectedJournalWithoutWorkerSlotRequiresPreviousVersionRecovery() throws {
    let fixture = try ConnectedFixture()
    defer { fixture.remove() }
    try fixture.store.save(ConnectedLease(server: "https://example.com/", deviceID: connectedOffer.owner, offer: connectedOffer))
    let data = try Data(contentsOf: fixture.store.file)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var offer = try #require(json["offer"] as? [String: Any])
    offer.removeValue(forKey: "slot")
    json["offer"] = offer
    let old = try JSONSerialization.data(withJSONObject: json)
    try old.write(to: fixture.store.file)
    #expect(throws: ConnectedRunnerError.previousVersionState) { try fixture.store.load() }
    #expect(try Data(contentsOf: fixture.store.file) == old)
    #expect(ConnectedRunnerStore.hasRecovery(in: fixture.directory))
}

@Test
func connectedMixedPlatformWorkersCannotOvercommitOneMemoryBudget() throws {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 48 * gib, readMemoryPressure: { .normal })
    let contenders = [RunnerPlatform.linux, .linux, .linux, .macOS, .macOS]
    let snapshot = ConnectedWorkerOverlap(expected: contenders.count)
    let acquired = ConnectedWorkerOverlap(expected: contenders.count)
    let held = Mutex<[RunnerMemoryReservation]>([])
    try RunnerPool(stop: RunnerPoolStop()).run(slots: contenders) { platform, _ in
        #expect(memory.isAvailable(reserving: platform.memoryReservationBytes))
        try snapshot.arrive(check: {})
        let reservation = try memory.tryAcquire(reserving: platform.memoryReservationBytes)
        if let reservation { held.withLock { $0.append(reservation) } }
        defer { if let reservation { memory.release(reservation) } }
        // Nobody releases capacity until all five racing workers tried admission.
        try acquired.arrive {
            let reservations = held.withLock { $0 }
            let total = reservations.reduce(UInt64(0)) { $0 + $1.bytes }
            #expect(reservations.count == 3)
            try #require(total <= 36 * gib)
            #expect(try memory.tryAcquire(reserving: 36 * gib - total + 1) == nil)
        }
    }
    let all = try #require(try memory.tryAcquire(reserving: 36 * gib))
    memory.release(all)
}

// A bounded barrier proves all simulated guests exist before any can finish.
private final class ConnectedWorkerOverlap: @unchecked Sendable {
    private let condition = NSCondition()
    private let expected: Int
    private var arrived = 0
    init(expected: Int) { self.expected = expected }
    func arrive(check: () throws -> Void) throws {
        condition.lock()
        defer { condition.unlock() }
        arrived += 1
        if arrived == expected {
            defer { condition.broadcast() }
            try check()
        } else {
            let deadline = Date(timeIntervalSinceNow: 5)
            while arrived < expected {
                guard condition.wait(until: deadline) else { throw TestFailure.runnerJob }
            }
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
                wait: @escaping (TimeInterval) throws -> Void = { _ in },
                renew: @escaping (ConnectedOffer, () throws -> Void) throws -> Bool = { _, _ in true },
                currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> ConnectedRunner {
        ConnectedRunner(backend: backend, store: store, server: "https://example.com/", deviceID: connectedOffer.owner,
                        accept: accept, complete: complete,
                        authorization: .init(renew: renew, checkCancellation: check, currentTime: currentTime),
                        wait: wait, currentTime: currentTime)
    }
}

private final class ConnectedBackend: RunnerBackend {
    enum Failure { case configure, run, destroy }
    var platform = RunnerPlatform.linux
    let failure: Failure?
    var creates = 0
    var destroys = 0
    var destroyed: Bool { destroys > 0 }
    var configuration: [String] = []
    var payload: Data?
    var onOperation: () throws -> Void = {}
    var onStatus: () throws -> Void = {}
    var statusFailure: (any Error)?
    var statusFailureOnPoll = 1
    var statusPolls = 0
    var startFailure: (any Error)?
    var configurationFailure: (any Error)?
    var statuses = [#"{"phase":"exited","jobStarted":true,"exitStatus":0}"#]
    init(failure: Failure? = nil) { self.failure = failure }
    func failAfterJobStart(_ error: any Error) {
        statuses = [#"{"phase":"listening","jobStarted":true}"#]
        statusFailure = error
        statusFailureOnPoll = 2
    }
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws { try onOperation(); creates += 1 }
    func exec(_ arguments: [String], standardInput: Data?, timeout: TimeInterval?, outputCapture: ProcessOutputCapture,
              as user: RunnerGuestUser, on id: RunnerID) throws -> ProcessResult {
        try onOperation()
        if arguments.contains("--protocol-version") { return processResult(stdout: arguments.contains("--local-cache") ? "3\n" : "2\n") }
        if arguments.first == "yieldd-configure-runner" {
            configuration = arguments
            payload = standardInput
            if let configurationFailure { throw configurationFailure }
            if failure == .configure { throw TestFailure.runnerJob }
        }
        if failure == .run, arguments.last == "start" { throw TestFailure.runnerJob }
        if arguments.last == "start", let startFailure { throw startFailure }
        if arguments.last == "output" { return processResult() }
        if arguments.last == "status" {
            statusPolls += 1
            try onStatus()
            if let statusFailure, statusPolls >= statusFailureOnPoll { throw statusFailure }
            guard !statuses.isEmpty else { throw TestFailure.unexpectedBackendCall }
            return processResult(stdout: statuses.removeFirst())
        }
        return processResult()
    }
    func destroy(_ id: RunnerID) throws {
        try onOperation()
        if failure == .destroy { throw TestFailure.machineCleanup }
        destroys += 1
    }
}
