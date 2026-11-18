import Darwin
import Foundation
import Testing
@testable import Yieldd

@Test func archiveVolumeBoundsConcurrentUnfinishedWritesAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try RunnerNetworkDirectories.createPrivateDirectory(root)
    let volume = ArchiveCacheVolume(directory: root, mount: ArchiveCacheVolume.mountPoint(in: root), maximumMiB: 128, ownershipDescriptor: nil)
    defer {
        // Never remove a fixture until its mount is gone.
        if (try? volume.detach()) != nil { try? FileManager.default.removeItem(at: root) }
    }
    let store = try volume.open()
    let reduced = ArchiveCacheVolume(directory: root, mount: volume.mount, maximumMiB: 32, ownershipDescriptor: nil)
    do {
        _ = try reduced.open()
        Issue.record("The archive disk exceeded the reduced quota")
    } catch {
        #expect(error.localizedDescription.contains("32 MiB allowance"))
    }
    let published = store.directory.appendingPathComponent("published")
    try Data("keep".utf8).write(to: published)
    var stats = statfs()
    #expect(statfs(store.directory.path, &stats) == 0)
    let capacity = UInt64(stats.f_bsize) * stats.f_blocks
    let available = UInt64(stats.f_bsize) * stats.f_bavail
    #expect(store.evictionBytes > 0)
    #expect(2 * store.evictionBytes + min(capacity / 8, 64 << 20) < available)

    let paths = ["upload.pending", "merge.pending"].map { store.directory.appendingPathComponent($0) }
    let bytes = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
        for path in paths { group.addTask { try fillArchiveVolume(path, bytes: 96 << 20) } }
        var total = 0
        for try await written in group { total += written }
        return total
    }
    #expect(bytes > 96 << 20)
    #expect(bytes <= 128 << 20)
    // A new owner adopts an interrupted mount with its unfinished bytes still charged.
    let recovered = try ArchiveCacheVolume(directory: root, mount: ArchiveCacheVolume.mountPoint(in: root), maximumMiB: 128, ownershipDescriptor: nil).open()
    #expect(recovered.directory == store.directory)
    #expect(recovered.evictionBytes == store.evictionBytes)
    #expect(try String(contentsOf: published, encoding: .utf8) == "keep")
    try volume.detach()
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    let reopened = try volume.open()
    #expect(reopened.evictionBytes == store.evictionBytes)
    #expect(try paths.allSatisfy { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize != nil })
    for path in paths { try FileManager.default.removeItem(at: path) }
    #expect(try fillArchiveVolume(reopened.directory.appendingPathComponent("next"), bytes: 1 << 20) == 1 << 20)
}

@Test func archiveVolumePreservesUnexpectedMountContentsOnFailedAttach() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let mount = ArchiveCacheVolume.mountPoint(in: root)
    try RunnerNetworkDirectories.createPrivateDirectory(root)
    let volume = ArchiveCacheVolume(directory: root, mount: ArchiveCacheVolume.mountPoint(in: root), maximumMiB: 128, ownershipDescriptor: nil)
    defer {
        if (try? volume.detach()) != nil { try? FileManager.default.removeItem(at: root) }
    }
    try RunnerNetworkDirectories.createPrivateDirectory(mount)
    let marker = mount.appendingPathComponent("existing")
    try Data("keep".utf8).write(to: marker)
    #expect(throws: (any Error).self) { try volume.open() }
    try volume.detach()
    #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    #expect(!FileManager.default.fileExists(atPath: mount.appendingPathComponent("store").path))
    try FileManager.default.removeItem(at: marker)
    _ = try volume.open()
}

@Test func archiveVolumeCleanupHonorsTheRemainingShutdownDeadline() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try RunnerNetworkDirectories.createPrivateDirectory(root)
    let volume = ArchiveCacheVolume(directory: root, mount: ArchiveCacheVolume.mountPoint(in: root),
                                    maximumMiB: 128, ownershipDescriptor: nil)
    defer {
        if (try? volume.detach()) != nil { try? FileManager.default.removeItem(at: root) }
    }
    let store = try volume.open()
    let stop = RunnerPoolStop()
    stop.request()
    var stopping = volume
    stopping.executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: { .now() })
    do {
        try stopping.detach()
        Issue.record("An expired shutdown deadline allowed a disk command to start")
    } catch let ProcessExecutionError.executionDeadlineExceeded(request, nil) {
        #expect(request.arguments == ["info", "-plist"])
        #expect(!request.cancellable)
    }
    #expect(FileManager.default.fileExists(atPath: store.directory.path))
    // A new owner can still adopt the mount. While time remains, a stop
    // request permits cleanup even though it cancels creation and attachment.
    _ = try volume.open()
    stopping.executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: { .now() + 5 })
    try stopping.detach()
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func standaloneRecoveryIdentifiesArchiveStorageFailure() throws {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try RunnerNetworkDirectories.createPrivateDirectory(state)
    defer { try? FileManager.default.removeItem(at: state) }
    try writePrivateRunnerFile(Data("invalid".utf8), to: state.appendingPathComponent("storage.json"))
    do {
        try removeUnleasedRunnerFiles(in: state, makeCloneStore: { kind in
            MacOSRunnerCloneStore(rootURL: state.appendingPathComponent(kind.rawValue))
        })
        Issue.record("Recovery succeeded with unreadable archive storage configuration")
    } catch let RunnerSessionError.cleanupFailed(failures) {
        #expect(failures.map(\.step) == [.archiveCache])
    }
}

private func fillArchiveVolume(_ file: URL, bytes: Int) throws -> Int {
    let fd = open(file.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    let chunk = [UInt8](repeating: 0xa3, count: 1 << 20)
    return try chunk.withUnsafeBytes { data in
        var written = 0
        while written < bytes {
            let count = Darwin.write(fd, data.baseAddress, min(bytes - written, data.count))
            if count < 0 {
                if errno == ENOSPC { return written }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else { throw POSIXError(.EIO) }
            written += count
        }
        return written
    }
}
