import Foundation

final class AppleContainerBackend: NativeCacheBackend {
    let platform = RunnerPlatform.linux
    static let creationTimeout: TimeInterval = 5 * 60
    static let memoryConfigurationTimeout: TimeInterval = 30
    static let cleanupTimeout: TimeInterval = 90
    static let inspectionTimeout: TimeInterval = 10
    static let preflightTimeout: TimeInterval = 5
    static let virtualCPUs = 4
    static let memoryGibibytes: UInt64 = 12
    static let memoryBytes = memoryGibibytes * 1_024 * 1_024 * 1_024
    static let memoryArgument = "\(memoryGibibytes)G"
    static let image = "local/yieldd-guest:dev"

    let containerURL: URL
    let executor: any ProcessExecuting
    let dockerReadiness: DockerReadiness
    private let loadStorage: () throws -> RunnerStorage?
    private let ownershipDescriptor: Int32?
    private let stateDirectory: URL
    private let network: any RunnerNetworking
    private let checkCancellation: () throws -> Void
    private let maximumExecutionDeadline: () -> DispatchTime?
    private let lock = NSLock()
    private struct Guest {
        let relay: any RunnerNetworkRelaying
        let cacheExchange: URL?
        var booted = false
    }
    private var guests: [RunnerID: Guest] = [:]
    private var pendingCacheExchanges: [RunnerID: URL] = [:]

    func prepareNativeCache(exchangeDirectory: URL, on id: RunnerID) throws {
        try lock.withLock {
            guard id.isValid, guests[id] == nil, pendingCacheExchanges[id] == nil else { throw POSIXError(.EEXIST) }
            pendingCacheExchanges[id] = exchangeDirectory
        }
    }

    func attachNativeCache(image: URL, cold: Bool, on id: RunnerID) throws {
        guard lock.withLock({ guests[id]?.cacheExchange?.appendingPathComponent("cache.img").path == image.path }) else {
            throw AppleContainerBackendError.unsupportedConfiguration
        }
        try exec(["yieldd-native-cache", "mount", cold ? "cold" : "warm"], timeout: 120,
                 outputCapture: .tail(maxBytes: 4096), as: .root, on: id)
    }

    func detachNativeCache(on id: RunnerID) throws {
        try exec(["yieldd-native-cache", "unmount"], timeout: 120,
                 outputCapture: .tail(maxBytes: 4096), as: .root, on: id)
    }

    init(
        containerURL: URL,
        executor: any ProcessExecuting,
        stateDirectory: URL,
        ownershipDescriptor: Int32? = nil,
        loadStorage: (() throws -> RunnerStorage?)? = nil,
        network: (any RunnerNetworking)? = nil,
        checkCancellation: @escaping () throws -> Void = {},
        maximumExecutionDeadline: @escaping () -> DispatchTime? = { nil },
        dockerReadiness: DockerReadiness = DockerReadiness()
    ) throws {
        self.containerURL = containerURL
        self.executor = executor
        self.dockerReadiness = dockerReadiness
        self.ownershipDescriptor = ownershipDescriptor
        self.stateDirectory = stateDirectory
        self.network = try network ?? RunnerNetwork(stateDirectory: stateDirectory, platform: .linux)
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
    }

    func create(id: RunnerID, memory allocation: RunnerMemoryAllocation) throws {
        try create(id: id, memory: allocation, recordIntent: {})
    }

    func create(id: RunnerID, memory allocation: RunnerMemoryAllocation, recordIntent: () throws -> Void) throws {
        try lock.withLock {
            let exchange = pendingCacheExchanges.removeValue(forKey: id)
            try checkCancellation()
            try prepare()
            guard guests[id] == nil else { throw POSIXError(.EEXIST) }
            try recordIntent()
            let relay = try network.start(for: id, checkCancellation: checkCancellation)
            guests[id] = Guest(relay: relay, cacheExchange: exchange)
            var arguments = [
                "machine", "create",
                "--name", id.value,
                "--no-boot",
                "--network-socket", relay.socketURL.path,
                "--home-mount", "none",
                "--cpus", String(Self.virtualCPUs),
                "--memory", Self.memoryArgument,
            ]
            if let exchange { arguments += ["--cache-exchange", exchange.path] }
            arguments.append(Self.image)
            _ = try run(arguments, timeout: Self.creationTimeout, ownershipDescriptor: ownershipDescriptor, checking: relay.check)
            let result = try run(["machine", "inspect", id.value], timeout: Self.inspectionTimeout,
                                 outputCapture: .tail(maxBytes: 64 * 1_024), checking: relay.check)
            try Self.requireRelayConfiguration(result.stdout, id: id, socket: relay.socketURL, exchange: exchange)
            _ = try run(["machine", "boot", id.value], timeout: Self.creationTimeout, checking: relay.check)
            guests[id]?.booted = true
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
            guard let guest = guests[id], guest.booted else { throw AppleContainerBackendError.notReady(id) }
            return guest.relay
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
            if let guest = guests[id] {
                do { try guest.relay.stop(deadline: maximumExecutionDeadline()) }
                catch { failures.append(.init(step: .network, error: error)) }
            }
            do { try deleteMachine(id, storage: loadStorage()) }
            catch { failures.append(.init(step: .machine, error: error)) }
            if failures.count == 1 && failures[0].step == .machine { throw failures[0].error }
            guard failures.isEmpty else { throw RunnerSessionError.cleanupFailed(failures) }
            // After an owner crash there is no relay object, only its socket directory.
            try RunnerNetworkDirectories(stateDirectory: stateDirectory).remove(id)
            guests.removeValue(forKey: id)
            pendingCacheExchanges.removeValue(forKey: id)
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

    static func requireRelayConfiguration(_ data: Data, id: RunnerID, socket: URL, exchange: URL? = nil) throws {
        struct Machine: Decodable, Equatable {
            let id: String
            let homeMount: String
            let networkSocket: String?
            let cacheExchange: String?
        }
        let machines: [Machine]
        do { machines = try JSONDecoder().decode([Machine].self, from: data) }
        catch { throw AppleContainerBackendError.invalidInspection }
        guard machines == [Machine(id: id.value, homeMount: "none", networkSocket: socket.path, cacheExchange: exchange?.path)] else {
            throw AppleContainerBackendError.unsupportedConfiguration
        }
    }

    static func requireNetworkSupport(containerURL: URL, executor: any ProcessExecuting, requiresNativeCache: Bool = false) throws {
        let request = ProcessRequest(executableURL: containerURL, arguments: ["machine", "create", "--help"],
                                     timeout: Self.preflightTimeout, outputCapture: .tail(maxBytes: 64 * 1_024))
        let result = try executor.execute(request).requireSuccess(for: request)
        guard result.stdoutText.contains("--network-socket") else { throw AppleContainerBackendError.unsupportedCLI }
        if requiresNativeCache && !result.stdoutText.contains("--cache-exchange") {
            throw AppleContainerBackendError.unsupportedCacheCLI
        }
        let boot = ProcessRequest(executableURL: containerURL, arguments: ["machine", "boot", "--help"],
                                  timeout: Self.preflightTimeout, outputCapture: .tail(maxBytes: 64 * 1_024))
        try executor.execute(boot).requireSuccess(for: boot)
    }

    private func run(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        outputCapture: ProcessOutputCapture = .all,
        cancellable: Bool = true,
        ownershipDescriptor: Int32? = nil,
        checking: @escaping () throws -> Void = {}
    ) throws -> ProcessResult {
        let request = ProcessRequest(
            executableURL: containerURL,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout,
            outputCapture: outputCapture,
            cancellable: cancellable,
            ownershipDescriptor: ownershipDescriptor
        )
        let result = try executor.execute(request, checking: checking)
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

enum AppleContainerBackendError: Error, LocalizedError, Equatable {
    case notReady(RunnerID)
    case unsupportedCLI
    case unsupportedCacheCLI
    case unsupportedConfiguration
    case invalidInspection

    var errorDescription: String? {
        switch self {
        case let .notReady(id): "The Linux runner network is not ready for \(id.value)."
        case .unsupportedCLI:
            "This Container executable does not support isolated runner networking. Build and install the pinned fork with Scripts/build-runner-container.sh, then restart Container before starting yieldd."
        case .unsupportedCacheCLI:
            "Linux cache disks require an updated Container fork. Run Scripts/build-runner-container.sh, install the package, and restart Container."
        case .unsupportedConfiguration:
            "Apple Container did not retain the isolated relay configuration. Build and install the pinned fork with Scripts/build-runner-container.sh, restart Container, and retry. The guest was not booted."
        case .invalidInspection:
            "Apple Container returned an invalid machine inspection. The guest was not booted."
        }
    }
}
