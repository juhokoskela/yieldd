import Darwin
import Foundation

struct NativeCacheDisk {
    let url: URL
    let isCold: Bool
}

struct NativeCacheStore {
    private struct Seed: Codable {
        let generation: UUID
        var lastUsed: Date
        let bytes: Int64
    }

    // Only the original image can replace the generation the job saw when it started.
    private struct Checkout: Codable {
        let writable: String?
        let previous: UUID?
        let inode: ino_t
        let device: dev_t
        let size: off_t
    }

    private let directory: URL
    private let platform: RunnerPlatform
    private let validate: () throws -> Void
    private let diskBytes: Int64
    private let manager = FileManager.default
    private var seeds: URL { directory.appendingPathComponent("seeds") }
    private var jobs: URL { directory.appendingPathComponent("jobs") }
    private var index: URL { directory.appendingPathComponent("index.json") }

    init(root: URL, platform: RunnerPlatform, diskBytes: Int64 = 8 << 30,
         validate: @escaping () throws -> Void = {}) {
        self.directory = root.appendingPathComponent(platform.rawValue)
        self.platform = platform
        self.diskBytes = diskBytes
        self.validate = validate
    }

    init(storage: RunnerStorage, platform: RunnerPlatform) throws {
        let root = storage.volumeURL.appendingPathComponent("job-caches/native")
        let device = try RunnerStorage.device(at: storage.volumeURL)
        self.init(root: root, platform: platform) {
            guard try RunnerStorage.device(at: storage.volumeURL) == device else {
                throw RunnerStorageError.volumeUnavailable(path: storage.volumePath)
            }
            try storage.validatePath(root)
        }
    }

    static func recover(in directory: URL, platform: RunnerPlatform, id: RunnerID) throws {
        guard let storage = try RunnerStorage.load(in: directory) else { return }
        let path = storage.volumeURL.appendingPathComponent("job-caches/native")
        // Validate the mounted volume before treating absence as a successful cleanup.
        _ = try storage.validate(stateDirectory: directory)
        try storage.validatePath(path)
        try Self(root: path, platform: platform).finish(id, publish: false)
    }

    private func jobPath(_ id: RunnerID) throws -> URL {
        guard id.isValid else { throw RunnerLeaseError.invalidRunnerID(path: jobs.path) }
        return jobs.appendingPathComponent(id.value)
    }

    @discardableResult
    func jobDirectory(_ id: RunnerID) throws -> URL {
        try validate()
        let job = try jobPath(id)
        for url in [directory, jobs, job] {
            try privateDirectory(url)
        }
        return job
    }

    func open(_ id: RunnerID, readable: [String], writable: String?) throws -> NativeCacheDisk {
        let scopes = readable + [writable].compactMap { $0 }
        guard !scopes.isEmpty, scopes.count <= 128, scopes.allSatisfy(Self.validScope) else {
            throw JobCacheError.invalidScope
        }
        let job = try jobDirectory(id)
        let record = job.appendingPathComponent("checkout.json")
        guard try readPrivateRunnerFile(record, maximumBytes: 2048) == nil else { throw JobCacheError.alreadyOpened }
        let staging = job.appendingPathComponent(UUID().uuidString + ".raw")
        defer { try? manager.removeItem(at: staging) }
        let (cold, previous) = try withLock {
            var entries = try readIndex()
            try reapSeeds(keeping: Set(entries.values.map(\.generation)))
            let sourceScope = readable.first { entries[$0] != nil }
            if let sourceScope, var seed = entries[sourceScope] {
                let source = seedFile(seed.generation)
                guard clonefile(source.path, staging.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
                    throw lastError()
                }
                seed.lastUsed = Date()
                entries[sourceScope] = seed
                try writePrivateRunnerFile(JSONEncoder().encode(entries), to: index)
            }
            return (sourceScope == nil, writable.flatMap { entries[$0]?.generation })
        }
        if cold { try createBlank(at: staging) }
        var info = stat()
        guard lstat(staging.path, &info) == 0 else { throw lastError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == diskBytes else {
            throw JobCacheError.invalidDisk
        }
        let checkout = Checkout(writable: writable, previous: previous, inode: info.st_ino, device: info.st_dev, size: info.st_size)
        try writePrivateRunnerFile(JSONEncoder().encode(checkout), to: record)
        let image = job.appendingPathComponent("cache.img")
        guard renamex_np(staging.path, image.path, UInt32(RENAME_EXCL)) == 0 else { throw lastError() }
        return NativeCacheDisk(url: image, isCold: cold)
    }

    func finish(_ id: RunnerID, publish: Bool) throws {
        try validate()
        let job = try jobPath(id)
        // Always remove the checkout on discard, stale writers, or failed publication.
        var publishError: Error?
        if publish {
            do { try publishCheckout(in: job) } catch { publishError = error }
        }
        do { try manager.removeItem(at: job) } catch CocoaError.fileNoSuchFile {}
        if let publishError { throw publishError }
    }

    private func publishCheckout(in job: URL) throws {
        guard let data = try readPrivateRunnerFile(job.appendingPathComponent("checkout.json"), maximumBytes: 2048) else { return }
        let checkout = try JSONDecoder().decode(Checkout.self, from: data)
        guard let target = checkout.writable else { return }
        guard Self.validScope(target) else { throw JobCacheError.invalidScope }
        try withLock {
            var entries = try readIndex()
            guard entries[target]?.generation == checkout.previous else { return }
            let image = job.appendingPathComponent("cache.img")
            let fd = Darwin.open(image.path, O_NOFOLLOW | O_NONBLOCK | O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw lastError() }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw lastError() }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_dev == checkout.device,
                  info.st_ino == checkout.inode, info.st_size == checkout.size else { throw JobCacheError.invalidDisk }
            let generation = UUID()
            let file = seedFile(generation)
            guard fclonefileat(fd, AT_FDCWD, file.path, UInt32(CLONE_NOOWNERCOPY)) == 0 else { throw lastError() }
            let newSeed = try FileHandle(forWritingTo: file)
            defer { try? newSeed.close() }
            try newSeed.synchronize()
            try synchronizeRunnerState(seeds)
            // Commit the index last. An interrupted save leaves the previous seed readable.
            entries[target] = Seed(generation: generation, lastUsed: Date(), bytes: info.st_blocks * 512)
            var retained: [String: Seed] = [:]
            var bytes: Int64 = 0
            for (scope, seed) in entries.sorted(by: { $0.value.lastUsed > $1.value.lastUsed }) {
                guard retained.count < 16, bytes + seed.bytes <= 16 << 30 else { continue }
                bytes += seed.bytes
                retained[scope] = seed
            }
            try writePrivateRunnerFile(JSONEncoder().encode(retained), to: index)
            try reapSeeds(keeping: Set(retained.values.map(\.generation)))
        }
    }

    private func createBlank(at url: URL) throws {
        if platform == .macOS {
            let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
                arguments: ["image", "create", "blank", "--format", "RAW", "--size", String(diskBytes),
                            "--volumeName", "YielddCache", url.path], timeout: 60, outputCapture: .tail(maxBytes: 4096))
            _ = try ProcessExecutor().execute(request).requireSuccess(for: request)
        } else {
            let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw lastError() }
            defer { close(fd) }
            guard ftruncate(fd, diskBytes) == 0 else { throw lastError() }
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try privateDirectory(seeds)
        let fd = Darwin.open(directory.appendingPathComponent("store.lock").path,
                             O_NOFOLLOW | O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK, 0o600)
        guard fd >= 0 else { throw lastError() }
        defer { close(fd) }
        return try body()
    }

    private func privateDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { throw JobCacheError.invalidStore }
    }

    private static func validScope(_ scope: String) -> Bool {
        scope.utf8.count == 64 && scope.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func seedFile(_ id: UUID) -> URL { seeds.appendingPathComponent(id.uuidString + ".img") }

    private func readIndex() throws -> [String: Seed] {
        guard let data = try readPrivateRunnerFile(index, maximumBytes: 64 * 1024) else { return [:] }
        return try JSONDecoder().decode([String: Seed].self, from: data)
    }

    private func reapSeeds(keeping generations: Set<UUID>) throws {
        for file in try manager.contentsOfDirectory(at: seeds, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "img", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !generations.contains(id) else { continue }
            try manager.removeItem(at: file)
        }
    }

    private func lastError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
