import Foundation
import ServiceManagement
import Synchronization
import Testing
@testable import Yieldd

private let agentConfiguration = ConnectedAgentConfiguration(
    server: URL(string: "https://coordinator.example")!, deviceID: "01234567-89ab-4def-8123-456789abcdef",
    platforms: [.linux], template: nil, container: URL(fileURLWithPath: "/usr/local/bin/container"))
private let agentToken = String(repeating: "a", count: 32)

@Test
func connectedAgentPersistsOnlyConfigurationWithPrivatePermissions() throws {
    let fixture = try ConnectedAgentFixture()
    defer { fixture.remove() }
    try fixture.store.save(agentConfiguration)
    #expect(try fixture.store.load() == agentConfiguration)
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.store.file.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(try !String(contentsOf: fixture.store.file, encoding: .utf8).contains(agentToken))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.store.file.path)
    #expect(throws: ConnectedAgentError.self) { try fixture.store.load() }
}

@Test
func connectedAgentRejectsSymlinkAndInvalidPlatformConfiguration() throws {
    let fixture = try ConnectedAgentFixture()
    defer { fixture.remove() }
    let target = fixture.store.directory.appendingPathComponent("target")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: fixture.store.file, withDestinationURL: target)
    #expect(throws: (any Error).self) { try fixture.store.load() }
    let invalid = ConnectedAgentConfiguration(server: agentConfiguration.server, deviceID: agentConfiguration.deviceID,
        platforms: [.macOS], template: nil, container: nil)
    #expect(throws: ConnectedAgentError.self) { try invalid.validate() }
}

@Test
func connectedAgentInstallationIsIdempotentAndRejectsCredentialChanges() throws {
    let fixture = try ConnectedAgentFixture()
    defer { fixture.remove() }
    let keychain = FakeAgentKeychain()
    let registered = Mutex(false)
    let service = LocalAgentService(status: { registered.withLock { $0 } ? .enabled : .notRegistered },
        register: { registered.withLock { $0 = true } }, unregister: {})
    try installConnectedAgent(configuration: agentConfiguration, token: agentToken, store: fixture.store,
        credentials: keychain.credentials, service: service)
    try installConnectedAgent(configuration: agentConfiguration, token: agentToken, store: fixture.store,
        credentials: keychain.credentials, service: service)
    #expect(keychain.values.withLock { $0[agentConfiguration.credentialAccount] } == agentToken)
    #expect(throws: AgentError.configurationChanged) {
        try installConnectedAgent(configuration: agentConfiguration, token: String(repeating: "b", count: 32),
            store: fixture.store, credentials: keychain.credentials, service: service)
    }
    #expect(keychain.values.withLock { $0[agentConfiguration.credentialAccount] } == agentToken)
}

@Test
func connectedAgentRetainsSettingsWhenRegistrationRequiresApproval() throws {
    let fixture = try ConnectedAgentFixture()
    defer { fixture.remove() }
    let keychain = FakeAgentKeychain()
    let requested = Mutex(false)
    let service = LocalAgentService(status: { requested.withLock { $0 } ? .requiresApproval : .notRegistered },
        register: { requested.withLock { $0 = true }; throw CocoaError(.userCancelled) }, unregister: {})
    try installConnectedAgent(configuration: agentConfiguration, token: agentToken, store: fixture.store,
        credentials: keychain.credentials, service: service)
    #expect(try fixture.store.load() == agentConfiguration)
}

@Test
func connectedAgentDoesNotReplaceStandaloneConfigurationOrDifferentRecoveryIdentity() throws {
    let fixture = try ConnectedAgentFixture()
    defer { fixture.remove() }
    let standalone = fixture.store.directory.appendingPathComponent("agent.json")
    try Data("original".utf8).write(to: standalone)
    let keychain = FakeAgentKeychain()
    let service = LocalAgentService(status: { .notRegistered }, register: { Issue.record("Must not register") }, unregister: {})
    #expect(throws: AgentError.configurationChanged) {
        try installConnectedAgent(configuration: agentConfiguration, token: agentToken, store: fixture.store,
            credentials: keychain.credentials, service: service)
    }
    try FileManager.default.removeItem(at: standalone)
    let offer = try ConnectedOffer(owner: agentConfiguration.deviceID,
        runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")
    try ConnectedRunnerStore(directory: fixture.store.directory).save(
        ConnectedLease(server: "https://other.example", deviceID: agentConfiguration.deviceID, offer: offer))
    #expect(throws: ConnectedRunnerError.identityChanged) {
        try installConnectedAgent(configuration: agentConfiguration, token: agentToken, store: fixture.store,
            credentials: keychain.credentials, service: service)
    }
    #expect(keychain.values.withLock { $0.isEmpty })
    #expect(try fixture.store.load() == nil)
}

@Test
func connectedAgentUninstallRetainsCredentialsAndSettingsUntilRecoverySucceeds() async throws {
    let fixture = try ConnectedAgentFixture()
    defer { fixture.remove() }
    let keychain = FakeAgentKeychain()
    try fixture.store.save(agentConfiguration)
    try keychain.credentials.save(agentConfiguration.credentialAccount, agentToken)
    let disabled = Mutex(false)
    let service = LocalAgentService(status: { .enabled }, register: {}, unregister: { disabled.withLock { $0 = true } })
    do {
        try await uninstallConnectedAgent(store: fixture.store, credentials: keychain.credentials, service: service) { _, _ in
            #expect(disabled.withLock { $0 })
            throw ConnectedRunnerError.transport
        }
        Issue.record("Expected failed recovery")
    } catch ConnectedRunnerError.transport {}
    #expect(try fixture.store.load() == agentConfiguration)
    #expect(try keychain.credentials.load(agentConfiguration.credentialAccount) == agentToken)
    try await uninstallConnectedAgent(store: fixture.store, credentials: keychain.credentials, service: service) { _, _ in }
    #expect(try fixture.store.load() == nil)
    #expect(keychain.values.withLock { $0.isEmpty })
}

@Test
func connectedUninstallDoesNotSweepOutstandingStandaloneGuests() throws {
    let fixture = try ConnectedAgentFixture()
    defer { fixture.remove() }
    let lease = RunnerLease(runnerID: RunnerID(value: "yieldd-macos-test-pending"),
        repository: try GitHubRepository("owner/repo"), platform: .macOS)
    let leases = try RunnerLeaseStore(directory: fixture.store.directory)
    try leases.save(lease)
    #expect(throws: ConnectedRunnerError.recoveryRequired) {
        try recoverConnectedAgent(configuration: agentConfiguration, token: "", directory: fixture.store.directory, stop: RunnerPoolStop())
    }
    #expect(try leases.load() == [lease])
}

private final class FakeAgentKeychain: Sendable {
    let values = Mutex<[String: String]>([:])
    var credentials: ConnectedAgentCredentials {
        ConnectedAgentCredentials(load: { account in
            try self.values.withLock { values in
                guard let value = values[account] else { throw ConnectedAgentError.keychain(-25300) }
                return value
            }
        }, save: { account, token in self.values.withLock { $0[account] = token } },
        remove: { account in _ = self.values.withLock { $0.removeValue(forKey: account) } })
    }
}

private struct ConnectedAgentFixture {
    let store: ConnectedAgentStore
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("connected-agent-\(UUID().uuidString)")
        _ = try AgentConfigurationStore(directory: directory)
        store = ConnectedAgentStore(directory: directory)
    }
    func remove() { try? FileManager.default.removeItem(at: store.directory) }
}
