import Darwin
import Foundation
import Testing
@testable import Yieldd

// Opt in because this mounts a disposable image. Its sparse capacity is 2 GiB,
// and the write probe is independently bounded to 128 MiB even if the quota fails.
@Test(.enabled(if: ProcessInfo.processInfo.environment["YIELDD_STORAGE_INTEGRATION"] == "1"))
func storageQuotaStopsWritesButNotRecoveryJournal() throws {
    let fixture = try StorageFixture()
    let suffix = UUID().uuidString
    let baseName = "yieldd-base-\(suffix)"
    let quotaName = "yieldd-quota-\(suffix)"
    let base = URL(fileURLWithPath: "/Volumes/\(baseName)")
    let volume = URL(fileURLWithPath: "/Volumes/\(quotaName)")
    let image = fixture.directory.appendingPathComponent("guest-storage.sparsebundle")
    let executor = ProcessExecutor()
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let request = ProcessRequest(executableURL: URL(fileURLWithPath: executable), arguments: arguments,
            timeout: 60, outputCapture: .tail(maxBytes: 1_024 * 1_024))
        let result = try executor.execute(request)
        if result.terminationStatus != 0 { print(result.stdoutText + result.stderrText) }
        return try result.requireSuccess(for: request)
    }
    _ = try run("/usr/bin/hdiutil", ["create", "-size", "2g", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", baseName, image.path])
    _ = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", image.path])
    var mounted = true
    defer {
        if mounted {
            do { _ = try run("/usr/bin/hdiutil", ["detach", base.path]); mounted = false }
            catch { Issue.record("Could not detach test image at \(image.path): \(error)") }
        }
        if !mounted { fixture.remove() }
    }
    struct Info: Decodable { let APFSContainerReference: String }
    let info = try PropertyListDecoder().decode(Info.self,
        from: run("/usr/sbin/diskutil", ["info", "-plist", base.path]).stdout)
    _ = try run("/usr/sbin/diskutil", ["apfs", "addVolume", info.APFSContainerReference,
                                     "APFS", quotaName, "-quota", "67108864"])
    let leases = try RunnerLeaseStore(directory: fixture.directory.appendingPathComponent("journal"))
    let legacy = leases.directory.appendingPathComponent("macos-runners")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
    try Data().write(to: legacy.appendingPathComponent(".DS_Store"))
    let storage = try configureRunnerStorage(volume: volume, leaseStore: leases)
    #expect(try configureRunnerStorage(volume: volume, leaseStore: leases) == storage)
    #expect(try storage.validate(stateDirectory: leases.directory).quotaBytes == 64 * 1_024 * 1_024)
    let template = volume.appendingPathComponent("Template.bundle")
    let templateFixture = try ProbeBundleFixture()
    defer { templateFixture.remove() }
    try FileManager.default.copyItem(at: templateFixture.templateURL, to: template)
    try storage.validateMacOS(template: template, clones: storage.clonesURL)
    let home = fixture.directory.appendingPathComponent("preflight-home")
    let preflightState = try RunnerLeaseStore(directory: home.appendingPathComponent("Library/Application Support/yieldd"))
    try storage.save(in: preflightState.directory)
    let tools = fixture.directory.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
    for name in ["container", "gh"] {
        try FileManager.default.createSymbolicLink(at: tools.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
    }
    let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/yieldd")
    for linux in [false, true] {
        let arguments = linux ? ["owner/repo"] : ["--macos", "owner/repo", "--macos-template", template.path]
        let result = try run("/usr/bin/env", ["CFFIXED_USER_HOME=\(home.path)", "PATH=\(tools.path)",
            binary.path, "agent", "install", "--preflight-only"] + arguments)
        #expect(result.stdoutText == (linux ? "linux\n" : "macos\n"))
    }
    #expect(throws: RunnerStorageError.outsideVolume(path: fixture.directory.path)) {
        try storage.validateMacOS(template: fixture.directory, clones: storage.clonesURL)
    }
    let containerStatus = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "{\"status\":\"running\",\"appRoot\":\"\(storage.containerURL.path)\"}")),
    ])
    try storage.validateContainer(containerExecutable: URL(fileURLWithPath: "/test/container"),
                                  executor: containerStatus)
    let wrongRoot = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "{\"status\":\"running\",\"appRoot\":\"\(fixture.directory.path)\"}")),
    ])
    #expect(throws: RunnerStorageError.containerRootMismatch(path: storage.containerURL.path)) {
        try storage.validateContainer(containerExecutable: URL(fileURLWithPath: "/test/container"),
                                      executor: wrongRoot)
    }

    let linuxID = RunnerID(value: "yieldd-linux-quota")
    let linuxBundle = storage.containerURL.appendingPathComponent("plugin-state/machine-apiserver/machines/\(linuxID.value)")
    try FileManager.default.createDirectory(at: linuxBundle, withIntermediateDirectories: true)
    let container = StorageContainerExecutor(storage: storage, id: linuxID)
    let linux = AppleContainerBackend(containerURL: URL(fileURLWithPath: "/test/container"),
        executor: container, stateDirectory: leases.directory)
    try AppleContainerSystem(containerURL: URL(fileURLWithPath: "/test/container"), executor: container,
                             stateDirectory: leases.directory).start()
    #expect(container.startArguments?.contains(storage.containerURL.path) == true)
    #expect(throws: RunnerStorageError.machineStorageRemains(runner: linuxID.value, path: linuxBundle.path)) { try linux.destroy(linuxID) }
    #expect(container.deleteCount == 1)
    container.listed = false
    #expect(throws: RunnerStorageError.machineStorageRemains(runner: linuxID.value, path: linuxBundle.path)) { try linux.destroy(linuxID) }
    container.listed = true
    container.removeBundle = true
    try linux.destroy(linuxID)
    #expect(container.deleteCount == 2)
    #expect(!FileManager.default.fileExists(atPath: linuxBundle.path))

    let id = RunnerID(value: "yieldd-disk-full")
    let clones = try MacOSRunnerCloneStore(stateDirectory: leases.directory)
    let clone = try clones.bundleURL(for: id)
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: false)
    let disk = clone.appendingPathComponent("Disk.img")
    let fd = Darwin.open(disk.path, O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0o600)
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    var written = 0
    var writeError: Int32 = 0
    let block = Data(repeating: 0xA5, count: 1_024 * 1_024)
    while written < 128 * 1_024 * 1_024 {
        let count = block.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if count < 0 { writeError = errno; break }
        guard count > 0 else { break }
        written += count
    }
    _ = Darwin.close(fd)
    #expect(writeError == ENOSPC || writeError == EDQUOT)
    #expect(written < 64 * 1_024 * 1_024)

    let lease = try RunnerLease(runnerID: id, repository: GitHubRepository("owner/repo"), platform: .macOS)
    try leases.save(lease)
    #expect(try leases.load() == [lease])
    try clones.remove(id)
    #expect(!FileManager.default.fileExists(atPath: clone.path))
    try leases.clear(id)
    #expect(try leases.load().isEmpty)

    _ = try run("/usr/bin/hdiutil", ["detach", base.path])
    mounted = false
    #expect(throws: (any Error).self) { try MacOSRunnerCloneStore(stateDirectory: leases.directory).remove(id) }
    #expect(!FileManager.default.fileExists(atPath: volume.path))
}

private final class StorageContainerExecutor: ProcessExecuting {
    let storage: RunnerStorage
    let id: RunnerID
    var listed = true
    var removeBundle = false
    var deleteCount = 0
    var startArguments: [String]?

    init(storage: RunnerStorage, id: RunnerID) { self.storage = storage; self.id = id }

    func execute(_ request: ProcessRequest) throws -> ProcessResult {
        if request.executableURL.path == "/usr/sbin/diskutil" { return try ProcessExecutor().execute(request) }
        switch Array(request.arguments.prefix(2)) {
        case ["system", "start"]:
            startArguments = request.arguments
            return processResult()
        case ["system", "status"]:
            return processResult(stdout: "{\"status\":\"running\",\"appRoot\":\"\(storage.containerURL.path)\"}")
        case ["machine", "list"]:
            return processResult(stdout: listed ? id.value : "")
        case ["machine", "delete"]:
            deleteCount += 1
            if removeBundle {
                try FileManager.default.removeItem(at: storage.containerURL
                    .appendingPathComponent("plugin-state/machine-apiserver/machines/\(id.value)"))
            }
            return processResult()
        default: throw TestFailure.unexpectedProcessRequest
        }
    }
}
