import Foundation
import Testing
@testable import Yieldd

@Test
func cloneSweepRemovesOnlyUnleasedRunnerDirectories() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL)
    let retained = ["notes.bundle", "yieldd-invalid_name.bundle", "yieldd-macos-other.backup"]
    let removed = ["yieldd-macos-incomplete.creating", "yieldd-macos-abandoned.bundle"]
    for name in retained + removed {
        try FileManager.default.createDirectory(
            at: fixture.cloneRootURL.appendingPathComponent(name), withIntermediateDirectories: true
        )
    }
    let file = fixture.cloneRootURL.appendingPathComponent("yieldd-regular-file.bundle")
    try Data("keep".utf8).write(to: file)
    let link = fixture.cloneRootURL.appendingPathComponent("yieldd-external.bundle")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.templateURL)
    try store.removeUnleased()
    try store.removeUnleased()
    let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.cloneRootURL.path)
    #expect(Set(contents) == Set(retained + [file.lastPathComponent, link.lastPathComponent]))
    #expect(try Data(contentsOf: fixture.templateURL.appendingPathComponent("Disk.img")) == fixture.disk)
}

@Test
func cloneSweepDoesNotFollowSymlinksInsideAbandonedClones() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL)
    let clone = try store.bundleURL(for: RunnerID(value: "yieldd-macos-abandoned"))
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: clone.appendingPathComponent("shared"), withDestinationURL: fixture.templateURL
    )
    try store.removeUnleased()
    #expect(try fixture.cloneRootContents().isEmpty)
    #expect(try Data(contentsOf: fixture.templateURL.appendingPathComponent("Disk.img")) == fixture.disk)
}

@Test
func cloneSweepRejectsSymlinkedRootAndPreservesItsTarget() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    try FileManager.default.createSymbolicLink(at: fixture.cloneRootURL, withDestinationURL: fixture.templateURL)
    let store = MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL)
    let id = RunnerID(value: "yieldd-macos-protected")
    let target = fixture.templateURL.appendingPathComponent("\(id.value).bundle")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    #expect(throws: MacOSRunnerCloneStoreError.self) { try store.removeUnleased() }
    #expect(throws: MacOSRunnerCloneStoreError.self) { try store.remove(id) }
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test
func cloneSweepAcceptsMissingRootWithoutCreatingIt() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    try MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL).removeUnleased()
    #expect(!FileManager.default.fileExists(atPath: fixture.cloneRootURL.path))
}

@Test
func cloneSweepAttemptsOtherClonesAfterRemovalFailure() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL)
    let blocked = try store.bundleURL(for: RunnerID(value: "yieldd-macos-blocked"))
    let removable = try store.creatingURL(for: RunnerID(value: "yieldd-macos-removable"))
    for url in [blocked, removable] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: url.appendingPathComponent("state"))
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
    #expect(throws: MacOSRunnerCloneStoreError.self) { try store.removeUnleased() }
    #expect(FileManager.default.fileExists(atPath: blocked.path))
    #expect(!FileManager.default.fileExists(atPath: removable.path))
}

@Test
func cloneRemovalAttemptsBothPathsAfterPartialFailure() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL)
    let id = RunnerID(value: "yieldd-macos-partial")
    let incomplete = try store.creatingURL(for: id)
    let published = try store.bundleURL(for: id)
    for url in [incomplete, published] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: url.appendingPathComponent("state"))
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: incomplete.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: incomplete.path) }
    #expect(throws: MacOSRunnerCloneStoreError.self) { try store.remove(id) }
    #expect(!FileManager.default.fileExists(atPath: published.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: incomplete.path)
    try store.remove(id)
    #expect(try fixture.cloneRootContents().isEmpty)
}
