import Foundation
import Testing
import Synchronization
@testable import Yieldd

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
    available.withLock { $0 = true }
    await model.update()
    #expect(model.snapshot?.ready == true && model.error == nil)
    await model.update("pause")
    #expect(fixture.control.isPaused)
    #expect(model.admission == "New jobs paused")
    await model.update("resume")
    #expect(!fixture.control.isPaused)
    await model.update("pause-on-battery")
    #expect(model.snapshot?.pauseOnBattery == true)
}
