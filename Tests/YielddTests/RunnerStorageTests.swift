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
    let error = try #require(#expect(throws: RunnerStorageError.self) { try RunnerStorage.load(in: fixture.directory) })
    guard case let .invalidConfiguration(path, reason) = error else { Issue.record("Expected decoding diagnostic"); return }
    #expect(path == file.path)
    #expect(!reason.isEmpty)
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

@Test(arguments: [false, true])
func storageConfigurationValidatesTheVolumeWithoutReadingItAgain(hasQuota: Bool) throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let volume = fixture.directory.resolvingSymlinksInPath()
    let leases = try RunnerLeaseStore(directory: fixture.directory)
    let uuid = UUID().uuidString
    let info = try plist(["VolumeUUID": uuid, "MountPoint": volume.path, "FilesystemType": "apfs"])
    let listing = try plist(["Containers": [["Volumes": [["APFSVolumeUUID": uuid, "CapacityQuota": hasQuota ? 12345 : 0]]]]])
    let executor = RecordingProcessExecutor(outcomes: [
        .success(ProcessResult(stdout: info, stderr: Data(), terminationReason: .exit, terminationStatus: 0)),
        .success(ProcessResult(stdout: listing, stderr: Data(), terminationReason: .exit, terminationStatus: 0)),
    ])
    let expected: RunnerStorageError = hasQuota ? .journalOnGuestVolume : .noQuota(path: volume.path)

    #expect(throws: expected) {
        try configureRunnerStorage(volume: volume, leaseStore: leases, executor: executor)
    }
    #expect(executor.requests.map(\.arguments) == [
        ["info", "-plist", volume.path],
        ["apfs", "list", "-plist"],
    ])
    #expect(try RunnerStorage.load(in: leases.directory) == nil)
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
    case "unlimited": .noQuota(path: path)
    case "journal": .journalOnGuestVolume
    default: .volumeUnavailable(path: path)
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
    #expect(throws: RunnerStorageError.outsideVolume(path: storage.clonesURL.path)) { try storage.validatePath(storage.clonesURL) }
    let id = RunnerID(value: "yieldd-retained")
    let machine = storage.containerURL.appendingPathComponent("plugin-state/machine-apiserver/machines/\(id.value)")
    try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
    #expect(throws: RunnerStorageError.machineStorageRemains(runner: id.value, path: machine.path)) { try storage.requireMachineRemoved(id) }
    try FileManager.default.removeItem(at: machine)
    try storage.requireMachineRemoved(id)
}

@Test
func backendStorageFailurePreventsGuestCreation() throws {
    let executor = RecordingProcessExecutor(outcomes: [])
    let backend = try AppleContainerBackend(containerURL: URL(fileURLWithPath: "/missing/container"), executor: executor,
        stateDirectory: unconfiguredContainerStateDirectory)
    #expect(throws: RunnerStorageError.notConfigured) { try backend.create(id: RunnerID(value: "yieldd-test"), memory: .full) }
    #expect(executor.requests.isEmpty)
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let mac = try MacOSVirtualizationBackend(stateDirectory: unconfiguredContainerStateDirectory, templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: executor, requireEntitlement: {},
        makeMachine: { _, _, _ in Issue.record("No VM may be created without a quota"); throw TestFailure.create })
    #expect(throws: RunnerStorageError.notConfigured) { try mac.create(id: RunnerID(value: "yieldd-test"), memory: .full) }
    #expect(!FileManager.default.fileExists(atPath: fixture.cloneRootURL.path))
}

@Test
func storageCLIRejectsRelativeVolume() throws {
    let error = try #require(#expect(throws: (any Error).self) { try StorageConfigureCommand.parse(["--volume", "relative"]) })
    #expect(StorageConfigureCommand.message(for: error) == "--volume must be an absolute mount point.")
}

@Test(arguments: [false, true])
func storageRejectsExistingAndDanglingSymlinkPrefixes(dangling: Bool) throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let root = fixture.directory.resolvingSymlinksInPath().appendingPathComponent("volume")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let storage = RunnerStorage(volumePath: root.path, volumeUUID: UUID().uuidString)
    let target = dangling ? fixture.directory.appendingPathComponent("absent") : fixture.directory
    let link = root.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let absentChild = link.appendingPathComponent("not-created/guest.bundle")
    #expect(throws: RunnerStorageError.outsideVolume(path: absentChild.path)) { try storage.validatePath(absentChild) }
    try storage.validatePath(root.appendingPathComponent("safe/not-created/guest.bundle"))
}

@Test
func missingStorageBindingBlocksBothDestructionBackends() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let executor = RecordingProcessExecutor(outcomes: [])
    let linux = try AppleContainerBackend(containerURL: URL(fileURLWithPath: "/missing/container"), executor: executor,
                                      stateDirectory: fixture.rootURL)
    let mac = try MacOSVirtualizationBackend(stateDirectory: fixture.rootURL, templateURL: fixture.templateURL,
        cloneRootURL: fixture.cloneRootURL, executor: executor)
    let id = RunnerID(value: "yieldd-retained")
    let bundle = try MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL).bundleURL(for: id)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    for backend: any RunnerBackend in [linux, mac] {
        #expect(throws: RunnerStorageError.notConfigured) { try backend.destroy(id) }
    }
    #expect(executor.requests.isEmpty)
    #expect(FileManager.default.fileExists(atPath: bundle.path))
}

@Test
func doctorAndInstallerRejectMissingStorageWithoutStartingAnything() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let executor = RecordingProcessExecutor(outcomes: [])
    let report = Doctor(stateDirectory: fixture.directory, executor: executor,
        executableLocator: ExecutableLocator(searchPath: fixture.directory.path)).run()
    #expect(!report.succeeded)
    #expect(report.checks.last == DoctorCheck(name: "Runner storage", status: .failed(describeError(RunnerStorageError.notConfigured))))
    let command = try AgentInstallCommand.parse(["owner/repo", "--preflight-only"])
    #expect(throws: RunnerStorageError.notConfigured) {
        try command.run(locateExecutable: { _ in URL(fileURLWithPath: "/usr/bin/true") }, stateDirectory: fixture.directory,
                        memoryAdmission: RunnerMemoryAdmission(physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024))
    }
    #expect(executor.requests.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("agent.json").path))
}

@Test
func stoppedContainerReportsItsRequiredStartupRoot() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let storage = RunnerStorage(volumePath: fixture.directory.resolvingSymlinksInPath().path, volumeUUID: UUID().uuidString)
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult(stderr: "service stopped", status: 1))])
    let error = try #require(#expect(throws: RunnerStorageError.self) {
        try storage.validateContainer(containerExecutable: URL(fileURLWithPath: "/test/container"), executor: executor)
    })
    #expect(describeError(error).contains("--app-root"))
    #expect(describeError(error).contains("service stopped"))
}

@Test(arguments: [false, true])
func containerStatusValidatesConfiguredRoot(nestedPaths: Bool) throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let storage = RunnerStorage(volumePath: fixture.directory.resolvingSymlinksInPath().path, volumeUUID: UUID().uuidString)
    try FileManager.default.createDirectory(at: storage.containerURL, withIntermediateDirectories: true)
    let matching = nestedPaths
        ? #"{"status":"running","paths":{"appRoot":"\#(storage.containerURL.path)"}}"#
        : #"{"status":"running","appRoot":"\#(storage.containerURL.path)"}"#
    let mismatching = nestedPaths
        ? #"{"status":"running","paths":{"appRoot":"\#(fixture.directory.path)"}}"#
        : #"{"status":"running","appRoot":"\#(fixture.directory.path)"}"#
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: matching)),
        .success(processResult(stdout: mismatching)),
    ])
    let container = URL(fileURLWithPath: "/test/container")
    try storage.validateContainer(containerExecutable: container, executor: executor)
    #expect(throws: RunnerStorageError.containerRootMismatch(path: storage.containerURL.path)) {
        try storage.validateContainer(containerExecutable: container, executor: executor)
    }
}

@Test
func containerStatusWithNullPathsUsesLegacyRoot() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let storage = RunnerStorage(volumePath: fixture.directory.resolvingSymlinksInPath().path, volumeUUID: UUID().uuidString)
    try FileManager.default.createDirectory(at: storage.containerURL, withIntermediateDirectories: true)
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult(
        stdout: #"{"status":"running","paths":null,"appRoot":"\#(storage.containerURL.path)"}"#))])
    try storage.validateContainer(containerExecutable: URL(fileURLWithPath: "/test/container"), executor: executor)
}

@Test(arguments: [#"{"status":"running"}"#, #"{"status":"running","paths":null}"#])
func containerStatusWithoutRootReportsMissingPath(status: String) throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let storage = RunnerStorage(volumePath: fixture.directory.resolvingSymlinksInPath().path, volumeUUID: UUID().uuidString)
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult(stdout: status))])
    #expect(throws: RunnerStorageError.containerUnavailable(detail: "system status did not report paths.appRoot")) {
        try storage.validateContainer(containerExecutable: URL(fileURLWithPath: "/test/container"), executor: executor)
    }
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
