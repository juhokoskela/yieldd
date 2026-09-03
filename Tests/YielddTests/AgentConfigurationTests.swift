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

    #expect(throws: AgentConfigurationError.emptyRepositories) {
        try AgentConfiguration(
            repositories: [],
            containerURL: containerURL,
            ghURL: ghURL
        )
    }
    #expect(throws: AgentConfigurationError.tooManyRepositories(maximum: RunnerPool.maximumSlots)) {
        try AgentConfiguration(
            repositories: Array(repeating: repository, count: RunnerPool.maximumSlots + 1),
            containerURL: containerURL,
            ghURL: ghURL
        )
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

enum InvalidStoredConfiguration: CaseIterable, CustomTestStringConvertible {
    case emptyRepositories
    case tooManyRepositories
    case invalidRepository
    case relativeContainerPath
    case relativeGitHubCLIPath
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
        case .malformedJSON:
            Data("{".utf8)
        case .oversizedFile:
            Data(repeating: 0, count: AgentConfigurationStore.maximumBytes + 1)
        }
    }
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
