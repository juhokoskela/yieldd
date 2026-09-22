import Darwin
import Foundation

struct RunnerLease: Equatable, Sendable {
    let runnerID: RunnerID
    let repository: GitHubRepository
    let platform: RunnerPlatform

    init(runnerID: RunnerID, repository: GitHubRepository, platform: RunnerPlatform = .linux) {
        self.runnerID = runnerID
        self.repository = repository
        self.platform = platform
    }
}

// The lock serializes every read-modify-write operation on the shared lease file.
final class RunnerLeaseStore: @unchecked Sendable {
    static let maximumBytes = 8 * 1_024

    let directory: URL
    let fileURL: URL
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        fileURL = directory.appendingPathComponent("active-runner.json", isDirectory: false)
    }

    func load() throws -> [RunnerLease] {
        try lock.withLock {
            try loadUnlocked()
        }
    }

    func save(_ lease: RunnerLease) throws {
        try lock.withLock {
            guard lease.runnerID.isValid else {
                throw RunnerLeaseError.invalidRunnerID(path: fileURL.path)
            }
            var leases = try loadUnlocked()
            if let index = leases.firstIndex(where: { $0.runnerID == lease.runnerID }) {
                leases[index] = lease
            } else {
                leases.append(lease)
            }
            try writeUnlocked(leases)
        }
    }

    func clear(_ id: RunnerID) throws {
        try lock.withLock {
            var leases = try loadUnlocked()
            let previousCount = leases.count
            leases.removeAll(where: { $0.runnerID == id })
            guard leases.count != previousCount else {
                return
            }
            try writeUnlocked(leases)
        }
    }

    private func loadUnlocked() throws -> [RunnerLease] {
        let descriptor = fileURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let errorNumber = errno
            guard errorNumber == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
            }
            return []
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else {
            throw RunnerLeaseError.tooLarge(
                path: fileURL.path,
                maximumBytes: Self.maximumBytes
            )
        }

        let stored: [StoredRunnerLease]
        do {
            stored = try JSONDecoder().decode([StoredRunnerLease].self, from: data)
        } catch {
            throw RunnerLeaseError.invalidContents(path: fileURL.path)
        }

        let leases = try stored.map { storedLease in
            let runnerID = RunnerID(value: storedLease.runnerID)
            guard runnerID.isValid else {
                throw RunnerLeaseError.invalidRunnerID(path: fileURL.path)
            }
            guard let repository = try? GitHubRepository(storedLease.repository) else {
                throw RunnerLeaseError.invalidContents(path: fileURL.path)
            }
            return RunnerLease(
                runnerID: runnerID,
                repository: repository,
                platform: storedLease.platform
            )
        }
        guard Set(leases.map(\.runnerID)).count == leases.count else {
            throw RunnerLeaseError.invalidContents(path: fileURL.path)
        }
        return leases
    }

    private func writeUnlocked(_ leases: [RunnerLease]) throws {
        guard !leases.isEmpty else {
            guard fileURL.path.withCString(Darwin.unlink) == 0 else {
                let errorNumber = errno
                guard errorNumber == ENOENT else {
                    throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
                }
                return
            }
            return
        }

        let stored = leases
            .sorted { $0.runnerID.value < $1.runnerID.value }
            .map { lease in
                StoredRunnerLease(
                    runnerID: lease.runnerID.value,
                    repository: lease.repository.fullName,
                    platform: lease.platform
                )
            }
        let data = try JSONEncoder().encode(stored)
        guard data.count <= Self.maximumBytes else {
            throw RunnerLeaseError.tooLarge(
                path: fileURL.path,
                maximumBytes: Self.maximumBytes
            )
        }
        try data.write(to: fileURL, options: .atomic)
        try synchronizeRunnerState(fileURL)
        try synchronizeRunnerState(directory)
    }
}

func synchronizeRunnerState(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

func withRunnerOwnership(
    in directory: URL? = nil,
    connected: Bool = false,
    operation: (RunnerLeaseStore) throws -> Void
) throws {
    let stateDirectory = try directory ?? yielddApplicationSupportDirectory()

    let store = try RunnerLeaseStore(directory: stateDirectory)
    let lockURL = stateDirectory.appendingPathComponent("runner.lock", isDirectory: false)
    let descriptor = lockURL.path.withCString { path in
        Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR)
        )
    }
    guard descriptor >= 0 else {
        let errorNumber = errno
        if errorNumber == EWOULDBLOCK {
            throw RunnerOwnershipError.alreadyRunning
        }
        throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
    }
    defer { _ = Darwin.close(descriptor) }

    if !connected, [RunnerPlatform.linux, .macOS].contains(where: {
        FileManager.default.fileExists(atPath: ConnectedRunnerStore(directory: stateDirectory, platform: $0).file.path)
    }) {
        throw ConnectedRunnerError.recoveryRequired
    }
    try operation(store)
}

func yielddApplicationSupportDirectory() throws -> URL {
    try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ).appendingPathComponent("yieldd", isDirectory: true)
}

enum RunnerLeaseError: Error, Equatable, LocalizedError {
    case invalidContents(path: String)
    case invalidRunnerID(path: String)
    case tooLarge(path: String, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidContents(path):
            "The saved runner lease at \(path) is invalid."
        case let .invalidRunnerID(path):
            "The saved runner lease at \(path) contains an invalid runner ID."
        case let .tooLarge(path, maximumBytes):
            "The saved runner lease at \(path) exceeds \(maximumBytes) bytes."
        }
    }
}

enum RunnerOwnershipError: Error, Equatable, LocalizedError {
    case alreadyRunning

    var errorDescription: String? {
        "Another yieldd runner command is already active."
    }
}

private struct StoredRunnerLease: Codable {
    let runnerID: String
    let repository: String
    let platform: RunnerPlatform
}
