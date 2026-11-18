import Darwin
import Foundation
import Testing
@testable import Yieldd

@Test func archiveServiceRecoversWithoutAWorkerPoll() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage = root.appendingPathComponent("storage")
    try RunnerNetworkDirectories.createPrivateDirectory(root)
    try RunnerNetworkDirectories.createPrivateDirectory(storage)
    let volume = ArchiveCacheVolume(directory: storage, mount: ArchiveCacheVolume.mountPoint(in: root),
                                    maximumMiB: 128, ownershipDescriptor: nil)
    let executable = root.appendingPathComponent("helper")
    let script = #"""
    #!/bin/sh
    if [ -f "$YIELDD_CACHE_SOCKET.fail-once" ]; then
        /bin/rm "$YIELDD_CACHE_SOCKET.fail-once"
        exit 1
    fi
    echo "$$" >> "$YIELDD_CACHE_SOCKET.starts"
    exec /usr/bin/nc -lU "$YIELDD_CACHE_SOCKET"
    """#
    try Data(script.utf8).write(to: executable)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let service = try ArchiveCacheService(stateDirectory: root, policy: Data("{}".utf8), stop: RunnerPoolStop(),
                                          executable: executable, volumeForLaunch: { volume })
    defer {
        service.stop()
        if (try? volume.detach()) != nil { try? manager.removeItem(at: root) }
        try? manager.removeItem(at: service.socketURL.deletingLastPathComponent())
    }
    try service.ensureRunning()
    let starts = service.socketURL.appendingPathExtension("starts")
    func launches() throws -> [pid_t] {
        try String(contentsOf: starts, encoding: .utf8).split(separator: "\n").compactMap { pid_t($0) }
    }
    let first = try #require(launches().first)
    try Data().write(to: service.socketURL.appendingPathExtension("fail-once"))
    try #require(kill(first, SIGKILL) == 0)

    // Busy and paused pools never call prepareToPoll. Even the first failed restart
    // must schedule another attempt without admitting a job or inspecting the helper.
    let deadline = DispatchTime.now() + 30
    while try launches().count < 2, DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    let restarted = try launches()
    try #require(restarted.count == 2)
    #expect(restarted[0] != restarted[1])
    service.stop()
    #expect(throws: CancellationError.self) { try service.ensureRunning() }
    #expect(!manager.fileExists(atPath: service.socketURL.path))
    #expect(kill(restarted[1], 0) < 0 && errno == ESRCH)
    #expect(!manager.fileExists(atPath: volume.mount.appendingPathComponent("store").path))
}
