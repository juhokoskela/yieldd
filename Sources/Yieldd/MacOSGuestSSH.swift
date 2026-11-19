import Darwin
import Foundation

struct MacOSGuestSSH {
    static let privateKeyFilename = "SSHPrivateKey"
    static let knownHostsFilename = "SSHKnownHosts"
    static let hostKeyAlias = "yieldd-macos-template"
    static let outputTailBytes = 64 * 1_024

    private let executableURL: URL
    private let privateKeyURL: URL
    private let knownHostsURL: URL
    private let executor: any ProcessExecuting
    private let socketURL: URL

    init(
        templateURL: URL,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        socketURL: URL,
        executor: any ProcessExecuting
    ) {
        self.executableURL = executableURL
        privateKeyURL = templateURL.appendingPathComponent(Self.privateKeyFilename)
        knownHostsURL = templateURL.appendingPathComponent(Self.knownHostsFilename)
        self.executor = executor
        self.socketURL = socketURL
    }

    static func validateTemplate(at templateURL: URL) throws {
        let privateKeyURL = templateURL.appendingPathComponent(privateKeyFilename)
        let knownHostsURL = templateURL.appendingPathComponent(knownHostsFilename)
        let privateKeyPermissions = try permissions(ofRegularFile: privateKeyURL)
        guard privateKeyPermissions & 0o077 == 0 else {
            throw MacOSGuestSSHError.insecurePrivateKey(
                path: privateKeyURL.path,
                permissions: privateKeyPermissions
            )
        }
        let knownHostsPermissions = try permissions(ofRegularFile: knownHostsURL)
        guard knownHostsPermissions & 0o022 == 0 else {
            throw MacOSGuestSSHError.insecureKnownHosts(
                path: knownHostsURL.path,
                permissions: knownHostsPermissions
            )
        }
    }

    func checkTransport(timeout: TimeInterval) throws {
        try run("/usr/bin/true", timeout: timeout)
    }

    func validateGuest(timeout: TimeInterval) throws {
        try run(
            "/Users/runner/bin/yieldd-runner-control ready",
            timeout: timeout
        )
    }

    @discardableResult func execute(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        cancellable: Bool = true
    ) throws -> ProcessResult {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw RunnerBackendError.emptyCommand
        }
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw MacOSGuestSSHError.invalidCommandArgument
        }
        let command = arguments.map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        return try run(
            command,
            timeout: timeout,
            standardInput: standardInput,
            outputCapture: outputCapture,
            cancellable: cancellable
        )
    }

    @discardableResult private func run(
        _ command: String,
        timeout: TimeInterval?,
        standardInput: Data? = nil,
        outputCapture: ProcessOutputCapture = .tail(maxBytes: Self.outputTailBytes),
        cancellable: Bool = true
    ) throws -> ProcessResult {
        let request = ProcessRequest(
            executableURL: executableURL,
            arguments: [
                "-o", "ProxyCommand=/usr/bin/nc -U '" + socketURL.path
                    .replacingOccurrences(of: "'", with: "'\\''")
                    .replacingOccurrences(of: "%", with: "%%") + "'",
                "-F", "/dev/null",
                "-i", privateKeyURL.path,
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=\(max(1, Int(min(timeout ?? 10, 10).rounded(.up))))",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=3",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "HostKeyAlias=\(Self.hostKeyAlias)",
                "-o", "IdentitiesOnly=yes",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "PasswordAuthentication=no",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(Self.configurationValue(knownHostsURL.path))",
                "runner@\(Self.hostKeyAlias)",
                // OpenSSH sends one command through the remote login shell.
                command,
            ],
            standardInput: standardInput,
            timeout: timeout,
            outputCapture: outputCapture,
            cancellable: cancellable
        )
        return try executor.execute(request).requireSuccess(for: request)
    }

    private static func configurationValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%")
        return "\"\(escaped)\""
    }

    private static func permissions(ofRegularFile url: URL) throws -> mode_t {
        let (descriptor, openError) = url.path.withCString { path in
            let descriptor = Darwin.open(
                path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            return (descriptor, descriptor >= 0 ? 0 : errno)
        }
        guard descriptor >= 0 else {
            throw MacOSGuestSSHError.fileOperationFailed(
                operation: "Opening the macOS guest SSH file",
                path: url.path,
                code: POSIXErrorCode(rawValue: openError) ?? .EIO
            )
        }
        defer { _ = Darwin.close(descriptor) }

        var fileStatus = stat()
        let result = Darwin.fstat(descriptor, &fileStatus)
        let errorNumber = result == 0 ? 0 : errno
        guard result == 0 else {
            throw MacOSGuestSSHError.fileOperationFailed(
                operation: "Inspecting the macOS guest SSH file",
                path: url.path,
                code: POSIXErrorCode(rawValue: errorNumber) ?? .EIO
            )
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            throw MacOSGuestSSHError.notRegularFile(path: url.path)
        }
        return fileStatus.st_mode & 0o777
    }
}

struct MacOSGuestConnection {
    static let readinessTimeout: TimeInterval = 60
    static let retryDelay: TimeInterval = 0.5
    static let sshAttemptTimeout: TimeInterval = 5

    private let checkTransport: (TimeInterval) throws -> Void
    private let validateGuest: (TimeInterval) throws -> Void
    private let currentTime: () -> TimeInterval

    init(
        ssh: MacOSGuestSSH,
        currentTime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        checkTransport = ssh.checkTransport
        validateGuest = ssh.validateGuest
        self.currentTime = currentTime
    }

    init(
        currentTime: @escaping () -> TimeInterval,
        checkTransport: @escaping (TimeInterval) throws -> Void,
        validateGuest: @escaping (TimeInterval) throws -> Void
    ) {
        self.currentTime = currentTime
        self.checkTransport = checkTransport
        self.validateGuest = validateGuest
    }

    func waitUntilReady(
        timeout: TimeInterval = Self.readinessTimeout,
        checkCancellation: () throws -> Void = {},
        wait: (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:)
    ) throws {
        precondition(timeout.isFinite && timeout > 0)
        let deadline = currentTime() + timeout
        try waitForSSH(
            deadline: deadline,
            attempt: checkTransport,
            shouldRetry: Self.isRetryableTransportFailure,
            timeoutError: MacOSGuestConnectionError.transportTimedOut,
            checkCancellation: checkCancellation,
            wait: wait
        )
        try waitForSSH(
            deadline: deadline,
            attempt: validateGuest,
            shouldRetry: { error in
                // The ready helper exits 1 until runner has a console and GUI session.
                if case let .nonZeroExit(_, result) = error, result.terminationStatus == 1 {
                    return true
                }
                return Self.isRetryableTransportFailure(error)
            },
            timeoutError: MacOSGuestConnectionError.guestReadinessTimedOut,
            checkCancellation: checkCancellation,
            wait: wait
        )
    }

    private func waitForSSH(
        deadline: TimeInterval,
        attempt: (TimeInterval) throws -> Void,
        shouldRetry: (ProcessExecutionError) -> Bool,
        timeoutError: (ProcessExecutionError?) -> MacOSGuestConnectionError,
        checkCancellation: () throws -> Void,
        wait: (TimeInterval) throws -> Void
    ) throws {
        var lastError: ProcessExecutionError?
        var readinessError: ProcessExecutionError?

        while true {
            try checkCancellation()
            let remaining = deadline - currentTime()
            guard remaining > 0 else {
                throw timeoutError(readinessError ?? lastError)
            }
            do {
                try attempt(min(Self.sshAttemptTimeout, remaining))
                return
            } catch let error as ProcessExecutionError {
                guard shouldRetry(error) else {
                    throw error
                }
                lastError = error
                if case let .nonZeroExit(_, result) = error, result.terminationStatus == 1 {
                    readinessError = error
                }
            }
            let remainingAfterAttempt = deadline - currentTime()
            if remainingAfterAttempt > 0 {
                try wait(min(Self.retryDelay, remainingAfterAttempt))
            }
        }
    }

    private static func isRetryableTransportFailure(
        _ error: ProcessExecutionError
    ) -> Bool {
        switch error {
        case .timedOut:
            true
        case let .nonZeroExit(_, result):
            result.terminationStatus == 255
        case .launchFailed, .inputWriteFailed, .outputReadFailed, .waitFailed,
             .cancelled, .executionDeadlineExceeded, .terminatedBySignal:
            false
        }
    }
}

enum MacOSGuestSSHError: Error, Equatable, LocalizedError {
    case invalidCommandArgument
    case insecurePrivateKey(path: String, permissions: mode_t)
    case insecureKnownHosts(path: String, permissions: mode_t)
    case notRegularFile(path: String)
    case fileOperationFailed(operation: String, path: String, code: POSIXErrorCode)

    var errorDescription: String? {
        switch self {
        case .invalidCommandArgument:
            "macOS guest command arguments must not contain NUL bytes."
        case let .insecurePrivateKey(path, permissions):
            "The macOS guest SSH private key at \(path) has permissions "
                + "\(String(permissions, radix: 8)); expected 600 or stricter."
        case let .insecureKnownHosts(path, permissions):
            "The macOS guest known-hosts file at \(path) has permissions "
                + "\(String(permissions, radix: 8)); it must not be group- or world-writable."
        case let .notRegularFile(path):
            "The macOS guest SSH file is not a regular file: \(path)"
        case let .fileOperationFailed(operation, path, code):
            "\(operation) failed for \(path): \(POSIXError(code).localizedDescription)"
        }
    }
}

enum MacOSGuestConnectionError: Error, LocalizedError {
    case transportTimedOut(lastError: ProcessExecutionError?)
    case guestReadinessTimedOut(lastError: ProcessExecutionError?)

    var errorDescription: String? {
        switch self {
        case let .transportTimedOut(lastError):
            if let lastError {
                "Timed out waiting for SSH on macOS guest \(MacOSGuestSSH.hostKeyAlias): \(describeError(lastError))"
            } else {
                "Timed out waiting for SSH on macOS guest \(MacOSGuestSSH.hostKeyAlias)."
            }
        case let .guestReadinessTimedOut(lastError):
            if let lastError {
                "Timed out waiting for the runner GUI session on macOS guest \(MacOSGuestSSH.hostKeyAlias): \(describeError(lastError))"
            } else {
                "Timed out waiting for the runner GUI session on macOS guest \(MacOSGuestSSH.hostKeyAlias)."
            }
        }
    }
}
