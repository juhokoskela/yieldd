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

    init(
        templateURL: URL,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        executor: any ProcessExecuting
    ) {
        self.executableURL = executableURL
        privateKeyURL = templateURL.appendingPathComponent(Self.privateKeyFilename)
        knownHostsURL = templateURL.appendingPathComponent(Self.knownHostsFilename)
        self.executor = executor
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

    func checkTransport(address: String, timeout: TimeInterval) throws {
        try run("/usr/bin/true", address: address, timeout: timeout)
    }

    func validateGuest(address: String, timeout: TimeInterval) throws {
        try run(
            "/Users/runner/bin/yieldd-runner-control ready",
            address: address,
            timeout: timeout
        )
    }

    private func run(
        _ command: String,
        address: String,
        timeout: TimeInterval
    ) throws {
        let request = ProcessRequest(
            executableURL: executableURL,
            arguments: [
                "-F", "/dev/null",
                "-i", privateKeyURL.path,
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=\(max(1, Int(timeout.rounded(.up))))",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "HostKeyAlias=\(Self.hostKeyAlias)",
                "-o", "IdentitiesOnly=yes",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "PasswordAuthentication=no",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(Self.configurationValue(knownHostsURL.path))",
                "runner@\(address)",
                // OpenSSH sends this through the remote login shell. Keep it fixed and argument-free.
                command,
            ],
            timeout: timeout,
            outputCapture: .tail(maxBytes: Self.outputTailBytes)
        )
        try executor.execute(request).requireSuccess(for: request)
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

    private let resolver: any MacOSGuestAddressResolving
    private let checkTransport: (String, TimeInterval) throws -> Void
    private let validateGuest: (String, TimeInterval) throws -> Void
    private let currentTime: () -> TimeInterval

    init(
        resolver: any MacOSGuestAddressResolving = MacOSGuestAddressResolver(),
        ssh: MacOSGuestSSH,
        currentTime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.resolver = resolver
        checkTransport = ssh.checkTransport
        validateGuest = ssh.validateGuest
        self.currentTime = currentTime
    }

    init(
        resolver: any MacOSGuestAddressResolving,
        currentTime: @escaping () -> TimeInterval,
        checkTransport: @escaping (String, TimeInterval) throws -> Void,
        validateGuest: @escaping (String, TimeInterval) throws -> Void
    ) {
        self.resolver = resolver
        self.currentTime = currentTime
        self.checkTransport = checkTransport
        self.validateGuest = validateGuest
    }

    func waitUntilReady(
        macAddress: String,
        timeout: TimeInterval = Self.readinessTimeout,
        checkCancellation: () throws -> Void = {},
        wait: (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:)
    ) throws -> String {
        precondition(timeout.isFinite && timeout > 0)
        let deadline = currentTime() + timeout
        let address = try waitForAddress(
            macAddress: macAddress,
            deadline: deadline,
            checkCancellation: checkCancellation,
            wait: wait
        )
        try waitForTransport(
            address: address,
            deadline: deadline,
            checkCancellation: checkCancellation,
            wait: wait
        )
        try checkCancellation()
        let remaining = deadline - currentTime()
        guard remaining > 0 else {
            throw MacOSGuestConnectionError.transportTimedOut(
                address: address,
                lastError: nil
            )
        }
        try validateGuest(address, min(Self.sshAttemptTimeout, remaining))
        return address
    }

    private func waitForAddress(
        macAddress: String,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void,
        wait: (TimeInterval) throws -> Void
    ) throws -> String {
        while true {
            try checkCancellation()
            let remaining = deadline - currentTime()
            guard remaining > 0 else {
                throw MacOSGuestConnectionError.addressTimedOut(macAddress: macAddress)
            }
            if let address = try resolver.address(for: macAddress) {
                return address
            }
            try wait(min(Self.retryDelay, remaining))
        }
    }

    private func waitForTransport(
        address: String,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void,
        wait: (TimeInterval) throws -> Void
    ) throws {
        var lastError: ProcessExecutionError?

        while true {
            try checkCancellation()
            let remaining = deadline - currentTime()
            guard remaining > 0 else {
                throw MacOSGuestConnectionError.transportTimedOut(
                    address: address,
                    lastError: lastError
                )
            }
            do {
                try checkTransport(address, min(Self.sshAttemptTimeout, remaining))
                return
            } catch let error as ProcessExecutionError {
                guard Self.isRetryableTransportFailure(error) else {
                    throw error
                }
                lastError = error
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
    case insecurePrivateKey(path: String, permissions: mode_t)
    case insecureKnownHosts(path: String, permissions: mode_t)
    case notRegularFile(path: String)
    case fileOperationFailed(operation: String, path: String, code: POSIXErrorCode)

    var errorDescription: String? {
        switch self {
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
    case addressTimedOut(macAddress: String)
    case transportTimedOut(address: String, lastError: ProcessExecutionError?)

    var errorDescription: String? {
        switch self {
        case let .addressTimedOut(macAddress):
            "Timed out waiting for a DHCP lease for macOS guest \(macAddress)."
        case let .transportTimedOut(address, lastError):
            if let lastError {
                "Timed out waiting for SSH on macOS guest \(address): \(describeError(lastError))"
            } else {
                "Timed out waiting for SSH on macOS guest \(address)."
            }
        }
    }
}
