import ArgumentParser
import Foundation

struct RunnerServiceOptions: ParsableArguments {
    @Argument(help: "Linux repositories in owner/name form. Repeat a repository for another slot.")
    var repositories: [String] = []

    @Option(name: .customLong("macos"), help: "macOS repository in owner/name form. Repeat for another slot, up to two.")
    var macOSRepositories: [String] = []

    @Option(name: .customLong("macos-template"), help: "Absolute path to the prepared macOS template bundle shared by the macOS slots.")
    var macOSTemplates: [String] = []

    mutating func validate() throws {
        do {
            _ = try serviceConfiguration()
        } catch {
            throw ValidationError(describeError(error))
        }
    }

    func serviceConfiguration() throws -> RunnerServiceConfiguration {
        guard macOSTemplates.count <= 1 else {
            throw ValidationError("Supply --macos-template only once.")
        }
        let macOSTemplate = macOSTemplates.first
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
