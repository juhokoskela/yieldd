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
        guard let container else { throw ConnectedAgentError.recoveryContainerRequired }
        guard FileManager.default.isExecutableFile(atPath: container.path) else {
            throw ConnectedAgentError.executableUnavailable(container.path)
        }
        return container
    }
}

struct ConnectedAgentStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("connected-agent.json") }

    func load() throws -> ConnectedAgentConfiguration? {
        guard let data = try readPrivateRunnerFile(file, maximumBytes: 16 * 1_024) else { return nil }
        let configuration = try JSONDecoder().decode(ConnectedAgentConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    func save(_ configuration: ConnectedAgentConfiguration) throws {
        try configuration.validate()
        try writePrivateRunnerFile(JSONEncoder().encode(configuration), to: file)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: file)
        try? AgentFailureStore(directory: directory).remove()
        try synchronizeRunnerState(directory)
    }
}

struct ConnectedAgentCredentials: Sendable {
    let load: @Sendable (String) throws -> String
    let save: @Sendable (String, String) throws -> Void
    let remove: @Sendable (String) throws -> Void

    static let keychain = ConnectedAgentCredentials(load: { account in
        try readConnectedAgentToken(account)
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

private func readConnectedAgentToken(_ account: String) throws -> String {
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
    if let previous = try store.load() {
        guard previous == configuration, try credentials.load(previous.credentialAccount) == token else {
            throw AgentError.configurationChanged
        }
        try service.refreshBundleRegistration()
    } else {
        try withRunnerOwnership(in: store.directory, connected: true) { leases in
            guard try store.load() == nil else { throw AgentError.configurationChanged }
            try validateEnrollment(configuration, leases: leases)
            try service.refreshBundleRegistration()
            guard service.status() == .notRegistered else { throw AgentError.configurationChanged }
            try credentials.save(configuration.credentialAccount, token)
            try store.save(configuration)
        }
    }
    try enableAgent(service: service)
}

private func validateEnrollment(_ configuration: ConnectedAgentConfiguration, leases: RunnerLeaseStore) throws {
    guard !FileManager.default.fileExists(atPath: leases.directory.appendingPathComponent("agent.json").path) else {
        throw RunnerOwnershipError.previousLease
    }
    for journal in ConnectedRunnerStore.all(in: leases.directory) {
        if let lease = try journal.load() {
            try configuration.requireIdentity(server: ConnectedHTTPClient.serverURL(lease.server), deviceID: lease.deviceID)
            if lease.offer.runnerPlatform == .linux, configuration.container == nil {
                throw ConnectedAgentError.recoveryContainerRequired
            }
        }
    }
}

func uninstallConnectedAgent(store: ConnectedAgentStore, credentials: ConnectedAgentCredentials,
                             service: LocalAgentService,
                             recover: (ConnectedAgentConfiguration, String) throws -> Void) async throws {
    try await disableAgent(service: service)
    guard let configuration = try store.load() else {
        if ConnectedRunnerStore.hasRecovery(in: store.directory) { throw ConnectedAgentError.invalidConfiguration }
        return
    }
    let token = try ConnectedRunnerStore.hasRecovery(in: store.directory)
        ? credentials.load(configuration.credentialAccount) : ""
    try recover(configuration, token)
    try credentials.remove(configuration.credentialAccount)
    try store.remove()
}

func recoverConnectedAgent(configuration: ConnectedAgentConfiguration, token: String,
                           directory: URL, stop: RunnerPoolStop, output: RunnerServiceOutput = .terminal) throws {
    try withRunnerOwnership(in: directory, connected: true) { store in
        try recoverConnectedPlatforms(directory: directory, server: configuration.server, deviceID: configuration.deviceID,
            token: token, confirmation: nil, stop: stop, resolveContainer: configuration.resolveContainer, output: output)
        try removeUnleasedRunnerFiles(in: directory, ownershipDescriptor: store.ownershipDescriptor, checkCancellation: stop.check)
    }
}

struct AgentInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Configure and enable the connected agent at login.")

    @Option(name: .long, help: "Coordinator HTTPS origin.") var server: String
    @Option(name: .long, help: "Lowercase device UUID configured on the coordinator.") var deviceID: String
    @Option(name: .long, help: "Platform to offer: linux or macos. Repeat for both. Defaults to linux.") var platform: [ConnectedPlatform] = []
    @Option(name: .long, help: "Absolute macOS template bundle path.") var macosTemplate: String?

    @Flag(name: .long, help: .hidden) var preflightOnly = false

    mutating func run() throws {
        let directory = try yielddApplicationSupportDirectory()
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
        let storage = try RunnerStorage.required(in: directory)
        try storage.validate(stateDirectory: directory)
        if let template = configuration.template {
            try storage.validateMacOS(template: template, clones: storage.clonesURL)
            try validateRunnerServiceTemplate(template, stateDirectory: directory)
        }
        try RunnerNetwork.requireRelay()
        if platforms.contains(.linux), let container {
            try storage.validatePath(storage.containerURL)
            try AppleContainerBackend.requireNetworkSupport(containerURL: container, executor: ProcessExecutor())
        }
        let store = ConnectedAgentStore(directory: directory)
        let token = ProcessInfo.processInfo.environment["YIELDD_CLIENT_TOKEN"] ?? ""
        try ConnectedHTTPClient.validateToken(token)
        let service = try localAgentService()
        if preflightOnly {
            let status = service.status()
            if status == .notFound { throw AgentError.serviceNotFound }
            guard status == .notRegistered, try store.load() == nil else { throw AgentError.configurationChanged }
            try withRunnerOwnership(in: directory, connected: true) { try validateEnrollment(configuration, leases: $0) }
            print(platforms.contains(.linux) ? "linux" : "macos")
            return
        }
        try installConnectedAgent(configuration: configuration, token: token,
            store: store, credentials: .keychain, service: service)
        print(registrationStatusDescription(service.status()))
    }
}

enum ConnectedAgentError: Error, LocalizedError {
    case invalidConfiguration, recoveryContainerRequired
    case executableUnavailable(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .executableUnavailable(path): "The configured executable is missing or not executable: \(path)"
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
