import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

@Test
func agentConfigurationRoundTripsWithPrivatePermissions() throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConfigurationStore(directory: directory)
    let repository = try GitHubRepository("owner/repository")
    let configuration = try AgentConfiguration(
        repositories: [repository, repository],
        containerURL: URL(fileURLWithPath: "/usr/local/bin/container"),
        ghURL: URL(fileURLWithPath: "/opt/homebrew/bin/gh")
    )

    try store.save(configuration)

    #expect(try store.load() == configuration)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
}

@Test
func agentConfigurationReportsMissingFileAndRemovalIsIdempotent() throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConfigurationStore(directory: directory)

    #expect(throws: AgentConfigurationError.missing(path: store.fileURL.path)) {
        try store.load()
    }
    try store.remove()
    try store.remove()
}

@Test(arguments: InvalidStoredConfiguration.allCases)
func agentConfigurationRejectsInvalidStoredValues(
    _ invalidConfiguration: InvalidStoredConfiguration
) throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConfigurationStore(directory: directory)
    try invalidConfiguration.data.write(to: store.fileURL)

    #expect(throws: AgentConfigurationError.invalidContents(path: store.fileURL.path)) {
        try store.load()
    }
}

@Test
func agentConfigurationDoesNotFollowSymbolicLinks() throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConfigurationStore(directory: directory)
    let target = directory.appendingPathComponent("target.json", isDirectory: false)
    try validStoredConfiguration.write(to: target)
    try FileManager.default.createSymbolicLink(
        at: store.fileURL,
        withDestinationURL: target
    )

    #expect(throws: AgentConfigurationError.invalidContents(path: store.fileURL.path)) {
        try store.load()
    }
}

@Test
func agentConfigurationEnforcesRepositoryAndExecutableInvariants() throws {
    let repository = try GitHubRepository("owner/repository")
    let containerURL = URL(fileURLWithPath: "/usr/local/bin/container")
    let ghURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")

    #expect(throws: AgentConfigurationError.missingContainerExecutable) {
        try AgentConfiguration(repositories: [repository], containerURL: nil, ghURL: ghURL)
    }

    let invalidURLs = [
        try #require(URL(string: "file:relative/container")),
        try #require(URL(string: "https://example.com/container")),
    ]
    for invalidURL in invalidURLs {
        #expect(throws: AgentConfigurationError.invalidExecutableURL(invalidURL)) {
            try AgentConfiguration(
                repositories: [repository],
                containerURL: invalidURL,
                ghURL: ghURL
            )
        }
        #expect(throws: AgentConfigurationError.invalidExecutableURL(invalidURL)) {
            try AgentConfiguration(
                repositories: [repository],
                containerURL: containerURL,
                ghURL: invalidURL
            )
        }
    }
}

@Test
func agentConfigurationRequiresGitHubCLI() throws {
    let configuration = try AgentConfiguration(
        repositories: [try GitHubRepository("owner/repository")],
        containerURL: URL(fileURLWithPath: "/missing/container"),
        ghURL: URL(fileURLWithPath: "/missing/gh")
    )

    #expect(throws: AgentConfigurationError.executableUnavailable(path: "/missing/gh")) {
        try configuration.requireGitHubCLI()
    }
}

@Test
func agentInstallCommandRejectsTooManySlots() {
    let repositories = Array(
        repeating: "owner/repository",
        count: RunnerPool.maximumSlots + 1
    )

    do {
        _ = try AgentInstallCommand.parse(repositories)
        Issue.record("Expected excessive runner slots to be rejected")
    } catch {
        #expect(String(describing: error).contains(
            "at most \(RunnerPool.maximumSlots) runner slots"
        ))
    }
}

@Test
func agentInstallPreflightResolvesToolsWithoutAPackagedApplication() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    var command = try AgentInstallCommand.parse(["owner/repository"])
    command.preflightOnly = true
    var resolvedTools: [String] = []

    try command.run(locateExecutable: { name in
        resolvedTools.append(name)
        return URL(fileURLWithPath: "/usr/bin/\(name)")
    }, stateDirectory: fixture.directory, memoryAdmission: RunnerMemoryAdmission(physicalMemoryBytes: 24 * 1_024 * 1_024 * 1_024), loadStorage: { _ in nil }, relayURL: URL(fileURLWithPath: "/usr/bin/true"),
       executor: RecordingProcessExecutor(outcomes: [.success(processResult(stdout: "--network-socket")), .success(processResult())]))

    #expect(resolvedTools == ["container", "gh"])
}

@Test
func agentInstallPreflightRejectsStockContainerBeforeSavingConfiguration() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let command = try AgentInstallCommand.parse(["owner/repository", "--preflight-only"])
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult(stdout: "stock machine create"))])
    #expect(throws: AppleContainerBackendError.unsupportedCLI) {
        try command.run(locateExecutable: { URL(fileURLWithPath: "/test/\($0)") },
            stateDirectory: fixture.directory, loadStorage: { _ in nil },
            relayURL: URL(fileURLWithPath: "/usr/bin/true"), executor: executor)
    }
    #expect(executor.requests.map(\.arguments) == [["machine", "create", "--help"]])
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("agent.json").path))
}

@Test
func agentInstallPreflightReportsMissingTool() throws {
    var command = try AgentInstallCommand.parse(["owner/repository"])
    command.preflightOnly = true
    let expectedError = ExecutableLocatorError.notFound(
        name: "container",
        searchedDirectories: ["/usr/bin"]
    )

    #expect(throws: expectedError) {
        try command.run(
            locateExecutable: { _ in throw expectedError },
            memoryAdmission: RunnerMemoryAdmission(physicalMemoryBytes: 24 * 1_024 * 1_024 * 1_024), loadStorage: { _ in nil }
        )
    }
}

enum InvalidStoredConfiguration: CaseIterable, CustomTestStringConvertible {
    case emptyRepositories
    case tooManyRepositories
    case invalidRepository
    case relativeContainerPath
    case relativeGitHubCLIPath
    case missingContainer
    case missingMacOSRepositories
    case relativeTemplate
    case templateWithoutSlots
    case macOSSlotsWithoutTemplate
    case tooManyMacOSSlots
    case malformedJSON
    case oversizedFile

    var testDescription: String {
        String(describing: self)
    }

    var data: Data {
        switch self {
        case .emptyRepositories:
            storedConfiguration(repositories: [])
        case .tooManyRepositories:
            storedConfiguration(
                repositories: Array(
                    repeating: "owner/repository",
                    count: RunnerPool.maximumSlots + 1
                )
            )
        case .invalidRepository:
            storedConfiguration(repositories: ["not-a-repository"])
        case .relativeContainerPath:
            storedConfiguration(container: "relative/container")
        case .relativeGitHubCLIPath:
            storedConfiguration(githubCLI: "relative/gh")
        case .missingContainer:
            Data(#"{"repositories":["owner/repo"],"macOSRepositories":[],"githubCLIExecutable":"/usr/bin/gh"}"#.utf8)
        case .missingMacOSRepositories:
            Data(#"{"repositories":["owner/repo"],"containerExecutable":"/usr/local/bin/container","githubCLIExecutable":"/usr/bin/gh"}"#.utf8)
        case .relativeTemplate:
            macOSStoredConfiguration(template: "relative/template")
        case .templateWithoutSlots:
            macOSStoredConfiguration(repositories: [])
        case .macOSSlotsWithoutTemplate:
            Data(#"{"repositories":[],"macOSRepositories":["owner/repo"],"githubCLIExecutable":"/usr/bin/gh"}"#.utf8)
        case .tooManyMacOSSlots:
            macOSStoredConfiguration(repositories: Array(repeating: "owner/repo", count: 3))
        case .malformedJSON:
            Data("{".utf8)
        case .oversizedFile:
            Data(repeating: 0, count: AgentConfigurationStore.maximumBytes + 1)
        }
    }
}

@Test(arguments: [false, true])
func agentConfigurationRoundTripsMacOSSlots(mixed: Bool) throws {
    let fixture = try ProbeBundleFixture()
    try saveTestStorageBinding(in: fixture.rootURL)
    defer { fixture.remove() }
    let store = try AgentConfigurationStore(directory: fixture.rootURL)
    let repository = try GitHubRepository("owner/repo")
    let alias = fixture.rootURL.appendingPathComponent("template-link")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.templateURL)
    let configuration = try AgentConfiguration(
        repositories: mixed ? [repository] : [], macOSRepositories: [repository, repository],
        macOSTemplateURL: alias, containerURL: mixed ? URL(fileURLWithPath: "/usr/bin/true") : nil,
        ghURL: URL(fileURLWithPath: "/usr/bin/true")
    )
    try store.save(configuration)
    try FileManager.default.removeItem(at: alias)
    let loaded = try store.load()
    #expect(loaded == configuration)
    #expect(loaded.runners.macOSTemplateURL == fixture.templateURL.resolvingSymlinksInPath())
    #expect(loaded.runners.slots.map(\.platform) == (mixed ? [.linux, .macOS, .macOS] : [.macOS, .macOS]))
    try loaded.requireGitHubCLI()
}

@Test(arguments: [false, true])
func agentInstallRejectsManagedTemplateBeforeRegistration(symlink: Bool) throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = try testCloneStores(in: directory)(.runners).bundleURL(for: RunnerID(value: "yieldd-template"))
    try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
    let disk = template.appendingPathComponent("Disk.img")
    try Data("must survive".utf8).write(to: disk)
    try saveTestStorageBinding(in: directory)
    let alias = directory.appendingPathComponent("template-link")
    if symlink { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: template) }
    let command = try AgentInstallCommand.parse([
        "--macos", "owner/repo", "--macos-template", (symlink ? alias : template).path,
    ])
    let error = try #require(#expect(throws: MacOSVirtualizationBackendError.self) {
        try command.run(
            locateExecutable: { _ in URL(fileURLWithPath: "/usr/bin/true") }, stateDirectory: directory,
            memoryAdmission: RunnerMemoryAdmission(physicalMemoryBytes: 24 * 1_024 * 1_024 * 1_024), loadStorage: { _ in nil }
        )
    })
    guard case .templateInsideCloneRoot = error else {
        Issue.record("Expected template location rejection")
        return
    }
    #expect(try String(contentsOf: disk, encoding: .utf8) == "must survive")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("agent.json").path))
}

@Test(arguments: [(24, false), (24, true), (32, true)])
func agentPreflightValidatesCombinedReservations(hostGiB: Int, mixed: Bool) throws {
    let fixture = try ProbeBundleFixture()
    try saveTestStorageBinding(in: fixture.rootURL)
    defer { fixture.remove() }
    let command = try AgentInstallCommand.parse(
        (mixed ? ["owner/repo"] : ["--macos", "owner/repo"]) + [
            "--macos", "owner/repo", "--macos-template", fixture.templateURL.path, "--preflight-only",
        ]
    )
    var resolvedTools: [String] = []
    func preflight() throws {
        try command.run(locateExecutable: { name in
            resolvedTools.append(name)
            return URL(fileURLWithPath: "/usr/bin/true")
        }, stateDirectory: fixture.rootURL,
        memoryAdmission: RunnerMemoryAdmission(physicalMemoryBytes: UInt64(hostGiB) * 1_024 * 1_024 * 1_024), loadStorage: { _ in nil },
        relayURL: URL(fileURLWithPath: "/usr/bin/true"),
        executor: RecordingProcessExecutor(outcomes: [.success(processResult(stdout: "--network-socket")), .success(processResult())]))
    }
    if mixed && hostGiB == 24 {
        #expect(throws: RunnerMemoryAdmissionError.insufficientHostMemory(
            requiredBytes: 20 * 1_024 * 1_024 * 1_024, budgetBytes: 18 * 1_024 * 1_024 * 1_024
        )) {
            try preflight()
        }
        #expect(resolvedTools.isEmpty)
    } else {
        try preflight()
        #expect(resolvedTools == ["container", "gh"])
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("agent.json").path))
}

private func macOSStoredConfiguration(
    repositories: [String] = ["owner/repo"], template: String = "/tmp/Template.bundle"
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "repositories": [String](), "macOSRepositories": repositories,
        "macOSTemplate": template, "githubCLIExecutable": "/usr/bin/gh",
    ])
}

@Test(arguments: [false, true])
func agentConfigurationRecordsOptionalContainerOutsideLaunchdPath(available: Bool) throws {
    let fixture = try ProbeBundleFixture()
    try saveTestStorageBinding(in: fixture.rootURL)
    defer { fixture.remove() }
    let tools = fixture.rootURL.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    for name in available ? ["gh", "container"] : ["gh"] {
        let url = tools.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    let runners = try RunnerServiceConfiguration(
        repositories: [], macOSRepositories: [GitHubRepository("owner/repo")], macOSTemplateURL: fixture.templateURL
    )
    let configuration = try AgentConfiguration.resolve(runners: runners, locateExecutable: ExecutableLocator(searchPath: tools.path).locate)
    #expect(configuration.runners == runners)
    #expect(configuration.containerURL == (available ? tools.appendingPathComponent("container") : nil))
    let store = try AgentConfigurationStore(directory: fixture.rootURL)
    try store.save(configuration)
    let saved = try store.load()
    #expect(saved == configuration)
    if available {
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
        let prepare = agentContainerPreparation(configuration: saved, executor: executor, stateDirectory: unconfiguredContainerStateDirectory)
        #expect(throws: RunnerStorageError.notConfigured) { try prepare() }
        #expect(throws: RunnerStorageError.notConfigured) { try prepare() }
        #expect(executor.requests.isEmpty)
    }
}

@Test(arguments: [false, true])
func agentStartupDefersAStaleContainerPath(mixed: Bool) throws {
    let configuration = try AgentConfiguration(
        repositories: mixed ? [GitHubRepository("owner/repo")] : [], macOSRepositories: [GitHubRepository("owner/repo")],
        macOSTemplateURL: URL(fileURLWithPath: "/missing/template"),
        containerURL: URL(fileURLWithPath: "/missing/container"), ghURL: URL(fileURLWithPath: "/usr/bin/true")
    )
    try configuration.requireGitHubCLI()
}

private let validStoredConfiguration = storedConfiguration()

private func storedConfiguration(
    repositories: [String] = ["owner/repository"],
    container: String = "/usr/local/bin/container",
    githubCLI: String = "/opt/homebrew/bin/gh"
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "repositories": repositories,
        "macOSRepositories": [String](),
        "containerExecutable": container,
        "githubCLIExecutable": githubCLI,
    ])
}

private func makeAgentTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-agent-\(UUID().uuidString)", isDirectory: true)
}
