import ArgumentParser
import Foundation

struct StorageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "storage",
        abstract: "Configure quota-limited guest storage without moving recovery records.",
        subcommands: [StorageConfigureCommand.self, StorageStatusCommand.self])
}

struct StorageConfigureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configure",
        abstract: "Use an existing quota-limited APFS volume for new runner guests.")

    @Option(name: .long, help: "Absolute mount point of an APFS volume with a nonzero quota.")
    var volume: String

    mutating func validate() throws {
        guard volume.hasPrefix("/") else { throw ValidationError("--volume must be an absolute mount point.") }
    }

    mutating func run() throws {
        try withRunnerOwnership(connected: true) { store in
            let storage = try configureRunnerStorage(volume: URL(fileURLWithPath: volume), leaseStore: store)
            print("Guest storage: \(storage.volumePath)")
            print("Recovery records remain at \(store.directory.path). No existing data was moved.")
            print("Copy the macOS template onto this volume. For Linux, stop Apple Container and start it with --app-root \(storage.containerURL.path), then rebuild the guest image. See Docs/runner-storage.md.")
        }
    }
}

struct StorageStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
        abstract: "Verify the mounted guest volume and show its current quota.")

    mutating func run() throws {
        let directory = try yielddApplicationSupportDirectory()
        let storage = try RunnerStorage.required(in: directory)
        let volume = try storage.validate(stateDirectory: directory)
        print("Guest volume: \(storage.volumePath) (\(storage.volumeUUID))")
        let quota = ByteCountFormatter.string(fromByteCount: Int64(clamping: volume.quotaBytes), countStyle: .binary)
        print("Shared hard quota: \(quota) (\(volume.quotaBytes) bytes).")
        print("Apple Container data: \(storage.containerURL.path)")
        print("macOS clones: \(storage.clonesURL.path)")
        print("macOS probe clones: \(storage.probesURL.path)")
        print("Recovery records: \(directory.path)")
    }
}

func configureRunnerStorage(volume: URL, leaseStore: RunnerLeaseStore,
                            executor: any ProcessExecuting = ProcessExecutor()) throws -> RunnerStorage {
    guard try leaseStore.pendingMachineTest() == nil, !ConnectedRunnerStore.hasRecovery(in: leaseStore.directory) else {
        throw RunnerStorageError.outstandingRecovery
    }
    let url = volume.standardizedFileURL
    let info = try APFSQuotaVolume.read(at: url, using: executor)
    let storage = RunnerStorage(volumePath: url.path, volumeUUID: info.uuid)
    try storage.validate(info, stateDirectory: leaseStore.directory)
    if let existing = try RunnerStorage.load(in: leaseStore.directory), existing != storage {
        throw RunnerStorageError.alreadyConfigured
    }
    let directories = [storage.containerURL, storage.clonesURL, storage.probesURL]
    try storage.validatePaths(directories)
    for directory in directories {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, directory.resolvingSymlinksInPath() == directory else {
                throw RunnerStorageError.invalidDirectory(path: directory.path)
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
    try storage.save(in: leaseStore.directory)
    return storage
}
