import Foundation
import Testing
@testable import Yieldd

private let lease = RunnerLease(
    runnerID: RunnerID(value: "yieldd-test-123"),
    repository: try! GitHubRepository("owner/repository")
)

@Test
func leaseStoreRoundTripsAndClearsLease() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)

    #expect(try store.load() == nil)

    try store.save(lease)
    #expect(try store.load() == lease)

    try store.clear()
    try store.clear()
    #expect(try store.load() == nil)
}

@Test
func leaseStoreRejectsOversizedState() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    try Data(repeating: 0, count: RunnerLeaseStore.maximumBytes + 1).write(to: store.fileURL)

    #expect(throws: RunnerLeaseError.tooLarge(
        path: store.fileURL.path,
        maximumBytes: RunnerLeaseStore.maximumBytes
    )) {
        try store.load()
    }
}

@Test
func leaseStoreReportsPathForInvalidContents() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    try Data("not JSON".utf8).write(to: store.fileURL)

    #expect(throws: RunnerLeaseError.invalidContents(path: store.fileURL.path)) {
        try store.load()
    }
}

@Test
func leaseStoreRejectsInvalidRunnerID() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)

    try Data(#"{"runnerID":"other-runner","repository":"owner/repository"}"#.utf8)
        .write(to: store.fileURL)
    #expect(throws: RunnerLeaseError.invalidRunnerID(path: store.fileURL.path)) {
        try store.load()
    }
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
