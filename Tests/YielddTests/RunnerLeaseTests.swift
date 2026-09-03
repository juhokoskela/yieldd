import Foundation
import Testing
@testable import Yieldd

private let lease = RunnerLease(
    runnerID: RunnerID(value: "yieldd-test-123"),
    repository: try! GitHubRepository("owner/repository")
)
private let secondLease = RunnerLease(
    runnerID: RunnerID(value: "yieldd-test-456"),
    repository: try! GitHubRepository("other/repository")
)

@Test
func leaseStoreRoundTripsAndClearsLease() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)

    #expect(try store.load().isEmpty)

    try store.save(lease)
    try store.save(secondLease)
    #expect(try store.load() == [lease, secondLease])

    try store.clear(lease.runnerID)
    #expect(try store.load() == [secondLease])

    try store.clear(secondLease.runnerID)
    try store.clear(secondLease.runnerID)
    #expect(try store.load().isEmpty)
}

@Test
func leaseStoreReadsTheSingleRunnerFormat() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    try Data(
        #"{"runnerID":"yieldd-test-123","repository":"owner/repository"}"#.utf8
    ).write(to: store.fileURL)

    #expect(try store.load() == [lease])
}

@Test
func leaseStorePreservesConcurrentUpdates() async throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    let leases = try (0..<8).map { index in
        RunnerLease(
            runnerID: RunnerID(value: "yieldd-test-\(index)"),
            repository: try GitHubRepository("owner/repository-\(index)")
        )
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for lease in leases {
            group.addTask {
                try store.save(lease)
            }
        }
        try await group.waitForAll()
    }

    #expect(Set(try store.load().map(\.runnerID)) == Set(leases.map(\.runnerID)))
}

@Test
func leaseStoreSupportsMaximumRunnerSlots() throws {
    let directory = makeStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    let repository = try GitHubRepository(
        "\(String(repeating: "o", count: 39))/\(String(repeating: "r", count: 100))"
    )

    for index in 0..<RunnerPool.maximumSlots {
        let suffix = String(index)
        let runnerID = RunnerID(value:
            "yieldd-\(String(repeating: "a", count: 121 - suffix.count))\(suffix)"
        )
        try store.save(RunnerLease(runnerID: runnerID, repository: repository))
    }

    #expect(try store.load().count == RunnerPool.maximumSlots)
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
