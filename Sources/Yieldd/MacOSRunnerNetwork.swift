import CryptoKit
import Darwin
import Foundation

protocol RunnerNetworkRelaying: AnyObject {
    var socketURL: URL { get }
    var sshSocketURL: URL { get }
    func check() throws
    func stop(deadline: DispatchTime?) throws
}

extension RunnerNetworkRelay: RunnerNetworkRelaying {}

protocol MacOSRunnerNetworking {
    func start(for id: RunnerID, checkCancellation: () throws -> Void) throws -> any RunnerNetworkRelaying
    func remove(_ id: RunnerID) throws
}

struct MacOSRunnerNetwork: MacOSRunnerNetworking {
    private let executableURL: URL
    private let directories: RunnerNetworkDirectories

    static var bundledRelayURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/yieldd-network-relay")
    }

    init(stateDirectory: URL, executableURL: URL = bundledRelayURL) throws {
        self.executableURL = executableURL
        directories = try RunnerNetworkDirectories(stateDirectory: stateDirectory)
    }

    static func requireRelay(at executableURL: URL = bundledRelayURL) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MacOSRunnerNetworkError.missingRelay(executableURL.path)
        }
    }

    func start(for id: RunnerID, checkCancellation: () throws -> Void) throws -> any RunnerNetworkRelaying {
        return try RunnerNetworkRelay.start(
            executableURL: executableURL, directory: directories.create(for: id),
            checkCancellation: checkCancellation
        )
    }

    func remove(_ id: RunnerID) throws { try directories.remove(id) }
}

// Short paths are required by sockaddr_un. The state-directory identity separates
// owners; runner identities make socket cleanup possible after the owner dies.
// Callers hold runner ownership before creating or removing these directories.
struct RunnerNetworkDirectories {
    let rootURL: URL

    init(stateDirectory: URL) throws {
        rootURL = try RunnerNetworkRelay.userTemporaryDirectory()
            .appendingPathComponent("yn-\(Self.key(stateDirectory.resolvingSymlinksInPath().path).prefix(16))", isDirectory: true)
    }

    func create(for id: RunnerID) throws -> URL {
        let directory = try directory(for: id)
        try Self.createPrivateDirectory(rootURL)
        try Self.createPrivateDirectory(directory)
        return directory
    }

    func remove(_ id: RunnerID) throws {
        let directory = try directory(for: id)
        guard try Self.exists(rootURL), try Self.exists(directory) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func removeUnleased(keeping ids: Set<RunnerID>) throws {
        guard try Self.exists(rootURL) else { return }
        let retained = Set(try ids.map { try directory(for: $0).lastPathComponent })
        for entry in try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent
            guard name.count == 24, name.allSatisfy({ "0123456789abcdef".contains($0) }),
                  !retained.contains(name) else { continue }
            // Reject replaced paths rather than following a symlink during recovery.
            if try Self.exists(entry) { try FileManager.default.removeItem(at: entry) }
        }
    }

    private func directory(for id: RunnerID) throws -> URL {
        guard id.isValid else { throw RunnerLeaseError.invalidRunnerID(path: rootURL.path) }
        return rootURL.appendingPathComponent(Self.key(id.value), isDirectory: true)
    }

    private static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard try exists(url) else { throw POSIXError(.ENOENT) }
    }

    private static func exists(_ url: URL) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFDIR, status.st_mode & 0o777 == 0o700,
              status.st_uid == getuid() else { throw POSIXError(.EACCES) }
        return true
    }
}

enum MacOSRunnerNetworkError: Error, LocalizedError {
    case missingRelay(String)

    var errorDescription: String? {
        switch self {
        case let .missingRelay(path):
            "The macOS runner network relay is missing at \(path). Build and use yieldd.app with Scripts/build-local-app.sh."
        }
    }
}
