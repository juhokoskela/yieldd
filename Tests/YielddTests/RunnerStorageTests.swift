import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import Yieldd

@Test
func storageConfigurationIsPrivateAndCannotChangeIdentity() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    #expect(try RunnerStorage.load(in: fixture.directory) == nil)
    #expect(throws: RunnerStorageError.notConfigured) { try RunnerStorage.required(in: fixture.directory) }
    let storage = RunnerStorage(volumePath: "/Volumes/Runners", volumeUUID: UUID().uuidString)
    try storage.save(in: fixture.directory)
    try storage.save(in: fixture.directory)
    #expect(try RunnerStorage.load(in: fixture.directory) == storage)
    let permissions = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent("storage.json").path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    #expect(throws: RunnerStorageError.alreadyConfigured) {
        try RunnerStorage(volumePath: "/Volumes/Other", volumeUUID: UUID().uuidString).save(in: fixture.directory)
    }
    #expect(try RunnerStorage.load(in: fixture.directory) == storage)
}

@Test
func storageRefusesMalformedOrSymlinkedConfiguration() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let file = fixture.directory.appendingPathComponent("storage.json")
    try Data("{}".utf8).write(to: file)
    #expect(throws: RunnerStorageError.invalidConfiguration) { try RunnerStorage.load(in: fixture.directory) }
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.directory.appendingPathComponent("absent"))
    #expect(throws: POSIXError.self) { try RunnerStorage.load(in: fixture.directory) }
}

@Test(arguments: [false, true])
func storageConfigurationRefusesUnresolvedLeases(connected: Bool) throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let leases = try RunnerLeaseStore(directory: fixture.directory)
    if connected {
        let offer = try ConnectedOffer(owner: UUID().uuidString.lowercased(),
            runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())", repository: "owner/repo", platform: "linux", architecture: "arm64")
        try ConnectedRunnerStore(directory: fixture.directory).save(ConnectedLease(server: "https://example.com", deviceID: "device", offer: offer))
    } else {
        try leases.save(RunnerLease(runnerID: RunnerID(value: "yieldd-pending"), repository: GitHubRepository("owner/repo")))
    }
    let executor = RecordingProcessExecutor(outcomes: [])
    #expect(throws: RunnerStorageError.outstandingRecovery) {
        try configureRunnerStorage(volume: fixture.directory, leaseStore: leases, executor: executor)
    }
    #expect(executor.requests.isEmpty)
    #expect(try RunnerStorage.load(in: fixture.directory) == nil)
}

@Test
func storageRefusesLegacyClonesWithoutRemovingThem() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let leases = try RunnerLeaseStore(directory: fixture.directory)
    let clone = fixture.directory.appendingPathComponent("macos-runners/yieldd-old.bundle")
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    #expect(throws: RunnerStorageError.legacyClones) {
        try configureRunnerStorage(volume: fixture.directory, leaseStore: leases, executor: RecordingProcessExecutor(outcomes: []))
    }
    #expect(FileManager.default.fileExists(atPath: clone.path))
}

@Test(arguments: ["missing", "identity", "unlimited", "journal"])
func storageValidationFailsClosed(failure: String) throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let path = fixture.directory.resolvingSymlinksInPath().path
    let uuid = UUID().uuidString
    let storage = RunnerStorage(volumePath: path, volumeUUID: uuid)
    let mountPoint = failure == "missing" ? "/Volumes/Elsewhere" : path
    let info = try plist(["VolumeUUID": failure == "identity" ? UUID().uuidString : uuid,
                          "MountPoint": mountPoint, "FilesystemType": "apfs"])
    let listing = try plist(["Containers": [["Volumes": [["APFSVolumeUUID": uuid, "CapacityQuota": failure == "unlimited" ? 0 : 12345]]]]])
    let executor = RecordingProcessExecutor(outcomes: [
        .success(ProcessResult(stdout: info, stderr: Data(), terminationReason: .exit, terminationStatus: 0)),
        .success(ProcessResult(stdout: listing, stderr: Data(), terminationReason: .exit, terminationStatus: 0)),
    ])
    let expected: RunnerStorageError = switch failure {
    case "unlimited": .noQuota(path)
    case "journal": .journalOnGuestVolume
    default: .volumeUnavailable(path)
    }
    #expect(throws: expected) { try storage.validate(stateDirectory: fixture.directory, executor: executor) }
}

@Test
func storageRejectsSymlinkEscapesAndMissingMachineCleanup() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let volume = fixture.directory.appendingPathComponent("volume")
    try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: false)
    let storage = RunnerStorage(volumePath: volume.resolvingSymlinksInPath().path, volumeUUID: UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: storage.clonesURL, withDestinationURL: fixture.directory)
    #expect(throws: RunnerStorageError.outsideVolume(storage.clonesURL.path)) { try storage.validatePath(storage.clonesURL) }
    let id = RunnerID(value: "yieldd-retained")
    let machine = storage.containerURL.appendingPathComponent("plugin-state/machine-apiserver/machines/\(id.value)")
    try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
    #expect(throws: RunnerStorageError.machineStorageRemains(id.value)) { try storage.requireMachineRemoved(id) }
    try FileManager.default.removeItem(at: machine)
    try storage.requireMachineRemoved(id)
}

@Test
func backendStorageFailurePreventsGuestCreation() throws {
    let executor = RecordingProcessExecutor(outcomes: [])
    let backend = AppleContainerBackend(containerURL: URL(fileURLWithPath: "/missing/container"), executor: executor,
        validateStorage: { throw RunnerStorageError.notConfigured })
    #expect(throws: RunnerStorageError.notConfigured) { try backend.create(id: RunnerID(value: "yieldd-test"), memory: .full) }
    #expect(executor.requests.isEmpty)
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let mac = try MacOSVirtualizationBackend(templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: executor, requireEntitlement: {}, validateStorageQuota: { _, _ in throw RunnerStorageError.notConfigured },
        makeMachine: { _, _ in Issue.record("No VM may be created without a quota"); throw TestFailure.create })
    #expect(throws: RunnerStorageError.notConfigured) { try mac.create(id: RunnerID(value: "yieldd-test"), memory: .full) }
    #expect(!FileManager.default.fileExists(atPath: fixture.cloneRootURL.path))
}

@Test
func storageCLIRejectsRelativeVolume() throws {
    let error = try #require(#expect(throws: (any Error).self) { try StorageConfigureCommand.parse(["--volume", "relative"]) })
    #expect(StorageConfigureCommand.message(for: error) == "--volume must be an absolute mount point.")
}

private func plist(_ object: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}

struct StorageFixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("yieldd-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
