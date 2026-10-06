import Foundation

final class AppleContainerBackend: RunnerBackend {
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
    private let loadStorage: () throws -> RunnerStorage?
    private let stateDirectory: URL
    private let network: (any RunnerNetworking)?
    private let checkCancellation: () throws -> Void
    private let maximumExecutionDeadline: () -> DispatchTime?
    private let lock = NSLock()
    private var relays: [RunnerID: any RunnerNetworkRelaying] = [:]

    init(
        containerURL: URL,
        executor: any ProcessExecuting,
        stateDirectory: URL,
        loadStorage: (() throws -> RunnerStorage?)? = nil,
        network: (any RunnerNetworking)? = nil,
        checkCancellation: @escaping () throws -> Void = {},
        maximumExecutionDeadline: @escaping () -> DispatchTime? = { nil },
        dockerReadiness: DockerReadiness = DockerReadiness()
    ) {
        self.containerURL = containerURL
        self.executor = executor
        self.dockerReadiness = dockerReadiness
        self.stateDirectory = stateDirectory
        self.network = network
        self.checkCancellation = checkCancellation
        self.maximumExecutionDeadline = maximumExecutionDeadline
        self.loadStorage = loadStorage ?? {
            let storage = try RunnerStorage.validated(in: stateDirectory, executor: executor)
            try storage.validateContainer(containerExecutable: containerURL, executor: executor)
            return storage
        }
    }

    func prepare() throws {
        _ = try loadStorage()
        if network == nil {
            try RunnerNetwork.requireRelay()
            try Self.requireNetworkSupport(containerURL: containerURL, executor: executor)
        }
    }

    func create(id: RunnerID, memory allocation: RunnerMemoryAllocation) throws {
        try create(id: id, memory: allocation, recordIntent: {})
    }

    func create(id: RunnerID, memory allocation: RunnerMemoryAllocation, recordIntent: () throws -> Void) throws {
        try lock.withLock {
            try checkCancellation()
            try prepare()
            guard relays[id] == nil else { throw POSIXError(.EEXIST) }
            try recordIntent()
            let provider = try network ?? RunnerNetwork(stateDirectory: stateDirectory)
            let relay = try provider.start(for: id, checkCancellation: checkCancellation)
            relays[id] = relay
            _ = try run([
                "machine", "create",
                "--name", id.value,
                "--no-boot",
                "--network-socket", relay.socketURL.path,
                "--home-mount", "none",
                "--cpus", String(Self.virtualCPUs),
                "--memory", Self.memoryArgument,
                Self.image,
            ], timeout: Self.creationTimeout, checking: relay.check)
            let result = try run(["machine", "inspect", id.value], timeout: 10,
                                 outputCapture: .tail(maxBytes: 64 * 1_024), checking: relay.check)
            try Self.requireRelayConfiguration(result.stdout, id: id, socket: relay.socketURL)
        }
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
            outputCapture: .tail(maxBytes: 64 * 1_024),
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
        try checkCancellation()
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
        let relay = try lock.withLock {
            guard let relay = relays[id] else { throw AppleContainerNetworkError.notReady(id) }
            return relay
        }
        return try run(
            containerArguments,
            standardInput: standardInput,
            timeout: timeout,
            outputCapture: outputCapture,
            checking: relay.check
        )
    }

    func destroy(_ id: RunnerID) throws {
        try lock.withLock {
            var failures: [RunnerSessionCleanupFailure] = []
            if let relay = relays[id] {
                do { try relay.stop(deadline: maximumExecutionDeadline()) }
                catch { failures.append(.init(step: .network, error: error)) }
            }
            do { try deleteMachine(id, storage: loadStorage()) }
            catch { failures.append(.init(step: .machine, error: error)) }
            if failures.count == 1 { throw failures[0].error }
            guard failures.isEmpty else { throw RunnerSessionError.cleanupFailed(failures) }
            // After an owner crash there is no relay object, only its socket directory.
            try RunnerNetworkDirectories(stateDirectory: stateDirectory).remove(id)
            relays.removeValue(forKey: id)
        }
    }

    private func deleteMachine(_ id: RunnerID, storage: RunnerStorage?) throws {
        guard try machineIDs().contains(id.value) else {
            try storage?.requireMachineRemoved(id)
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
        try storage?.requireMachineRemoved(id)
    }

    static func requireRelayConfiguration(_ data: Data, id: RunnerID, socket: URL) throws {
        struct Machine: Decodable {
            let id: String
            let homeMount: String
            let networkSocket: String
        }
        guard let machines = try? JSONDecoder().decode([Machine].self, from: data), machines.count == 1,
              machines[0].id == id.value, machines[0].homeMount == "none", machines[0].networkSocket == socket.path else {
            throw AppleContainerNetworkError.unsupportedConfiguration
        }
    }

    static func requireNetworkSupport(containerURL: URL, executor: any ProcessExecuting) throws {
        let request = ProcessRequest(executableURL: containerURL, arguments: ["machine", "create", "--help"],
                                     timeout: 5, outputCapture: .tail(maxBytes: 64 * 1_024))
        let result = try executor.execute(request).requireSuccess(for: request)
        guard result.stdoutText.contains("--network-socket") else { throw AppleContainerNetworkError.unsupportedCLI }
    }

    func stopRunner(on id: RunnerID) throws {
        _ = try loadStorage()
        _ = try run(
            [
                "machine", "run",
                "--name", id.value,
                "--user", RunnerGuestUser.root.rawValue,
                "--",
                "yieldd-runner-control", "stop",
            ],
            timeout: Self.runnerStopTimeout,
            outputCapture: .tail(maxBytes: 64 * 1_024),
            cancellable: false
        )
    }

    private func run(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        outputCapture: ProcessOutputCapture = .all,
        cancellable: Bool = true,
        checking: (() throws -> Void)? = nil
    ) throws -> ProcessResult {
        let request = ProcessRequest(
            executableURL: containerURL,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout,
            outputCapture: outputCapture,
            cancellable: cancellable
        )
        let result: ProcessResult
        if let checking { result = try executor.execute(request, checking: checking) }
        else { result = try executor.execute(request) }
        return try result.requireSuccess(for: request)
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

enum AppleContainerNetworkError: Error, LocalizedError {
    case notReady(RunnerID)
    case unsupportedCLI
    case unsupportedConfiguration

    var errorDescription: String? {
        switch self {
        case let .notReady(id): "The Linux runner network is not ready for \(id.value)."
        case .unsupportedCLI:
            "This Container executable does not support isolated runner networking. Build and install the pinned fork with Scripts/build-runner-container.sh, then restart Container before starting yieldd."
        case .unsupportedConfiguration:
            "Apple Container did not retain the isolated relay configuration. Build and install the pinned fork with Scripts/build-runner-container.sh, restart Container, and retry. The guest was not booted."
        }
    }
}
