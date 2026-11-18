import Foundation
import Testing
@testable import Yieldd

@Test
func leaseStoreRepairsStateDirectoryPermissions() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: directory.path
    )

    let store = try RunnerLeaseStore(directory: directory)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)

    #expect(store.directory == directory)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test
func runnerOwnershipRejectsConcurrentCommandsAndReleasesTheLock() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    try withRunnerOwnership(in: directory) { _ in
        #expect(throws: RunnerOwnershipError.alreadyRunning) {
            try withRunnerOwnership(in: directory) { _ in }
        }
    }

    var reacquired = false
    for _ in 0..<100 where !reacquired {
        do {
            try withRunnerOwnership(in: directory) { _ in
                reacquired = true
            }
        } catch RunnerOwnershipError.alreadyRunning {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    #expect(reacquired)
}

private func makeStateDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-state-\(UUID().uuidString)", isDirectory: true)
}
