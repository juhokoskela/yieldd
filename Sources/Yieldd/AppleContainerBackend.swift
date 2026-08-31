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

    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        on id: RunnerID
    ) throws -> ProcessResult {
        guard !arguments.isEmpty else {
            throw RunnerBackendError.emptyCommand
        }
        var containerArguments = [
            "machine", "run",
            "--name", id.value,
            "--user", "runner",
        ]
        if standardInput != nil {
            containerArguments.append("--interactive")
        }
        containerArguments.append("--")
        containerArguments.append(contentsOf: arguments)

        return try run(
            containerArguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    func destroy(_ id: RunnerID) throws {
        let list = try run(["machine", "list", "--quiet"])
        let machineIDs = list.stdoutText.split(whereSeparator: \Character.isNewline)
        guard machineIDs.contains(Substring(id.value)) else {
            return
        }
        _ = try run(["machine", "delete", id.value])
    }

    private func run(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessResult {
        let request = ProcessRequest(
            executableURL: containerURL,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout
        )
        return try executor.execute(request).requireSuccess(for: request)
    }
}
