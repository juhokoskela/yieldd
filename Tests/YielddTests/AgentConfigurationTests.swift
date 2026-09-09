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

    let emptyError = try #require(#expect(throws: ValidationError.self) {
        try AgentConfiguration(
            repositories: [],
            containerURL: containerURL,
            ghURL: ghURL
        )
    })
    #expect(emptyError.message == "At least one runner repository is required.")
    let countError = try #require(#expect(throws: ValidationError.self) {
        try AgentConfiguration(
            repositories: Array(repeating: repository, count: RunnerPool.maximumSlots + 1),
            containerURL: containerURL,
            ghURL: ghURL
        )
    })
    #expect(countError.message == "Supports at most 16 runner slots.")
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
func agentConfigurationRequiresConfiguredExecutables() throws {
    let configuration = try AgentConfiguration(
        repositories: [try GitHubRepository("owner/repository")],
        containerURL: URL(fileURLWithPath: "/missing/container"),
        ghURL: URL(fileURLWithPath: "/missing/gh")
    )

    #expect(throws: AgentConfigurationError.executableUnavailable(path: "/missing/container")) {
        try configuration.requireExecutables()
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
func agentInstallCommandRejectsInvalidRepository() throws {
    var command = try AgentInstallCommand.parse(["owner/repository"])
    command.runners.repositories = ["not-a-repository"]

    #expect(throws: GitHubRepositoryError.invalidFormat("not-a-repository")) {
        try command.runners.validate()
    }
}

@Test
func agentInstallPreflightResolvesToolsWithoutAPackagedApplication() throws {
    var command = try AgentInstallCommand.parse(["owner/repository"])
    command.preflightOnly = true
    var resolvedTools: [String] = []

    try command.run { name in
        resolvedTools.append(name)
        return URL(fileURLWithPath: "/usr/bin/\(name)")
    }

    #expect(resolvedTools == ["container", "gh"])
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
        try command.run { _ in throw expectedError }
    }
}

enum InvalidStoredConfiguration: CaseIterable, CustomTestStringConvertible {
    case emptyRepositories
    case tooManyRepositories
    case invalidRepository
    case relativeContainerPath
    case relativeGitHubCLIPath
    case missingContainer
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
            Data(#"{"repositories":["owner/repo"],"githubCLIExecutable":"/usr/bin/gh"}"#.utf8)
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

@Test
func agentConfigurationLoadsLegacyLinuxSlots() throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConfigurationStore(directory: directory)
    try validStoredConfiguration.write(to: store.fileURL)
    let configuration = try store.load()
    #expect(configuration.runners.slots.map(\.platform) == [.linux])
    #expect(configuration.macOSRepositories.isEmpty)
    #expect(configuration.runners.macOSTemplateURL == nil)
    #expect(configuration.containerURL?.path == "/usr/local/bin/container")
}

@Test(arguments: [false, true])
func agentConfigurationRoundTripsMacOSSlots(mixed: Bool) throws {
    let fixture = try ProbeBundleFixture()
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
    try loaded.requireExecutables()
}

@Test
func agentMacOSPreflightOnlyResolvesGitHubCLI() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let command = try AgentInstallCommand.parse([
        "--macos", "owner/repo", "--macos", "owner/repo",
        "--macos-template", fixture.templateURL.path, "--preflight-only",
    ])
    var tools: [String] = []
    try command.run(locateExecutable: { name in
        tools.append(name)
        return URL(fileURLWithPath: "/usr/bin/true")
    }, stateDirectory: fixture.rootURL)
    #expect(tools == ["gh"])
    #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("agent.json").path))
}

@Test(arguments: [false, true])
func agentInstallRejectsManagedTemplateBeforeRegistration(symlink: Bool) throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = try MacOSRunnerCloneStore(stateDirectory: directory).bundleURL(for: RunnerID(value: "yieldd-template"))
    try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
    let disk = template.appendingPathComponent("Disk.img")
    try Data("must survive".utf8).write(to: disk)
    let alias = directory.appendingPathComponent("template-link")
    if symlink { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: template) }
    let command = try AgentInstallCommand.parse([
        "--macos", "owner/repo", "--macos-template", (symlink ? alias : template).path,
    ])
    let error = try #require(#expect(throws: MacOSVirtualizationBackendError.self) {
        try command.run(locateExecutable: { _ in URL(fileURLWithPath: "/usr/bin/true") }, stateDirectory: directory)
    })
    guard case .templateInsideCloneRoot = error else {
        Issue.record("Expected template location rejection")
        return
    }
    #expect(try String(contentsOf: disk, encoding: .utf8) == "must survive")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("agent.json").path))
}

private func macOSStoredConfiguration(
    repositories: [String] = ["owner/repo"], template: String = "/tmp/Template.bundle"
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "repositories": [String](), "macOSRepositories": repositories,
        "macOSTemplate": template, "githubCLIExecutable": "/usr/bin/gh",
    ])
}

private let validStoredConfiguration = storedConfiguration()

private func storedConfiguration(
    repositories: [String] = ["owner/repository"],
    container: String = "/usr/local/bin/container",
    githubCLI: String = "/opt/homebrew/bin/gh"
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "repositories": repositories,
        "containerExecutable": container,
        "githubCLIExecutable": githubCLI,
    ])
}

private func makeAgentTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-agent-\(UUID().uuidString)", isDirectory: true)
}
