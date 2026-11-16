import Foundation
import Testing
@testable import Yieldd

@Test
func liveStatusKeepsCleanupActiveAfterMachineCapacityIsReleased() throws {
    let directory = try liveStatusDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = ConnectedAgentControl(directory: directory)
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024, readMemoryPressure: { .normal })
    control.configure(workers: [ConnectedWorker(backend: .linux(containerURL: URL(fileURLWithPath: "/container")), slot: 0)], memory: memory)
    control.markReady()
    let reservation = try #require(try memory.tryAcquire(reserving: RunnerPlatform.linux.memoryReservationBytes))
    let offer = try ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
        runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")
    #expect(control.beginAssignment(worker: "linux-0"))
    control.update(worker: "linux-0", phase: .provisioning, offer: offer)
    control.connection(worker: "linux-0", state: .connected, error: nil)
    control.session(worker: "linux-0", state: .jobStarted(RunnerID(value: offer.runner)))
    #expect(control.snapshot.workers.first?.phase == .running)
    #expect(control.snapshot.workers.first?.lastContactAt != nil)
    #expect(control.snapshot.memory?.reservedBytes == reservation.bytes)
    _ = try control.request("pause")
    memory.release(reservation)
    control.session(worker: "linux-0", state: .capacityReleased(RunnerID(value: offer.runner)))
    let cleaning = control.snapshot
    #expect(cleaning.memory?.reservedBytes == 0)
    #expect(cleaning.activeAssignments == 1 && !cleaning.drained)
    #expect(cleaning.workers.first?.phase == .cleaningUp)
    #expect(cleaning.workers.first?.repository == "owner/repo")
    control.finishAssignment(worker: "linux-0")
    let complete = control.snapshot
    #expect(complete.drained && complete.workers.first?.runner == nil)
    let decoded = try JSONDecoder().decode(AgentControlSnapshot.self, from: JSONEncoder().encode(complete))
    #expect(decoded == complete)
}

@Test
func liveStatusReportsRecoveryAndRetainsTheLastErrorAfterReconnect() throws {
    let directory = try liveStatusDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = ConnectedAgentControl(directory: directory)
    let offer = try ConnectedOffer(owner: "01234567-89ab-4def-8123-456789abcdef",
        runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")
    control.recovering([ConnectedLease(server: "https://coordinator.example", deviceID: offer.owner, offer: offer)])
    #expect(control.snapshot.phase == .recovering && !control.snapshot.ready)
    #expect(control.snapshot.activeAssignments == 1)
    #expect(control.snapshot.workers.first?.phase == .recovering)
    control.connection(worker: "linux-0", state: .retrying, error: "Coordinator unavailable")
    let errorDate = control.snapshot.lastError?.occurredAt
    control.connection(worker: "linux-0", state: .connected, error: nil)
    #expect(control.snapshot.lastError?.occurredAt == errorDate)
    #expect(control.snapshot.workers.first?.connection == .connected)
    control.fail(ConnectedRunnerError.transport)
    #expect(control.snapshot.phase == .failed && !control.snapshot.ready)
}

@Test
func unavailableServiceReportsHistoryWithoutPresentingItAsLiveHealth() throws {
    let directory = try liveStatusDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let failure = AgentReportedError(message: "Saved token is unavailable")
    try AgentFailureStore(directory: directory).save(failure)
    let report = connectedAgentStatus(registration: .enabled, directory: directory, request: { throw AgentControlError.unavailable })
    #expect(report.live == nil)
    #expect(report.lastFailure == failure)
    #expect(report.unavailableReason != nil)
    #expect(renderAgentStatus(report).contains("Last recorded failure"))
    let data = try JSONEncoder().encode(report)
    let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(value["version"] as? Int == 1)
    #expect(value["live"] == nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("connected-agent-error.json").path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
}

@Test
func damagedDiagnosticHistoryDoesNotBlockLiveStatusOrAgentStartup() throws {
    let directory = try liveStatusDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writePrivateRunnerFile(Data("damaged".utf8), to: directory.appendingPathComponent("connected-agent-error.json"))
    let control = ConnectedAgentControl(directory: directory)
    control.markReady()
    let report = connectedAgentStatus(registration: .enabled, directory: directory, request: { control.snapshot })
    #expect(report.live?.ready == true)
    #expect(report.lastFailure == nil)
}

private func liveStatusDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-status-\(UUID().uuidString)")
    _ = try AgentConfigurationStore(directory: directory)
    return directory
}
