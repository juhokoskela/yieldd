import AppKit
import Foundation
import Testing
import Synchronization
import notify
@testable import Yieldd

@Test
func powerSourceReadsOnlyOnStartupAndPowerChanges() async throws {
    let notification = "dev.yieldd.test.power." + UUID().uuidString
    let reads = Mutex(0)
    let source = AgentPowerSource(notification: notification) {
        reads.withLock { $0 += 1; return $0 > 1 }
    }
    for _ in 0..<100 { #expect(!source.onBattery()) }
    #expect(reads.withLock { $0 } == 1)
    try #require(notify_post(notification) == NOTIFY_STATUS_OK)
    let deadline = ContinuousClock.now + .seconds(2)
    while !source.onBattery() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(source.onBattery())
    #expect(reads.withLock { $0 } == 2)
}

@Test
func batteryPolicyGatesNewAssignmentsAndPreservesManualPause() throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let battery = Mutex(false)
    let control = ConnectedAgentControl(directory: fixture.directory, usingBattery: { battery.withLock { $0 } })
    control.markReady()
    #expect(control.beginAssignment(worker: "macos-0"))
    #expect(try control.request("pause-on-battery").pauseOnBattery == true)
    battery.withLock { $0 = true }
    #expect(!control.beginAssignment(worker: "linux-0"))
    #expect(control.snapshot.activeAssignments == 1)
    #expect(control.snapshot.pausedByBattery == true)
    let relaunched = ConnectedAgentControl(directory: fixture.directory, usingBattery: { true })
    #expect(relaunched.isPaused)
    _ = try control.request("pause")
    battery.withLock { $0 = false }
    #expect(control.isPaused)
    #expect(try !control.request("resume").paused)
    battery.withLock { $0 = true }
    #expect(try !control.request("allow-on-battery").paused)
    #expect(control.beginAssignment(worker: "linux-0"))
}

@MainActor @Test
func companionCanPauseManuallyWhileBatteryPolicyIsActive() async throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let battery = Mutex(true)
    let control = ConnectedAgentControl(directory: fixture.directory, usingBattery: { battery.withLock { $0 } })
    _ = try control.request("pause-on-battery")
    let model = CompanionModel { try control.request($0) }
    await model.update()
    let delegate = CompanionDelegate(model: model)
    let menu = NSMenu()
    delegate.menuNeedsUpdate(menu)
    let item = try #require(menu.item(withTitle: "Pause New Jobs"))
    #expect(menu.item(withTitle: "Allow New Jobs on Battery") != nil)
    let action = try #require(item.action)
    #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
    let deadline = ContinuousClock.now + .seconds(2)
    while model.snapshot?.manuallyPaused != true && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    battery.withLock { $0 = false }
    #expect(control.isPaused)
    #expect(try !control.request("resume").paused)
}

@Test
func oldAgentSnapshotsOmitBatteryPreferences() throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let data = try JSONEncoder().encode(fixture.control.snapshot)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for field in ["pauseOnBattery", "pausedByBattery", "manuallyPaused"] { json.removeValue(forKey: field) }
    let decoded = try JSONDecoder().decode(AgentControlSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.pauseOnBattery == nil && decoded.pausedByBattery == nil && decoded.manuallyPaused == nil)
}

@Test
func batteryPreferenceFollowsMarkerAfterDirectorySyncFailure() throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let alias = fixture.directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
    let control = ConnectedAgentControl(directory: alias, usingBattery: { true })
    for (command, expected) in [("pause-on-battery", true), ("allow-on-battery", false)] {
        // The marker operation succeeds through the alias. Directory sync rejects a symlink.
        #expect(throws: POSIXError.self) { try control.request(command) }
        #expect(control.isPaused == expected)
        #expect(ConnectedAgentControl(directory: fixture.directory, usingBattery: { true }).isPaused == expected)
        let restarted = ConnectedAgentControl(directory: alias, usingBattery: { true })
        #expect(throws: POSIXError.self) { try restarted.request(command) }
        #expect(throws: POSIXError.self) { try control.request(command) }
    }
}

@MainActor @Test
func companionPauseCanFinishBeforeAnOlderStatusReply() async throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let started = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let timedOut = Mutex(false)
    let model = CompanionModel { command in
        let result = try fixture.control.request(command)
        if command == "status" {
            started.withLock { $0 = true }
            guard release.wait(timeout: .now() + 2) == .success else {
                timedOut.withLock { $0 = true }
                throw AgentControlError.unavailable
            }
        }
        return result
    }
    let status = Task { await model.update() }
    let deadline = ContinuousClock.now + .seconds(2)
    while !started.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    try #require(started.withLock { $0 })
    #expect(await model.update() == nil)
    #expect(await model.update("pause") == nil)
    #expect(model.snapshot?.manuallyPaused == true)
    release.signal()
    #expect(await status.value == nil)
    #expect(!timedOut.withLock { $0 })
    #expect(model.snapshot?.manuallyPaused == true && model.error == nil)
}

@MainActor @Test
func openCompanionMenuReplacesOfflineActionsWhenTheAgentRecovers() async throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let available = Mutex(false)
    let model = CompanionModel { command in
        guard available.withLock({ $0 }) else { throw AgentControlError.unavailable }
        return try fixture.control.request(command)
    }
    await model.update()
    let delegate = CompanionDelegate(model: model)
    let menu = NSMenu()
    delegate.menuNeedsUpdate(menu)
    #expect(menu.item(withTitle: "Check Again") != nil)
    available.withLock { $0 = true }
    delegate.menuWillOpen(menu)
    let deadline = ContinuousClock.now + .seconds(2)
    while menu.item(withTitle: "Pause New Jobs") == nil && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(menu.item(withTitle: "Pause New Jobs") != nil)
    #expect(menu.item(withTitle: "Check Again") == nil)
    delegate.menuDidClose(menu)
}

@MainActor @Test
func companionPreservesExplicitRejectionsAcrossSuccessfulPolls() async throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let model = CompanionModel { command in
        if command == "pause-on-battery" { throw AgentControlError.rejected("Could not save the battery preference.") }
        return try fixture.control.request(command)
    }
    #expect(await model.update("pause-on-battery") != nil)
    #expect(await model.update() == nil)
    #expect(model.error == "Could not save the battery preference.")
    model.dismissRejection()
    #expect(model.error == nil)
}

@MainActor @Test
func companionClearsLostReplyErrorWhenItReadsTheCommittedPause() async throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let model = CompanionModel { command in
        let snapshot = try fixture.control.request(command)
        if command == "pause" { throw AgentControlError.unavailable }
        return snapshot
    }
    await model.update()
    await model.update("pause")
    #expect(model.error != nil)
    await model.update()
    #expect(model.error == nil)
    #expect(model.snapshot?.manuallyPaused == true)
}

@Test
func connectedPauseSerializesAdmissionAndDrainsOnlyAfterCleanup() throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let control = fixture.control
    #expect(!control.snapshot.ready)
    _ = try control.request("pause")
    #expect(!control.snapshot.drained)
    control.markReady()
    #expect(control.snapshot.drained)
    _ = try control.request("resume")
    #expect(control.beginAssignment(worker: "linux-0"))
    #expect(try !control.request("pause").drained)
    #expect(!control.beginAssignment(worker: "linux-1"))
    #expect(control.snapshot.activeAssignments == 1)
    control.finishAssignment(worker: "linux-0")
    #expect(control.snapshot.drained)
    #expect(ConnectedAgentControl(directory: fixture.directory).snapshot.paused)
    _ = try control.request("resume")
    #expect(!ConnectedAgentControl(directory: fixture.directory).snapshot.paused)
    #expect(throws: AgentControlError.self) { try control.request("discard") }
}

@Test
func connectedControlRoundTripsThroughAnonymousXPC() throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    let listener = NSXPCListener.anonymous()
    let endpoint = AgentControlEndpoint(control: fixture.control, listener: listener)
    endpoint.start()
    defer { endpoint.stop() }
    fixture.control.markReady()
    let paused = try requestAgentControl("pause", connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
    #expect(paused.paused && paused.drained)
    let resumed = try requestAgentControl("resume", connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
    #expect(!resumed.paused)
}

@Test
func connectedClientDeclinesAnOfferReceivedDuringPauseWithoutAcceptingIt() throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    fixture.control.markReady()
    var declined = false
    var released = false
    let offer = try ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
        runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: { if declined { throw CancellationError() } }, recover: {},
            acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in released = true },
            poll: { _ = try fixture.control.request("pause"); return offer },
            decline: { _ in declined = true }, run: { _, _, _ in Issue.record("Paused offer must not execute") },
            wait: { _ in }, retrying: { _ in }, paused: { fixture.control.snapshot.paused },
            beginAssignment: { fixture.control.beginAssignment(worker: "linux-0") },
            finishAssignment: { fixture.control.finishAssignment(worker: "linux-0") })
    }
    #expect(declined && released && fixture.control.snapshot.drained)
}

@Test
func cacheServiceRestartFailureRetriesBeforeAdvertisingCapacity() {
    var events: [String] = []
    var attempts = 0
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: {}, recover: { events.append("recover") },
            acquire: { Issue.record("Unexpected reservation"); return nil }, release: { _ in },
            prepareToPoll: {
                attempts += 1
                if attempts == 1 { throw POSIXError(.ENOSPC) }
            }, poll: { events.append("poll"); throw CancellationError() },
            decline: { _ in Issue.record("Unexpected offer") }, run: { _, _, _ in Issue.record("Unexpected job") },
            wait: { delay in #expect(delay == 5); events.append("wait") },
            retrying: { error in #expect((error as? POSIXError)?.code == .ENOSPC); events.append("retry") })
    }
    #expect(attempts == 2)
    #expect(events == ["recover", "retry", "wait", "poll"])
}

@Test(arguments: [false, true])
func connectedDrainWaitsForRetryingCleanupBeforeReleasingAssignment(combined: Bool) throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    fixture.control.markReady()
    var recovering = false
    var recovered = false
    var attempts = 0
    let offer = try ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
        runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: { if recovered { throw CancellationError() } }, recover: {
            if recovering {
                #expect(!fixture.control.snapshot.drained)
                attempts += 1
                if attempts == 1 { throw ConnectedRunnerError.transport }
                recovered = true
            }
        }, acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in },
            poll: { offer }, decline: { _ in Issue.record("Unexpected decline") }, run: { _, _, _ in
                _ = try fixture.control.request("pause")
                recovering = true
                if combined {
                    throw RunnerSessionError.operationAndCleanupFailed(operation: ConnectedExecutionError.revoked,
                        cleanup: [.init(step: .githubRunner, error: ConnectedRunnerError.transport)])
                }
                throw ConnectedRunnerError.transport
            }, wait: { _ in }, retrying: { _ in }, paused: { fixture.control.snapshot.paused },
            beginAssignment: { fixture.control.beginAssignment(worker: "linux-0") },
            finishAssignment: { fixture.control.finishAssignment(worker: "linux-0") })
    }
    #expect(attempts == 2)
    #expect(fixture.control.snapshot.drained)
}

@Test(arguments: [false, true])
func drainDetectsResumePauseRaceAndAgentRestart(restart: Bool) throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    fixture.control.markReady()
    #expect(fixture.control.beginAssignment(worker: "linux-0"))
    var current = fixture.control
    #expect(throws: AgentControlError.self) {
        try waitForAgentDrain(request: { try current.request($0) }, wait: {
            if restart {
                current = ConnectedAgentControl(directory: fixture.directory)
                current.markReady()
            } else {
                _ = try current.request("resume")
                _ = try current.request("pause")
                current.finishAssignment(worker: "linux-0")
            }
        })
    }
}

@Test
func connectedControlRejectsMissingInstallationAndKeepsUnexpectedPauseMarkersSafe() throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    #expect(throws: AgentControlError.self) { try requireInstalledConnectedAgent(in: fixture.directory) }
    let marker = fixture.directory.appendingPathComponent("connected-agent.paused")
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: fixture.directory.appendingPathComponent("missing"))
    _ = try fixture.control.request("pause")
    #expect(ConnectedAgentControl(directory: fixture.directory).snapshot.paused)
    _ = try fixture.control.request("resume")
    #expect(!ConnectedAgentControl(directory: fixture.directory).snapshot.paused)
}

@Test
func connectedDrainCompletesAfterASuccessfulAssignmentAndCleanup() throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    fixture.control.markReady()
    let offer = try ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
        runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")
    var finished = false
    #expect(throws: CancellationError.self) {
        try runConnectedClient(checkCancellation: { if finished { throw CancellationError() } }, recover: {},
            acquire: { RunnerMemoryReservation(allocation: .full, bytes: 1) }, release: { _ in },
            poll: { offer }, decline: { _ in Issue.record("Unexpected decline") }, run: { _, _, release in
                _ = try fixture.control.request("pause")
                #expect(!fixture.control.snapshot.drained)
                release()
                #expect(!fixture.control.snapshot.drained)
            }, wait: { _ in }, retrying: { _ in }, paused: { fixture.control.snapshot.paused },
            beginAssignment: { fixture.control.beginAssignment(worker: "linux-0") }, finishAssignment: {
                if fixture.control.snapshot.activeAssignments > 0 { finished = true }
                fixture.control.finishAssignment(worker: "linux-0")
            })
    }
    #expect(fixture.control.snapshot.drained)
}

private struct AgentControlFixture {
    let directory: URL
    let control: ConnectedAgentControl
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-control-\(UUID().uuidString)")
        _ = try RunnerLeaseStore(directory: directory)
        control = ConnectedAgentControl(directory: directory)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Test
func companionControlsTheAgentOverXPCAndRecoversFromLostContact() async throws {
    let fixture = try AgentControlFixture()
    defer { fixture.remove() }
    fixture.control.markReady()
    let listener = NSXPCListener.anonymous()
    let control = AgentControlEndpoint(control: fixture.control, listener: listener)
    control.start()
    defer { control.stop() }
    let endpoint = listener.endpoint
    let available = Mutex(false)
    let model = CompanionModel { command in
        guard available.withLock({ $0 }) else { throw AgentControlError.unavailable }
        return try requestAgentControl(command, connection: NSXPCConnection(listenerEndpoint: endpoint))
    }
    await model.update()
    #expect(model.snapshot == nil && model.error != nil)
    #expect(model.idleRefreshInterval == .seconds(60))
    available.withLock { $0 = true }
    await model.update()
    #expect(model.snapshot?.ready == true && model.error == nil)
    #expect(model.idleRefreshInterval == .seconds(30))
    #expect(fixture.control.beginAssignment(worker: "linux-0"))
    await model.update()
    #expect(model.idleRefreshInterval == .seconds(5))
    fixture.control.finishAssignment(worker: "linux-0")
    await model.update("pause")
    #expect(fixture.control.isPaused)
    #expect(model.admission == "New jobs paused")
    await model.update("resume")
    #expect(!fixture.control.isPaused)
    await model.update("pause-on-battery")
    #expect(model.snapshot?.pauseOnBattery == true)
}
