import Foundation
import ServiceManagement
import Testing
@testable import Yieldd

@Test
func agentInstallRegistersAndSavesNewConfiguration() throws {
    let fixture = try AgentServiceFixture(status: .notRegistered)
    defer { fixture.remove() }

    try installAgent(
        configuration: fixture.configuration,
        store: fixture.store,
        service: fixture.service
    )

    #expect(fixture.registerCalls == 1)
    #expect(try fixture.store.load() == fixture.configuration)
}

@Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
func agentInstallRepairsMissingConfiguration(
    status: SMAppService.Status
) throws {
    let fixture = try AgentServiceFixture(status: status)
    defer { fixture.remove() }

    try installAgent(
        configuration: fixture.configuration,
        store: fixture.store,
        service: fixture.service
    )

    #expect(fixture.registerCalls == 0)
    #expect(try fixture.store.load() == fixture.configuration)
}

@Test
func agentInstallRepairsInvalidConfiguration() throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    try Data("{".utf8).write(to: fixture.store.fileURL)

    try installAgent(
        configuration: fixture.configuration,
        store: fixture.store,
        service: fixture.service
    )

    #expect(try fixture.store.load() == fixture.configuration)
}

@Test
func agentInstallRejectsAChangedEnabledConfiguration() throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    let existing = try AgentConfiguration(
        repositories: [GitHubRepository("owner/other")],
        containerURL: fixture.configuration.containerURL,
        ghURL: fixture.configuration.ghURL
    )
    try fixture.store.save(existing)

    #expect(throws: AgentError.configurationChanged) {
        try installAgent(
            configuration: fixture.configuration,
            store: fixture.store,
            service: fixture.service
        )
    }
}

@Test
func agentInstallRecognizesApprovalAfterRegistrationError() throws {
    let fixture = try AgentServiceFixture(status: .notRegistered)
    defer { fixture.remove() }
    fixture.registerError = AgentServiceTestError.registrationDenied
    fixture.statusAfterRegister = .requiresApproval

    try installAgent(
        configuration: fixture.configuration,
        store: fixture.store,
        service: fixture.service
    )

    #expect(fixture.registerCalls == 1)
}

@Test
func agentInstallPreservesUnexpectedRegistrationErrors() throws {
    let fixture = try AgentServiceFixture(status: .notRegistered)
    defer { fixture.remove() }
    fixture.registerError = AgentServiceTestError.registrationFailed

    #expect(throws: AgentServiceTestError.registrationFailed) {
        try installAgent(
            configuration: fixture.configuration,
            store: fixture.store,
            service: fixture.service
        )
    }
}

@Test
func agentInstallDoesNotConcealServiceNotFound() throws {
    let fixture = try AgentServiceFixture(status: .notFound)
    defer { fixture.remove() }

    #expect(throws: AgentError.serviceNotFound) {
        try installAgent(
            configuration: fixture.configuration,
            store: fixture.store,
            service: fixture.service
        )
    }
    #expect(fixture.registerCalls == 0)
}

@Test
func agentStatusReportsLeasesBeforeReturningInvalidConfiguration() throws {
    let fixture = try AgentServiceFixture(status: .notFound)
    defer { fixture.remove() }
    try Data("{".utf8).write(to: fixture.store.fileURL)
    let leaseStore = try RunnerLeaseStore(directory: fixture.store.directory)
    let id = RunnerID(value: "yieldd-status-test")
    try leaseStore.save(
        RunnerLease(
            runnerID: id,
            repository: try GitHubRepository("owner/repository")
        )
    )
    var lines: [String] = []

    #expect(throws: AgentConfigurationError.invalidContents(path: fixture.store.fileURL.path)) {
        try reportAgentStatus(
            store: fixture.store,
            service: fixture.service,
            output: { lines.append($0) }
        )
    }

    #expect(lines.first == "macOS could not resolve the local agent registration.")
    #expect(lines.contains("Active runner leases:"))
    #expect(lines.contains("- \(id.value) (owner/repository)"))
}

@Test
func agentUninstallWaitsForUnregisterAndRecoveryBeforeRemovingConfiguration() async throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    try fixture.store.save(fixture.configuration)

    try await uninstallAgent(
        store: fixture.store,
        service: fixture.service,
        recover: {
            fixture.events.append("recover")
        }
    )

    #expect(fixture.events == ["unregister", "recover"])
    #expect(throws: AgentConfigurationError.missing(path: fixture.store.fileURL.path)) {
        try fixture.store.load()
    }
}

@Test
func agentUninstallPreservesConfigurationWhenRecoveryFails() async throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    try fixture.store.save(fixture.configuration)

    await #expect(throws: AgentServiceTestError.recoveryFailed) {
        try await uninstallAgent(
            store: fixture.store,
            service: fixture.service,
            recover: {
                throw AgentServiceTestError.recoveryFailed
            }
        )
    }

    #expect(try fixture.store.load() == fixture.configuration)
}

@Test
func agentUninstallTreatsConfirmedMissingServiceAsAlreadyStopped() async throws {
    let fixture = try AgentServiceFixture(status: .notFound)
    defer { fixture.remove() }
    fixture.unregisterError = NSError(
        domain: SMAppServiceErrorDomain,
        code: Int(kSMErrorJobNotFound)
    )
    var recovered = false

    try await uninstallAgent(
        store: fixture.store,
        service: fixture.service,
        recover: {
            recovered = true
        }
    )

    #expect(fixture.unregisterCalls == 1)
    #expect(recovered)
}

@Test
func agentStatusReportsMacOSSlotsAndTemplate() throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    let configuration = try AgentConfiguration(
        repositories: [], macOSRepositories: [GitHubRepository("owner/mac"), GitHubRepository("owner/mac")],
        macOSTemplateURL: fixture.directory.appendingPathComponent("Template.bundle"),
        containerURL: nil, ghURL: fixture.configuration.ghURL
    )
    try fixture.store.save(configuration)
    var lines: [String] = []
    try reportAgentStatus(store: fixture.store, service: fixture.service, output: { lines.append($0) })
    #expect(lines.contains("macOS repositories: owner/mac, owner/mac"))
    #expect(lines.contains("macOS template: \(try #require(configuration.runners.macOSTemplateURL).path)"))
    #expect(!lines.contains { $0.hasPrefix("container:") })
}

@Test
func agentInstallRejectsChangedMacOSTemplateWhileEnabled() throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    func configuration(_ name: String) throws -> AgentConfiguration {
        try AgentConfiguration(
            repositories: [], macOSRepositories: [GitHubRepository("owner/mac")],
            macOSTemplateURL: fixture.directory.appendingPathComponent(name),
            containerURL: nil, ghURL: fixture.configuration.ghURL
        )
    }
    let existing = try configuration("Original.bundle")
    try fixture.store.save(existing)
    #expect(throws: AgentError.configurationChanged) {
        try installAgent(configuration: configuration("Replacement.bundle"), store: fixture.store, service: fixture.service)
    }
    #expect(try fixture.store.load() == existing)
    #expect(fixture.registerCalls == 0)
}

@Test(arguments: [RunnerPlatform.linux, .macOS], [nil, RunnerPlatform.linux, .macOS])
func agentStartsContainerOnlyForLinuxSlotsOrLeases(platform: RunnerPlatform, leasePlatform: RunnerPlatform?) throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    let repository = try GitHubRepository("owner/repo")
    let configuration = try AgentConfiguration(
        repositories: platform == .linux ? [repository] : [],
        macOSRepositories: platform == .macOS ? [repository] : [],
        macOSTemplateURL: platform == .macOS ? fixture.directory.appendingPathComponent("Missing.bundle") : nil,
        containerURL: fixture.configuration.containerURL, ghURL: fixture.configuration.ghURL
    )
    let leases = try RunnerLeaseStore(directory: fixture.directory)
    if let leasePlatform {
        try leases.save(RunnerLease(runnerID: RunnerID(value: "yieldd-abandoned"), repository: repository, platform: leasePlatform))
    }
    let needsContainer = platform == .linux || leasePlatform == .linux
    let executor = RecordingProcessExecutor(outcomes: needsContainer ? [.success(processResult())] : [])
    try startAgentContainerIfNeeded(configuration: configuration, leaseStore: leases, executor: executor)
    #expect(executor.requests.count == (needsContainer ? 1 : 0))
    if needsContainer {
        let request = try #require(executor.requests.first)
        #expect(request.executableURL == configuration.containerURL)
        #expect(request.arguments == ["system", "start", "--disable-kernel-install", "--timeout", "60"])
    }
}

private final class AgentServiceFixture {
    let directory: URL
    let store: AgentConfigurationStore
    let configuration: AgentConfiguration
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status?
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    var registerCalls = 0
    var unregisterCalls = 0
    var events: [String] = []

    init(status: SMAppService.Status) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yieldd-agent-service-\(UUID().uuidString)", isDirectory: true)
        store = try AgentConfigurationStore(directory: directory)
        configuration = try AgentConfiguration(
            repositories: [GitHubRepository("owner/repository")],
            containerURL: URL(fileURLWithPath: "/usr/local/bin/container"),
            ghURL: URL(fileURLWithPath: "/opt/homebrew/bin/gh")
        )
        self.status = status
    }

    var service: LocalAgentService {
        LocalAgentService(
            status: { self.status },
            register: {
                self.registerCalls += 1
                if let statusAfterRegister = self.statusAfterRegister {
                    self.status = statusAfterRegister
                }
                if let registerError = self.registerError {
                    throw registerError
                }
            },
            unregister: {
                self.unregisterCalls += 1
                self.events.append("unregister")
                if let unregisterError = self.unregisterError {
                    throw unregisterError
                }
                self.status = .notRegistered
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum AgentServiceTestError: Error {
    case registrationDenied
    case registrationFailed
    case recoveryFailed
}
