import Foundation
import ServiceManagement

struct RunnerMemoryStatus: Codable, Equatable, Sendable {
    let budgetBytes: UInt64
    let reservedBytes: UInt64
    let pressure: HostMemoryPressure
}

enum AgentServicePhase: String, Codable, Sendable {
    case starting, recovering, ready, stopping
}

enum AgentConnectionState: String, Codable, Sendable {
    case connecting, connected, retrying, failed
}

enum AgentWorkerPhase: String, Codable, Sendable {
    case idle, waitingForMemory, provisioning, waitingForJob, running, cleaningUp, recovering
}

struct AgentReportedError: Codable, Equatable, Sendable {
    let message: String
    let occurredAt: Date

    init(message: String, occurredAt: Date = Date()) {
        self.message = String(message.prefix(2_048))
        self.occurredAt = occurredAt
    }
}

struct AgentWorkerStatus: Codable, Equatable, Sendable {
    let id: String
    let platform: RunnerPlatform
    let slot: Int
    var phase: AgentWorkerPhase = .idle
    var connection: AgentConnectionState = .connecting
    var lastContactAt: Date?
    var runner: String?
    var repository: String?
}

enum AgentRegistrationState: String, Codable {
    case notRegistered, enabled, requiresApproval, notFound, unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }
}

struct AgentStatusReport: Encodable {
    let version = 1
    let registration: AgentRegistrationState
    let configuration: ConnectedAgentConfiguration?
    let live: AgentControlSnapshot?
    let unavailableReason: String?
    let lastFailure: AgentReportedError?
}

struct AgentFailureStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("connected-agent-error.json") }

    func load() throws -> AgentReportedError? {
        guard let data = try readPrivateRunnerFile(file, maximumBytes: 32_768) else { return nil }
        return try JSONDecoder().decode(AgentReportedError.self, from: data)
    }

    func remove() throws {
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    func save(_ failure: AgentReportedError) throws {
        try writePrivateRunnerFile(JSONEncoder().encode(failure), to: file)
    }
}

func connectedAgentStatus(registration: AgentRegistrationState, directory: URL,
                          request: () throws -> AgentControlSnapshot = { try requestAgentControl("status", timeout: 2) }) -> AgentStatusReport {
    let configuration = try? ConnectedAgentStore(directory: directory).load()
    do {
        return AgentStatusReport(registration: registration, configuration: configuration, live: try request(), unavailableReason: nil, lastFailure: nil)
    } catch {
        return AgentStatusReport(registration: registration, configuration: configuration, live: nil, unavailableReason: describeError(error),
            lastFailure: try? AgentFailureStore(directory: directory).load())
    }
}

func renderAgentStatus(_ report: AgentStatusReport) -> String {
    var lines = ["Agent registration: \(report.registration.rawValue)"]
    guard let status = report.live else {
        if let configuration = report.configuration {
            lines.append("Configured coordinator: \(configuration.server.absoluteString)")
            lines.append("Configured device: \(configuration.deviceID)")
            lines.append("Configured platforms: \(configuration.platforms.map(\.rawValue).joined(separator: ", "))")
        }
        lines.append("Live status unavailable: \(report.unavailableReason ?? "unknown error")")
        if let failure = report.lastFailure {
            lines.append("Last recorded failure (\(failure.occurredAt.formatted(.iso8601))): \(failure.message)")
        }
        return lines.joined(separator: "\n")
    }
    lines.append("Service: \(status.phase.rawValue), \(status.paused ? "paused" : status.ready ? "accepting assignments" : "admissions unavailable")")
    if let server = status.server { lines.append("Coordinator: \(server)") }
    if let deviceID = status.deviceID { lines.append("Device: \(deviceID)") }
    lines.append("Active assignments or cleanup: \(status.activeAssignments)")
    if let memory = status.memory {
        lines.append("Memory reservations: \(memory.reservedBytes) / \(memory.budgetBytes) bytes; pressure: \(memory.pressure.rawValue)")
    }
    for worker in status.workers {
        var line = "\(worker.id): \(worker.phase.rawValue), last coordinator result \(worker.connection.rawValue)"
        if let repository = worker.repository { line += ", \(repository)" }
        if let runner = worker.runner { line += ", \(runner)" }
        if let contact = worker.lastContactAt { line += ", last contact \(contact.formatted(.iso8601))" }
        lines.append(line)
    }
    if let error = status.lastError { lines.append("Last error (\(error.occurredAt.formatted(.iso8601))): \(error.message)") }
    return lines.joined(separator: "\n")
}
