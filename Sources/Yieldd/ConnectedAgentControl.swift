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
    let hostPower: HostPowerStatus?
    let thermalState: HostThermalState?

    var drained: Bool { ready && paused && activeAssignments == 0 }
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
    let severNetwork: @Sendable () -> Void
    let applyCPUQuota: @Sendable (Int) -> Void
    let markDestroyOnWake: @Sendable () -> Void
}

// The lock serializes admission with pause/meeting/reclaim and owns the assignment set.
final class ConnectedAgentControl: @unchecked Sendable {
    static let wakeHoldDownDuration: TimeInterval = 30
    static let thermalHoldDownDuration: TimeInterval = 10 * 60

    private let lock = NSLock()
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
    }

    var snapshot: AgentControlSnapshot {
        lock.withLock { snapshotUnlocked() }
    }

    var isPaused: Bool {
        lock.withLock { isPausedUnlocked(now: currentDate(), power: powerStatus(), thermal: thermalStateProvider(), darkWake: isDarkWakeProvider()) }
    }

    var effectiveLinuxCPUs: Int {
        lock.withLock {
            let now = currentDate()
            expireTimersUnlocked(now: now)
            guard meetingMode else { return AppleContainerBackend.virtualCPUs }
            let thermal = thermalStateProvider()
            updateThermalGuardUnlocked(now: now, thermal: thermal)
            if thermalCappedToTwo { return min(meetingModeCPUs, 2) }
            return meetingModeCPUs
        }
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
        lock.withLock { workers[worker]?.phase = phase }
        notifyStateChanged()
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
        lock.withLock {
            workers[worker]?.connection = state
            if state == .connected { workers[worker]?.lastContactAt = currentDate() }
            if let error { lastError = AgentReportedError(message: error, occurredAt: currentDate()) }
        }
        notifyStateChanged()
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
            wakeHoldDownUntil = currentDate().addingTimeInterval(Self.wakeHoldDownDuration)
            return Array(slotHandlers.values)
        }
        for handler in handlers {
            handler.markDestroyOnWake()
            handler.severNetwork()
            _ = handler.abort(.sleepInterrupted, nil)
        }
        notifyStateChanged()
    }

    /// Invoked on `kIOMessageSystemHasPoweredOn` to enforce flap damping before new admissions.
    func handleSystemDidWake() {
        lock.withLock {
            wakeHoldDownUntil = currentDate().addingTimeInterval(Self.wakeHoldDownDuration)
        }
        notifyStateChanged()
    }

    func canPoll(platform: RunnerPlatform) -> Bool {
        lock.withLock {
            let now = currentDate()
            let power = powerStatus()
            let thermal = thermalStateProvider()
            let darkWake = isDarkWakeProvider()
            guard !isPausedUnlocked(now: now, power: power, thermal: thermal, darkWake: darkWake) else { return false }
            if meetingMode {
                if platform == .macOS { return false }
                if assignments.count >= 1 { return false }
            }
            return true
        }
    }

    func beginAssignment(worker: String, platform: RunnerPlatform? = nil) -> Bool {
        let resolvedPlatform = platform ?? (worker.hasPrefix("macOS-") ? .macOS : .linux)
        let allowed = lock.withLock { () -> Bool in
            let now = currentDate()
            let power = powerStatus()
            let thermal = thermalStateProvider()
            let darkWake = isDarkWakeProvider()
            guard phase == .ready, !isPausedUnlocked(now: now, power: power, thermal: thermal, darkWake: darkWake) else {
                return false
            }
            if meetingMode {
                // Meeting mode atomically caps total active slots across both platforms to 1 Linux guest.
                guard resolvedPlatform == .linux, assignments.isEmpty else { return false }
            }
            precondition(!assignments.contains(worker))
            assignments.insert(worker)
            return true
        }
        if allowed { notifyStateChanged() }
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
        var postLockActions: [@Sendable () -> Void] = []
        let snapshot = try lock.withLock { () throws -> AgentControlSnapshot in
            let now = currentDate()
            expireTimersUnlocked(now: now)
            switch parsed.action {
            case "pause":
                try setManualPauseUnlocked(enabled: true, until: parsed.durationSeconds.map { now.addingTimeInterval(max(1, $0)) })
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
                try setManualPauseUnlocked(enabled: true, until: parsed.durationSeconds.map { now.addingTimeInterval(max(1, $0)) })
                for id in assignments {
                    workers[id]?.reclaiming = true
                    if let handler = slotHandlers[id] {
                        postLockActions.append { _ = handler.abort(.reclaimed, nil) }
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
                    postLockActions.append { _ = handler.abort(.reclaimed, runner) }
                }
            case "meeting-mode":
                let enabled = parsed.enabled ?? !meetingMode
                if let cpus = parsed.cpus {
                    guard cpus == 2 || cpus == 4 else { throw AgentControlError.invalidRequest }
                    meetingModeCPUs = cpus
                }
                meetingMode = enabled
                meetingModeUntil = enabled ? parsed.durationSeconds.map { now.addingTimeInterval(max(1, $0)) } : nil
                if !enabled {
                    thermalCappedToTwo = false
                    thermalHoldDownUntil = nil
                }
                try savePolicyUnlocked()
                let targetCPUs = enabled ? meetingModeCPUs : AppleContainerBackend.virtualCPUs
                for (id, status) in workers where status.platform == .linux && assignments.contains(id) {
                    if let handler = slotHandlers[id] {
                        postLockActions.append { handler.applyCPUQuota(targetCPUs) }
                    }
                }
            case "status": break
            default: throw AgentControlError.invalidRequest
            }
            return snapshotUnlocked()
        }
        let actions = postLockActions
        if !actions.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                for action in actions { action() }
            }
        }
        if parsed.action != "status" { notifyStateChanged() }
        return snapshot
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

    private func expireTimersUnlocked(now: Date) {
        if let until = pausedUntil, now >= until {
            pausedUntil = nil
            if paused {
                _ = Darwin.unlink(pauseFile.path)
                try? synchronizeRunnerState(pauseFile.deletingLastPathComponent())
                paused = false
                resumeGeneration += 1
            }
            try? savePolicyUnlocked()
        }
        if let until = meetingModeUntil, now >= until {
            meetingMode = false
            meetingModeUntil = nil
            thermalCappedToTwo = false
            thermalHoldDownUntil = nil
            try? savePolicyUnlocked()
        }
        if let until = wakeHoldDownUntil, now >= until {
            wakeHoldDownUntil = nil
        }
        if let until = thermalHoldDownUntil, now >= until {
            thermalHoldDownUntil = nil
            thermalCappedToTwo = false
        }
    }

    private func updateThermalGuardUnlocked(now: Date, thermal: HostThermalState) {
        if thermal.isSevere {
            thermalHoldDownUntil = now.addingTimeInterval(Self.thermalHoldDownDuration)
            thermalCappedToTwo = true
        } else if meetingMode && thermal == .fair {
            thermalHoldDownUntil = now.addingTimeInterval(Self.thermalHoldDownDuration)
            thermalCappedToTwo = true
        }
    }

    private func admissionReasonsUnlocked(now: Date, power: HostPowerStatus, thermal: HostThermalState, darkWake: Bool) -> [AgentAdmissionReason] {
        expireTimersUnlocked(now: now)
        updateThermalGuardUnlocked(now: now, thermal: thermal)
        var reasons: [AgentAdmissionReason] = []
        if paused {
            reasons.append(pausedUntil != nil ? .timedPause : .manual)
        }
        if pauseOnBattery && power.source == .battery {
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

    private func isPausedUnlocked(now: Date, power: HostPowerStatus, thermal: HostThermalState, darkWake: Bool) -> Bool {
        let blocking = admissionReasonsUnlocked(now: now, power: power, thermal: thermal, darkWake: darkWake)
        return blocking.contains { $0 != .reclaiming }
    }

    private func savePolicyUnlocked() throws {
        let policy = AgentPersistedPolicy(
            pausedUntil: pausedUntil,
            meetingMode: meetingMode,
            meetingModeUntil: meetingModeUntil,
            meetingModeCPUs: meetingModeCPUs
        )
        try writePrivateRunnerFile(JSONEncoder().encode(policy), to: policyFile)
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

    private func snapshotUnlocked() -> AgentControlSnapshot {
        let now = currentDate()
        let power = powerStatus()
        let thermal = thermalStateProvider()
        let darkWake = isDarkWakeProvider()
        let reasons = admissionReasonsUnlocked(now: now, power: power, thermal: thermal, darkWake: darkWake)
        let battery = pauseOnBattery && power.source == .battery
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
            meetingMode: meetingMode, meetingModeUntil: meetingModeUntil, meetingModeCPUs: effectiveCPUs,
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
