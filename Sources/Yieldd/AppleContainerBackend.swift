import Foundation

struct AppleContainerBackend: RunnerBackend {
    let platform = RunnerPlatform.linux
    static let creationTimeout: TimeInterval = 5 * 60
    static let memoryConfigurationTimeout: TimeInterval = 30
    static let cleanupTimeout: TimeInterval = 90
    static let runnerStopTimeout: TimeInterval = 30
    static let virtualCPUs = 4
    static let memoryGibibytes: UInt64 = 12
    static let memoryBytes = memoryGibibytes * 1_024 * 1_024 * 1_024
    static let memoryArgument = "\(memoryGibibytes)G"
    static let image = "local/yieldd-guest:dev"

    let containerURL: URL
    let executor: any ProcessExecuting
    let dockerReadiness: DockerReadiness

    init(
        containerURL: URL,
        executor: any ProcessExecuting,
        dockerReadiness: DockerReadiness = DockerReadiness()
    ) {
        self.containerURL = containerURL
        self.executor = executor
        self.dockerReadiness = dockerReadiness
    }

    func create(id: RunnerID, memory allocation: RunnerMemoryAllocation) throws {
        _ = try run([
            "machine", "create",
            "--name", id.value,
            "--home-mount", "none",
            "--cpus", String(Self.virtualCPUs),
            "--memory", Self.memoryArgument,
            Self.image,
        ], timeout: Self.creationTimeout)
        try dockerReadiness.wait {
            _ = try exec(
                ["docker", "info"],
                timeout: DockerReadiness.probeTimeout,
                on: id
            )
        }
        try exec(
            ["yieldd-runner-control", "memory", allocation.rawValue],
            timeout: Self.memoryConfigurationTimeout,
            outputCapture: .all,
            as: .root,
            on: id
        )
    }

    @discardableResult func exec(
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
