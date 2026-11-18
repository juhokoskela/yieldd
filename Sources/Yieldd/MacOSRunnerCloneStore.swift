import Darwin
import Foundation

func removeMacOSRunnerFiles(_ id: RunnerID, in directory: URL,
                           makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil) throws {
    var failures: [RunnerSessionCleanupFailure] = []
    do { try RunnerNetworkDirectories(stateDirectory: directory).remove(id) }
    catch { failures.append(.init(step: .network, error: error)) }
    do {
        let clones = try (makeCloneStore ?? { try MacOSRunnerCloneStore(stateDirectory: directory, kind: $0) })(.runners)
        try clones.remove(id)
    } catch { failures.append(.init(step: .machine, error: error)) }
    if !failures.isEmpty { throw RunnerSessionError.cleanupFailed(failures) }
}

// Called under exclusive ownership after all outstanding guests have been recovered.
func removeUnleasedRunnerFiles(in directory: URL, ownershipDescriptor: Int32? = nil, checkCancellation: () throws -> Void = {},
                               makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil) throws {
    let makeCloneStore = makeCloneStore ?? { try MacOSRunnerCloneStore(stateDirectory: directory, kind: $0) }
    var failures: [RunnerSessionCleanupFailure] = []
    try checkCancellation()
    do { try RunnerNetworkDirectories(stateDirectory: directory).removeUnleased() }
    catch {
        if isCancellation(error) { throw error }
        if case let RunnerSessionError.cleanupFailed(entries) = error { failures.append(contentsOf: entries) }
        else { failures.append(.init(step: .network, error: error)) }
    }
    do { try ArchiveCacheVolume.recover(in: directory, ownershipDescriptor: ownershipDescriptor) }
    catch { failures.append(.init(step: .machine, error: error)) }
    for kind in RunnerCloneKind.allCases {
        do {
            try makeCloneStore(kind)
                .removeUnleased(checkCancellation: checkCancellation)
        } catch {
            if isCancellation(error) { throw error }
            failures.append(.init(step: .machine, error: error))
        }
    }
    if !failures.isEmpty { throw RunnerSessionError.cleanupFailed(failures) }
}

struct MacOSRunnerCloneStore {
    let rootURL: URL
    private let validateRoot: () throws -> Void

    init(rootURL: URL) {
        self.rootURL = rootURL
        validateRoot = {}
    }

    init(stateDirectory: URL, kind: RunnerCloneKind = .runners) throws {
        let storage = try RunnerStorage.required(in: stateDirectory)
        rootURL = storage.cloneRoot(kind)
        validateRoot = {
            let current = try RunnerStorage.validated(in: stateDirectory)
            guard current == storage else { throw RunnerStorageError.volumeUnavailable(path: storage.volumePath) }
            try current.validatePath(current.cloneRoot(kind))
        }
    }

    func removeUnleased(checkCancellation: () throws -> Void = {}) throws {
        guard try rootExists() else { return }
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        var failures: [any Error] = []
        for entry in entries {
            try checkCancellation()
            guard ["creating", "bundle"].contains(entry.pathExtension) else { continue }
            let id = RunnerID(value: entry.deletingPathExtension().lastPathComponent)
            guard id.isValid else { continue }
            do {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try FileManager.default.removeItem(at: entry)
            } catch {
                failures.append(error)
            }
        }
        if !failures.isEmpty { throw MacOSRunnerCloneStoreError.cleanupFailed(failures) }
    }

    private func rootExists() throws -> Bool {
        try validateRoot()
        var status = stat()
        guard Darwin.lstat(rootURL.path, &status) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw MacOSRunnerCloneStoreError.invalidRoot(rootURL.path)
        }
        return true
    }

    func creatingURL(for id: RunnerID) throws -> URL {
        try url(for: id, suffix: "creating")
    }

    func bundleURL(for id: RunnerID) throws -> URL {
        try url(for: id, suffix: "bundle")
    }

    func remove(_ id: RunnerID) throws {
        let urls = try [creatingURL(for: id), bundleURL(for: id)]
        guard try rootExists() else { return }
        var failures: [any Error] = []
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                failures.append(error)
            }
        }
        if !failures.isEmpty { throw MacOSRunnerCloneStoreError.cleanupFailed(failures) }
    }

    private func url(for id: RunnerID, suffix: String) throws -> URL {
        guard id.isValid else {
            throw RunnerLeaseError.invalidRunnerID(path: rootURL.path)
        }
        return rootURL.appendingPathComponent("\(id.value).\(suffix)", isDirectory: true)
    }
}

enum MacOSRunnerCloneStoreError: Error, LocalizedError {
    case invalidRoot(String)
    case cleanupFailed([any Error])

    var errorDescription: String? {
        switch self {
        case let .invalidRoot(path):
            "The macOS runner clone root must be a directory, not a symbolic link: \(path)"
        case let .cleanupFailed(errors):
            "Could not remove macOS runner clones: \(errors.map(describeError).joined(separator: "; "))"
        }
    }
}
