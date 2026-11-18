import ArgumentParser
import Darwin
import Foundation
import Synchronization

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

    var drained: Bool { ready && paused && activeAssignments == 0 }
}

// The lock serializes admission with pause and owns the assignment set.
final class ConnectedAgentControl: @unchecked Sendable {
    private let lock = NSLock()
    private let pauseFile: URL
    private var paused: Bool
    private let instanceID = UUID()
    private var resumeGeneration: UInt64 = 0
    private var assignments: Set<String> = []
    private var phase: AgentServicePhase = .starting
    private let server: String?
    private let deviceID: String?
    private var memory: RunnerMemoryAdmission?
    private var workers: [String: AgentWorkerStatus] = [:]
    private var lastError: AgentReportedError?

    init(directory: URL, configuration: ConnectedAgentConfiguration? = nil) {
        server = configuration?.server.absoluteString
        deviceID = configuration?.deviceID
        pauseFile = directory.appendingPathComponent("connected-agent.paused")
        var info = stat()
        paused = Darwin.lstat(pauseFile.path, &info) == 0 || errno != ENOENT
    }

    var snapshot: AgentControlSnapshot {
        lock.withLock { snapshotUnlocked() }
    }

    var isPaused: Bool { lock.withLock { paused } }

    func starting() {
        lock.withLock { if phase != .stopping { phase = .starting } }
    }

    func markReady() {
        lock.withLock {
            guard phase != .stopping else { return }
            phase = .ready
        }
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
    }

    func update(worker: String, phase: AgentWorkerPhase) {
        lock.withLock { workers[worker]?.phase = phase }
    }

    func assign(worker: String, offer: ConnectedOffer) {
        lock.withLock {
            workers[worker]?.phase = .provisioning
            workers[worker]?.runner = offer.runner
            workers[worker]?.repository = offer.repository
        }
    }

    func connection(worker: String, state: AgentConnectionState, error: String?) {
        lock.withLock {
            workers[worker]?.connection = state
            if state == .connected { workers[worker]?.lastContactAt = Date() }
            if let error { lastError = AgentReportedError(message: error) }
        }
    }

    func session(worker: String, state: RunnerSessionState) {
        switch state {
        case .listenerStarted: update(worker: worker, phase: .waitingForJob)
        case .jobStarted: update(worker: worker, phase: .running)
        case .listenerExited, .capacityReleased: update(worker: worker, phase: .cleaningUp)
        case let .executionStopped(_, reason):
            lock.withLock { lastError = AgentReportedError(message: reason); workers[worker]?.phase = .cleaningUp }
        case .cleanupCompleted: break
        }
    }

    func stopping() { lock.withLock { phase = .stopping } }


    func beginAssignment(worker: String) -> Bool {
        lock.withLock {
            guard phase == .ready, !paused else { return false }
            precondition(!assignments.contains(worker))
            assignments.insert(worker)
            return true
        }
    }

    func finishAssignment(worker: String) {
        lock.withLock {
            assignments.remove(worker)
            workers[worker]?.phase = .idle
            workers[worker]?.runner = nil
            workers[worker]?.repository = nil
        }
    }

    func request(_ command: String) throws -> AgentControlSnapshot {
        try lock.withLock {
            switch command {
            case "pause":
                if !paused {
                    let descriptor = Darwin.open(pauseFile.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
                    guard descriptor >= 0 || errno == EEXIST else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if descriptor >= 0 { _ = Darwin.close(descriptor) }
                    paused = true
                    try synchronizeRunnerState(pauseFile.deletingLastPathComponent())
                }
            case "resume":
                if paused {
                    guard Darwin.unlink(pauseFile.path) == 0 || errno == ENOENT else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try synchronizeRunnerState(pauseFile.deletingLastPathComponent())
                    paused = false
                    resumeGeneration += 1
                }
            case "status": break
            default: throw AgentControlError.invalidRequest
            }
            return snapshotUnlocked()
        }
    }

    private func snapshotUnlocked() -> AgentControlSnapshot {
        AgentControlSnapshot(version: 1, instanceID: instanceID, resumeGeneration: resumeGeneration, paused: paused, ready: phase == .ready, activeAssignments: assignments.count,
            recordedAt: Date(), phase: phase, server: server, deviceID: deviceID, memory: memory?.status,
            workers: workers.values.sorted { $0.id < $1.id }, lastError: lastError)
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
    mutating func run() throws {
        try requireInstalledConnectedAgent()
        let snapshot = try requestAgentControl("pause")
        print("Paused. \(snapshot.activeAssignments) assignment(s) still active or cleaning up.")
    }
}

struct AgentResumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume accepting connected assignments.")
    mutating func run() throws {
        try requireInstalledConnectedAgent()
        _ = try requestAgentControl("resume")
        print("Connected assignments enabled.")
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
        case .notInstalled: "Pause, resume, and drain require an installed connected agent."
        case .drainInterrupted: "Drain interrupted because the agent restarted or connected assignments were resumed."
        case .invalidRequest: "Unknown connected agent control request."
        case .invalidResponse: "The connected agent returned an unsupported control response."
        case .unavailable: "The connected agent is unavailable. Check its login-item registration and agent logs."
        case let .rejected(reason): reason
        }
    }
}
