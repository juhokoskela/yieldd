import Darwin
import Foundation
import Testing
@testable import Yieldd

private let mainScope = String(repeating: "a", count: 64)
private let pullRequestScope = String(repeating: "b", count: 64)

private func runner() -> RunnerID { .init(value: "yieldd-" + UUID().uuidString.lowercased()) }

private func workspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}

private func mark(_ disk: NativeCacheDisk, _ text: String) throws {
    let file = try FileHandle(forWritingTo: disk.url)
    defer { try? file.close() }
    try file.write(contentsOf: Data(text.utf8))
}

private func read(_ disk: NativeCacheDisk) throws -> String {
    let file = try FileHandle(forReadingFrom: disk.url)
    defer { try? file.close() }
    return String(decoding: try file.read(upToCount: 5) ?? Data(), as: UTF8.self)
}

@Test func nativeJobsClonePrivateImagesAndPublishOnlyToTheirWriteScope() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux, diskBytes: 1 << 20)
    let seed = runner()
    let first = try store.open(seed, readable: [mainScope], writable: mainScope)
    #expect(first.isCold)
    try mark(first, "main1")
    try store.publish(first)
    try store.discard(seed)

    let pr = runner()
    let inherited = try store.open(pr, readable: [pullRequestScope, mainScope], writable: pullRequestScope)
    #expect(!inherited.isCold)
    #expect(try read(inherited) == "main1")
    try mark(inherited, "pull1")
    try store.publish(inherited)
    try store.discard(pr)

    for (scope, expected) in [(mainScope, "main1"), (pullRequestScope, "pull1")] {
        let id = runner()
        let reader = try store.open(id, readable: [scope], writable: nil)
        #expect(try read(reader) == expected)
        try mark(reader, "other")
        try store.publish(reader)
        try store.discard(id)
        let later = runner()
        #expect(try read(store.open(later, readable: [scope], writable: nil)) == expected)
        try store.discard(later)
    }
}

@Test func concurrentNativePublishPreservesFirstCompletedGeneration() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux, diskBytes: 1 << 20)
    let one = runner(), two = runner()
    let first = try store.open(one, readable: [mainScope], writable: mainScope)
    let second = try store.open(two, readable: [mainScope], writable: mainScope)
    try mark(first, "first")
    try mark(second, "later")
    try store.publish(first)
    try store.publish(second)
    let check = runner()
    #expect(try read(store.open(check, readable: [mainScope], writable: nil)) == "first")
}

@Test func frequentlyRestoredBaseSurvivesPullRequestEviction() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux, diskBytes: 1 << 20)
    let first = runner()
    let disk = try store.open(first, readable: [], writable: mainScope)
    try mark(disk, "main1")
    try store.publish(disk)
    for n in 0..<17 {
        let id = runner()
        let pr = String(format: "%064x", n)
        let disk = try store.open(id, readable: [pr, mainScope], writable: pr)
        #expect(!disk.isCold)
        try store.publish(disk)
    }
    let reader = runner()
    #expect(try read(store.open(reader, readable: [mainScope], writable: nil)) == "main1")
}

@Test(arguments: ["replace", "symlink", "resize", "hardlink"])
func replacedGuestDiskCannotBecomeASeed(change: String) throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux, diskBytes: 1 << 20)
    let id = runner()
    let disk = try store.open(id, readable: [], writable: mainScope)
    let other = root.appendingPathComponent("other")
    switch change {
    case "replace", "symlink":
        try FileManager.default.moveItem(at: disk.url, to: other)
        if change == "replace" { try FileManager.default.copyItem(at: other, to: disk.url) }
        else { try FileManager.default.createSymbolicLink(at: disk.url, withDestinationURL: other) }
    case "hardlink":
        try FileManager.default.linkItem(at: disk.url, to: other)
    default:
        #expect(truncate(disk.url.path, 1) == 0)
    }
    #expect(throws: (any Error).self) { try store.publish(disk) }
    let check = runner()
    #expect(try store.open(check, readable: [mainScope], writable: nil).isCold)
    try store.discard(id)
}

@Test func nativeStoreRejectsInvalidScopeAndRunnerBeforeCreatingJob() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux)
    #expect(throws: JobCacheError.self) { try store.open(runner(), readable: ["../seed"], writable: nil) }
    #expect(throws: RunnerLeaseError.self) {
        try store.open(.init(value: "yieldd-../sibling"), readable: [mainScope], writable: nil)
    }
}

@Test func macOSColdDiskHasTheRequestedRawSizeAndCanBeCloned() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let size: Int64 = 256 << 20
    let store = NativeCacheStore(root: root, platform: .macOS, diskBytes: size)
    let id = runner()
    let first = try store.open(id, readable: [mainScope], writable: mainScope)
    #expect(first.isCold)
    let file = try FileHandle(forReadingFrom: first.url)
    #expect(try file.seekToEnd() == UInt64(size))
    try file.close()
    try store.publish(first)
    let second = runner()
    #expect(try !store.open(second, readable: [mainScope], writable: nil).isCold)
    try store.discard(second)
}

@Test func abandonedCheckoutCannotReopenUntilRecoveryDiscardsIt() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux, diskBytes: 4096)
    let id = runner()
    let first = try store.open(id, readable: [], writable: mainScope)
    #expect(try FileManager.default.contentsOfDirectory(atPath: first.url.deletingLastPathComponent().path) == ["cache.img"])
    #expect(throws: JobCacheError.self) { try store.open(id, readable: [], writable: mainScope) }
    let restarted = NativeCacheStore(root: root, platform: .linux, diskBytes: 4096)
    try restarted.discard(id)
    #expect(!FileManager.default.fileExists(atPath: first.url.deletingLastPathComponent().path))
    #expect(try restarted.open(id, readable: [mainScope], writable: nil).isCold)
}

@Test func warmLookupLeavesTheIndexAloneAndPublicationReapsOrphans() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux, diskBytes: 4096)
    let first = runner()
    try store.publish(store.open(first, readable: [], writable: mainScope))
    try store.discard(first)
    let area = root.appendingPathComponent(RunnerPlatform.linux.rawValue)
    let index = area.appendingPathComponent("index.json")
    let before = try Data(contentsOf: index)
    let orphan = area.appendingPathComponent("seeds/\(UUID().uuidString).img")
    try Data().write(to: orphan)
    let second = runner()
    let disk = try store.open(second, readable: [mainScope], writable: mainScope)
    #expect(!disk.isCold)
    #expect(try Data(contentsOf: index) == before)
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    try store.publish(disk)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    try store.discard(second)
}
