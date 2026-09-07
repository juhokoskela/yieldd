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

enum RunnerMemoryAllocation: String, Equatable, Sendable {
    case constrained
    case full
}

protocol RunnerBackend {
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws
    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws
    func stopRunner(on id: RunnerID) throws
    func destroy(_ id: RunnerID) throws
}

extension RunnerBackend {
    func exec(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        on id: RunnerID
    ) throws {
        try exec(
            arguments,
            standardInput: standardInput,
            timeout: timeout,
            outputCapture: .all,
            as: .runner,
            on: id
        )
    }

    func exec(
        _ arguments: [String],
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws {
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
