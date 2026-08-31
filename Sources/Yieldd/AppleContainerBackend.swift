import Foundation

struct AppleContainerBackend: RunnerBackend {
    let containerURL: URL
    let executor: any ProcessExecuting

    func create(id: RunnerID, image: String) throws {
        _ = try run([
            "machine", "create",
            "--name", id.value,
            "--home-mount", "none",
            image,
        ])
    }

    func exec(_ arguments: [String], on id: RunnerID) throws -> ProcessResult {
        guard !arguments.isEmpty else {
            throw RunnerBackendError.emptyCommand
        }
        return try run([
            "machine", "run",
            "--name", id.value,
            "--user", "runner",
            "--",
        ] + arguments)
    }

    func destroy(_ id: RunnerID) throws {
        let list = try run(["machine", "list", "--quiet"])
        let machineIDs = list.stdoutText.split(whereSeparator: \Character.isNewline)
        guard machineIDs.contains(Substring(id.value)) else {
            return
        }
        _ = try run(["machine", "delete", id.value])
    }

    private func run(_ arguments: [String]) throws -> ProcessResult {
        let request = ProcessRequest(executableURL: containerURL, arguments: arguments)
        return try executor.execute(request).requireSuccess(for: request)
    }
}
