import ArgumentParser
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
            throw ValidationError("At least one runner repository is required.")
        }
        guard repositories.count + macOSRepositories.count <= RunnerPool.maximumSlots else {
            throw ValidationError("Supports at most \(RunnerPool.maximumSlots) runner slots.")
        }
        guard macOSRepositories.count <= Self.maximumMacOSSlots else {
            throw ValidationError("Supports at most \(Self.maximumMacOSSlots) macOS runner slots.")
        }
        guard macOSRepositories.isEmpty == (macOSTemplateURL == nil) else {
            throw ValidationError("--macos and --macos-template must be supplied together.")
        }
        if let macOSTemplateURL, !macOSTemplateURL.isFileURL || !macOSTemplateURL.path.hasPrefix("/") {
            throw ValidationError("The macOS template must be an absolute filesystem URL.")
        }
        slots = repositories.map { RunnerSlot(repository: $0, platform: .linux) }
            + macOSRepositories.map { RunnerSlot(repository: $0, platform: .macOS) }
        self.macOSTemplateURL = macOSTemplateURL?.resolvingSymlinksInPath()
    }

    var requiresLinux: Bool { slots.contains { $0.platform == .linux } }

    var memoryReservationBytes: UInt64 {
        slots.reduce(0) { $0 + $1.platform.memoryReservationBytes }
    }
}

struct RunnerServiceOptions: ParsableArguments {
    @Argument(help: "Linux repositories in owner/name form. Repeat a repository for another slot.")
    var repositories: [String] = []

    @Option(name: .customLong("macos"), help: "macOS repository in owner/name form. Repeat for another slot, up to two.")
    var macOSRepositories: [String] = []

    @Option(name: .customLong("macos-template"), help: "Absolute path to the prepared macOS template bundle shared by the macOS slots.")
    var macOSTemplate: String?

    mutating func validate() throws { _ = try serviceConfiguration() }

    func serviceConfiguration() throws -> RunnerServiceConfiguration {
        if let macOSTemplate, macOSTemplate.isEmpty {
            throw ValidationError("--macos-template must not be empty.")
        }
        if let macOSTemplate, !macOSTemplate.hasPrefix("/") {
            throw ValidationError("--macos-template must be an absolute path.")
        }
        return try RunnerServiceConfiguration(
            repositories: repositories.map(GitHubRepository.init),
            macOSRepositories: macOSRepositories.map(GitHubRepository.init),
            macOSTemplateURL: macOSTemplate.map { URL(fileURLWithPath: $0) }
        )
    }
}
