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
    try store.finish(seed, publish: true)

    let pr = runner()
    let inherited = try store.open(pr, readable: [pullRequestScope, mainScope], writable: pullRequestScope)
    #expect(!inherited.isCold)
    #expect(try read(inherited) == "main1")
    try mark(inherited, "pull1")
    try store.finish(pr, publish: true)

    for (scope, expected) in [(mainScope, "main1"), (pullRequestScope, "pull1")] {
        let id = runner()
        let reader = try store.open(id, readable: [scope], writable: nil)
        #expect(try read(reader) == expected)
        try mark(reader, "other")
        try store.finish(id, publish: true)
        let later = runner()
        #expect(try read(store.open(later, readable: [scope], writable: nil)) == expected)
        try store.finish(later, publish: false)
    }
}

@Test func concurrentNativePublishPreservesFirstCompletedGeneration() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux, diskBytes: 1 << 20)
    let one = runner(), two = runner()
    try mark(store.open(one, readable: [mainScope], writable: mainScope), "first")
    try mark(store.open(two, readable: [mainScope], writable: mainScope), "later")
    try store.finish(one, publish: true)
    try store.finish(two, publish: true)
    let check = runner()
    #expect(try read(store.open(check, readable: [mainScope], writable: nil)) == "first")
}

@Test func frequentlyRestoredBaseSurvivesPullRequestEviction() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux, diskBytes: 1 << 20)
    let first = runner()
    try mark(store.open(first, readable: [], writable: mainScope), "main1")
    try store.finish(first, publish: true)
    for n in 0..<17 {
        let id = runner()
        let pr = String(format: "%064x", n)
        #expect(try !store.open(id, readable: [pr, mainScope], writable: pr).isCold)
        try store.finish(id, publish: true)
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
    #expect(throws: (any Error).self) { try store.finish(id, publish: true) }
    let check = runner()
    #expect(try store.open(check, readable: [mainScope], writable: nil).isCold)
    try store.finish(id, publish: false)
}

@Test func nativeStoreRejectsInvalidScopeAndRunnerBeforeCreatingJob() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCacheStore(root: root, platform: .linux)
    #expect(throws: JobCacheError.self) { try store.open(runner(), readable: ["../seed"], writable: nil) }
    #expect(throws: RunnerLeaseError.self) { try store.jobDirectory(.init(value: "yieldd-../sibling")) }
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
    try store.finish(id, publish: true)
    let second = runner()
    #expect(try !store.open(second, readable: [mainScope], writable: nil).isCold)
    try store.finish(second, publish: false)
}
