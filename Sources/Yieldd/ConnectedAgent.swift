import ArgumentParser
import Darwin
import Foundation
import Security
import LocalAuthentication

struct ConnectedAgentConfiguration: Codable, Equatable, Sendable {
    let server: URL
    let deviceID: String
    let platforms: [RunnerPlatform]
    let template: URL?
    let container: URL?

    func validate() throws {
        _ = try ConnectedHTTPClient.serverURL(server.absoluteString)
        guard UUID(uuidString: deviceID)?.uuidString.lowercased() == deviceID,
              !platforms.isEmpty, Set(platforms).count == platforms.count,
              platforms.contains(.macOS) == (template != nil),
              !platforms.contains(.linux) || container != nil else {
            throw ConnectedAgentError.invalidConfiguration
        }
        for case let url? in [template, container] {
            guard url.isFileURL, url.path.hasPrefix("/") else { throw ConnectedAgentError.invalidConfiguration }
        }
    }

    func requireIdentity(server: URL, deviceID: String) throws {
        guard self.deviceID == deviceID,
              try ConnectedHTTPClient.serverURL(self.server.absoluteString) == ConnectedHTTPClient.serverURL(server.absoluteString) else {
            throw ConnectedRunnerError.identityChanged
        }
    }

    var credentialAccount: String { "\(server.absoluteString)|\(deviceID)" }

    func resolveContainer() throws -> URL {
        guard let container else { throw AgentConfigurationError.containerPathNotRecorded }
        guard FileManager.default.isExecutableFile(atPath: container.path) else {
            throw AgentConfigurationError.executableUnavailable(path: container.path)
        }
        return container
    }
}

struct ConnectedAgentStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("connected-agent.json") }

    func load() throws -> ConnectedAgentConfiguration? {
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
            throw ConnectedAgentError.invalidConfiguration
        }
        let data = try handle.read(upToCount: AgentConfigurationStore.maximumBytes + 1) ?? Data()
        guard data.count <= AgentConfigurationStore.maximumBytes else { throw ConnectedAgentError.invalidConfiguration }
        let configuration = try JSONDecoder().decode(ConnectedAgentConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    func save(_ configuration: ConnectedAgentConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        let temporary = directory.appendingPathComponent(".connected-agent-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeRunnerState(directory)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: file)
        try synchronizeRunnerState(directory)
    }
}

struct ConnectedAgentCredentials: Sendable {
    let load: @Sendable (String) throws -> String
    let save: @Sendable (String, String) throws -> Void
    let remove: @Sendable (String) throws -> Void

    static let keychain = ConnectedAgentCredentials(load: { account in
        var query = keychainQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw ConnectedAgentError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ConnectedRunnerError.invalidToken
        }
        try ConnectedHTTPClient.validateToken(token)
        return token
    }, save: { account, token in
        try ConnectedHTTPClient.validateToken(token)
        let query = keychainQuery(account)
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(token.utf8)
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ConnectedAgentError.keychain(added) }
        } else if status != errSecSuccess {
            throw ConnectedAgentError.keychain(status)
        }
    }, remove: { account in
        let status = SecItemDelete(keychainQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectedAgentError.keychain(status) }
    })
}

private func keychainQuery(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "dev.yieldd.connected-agent",
     kSecAttrAccount as String: account,
     kSecAttrSynchronizable as String: false]
}

func installConnectedAgent(configuration: ConnectedAgentConfiguration, token: String,
                           store: ConnectedAgentStore, credentials: ConnectedAgentCredentials,
                           service: LocalAgentService) throws {
    try configuration.validate()
    try ConnectedHTTPClient.validateToken(token)
    guard !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("agent.json").path) else {
        throw AgentError.configurationChanged
    }
    if let previous = try store.load() {
        guard previous == configuration, try credentials.load(previous.credentialAccount) == token else {
            throw AgentError.configurationChanged
        }
    } else {
        guard service.status() == .notRegistered else { throw AgentError.configurationChanged }
        try withRunnerOwnership(in: store.directory, connected: true) { leases in
            guard try leases.load().isEmpty else { throw ConnectedAgentError.standaloneRecoveryRequired }
            for journal in ConnectedRunnerStore.all(in: store.directory) {
                if let lease = try journal.load() {
                    try configuration.requireIdentity(server: ConnectedHTTPClient.serverURL(lease.server), deviceID: lease.deviceID)
                    if lease.offer.runnerPlatform == .linux, configuration.container == nil {
                        throw ConnectedAgentError.recoveryContainerRequired
                    }
                }
            }
            try credentials.save(configuration.credentialAccount, token)
            try store.save(configuration)
        }
    }
    try enableAgent(service: service)
}

func uninstallConnectedAgent(store: ConnectedAgentStore, credentials: ConnectedAgentCredentials,
                             service: LocalAgentService,
                             recover: (ConnectedAgentConfiguration, String) throws -> Void) async throws {
    try await disableAgent(service: service)
    guard let configuration = try store.load() else { throw ConnectedAgentError.invalidConfiguration }
    let token = try ConnectedRunnerStore.hasRecovery(in: store.directory)
        ? credentials.load(configuration.credentialAccount) : ""
    try recover(configuration, token)
    try credentials.remove(configuration.credentialAccount)
    try store.remove()
}

func recoverConnectedAgent(configuration: ConnectedAgentConfiguration, token: String,
                           directory: URL, stop: RunnerPoolStop, output: RunnerServiceOutput = .terminal) throws {
    try withRunnerOwnership(in: directory, connected: true) { leases in
        guard try leases.load().isEmpty else { throw ConnectedAgentError.standaloneRecoveryRequired }
        try recoverConnectedPlatforms(directory: directory, server: configuration.server, deviceID: configuration.deviceID,
            token: token, confirmation: nil, stop: stop, resolveContainer: configuration.resolveContainer, output: output)
        try removeUnleasedRunnerFiles(in: directory, keeping: [], checkCancellation: stop.check)
    }
}

struct AgentInstallConnectedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install-connected", abstract: "Configure and enable the connected agent at login.")

    @Option(name: .long, help: "Coordinator HTTPS origin.") var server: String
    @Option(name: .long, help: "Lowercase device UUID configured on the coordinator.") var deviceID: String
    @Option(name: .long, help: "Platform to offer: linux or macos. Repeat for both. Defaults to linux.") var platform: [ConnectedPlatform] = []
    @Option(name: .long, help: "Absolute macOS template bundle path.") var macosTemplate: String?

    @Flag(name: .long, help: .hidden) var preflightOnly = false

    mutating func run() throws {
        let service = try localAgentService()
        let standalone = try AgentConfigurationStore()
        let platforms = (platform.isEmpty ? [.linux] : platform).map(\.runnerPlatform)
        let locator = ExecutableLocator()
        let container: URL?
        do { container = try locator.locate("container") }
        catch ExecutableLocatorError.notFound where !platforms.contains(.linux) { container = nil }
        if let macosTemplate, !macosTemplate.hasPrefix("/") { throw ConnectedAgentError.invalidConfiguration }
        let configuration = ConnectedAgentConfiguration(server: try ConnectedHTTPClient.serverURL(server), deviceID: deviceID,
            platforms: platforms, template: macosTemplate.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, container: container)
        try configuration.validate()
        let memory = RunnerMemoryAdmission()
        for platform in platforms { try memory.validateCapacity(reserving: platform.memoryReservationBytes) }
        let storage = try RunnerStorage.required(in: standalone.directory)
        try storage.validate(stateDirectory: standalone.directory)
        if let template = configuration.template {
            try storage.validateMacOS(template: template, clones: storage.clonesURL)
            try validateRunnerServiceTemplate(template, stateDirectory: standalone.directory)
        }
        try RunnerNetwork.requireRelay()
        if platforms.contains(.linux), let container {
            try storage.validatePath(storage.containerURL)
            try AppleContainerBackend.requireNetworkSupport(containerURL: container, executor: ProcessExecutor())
        }
        let token = ProcessInfo.processInfo.environment["YIELDD_CLIENT_TOKEN"] ?? ""
        try ConnectedHTTPClient.validateToken(token)
        guard !preflightOnly else {
            print(platforms.contains(.linux) ? "linux" : "macos")
            return
        }
        try installConnectedAgent(configuration: configuration, token: token,
            store: ConnectedAgentStore(directory: standalone.directory), credentials: .keychain, service: service)
        print(registrationStatusDescription(service.status()))
    }
}

enum ConnectedAgentError: Error, LocalizedError {
    case invalidConfiguration, standaloneRecoveryRequired, recoveryContainerRequired
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .standaloneRecoveryRequired: "Run yieldd recover to clean up standalone runner leases before using connected mode."
        case .recoveryContainerRequired: "An outstanding Linux assignment needs a saved container executable. Recover it with the original connect command before installing a macOS-only agent."
        case .invalidConfiguration: "The connected agent needs a valid coordinator, device UUID, distinct platforms, and absolute paths for its tools and macOS template."
        case .keychain(errSecItemNotFound): "The connected agent token is missing from Keychain. Restore its original token before recovering outstanding assignments."
        case let .keychain(status): "Connected agent credential access failed (Keychain status \(status)). Unlock the login keychain and retry."
        }
    }
}

func prepareConnectedAgentKeychain() throws {
    // The file-based login keychain has ACL prompts outside LocalAuthentication.
    // This process runs as a LaunchAgent and must fail instead of showing them.
    let status = SecKeychainSetUserInteractionAllowed(false)
    guard status == errSecSuccess else { throw ConnectedAgentError.keychain(status) }
}
