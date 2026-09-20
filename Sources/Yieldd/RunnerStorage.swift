import Darwin
import Foundation

// The configuration and cleanup journals live outside the guest volume. A missing
// mount must never turn into an ordinary directory on the host filesystem.
struct RunnerStorage: Codable, Equatable {
    static let maximumConfigurationBytes = 8 * 1_024
    static let machinesPath = "plugin-state/machine-apiserver/machines"
    let volumePath: String
    let volumeUUID: String

    var volumeURL: URL { URL(fileURLWithPath: volumePath, isDirectory: true) }
    var containerURL: URL { volumeURL.appendingPathComponent("container", isDirectory: true) }
    var clonesURL: URL { cloneRoot(.runners) }
    var probesURL: URL { cloneRoot(.probes) }

    func cloneRoot(_ kind: RunnerCloneKind) -> URL {
        volumeURL.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    static func cloneRoot(in directory: URL, kind: RunnerCloneKind = .runners) throws -> URL {
        try required(in: directory).cloneRoot(kind)
    }

    static func load(in directory: URL) throws -> Self? {
        let file = directory.appendingPathComponent("storage.json")
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw RunnerStorageError.invalidConfiguration(path: file.path, reason: "not a regular file") }
        let data = try handle.read(upToCount: maximumConfigurationBytes + 1) ?? Data()
        guard data.count <= maximumConfigurationBytes else {
            throw RunnerStorageError.configurationTooLarge(path: file.path, maximumBytes: maximumConfigurationBytes)
        }
        let stored: Self
        do { stored = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RunnerStorageError.invalidConfiguration(path: file.path, reason: describeError(error)) }
        guard stored.volumePath.hasPrefix("/"), UUID(uuidString: stored.volumeUUID) != nil else {
            throw RunnerStorageError.invalidConfiguration(path: file.path, reason: "expected an absolute mount point and a volume UUID")
        }
        return stored
    }

    static func required(in directory: URL) throws -> Self {
        guard let storage = try load(in: directory) else {
            throw RunnerStorageError.notConfigured
        }
        return storage
    }

    static func validated(in directory: URL, executor: any ProcessExecuting = ProcessExecutor()) throws -> Self {
        let storage = try required(in: directory)
        try storage.validate(stateDirectory: directory, executor: executor)
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
        try validate(volume, stateDirectory: stateDirectory)
        return volume
    }

    func validate(_ volume: APFSQuotaVolume, stateDirectory: URL) throws {
        guard volume.uuid == volumeUUID,
              volumeURL.resolvingSymlinksInPath().path == volumePath else {
            throw RunnerStorageError.volumeUnavailable(path: volumePath)
        }
        guard volume.quotaBytes > 0 else { throw RunnerStorageError.noQuota(path: volumePath) }
        guard try Self.device(at: stateDirectory) != Self.device(at: volumeURL) else {
            throw RunnerStorageError.journalOnGuestVolume
        }
    }

    func validatePath(_ url: URL) throws {
        try validatePaths([url])
    }

    func validatePaths(_ urls: [URL]) throws {
        var root = stat()
        guard lstat(volumePath, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else {
            throw RunnerStorageError.volumeUnavailable(path: volumePath)
        }
        for url in urls {
            let path = url.standardizedFileURL
            guard path.pathComponents.starts(with: volumeURL.pathComponents) else {
                throw RunnerStorageError.outsideVolume(path: url.path)
            }
            var prefix = volumeURL
            for component in path.pathComponents.dropFirst(volumeURL.pathComponents.count) {
                prefix.appendPathComponent(component)
                var status = stat()
                if lstat(prefix.path, &status) != 0 {
                    let code = errno
                    if code == ENOENT { break }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                guard status.st_mode & S_IFMT != S_IFLNK, status.st_dev == root.st_dev else {
                    throw RunnerStorageError.outsideVolume(path: url.path)
                }
            }
        }
    }

    func validateMacOS(template: URL, clones: URL) throws {
        guard clones.standardizedFileURL == clonesURL || clones.standardizedFileURL == probesURL else {
            throw RunnerStorageError.invalidCloneRoot(path: clones.path)
        }
        try validateTemplateLocation(template)
        try validatePaths([template, clones])
    }

    func validateTemplateLocation(_ template: URL) throws {
        for kind in RunnerCloneKind.allCases {
            try MacOSVirtualizationBackend.validateTemplateLocation(template, cloneRootURL: cloneRoot(kind))
        }
    }

    func validateContainer(containerExecutable: URL,
                           executor: any ProcessExecuting = ProcessExecutor()) throws {
        try validatePaths([containerURL] + ["containers", "content", "snapshots", "volumes", "plugin-state", Self.machinesPath]
            .map { containerURL.appendingPathComponent($0) })
        let request = ProcessRequest(executableURL: containerExecutable,
            arguments: ["system", "status", "--format", "json"], timeout: 15,
            outputCapture: .tail(maxBytes: 64 * 1_024), cancellable: false)
        let result = try executor.execute(request)
        guard result.terminationReason == .exit, result.terminationStatus == 0 else {
            throw RunnerStorageError.containerUnavailable(detail: result.stderrText)
        }
        struct Status: Decodable { let status: String; let appRoot: String }
        let status: Status
        do { status = try JSONDecoder().decode(Status.self, from: result.stdout) }
        catch { throw RunnerStorageError.containerUnavailable(detail: describeError(error)) }
        guard status.status == "running" else { throw RunnerStorageError.containerUnavailable(detail: status.status) }
        guard URL(fileURLWithPath: status.appRoot).resolvingSymlinksInPath() == containerURL else {
            throw RunnerStorageError.containerRootMismatch(path: containerURL.path)
        }
    }

    func requireMachineRemoved(_ id: RunnerID) throws {
        guard id.isValid else { throw RunnerLeaseError.invalidRunnerID(path: containerURL.path) }
        let machines = containerURL.appendingPathComponent(Self.machinesPath)
        try validatePath(machines)
        let bundle = machines.appendingPathComponent(id.value)
        var status = stat()
        if lstat(bundle.path, &status) == 0 { throw RunnerStorageError.machineStorageRemains(runner: id.value, path: bundle.path) }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func device(at url: URL) throws -> dev_t {
        var current = url
        while true {
            var status = stat()
            if stat(current.path, &status) == 0 { return status.st_dev }
            guard errno == ENOENT, current.path != "/" else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            current.deleteLastPathComponent()
        }
    }
}

enum RunnerCloneKind: String, CaseIterable {
    case runners = "macos-runners"
    case probes = "macos-probes"
}

struct APFSQuotaVolume: Equatable {
    let uuid: String
    let quotaBytes: UInt64

    static func read(at url: URL, using executor: any ProcessExecuting) throws -> Self {
        let infoRequest = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["info", "-plist", url.path], timeout: 15,
            outputCapture: .tail(maxBytes: 64 * 1_024), cancellable: false)
        let infoResult = try executor.execute(infoRequest)
        guard infoResult.terminationReason == .exit, infoResult.terminationStatus == 0 else {
            throw RunnerStorageError.volumeUnavailable(path: url.path)
        }
        struct Info: Decodable { let VolumeUUID: String; let MountPoint: String?; let FilesystemType: String }
        let info = try PropertyListDecoder().decode(Info.self, from: infoResult.stdout)
        guard info.FilesystemType == "apfs", info.MountPoint == url.path else {
            throw RunnerStorageError.volumeUnavailable(path: url.path)
        }
        let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["apfs", "list", "-plist"], timeout: 15,
            outputCapture: .tail(maxBytes: 1_024 * 1_024), cancellable: false)
        let result = try executor.execute(request)
        try result.requireSuccess(for: request)
        guard let volume = try decode(result.stdout).first(where: { $0.uuid == info.VolumeUUID }) else {
            throw RunnerStorageError.volumeUnavailable(path: url.path)
        }
        return volume
    }

    static func decode(_ data: Data) throws -> [Self] {
        struct Volume: Decodable {
            let APFSVolumeUUID: String
            let CapacityQuota: UInt64
        }
        struct Container: Decodable { let Volumes: [Volume] }
        struct List: Decodable { let Containers: [Container] }
        return try PropertyListDecoder().decode(List.self, from: data).Containers.flatMap { container in
            container.Volumes.map { Self(uuid: $0.APFSVolumeUUID, quotaBytes: $0.CapacityQuota) }
        }
    }
}

enum RunnerStorageError: Error, Equatable, LocalizedError {
    case notConfigured
    case invalidConfiguration(path: String, reason: String)
    case configurationTooLarge(path: String, maximumBytes: Int)
    case alreadyConfigured
    case outstandingRecovery
    case volumeUnavailable(path: String)
    case noQuota(path: String)
    case journalOnGuestVolume
    case outsideVolume(path: String)
    case invalidDirectory(path: String)
    case invalidCloneRoot(path: String)
    case containerRootMismatch(path: String)
    case containerUnavailable(detail: String)
    case machineStorageRemains(runner: String, path: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Runner storage is not configured. If cleanup is pending, restore storage.json from your recovery records. Otherwise configure a quota-limited APFS volume with yieldd storage configure. Do not discard cleanup records. See Docs/runner-storage.md."
        case let .invalidConfiguration(path, reason): "Invalid runner storage configuration at \(path): \(reason). Restore this file; do not discard cleanup records."
        case let .configurationTooLarge(path, maximumBytes): "Runner storage configuration at \(path) exceeds \(maximumBytes) bytes. Restore this file; do not discard cleanup records."
        case .alreadyConfigured: "Runner storage is already bound to another volume. Recover all runners before changing storage; keep the original volume and storage.json available for cleanup."
        case .outstandingRecovery: "Recover all standalone and connected runners before configuring storage."
        case let .volumeUnavailable(path): "The configured runner volume is not mounted at \(path) with its original identity. Mount it before starting or recovering runners."
        case let .noQuota(path): "The APFS volume at \(path) has no hard quota. Set a volume quota before using it for runners."
        case .journalOnGuestVolume: "Recovery records must be on a different filesystem from the quota-limited guest storage."
        case let .outsideVolume(path): "Runner storage must remain on the configured quota-limited volume: \(path)"
        case let .invalidDirectory(path): "Runner storage must be a directory, not a file or symbolic link: \(path)"
        case let .invalidCloneRoot(path): "macOS clones must use the configured macos-runners or macos-probes directory: \(path)"
        case let .containerUnavailable(detail): "Apple Container is not reachable as a running service. Start it with the configured --app-root, then retry. \(detail)"
        case let .containerRootMismatch(path): "Apple Container is not using the configured storage. Stop it, then start it with --app-root \(path). Existing Container data was not moved."
        case let .machineStorageRemains(id, path): "The bundle for \(id) remains at \(path) after Container cleanup. Keep the cleanup records. Restart Container with the configured --app-root and retry recovery. If the bundle remains unlisted, follow the offline repair procedure in Docs/runner-storage.md; repeated recovery alone cannot remove it."
        }
    }
}
