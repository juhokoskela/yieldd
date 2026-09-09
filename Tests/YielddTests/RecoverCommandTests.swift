import Foundation
import Testing
@testable import Yieldd

@Test
func standaloneRecoveryWithoutLeasesNeedsNeitherGitHubNorContainer() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try withRunnerOwnership(in: directory) { store in
        let clone = MacOSRunnerCloneStore(stateDirectory: directory).rootURL
            .appendingPathComponent("yieldd-abandoned.bundle")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try recoverAbandonedRunners(
            leaseStore: store,
            makeGitHub: { throw TestFailure.unexpectedProcessRequest },
            makeLinuxBackend: { throw TestFailure.unexpectedBackendCall },
            checkCancellation: {}, wait: { _ in throw TestFailure.unexpectedBackendCall }
        )
        #expect(!FileManager.default.fileExists(atPath: clone.path))
    }
}

@Test
func standaloneMacOSRecoveryNeedsNoTemplateOrLinuxBackend() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let github = RecoveryGitHub()
    try withRunnerOwnership(in: directory) { store in
        let id = RunnerID(value: "yieldd-abandoned")
        try store.save(RunnerLease(runnerID: id, repository: GitHubRepository("owner/repo"), platform: .macOS))
        try recoverAbandonedRunners(
            leaseStore: store, makeGitHub: { github },
            makeLinuxBackend: { throw TestFailure.unexpectedBackendCall },
            checkCancellation: {}, wait: { _ in throw TestFailure.unexpectedBackendCall }
        )
        #expect(try store.load().isEmpty)
        #expect(github.removed == [id.value])
    }
}

private final class RecoveryGitHub: GitHubRunnerManaging {
    var removed: [String] = []
    func createRegistrationToken(for repository: GitHubRepository) throws -> String {
        throw TestFailure.unexpectedProcessRequest
    }
    func removeRunners(named name: String, from repository: GitHubRepository) throws {
        removed.append(name)
    }
}
