import Foundation

struct AgentConfiguration: Equatable, Sendable {
    let repositories: [GitHubRepository]
    let containerURL: URL
    let ghURL: URL

    func requireExecutables(fileManager: FileManager = .default) throws {
        for url in [containerURL, ghURL] where !fileManager.isExecutableFile(atPath: url.path) {
            throw AgentConfigurationError.executableUnavailable(path: url.path)
        }
    }
}

struct AgentConfigurationStore {
    static let maximumBytes = 16 * 1_024

    let directory: URL
    let fileURL: URL

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? yielddApplicationSupportDirectory()
        try FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fileURL = self.directory.appendingPathComponent("agent.json", isDirectory: false)
    }

    func load() throws -> AgentConfiguration {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain,
                  cocoaError.code == NSFileNoSuchFileError else {
                throw error
            }
            throw AgentConfigurationError.missing(path: fileURL.path)
        }
        defer { try? handle.close() }

        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes,
              let stored = try? JSONDecoder().decode(StoredAgentConfiguration.self, from: data),
              !stored.repositories.isEmpty,
              stored.repositories.count <= RunnerServiceCommand.maximumSlots,
              stored.containerExecutable.hasPrefix("/"),
              stored.githubCLIExecutable.hasPrefix("/"),
              let repositories = try? stored.repositories.map(GitHubRepository.init) else {
            throw AgentConfigurationError.invalidContents(path: fileURL.path)
        }

        return AgentConfiguration(
            repositories: repositories,
            containerURL: URL(fileURLWithPath: stored.containerExecutable),
            ghURL: URL(fileURLWithPath: stored.githubCLIExecutable)
        )
    }

    func save(_ configuration: AgentConfiguration) throws {
        precondition(!configuration.repositories.isEmpty)
        precondition(configuration.repositories.count <= RunnerServiceCommand.maximumSlots)
        precondition(configuration.containerURL.path.hasPrefix("/"))
        precondition(configuration.ghURL.path.hasPrefix("/"))

        let stored = StoredAgentConfiguration(
            repositories: configuration.repositories.map(\.fullName),
            containerExecutable: configuration.containerURL.path,
            githubCLIExecutable: configuration.ghURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func remove() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}

enum AgentConfigurationError: Error, Equatable, LocalizedError {
    case missing(path: String)
    case invalidContents(path: String)
    case executableUnavailable(path: String)

    var errorDescription: String? {
        switch self {
        case let .missing(path):
            "The local agent configuration is missing at \(path)."
        case let .invalidContents(path):
            "The local agent configuration at \(path) is invalid."
        case let .executableUnavailable(path):
            "The configured executable is missing or not executable: \(path)"
        }
    }
}

private struct StoredAgentConfiguration: Codable {
    let repositories: [String]
    let containerExecutable: String
    let githubCLIExecutable: String
}
