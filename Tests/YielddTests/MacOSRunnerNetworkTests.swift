import Darwin
import Foundation
import Testing
import Virtualization
@testable import Yieldd

@Suite struct MacOSRunnerNetworkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YIELDD_TEST_RELAY"] != nil))
    func realRelayAttachmentAndCleanupWithFakeVM() throws {
        let executable = try #require(ProcessInfo.processInfo.environment["YIELDD_TEST_RELAY"])
        let fixture = try ProbeBundleFixture()
        defer { fixture.remove() }
        let directories = try RunnerNetworkDirectories(stateDirectory: fixture.rootURL)
        defer { try? FileManager.default.removeItem(at: directories.rootURL) }
        let machine = ProbeVirtualMachine()
        let executor = RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2))
        var socket: PacketSocket?
        let backend = try MacOSVirtualizationBackend(
            stateDirectory: fixture.rootURL, templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
            executor: executor,
            network: MacOSRunnerNetwork(stateDirectory: fixture.rootURL, executableURL: URL(fileURLWithPath: executable)),
            requireEntitlement: {}, requireRelay: { try MacOSRunnerNetwork.requireRelay(at: URL(fileURLWithPath: executable)) },
            loadStorage: { nil }, makeMachine: { _, _, path in
                socket = try PacketSocket(path: path.path)
                return machine
            }
        )
        let id = RunnerID(value: "yieldd-network-integration")
        defer { try? backend.destroy(id) }
        try backend.create(id: id, memory: .full)
        let device = try #require(socket).device()
        #expect(device.attachment is VZFileHandleNetworkDeviceAttachment)
        #expect(device.macAddress.string == "02:00:00:00:00:02")
        let request = try #require(executor.requests.first)
        #expect(request.arguments.contains { $0.hasPrefix("ProxyCommand=/usr/bin/nc -U '") })
        #expect(request.arguments.contains("runner@yieldd-macos-template"))
        try backend.destroy(id)
        socket = nil
        #expect(machine.isStopped)
        #expect(try fixture.cloneRootContents().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directories.rootURL.path).isEmpty)
    }
}

@Test
func runnerNetworkDirectoriesArePrivateShortAndRecoverable() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = try RunnerNetworkDirectories(stateDirectory: fixture.rootURL)
    defer { try? FileManager.default.removeItem(at: store.rootURL) }
    #expect(try store.rootURL.deletingLastPathComponent() == RunnerNetworkRelay.userTemporaryDirectory())
    try RunnerNetworkRelay.requirePrivateDirectory(store.rootURL.deletingLastPathComponent())
    let first = RunnerID(value: "yieldd-network-first")
    let second = RunnerID(value: "yieldd-network-second")
    let kept = try store.create(for: first)
    let orphan = try store.create(for: second)
    try Data("socket placeholder".utf8).write(to: orphan.appendingPathComponent("stale"))
    for directory in [store.rootURL, kept, orphan] {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
    }
    #expect(kept.appendingPathComponent("n.ssh").path.utf8.count < 104)
    let recovered = try RunnerNetworkDirectories(stateDirectory: fixture.rootURL)
    #expect(recovered.rootURL == store.rootURL)
    try recovered.removeUnleased(keeping: [first])
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    try recovered.remove(first)
    try recovered.remove(first)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path).isEmpty)
    #expect(try RunnerNetworkDirectories(stateDirectory: fixture.rootURL.appendingPathComponent("other")).rootURL != store.rootURL)
}

@Test
func runnerNetworkDirectoriesRejectReplacedPaths() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = try RunnerNetworkDirectories(stateDirectory: fixture.rootURL)
    defer { try? FileManager.default.removeItem(at: store.rootURL) }
    let id = RunnerID(value: "yieldd-network-first")
    let directory = try store.create(for: id)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.templateURL)
    #expect(throws: POSIXError(.EACCES)) { try store.create(for: id) }
    #expect(throws: POSIXError(.EACCES)) { try store.remove(id) }
    #expect(throws: POSIXError(.EACCES)) { try store.removeUnleased(keeping: []) }
    #expect(FileManager.default.fileExists(atPath: fixture.templateURL.path))
}

@Test
func runnerNetworkPreflightRejectsMissingHelperWithoutCreatingDirectories() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let missing = fixture.rootURL.appendingPathComponent("missing-relay")
    #expect(throws: MacOSRunnerNetworkError.self) { try MacOSRunnerNetwork.requireRelay(at: missing) }
    #expect(!FileManager.default.fileExists(atPath: try RunnerNetworkDirectories(stateDirectory: fixture.rootURL).rootURL.path))
}

@Test
func runnerNetworkOrphansAreRemovedEvenWhenCloneStorageIsMissing() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = try RunnerNetworkDirectories(stateDirectory: fixture.rootURL)
    defer { try? FileManager.default.removeItem(at: store.rootURL) }
    let orphan = try store.create(for: RunnerID(value: "yieldd-network-orphan"))
    #expect(throws: RunnerSessionError.self) {
        try removeUnleasedMacOSClones(in: fixture.rootURL, keeping: [])
    }
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
}
