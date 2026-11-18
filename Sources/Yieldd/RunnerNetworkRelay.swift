import Darwin
import Foundation

// Process and descriptor operations are serialized by lock. The relay's stdin
// is a lifetime pipe: only this owner holds its write end, marked close-on-exec.
final class RunnerNetworkRelay: @unchecked Sendable {
    let socketURL: URL
    let sshSocketURL: URL
    private let directoryURL: URL
    private let process = Process()
    private let lifetime = Pipe()
    private let readiness = Pipe()
    private let lock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    private var launched = false
    private var removed = false

    static func start(
        executableURL: URL,
        directory: URL,
        identity: (runner: String, platform: String)? = nil,
        cacheSocket: URL? = nil,
        startupTimeout: TimeInterval = 5,
        checkCancellation: () throws -> Void = {}
    ) throws -> RunnerNetworkRelay {
        precondition(startupTimeout.isFinite && startupTimeout > 0)
        try checkCancellation()
        let relay = try RunnerNetworkRelay(executableURL: executableURL, directory: directory, identity: identity, cacheSocket: cacheSocket)
        do {
            try relay.lock.withLock {
                try relay.launch(timeout: startupTimeout, checkCancellation: checkCancellation)
            }
            return relay
        } catch {
            do { try relay.stop() } catch let cleanup {
                throw RunnerNetworkRelayError.startAndCleanupFailed(start: error, cleanup: cleanup)
            }
            throw error
        }
    }

    private init(executableURL: URL, directory: URL, identity: (runner: String, platform: String)?, cacheSocket: URL?) throws {
        let path = directory.path
        guard path.utf8.count + "/n.ssh".utf8.count < 104 else {
            throw RunnerNetworkRelayError.socketPathTooLong
        }
        try Self.requirePrivateDirectory(directory)
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw POSIXError(.ENOTEMPTY)
        }
        directoryURL = directory
        socketURL = directoryURL.appendingPathComponent("n")
        sshSocketURL = socketURL.appendingPathExtension("ssh")
        process.executableURL = executableURL
        var arguments = ["--socket", socketURL.path]
        if let identity {
            arguments += ["--runner", identity.runner, "--platform", identity.platform.lowercased()]
        }
        if let cacheSocket { arguments += ["--cache-socket", cacheSocket.path] }
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = lifetime
        process.standardOutput = readiness
        // The trusted relay emits bounded per-reason summaries, not packet contents.
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [exited] _ in exited.signal() }
    }

    private func launch(timeout: TimeInterval, checkCancellation: () throws -> Void) throws {
        for handle in [lifetime.fileHandleForReading, lifetime.fileHandleForWriting,
                       readiness.fileHandleForReading, readiness.fileHandleForWriting] {
            guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw Self.posixError() }
        }
        let descriptor = readiness.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Self.posixError() }
        try process.run()
        launched = true
        try lifetime.fileHandleForReading.close()
        try readiness.fileHandleForWriting.close()

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 1_025)
        while true {
            try checkCancellation()
            try requireRunningLocked()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                payload.append(contentsOf: buffer.prefix(count))
                guard payload.count <= 1_024 else { throw RunnerNetworkRelayError.invalidReadiness }
                if payload.contains(10) {
                    struct Ready: Decodable { let version: Int; let ssh: String }
                    guard let ready = try? JSONDecoder().decode(Ready.self, from: payload), ready.version == 2,
                          ready.ssh == sshSocketURL.path
                    else { throw RunnerNetworkRelayError.invalidReadiness }
                    try requireRunningLocked()
                    return
                }
            } else if count == 0 {
                throw RunnerNetworkRelayError.invalidReadiness
            } else if errno != EAGAIN && errno != EINTR {
                throw Self.posixError()
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RunnerNetworkRelayError.startupTimedOut }
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptorState, 1, 20) < 0, errno != EINTR { throw Self.posixError() }
        }
    }

    func check() throws { try lock.withLock { try requireRunningLocked() } }

    var isRunning: Bool { lock.withLock { launched && process.isRunning } }

    private func requireRunningLocked() throws {
        guard launched, process.isRunning else {
            throw RunnerNetworkRelayError.exited(status: launched ? process.terminationStatus : nil)
        }
    }

    func stop(deadline: DispatchTime? = nil) throws {
        try lock.withLock {
            guard !removed else { return }
            try? lifetime.fileHandleForWriting.close()
            if launched, process.isRunning {
                waitForExit(seconds: 1, deadline: deadline)
                if process.isRunning {
                    process.terminate()
                    waitForExit(seconds: 1, deadline: deadline)
                }
                if process.isRunning {
                    guard kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else { throw Self.posixError() }
                    waitForExit(seconds: 2, deadline: deadline)
                }
                guard !process.isRunning else { throw RunnerNetworkRelayError.stopTimedOut }
            }
            try? lifetime.fileHandleForReading.close()
            try? readiness.fileHandleForReading.close()
            try? readiness.fileHandleForWriting.close()
            do { try FileManager.default.removeItem(at: directoryURL) }
            catch CocoaError.fileNoSuchFile {}
            removed = true
        }
    }

    private func waitForExit(seconds: TimeInterval, deadline: DispatchTime?) {
        _ = exited.wait(timeout: min(.now() + seconds, deadline ?? .distantFuture))
    }

    deinit { try? stop() }

    // Ignore TMPDIR: this OS-provided parent is private to the current user and
    // short enough for Unix sockets. Shared /tmp permits cross-user squatting.
    static func userTemporaryDirectory() throws -> URL {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { throw posixError() }
        var path = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &path, size) == size else { throw posixError() }
        let url = URL(fileURLWithPath: String(decoding: path.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
        try requirePrivateDirectory(url)
        return url
    }

    static func requirePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700,
              info.st_uid == getuid() else { throw POSIXError(.EACCES) }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

enum RunnerNetworkRelayError: Error, LocalizedError {
    case socketPathTooLong
    case invalidReadiness
    case startupTimedOut
    case exited(status: Int32?)
    case stopTimedOut
    case startAndCleanupFailed(start: any Error, cleanup: any Error)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong: "The relay socket path is too long. Use a shorter temporary directory."
        case .invalidReadiness: "The network relay returned an invalid or unsupported readiness response."
        case .startupTimedOut: "The network relay did not become ready before the startup deadline."
        case let .exited(status): "The network relay is not running\(status.map { " (exit status \($0))" } ?? "")."
        case .stopTimedOut: "Network relay termination was not confirmed before the shutdown deadline. Its socket directory was retained for another cleanup attempt."
        case let .startAndCleanupFailed(start, cleanup):
            "Network relay startup failed: \(start.localizedDescription). Cleanup also failed: \(cleanup.localizedDescription)"
        }
    }
}
