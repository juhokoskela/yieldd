import Darwin
import Foundation

struct ConnectedOffer: Codable, Equatable {
    let owner: String
    let runner: String
    let repository: String
    let platform: String
    let architecture: String

    func validate() throws {
        guard UUID(uuidString: owner)?.uuidString.lowercased() == owner,
              runner.hasPrefix("yieldd-bootstrap-"),
              UUID(uuidString: String(runner.dropFirst("yieldd-bootstrap-".count)))?.uuidString.lowercased()
                == String(runner.dropFirst("yieldd-bootstrap-".count)),
              platform == "linux", architecture == "arm64" else {
            throw ConnectedRunnerError.invalidOffer
        }
        _ = try GitHubRepository(repository)
    }
}

struct ConnectedLease: Codable, Equatable {
    let server: String
    let deviceID: String
    let offer: ConnectedOffer
}

struct ConnectedRunnerStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("connected-runner.json") }

    func load() throws -> ConnectedLease? {
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o077 == 0 else {
            throw ConnectedRunnerError.invalidState
        }
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192,
              let lease = try? JSONDecoder().decode(ConnectedLease.self, from: data) else {
            throw ConnectedRunnerError.invalidState
        }
        try lease.offer.validate()
        return lease
    }

    func save(_ lease: ConnectedLease) throws {
        try lease.offer.validate()
        let data = try JSONEncoder().encode(lease)
        guard data.count <= 8192 else { throw ConnectedRunnerError.invalidState }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try synchronize(file)
        try synchronize(directory)
    }

    func clear() throws {
        try FileManager.default.removeItem(at: file)
        try synchronize(directory)
    }

    private func synchronize(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

enum ConnectedRunnerError: Error, Equatable, LocalizedError {
    case invalidOffer, invalidState, invalidJIT, invalidServer, invalidToken, recoveryRequired, identityChanged
    case responseTooLarge, transport, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidOffer: "The coordinator offer must identify one Linux ARM64 runner."
        case .invalidState: "The connected runner journal is invalid or not private. Do not delete unresolved recovery state."
        case .invalidJIT: "JIT credentials do not identify the offered ephemeral runner and _work directory."
        case .invalidServer: "--server must be an HTTPS origin, or HTTP on a loopback IP for local testing."
        case .invalidToken: "YIELDD_CLIENT_TOKEN must contain 32 to 256 non-whitespace characters."
        case .recoveryRequired: "A connected runner needs cleanup. Run connect with its original server and device ID before using standalone commands."
        case .identityChanged: "The connected runner journal belongs to another server or device. Reconnect with its original settings to recover it."
        case .responseTooLarge: "The coordinator response exceeded its size limit."
        case .transport: "The coordinator request failed. Reconnect with the same settings to recover any outstanding assignment."
        case let .http(status): "The coordinator returned HTTP \(status). Any unacknowledged cleanup remains in the local journal."
        }
    }
}

func validateConnectedJIT(_ encoded: String, runner: String) throws {
    guard encoded.utf8.count <= 1_024 * 1_024,
          let data = Data(base64Encoded: encoded),
          let files = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          !files.isEmpty,
          files.keys.allSatisfy({ $0.hasPrefix(".") && $0.count > 1 && $0.dropFirst().utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) }),
          let settings = files[".runner"].flatMap({ Data(base64Encoded: $0) }),
          let decoded = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else {
        throw ConnectedRunnerError.invalidJIT
    }
    var normalized: [String: Any] = [:]
    for (key, value) in decoded {
        guard normalized.updateValue(value, forKey: key.lowercased()) == nil else {
            throw ConnectedRunnerError.invalidJIT
        }
    }
    let ephemeral = normalized["ephemeral"]
    guard normalized["agentname"] as? String == runner,
          normalized["workfolder"] as? String == "_work",
          (ephemeral as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            || (ephemeral as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true else {
        throw ConnectedRunnerError.invalidJIT
    }
}
