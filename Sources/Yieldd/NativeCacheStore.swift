import Darwin
import Foundation

struct NativeCacheDisk {
    let url: URL
    let isCold: Bool
    fileprivate let writable: String?
    fileprivate let previous: UUID?
    fileprivate let inode: ino_t
    fileprivate let device: dev_t
    fileprivate let size: off_t
}

struct NativeCacheStore {
    private struct Seed: Codable {
        let generation: UUID
        var lastUsed: Date
        let bytes: Int64
    }

    private struct Index: Codable {
        var seeds: [String: Seed] = [:]
        // A writer starting from an empty scope may save only until another job publishes there.
        // Track active jobs so evicting the new seed cannot make a stale writer current again.
        var emptyScopeWriters: [String: String] = [:]
    }

    private let directory: URL
    private let platform: RunnerPlatform
    private let validate: () throws -> Void
    private let diskBytes: Int64
    private let executor: any ProcessExecuting
    private let ownershipDescriptor: Int32?
    private let manager = FileManager.default
    private var seeds: URL { directory.appendingPathComponent("seeds") }
    private var jobs: URL { directory.appendingPathComponent("jobs") }
    private var index: URL { directory.appendingPathComponent("index.json") }

    init(root: URL, platform: RunnerPlatform, diskBytes: Int64 = 8 << 30,
         executor: any ProcessExecuting = ProcessExecutor(), ownershipDescriptor: Int32? = nil,
         validate: @escaping () throws -> Void = {}) {
        self.directory = root.appendingPathComponent(platform.rawValue)
        self.platform = platform
        self.diskBytes = diskBytes
        self.executor = executor
        self.ownershipDescriptor = ownershipDescriptor
        self.validate = validate
    }

    init(storage: RunnerStorage, platform: RunnerPlatform, executor: any ProcessExecuting, ownershipDescriptor: Int32?) throws {
        let root = storage.volumeURL.appendingPathComponent("job-caches/native")
        let device = try RunnerStorage.device(at: storage.volumeURL)
        self.init(root: root, platform: platform, executor: executor, ownershipDescriptor: ownershipDescriptor) {
            guard try RunnerStorage.device(at: storage.volumeURL) == device else {
                throw RunnerStorageError.volumeUnavailable(path: storage.volumePath)
            }
            try storage.validatePath(root)
        }
    }

    private func jobPath(_ id: RunnerID) throws -> URL {
        guard id.isValid else { throw RunnerLeaseError.invalidRunnerID(path: jobs.path) }
        return jobs.appendingPathComponent(id.value)
    }

    private func jobDirectory(_ id: RunnerID) throws -> URL {
        try validate()
        let job = try jobPath(id)
        try privateDirectory(directory)
        try privateDirectory(jobs)
        guard mkdir(job.path, 0o700) == 0 else {
            if errno == EEXIST { throw JobCacheError.alreadyOpened }
            throw lastError()
        }
        return job
    }

    func open(_ id: RunnerID, readable: [String], writable: String?) throws -> NativeCacheDisk {
        let scopes = readable + [writable].compactMap { $0 }
        guard !scopes.isEmpty, scopes.count <= 128, scopes.allSatisfy(Self.validScope) else {
            throw JobCacheError.invalidScope
        }
        let job = try jobDirectory(id)
        let image = job.appendingPathComponent("cache.img")
        let (cold, previous) = try withLock {
            var catalog = try readIndex()
            let sourceScope = readable.first { catalog.seeds[$0] != nil }
            if let sourceScope, let seed = catalog.seeds[sourceScope] {
                let source = seedFile(seed.generation)
                guard clonefile(source.path, image.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
                    throw lastError()
                }
                // Eviction tolerates a lost timestamp; a hit needs no journal write.
                _ = utimensat(AT_FDCWD, source.path, nil, AT_SYMLINK_NOFOLLOW)
            }
            let previous = writable.flatMap { catalog.seeds[$0]?.generation }
            if let writable, previous == nil {
                catalog.emptyScopeWriters[id.value] = writable
                try save(catalog)
            }
            return (sourceScope == nil, previous)
        }
        if cold { try createBlank(at: image) }
        var info = stat()
        guard lstat(image.path, &info) == 0 else { throw lastError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == diskBytes else {
            throw JobCacheError.invalidDisk
        }
        return NativeCacheDisk(url: image, isCold: cold, writable: writable, previous: previous,
                               inode: info.st_ino, device: info.st_dev, size: info.st_size)
    }

    func discard(_ id: RunnerID) throws {
        try validate()
        let job = try jobPath(id)
        // Release disk space before replacing the catalog, including when a full volume caused cleanup.
        do { try manager.removeItem(at: job) } catch CocoaError.fileNoSuchFile {}
        var info = stat()
        if lstat(index.path, &info) == 0 {
            try withLock {
                var catalog = try readIndex()
                if catalog.emptyScopeWriters.removeValue(forKey: id.value) != nil {
                    try save(catalog)
                }
            }
        } else if errno != ENOENT { throw lastError() }
    }

    // Recovery only discards. Publishing requires the original live checkout and an unchanged base.
    func publish(_ disk: NativeCacheDisk) throws {
        try validate()
        guard let target = disk.writable else { return }
        let job = disk.url.deletingLastPathComponent()
        guard job.deletingLastPathComponent().path == jobs.path else {
            throw JobCacheError.invalidDisk
        }
        try withLock {
            var catalog = try readIndex()
            let previous = Set(catalog.seeds.values.map(\.generation))
            try reapSeeds(keeping: previous)
            guard catalog.seeds[target]?.generation == disk.previous else { return }
            if disk.previous == nil, catalog.emptyScopeWriters[job.lastPathComponent] != target { return }
            let fd = Darwin.open(disk.url.path, O_NOFOLLOW | O_NONBLOCK | O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw lastError() }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw lastError() }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_dev == disk.device,
                  info.st_ino == disk.inode, info.st_size == disk.size else { throw JobCacheError.invalidDisk }
            let generation = UUID()
            let file = seedFile(generation)
            guard fclonefileat(fd, AT_FDCWD, file.path, UInt32(CLONE_NOOWNERCOPY)) == 0 else { throw lastError() }
            let newSeed = try FileHandle(forWritingTo: file)
            defer { try? newSeed.close() }
            try newSeed.synchronize()
            try synchronizeRunnerState(seeds)
            // Commit the index last. An interrupted save leaves the previous seed readable.
            catalog.emptyScopeWriters = catalog.emptyScopeWriters.filter { $0.value != target }
            catalog.seeds[target] = Seed(generation: generation, lastUsed: Date(), bytes: info.st_blocks * 512)
            if catalog.seeds.count > 16 || catalog.seeds.values.reduce(Int64(0), { $0 + $1.bytes }) > 16 << 30 {
                let candidates = catalog.seeds.mapValues { seed in
                    var seed = seed
                    let file = seedFile(seed.generation)
                    if let touched = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                        seed.lastUsed = max(touched, seed.lastUsed)
                    }
                    return seed
                }
                catalog.seeds.removeAll(keepingCapacity: true)
                var bytes: Int64 = 0
                for (scope, seed) in candidates.sorted(by: { $0.value.lastUsed > $1.value.lastUsed }) {
                    guard catalog.seeds.count < 16, bytes + seed.bytes <= 16 << 30 else { break }
                    bytes += seed.bytes
                    catalog.seeds[scope] = seed
                }
            }
            try save(catalog)
            let removed = previous.union([generation]).subtracting(catalog.seeds.values.map(\.generation))
            for id in removed { try manager.removeItem(at: seedFile(id)) }
        }
    }

    private func createBlank(at url: URL) throws {
        if platform == .macOS {
            let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
                arguments: ["image", "create", "blank", "--format", "RAW", "--size", String(diskBytes),
                            "--volumeName", "YielddCache", url.path], timeout: 60, outputCapture: .tail(maxBytes: 4096),
                ownershipDescriptor: ownershipDescriptor)
            _ = try executor.execute(request).requireSuccess(for: request)
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

    private func readIndex() throws -> Index {
        guard let data = try readPrivateRunnerFile(index, maximumBytes: 64 * 1024) else { return Index() }
        return try JSONDecoder().decode(Index.self, from: data)
    }

    private func save(_ catalog: Index) throws {
        try writePrivateRunnerFile(JSONEncoder().encode(catalog), to: index)
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

enum JobCacheError: LocalizedError {
    case invalidScope, invalidDisk, invalidStore, alreadyOpened

    var errorDescription: String? {
        switch self {
        case .invalidScope: "The cache service returned an invalid scope."
        case .invalidDisk: "The job's cache disk changed identity or size. Its contents were discarded."
        case .invalidStore: "The native cache store contains an invalid file or directory."
        case .alreadyOpened: "This job already opened a native cache disk."
        }
    }
}
