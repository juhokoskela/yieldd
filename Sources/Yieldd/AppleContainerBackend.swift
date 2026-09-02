import Foundation

struct AppleContainerBackend: RunnerBackend {
    static let creationTimeout: TimeInterval = 5 * 60
    static let cleanupTimeout: TimeInterval = 90
    static let runnerStopTimeout: TimeInterval = 30
    static let virtualCPUs = 4
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
        ], timeout: Self.creationTimeout)
    }

    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
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
            timeout: timeout,
            outputCapture: outputCapture
        )
    }

    func destroy(_ id: RunnerID) throws {
        guard try machineIDs().contains(id.value) else {
            return
        }
        do {
            _ = try run(
                ["machine", "delete", id.value],
                timeout: Self.cleanupTimeout,
                cancellable: false
            )
        } catch {
            let deletionError = error
            guard let remainingMachineIDs = try? machineIDs(),
                  !remainingMachineIDs.contains(id.value) else {
                throw deletionError
            }
        }
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
        outputCapture: ProcessOutputCapture = .all,
        cancellable: Bool = true
    ) throws -> ProcessResult {
        let request = ProcessRequest(
            executableURL: containerURL,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout,
            outputCapture: outputCapture,
            cancellable: cancellable
        )
        return try executor.execute(request).requireSuccess(for: request)
    }

    private func machineIDs() throws -> Set<String> {
        let result = try run(
            ["machine", "list", "--quiet"],
            timeout: Self.cleanupTimeout,
            cancellable: false
        )
        return Set(result.stdoutText.split(whereSeparator: \Character.isNewline).map(String.init))
    }
}
