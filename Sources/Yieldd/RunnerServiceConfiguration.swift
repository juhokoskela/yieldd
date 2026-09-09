import Foundation

struct RunnerSlot: Equatable, Sendable {
    let repository: GitHubRepository
    let platform: RunnerPlatform
}

struct RunnerServiceConfiguration: Equatable, Sendable {
    static let maximumMacOSSlots = 2

    let slots: [RunnerSlot]
    let macOSTemplateURL: URL?

    init(
        repositories: [GitHubRepository],
        macOSRepositories: [GitHubRepository] = [],
        macOSTemplateURL: URL? = nil
    ) throws {
        guard !repositories.isEmpty || !macOSRepositories.isEmpty else {
            throw RunnerServiceConfigurationError.noRepositories
        }
        guard repositories.count + macOSRepositories.count <= RunnerPool.maximumSlots else {
            throw RunnerServiceConfigurationError.tooManySlots
        }
        guard macOSRepositories.count <= Self.maximumMacOSSlots else {
            throw RunnerServiceConfigurationError.tooManyMacOSSlots
        }
        guard macOSRepositories.isEmpty == (macOSTemplateURL == nil) else {
            throw RunnerServiceConfigurationError.templatePairRequired
        }
        if let macOSTemplateURL, !macOSTemplateURL.isFileURL || !macOSTemplateURL.path.hasPrefix("/") {
            throw RunnerServiceConfigurationError.invalidTemplateURL
        }
        slots = repositories.map { RunnerSlot(repository: $0, platform: .linux) }
            + macOSRepositories.map { RunnerSlot(repository: $0, platform: .macOS) }
        self.macOSTemplateURL = macOSTemplateURL?.resolvingSymlinksInPath()
    }

    var requiresLinux: Bool { slots.contains { $0.platform == .linux } }

    func repositories(for platform: RunnerPlatform) -> [GitHubRepository] {
        slots.filter { $0.platform == platform }.map(\.repository)
    }

    var memoryReservationBytes: UInt64 {
        slots.reduce(0) { $0 + $1.platform.memoryReservationBytes }
    }
}

enum RunnerServiceConfigurationError: Error, Equatable, LocalizedError {
    case noRepositories
    case tooManySlots
    case tooManyMacOSSlots
    case templatePairRequired
    case invalidTemplateURL
    case missingContainerExecutable

    var errorDescription: String? {
        switch self {
        case .noRepositories:
            "At least one runner repository is required."
        case .tooManySlots:
            "The runner service supports at most \(RunnerPool.maximumSlots) runner slots."
        case .tooManyMacOSSlots:
            "The runner service supports at most \(RunnerServiceConfiguration.maximumMacOSSlots) macOS runner slots."
        case .templatePairRequired:
            "--macos and --macos-template must be supplied together."
        case .invalidTemplateURL:
            "The macOS template must be an absolute filesystem URL."
        case .missingContainerExecutable:
            "Linux runner slots require a configured container executable."
        }
    }
}
