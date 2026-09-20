import Darwin
import Foundation

struct MacOSRunnerCloneStore {
    let rootURL: URL
    private let stateDirectory: URL?

    init(rootURL: URL) {
        self.rootURL = rootURL
        stateDirectory = nil
    }

    init(stateDirectory: URL) throws {
        self.stateDirectory = stateDirectory
        if let storage = try RunnerStorage.load(in: stateDirectory) {
            try storage.validate(stateDirectory: stateDirectory)
            try storage.validatePath(storage.clonesURL)
            rootURL = storage.clonesURL
        } else {
            // Old obligations remain recoverable before storage is configured.
            rootURL = stateDirectory.appendingPathComponent("macos-runners", isDirectory: true)
        }
    }

    func removeUnleased(
        keeping leasedIDs: Set<RunnerID>,
        checkCancellation: () throws -> Void = {}
    ) throws {
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
            guard id.isValid, !leasedIDs.contains(id) else { continue }
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
        if let stateDirectory, let storage = try RunnerStorage.load(in: stateDirectory) {
            try storage.validate(stateDirectory: stateDirectory)
            try storage.validatePath(rootURL)
        }
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
