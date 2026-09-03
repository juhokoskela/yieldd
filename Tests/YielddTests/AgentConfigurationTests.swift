import Foundation
import Testing
@testable import Yieldd

@Test
func agentConfigurationRoundTripsWithPrivatePermissions() throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConfigurationStore(directory: directory)
    let repository = try GitHubRepository("owner/repository")
    let configuration = AgentConfiguration(
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

@Test
func agentConfigurationRejectsInvalidStoredValues() throws {
    let directory = makeAgentTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConfigurationStore(directory: directory)
    try Data(
        #"{"repositories":["owner/repository"],"containerExecutable":"relative/container","githubCLIExecutable":"/bin/gh"}"#.utf8
    ).write(to: store.fileURL)

    #expect(throws: AgentConfigurationError.invalidContents(path: store.fileURL.path)) {
        try store.load()
    }
}

@Test
func agentConfigurationRequiresConfiguredExecutables() throws {
    let configuration = AgentConfiguration(
        repositories: [try GitHubRepository("owner/repository")],
        containerURL: URL(fileURLWithPath: "/missing/container"),
        ghURL: URL(fileURLWithPath: "/missing/gh")
    )

    #expect(throws: AgentConfigurationError.executableUnavailable(path: "/missing/container")) {
        try configuration.requireExecutables()
    }
}

@Test
func agentServiceInstallCommandPreservesRepeatedRepositories() throws {
    let command = try AgentServiceInstallCommand.parse([
        "owner/repository",
        "owner/repository",
    ])

    #expect(command.repositories == ["owner/repository", "owner/repository"])
}

@Test
func agentServiceInstallCommandRejectsInvalidSlotCounts() {
    #expect(throws: (any Error).self) {
        _ = try AgentServiceInstallCommand.parse([])
    }

    let repositories = Array(
        repeating: "owner/repository",
        count: RunnerServiceCommand.maximumSlots + 1
    )
    #expect(throws: (any Error).self) {
        _ = try AgentServiceInstallCommand.parse(repositories)
    }
}

private func makeAgentTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-agent-\(UUID().uuidString)", isDirectory: true)
}
