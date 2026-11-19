import Darwin
import Foundation

func loadJobCachePolicy(in directory: URL) throws -> Data? {
    try readPrivateRunnerFile(directory.appendingPathComponent("job-caches.json"), maximumBytes: 64 * 1024)
}

// One SQLite store per enrolled Mac. Workers share the helper and each give their VM
// its own authenticated route. No archive endpoint is bound to a host TCP interface.
final class ArchiveCacheService: @unchecked Sendable {
    let socketURL: URL
    private let shutdown: RunnerPoolStop
    private let executable: URL
    private let volumeForLaunch: () throws -> ArchiveCacheVolume
    private var volume: ArchiveCacheVolume?
    private let policy: String
    private let lock = NSLock()
    private var child: Process?
    private var lifetime: Pipe?
    private var stopped = false
    private var restartScheduled = false
    private var restartDelay = 1
    private var readySince = DispatchTime.now()

    init(stateDirectory: URL, policy: Data, stop: RunnerPoolStop, executable: URL,
         volumeForLaunch: @escaping () throws -> ArchiveCacheVolume) throws {
        self.shutdown = stop
        self.executable = executable
        self.volumeForLaunch = volumeForLaunch
        guard let json = String(data: policy, encoding: .utf8), !json.utf8.contains(0) else {
            throw ArchiveCacheError.invalidPolicy
        }
        self.policy = json
        let root = try RunnerNetworkDirectories(stateDirectory: stateDirectory).rootURL
        try RunnerNetworkDirectories.createPrivateDirectory(root)
        socketURL = root.appendingPathComponent("archive.sock")
    }

    static func start(storage: RunnerStorage, stateDirectory: URL, policy: Data, ownershipDescriptor: Int32? = nil,
                      stop: RunnerPoolStop) throws -> ArchiveCacheService {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/yieldd-cache-server")
        let service = try ArchiveCacheService(stateDirectory: stateDirectory, policy: policy, stop: stop, executable: executable) {
            // Recheck the volume on every launch, including after a helper crash.
            let executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
            let storageVolume = try storage.validate(stateDirectory: stateDirectory, executor: executor)
            let root = storage.volumeURL.appendingPathComponent("job-caches")
            let archives = root.appendingPathComponent("archives")
            try storage.validatePath(archives)
            try RunnerNetworkDirectories.createPrivateDirectory(root)
            try RunnerNetworkDirectories.createPrivateDirectory(archives)
            return ArchiveCacheVolume(directory: archives, mount: ArchiveCacheVolume.mountPoint(in: stateDirectory),
                                      maximumMiB: min(16 << 10, (storageVolume.quotaBytes / 8) >> 20),
                                      ownershipDescriptor: ownershipDescriptor, executor: executor)
        }
        try service.ensureRunning()
        return service
    }

    func ensureRunning() throws {
        try lock.withLock {
            try shutdown.check()
            guard !stopped else { throw CancellationError() }
            if let child {
                guard child.isRunning else { throw ArchiveCacheError.startupFailed }
                return
            }
            guard !restartScheduled else { throw ArchiveCacheError.startupFailed }
            try launchLocked()
        }
    }

    private func launchLocked() throws {
        stopLocked()
        try shutdown.check()
        let volume = try volumeForLaunch()
        self.volume = volume
        var ready = false
        defer { if !ready { stopLocked() } }
        let mounted = try volume.open()
        try removeSocket()
        let process = Process()
        let pipe = Pipe()
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        process.executableURL = executable
        process.currentDirectoryURL = mounted.directory
        process.environment = ["YIELDD_CACHE_POLICY": policy, "YIELDD_CACHE_SOCKET": socketURL.path,
                               "API_BASE_URL": "http://192.168.127.1:7341", "CACHE_MAX_SIZE_BYTES": String(mounted.evictionBytes),
                               "MAX_CONCURRENT_MERGES": "0", "SQLITE_TMPDIR": mounted.directory.path, "TMPDIR": mounted.directory.path]
        process.standardInput = pipe
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] exited in
            // stopLocked() may be waiting for Foundation to finish reaping this process.
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.didExit(exited) }
        }
        try process.run()
        lifetime = pipe
        child = process
        try pipe.fileHandleForReading.close()
        let deadline = DispatchTime.now() + 30
        while process.isRunning {
            try shutdown.check()
            var info = stat()
            if lstat(socketURL.path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK {
                ready = true
                readySince = .now()
                return
            }
            guard DispatchTime.now() < deadline else { break }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw ArchiveCacheError.startupFailed
    }

    private func didExit(_ exited: Process) {
        lock.withLock {
            guard child === exited else { return }
            if DispatchTime.now() >= readySince + 30 { restartDelay = 1 }
            scheduleRestartLocked()
        }
    }

    private func scheduleRestartLocked() {
        guard !stopped, !restartScheduled, (try? shutdown.check()) != nil else { return }
        restartScheduled = true
        let delay = restartDelay
        restartDelay = min(30, delay * 2)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            self?.restart()
        }
    }

    private func restart() {
        lock.withLock {
            restartScheduled = false
            guard !stopped, (try? shutdown.check()) != nil, child?.isRunning != true else { return }
            do { try launchLocked() } catch {
                guard (try? shutdown.check()) != nil else { return }
                FileHandle.standardError.write(Data("Archive service restart failed: \(describeError(error))\n".utf8))
                scheduleRestartLocked()
            }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            stopLocked()
        }
    }

    private func stopLocked() {
        defer {
            if let volume {
                do { try volume.detach() }
                catch { FileHandle.standardError.write(Data("Archive disk remains attached: \(describeError(error))\n".utf8)) }
                self.volume = nil
            }
        }
        guard let child else { return }
        if child.isRunning { child.terminate() }
        // Let ordinary shutdown finish database work. Owner EOF also stops the helper
        // after an uncatchable exit, or if an HTTP transfer is still outstanding.
        let deadline = min(DispatchTime.now() + 2, shutdown.executionDeadline() ?? .distantFuture)
        while child.isRunning && DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        try? lifetime?.fileHandleForWriting.close()
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        self.child = nil
        lifetime = nil
        try? removeSocket()
    }

    // An uncatchable termination can leave the Unix socket in its private parent.
    private func removeSocket() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw POSIXError(.EACCES) }
        guard unlink(socketURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { stop() }
}

private enum ArchiveCacheError: LocalizedError {
    case startupFailed, invalidPolicy
    var errorDescription: String? {
        switch self {
        case .startupFailed: "The local archive service could not open its cache. Check the agent log."
        case .invalidPolicy: "The job cache configuration must contain UTF-8 JSON."
        }
    }
}
