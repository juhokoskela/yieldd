import Foundation

struct RunnerID: Hashable, Sendable {
    let value: String

    var isValid: Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return value.hasPrefix("yieldd-")
            && value.count <= 128
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

enum RunnerGuestUser: String, Equatable, Sendable {
    case root
    case runner
}

enum RunnerPlatform: String, Codable, Sendable {
    case linux
    case macOS

    var memoryReservationBytes: UInt64 {
        switch self {
        case .linux: AppleContainerBackend.memoryBytes
        case .macOS: MacOSVirtualMachineLifecycle.memoryBytes
        }
    }

    var maximumSlots: Int {
        switch self {
        case .linux: RunnerPool.maximumSlots
        case .macOS: 2
        }
    }

    var runnerLabel: String {
        switch self {
        case .linux: "yieldd"
        case .macOS: "yieldd-macos"
        }
    }

    func makeTestRunnerID() -> RunnerID {
        RunnerID(value: "\(runnerLabel)-test-\(UUID().uuidString.lowercased())")
    }
}

enum RunnerMemoryAllocation: String, Equatable, Sendable {
    case constrained
    case full
}

protocol RunnerBackend {
    var platform: RunnerPlatform { get }
    func prepare() throws
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws
    func create(id: RunnerID, memory: RunnerMemoryAllocation, recordIntent: () throws -> Void) throws
    @discardableResult func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws -> ProcessResult
    func destroy(_ id: RunnerID) throws
}

extension RunnerBackend {
    func prepare() throws {}

    func create(id: RunnerID, memory: RunnerMemoryAllocation, recordIntent: () throws -> Void) throws {
        try prepare()
        try recordIntent()
        try create(id: id, memory: memory)
    }

    @discardableResult func exec(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        on id: RunnerID
    ) throws -> ProcessResult {
        try exec(
            arguments,
            standardInput: standardInput,
            timeout: timeout,
            outputCapture: .tail(maxBytes: 64 * 1_024),
            as: .runner,
            on: id
        )
    }

    @discardableResult func exec(
        _ arguments: [String],
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws -> ProcessResult {
        try exec(
            arguments,
            standardInput: nil,
            timeout: timeout,
            outputCapture: outputCapture,
            as: user,
            on: id
        )
    }
}

enum RunnerBackendError: Error, Equatable, LocalizedError {
    case emptyCommand

    var errorDescription: String? {
        "Runner command must not be empty."
    }
}
