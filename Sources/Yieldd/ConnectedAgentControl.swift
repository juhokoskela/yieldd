import ArgumentParser
import Darwin
import Foundation
import notify
import Synchronization

let agentStateChangedNotification = "dev.yieldd.agent.stateChanged"

struct AgentControlSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let instanceID: UUID
    let resumeGeneration: UInt64
    let paused: Bool
    let ready: Bool
    let activeAssignments: Int
    let recordedAt: Date
    let phase: AgentServicePhase
    let server: String?
    let deviceID: String?
    let memory: RunnerMemoryStatus?
    let workers: [AgentWorkerStatus]
    let lastError: AgentReportedError?

    let pauseOnBattery: Bool?
    let pausedByBattery: Bool?
    let manuallyPaused: Bool?

    let admissionReasons: [AgentAdmissionReason]?
    let pausedUntil: Date?
    let meetingMode: Bool?
    let meetingModeUntil: Date?
    let meetingModeCPUs: Int?
    let meetingModeConfiguredCPUs: Int?
    let hostPower: HostPowerStatus?
    let thermalState: HostThermalState?

    var drained: Bool { ready && paused && activeAssignments == 0 }

    init(
        version: Int,
        instanceID: UUID,
        resumeGeneration: UInt64,
        paused: Bool,
        ready: Bool,
        activeAssignments: Int,
        recordedAt: Date,
        phase: AgentServicePhase,
        server: String?,
        deviceID: String?,
        memory: RunnerMemoryStatus?,
        workers: [AgentWorkerStatus],
        lastError: AgentReportedError?,
        pauseOnBattery: Bool? = nil,
        pausedByBattery: Bool? = nil,
        manuallyPaused: Bool? = nil,
        admissionReasons: [AgentAdmissionReason]? = nil,
        pausedUntil: Date? = nil,
        meetingMode: Bool? = nil,
        meetingModeUntil: Date? = nil,
        meetingModeCPUs: Int? = nil,
        meetingModeConfiguredCPUs: Int? = nil,
        hostPower: HostPowerStatus? = nil,
        thermalState: HostThermalState? = nil
    ) {
        self.version = version
        self.instanceID = instanceID
        self.resumeGeneration = resumeGeneration
        self.paused = paused
        self.ready = ready
        self.activeAssignments = activeAssignments
        self.recordedAt = recordedAt
        self.phase = phase
        self.server = server
        self.deviceID = deviceID
        self.memory = memory
        self.workers = workers
        self.lastError = lastError
        self.pauseOnBattery = pauseOnBattery
        self.pausedByBattery = pausedByBattery
        self.manuallyPaused = manuallyPaused
        self.admissionReasons = admissionReasons
        self.pausedUntil = pausedUntil
        self.meetingMode = meetingMode
        self.meetingModeUntil = meetingModeUntil
        self.meetingModeCPUs = meetingModeCPUs
        self.meetingModeConfiguredCPUs = meetingModeConfiguredCPUs
        self.hostPower = hostPower
        self.thermalState = thermalState
    }
}

struct AgentControlRequest: Codable, Equatable, Sendable {
    let version: Int
    let action: String
    let durationSeconds: TimeInterval?
    let enabled: Bool?
    let cpus: Int?
    let worker: String?
    let runner: String?

    init(action: String, durationSeconds: TimeInterval? = nil, enabled: Bool? = nil,
         cpus: Int? = nil, worker: String? = nil, runner: String? = nil) {
        self.version = 1
        self.action = action
        self.durationSeconds = durationSeconds
        self.enabled = enabled
        self.cpus = cpus
        self.worker = worker
        self.runner = runner
    }

    func encodedCommand() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

private struct AgentPersistedPolicy: Codable, Equatable {
    var pausedUntil: Date?
    var meetingMode: Bool = false
    var meetingModeUntil: Date?
    var meetingModeCPUs: Int?
}

struct AgentSlotControlHandler: Sendable {
    let abort: @Sendable (ConnectedExecutionError, String?) -> Bool
    let severNetwork: @Sendable (DispatchTime) -> Void
    let applyCPUQuota: @Sendable (Int, String?) -> Void
}

/// Shared sleep/wake coordination used by both the installed agent control and foreground `yieldd connect`.
final class ConnectedSleepCoordinator: @unchecked Sendable {
    static let wakeHoldDownDuration: TimeInterval = 30
    private let lock = NSLock()
    private let currentDate: @Sendable () -> Date
    private var wakeHoldDownUntil: Date?
    private var handlers: [String: AgentSlotControlHandler] = [:]

    init(currentDate: @escaping @Sendable () -> Date = Date.init) {
        self.currentDate = currentDate
    }

    func register(worker: String, handler: AgentSlotControlHandler) {
        lock.withLock { handlers[worker] = handler }
    }

    func unregister(worker: String) {
        lock.withLock { _ = handlers.removeValue(forKey: worker) }
    }

    func isPausedForWake() -> Bool {
        lock.withLock {
            guard let until = wakeHoldDownUntil else { return false }
            if currentDate() >= until {
                wakeHoldDownUntil = nil
                return false
            }
            return true
        }
    }

    func beginAssignment() -> Bool {
        !isPausedForWake()
    }

    func handleSystemWillSleep() {
        let activeHandlers: [AgentSlotControlHandler] = lock.withLock {
            wakeHoldDownUntil = currentDate().addingTimeInterval(Self.wakeHoldDownDuration)
            return Array(handlers.values)
        }
        Self.abortAndSever(activeHandlers)
    }

    func handleSystemDidWake() {
        lock.withLock {
            wakeHoldDownUntil = currentDate().addingTimeInterval(Self.wakeHoldDownDuration)
        }
    }

    static func abortAndSever(_ handlers: [AgentSlotControlHandler]) {
        // Latch sleep interruption on every slot synchronously first so no guest can
        // pass an authorization check after wake.
        for handler in handlers {
            _ = handler.abort(.sleepInterrupted, nil)
        }
        // Sever all active relays concurrently under a single shared deadline so
        // multiple active slots remain bounded within the sleep-callback budget.
        guard !handlers.isEmpty else { return }
        let sharedDeadline = DispatchTime.now() + .milliseconds(800)
        let group = DispatchGroup()
        for handler in handlers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                handler.severNetwork(sharedDeadline)
                group.leave()
            }
        }
        _ = group.wait(timeout: sharedDeadline)
    }
}

// The lock serializes admission with pause/meeting/reclaim and owns the assignment set.
final class ConnectedAgentControl: @unchecked Sendable {
    static let wakeHoldDownDuration: TimeInterval = 30
    static let thermalHoldDownDuration: TimeInterval = 10 * 60

    private let lock = NSLock()
    private let quotaQueue = DispatchQueue(label: "dev.yieldd.agent.quota", qos: .userInitiated)
    private let policyTimerQueue = DispatchQueue(label: "dev.yieldd.agent.timer")
    private let pauseFile: URL
    private let batteryPolicyFile: URL
    private let policyFile: URL
    private let powerStatus: @Sendable () -> HostPowerStatus
    private let thermalStateProvider: @Sendable () -> HostThermalState
    private let isDarkWakeProvider: @Sendable () -> Bool
    private let currentDate: @Sendable () -> Date
    private let hardwareProfile: HostHardwareProfile
    private let stateChangedNotificationName: String?

    private var pauseOnBattery: Bool
    private var paused: Bool
    private var pausedUntil: Date?
    private var meetingMode: Bool
    private var meetingModeUntil: Date?
    private var meetingModeCPUs: Int
    private var wakeHoldDownUntil: Date?
    private var thermalHoldDownUntil: Date?
    private var thermalCappedToTwo = false
    private var policyTimer: DispatchSourceTimer?
    private var scheduledTimerDeadline: Date?

    private let instanceID = UUID()
    private var resumeGeneration: UInt64 = 0
    private var assignments: Set<String> = []
    private var phase: AgentServicePhase = .starting
    private let server: String?
    private let deviceID: String?
    private var memory: RunnerMemoryAdmission?
    private var workers: [String: AgentWorkerStatus] = [:]
    private var slotHandlers: [String: AgentSlotControlHandler] = [:]
    private var lastError: AgentReportedError?
    private var thermalObserver: (any NSObjectProtocol)?

    convenience init(directory: URL, configuration: ConnectedAgentConfiguration? = nil,
                     usingBattery: @escaping @Sendable () -> Bool) {
        self.init(
            directory: directory,
            configuration: configuration,
            powerStatus: {
                HostPowerStatus(source: usingBattery() ? .battery : .ac, batteryPercent: nil, lowPowerMode: false, drainingOnAC: false)
            },
            thermalState: { .nominal },
            isDarkWake: { false },
            notificationName: nil
        )
    }

    init(directory: URL, configuration: ConnectedAgentConfiguration? = nil,
         powerStatus: @escaping @Sendable () -> HostPowerStatus = AgentPowerSource.system.status,
         thermalState: @escaping @Sendable () -> HostThermalState = { HostThermalState(ProcessInfo.processInfo.thermalState) },
         isDarkWake: @escaping @Sendable () -> Bool = SystemPowerMonitor.isDarkWake,
         currentDate: @escaping @Sendable () -> Date = Date.init,
         hardwareProfile: HostHardwareProfile = .current,
         notificationName: String? = agentStateChangedNotification) {
        server = configuration?.server.absoluteString
        deviceID = configuration?.deviceID
        pauseFile = directory.appendingPathComponent("connected-agent.paused")
        batteryPolicyFile = directory.appendingPathComponent("connected-agent.pause-on-battery")
        policyFile = directory.appendingPathComponent("connected-agent-policy.json")
        self.powerStatus = powerStatus
        self.thermalStateProvider = thermalState
        self.isDarkWakeProvider = isDarkWake
        self.currentDate = currentDate
        self.hardwareProfile = hardwareProfile
        self.stateChangedNotificationName = notificationName
        var info = stat()
        pauseOnBattery = Darwin.lstat(batteryPolicyFile.path, &info) == 0 || errno != ENOENT
        paused = Darwin.lstat(pauseFile.path, &info) == 0 || errno != ENOENT
        let persisted = Self.loadPolicy(at: policyFile)
        pausedUntil = persisted?.pausedUntil
        meetingMode = persisted?.meetingMode ?? false
        meetingModeUntil = persisted?.meetingModeUntil
        let configuredCPUs = persisted?.meetingModeCPUs ?? hardwareProfile.defaultMeetingModeCPUs
        meetingModeCPUs = configuredCPUs == 4 ? 4 : 2
        if notificationName != nil {
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.reconcilePolicies()
            }
        }
        lock.withLock {
            reschedulePolicyTimerUnlocked(now: currentDate())
        }
    }

    deinit {
        policyTimer?.cancel()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    var snapshot: AgentControlSnapshot {
        let (result, actions, stateChanged) = lock.withLock { () -> (AgentControlSnapshot, [@Sendable () -> Void], Bool) in
            var actions: [@Sendable () -> Void] = []
            var stateChanged = false
            let snap = snapshotUnlocked(quotaActions: &actions, stateChanged: &stateChanged)
            return (snap, actions, stateChanged)
        }
        dispatchQuotaActions(actions)
        if stateChanged { notifyStateChanged() }
        return result
    }

    var isPaused: Bool {
        let (paused, actions, stateChanged) = lock.withLock { () -> (Bool, [@Sendable () -> Void], Bool) in
            var actions: [@Sendable () -> Void] = []
            var stateChanged = false
            let result = isPausedUnlocked(
                now: currentDate(),
                power: powerStatus(),
                thermal: thermalStateProvider(),
                darkWake: isDarkWakeProvider(),
                quotaActions: &actions,
                stateChanged: &stateChanged
            )
            return (result, actions, stateChanged)
        }
        dispatchQuotaActions(actions)
        if stateChanged { notifyStateChanged() }
        return paused
    }

    var effectiveLinuxCPUs: Int {
        let (cpus, actions, stateChanged) = lock.withLock { () -> (Int, [@Sendable () -> Void], Bool) in
            var actions: [@Sendable () -> Void] = []
            let now = currentDate()
            let thermal = thermalStateProvider()
            let expired = expireTimersUnlocked(now: now, thermal: thermal, quotaActions: &actions)
            guard meetingMode else { return (AppleContainerBackend.virtualCPUs, actions, expired) }
            let thermalChanged = updateThermalGuardUnlocked(now: now, thermal: thermal, quotaActions: &actions)
            let target = thermalCappedToTwo ? min(meetingModeCPUs, 2) : meetingModeCPUs
            return (target, actions, expired || thermalChanged)
        }
        dispatchQuotaActions(actions)
        if stateChanged { notifyStateChanged() }
        return cpus
    }

    /// Re-evaluates timed pauses, Meeting Mode expiry, and thermal state transitions,
    /// pushing any required CPU quota adjustments to active Linux runners.
    func reconcilePolicies() {
        let (actions, stateChanged) = lock.withLock { () -> ([@Sendable () -> Void], Bool) in
            var actions: [@Sendable () -> Void] = []
            let now = currentDate()
            let thermal = thermalStateProvider()
            let expired = expireTimersUnlocked(now: now, thermal: thermal, quotaActions: &actions)
            let thermalChanged = updateThermalGuardUnlocked(now: now, thermal: thermal, quotaActions: &actions)
            reschedulePolicyTimerUnlocked(now: now)
            return (actions, expired || thermalChanged)
        }
        dispatchQuotaActions(actions)
        if stateChanged { notifyStateChanged() }
    }

    func starting() {
        lock.withLock { if phase != .stopping { phase = .starting } }
        notifyStateChanged()
    }

    func markReady() {
        lock.withLock {
            guard phase != .stopping else { return }
            phase = .ready
        }
        notifyStateChanged()
    }

    func configure(workers slots: [ConnectedWorker], memory: RunnerMemoryAdmission) {
        lock.withLock {
            self.memory = memory
            precondition(assignments.isEmpty)
            workers = Dictionary(uniqueKeysWithValues: slots.map { worker in
                let id = worker.id
                return (id, AgentWorkerStatus(id: id, platform: worker.backend.platform, slot: worker.slot))
            })
        }
        notifyStateChanged()
    }

    func registerSlotHandler(worker: String, handler: AgentSlotControlHandler) {
        lock.withLock { slotHandlers[worker] = handler }
    }

    func unregisterSlotHandler(worker: String) {
        lock.withLock { _ = slotHandlers.removeValue(forKey: worker) }
    }

    func recovering(_ leases: [ConnectedLease]) {
        lock.withLock {
            if phase != .stopping { phase = .recovering }
            for lease in leases {
                let offer = lease.offer
                let id = offer.runnerPlatform.connectedWorkerID(slot: offer.slot)
                workers[id] = AgentWorkerStatus(id: id, platform: offer.runnerPlatform, slot: offer.slot,
                    phase: .recovering, runner: offer.runner, repository: offer.repository)
                assignments.insert(id)
            }
        }
        notifyStateChanged()
    }

    func update(worker: String, phase: AgentWorkerPhase) {
        let changed = lock.withLock { () -> Bool in
            guard workers[worker] != nil, workers[worker]?.phase != phase else { return false }
            workers[worker]?.phase = phase
            return true
        }
        if changed { notifyStateChanged() }
    }

    func assign(worker: String, offer: ConnectedOffer) {
        lock.withLock {
            workers[worker]?.phase = .provisioning
            workers[worker]?.runner = offer.runner
            workers[worker]?.repository = offer.repository
            workers[worker]?.jobStartedAt = nil
            workers[worker]?.workflowRunID = nil
            workers[worker]?.reclaiming = nil
        }
        notifyStateChanged()
    }

    func recordWorkflowRun(worker: String, runID: Int64) {
        guard runID > 0 else { return }
        let changed = lock.withLock { () -> Bool in
            guard workers[worker]?.workflowRunID != runID else { return false }
            workers[worker]?.workflowRunID = runID
            return true
        }
        if changed { notifyStateChanged() }
    }

    func connection(worker: String, state: AgentConnectionState, error: String?) {
        let changed = lock.withLock { () -> Bool in
            let stateChanged = workers[worker]?.connection != state
            workers[worker]?.connection = state
            if state == .connected { workers[worker]?.lastContactAt = currentDate() }
            if let error { lastError = AgentReportedError(message: error, occurredAt: currentDate()) }
            return stateChanged || error != nil
        }
        if changed { notifyStateChanged() }
    }

    func recordError(_ message: String) {
        lock.withLock { lastError = AgentReportedError(message: message, occurredAt: currentDate()) }
        notifyStateChanged()
    }

    func session(worker: String, state: RunnerSessionState) {
        switch state {
        case .listenerStarted: update(worker: worker, phase: .waitingForJob)
        case .jobStarted:
            lock.withLock {
                workers[worker]?.phase = .running
                workers[worker]?.jobStartedAt = currentDate()
            }
            notifyStateChanged()
        case .listenerExited, .capacityReleased: update(worker: worker, phase: .cleaningUp)
        case let .executionStopped(_, reason):
            lock.withLock {
                lastError = AgentReportedError(message: reason, occurredAt: currentDate())
                workers[worker]?.phase = .cleaningUp
            }
            notifyStateChanged()
        case .cleanupCompleted: break
        }
    }

    func stopping() {
        lock.withLock { phase = .stopping }
        notifyStateChanged()
    }

    /// Invoked inside `kIOMessageSystemWillSleep` (strictly <= 1.5s budget before `IOAllowPowerChange`).
    func handleSystemWillSleep() {
        let handlers: [AgentSlotControlHandler] = lock.withLock {
            let now = currentDate()
            wakeHoldDownUntil = now.addingTimeInterval(Self.wakeHoldDownDuration)
            reschedulePolicyTimerUnlocked(now: now)
            return Array(slotHandlers.values)
        }
        ConnectedSleepCoordinator.abortAndSever(handlers)
        notifyStateChanged()
    }

    /// Invoked on `kIOMessageSystemHasPoweredOn` to enforce flap damping before new admissions.
    func handleSystemDidWake() {
        lock.withLock {
            let now = currentDate()
            wakeHoldDownUntil = now.addingTimeInterval(Self.wakeHoldDownDuration)
            reschedulePolicyTimerUnlocked(now: now)
        }
        notifyStateChanged()
    }

    func canPoll(platform: RunnerPlatform) -> Bool {
        let (allowed, actions, stateChanged) = lock.withLock { () -> (Bool, [@Sendable () -> Void], Bool) in
            var actions: [@Sendable () -> Void] = []
            var stateChanged = false
            let now = currentDate()
            let power = powerStatus()
            let thermal = thermalStateProvider()
            let darkWake = isDarkWakeProvider()
            guard !isPausedUnlocked(now: now, power: power, thermal: thermal, darkWake: darkWake,
                                    quotaActions: &actions, stateChanged: &stateChanged) else {
                return (false, actions, stateChanged)
            }
            if meetingMode {
                if platform == .macOS { return (false, actions, stateChanged) }
                if assignments.count >= 1 { return (false, actions, stateChanged) }
            }
            return (true, actions, stateChanged)
        }
        dispatchQuotaActions(actions)
        if stateChanged { notifyStateChanged() }
        return allowed
    }

    func beginAssignment(worker: String, platform: RunnerPlatform? = nil, offer: ConnectedOffer? = nil) -> Bool {
        let resolvedPlatform = platform ?? (worker.hasPrefix("macOS-") ? .macOS : .linux)
        let (allowed, actions, stateChanged) = lock.withLock { () -> (Bool, [@Sendable () -> Void], Bool) in
            var actions: [@Sendable () -> Void] = []
            var stateChanged = false
            let now = currentDate()
            let power = powerStatus()
            let thermal = thermalStateProvider()
            let darkWake = isDarkWakeProvider()
            guard phase == .ready, !isPausedUnlocked(now: now, power: power, thermal: thermal, darkWake: darkWake,
                                                     quotaActions: &actions, stateChanged: &stateChanged) else {
                return (false, actions, stateChanged)
            }
            if meetingMode {
                // Meeting mode atomically caps total active slots across both platforms to 1 Linux guest.
                guard resolvedPlatform == .linux, assignments.isEmpty else { return (false, actions, stateChanged) }
            }
            precondition(!assignments.contains(worker))
            assignments.insert(worker)
            if let offer {
                workers[worker]?.phase = .provisioning
                workers[worker]?.runner = offer.runner
                workers[worker]?.repository = offer.repository
                workers[worker]?.jobStartedAt = nil
                workers[worker]?.workflowRunID = nil
                workers[worker]?.reclaiming = nil
            }
            return (true, actions, true)
        }
        dispatchQuotaActions(actions)
        if stateChanged { notifyStateChanged() }
        return allowed
    }

    func finishAssignment(worker: String) {
        lock.withLock {
            assignments.remove(worker)
            workers[worker]?.phase = .idle
            workers[worker]?.runner = nil
            workers[worker]?.repository = nil
            workers[worker]?.jobStartedAt = nil
            workers[worker]?.workflowRunID = nil
            workers[worker]?.reclaiming = nil
        }
        notifyStateChanged()
    }

    func request(_ command: String) throws -> AgentControlSnapshot {
        let parsed: AgentControlRequest
        if command.first == "{" {
            guard let data = command.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(AgentControlRequest.self, from: data),
                  decoded.version == 1 else {
                throw AgentControlError.invalidRequest
            }
            parsed = decoded
        } else {
            parsed = AgentControlRequest(action: command)
        }
        var abortActions: [@Sendable () -> Void] = []
        var quotaActions: [@Sendable () -> Void] = []
        var stateChanged = parsed.action != "status"
        let snapshot = try lock.withLock { () throws -> AgentControlSnapshot in
            let now = currentDate()
            let thermal = thermalStateProvider()
            if expireTimersUnlocked(now: now, thermal: thermal, quotaActions: &quotaActions) {
                stateChanged = true
            }
            switch parsed.action {
            case "pause":
                try setManualPauseUnlocked(enabled: true, until: parsed.durationSeconds.map { now.addingTimeInterval(max(0.05, $0)) })
            case "resume":
                try setManualPauseUnlocked(enabled: false, until: nil)
            case "pause-on-battery", "allow-on-battery":
                let enabled = parsed.action == "pause-on-battery"
                if enabled != pauseOnBattery {
                    if enabled {
                        try Self.createMarker(batteryPolicyFile)
                    } else if Darwin.unlink(batteryPolicyFile.path) != 0, errno != ENOENT {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    // A new controller can already see this change even if the following sync fails.
                    pauseOnBattery = enabled
                }
                // Also confirm durability on retries after an agent restart.
                try synchronizeRunnerState(batteryPolicyFile.deletingLastPathComponent())
            case "reclaim":
                try setManualPauseUnlocked(enabled: true, until: parsed.durationSeconds.map { now.addingTimeInterval(max(0.05, $0)) })
                for id in assignments {
                    workers[id]?.reclaiming = true
                    if let handler = slotHandlers[id] {
                        abortActions.append { _ = handler.abort(.reclaimed, nil) }
                    }
                }
            case "abort-job":
                guard let worker = parsed.worker, let runner = parsed.runner, !runner.isEmpty else {
                    throw AgentControlError.invalidRequest
                }
                guard assignments.contains(worker), workers[worker]?.runner == runner else {
                    throw AgentControlError.rejected("That job is no longer running on \(worker).")
                }
                workers[worker]?.reclaiming = true
                if let handler = slotHandlers[worker] {
                    abortActions.append { _ = handler.abort(.reclaimed, runner) }
                }
            case "meeting-mode":
                let nextCPUs: Int
                if let cpus = parsed.cpus {
                    guard cpus == 2 || cpus == 4 else { throw AgentControlError.invalidRequest }
                    nextCPUs = cpus
                } else {
                    nextCPUs = meetingModeCPUs
                }
                let wasMeetingMode = meetingMode
                let nextEnabled: Bool
                let nextUntil: Date?
                if let requestedEnabled = parsed.enabled {
                    nextEnabled = requestedEnabled
                    if requestedEnabled {
                        if let duration = parsed.durationSeconds {
                            nextUntil = now.addingTimeInterval(max(0.05, duration))
                        } else if meetingMode {
                            nextUntil = meetingModeUntil
                        } else {
                            nextUntil = nil
                        }
                    } else {
                        nextUntil = nil
                    }
                } else if parsed.cpus != nil {
                    // CPU-only update from Settings preserves current enabled state and timer.
                    nextEnabled = meetingMode
                    nextUntil = meetingModeUntil
                } else {
                    nextEnabled = !meetingMode
                    nextUntil = nextEnabled ? parsed.durationSeconds.map { now.addingTimeInterval(max(0.05, $0)) } : nil
                }
                var nextThermalCapped = nextEnabled ? thermalCappedToTwo : false
                var nextThermalHoldDown = nextEnabled ? thermalHoldDownUntil : nil
                if nextEnabled && (thermal.isSevere || thermal == .fair) {
                    nextThermalCapped = true
                    nextThermalHoldDown = now.addingTimeInterval(Self.thermalHoldDownDuration)
                }
                let nextPolicy = AgentPersistedPolicy(
                    pausedUntil: pausedUntil,
                    meetingMode: nextEnabled,
                    meetingModeUntil: nextUntil,
                    meetingModeCPUs: nextCPUs
                )
                // Persist before mutating in-memory state so a failed write never diverges.
                try savePolicyUnlocked(nextPolicy)
                meetingMode = nextEnabled
                meetingModeUntil = nextUntil
                meetingModeCPUs = nextCPUs
                thermalCappedToTwo = nextThermalCapped
                thermalHoldDownUntil = nextThermalHoldDown
                // Replace any earlier timer-expiry quota actions with the single authoritative target.
                quotaActions.removeAll()
                if wasMeetingMode || nextEnabled {
                    let effectiveTarget = nextEnabled ? (nextThermalCapped ? min(nextCPUs, 2) : nextCPUs) : AppleContainerBackend.virtualCPUs
                    appendLinuxCPUQuotaActionsUnlocked(targetCPUs: effectiveTarget, to: &quotaActions)
                }
            case "status": break
            default: throw AgentControlError.invalidRequest
            }
            reschedulePolicyTimerUnlocked(now: now)
            return snapshotUnlocked(quotaActions: &quotaActions, stateChanged: &stateChanged)
        }
        // Latch fast in-memory aborts synchronously before returning the control reply.
        for action in abortActions { action() }
        dispatchQuotaActions(quotaActions)
        if stateChanged { notifyStateChanged() }
        return snapshot
    }

    private func dispatchQuotaActions(_ actions: [@Sendable () -> Void]) {
        guard !actions.isEmpty else { return }
        quotaQueue.async {
            for action in actions { action() }
        }
    }

    private func appendLinuxCPUQuotaActionsUnlocked(targetCPUs: Int, to actions: inout [@Sendable () -> Void]) {
        for (id, status) in workers where status.platform == .linux && assignments.contains(id) {
            if let handler = slotHandlers[id] {
                let runner = status.runner
                actions.append { handler.applyCPUQuota(targetCPUs, runner) }
            }
        }
    }

    private func reschedulePolicyTimerUnlocked(now: Date) {
        let nextDeadline = [pausedUntil, meetingModeUntil, wakeHoldDownUntil, thermalHoldDownUntil]
            .compactMap { $0 }
            .min()
        guard nextDeadline != scheduledTimerDeadline else { return }
        policyTimer?.cancel()
        policyTimer = nil
        scheduledTimerDeadline = nextDeadline
        guard let nextDeadline else { return }
        let delay = max(0.01, nextDeadline.timeIntervalSince(now))
        let timer = DispatchSource.makeTimerSource(queue: policyTimerQueue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.reconcilePolicies()
        }
        policyTimer = timer
        timer.resume()
    }

    private func setManualPauseUnlocked(enabled: Bool, until: Date?) throws {
        if enabled {
            if !paused {
                try Self.createMarker(pauseFile)
                paused = true
            }
            pausedUntil = until
            try synchronizeRunnerState(pauseFile.deletingLastPathComponent())
            if until != nil || FileManager.default.fileExists(atPath: policyFile.path) {
                try savePolicyUnlocked()
            }
        } else {
            if paused {
                guard Darwin.unlink(pauseFile.path) == 0 || errno == ENOENT else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try synchronizeRunnerState(pauseFile.deletingLastPathComponent())
                paused = false
                resumeGeneration += 1
            }
            if pausedUntil != nil {
                pausedUntil = nil
                try savePolicyUnlocked()
            }
        }
    }

    @discardableResult
    private func expireTimersUnlocked(now: Date, thermal: HostThermalState, quotaActions: inout [@Sendable () -> Void]) -> Bool {
        var changed = false
        if let until = pausedUntil, now >= until {
            pausedUntil = nil
            if paused {
                _ = Darwin.unlink(pauseFile.path)
                try? synchronizeRunnerState(pauseFile.deletingLastPathComponent())
                paused = false
                resumeGeneration += 1
            }
            try? savePolicyUnlocked()
            changed = true
        }
        if let until = meetingModeUntil, now >= until {
            meetingMode = false
            meetingModeUntil = nil
            thermalCappedToTwo = false
            thermalHoldDownUntil = nil
            try? savePolicyUnlocked()
            appendLinuxCPUQuotaActionsUnlocked(targetCPUs: AppleContainerBackend.virtualCPUs, to: &quotaActions)
            changed = true
        }
        if let until = wakeHoldDownUntil, now >= until {
            wakeHoldDownUntil = nil
            changed = true
        }
        if let until = thermalHoldDownUntil, now >= until {
            let wasCapped = thermalCappedToTwo
            thermalHoldDownUntil = nil
            if thermal == .nominal {
                thermalCappedToTwo = false
                if wasCapped && meetingMode && meetingModeCPUs > 2 {
                    appendLinuxCPUQuotaActionsUnlocked(targetCPUs: meetingModeCPUs, to: &quotaActions)
                }
            }
            changed = true
        }
        if changed {
            reschedulePolicyTimerUnlocked(now: now)
        }
        return changed
    }

    @discardableResult
    private func updateThermalGuardUnlocked(now: Date, thermal: HostThermalState, quotaActions: inout [@Sendable () -> Void]) -> Bool {
        let wasCapped = thermalCappedToTwo
        if thermal.isSevere {
            thermalHoldDownUntil = now.addingTimeInterval(Self.thermalHoldDownDuration)
            thermalCappedToTwo = true
            reschedulePolicyTimerUnlocked(now: now)
        } else if meetingMode && thermal == .fair {
            thermalHoldDownUntil = now.addingTimeInterval(Self.thermalHoldDownDuration)
            thermalCappedToTwo = true
            reschedulePolicyTimerUnlocked(now: now)
        }
        if !wasCapped && thermalCappedToTwo && meetingMode {
            appendLinuxCPUQuotaActionsUnlocked(targetCPUs: min(meetingModeCPUs, 2), to: &quotaActions)
            return true
        }
        return !wasCapped && thermalCappedToTwo
    }

    private func admissionReasonsUnlocked(
        now: Date, power: HostPowerStatus, thermal: HostThermalState, darkWake: Bool,
        quotaActions: inout [@Sendable () -> Void], stateChanged: inout Bool
    ) -> [AgentAdmissionReason] {
        if expireTimersUnlocked(now: now, thermal: thermal, quotaActions: &quotaActions) { stateChanged = true }
        if updateThermalGuardUnlocked(now: now, thermal: thermal, quotaActions: &quotaActions) { stateChanged = true }
        var reasons: [AgentAdmissionReason] = []
        if paused {
            reasons.append(pausedUntil != nil ? .timedPause : .manual)
        }
        if (pauseOnBattery || meetingMode) && power.source == .battery {
            reasons.append(.battery)
        }
        if meetingMode && power.source == .unknown {
            reasons.append(.unknownPower)
        }
        if (pauseOnBattery || meetingMode) && power.drainingOnAC {
            reasons.append(.drainingCharger)
        }
        if power.lowPowerMode {
            reasons.append(.lowPowerMode)
        }
        if darkWake {
            reasons.append(.darkWake)
        }
        if let until = wakeHoldDownUntil, now < until {
            reasons.append(.wakeHoldDown)
        }
        if thermal.isSevere || (meetingMode && thermal == .fair && meetingModeCPUs <= 2) {
            reasons.append(.thermal)
        }
        if workers.values.contains(where: { $0.reclaiming == true }) {
            reasons.append(.reclaiming)
        }
        return reasons
    }

    private func isPausedUnlocked(
        now: Date, power: HostPowerStatus, thermal: HostThermalState, darkWake: Bool,
        quotaActions: inout [@Sendable () -> Void], stateChanged: inout Bool
    ) -> Bool {
        let blocking = admissionReasonsUnlocked(
            now: now, power: power, thermal: thermal, darkWake: darkWake,
            quotaActions: &quotaActions, stateChanged: &stateChanged
        )
        return blocking.contains { $0 != .reclaiming }
    }

    private func savePolicyUnlocked(_ policy: AgentPersistedPolicy? = nil) throws {
        let value = policy ?? AgentPersistedPolicy(
            pausedUntil: pausedUntil,
            meetingMode: meetingMode,
            meetingModeUntil: meetingModeUntil,
            meetingModeCPUs: meetingModeCPUs
        )
        try writePrivateRunnerFile(JSONEncoder().encode(value), to: policyFile)
    }

    private static func loadPolicy(at url: URL) -> AgentPersistedPolicy? {
        guard let data = try? readPrivateRunnerFile(url, maximumBytes: 8_192) else { return nil }
        return try? JSONDecoder().decode(AgentPersistedPolicy.self, from: data)
    }

    private static func createMarker(_ file: URL) throws {
        let descriptor = Darwin.open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 || errno == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    private func notifyStateChanged() {
        guard let stateChangedNotificationName else { return }
        _ = notify_post(stateChangedNotificationName)
    }

    private func snapshotUnlocked(quotaActions: inout [@Sendable () -> Void], stateChanged: inout Bool) -> AgentControlSnapshot {
        let now = currentDate()
        let power = powerStatus()
        let thermal = thermalStateProvider()
        let darkWake = isDarkWakeProvider()
        let reasons = admissionReasonsUnlocked(
            now: now, power: power, thermal: thermal, darkWake: darkWake,
            quotaActions: &quotaActions, stateChanged: &stateChanged
        )
        let battery = (pauseOnBattery || meetingMode) && power.source == .battery
        let effectivePaused = reasons.contains { $0 != .reclaiming }
        let displayedReasons = meetingMode ? (reasons + [.meetingMode]) : reasons
        let effectiveCPUs = thermalCappedToTwo ? min(meetingModeCPUs, 2) : meetingModeCPUs
        return AgentControlSnapshot(
            version: 1, instanceID: instanceID, resumeGeneration: resumeGeneration,
            paused: effectivePaused, ready: phase == .ready, activeAssignments: assignments.count,
            recordedAt: now, phase: phase, server: server, deviceID: deviceID, memory: memory?.status,
            workers: workers.values.sorted { $0.id < $1.id }, lastError: lastError,
            pauseOnBattery: pauseOnBattery, pausedByBattery: battery, manuallyPaused: paused,
            admissionReasons: displayedReasons, pausedUntil: pausedUntil,
            meetingMode: meetingMode, meetingModeUntil: meetingModeUntil,
            meetingModeCPUs: effectiveCPUs, meetingModeConfiguredCPUs: meetingModeCPUs,
            hostPower: power, thermalState: thermal
        )
    }
}

@objc protocol AgentControlProtocol {
    func request(_ command: String, reply: @escaping @Sendable (Data?, String?) -> Void)
}

private let agentControlService = "dev.yieldd.agent.control"

final class AgentControlEndpoint: NSObject, AgentControlProtocol, NSXPCListenerDelegate {
    private let control: ConnectedAgentControl
    private let listener: NSXPCListener

    init(control: ConnectedAgentControl, listener: NSXPCListener = NSXPCListener(machServiceName: agentControlService)) {
        self.control = control
        self.listener = listener
        super.init()
        listener.delegate = self
    }

    func start() { listener.resume() }
    func stop() { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: AgentControlProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func request(_ command: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        do { reply(try JSONEncoder().encode(control.request(command)), nil) }
        catch { reply(nil, describeError(error)) }
    }
}

func requestAgentControl(_ command: String, connection: NSXPCConnection = NSXPCConnection(machServiceName: agentControlService), timeout: TimeInterval = 10) throws -> AgentControlSnapshot {
    precondition(timeout.isFinite && timeout > 0)
    connection.remoteObjectInterface = NSXPCInterface(with: AgentControlProtocol.self)
    let result = Mutex<Result<Data, AgentControlError>?>(nil)
    let completed = DispatchSemaphore(value: 0)
    let finish: @Sendable (Result<Data, AgentControlError>) -> Void = { value in
        result.withLock { stored in
            guard stored == nil else { return }
            stored = value
            completed.signal()
        }
    }
    connection.interruptionHandler = { finish(.failure(.unavailable)) }
    connection.invalidationHandler = { finish(.failure(.unavailable)) }
    connection.resume()
    defer { connection.invalidate() }
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(.failure(.unavailable)) }) as? AgentControlProtocol else {
        throw AgentControlError.unavailable
    }
    proxy.request(command) { data, error in
        if let error { finish(.failure(.rejected(error))) }
        else if let data { finish(.success(data)) }
        else { finish(.failure(.invalidResponse)) }
    }
    guard completed.wait(timeout: .now() + timeout) == .success else { throw AgentControlError.unavailable }
    guard let value = result.withLock({ $0 }) else { throw AgentControlError.invalidResponse }
    let snapshot = try JSONDecoder().decode(AgentControlSnapshot.self, from: value.get())
    guard snapshot.version == 1 else { throw AgentControlError.invalidResponse }
    return snapshot
}

struct AgentPauseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Stop accepting connected assignments; let active work finish.")
    @Option(name: .long, help: "Automatically resume after this many minutes.")
    var minutes: Int?

    mutating func run() throws {
        try requireInstalledConnectedAgent()
        let command: String
        if let minutes, minutes > 0 {
            command = try AgentControlRequest(action: "pause", durationSeconds: TimeInterval(minutes * 60)).encodedCommand()
        } else {
            command = "pause"
        }
        let snapshot = try requestAgentControl(command)
        print("Paused. \(snapshot.activeAssignments) assignment(s) still active or cleaning up.")
    }
}

struct AgentReclaimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reclaim", abstract: "Pause new jobs and immediately stop all running local runners to reclaim Mac compute.")
    @Option(name: .long, help: "Automatically resume accepting jobs after this many minutes.")
    var minutes: Int?

    mutating func run() throws {
        try requireInstalledConnectedAgent()
        let request = AgentControlRequest(action: "reclaim", durationSeconds: minutes.flatMap { $0 > 0 ? TimeInterval($0 * 60) : nil })
        let snapshot = try requestAgentControl(try request.encodedCommand())
        print("Reclaiming compute and paused new jobs. \(snapshot.activeAssignments) assignment(s) stopping.")
    }
}

struct AgentResumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume accepting connected assignments.")
    mutating func run() throws {
        try requireInstalledConnectedAgent()
        let status = try requestAgentControl("resume")
        print(status.pausedByBattery == true ? "New jobs are paused on battery power." : "Resumed accepting new jobs.")
    }
}

struct AgentDrainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drain", abstract: "Pause and wait until connected assignments and cleanup finish.")
    mutating func run() throws {
        try requireInstalledConnectedAgent()
        print("Draining. The agent will remain paused until resumed.")
        try waitForAgentDrain(request: { try requestAgentControl($0) }, wait: { Thread.sleep(forTimeInterval: 1) })
        print("Drained. No connected assignments or cleanup remain.")
    }
}

func requireInstalledConnectedAgent(in directory: URL? = nil) throws {
    let directory = try directory ?? yielddApplicationSupportDirectory()
    guard try ConnectedAgentStore(directory: directory).load() != nil else { throw AgentControlError.notInstalled }
}

func waitForAgentDrain(request: (String) throws -> AgentControlSnapshot, wait: () throws -> Void) throws {
    let initial = try request("pause")
    var snapshot = initial
    while !snapshot.drained {
        try wait()
        snapshot = try request("status")
        guard snapshot.paused, snapshot.instanceID == initial.instanceID,
              snapshot.resumeGeneration == initial.resumeGeneration else { throw AgentControlError.drainInterrupted }
    }
}

enum AgentControlError: Error, LocalizedError {
    case invalidRequest, invalidResponse, unavailable, drainInterrupted, notInstalled
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Pause, resume, drain, and reclaim require an installed connected agent."
        case .drainInterrupted: "Drain interrupted because the agent restarted or connected assignments were resumed."
        case .invalidRequest: "Unknown connected agent control request."
        case .invalidResponse: "The connected agent returned an unsupported control response."
        case .unavailable: "The connected agent is unavailable. Check its login-item registration and agent logs."
        case let .rejected(reason): reason
        }
    }
}
