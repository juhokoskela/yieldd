import AppKit
import Foundation
import Synchronization
import Testing
@testable import Yieldd

private let testOfferLinux = try! ConnectedOffer(
    owner: "01234567-89ab-4def-8123-456789abcdef",
    runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef",
    repository: "owner/repo",
    platform: "linux",
    architecture: "arm64",
    slot: 0
)

private let testOfferLinuxSecond = try! ConnectedOffer(
    owner: "01234567-89ab-4def-8123-456789abcdef",
    runner: "yieldd-bootstrap-11234567-89ab-4def-8123-456789abcdef",
    repository: "owner/repo",
    platform: "linux",
    architecture: "arm64",
    slot: 0
)

@Test
func preStartOfflineGraceIsShorterAndWidensAfterJobStart() throws {
    var now: TimeInterval = 100
    let observedRun = Mutex<Int64?>(nil)
    let auth = ConnectedExecutionAuthorization(
        renewWithMetadata: { _, _ in
            throw ConnectedRunnerError.transport
        },
        checkCancellation: {},
        currentTime: { now },
        initialOfflineGrace: ConnectedExecutionAuthorization.preStartOfflineGrace,
        onWorkflowRunID: { id in observedRun.withLock { $0 = id } }
    )
    auth.start(testOfferLinux)
    now = 159
    try auth.check()
    now = 160
    #expect(throws: ConnectedExecutionError.expired) { try auth.check() }

    auth.stop()
    now = 200
    auth.start(testOfferLinux)
    auth.markJobStarted()
    now = 499
    try auth.check()
    now = 500
    #expect(throws: ConnectedExecutionError.expired) { try auth.check() }
}

@Test
func authorizationAbortRejectsStaleRunnerUUIDAndRecordsWorkflowRunID() throws {
    let observedRun = Mutex<Int64?>(nil)
    let auth = ConnectedExecutionAuthorization(
        renewWithMetadata: { _, _ in
            ConnectedAuthorizationRenewal(shouldContinue: true, workflowRunID: 424242)
        },
        checkCancellation: {},
        currentTime: { 10 },
        onWorkflowRunID: { id in observedRun.withLock { $0 = id } }
    )
    auth.start(testOfferLinux)
    try auth.check()
    #expect(observedRun.withLock { $0 } == 424242)

    // Stale click for a different runner UUID must be rejected harmlessly.
    #expect(!auth.abort(reason: .reclaimed, expectedRunner: testOfferLinuxSecond.runner))
    try auth.check()

    // Matching runner UUID aborts immediately.
    #expect(auth.abort(reason: .reclaimed, expectedRunner: testOfferLinux.runner))
    #expect(throws: ConnectedExecutionError.reclaimed) { try auth.check() }
}

@Test
func meetingModeEnforcesSingleLinuxSlotACPowerAndThermalBackoff() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-mode-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let power = Mutex(HostPowerStatus(source: .ac, batteryPercent: 100, lowPowerMode: false, drainingOnAC: false))
    let thermal = Mutex(HostThermalState.nominal)
    let darkWake = Mutex(false)
    let now = Mutex(Date(timeIntervalSince1970: 1_000_000))

    let control = ConnectedAgentControl(
        directory: directory,
        powerStatus: { power.withLock { $0 } },
        thermalState: { thermal.withLock { $0 } },
        isDarkWake: { darkWake.withLock { $0 } },
        currentDate: { now.withLock { $0 } },
        hardwareProfile: HostHardwareProfile(modelIdentifier: "Mac16,7", logicalCPUs: 16),
        notificationName: nil
    )
    control.markReady()

    let enableCmd = try AgentControlRequest(action: "meeting-mode", enabled: true, cpus: 4).encodedCommand()
    let enabled = try control.request(enableCmd)
    #expect(enabled.meetingMode == true)
    #expect(enabled.meetingModeCPUs == 4)

    // macOS jobs are deferred to hosted overflow in Meeting Mode.
    #expect(!control.canPoll(platform: .macOS))
    #expect(!control.beginAssignment(worker: "macOS-0", platform: .macOS))

    // Only 1 Linux slot can be admitted atomically.
    #expect(control.canPoll(platform: .linux))
    #expect(control.beginAssignment(worker: "linux-0", platform: .linux))
    #expect(!control.beginAssignment(worker: "linux-1", platform: .linux))
    control.finishAssignment(worker: "linux-0")

    // Unknown power or draining charger fails closed in Meeting Mode.
    power.withLock { $0 = HostPowerStatus(source: .unknown, batteryPercent: nil, lowPowerMode: false, drainingOnAC: false) }
    #expect(!control.beginAssignment(worker: "linux-0", platform: .linux))
    power.withLock { $0 = HostPowerStatus(source: .ac, batteryPercent: 80, lowPowerMode: false, drainingOnAC: true) }
    #expect(!control.beginAssignment(worker: "linux-0", platform: .linux))
    power.withLock { $0 = HostPowerStatus(source: .ac, batteryPercent: 80, lowPowerMode: false, drainingOnAC: false) }

    // Fair thermal state steps 4 -> 2 vCPUs decrease-only; serious pauses admissions.
    thermal.withLock { $0 = .fair }
    #expect(control.effectiveLinuxCPUs == 2)
    thermal.withLock { $0 = .serious }
    #expect(!control.beginAssignment(worker: "linux-0", platform: .linux))
    thermal.withLock { $0 = .nominal }

    // DarkWake blocks new admissions.
    darkWake.withLock { $0 = true }
    #expect(!control.beginAssignment(worker: "linux-0", platform: .linux))
    darkWake.withLock { $0 = false }

    // Advance past 10-minute thermal hold-down.
    now.withLock { $0 = $0.addingTimeInterval(601) }
    #expect(control.beginAssignment(worker: "linux-0", platform: .linux))
}

@Test
func reclaimPausesAndAbortsAllWhileAbortJobTargetsExactRunnerWithoutPausing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reclaim-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let control = ConnectedAgentControl(directory: directory, usingBattery: { false })
    control.markReady()
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024)
    let workers = [
        ConnectedWorker(backend: .linux(containerURL: URL(fileURLWithPath: "/usr/bin/true")), slot: 0),
    ]
    control.configure(workers: workers, memory: memory)
    #expect(control.beginAssignment(worker: "linux-0", platform: .linux))
    control.assign(worker: "linux-0", offer: testOfferLinux)

    let aborted = Mutex<(ConnectedExecutionError, String?)?>(nil)
    let severed = Mutex(false)
    let markedWake = Mutex(false)
    let done = DispatchSemaphore(value: 0)
    control.registerSlotHandler(worker: "linux-0", handler: AgentSlotControlHandler(
        abort: { reason, expected in
            aborted.withLock { $0 = (reason, expected) }
            done.signal()
            return true
        },
        severNetwork: { severed.withLock { $0 = true } },
        applyCPUQuota: { _ in },
        markDestroyOnWake: { markedWake.withLock { $0 = true } }
    ))

    // Stale runner UUID is rejected cleanly.
    let staleAbort = try AgentControlRequest(action: "abort-job", worker: "linux-0", runner: testOfferLinuxSecond.runner).encodedCommand()
    #expect(throws: AgentControlError.self) { try control.request(staleAbort) }
    #expect(!control.isPaused)

    // Exact runner UUID aborts without pausing the agent.
    let validAbort = try AgentControlRequest(action: "abort-job", worker: "linux-0", runner: testOfferLinux.runner).encodedCommand()
    let afterAbort = try control.request(validAbort)
    #expect(!afterAbort.paused)
    #expect(done.wait(timeout: .now() + 2) == .success)
    #expect(aborted.withLock { $0?.0 == .reclaimed && $0?.1 == testOfferLinux.runner })

    // Global reclaim pauses durably and aborts active jobs.
    let afterReclaim = try control.request("reclaim")
    #expect(afterReclaim.paused && afterReclaim.manuallyPaused == true)
    #expect(done.wait(timeout: .now() + 2) == .success)

    // System sleep severs network, marks destroy-on-wake, and latches sleep interruption.
    control.handleSystemWillSleep()
    #expect(severed.withLock { $0 })
    #expect(markedWake.withLock { $0 })
}

@Test
func manualPauseRetriesDirectorySyncOnSubsequentCalls() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pause-sync-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let alias = directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    let control = ConnectedAgentControl(directory: alias, usingBattery: { false })
    #expect(throws: POSIXError.self) { try control.request("pause") }
    // Second call must STILL fail instead of falsely reporting durable success.
    #expect(throws: POSIXError.self) { try control.request("pause") }
}

@Test
func timedPauseExpiresAutomatically() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timed-pause-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Mutex(Date(timeIntervalSince1970: 2_000_000))
    let control = ConnectedAgentControl(
        directory: directory,
        powerStatus: { HostPowerStatus(source: .ac, batteryPercent: 100, lowPowerMode: false, drainingOnAC: false) },
        thermalState: { .nominal },
        isDarkWake: { false },
        currentDate: { now.withLock { $0 } },
        notificationName: nil
    )
    control.markReady()
    let cmd = try AgentControlRequest(action: "pause", durationSeconds: 1800).encodedCommand()
    let paused = try control.request(cmd)
    #expect(paused.paused && paused.pausedUntil != nil)
    now.withLock { $0 = $0.addingTimeInterval(1801) }
    #expect(!control.isPaused)
    #expect(control.beginAssignment(worker: "linux-0", platform: .linux))
}

@MainActor @Test
func companionSurfacesUnavailableDiagnosticsAndReclaimMenu() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-ux-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let report = AgentStatusReport(
        registration: .requiresApproval,
        configuration: nil,
        live: nil,
        unavailableReason: "unavailable",
        lastFailure: AgentReportedError(message: "Keychain locked")
    )
    let offlineModel = CompanionModel(
        request: { _ in throw AgentControlError.unavailable },
        loadDiagnostics: { report }
    )
    await offlineModel.update()
    #expect(offlineModel.admission == "Approval required in Login Items")
    #expect(offlineModel.unavailableReport?.lastFailure?.message == "Keychain locked")

    let control = ConnectedAgentControl(directory: directory, usingBattery: { false })
    control.markReady()
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024)
    control.configure(workers: [ConnectedWorker(backend: .linux(containerURL: URL(fileURLWithPath: "/usr/bin/true")), slot: 0)], memory: memory)
    #expect(control.beginAssignment(worker: "linux-0", platform: .linux))
    control.assign(worker: "linux-0", offer: testOfferLinux)
    control.recordWorkflowRun(worker: "linux-0", runID: 777)
    control.session(worker: "linux-0", state: .jobStarted(RunnerID(value: testOfferLinux.runner)))

    let onlineModel = CompanionModel(request: { try control.request($0) }, loadDiagnostics: { nil })
    await onlineModel.update()
    let delegate = CompanionDelegate(model: onlineModel)
    let menu = NSMenu()
    delegate.menuNeedsUpdate(menu)
    #expect(menu.item(withTitle: "Reclaim Compute Now") != nil)
    #expect(menu.item(withTitle: "Meeting Mode") != nil)
    let workerRow = try #require(menu.item(withTitle: "Linux"))
    let submenu = try #require(workerRow.submenu)
    #expect(submenu.item(withTitle: "Open GitHub Run…") != nil)
    #expect(submenu.item(withTitle: "Abort Job") != nil)
}
