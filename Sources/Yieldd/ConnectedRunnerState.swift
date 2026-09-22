import Darwin
import Foundation

struct ConnectedOffer: Codable, Equatable, Sendable {
    let slot: Int
    let owner: String
    let runner: String
    let repository: String
    let platform: String
    let architecture: String

    init(owner: String, runner: String, repository: String, platform: String, architecture: String, slot: Int = 0) throws {
        let suffix = String(runner.dropFirst("yieldd-bootstrap-".count))
        guard (0..<RunnerPool.maximumSlots).contains(slot), UUID(uuidString: owner)?.uuidString.lowercased() == owner,
              runner.hasPrefix("yieldd-bootstrap-"),
              UUID(uuidString: suffix)?.uuidString.lowercased() == suffix,
              ["linux", "macos"].contains(platform), architecture == "arm64" else {
            throw ConnectedRunnerError.invalidOffer
        }
        _ = try GitHubRepository(repository)
        self.slot = slot
        self.owner = owner
        self.runner = runner
        self.repository = repository
        self.platform = platform
        self.architecture = architecture
    }

    var runnerPlatform: RunnerPlatform { platform == "macos" ? .macOS : .linux }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(owner: values.decode(String.self, forKey: .owner), runner: values.decode(String.self, forKey: .runner),
                      repository: values.decode(String.self, forKey: .repository), platform: values.decode(String.self, forKey: .platform),
                      architecture: values.decode(String.self, forKey: .architecture), slot: values.decode(Int.self, forKey: .slot))
    }
}

struct ConnectedLease: Codable, Equatable {
    let server: String
    let deviceID: String
    let offer: ConnectedOffer
}

struct ConnectedRunnerStore {
    let directory: URL
    var platform: RunnerPlatform = .linux
    var slot: Int = 0
    var publish: (URL, URL) throws -> Void = { source, destination in
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    var file: URL {
        let name = platform == .linux ? "connected-runner" : "connected-macos-runner"
        return directory.appendingPathComponent(slot == 0 ? "\(name).json" : "\(name)-\(slot).json")
    }

    static func all(in directory: URL) -> [ConnectedRunnerStore] {
        [RunnerPlatform.macOS, .linux].flatMap { platform in
            (0..<RunnerPool.maximumSlots).map { ConnectedRunnerStore(directory: directory, platform: platform, slot: $0) }
        }
    }

    static func hasRecovery(in directory: URL) -> Bool {
        all(in: directory).contains { FileManager.default.fileExists(atPath: $0.file.path) }
    }

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
        guard data.count <= 8192 else { throw ConnectedRunnerError.invalidState }
        let lease: ConnectedLease
        do {
            lease = try JSONDecoder().decode(ConnectedLease.self, from: data)
        } catch let DecodingError.keyNotFound(key, context)
            where key.stringValue == "slot" && context.codingPath.map(\.stringValue) == ["offer"] {
            throw ConnectedRunnerError.previousVersionState
        } catch {
            throw ConnectedRunnerError.invalidState
        }
        guard lease.offer.runnerPlatform == platform, lease.offer.slot == slot else {
            throw ConnectedRunnerError.invalidState
        }
        return lease
    }

    func save(_ lease: ConnectedLease) throws {
        guard lease.offer.runnerPlatform == platform, lease.offer.slot == slot else { throw ConnectedRunnerError.invalidState }
        let data = try JSONEncoder().encode(lease)
        guard data.count <= 8192 else { throw ConnectedRunnerError.invalidState }
        let temporary = directory.appendingPathComponent(".connected-runner-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try publish(temporary, file)
        try synchronizeRunnerState(directory)
    }

    func clear() throws {
        try FileManager.default.removeItem(at: file)
        try synchronizeRunnerState(directory)
    }
}

enum ConnectedRunnerError: Error, Equatable, LocalizedError {
    case previousVersionState
    case invalidOffer, invalidState, invalidJIT, invalidServer, invalidToken, recoveryRequired, identityChanged
    case responseTooLarge, transport, http(Int)
    case registrationReconciliationRequired(String), confirmationMismatch

    var errorDescription: String? {
        switch self {
        case .previousVersionState: "The connected journal belongs to the previous single-worker version. Finish recovery with the previous yieldd version before upgrading. Do not delete unresolved recovery state."
        case .invalidOffer: "The coordinator offer must identify one supported Linux or macOS ARM64 runner."
        case .invalidState: "The connected runner journal is invalid or not private. Do not delete unresolved recovery state."
        case .invalidJIT: "JIT credentials do not identify the offered ephemeral runner and _work directory."
        case .invalidServer: "--server must be an HTTPS origin, or HTTP on a loopback IP for local testing."
        case .invalidToken: "YIELDD_CLIENT_TOKEN must contain 32 to 256 non-whitespace characters."
        case .recoveryRequired: "A connected runner needs cleanup. Run connect with its original server and device ID before using standalone commands."
        case .identityChanged: "The connected runner journal belongs to another server or device. Reconnect with its original settings to recover it."
        case .responseTooLarge: "The coordinator response exceeded its size limit."
        case .transport: "The coordinator request failed. Outstanding cleanup remains in the local journal."
        case let .http(status): "The coordinator returned HTTP \(status). Any unacknowledged cleanup remains in the local journal."
        case let .registrationReconciliationRequired(runner):
            "The coordinator no longer recognizes this assignment. Restore its original state, or manually remove GitHub runner \(runner), then run connect with --confirm-registration-removed \(runner) and the original server and device ID."
        case .confirmationMismatch: "The confirmed runner must match the outstanding connected journal. No recovery state was cleared."
        }
    }
}

func validateConnectedJIT(_ encoded: String, runner: String) throws {
    guard encoded.utf8.count <= 1_024 * 1_024,
          let data = Data(base64Encoded: encoded),
          let files = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          files[".credentials"] != nil,
          Set(files.keys).isSubset(of: [".runner", ".credentials", ".credentials_rsaparams"]),
          files.values.allSatisfy({ Data(base64Encoded: $0).map { !$0.isEmpty } == true }),
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
