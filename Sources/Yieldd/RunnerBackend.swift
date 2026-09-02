import Foundation

struct RunnerID: Hashable, Sendable {
    let value: String
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
    func create(id: RunnerID, image: String) throws
    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws -> ProcessResult
    func stopRunner(on id: RunnerID) throws
    func destroy(_ id: RunnerID) throws
}

extension RunnerBackend {
    func exec(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        on id: RunnerID
    ) throws -> ProcessResult {
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

    @discardableResult
    func setMemoryAllocation(
        _ allocation: RunnerMemoryAllocation,
        timeout: TimeInterval,
        on id: RunnerID
    ) throws -> ProcessResult {
        try exec(
            ["yieldd-runner-control", "memory", allocation.rawValue],
            standardInput: nil,
            timeout: timeout,
            outputCapture: .all,
            as: .root,
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
