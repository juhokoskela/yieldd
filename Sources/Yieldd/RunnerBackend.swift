import Foundation

struct RunnerID: Hashable, Sendable {
    let value: String
}

protocol RunnerBackend {
    func create(id: RunnerID, image: String) throws
    func exec(_ arguments: [String], on id: RunnerID) throws -> ProcessResult
    func destroy(_ id: RunnerID) throws
}

enum RunnerBackendError: Error, Equatable, LocalizedError {
    case emptyCommand

    var errorDescription: String? {
        "Runner command must not be empty."
    }
}
