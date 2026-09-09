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

@Test(arguments: [false, true])
func agentStatusReportsMacOSSlotsAndTemplate(mixed: Bool) throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    let configuration = try AgentConfiguration(
        repositories: mixed ? [GitHubRepository("owner/linux")] : [],
        macOSRepositories: [GitHubRepository("owner/mac"), GitHubRepository("owner/mac")],
        macOSTemplateURL: fixture.directory.appendingPathComponent("Template.bundle"),
        containerURL: mixed ? fixture.configuration.containerURL : nil, ghURL: fixture.configuration.ghURL
    )
    try fixture.store.save(configuration)
    var lines: [String] = []
    try reportAgentStatus(store: fixture.store, service: fixture.service, output: { lines.append($0) })
    #expect(lines.filter { $0 == "- owner/mac (macOS)" }.count == 2)
    #expect(lines.contains("- owner/linux (linux)") == mixed)
    #expect(lines.contains("macOS template: \(try #require(configuration.runners.macOSTemplateURL).path)"))
    #expect(lines.contains { $0.hasPrefix("container:") } == mixed)
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

@Test(arguments: [false, true])
func agentUninstallRecoversMacOSLeasesWithoutContainer(mixed: Bool) async throws {
    let fixture = try AgentServiceFixture(status: .enabled)
    defer { fixture.remove() }
    let repository = try GitHubRepository("owner/repo")
    let configuration = try AgentConfiguration(
        repositories: mixed ? [repository] : [], macOSRepositories: [repository],
        macOSTemplateURL: fixture.directory.appendingPathComponent("Missing.bundle"),
        containerURL: URL(fileURLWithPath: "/missing/container"), ghURL: fixture.configuration.ghURL
    )
    let leases = try RunnerLeaseStore(directory: fixture.directory)
    let id = RunnerID(value: "yieldd-abandoned")
    try leases.save(RunnerLease(runnerID: id, repository: repository, platform: .macOS))
    let clone = try MacOSRunnerCloneStore(stateDirectory: fixture.directory).bundleURL(for: id)
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    try fixture.store.save(configuration)
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: #"[{"runners":[{"id":42,"name":"yieldd-abandoned","busy":false}]}]"#)),
        .success(processResult()),
    ])
    try await uninstallAgent(store: fixture.store, service: fixture.service, recover: {
        try recoverAgentRunners(store: fixture.store, stop: RunnerPoolStop(), executor: executor)
    })
    #expect(try leases.load().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: clone.path))
    #expect(executor.requests.count == 2)
    #expect(executor.requests.allSatisfy { $0.executableURL == configuration.ghURL })
    #expect(executor.requests.last?.arguments.contains("DELETE") == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
}

@Test(arguments: [false, true])
func agentRecoveryKeepsLinuxFailuresIndependentOfMacOSCleanup(missingContainerPath: Bool) throws {
    let fixture = try AgentServiceFixture(status: .notRegistered)
    defer { fixture.remove() }
    let repository = try GitHubRepository("owner/repo")
    let configuration = try AgentConfiguration(
        repositories: [], macOSRepositories: [repository],
        macOSTemplateURL: fixture.directory.appendingPathComponent("Missing.bundle"),
        containerURL: missingContainerPath ? nil : URL(fileURLWithPath: "/usr/bin/true"),
        ghURL: fixture.configuration.ghURL
    )
    try fixture.store.save(configuration)
    let leases = try RunnerLeaseStore(directory: fixture.directory)
    let linuxIDs = [RunnerID(value: "yieldd-a-linux"), RunnerID(value: "yieldd-b-linux")]
    for id in linuxIDs { try leases.save(RunnerLease(runnerID: id, repository: repository)) }
    let macID = RunnerID(value: "yieldd-z-macos")
    try leases.save(RunnerLease(runnerID: macID, repository: repository, platform: .macOS))
    let clone = try MacOSRunnerCloneStore(stateDirectory: fixture.directory).bundleURL(for: macID)
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    let outcomes: [Result<ProcessResult, any Error>] = (missingContainerPath ? [] : [.failure(TestFailure.create)]) + [
        .success(processResult(stdout: #"[{"runners":[{"id":42,"name":"yieldd-z-macos","busy":false}]}]"#)),
        .success(processResult()),
    ]
    let executor = RecordingProcessExecutor(outcomes: outcomes)
    let error = try #require(#expect(throws: RunnerSessionError.self) {
        try recoverAgentRunners(store: fixture.store, stop: RunnerPoolStop(), executor: executor)
    })
    guard case let .cleanupFailed(failures) = error else {
        Issue.record("Expected independent Linux cleanup failures")
        return
    }
    #expect(failures.count == 2)
    for failure in failures {
        guard case let RunnerRecoveryError.linuxBackendUnavailable(underlying) = failure.error else {
            Issue.record("Expected Linux preparation failure")
            continue
        }
        if missingContainerPath {
            #expect(underlying as? AgentConfigurationError == .containerPathNotRecorded)
        } else {
            #expect(underlying as? TestFailure == .create)
        }
    }
    #expect(try leases.load().map(\.runnerID) == linuxIDs)
    #expect(!FileManager.default.fileExists(atPath: clone.path))
    #expect(executor.requests.filter { $0.executableURL == configuration.containerURL }.count == (missingContainerPath ? 0 : 1))
    #expect(executor.requests.last?.arguments.contains("DELETE") == true)
    #expect(try fixture.store.load() == configuration)
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
