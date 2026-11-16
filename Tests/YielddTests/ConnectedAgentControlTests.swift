import Foundation
import Testing
@testable import Yieldd

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
func connectedDrainWaitsForRetryingCleanupBeforeReleasingAssignment() throws {
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
                throw ConnectedRunnerError.transport
            }, wait: { _ in }, retrying: { _ in }, paused: { fixture.control.snapshot.paused },
            beginAssignment: { fixture.control.beginAssignment(worker: "linux-0") },
            finishAssignment: { fixture.control.finishAssignment(worker: "linux-0") })
    }
    #expect(attempts == 2)
    #expect(fixture.control.snapshot.drained)
}

private struct AgentControlFixture {
    let directory: URL
    let control: ConnectedAgentControl
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-control-\(UUID().uuidString)")
        _ = try AgentConfigurationStore(directory: directory)
        control = ConnectedAgentControl(directory: directory)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
