import Darwin
import Foundation

struct RunnerLeaseStore {
    let directory: URL
    fileprivate(set) var ownershipDescriptor: Int32?

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
    recoveringMachineTest: Bool = false,
    operation: (RunnerLeaseStore) throws -> Void
) throws {
    let stateDirectory = try directory ?? yielddApplicationSupportDirectory()

    var store = try RunnerLeaseStore(directory: stateDirectory)
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

    if FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("active-runner.json").path) {
        throw RunnerOwnershipError.previousLease
    }
    if !connected, ConnectedRunnerStore.hasRecovery(in: stateDirectory) {
        throw ConnectedRunnerError.recoveryRequired
    }
    if !recoveringMachineTest, try store.pendingMachineTest() != nil {
        throw MachineTestError.recoveryRequired
    }
    store.ownershipDescriptor = descriptor
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
    case invalidRunnerID(path: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRunnerID(path):
            "The saved runner lease at \(path) contains an invalid runner ID."
        }
    }
}

enum RunnerOwnershipError: Error, Equatable, LocalizedError {
    case previousLease, alreadyRunning

    var errorDescription: String? {
        switch self {
        case .previousLease: "Finish runner cleanup with the previous yieldd binary before continuing."
        case .alreadyRunning: "Another yieldd runner command is already active."
        }
    }
}
