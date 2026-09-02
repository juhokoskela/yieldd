import Darwin
import Foundation

struct RunnerLease: Equatable {
    let runnerID: RunnerID
    let repository: GitHubRepository
}

struct RunnerLeaseStore {
    static let maximumBytes = 4 * 1_024

    let fileURL: URL

    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fileURL = directory.appendingPathComponent("active-runner.json", isDirectory: false)
    }

    func load() throws -> RunnerLease? {
        let descriptor = fileURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let errorNumber = errno
            guard errorNumber == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
            }
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else {
            throw RunnerLeaseError.tooLarge(maximumBytes: Self.maximumBytes)
        }

        let stored = try JSONDecoder().decode(StoredRunnerLease.self, from: data)
        guard Self.isValidRunnerID(stored.runnerID) else {
            throw RunnerLeaseError.invalidRunnerID
        }

        return RunnerLease(
            runnerID: RunnerID(value: stored.runnerID),
            repository: try GitHubRepository(stored.repository)
        )
    }

    func save(_ lease: RunnerLease) throws {
        let stored = StoredRunnerLease(
            runnerID: lease.runnerID.value,
            repository: lease.repository.fullName
        )
        let data = try JSONEncoder().encode(stored)
        guard data.count <= Self.maximumBytes else {
            throw RunnerLeaseError.tooLarge(maximumBytes: Self.maximumBytes)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard fileURL.path.withCString(Darwin.unlink) == 0 else {
            let errorNumber = errno
            guard errorNumber == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
            }
            return
        }
    }

    private static func isValidRunnerID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return value.hasPrefix("yieldd-")
            && value.count <= 128
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

func withRunnerOwnership(
    in directory: URL? = nil,
    operation: (RunnerLeaseStore) throws -> Void
) throws {
    let stateDirectory: URL
    if let directory {
        stateDirectory = directory
    } else {
        stateDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("yieldd", isDirectory: true)
    }

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

    try operation(store)
}

enum RunnerLeaseError: Error, Equatable, LocalizedError {
    case invalidRunnerID
    case tooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRunnerID:
            "The saved runner lease contains an invalid runner ID."
        case let .tooLarge(maximumBytes):
            "The saved runner lease exceeds \(maximumBytes) bytes."
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
}
