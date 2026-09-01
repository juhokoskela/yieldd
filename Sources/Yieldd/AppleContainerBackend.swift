import Foundation

struct AppleContainerBackend: RunnerBackend {
    // Machine deletion has its own 60-second budget after the machine stops.
    static let cleanupTimeout: TimeInterval = 90
    static let runnerStopTimeout: TimeInterval = 30
    static let virtualCPUs = 8
    static let memory = "12G"

    let containerURL: URL
    let executor: any ProcessExecuting

    func create(id: RunnerID, image: String) throws {
        _ = try run([
            "machine", "create",
            "--name", id.value,
            "--home-mount", "none",
            "--cpus", String(Self.virtualCPUs),
            "--memory", Self.memory,
            image,
        ])
    }

    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws -> ProcessResult {
        guard !arguments.isEmpty else {
            throw RunnerBackendError.emptyCommand
        }
        var containerArguments = [
            "machine", "run",
            "--name", id.value,
            "--user", user.rawValue,
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
        let list = try run(
            ["machine", "list", "--quiet"],
            timeout: Self.cleanupTimeout,
            cancellable: false
        )
        let machineIDs = list.stdoutText.split(whereSeparator: \Character.isNewline)
        guard machineIDs.contains(Substring(id.value)) else {
            return
        }
        _ = try run(
            ["machine", "delete", id.value],
            timeout: Self.cleanupTimeout,
            cancellable: false
        )
    }

    func stopRunner(on id: RunnerID) throws {
        _ = try run(
            [
                "machine", "run",
                "--name", id.value,
                "--user", RunnerGuestUser.root.rawValue,
                "--",
                "yieldd-runner-control", "stop",
            ],
            timeout: Self.runnerStopTimeout,
            cancellable: false
        )
    }

    private func run(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        cancellable: Bool = true
    ) throws -> ProcessResult {
        let request = ProcessRequest(
            executableURL: containerURL,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout,
            cancellable: cancellable
        )
        return try executor.execute(request).requireSuccess(for: request)
    }
}
