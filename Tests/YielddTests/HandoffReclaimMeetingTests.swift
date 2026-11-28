import AppKit
import Foundation
import notify
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

    let aborted = Mutex<[(ConnectedExecutionError, String?)]>([])
    let severed = Mutex(false)
    let done = DispatchSemaphore(value: 0)
    control.registerSlotHandler(worker: "linux-0", handler: AgentSlotControlHandler(
        abort: { reason, expected in
            aborted.withLock { $0.append((reason, expected)) }
            done.signal()
            return true
        },
        severNetwork: { _ in severed.withLock { $0 = true } },
        applyCPUQuota: { _, _ in }
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
    #expect(aborted.withLock { $0.last?.0 == .reclaimed && $0.last?.1 == testOfferLinux.runner })

    // Global reclaim pauses durably and aborts active jobs.
    let afterReclaim = try control.request("reclaim")
    #expect(afterReclaim.paused && afterReclaim.manuallyPaused == true)
    #expect(done.wait(timeout: .now() + 2) == .success)

    // System sleep latches sleep interruption and severs network concurrently.
    control.handleSystemWillSleep()
    #expect(severed.withLock { $0 })
    #expect(aborted.withLock { $0.last?.0 == .sleepInterrupted })
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

@Test
func startupOwnershipLockPreventsDestroyingAnotherProcessGuest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-guard-\(UUID().uuidString)")
    let leaseStore = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ConnectedRunnerStore(directory: directory, platform: .linux, slot: 0)
    try store.save(ConnectedLease(server: "http://127.0.0.1:18080", deviceID: "01234567-89ab-4def-8123-456789abcdef", offer: testOfferLinux))

    let containerResolved = Mutex(false)
    let tokenLoaded = Mutex(false)
    try withRunnerOwnership(in: leaseStore.directory, connected: true) { _ in
        let stop = RunnerPoolStop()
        #expect(throws: RunnerOwnershipError.alreadyRunning) {
            try runConnectedService(
                server: URL(string: "http://127.0.0.1:18080")!,
                deviceID: "01234567-89ab-4def-8123-456789abcdef",
                loadToken: {
                    tokenLoaded.withLock { $0 = true }
                    return "token"
                },
                platforms: [.linux],
                template: nil,
                stop: stop,
                stateDirectory: directory,
                resolveContainer: {
                    containerResolved.withLock { $0 = true }
                    return URL(fileURLWithPath: "/usr/bin/true")
                }
            )
        }
    }
    #expect(!containerResolved.withLock { $0 })
    #expect(!tokenLoaded.withLock { $0 })
    #expect(try store.load() != nil)
}

@Test
func darkWakeCapabilitiesClassifierAndMonitorStopSafety() {
    #expect(!SystemPowerMonitor.isDarkWakeCapabilities(nil))
    #expect(!SystemPowerMonitor.isDarkWakeCapabilities(0x0))
    #expect(!SystemPowerMonitor.isDarkWakeCapabilities(0xF))  // CPU + Graphics + Audio + Network (full wake)
    #expect(!SystemPowerMonitor.isDarkWakeCapabilities(0x3))  // CPU + Graphics
    #expect(SystemPowerMonitor.isDarkWakeCapabilities(0x1))   // CPU only (DarkWake)
    #expect(SystemPowerMonitor.isDarkWakeCapabilities(0x5))   // CPU + Audio, no Graphics (DarkWake)

    let monitor = SystemPowerMonitor(onWillSleep: {}, onDidWake: {})
    _ = monitor.start()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        monitor.stop()
    }
}

@Test
func agentPowerSourceRefreshesAfterTTLExpiry() {
    let now = Mutex<TimeInterval>(100)
    let draining = Mutex(false)
    let source = AgentPowerSource(
        notifications: ["dev.yieldd.test.power.\(UUID().uuidString)"],
        refreshTTL: 10,
        observeLowPowerMode: false,
        currentTime: { now.withLock { $0 } },
        readStatus: {
            HostPowerStatus(source: .ac, batteryPercent: 90, lowPowerMode: false, drainingOnAC: draining.withLock { $0 })
        }
    )
    #expect(!source.status().drainingOnAC)
    draining.withLock { $0 = true }
    now.withLock { $0 = 105 }
    #expect(!source.status().drainingOnAC) // Still within 10s TTL
    now.withLock { $0 = 110 }
    #expect(source.status().drainingOnAC)  // Refreshed on TTL expiry
}

@Test
func authorizationPrepareAbortAnchoringAndGenerationIsolation() throws {
    // 1. Abort during /accept (after prepare, before start) latches and survives start().
    var now: TimeInterval = 100
    let auth = ConnectedExecutionAuthorization(
        renewWithMetadata: { _, _ in ConnectedAuthorizationRenewal(shouldContinue: true) },
        checkCancellation: {},
        currentTime: { now },
        initialOfflineGrace: 60
    )
    auth.prepare(runner: testOfferLinux.runner)
    #expect(auth.abort(reason: .reclaimed, expectedRunner: testOfferLinux.runner))
    auth.start(testOfferLinux)
    #expect(throws: ConnectedExecutionError.reclaimed) { try auth.check() }
    auth.stop()

    // 2. markJobStarted anchors deadline to lastAuthorizedAt + 300, never now + 300.
    now = 100
    let auth2 = ConnectedExecutionAuthorization(
        renewWithMetadata: { _, _ in throw ConnectedRunnerError.transport },
        checkCancellation: {},
        currentTime: { now },
        initialOfflineGrace: 60
    )
    auth2.start(testOfferLinux) // lastAuthorizedAt = 100, deadline = 160
    now = 155
    auth2.markJobStarted()      // deadline must become 100 + 300 = 400 (NOT 155 + 300 = 455)
    now = 399
    try auth2.check()
    now = 400
    #expect(throws: ConnectedExecutionError.expired) { try auth2.check() }
    auth2.stop()

    // 3. Late renewal from job A cannot revoke or leak workflowRunID onto job B.
    let renewalStarted = DispatchSemaphore(value: 0)
    let allowRenewalFinish = DispatchSemaphore(value: 0)
    let leakedRuns = Mutex<[Int64]>([])
    let auth3 = ConnectedExecutionAuthorization(
        renewWithMetadata: { offer, _ in
            if offer.runner == testOfferLinux.runner {
                renewalStarted.signal()
                _ = allowRenewalFinish.wait(timeout: .now() + 5)
                return ConnectedAuthorizationRenewal(shouldContinue: false, workflowRunID: 99999)
            }
            return ConnectedAuthorizationRenewal(shouldContinue: true)
        },
        checkCancellation: {},
        currentTime: { 100 },
        onWorkflowRunID: { id in leakedRuns.withLock { $0.append(id) } }
    )
    auth3.start(testOfferLinux)
    let threadDone = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = try? auth3.check()
        threadDone.signal()
    }
    #expect(renewalStarted.wait(timeout: .now() + 2) == .success)
    auth3.stop()
    auth3.start(testOfferLinuxSecond)
    allowRenewalFinish.signal()
    #expect(threadDone.wait(timeout: .now() + 2) == .success)
    try auth3.check()
    #expect(leakedRuns.withLock { $0 }.isEmpty)
}

@Test
func meetingModeBatteryGateTimerPreservationAndLiveThermalReconciliation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-reconcile-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let power = Mutex(HostPowerStatus(source: .battery, batteryPercent: 80, lowPowerMode: false, drainingOnAC: false))
    let thermal = Mutex(HostThermalState.nominal)
    let now = Mutex(Date(timeIntervalSince1970: 3_000_000))

    let control = ConnectedAgentControl(
        directory: directory,
        powerStatus: { power.withLock { $0 } },
        thermalState: { thermal.withLock { $0 } },
        isDarkWake: { false },
        currentDate: { now.withLock { $0 } },
        hardwareProfile: HostHardwareProfile(modelIdentifier: "Mac16,7", logicalCPUs: 16),
        notificationName: nil
    )
    control.markReady()
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024)
    control.configure(workers: [ConnectedWorker(backend: .linux(containerURL: URL(fileURLWithPath: "/usr/bin/true")), slot: 0)], memory: memory)

    // With pauseOnBattery == false, Meeting Mode still denies battery admissions.
    let enable = try AgentControlRequest(action: "meeting-mode", durationSeconds: 1800, enabled: true, cpus: 4).encodedCommand()
    let snapOnBattery = try control.request(enable)
    #expect(snapOnBattery.pauseOnBattery == false)
    #expect(snapOnBattery.pausedByBattery == true)
    #expect(snapOnBattery.admissionReasons?.contains(.battery) == true)
    #expect(!control.canPoll(platform: .linux))

    // Switch to AC power and start a Linux assignment.
    power.withLock { $0 = HostPowerStatus(source: .ac, batteryPercent: 80, lowPowerMode: false, drainingOnAC: false) }
    #expect(control.beginAssignment(worker: "linux-0", platform: .linux))
    control.assign(worker: "linux-0", offer: testOfferLinux)

    let appliedQuotas = Mutex<[Int]>([])
    let quotaEvent = DispatchSemaphore(value: 0)
    control.registerSlotHandler(worker: "linux-0", handler: AgentSlotControlHandler(
        abort: { _, _ in true },
        severNetwork: { _ in },
        applyCPUQuota: { cpus, _ in
            appliedQuotas.withLock { $0.append(cpus) }
            quotaEvent.signal()
        }
    ))

    // CPU-only change (enabled: nil) preserves active meetingMode and meetingModeUntil.
    let originalUntil = try #require(snapOnBattery.meetingModeUntil)
    let cpuOnly = try AgentControlRequest(action: "meeting-mode", cpus: 2).encodedCommand()
    let afterCPU = try control.request(cpuOnly)
    #expect(afterCPU.meetingMode == true)
    #expect(afterCPU.meetingModeUntil == originalUntil)
    #expect(afterCPU.meetingModeConfiguredCPUs == 2)
    #expect(afterCPU.meetingModeCPUs == 2)
    #expect(quotaEvent.wait(timeout: .now() + 2) == .success)
    #expect(appliedQuotas.withLock { $0.last } == 2)

    // Switch back to 4 vCPUs, then transition thermal -> .fair and verify live step-down to 2.
    _ = try control.request(try AgentControlRequest(action: "meeting-mode", cpus: 4).encodedCommand())
    #expect(quotaEvent.wait(timeout: .now() + 2) == .success)
    #expect(appliedQuotas.withLock { $0.last } == 4)

    thermal.withLock { $0 = .fair }
    control.reconcilePolicies()
    #expect(quotaEvent.wait(timeout: .now() + 2) == .success)
    #expect(appliedQuotas.withLock { $0.last } == 2)
    let cappedSnap = control.snapshot
    #expect(cappedSnap.meetingModeConfiguredCPUs == 4)
    #expect(cappedSnap.meetingModeCPUs == 2)

    // Advance past meetingModeUntil and verify running Linux guest is restored to 4 vCPUs.
    thermal.withLock { $0 = .nominal }
    now.withLock { $0 = originalUntil.addingTimeInterval(5) }
    control.reconcilePolicies()
    #expect(quotaEvent.wait(timeout: .now() + 2) == .success)
    #expect(appliedQuotas.withLock { $0.last } == 4)
    #expect(control.snapshot.meetingMode == false)
}

@Test
func sleepHandlerLatchesAbortFirstAndBoundsParallelRelaySevers() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-order-\(UUID().uuidString)")
    _ = try? RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let control = ConnectedAgentControl(directory: directory, usingBattery: { false })
    let events = Mutex<[String]>([])
    for slot in 0..<4 {
        control.registerSlotHandler(worker: "linux-\(slot)", handler: AgentSlotControlHandler(
            abort: { reason, _ in
                events.withLock { $0.append("abort-\(slot)-\(reason)") }
                return true
            },
            severNetwork: { _ in
                events.withLock { $0.append("sever-\(slot)") }
                Thread.sleep(forTimeInterval: 1.5)
            },
            applyCPUQuota: { _, _ in }
        ))
    }

    let start = continuousMonotonicSeconds()
    control.handleSystemWillSleep()
    let elapsed = continuousMonotonicSeconds() - start
    #expect(elapsed < 1.4)

    let recorded = events.withLock { $0 }
    // All 4 aborts must be latched before any severNetwork finishes/runs in parallel.
    #expect(recorded.prefix(4).allSatisfy { $0.hasPrefix("abort-") })
}

@Test
func appleContainerGracefulStopRunsEvenWhenCancelled() throws {
    final class RecordingExecutor: ProcessExecuting, @unchecked Sendable {
        let requests = Mutex<[ProcessRequest]>([])
        func execute(_ request: ProcessRequest) throws -> ProcessResult {
            requests.withLock { $0.append(request) }
            if request.arguments.starts(with: ["machine", "inspect"]) {
                let id = request.arguments[2]
                let socket = requests.withLock {
                    $0.first(where: { $0.arguments.starts(with: ["machine", "create"]) })
                        .flatMap { req -> String? in
                            guard let idx = req.arguments.firstIndex(of: "--network-socket"),
                                  idx + 1 < req.arguments.count else { return nil }
                            return req.arguments[idx + 1]
                        } ?? ""
                }
                let json = "[{\"id\":\"\(id)\",\"homeMount\":\"none\",\"networkSocket\":\"\(socket)\"}]"
                return ProcessResult(stdout: Data(json.utf8), stderr: Data(), terminationReason: .exit, terminationStatus: 0)
            }
            return ProcessResult(stdout: Data(), stderr: Data(), terminationReason: .exit, terminationStatus: 0)
        }
    }
    final class DummyRelay: RunnerNetworkRelaying, @unchecked Sendable {
        let socketURL: URL
        let sshSocketURL: URL
        init(socketURL: URL, sshSocketURL: URL) {
            self.socketURL = socketURL
            self.sshSocketURL = sshSocketURL
        }
        var isRunning: Bool { true }
        func check() throws {}
        func stop(deadline: DispatchTime?) throws {}
    }
    struct DummyNetwork: RunnerNetworking {
        let dir: URL
        func start(for id: RunnerID, checkCancellation: () throws -> Void) throws -> any RunnerNetworkRelaying {
            DummyRelay(socketURL: dir.appendingPathComponent("relay.sock"), sshSocketURL: dir.appendingPathComponent("ssh.sock"))
        }
    }

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("graceful-stop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let cancelled = Mutex(false)
    let executor = RecordingExecutor()
    let backend = try AppleContainerBackend(
        containerURL: URL(fileURLWithPath: "/usr/bin/true"),
        executor: executor,
        stateDirectory: dir,
        loadStorage: { nil },
        network: DummyNetwork(dir: dir),
        checkCancellation: { if cancelled.withLock({ $0 }) { throw CancellationError() } },
        dockerReadiness: DockerReadiness(wait: { _ in }, checkCancellation: {})
    )
    let id = RunnerID(value: testOfferLinux.runner)
    try backend.create(id: id, memory: .full)

    // Cancel authorization / pool stop, then verify gracefulStopRunner still issues non-cancellable stop.
    cancelled.withLock { $0 = true }
    backend.gracefulStopRunner(id)

    let stopRequests = executor.requests.withLock { list in
        list.filter { $0.arguments.suffix(2) == ["yieldd-runner-control", "stop"] }
    }
    #expect(stopRequests.count == 1)
    #expect(stopRequests[0].cancellable == false)
}

@Test
func hoistedSlotReservationIsReleasedOnRecoveryAfterNonTransientCleanupFailure() throws {
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024)
    let slotReservation = ConnectedSlotReservation()
    var runAttempts = 0
    var recoverAttempts = 0
    struct CleanupBoom: Error {}

    // First runConnectedClient exits with a non-transient cleanup failure, leaving reservation held.
    #expect(throws: CleanupBoom.self) {
        try runConnectedClient(
            checkCancellation: {},
            recover: { recoverAttempts += 1 },
            acquire: { try memory.tryAcquire(reserving: RunnerPlatform.linux.memoryReservationBytes) },
            release: memory.release,
            poll: { runAttempts == 0 ? testOfferLinux : nil },
            decline: { _ in },
            run: { _, _, _ in
                runAttempts += 1
                throw CleanupBoom()
            },
            wait: { _ in },
            retrying: { _ in },
            slotReservation: slotReservation
        )
    }
    #expect(memory.status.reservedBytes == RunnerPlatform.linux.memoryReservationBytes)
    #expect(slotReservation.reservation != nil)

    // Next loop iteration recovers and releases the exact hoisted reservation back to 0.
    #expect(throws: CancellationError.self) {
        try runConnectedClient(
            checkCancellation: {
                if recoverAttempts >= 2 { throw CancellationError() }
            },
            recover: { recoverAttempts += 1 },
            acquire: { nil },
            release: memory.release,
            poll: { nil },
            decline: { _ in },
            run: { _, _, _ in },
            wait: { _ in },
            retrying: { _ in },
            slotReservation: slotReservation
        )
    }
    #expect(memory.status.reservedBytes == 0)
    #expect(slotReservation.reservation == nil)
}

@Test
func connectedRunnerValidatesProtocolBeforeCPUQuotaAndToleratesExit2() throws {
    final class OrderedBackend: RunnerBackend {
        let platform = RunnerPlatform.linux
        var steps: [String] = []
        func create(id: RunnerID, memory: RunnerMemoryAllocation) throws { steps.append("create") }
        func exec(_ arguments: [String], standardInput: Data?, timeout: TimeInterval?,
                  outputCapture: ProcessOutputCapture, as user: RunnerGuestUser, on id: RunnerID) throws -> ProcessResult {
            if arguments.count == 2 && arguments[1] == "--protocol-version" {
                steps.append("protocol-\(arguments[0])")
                return ProcessResult(stdout: Data("2\n".utf8), stderr: Data(), terminationReason: .exit, terminationStatus: 0)
            }
            if arguments.first == "yieldd-configure-runner" {
                steps.append("configure")
                return ProcessResult(stdout: Data(), stderr: Data(), terminationReason: .exit, terminationStatus: 0)
            }
            if arguments == ["yieldd-runner-control", "start"] {
                steps.append("start")
                return ProcessResult(stdout: Data(), stderr: Data(), terminationReason: .exit, terminationStatus: 0)
            }
            if arguments == ["yieldd-runner-control", "status"] {
                return ProcessResult(stdout: Data("{\"phase\":\"exited\",\"jobStarted\":true,\"exitStatus\":0}\n".utf8),
                                     stderr: Data(), terminationReason: .exit, terminationStatus: 0)
            }
            return ProcessResult(stdout: Data(), stderr: Data(), terminationReason: .exit, terminationStatus: 0)
        }
        func applyCPUQuota(_ cpus: Int, on id: RunnerID) throws {
            steps.append("cpu-\(cpus)")
            let req = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["cpu"])
            let res = ProcessResult(stdout: Data(), stderr: Data("usage\n".utf8), terminationReason: .exit, terminationStatus: 2)
            throw ProcessExecutionError.nonZeroExit(request: req, result: res)
        }
        func destroy(_ id: RunnerID) throws { steps.append("destroy") }
    }

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-compat-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    let backend = OrderedBackend()
    let store = ConnectedRunnerStore(directory: dir, platform: .linux, slot: 0)
    let auth = ConnectedExecutionAuthorization(renew: { _, _ in true }, checkCancellation: {})
    var warnings: [String] = []
    let runner = ConnectedRunner(
        backend: backend,
        store: store,
        server: "http://127.0.0.1:18080",
        deviceID: "01234567-89ab-4def-8123-456789abcdef",
        accept: { _ in
            let runnerJSON = try JSONSerialization.data(withJSONObject: [
                "AgentName": testOfferLinux.runner,
                "WorkFolder": "_work",
                "Ephemeral": "True",
            ]).base64EncodedString()
            return try JSONEncoder().encode([".runner": runnerJSON, ".credentials": "e30="]).base64EncodedString()
        },
        complete: { _ in },
        authorization: auth,
        wait: { _ in },
        initialLinuxCPUs: { 2 },
        onWarning: { warnings.append($0) }
    )
    try runner.run(testOfferLinux, memory: .full)

    let protocolIndex = try #require(backend.steps.lastIndex(where: { $0.hasPrefix("protocol-") }))
    let cpuIndex = try #require(backend.steps.firstIndex(of: "cpu-2"))
    let configureIndex = try #require(backend.steps.firstIndex(of: "configure"))
    #expect(protocolIndex < cpuIndex)
    #expect(cpuIndex < configureIndex)
    #expect(warnings.count == 1)
    #expect(warnings[0].contains("does not support runtime CPU quotas"))
}

@Test
func idleWorkerUpdatesDoNotSpamStateChangeNotifications() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notify-spam-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    let notificationName = "dev.yieldd.test.state.\(UUID().uuidString)"
    let count = Mutex(0)
    var token: Int32 = 0
    let queue = DispatchQueue(label: "dev.yieldd.test.notify")
    #expect(notify_register_dispatch(notificationName, &token, queue) { _ in
        count.withLock { $0 += 1 }
    } == NOTIFY_STATUS_OK)
    defer { notify_cancel(token) }

    let control = ConnectedAgentControl(directory: dir, notificationName: notificationName)
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024)
    control.configure(workers: [ConnectedWorker(backend: .linux(containerURL: URL(fileURLWithPath: "/usr/bin/true")), slot: 0)], memory: memory)
    control.connection(worker: "linux-0", state: .connected, error: nil)
    control.update(worker: "linux-0", phase: .idle)

    Thread.sleep(forTimeInterval: 0.1)
    let baseline = count.withLock { $0 }

    // Repeated unchanged idle/connected updates must not post notifications.
    for _ in 0..<20 {
        control.update(worker: "linux-0", phase: .idle)
        control.connection(worker: "linux-0", state: .connected, error: nil)
    }
    Thread.sleep(forTimeInterval: 0.1)
    #expect(count.withLock { $0 } == baseline)
}

@Test
func meetingModeQuotaWritesAreSerializedBoundToRunnerAndRestoredOnThermalAndTimerExpiry() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quota-serial-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    let thermal = Mutex(HostThermalState.nominal)
    let now = Mutex(Date(timeIntervalSince1970: 4_000_000))
    let control = ConnectedAgentControl(
        directory: dir,
        powerStatus: { HostPowerStatus(source: .ac, batteryPercent: 100, lowPowerMode: false, drainingOnAC: false) },
        thermalState: { thermal.withLock { $0 } },
        isDarkWake: { false },
        currentDate: { now.withLock { $0 } },
        notificationName: nil
    )
    control.markReady()
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024)
    control.configure(workers: [ConnectedWorker(backend: .linux(containerURL: URL(fileURLWithPath: "/usr/bin/true")), slot: 0)], memory: memory)
    #expect(control.beginAssignment(worker: "linux-0", platform: .linux, offer: testOfferLinux))

    let firstStarted = DispatchSemaphore(value: 0)
    let allowFirstFinish = DispatchSemaphore(value: 0)
    let applied = Mutex<[(Int, String?)]>([])
    let done = DispatchSemaphore(value: 0)
    let blockFirst = Mutex(true)

    control.registerSlotHandler(worker: "linux-0", handler: AgentSlotControlHandler(
        abort: { _, _ in true },
        severNetwork: { _ in },
        applyCPUQuota: { cpus, runner in
            if cpus == 2 && blockFirst.withLock({ $0 }) {
                blockFirst.withLock { $0 = false }
                firstStarted.signal()
                _ = allowFirstFinish.wait(timeout: .now() + 5)
            }
            applied.withLock { $0.append((cpus, runner)) }
            done.signal()
        }
    ))

    // CPU-only change while Meeting Mode is OFF must not invoke applyCPUQuota.
    _ = try control.request(try AgentControlRequest(action: "meeting-mode", cpus: 2).encodedCommand())
    Thread.sleep(forTimeInterval: 0.05)
    #expect(applied.withLock { $0 }.isEmpty)

    // Enable Meeting Mode (2 vCPUs) and hold that write in flight while disabling Meeting Mode (4 vCPUs).
    _ = try control.request(try AgentControlRequest(action: "meeting-mode", enabled: true, cpus: 2).encodedCommand())
    #expect(firstStarted.wait(timeout: .now() + 2) == .success)
    _ = try control.request(try AgentControlRequest(action: "meeting-mode", enabled: false).encodedCommand())
    allowFirstFinish.signal()

    #expect(done.wait(timeout: .now() + 2) == .success)
    #expect(done.wait(timeout: .now() + 2) == .success)
    let history = applied.withLock { $0 }
    #expect(history.count == 2)
    #expect(history[0].0 == 2 && history[0].1 == testOfferLinux.runner)
    #expect(history[1].0 == 4 && history[1].1 == testOfferLinux.runner)

    // Thermal hold-down expiry restores running Linux guest from 2 back to 4 vCPUs.
    _ = try control.request(try AgentControlRequest(action: "meeting-mode", enabled: true, cpus: 4).encodedCommand())
    #expect(done.wait(timeout: .now() + 2) == .success)
    thermal.withLock { $0 = .fair }
    control.reconcilePolicies()
    #expect(done.wait(timeout: .now() + 2) == .success)
    #expect(applied.withLock { $0.last?.0 } == 2)

    thermal.withLock { $0 = .nominal }
    now.withLock { $0 = $0.addingTimeInterval(601) }
    control.reconcilePolicies()
    #expect(done.wait(timeout: .now() + 2) == .success)
    #expect(applied.withLock { $0.last?.0 } == 4)
}

@Test
func timedMeetingModeExpiresAutomaticallyViaScheduledTimer() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-timer-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    let control = ConnectedAgentControl(
        directory: dir,
        powerStatus: { HostPowerStatus(source: .ac, batteryPercent: 100, lowPowerMode: false, drainingOnAC: false) },
        thermalState: { .nominal },
        isDarkWake: { false },
        notificationName: nil
    )
    control.markReady()
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024)
    control.configure(workers: [ConnectedWorker(backend: .linux(containerURL: URL(fileURLWithPath: "/usr/bin/true")), slot: 0)], memory: memory)
    #expect(control.beginAssignment(worker: "linux-0", platform: .linux, offer: testOfferLinux))

    let restored = DispatchSemaphore(value: 0)
    let applied = Mutex<[Int]>([])
    control.registerSlotHandler(worker: "linux-0", handler: AgentSlotControlHandler(
        abort: { _, _ in true },
        severNetwork: { _ in },
        applyCPUQuota: { cpus, _ in
            applied.withLock { $0.append(cpus) }
            if cpus == 4 { restored.signal() }
        }
    ))

    _ = try control.request(try AgentControlRequest(action: "meeting-mode", durationSeconds: 0.1, enabled: true, cpus: 2).encodedCommand())
    // Do NOT poll snapshot or canPoll — the scheduled timer must automatically expire and restore 4 vCPUs.
    #expect(restored.wait(timeout: .now() + 3) == .success)
    #expect(control.snapshot.meetingMode == false)
    #expect(applied.withLock { $0.last } == 4)
}

@Test
func foregroundSleepCoordinatorAbortsSeversAndEnforcesWakeHoldDown() throws {
    let now = Mutex(Date(timeIntervalSince1970: 5_000_000))
    let coordinator = ConnectedSleepCoordinator(currentDate: { now.withLock { $0 } })
    let auth = ConnectedExecutionAuthorization(renew: { _, _ in true }, checkCancellation: {})
    let severed = Mutex(false)
    coordinator.register(worker: "linux-0", handler: AgentSlotControlHandler(
        abort: { reason, expected in auth.abort(reason: reason, expectedRunner: expected) },
        severNetwork: { _ in severed.withLock { $0 = true } },
        applyCPUQuota: { _, _ in }
    ))

    // Prepare runner atomically before admission; sleep immediately after admission must abort it.
    auth.prepare(runner: testOfferLinux.runner)
    #expect(coordinator.beginAssignment())
    coordinator.handleSystemWillSleep()
    #expect(severed.withLock { $0 })
    #expect(throws: ConnectedExecutionError.sleepInterrupted) { try auth.check() }
    #expect(coordinator.isPausedForWake())
    #expect(!coordinator.beginAssignment())

    // Hold-down expires after 30s.
    now.withLock { $0 = $0.addingTimeInterval(31) }
    #expect(!coordinator.isPausedForWake())
    #expect(coordinator.beginAssignment())
}
