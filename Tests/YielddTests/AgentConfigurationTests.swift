import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

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
        "macOSRepositories": [String](),
        "containerExecutable": container,
        "githubCLIExecutable": githubCLI,
    ])
}

private func makeAgentTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-agent-\(UUID().uuidString)", isDirectory: true)
}
