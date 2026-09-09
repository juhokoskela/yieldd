import Darwin
import Foundation

struct AgentConfiguration: Equatable {
    let runners: RunnerServiceConfiguration
    let containerURL: URL?
    let ghURL: URL

    var repositories: [GitHubRepository] { runners.slots.filter { $0.platform == .linux }.map(\.repository) }
    var macOSRepositories: [GitHubRepository] { runners.slots.filter { $0.platform == .macOS }.map(\.repository) }

    init(
        repositories: [GitHubRepository],
        macOSRepositories: [GitHubRepository] = [],
        macOSTemplateURL: URL? = nil,
        containerURL: URL?,
        ghURL: URL
    ) throws {
        runners = try RunnerServiceConfiguration(
            repositories: repositories, macOSRepositories: macOSRepositories, macOSTemplateURL: macOSTemplateURL
        )
        guard !runners.requiresLinux || containerURL != nil else {
            throw AgentConfigurationError.missingContainerExecutable
        }
        for url in [containerURL, ghURL].compactMap({ $0 })
        where !url.isFileURL || !url.path.hasPrefix("/") {
            throw AgentConfigurationError.invalidExecutableURL(url)
        }

        self.containerURL = containerURL
        self.ghURL = ghURL
    }

    func requireExecutables() throws {
        for url in [runners.requiresLinux ? containerURL : nil, ghURL].compactMap({ $0 })
        where !FileManager.default.isExecutableFile(atPath: url.path) {
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
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT {
                throw AgentConfigurationError.missing(path: fileURL.path)
            }
            if errorNumber == ELOOP {
                throw AgentConfigurationError.invalidContents(path: fileURL.path)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else {
            throw AgentConfigurationError.invalidContents(path: fileURL.path)
        }

        let stored: StoredAgentConfiguration
        do {
            stored = try JSONDecoder().decode(StoredAgentConfiguration.self, from: data)
        } catch {
            throw AgentConfigurationError.invalidContents(path: fileURL.path)
        }
        guard stored.containerExecutable.map({ $0.hasPrefix("/") }) ?? true,
              stored.macOSTemplate.map({ $0.hasPrefix("/") }) ?? true,
              stored.githubCLIExecutable.hasPrefix("/") else {
            throw AgentConfigurationError.invalidContents(path: fileURL.path)
        }

        do {
            return try AgentConfiguration(
                repositories: stored.repositories.map(GitHubRepository.init),
                macOSRepositories: (stored.macOSRepositories ?? []).map(GitHubRepository.init),
                macOSTemplateURL: stored.macOSTemplate.map { URL(fileURLWithPath: $0) },
                containerURL: stored.containerExecutable.map { URL(fileURLWithPath: $0) },
                ghURL: URL(fileURLWithPath: stored.githubCLIExecutable)
            )
        } catch {
            throw AgentConfigurationError.invalidContents(path: fileURL.path)
        }
    }

    func save(_ configuration: AgentConfiguration) throws {
        let stored = StoredAgentConfiguration(
            repositories: configuration.repositories.map(\.fullName),
            macOSRepositories: configuration.macOSRepositories.map(\.fullName),
            macOSTemplate: configuration.runners.macOSTemplateURL?.path,
            containerExecutable: configuration.containerURL?.path,
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
    case missingContainerExecutable
    case invalidExecutableURL(URL)
    case missing(path: String)
    case invalidContents(path: String)
    case executableUnavailable(path: String)

    var errorDescription: String? {
        switch self {
        case .missingContainerExecutable:
            "Linux runner slots require a configured container executable."
        case let .invalidExecutableURL(url):
            "The local agent executable URL must be an absolute file URL: \(url.absoluteString)"
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
    let macOSRepositories: [String]?
    let macOSTemplate: String?
    let containerExecutable: String?
    let githubCLIExecutable: String
}
