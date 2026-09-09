import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

@Test
func serviceOptionsPreserveMixedAndRepeatedSlots() throws {
    let command = try RunnerServiceCommand.parse([
        "owner/repo", "--macos", "owner/repo", "--macos", "owner/repo",
        "--macos-template", "/tmp/template with spaces.bundle",
    ])
    let configuration = try command.runners.serviceConfiguration()
    #expect(configuration.slots.map(\.platform) == [.linux, .macOS, .macOS])
    #expect(configuration.slots.map(\.repository.fullName) == Array(repeating: "owner/repo", count: 3))
    #expect(configuration.requiresLinux)
    #expect(configuration.macOSTemplateURL?.lastPathComponent == "template with spaces.bundle")
    let macOnly = try RunnerServiceCommand.parse([
        "--macos", "owner/repo", "--macos-template", "/tmp/template.bundle",
    ]).runners.serviceConfiguration()
    #expect(!macOnly.requiresLinux)
}

@Test(arguments: [
    ([], "At least one runner repository is required."),
    (["not-a-repository"], "Repository must use the owner/name format accepted by GitHub."),
    (["--macos", "not-a-repository", "--macos-template", "/tmp/template"], "Repository must use the owner/name format accepted by GitHub."),
    (["--macos", "owner/repo"], "--macos and --macos-template must be supplied together."),
    (["owner/repo", "--macos-template", "/tmp/template"], "--macos and --macos-template must be supplied together."),
    (["--macos", "owner/repo", "--macos-template", ""], "--macos-template must be an absolute path."),
    (["--macos", "owner/repo", "--macos-template", "/tmp/a", "--macos-template", "/tmp/b"], "Supply --macos-template only once."),
    (["--macos", "owner/repo", "--macos-template", "/tmp/a", "--macos-template", "/tmp/a"], "Supply --macos-template only once."),
    (["--macos", "owner/repo", "--macos-template", "relative.bundle"], "--macos-template must be an absolute path."),
    (["--macos", "owner/repo", "--macos-template", "./relative.bundle"], "--macos-template must be an absolute path."),
    (["--macos", "owner/repo", "--macos", "owner/repo", "--macos", "owner/repo", "--macos-template", "/tmp/template"], "The runner service supports at most 2 macOS runner slots."),
])
func serviceOptionsRejectInvalidSlotConfigurations(arguments: [String], message: String) throws {
    let error = try #require(#expect(throws: (any Error).self) { try RunnerServiceCommand.parse(arguments) })
    #expect(RunnerServiceCommand.message(for: error) == message)
    let agentError = try #require(#expect(throws: (any Error).self) { try AgentInstallCommand.parse(arguments) })
    #expect(AgentInstallCommand.message(for: agentError) == message)
}

@Test(arguments: [false, true])
func serviceRejectsManagedTemplateBeforeRecovery(symlink: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yieldd-service-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    let template = try MacOSRunnerCloneStore(stateDirectory: directory).bundleURL(for: RunnerID(value: "yieldd-template"))
    try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
    let disk = template.appendingPathComponent("Disk.img")
    try Data("must survive".utf8).write(to: disk)
    let alias = directory.appendingPathComponent("template-link")
    if symlink { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: template) }
    let configuration = try RunnerServiceConfiguration(
        repositories: [], macOSRepositories: [GitHubRepository("owner/repo")], macOSTemplateURL: symlink ? alias : template
    )
    let error = try #require(#expect(throws: MacOSVirtualizationBackendError.self) {
        try runRunnerService(
            configuration: configuration, leaseStore: store, containerURL: nil,
            ghURL: URL(fileURLWithPath: "/missing/gh"), stop: RunnerPoolStop(), output: .terminal,
            prepareContainer: {
                Issue.record("Template validation must precede Container startup")
                throw TestFailure.unexpectedProcessRequest
            }
        )
    })
    guard case .templateInsideCloneRoot = error else {
        Issue.record("Expected template location rejection")
        return
    }
    #expect(try String(contentsOf: disk, encoding: .utf8) == "must survive")
}

@Test(arguments: [RunnerPlatform.linux, .macOS])
func serviceSessionSelectsBackendAndJobLabel(platform: RunnerPlatform) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let session = try makeRunnerSession(
        backend: platform == .macOS ? .macOS(templateURL: fixture.templateURL) : .linux(containerURL: URL(fileURLWithPath: "/missing/container")),
        leaseStore: RunnerLeaseStore(directory: fixture.rootURL),
        ghURL: URL(fileURLWithPath: "/missing/gh"), stop: RunnerPoolStop(),
        memoryAdmission: RunnerMemoryAdmission(), stateChanged: { _ in }
    )
    #expect(session.backend.platform == platform)
    let messages = ServiceMessages()
    reportRunnerServiceState(
        .waitingForJob(RunnerID(value: "yieldd-test")), platform: platform,
        output: RunnerServiceOutput(info: messages.append, warning: messages.append, error: messages.append)
    )
    #expect(messages.values == ["Runner yieldd-test is waiting for one job labeled '\(platform.runnerLabel)'."])
}

@Test
func serviceRejectsOversubscribedMixedSlotsBeforeRecovery() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let leases = try RunnerLeaseStore(directory: fixture.rootURL)
    let repository = try GitHubRepository("owner/repo")
    let orphan = try MacOSRunnerCloneStore(stateDirectory: fixture.rootURL)
        .bundleURL(for: RunnerID(value: "yieldd-abandoned"))
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let messages = ServiceMessages()
    #expect(throws: RunnerMemoryAdmissionError.insufficientHostMemory(
        requiredBytes: 20 * 1_024 * 1_024 * 1_024, budgetBytes: 18 * 1_024 * 1_024 * 1_024
    )) {
        try runRunnerService(
            configuration: RunnerServiceConfiguration(
                repositories: [repository], macOSRepositories: [repository], macOSTemplateURL: fixture.templateURL
            ),
            leaseStore: leases, containerURL: URL(fileURLWithPath: "/missing/container"),
            ghURL: URL(fileURLWithPath: "/missing/gh"), stop: RunnerPoolStop(),
            output: RunnerServiceOutput(info: messages.append, warning: messages.append, error: messages.append),
            memoryAdmission: RunnerMemoryAdmission(physicalMemoryBytes: 24 * 1_024 * 1_024 * 1_024)
        )
    }
    #expect(messages.values.isEmpty)
    #expect(try leases.load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: orphan.path))
}

@Test(arguments: [
    (8, 1, 0, false),
    (24, 0, 2, true),
    (24, 1, 1, false),
    (24, 2, 0, false),
    (32, 1, 1, true),
    (32, 2, 0, true),
    (32, 1, 2, false),
])
func serviceCapacityCoversEveryConfiguredSlot(hostGiB: Int, linux: Int, macOS: Int, fits: Bool) throws {
    let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
    let repository = try GitHubRepository("owner/repo")
    let configuration = try RunnerServiceConfiguration(
        repositories: Array(repeating: repository, count: linux),
        macOSRepositories: Array(repeating: repository, count: macOS),
        macOSTemplateURL: macOS > 0 ? URL(fileURLWithPath: "/tmp/template.bundle") : nil
    )
    let requiredBytes = UInt64(linux * 12 + macOS * 8) * gibibyte
    #expect(configuration.memoryReservationBytes == requiredBytes)
    let admission = RunnerMemoryAdmission(physicalMemoryBytes: UInt64(hostGiB) * gibibyte)
    if fits {
        try admission.validateCapacity(reserving: configuration.memoryReservationBytes)
    } else {
        #expect(throws: RunnerMemoryAdmissionError.insufficientHostMemory(
            requiredBytes: requiredBytes, budgetBytes: UInt64(hostGiB) * gibibyte * 3 / 4
        )) {
            try admission.validateCapacity(reserving: configuration.memoryReservationBytes)
        }
    }
}

@Test(arguments: ["https://example.com/template.bundle", "file:relative.bundle"])
func serviceConfigurationRejectsNonAbsoluteFileURLs(value: String) throws {
    let url = try #require(URL(string: value))
    #expect(throws: RunnerServiceConfigurationError.invalidTemplateURL) {
        try RunnerServiceConfiguration(
            repositories: [], macOSRepositories: [GitHubRepository("owner/repo")], macOSTemplateURL: url
        )
    }
}

@Test
func serviceRejectsMissingEntitlementBeforeRecovery() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let leases = try RunnerLeaseStore(directory: fixture.rootURL)
    let lease = RunnerLease(runnerID: RunnerID(value: "yieldd-abandoned"), repository: try GitHubRepository("owner/repo"))
    try leases.save(lease)
    let orphan = try MacOSRunnerCloneStore(stateDirectory: fixture.rootURL).bundleURL(for: RunnerID(value: "yieldd-orphan"))
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let messages = ServiceMessages()
    let error = try #require(#expect(throws: MacOSVirtualizationProbeError.self) {
        try runRunnerService(
            configuration: RunnerServiceConfiguration(repositories: [], macOSRepositories: [lease.repository], macOSTemplateURL: fixture.templateURL),
            leaseStore: leases, containerURL: nil, ghURL: URL(fileURLWithPath: "/missing/gh"),
            stop: RunnerPoolStop(),
            output: RunnerServiceOutput(info: messages.append, warning: messages.append, error: messages.append),
            memoryAdmission: RunnerMemoryAdmission(physicalMemoryBytes: 24 * 1_024 * 1_024 * 1_024)
        )
    })
    guard case .missingEntitlement = error else {
        Issue.record("Expected missing virtualization entitlement, got \(error)")
        return
    }
    #expect(try leases.load() == [lease])
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    #expect(messages.values.isEmpty)
}

@Test
func serviceRecoveryReportsMissingContainerAndRetainsLinuxLease() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let leases = try RunnerLeaseStore(directory: fixture.rootURL)
    let lease = RunnerLease(runnerID: RunnerID(value: "yieldd-abandoned"), repository: try GitHubRepository("owner/repo"))
    let executor = RecordingProcessExecutor(outcomes: [])
    let recovery = makeRunnerRecovery(
        leaseStore: leases, resolveContainer: { try ExecutableLocator(searchPath: fixture.rootURL.path).locate("container") },
        ghURL: URL(fileURLWithPath: "/missing/gh"), stop: RunnerPoolStop(), executor: executor, stateChanged: { _ in }
    )
    #expect(try recovery.run().isEmpty)
    try leases.save(lease)
    let error = try #require(#expect(throws: RunnerSessionError.self) { try recovery.run() })
    #expect(describeError(error).contains("Linux lease recovery could not prepare Apple Container"))
    #expect(describeError(error).contains("Could not find executable container"))
    #expect(try leases.load() == [lease])
    #expect(executor.requests.isEmpty)
}

@Test(arguments: [RunnerPlatform.linux, .macOS])
func serviceRunnerNamesMatchTheirPlatform(platform: RunnerPlatform) {
    let id = platform.makeServiceRunnerID()
    #expect(id.value.hasPrefix("\(platform.runnerLabel)-"))
    #expect(id.value.count <= 64)
    #expect(id.isValid)
}

@Test
func serviceBannerNamesBothPlatforms() throws {
    let configuration = try RunnerServiceConfiguration(
        repositories: [GitHubRepository("owner/linux")], macOSRepositories: [GitHubRepository("owner/mac")],
        macOSTemplateURL: URL(fileURLWithPath: "/tmp/template.bundle")
    )
    #expect(runnerServiceBanner(configuration) == "Serving 2 ephemeral runner slots for owner/linux (linux), owner/mac (macos).")
}

private final class ServiceMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var values: [String] { lock.withLock { messages } }
    func append(_ value: String) { lock.withLock { messages.append(value) } }
}
