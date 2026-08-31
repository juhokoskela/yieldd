import Foundation

struct RunnerID: Hashable, Sendable {
    let value: String
}

protocol RunnerBackend {
    func create(id: RunnerID, image: String) throws
    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        on id: RunnerID
    ) throws -> ProcessResult
    func destroy(_ id: RunnerID) throws
}

extension RunnerBackend {
    func exec(_ arguments: [String], on id: RunnerID) throws -> ProcessResult {
        try exec(arguments, standardInput: nil, timeout: nil, on: id)
    }

    func exec(
        _ arguments: [String],
        standardInput: Data?,
        on id: RunnerID
    ) throws -> ProcessResult {
        try exec(arguments, standardInput: standardInput, timeout: nil, on: id)
    }

    func exec(
        _ arguments: [String],
        timeout: TimeInterval,
        on id: RunnerID
    ) throws -> ProcessResult {
        try exec(arguments, standardInput: nil, timeout: timeout, on: id)
    }
}

enum RunnerBackendError: Error, Equatable, LocalizedError {
    case emptyCommand

    var errorDescription: String? {
        "Runner command must not be empty."
    }
}
