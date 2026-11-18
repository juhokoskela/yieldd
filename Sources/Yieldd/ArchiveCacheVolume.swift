import Darwin
import Foundation

// SQLite, pending multipart uploads, and published archives all live
// on this filesystem. The kernel enforces one limit across simultaneous requests.
struct ArchiveCacheVolume {
    let directory: URL
    let mount: URL
    let maximumMiB: UInt64
    let ownershipDescriptor: Int32?
    var executor = ProcessExecutor()
    private var image: URL { directory.appendingPathComponent("archives.sparseimage") }

    struct Store {
        let directory: URL
        let evictionBytes: UInt64
    }

    func open() throws -> Store {
        let manager = FileManager.default
        let contents = Set(try manager.contentsOfDirectory(atPath: directory.path))
        if contents.contains("creating.sparseimage") {
            // The owner lock is inherited by hdiutil. Recovery cannot race an old create.
            guard unlink(directory.appendingPathComponent("creating.sparseimage").path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        if !contents.contains("archives.sparseimage") {
            let free = try filesystemSize(directory, available: true)
            let size = min(maximumMiB, (free / 4) >> 20)
            guard size >= 128 else { throw VolumeError.insufficientSpace }
            let staging = directory.appendingPathComponent("creating.sparseimage")
            try run(["create", "-quiet", "-fs", "APFS", "-type", "SPARSE", "-size", "\(size)m",
                     "-volname", "yieldd archives", staging.path])
            try manager.moveItem(at: staging, to: image)
            try synchronizeRunnerState(directory)
        }
        var info = stat()
        guard lstat(image.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw VolumeError.wrongImage }
        if try !attached() {
            try RunnerNetworkDirectories.createPrivateDirectory(mount)
            guard try device(mount) == device(mount.deletingLastPathComponent()),
                  try manager.contentsOfDirectory(atPath: mount.path).isEmpty else { throw VolumeError.wrongImage }
            try run(["attach", "-quiet", "-nobrowse", "-owners", "off", "-mountpoint", mount.path, image.path])
            guard try attached() else { throw VolumeError.wrongImage }
        }
        guard try device(mount) != device(mount.deletingLastPathComponent()) else { throw VolumeError.wrongImage }
        let size = try filesystemSize(mount, available: false)
        guard size <= maximumMiB << 20 else { throw VolumeError.quotaReduced(maximumMiB) }
        // The bare mount point is kept empty. Losing the mount before spawn makes the
        // requested working directory disappear, so the helper cannot write to its parent.
        let store = mount.appendingPathComponent("store", isDirectory: true)
        try RunnerNetworkDirectories.createPrivateDirectory(store)
        return Store(directory: store, evictionBytes: size / 2)
    }

    // User-owned agent state supports unprivileged mounts even when ownership
    // is disabled on the volume containing the sparse image.
    static func mountPoint(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("archive-volume", isDirectory: true)
    }

    static func recover(in stateDirectory: URL, ownershipDescriptor: Int32?, executor: ProcessExecutor) throws {
        guard let storage = try RunnerStorage.load(in: stateDirectory) else { return }
        let directory = storage.volumeURL.appendingPathComponent("job-caches/archives")
        let volume = ArchiveCacheVolume(directory: directory, mount: mountPoint(in: stateDirectory),
                                        maximumMiB: 0, ownershipDescriptor: ownershipDescriptor, executor: executor)
        var info = stat()
        guard lstat(volume.image.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = try storage.validate(stateDirectory: stateDirectory, executor: executor)
        try storage.validatePath(volume.image)
        try volume.detach()
    }

    func detach() throws {
        if try attached(cancellable: false) {
            try run(["detach", "-quiet", mount.path], cancellable: false)
        }
    }

    private func attached(cancellable: Bool = true) throws -> Bool {
        // hdiutil reports hyphenated plist keys. Ignore other disk images on the Mac.
        let plist = try PropertyListSerialization.propertyList(from: run(["info", "-plist"], cancellable: cancellable), format: nil)
        guard let images = (plist as? [String: Any])?["images"] as? [[String: Any]] else { throw VolumeError.wrongImage }
        let expected = image.resolvingSymlinksInPath().path
        let matches = images.filter { item in
            guard let path = item["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected
        }
        guard !matches.isEmpty else { return false }
        let mounts = (matches.first?["system-entities"] as? [[String: Any]])?.compactMap { entity in
            (entity["mount-point"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
        guard matches.count == 1, mounts == [mount.resolvingSymlinksInPath().path] else { throw VolumeError.wrongImage }
        return true
    }

    @discardableResult
    private func run(_ arguments: [String], cancellable: Bool = true) throws -> Data {
        let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: arguments, timeout: 90, cancellable: cancellable, ownershipDescriptor: ownershipDescriptor)
        return try executor.execute(request).requireSuccess(for: request).stdout
    }

    private func device(_ url: URL) throws -> dev_t {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw VolumeError.wrongImage }
        return value.st_dev
    }

    private func filesystemSize(_ url: URL, available: Bool) throws -> UInt64 {
        var value = statfs()
        guard statfs(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt64(value.f_bsize) * (available ? value.f_bavail : value.f_blocks)
    }

    private enum VolumeError: LocalizedError {
        case insufficientSpace, wrongImage, quotaReduced(UInt64)
        var errorDescription: String? {
            switch self {
            case .insufficientSpace: "Runner storage needs more free space to create the archive disk."
            case let .quotaReduced(limit): "The archive disk exceeds the current \(limit) MiB allowance. Restore the previous runner quota or reset the archive store."
            case .wrongImage: "The archive disk or its private mount point does not match the configured store."
            }
        }
    }
}
