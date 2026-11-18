import Darwin
import Foundation

// One SQLite store per enrolled Mac. Workers share the helper and each give their VM
// its own authenticated route. No archive endpoint is bound to a host TCP interface.
final class ArchiveCacheService: @unchecked Sendable {
    let socketURL: URL
    private let storage: RunnerStorage
    private let stateDirectory: URL
    private let ownershipDescriptor: Int32?
    private var volume: ArchiveCacheVolume?
    private let policy: String
    private let lock = NSLock()
    private var child: Process?
    private var lifetime: Pipe?

    private init(storage: RunnerStorage, stateDirectory: URL, policy: Data, ownershipDescriptor: Int32?) throws {
        self.ownershipDescriptor = ownershipDescriptor
        self.storage = storage
        self.stateDirectory = stateDirectory
        guard let json = String(data: policy, encoding: .utf8), !json.utf8.contains(0) else {
            throw ArchiveCacheError.invalidPolicy
        }
        self.policy = json
        let root = try RunnerNetworkDirectories(stateDirectory: stateDirectory).rootURL
        try RunnerNetworkDirectories.createPrivateDirectory(root)
        socketURL = root.appendingPathComponent("archive.sock")
    }

    static func start(storage: RunnerStorage, stateDirectory: URL, policy: Data, ownershipDescriptor: Int32? = nil,
                      checkCancellation: () throws -> Void) throws -> ArchiveCacheService {
        let service = try ArchiveCacheService(storage: storage, stateDirectory: stateDirectory, policy: policy, ownershipDescriptor: ownershipDescriptor)
        try service.ensureRunning(checkCancellation: checkCancellation)
        return service
    }

    func ensureRunning(checkCancellation: () throws -> Void) throws {
        try lock.withLock {
            if child?.isRunning == true { return }
            stopLocked()
            try checkCancellation()
            // Recheck the volume on every launch, including after a helper crash.
            let storageVolume = try storage.validate(stateDirectory: stateDirectory)
            let root = storage.volumeURL.appendingPathComponent("job-caches")
            let archives = root.appendingPathComponent("archives")
            try storage.validatePath(archives)
            try RunnerNetworkDirectories.createPrivateDirectory(root)
            try RunnerNetworkDirectories.createPrivateDirectory(archives)
            let volume = ArchiveCacheVolume(directory: archives, mount: ArchiveCacheVolume.mountPoint(in: stateDirectory),
                                            maximumMiB: min(16 << 10, (storageVolume.quotaBytes / 8) >> 20),
                                            ownershipDescriptor: ownershipDescriptor)
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
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/yieldd-cache-server")
            process.currentDirectoryURL = mounted.directory
            process.environment = ["YIELDD_CACHE_POLICY": policy, "YIELDD_CACHE_SOCKET": socketURL.path,
                                   "API_BASE_URL": "http://192.168.127.1:7341", "CACHE_MAX_SIZE_BYTES": String(mounted.evictionBytes),
                                   "SQLITE_TMPDIR": mounted.directory.path, "TMPDIR": mounted.directory.path]
            process.standardInput = pipe
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
            try process.run()
            lifetime = pipe
            child = process
            try pipe.fileHandleForReading.close()
            let deadline = DispatchTime.now() + 30
            while process.isRunning {
                try checkCancellation()
                var info = stat()
                if lstat(socketURL.path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK { ready = true; return }
                guard DispatchTime.now() < deadline else { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            throw ArchiveCacheError.startupFailed
        }
    }

    func stop() { lock.withLock { stopLocked() } }

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
        let deadline = DispatchTime.now() + 2
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
