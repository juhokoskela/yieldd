import Darwin
import Foundation

// The configuration and cleanup journals live outside the guest volume. A missing
// mount must never turn into an ordinary directory on the host filesystem.
struct RunnerStorage: Codable, Equatable {
    let volumePath: String
    let volumeUUID: String

    var volumeURL: URL { URL(fileURLWithPath: volumePath, isDirectory: true) }
    var containerURL: URL { volumeURL.appendingPathComponent("container", isDirectory: true) }
    var clonesURL: URL { volumeURL.appendingPathComponent("macos-runners", isDirectory: true) }
    var probesURL: URL { volumeURL.appendingPathComponent("macos-probes", isDirectory: true) }

    static func load(in directory: URL) throws -> Self? {
        let file = directory.appendingPathComponent("storage.json")
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try handle.read(upToCount: 8193), data.count <= 8192,
              let stored = try? JSONDecoder().decode(Self.self, from: data),
              stored.volumePath.hasPrefix("/"), UUID(uuidString: stored.volumeUUID) != nil else {
            throw RunnerStorageError.invalidConfiguration
        }
        return stored
    }

    static func required(in directory: URL? = nil) throws -> Self {
        guard let storage = try load(in: directory ?? yielddApplicationSupportDirectory()) else {
            throw RunnerStorageError.notConfigured
        }
        return storage
    }

    func save(in directory: URL) throws {
        if let existing = try Self.load(in: directory) {
            guard existing == self else { throw RunnerStorageError.alreadyConfigured }
            return
        }
        let file = directory.appendingPathComponent("storage.json")
        let temporary = directory.appendingPathComponent(".storage-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(self))
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeRunnerState(directory)
    }

    @discardableResult
    func validate(stateDirectory: URL, executor: any ProcessExecuting = ProcessExecutor()) throws -> APFSQuotaVolume {
        let volume = try APFSQuotaVolume.read(at: volumeURL, using: executor)
        guard volume.uuid == volumeUUID, volume.mountPoint == volumePath,
              volumeURL.resolvingSymlinksInPath().path == volumePath else {
            throw RunnerStorageError.volumeUnavailable(volumePath)
        }
        guard volume.quotaBytes > 0 else { throw RunnerStorageError.noQuota(volumePath) }
        guard try Self.device(at: stateDirectory) != Self.device(at: volumeURL) else {
            throw RunnerStorageError.journalOnGuestVolume
        }
        return volume
    }

    func validatePath(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathComponents.starts(with: volumeURL.pathComponents),
              try Self.device(at: resolved) == Self.device(at: volumeURL) else {
            throw RunnerStorageError.outsideVolume(url.path)
        }
    }

    func validateMacOS(template: URL, clones: URL, stateDirectory: URL,
                       executor: any ProcessExecuting = ProcessExecutor()) throws {
        try validate(stateDirectory: stateDirectory, executor: executor)
        try validatePath(template)
        try validatePath(clones)
        try MacOSVirtualizationBackend.validateTemplateLocation(template, cloneRootURL: clonesURL)
        try MacOSVirtualizationBackend.validateTemplateLocation(template, cloneRootURL: probesURL)
        guard clones.standardizedFileURL == clonesURL || clones.standardizedFileURL == probesURL else {
            throw RunnerStorageError.outsideVolume(clones.path)
        }
    }

    func validateContainer(containerExecutable: URL, stateDirectory: URL,
                           executor: any ProcessExecuting = ProcessExecutor()) throws {
        try validate(stateDirectory: stateDirectory, executor: executor)
        try validatePath(containerURL)
        let request = ProcessRequest(executableURL: containerExecutable,
            arguments: ["system", "status", "--format", "json"], timeout: 15,
            outputCapture: .tail(maxBytes: 64 * 1_024), cancellable: false)
        let result = try executor.execute(request)
        try result.requireSuccess(for: request)
        struct Status: Decodable { let status: String; let appRoot: String }
        let status = try JSONDecoder().decode(Status.self, from: result.stdout)
        guard status.status == "running",
              URL(fileURLWithPath: status.appRoot).resolvingSymlinksInPath() == containerURL else {
            throw RunnerStorageError.containerRootMismatch(containerURL.path)
        }
        // These contain writable guest disks, snapshots, or guest-generated logs.
        for name in ["containers", "content", "snapshots", "volumes", "plugin-state", "plugin-state/machine-apiserver/machines"] {
            try validatePath(containerURL.appendingPathComponent(name))
        }
    }

    func requireMachineRemoved(_ id: RunnerID) throws {
        guard id.isValid else { throw RunnerLeaseError.invalidRunnerID(path: containerURL.path) }
        let machines = containerURL.appendingPathComponent("plugin-state/machine-apiserver/machines")
        try validatePath(machines)
        let bundle = machines.appendingPathComponent(id.value)
        var status = stat()
        if lstat(bundle.path, &status) == 0 { throw RunnerStorageError.machineStorageRemains(id.value) }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func device(at url: URL) throws -> dev_t {
        var current = url
        while true {
            var status = stat()
            if fstatat(AT_FDCWD, current.path, &status, 0) == 0 { return status.st_dev }
            guard errno == ENOENT, current.path != "/" else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            current.deleteLastPathComponent()
        }
    }
}

struct APFSQuotaVolume: Equatable {
    let uuid: String
    let mountPoint: String?
    let quotaBytes: UInt64

    static func read(at url: URL, using executor: any ProcessExecuting) throws -> Self {
        let infoRequest = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["info", "-plist", url.path], timeout: 15,
            outputCapture: .tail(maxBytes: 64 * 1_024), cancellable: false)
        let infoResult = try executor.execute(infoRequest)
        guard infoResult.terminationReason == .exit, infoResult.terminationStatus == 0 else {
            throw RunnerStorageError.volumeUnavailable(url.path)
        }
        struct Info: Decodable { let VolumeUUID: String; let MountPoint: String?; let FilesystemType: String }
        let info = try PropertyListDecoder().decode(Info.self, from: infoResult.stdout)
        guard info.FilesystemType == "apfs", info.MountPoint == url.path else {
            throw RunnerStorageError.volumeUnavailable(url.path)
        }
        let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["apfs", "list", "-plist"], timeout: 15,
            outputCapture: .tail(maxBytes: 1_024 * 1_024), cancellable: false)
        let result = try executor.execute(request)
        try result.requireSuccess(for: request)
        guard let volume = try decode(result.stdout).first(where: { $0.uuid == info.VolumeUUID }) else {
            throw RunnerStorageError.volumeUnavailable(url.path)
        }
        return Self(uuid: volume.uuid, mountPoint: info.MountPoint, quotaBytes: volume.quotaBytes)
    }

    static func decode(_ data: Data) throws -> [Self] {
        struct Volume: Decodable {
            let APFSVolumeUUID: String
            let MountPoint: String?
            let CapacityQuota: UInt64
        }
        struct Container: Decodable { let Volumes: [Volume] }
        struct List: Decodable { let Containers: [Container] }
        return try PropertyListDecoder().decode(List.self, from: data).Containers.flatMap { container in
            container.Volumes.map { Self(uuid: $0.APFSVolumeUUID, mountPoint: $0.MountPoint, quotaBytes: $0.CapacityQuota) }
        }
    }
}

enum RunnerStorageError: Error, Equatable, LocalizedError {
    case notConfigured, invalidConfiguration, alreadyConfigured, outstandingRecovery, legacyClones
    case volumeUnavailable(String), noQuota(String), journalOnGuestVolume, outsideVolume(String), invalidDirectory(String)
    case containerRootMismatch(String), machineStorageRemains(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Runner storage is not configured. Create a quota-limited APFS volume, then run yieldd storage configure --volume /Volumes/YielddRunners. See Docs/runner-storage.md."
        case .invalidConfiguration: "The runner storage configuration is invalid. Restore storage.json; do not discard unresolved cleanup records."
        case .alreadyConfigured: "Runner storage is already bound to another volume. Recover all runners before changing storage; keep the original volume and storage.json available for cleanup."
        case .outstandingRecovery: "Recover all standalone and connected runners before configuring storage."
        case .legacyClones: "Legacy macOS clones remain in the state directory. Recover or inspect them before configuring storage; no files were moved."
        case let .volumeUnavailable(path): "The configured runner volume is not mounted at \(path) with its original identity. Mount it before starting or recovering runners."
        case let .noQuota(path): "The APFS volume at \(path) has no hard quota. Set a volume quota before using it for runners."
        case .journalOnGuestVolume: "Recovery records must be on a different filesystem from the quota-limited guest storage."
        case let .outsideVolume(path): "Runner storage must remain on the configured quota-limited volume: \(path)"
        case let .invalidDirectory(path): "Runner storage must be a directory, not a file or symbolic link: \(path)"
        case let .containerRootMismatch(path): "Apple Container is not using the configured storage. Stop it, then start it with --app-root \(path). Existing Container data was not moved."
        case let .machineStorageRemains(id): "Apple Container still has disk storage for \(id), even though its API no longer lists the machine. Cleanup remains pending. Free space on the guest volume and restart Container using its configured app root, then retry recovery."
        }
    }
}
