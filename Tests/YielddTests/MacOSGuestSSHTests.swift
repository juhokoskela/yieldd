import Darwin
import Foundation
import Testing
@testable import Yieldd

private let sshURL = URL(fileURLWithPath: "/usr/bin/ssh")

@Test
func guestSSHBuildsCompleteTransportAndValidationCommands() throws {
    let template = try GuestSSHTemplateFixture()
    defer { template.remove() }
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .success(processResult()),
    ])
    let ssh = MacOSGuestSSH(
        templateURL: template.url,
        executableURL: sshURL,
        executor: executor
    )

    try ssh.checkTransport(address: "192.168.65.5", timeout: 4.25)
    try ssh.validateGuest(address: "192.168.65.5", timeout: 4.25)
    let knownHostsPath = template.knownHostsURL.path.replacingOccurrences(
        of: "%",
        with: "%%"
    )

    let arguments = [
        "-F", "/dev/null",
        "-i", template.privateKeyURL.path,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "HostKeyAlias=yieldd-macos-template",
        "-o", "IdentitiesOnly=yes",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=\"\(knownHostsPath)\"",
        "runner@192.168.65.5",
    ]
    func request(_ command: String) -> ProcessRequest {
        ProcessRequest(
            executableURL: sshURL,
            arguments: arguments + [command],
            timeout: 4.25,
            outputCapture: .tail(maxBytes: MacOSGuestSSH.outputTailBytes)
        )
    }

    #expect(executor.requests == [
        request("/usr/bin/true"),
        request("/Users/runner/bin/yieldd-runner-control ready"),
    ])
}

@Test
func guestSSHExecPreservesArgumentsAndKeepsSecretsOnStdin() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let ssh = MacOSGuestSSH(templateURL: URL(fileURLWithPath: "/unused"), executor: executor)
    let arguments = ["", "a b", "a'b", "$(touch /never-run)", "`exit 1`", "line\nbreak", "\\", "--flag"]
    try ssh.execute(
        ["/usr/bin/printf", "%s\\000"] + arguments,
        address: "192.168.64.2",
        standardInput: Data("secret-token\n".utf8),
        timeout: nil,
        outputCapture: .tail(maxBytes: 1024),
        cancellable: false
    )
    let request = try #require(executor.requests.first)
    #expect(request.standardInput == Data("secret-token\n".utf8))
    #expect(!request.arguments.joined().contains("secret-token"))
    #expect(request.timeout == nil)
    #expect(!request.cancellable)
    #expect(request.outputCapture == .tail(maxBytes: 1024))
    let command = try #require(request.arguments.last)
    let result = try ProcessExecutor().execute(ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], timeout: 5
    ))
    #expect(result.terminationStatus == 0)
    #expect(result.stdout == Data((arguments.joined(separator: "\0") + "\0").utf8))
}

@Test
func guestSSHRejectsNULArgumentsBeforeLaunching() throws {
    let executor = RecordingProcessExecutor(outcomes: [])
    let ssh = MacOSGuestSSH(templateURL: URL(fileURLWithPath: "/unused"), executor: executor)
    #expect(throws: MacOSGuestSSHError.invalidCommandArgument) {
        try ssh.execute(["printf", "a\0b"], address: "192.168.64.2", timeout: 5, outputCapture: .all)
    }
    #expect(executor.requests.isEmpty)
}

@Test(arguments: [[], [""]])
func guestSSHRejectsEmptyCommandsBeforeLaunching(arguments: [String]) {
    let executor = RecordingProcessExecutor(outcomes: [])
    let ssh = MacOSGuestSSH(templateURL: URL(fileURLWithPath: "/unused"), executor: executor)
    #expect(throws: RunnerBackendError.emptyCommand) {
        try ssh.execute(arguments, address: "192.168.64.2", timeout: 5, outputCapture: .all)
    }
    #expect(executor.requests.isEmpty)
}

@Test
func guestSSHRejectsSymlinkedTemplateCredentials() throws {
    let template = try GuestSSHTemplateFixture()
    defer { template.remove() }
    try FileManager.default.removeItem(at: template.privateKeyURL)
    try FileManager.default.createSymbolicLink(
        at: template.privateKeyURL,
        withDestinationURL: template.knownHostsURL
    )

    do {
        try MacOSGuestSSH.validateTemplate(at: template.url)
        Issue.record("Expected the symbolic link to be rejected")
    } catch let MacOSGuestSSHError.fileOperationFailed(_, path, code) {
        #expect(path == template.privateKeyURL.path)
        #expect(code == .ELOOP)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func guestSSHValidatesPrivateTemplateCredentials() throws {
    let template = try GuestSSHTemplateFixture()
    defer { template.remove() }

    try MacOSGuestSSH.validateTemplate(at: template.url)

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: template.privateKeyURL.path
    )
    #expect(throws: MacOSGuestSSHError.insecurePrivateKey(
        path: template.privateKeyURL.path,
        permissions: 0o644
    )) {
        try MacOSGuestSSH.validateTemplate(at: template.url)
    }

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: template.privateKeyURL.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o666],
        ofItemAtPath: template.knownHostsURL.path
    )
    #expect(throws: MacOSGuestSSHError.insecureKnownHosts(
        path: template.knownHostsURL.path,
        permissions: 0o666
    )) {
        try MacOSGuestSSH.validateTemplate(at: template.url)
    }
}

@Test
func guestConnectionWaitsForDHCPAndRetriesSSHTransport() throws {
    let resolver = StubGuestAddressResolver(addresses: [nil, "192.168.65.5"])
    let clock = GuestConnectionClock()
    var transportAttempts = 0
    var validationAttempts = 0
    let retryError = sshFailure()
    let connection = MacOSGuestConnection(
        resolver: resolver,
        currentTime: clock.read,
        checkTransport: { address, timeout in
            #expect(address == "192.168.65.5")
            #expect(timeout == MacOSGuestConnection.sshAttemptTimeout)
            transportAttempts += 1
            if transportAttempts == 1 {
                throw retryError
            }
        },
        validateGuest: { address, timeout in
            #expect(address == "192.168.65.5")
            #expect(timeout == MacOSGuestConnection.sshAttemptTimeout)
            validationAttempts += 1
        }
    )

    let address = try connection.waitUntilReady(
        macAddress: "02:00:00:00:00:0f",
        checkCancellation: {},
        wait: clock.wait
    )

    #expect(address == "192.168.65.5")
    #expect(resolver.calls == 2)
    #expect(transportAttempts == 2)
    #expect(validationAttempts == 1)
    #expect(clock.waits == [0.5, 0.5])
}

@Test
func guestConnectionWaitsForTheRunnerGUISessionAfterSSHIsReady() throws {
    let clock = GuestConnectionClock()
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .success(processResult(stderr: "the runner account is not logged in", status: 1)),
        .success(processResult(stderr: "the runner GUI launchd domain is unavailable", status: 1)),
        .success(processResult()),
    ])
    let connection = MacOSGuestConnection(
        resolver: StubGuestAddressResolver(addresses: ["192.168.65.5"]),
        ssh: MacOSGuestSSH(templateURL: URL(fileURLWithPath: "/unused"), executor: executor),
        currentTime: clock.read
    )

    let address = try connection.waitUntilReady(
        macAddress: "02:00:00:00:00:0f",
        wait: clock.wait
    )

    #expect(address == "192.168.65.5")
    #expect(clock.waits == [0.5, 0.5])
    #expect(executor.requests.map { $0.arguments.last } == [
        "/usr/bin/true",
        "/Users/runner/bin/yieldd-runner-control ready",
        "/Users/runner/bin/yieldd-runner-control ready",
        "/Users/runner/bin/yieldd-runner-control ready",
    ])
}

@Test
func guestConnectionTimesOutWhileWaitingForDHCP() throws {
    let resolver = StubGuestAddressResolver(addresses: [nil])
    let clock = GuestConnectionClock()
    let connection = MacOSGuestConnection(
        resolver: resolver,
        currentTime: clock.read,
        checkTransport: { _, _ in Issue.record("SSH must not run without an address") },
        validateGuest: { _, _ in Issue.record("Guest validation must not run") }
    )

    do {
        _ = try connection.waitUntilReady(
            macAddress: "02:00:00:00:00:0f",
            timeout: 1,
            wait: clock.wait
        )
        Issue.record("Expected address resolution to time out")
    } catch let MacOSGuestConnectionError.addressTimedOut(macAddress) {
        #expect(macAddress == "02:00:00:00:00:0f")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(clock.waits == [0.5, 0.5])
}

@Test
func guestConnectionPreservesTheLastTransportFailureOnTimeout() throws {
    let resolver = StubGuestAddressResolver(addresses: ["192.168.65.5"])
    let clock = GuestConnectionClock()
    let retryError = sshFailure()
    var transportAttempts = 0
    let connection = MacOSGuestConnection(
        resolver: resolver,
        currentTime: clock.read,
        checkTransport: { _, _ in
            transportAttempts += 1
            throw retryError
        },
        validateGuest: { _, _ in Issue.record("Guest validation must not run") }
    )

    do {
        _ = try connection.waitUntilReady(
            macAddress: "02:00:00:00:00:0f",
            timeout: 1,
            wait: clock.wait
        )
        Issue.record("Expected SSH transport to time out")
    } catch let MacOSGuestConnectionError.transportTimedOut(address, lastError) {
        #expect(address == "192.168.65.5")
        #expect(lastError != nil)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(transportAttempts == 2)
    #expect(clock.waits == [0.5, 0.5])
}

@Test
func guestConnectionDoesNotRetryExitStatusOneDuringTransport() throws {
    let clock = GuestConnectionClock()
    var attempts = 0
    let connection = MacOSGuestConnection(
        resolver: StubGuestAddressResolver(addresses: ["192.168.65.5"]),
        currentTime: clock.read,
        checkTransport: { _, _ in
            attempts += 1
            throw sshFailure(status: 1, stderr: "transport failed")
        },
        validateGuest: { _, _ in Issue.record("Guest validation must not run") }
    )

    do {
        _ = try connection.waitUntilReady(macAddress: "02:00:00:00:00:0f", wait: clock.wait)
        Issue.record("Expected SSH transport to fail")
    } catch let ProcessExecutionError.nonZeroExit(_, result) {
        #expect(result.terminationStatus == 1)
        #expect(result.stderrText == "transport failed")
    }
    #expect(attempts == 1)
    #expect(clock.waits.isEmpty)
}

@Test
func guestConnectionDoesNotRetryLocalTransportFailure() throws {
    let resolver = StubGuestAddressResolver(addresses: ["192.168.65.5"])
    let clock = GuestConnectionClock()
    let request = ProcessRequest(executableURL: sshURL, arguments: [])
    let connection = MacOSGuestConnection(
        resolver: resolver,
        currentTime: clock.read,
        checkTransport: { _, _ in
            throw ProcessExecutionError.waitFailed(
                request: request,
                underlying: TestFailure.create
            )
        },
        validateGuest: { _, _ in Issue.record("Guest validation must not run") }
    )

    do {
        _ = try connection.waitUntilReady(
            macAddress: "02:00:00:00:00:0f",
            wait: clock.wait
        )
        Issue.record("Expected the local SSH wait to fail")
    } catch let ProcessExecutionError.waitFailed(actualRequest, _) {
        #expect(actualRequest == request)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(clock.waits.isEmpty)
}

@Test(arguments: [Int32(2), 126, 127])
func guestConnectionPropagatesGuestValidationFailureWithoutRetry(status: Int32) throws {
    let resolver = StubGuestAddressResolver(addresses: ["192.168.65.5"])
    let clock = GuestConnectionClock()
    let validationError = sshFailure(status: status)
    var transportAttempts = 0
    var validationAttempts = 0
    let connection = MacOSGuestConnection(
        resolver: resolver,
        currentTime: clock.read,
        checkTransport: { _, _ in transportAttempts += 1 },
        validateGuest: { _, _ in
            validationAttempts += 1
            throw validationError
        }
    )

    do {
        _ = try connection.waitUntilReady(
            macAddress: "02:00:00:00:00:0f",
            wait: clock.wait
        )
        Issue.record("Expected guest validation to fail")
    } catch let ProcessExecutionError.nonZeroExit(_, result) {
        #expect(result.terminationStatus == status)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(transportAttempts == 1)
    #expect(validationAttempts == 1)
    #expect(clock.waits.isEmpty)
}

@Test
func guestConnectionReadinessSharesTheDHCPAndSSHDeadline() throws {
    let clock = GuestConnectionClock()
    var transportAttempts = 0
    var validationTimeouts: [TimeInterval] = []
    let diagnostic = "the runner GUI launchd domain is unavailable; enable automatic login for runner"
    let connection = MacOSGuestConnection(
        resolver: StubGuestAddressResolver(addresses: [nil, "192.168.65.5"]),
        currentTime: clock.read,
        checkTransport: { _, _ in
            transportAttempts += 1
            if transportAttempts == 1 { throw sshFailure() }
        },
        validateGuest: { _, timeout in
            validationTimeouts.append(timeout)
            if timeout < 0.5 {
                clock.wait(timeout)
                throw ProcessExecutionError.timedOut(
                    request: ProcessRequest(executableURL: sshURL, arguments: [], timeout: timeout), result: processResult())
            }
            throw sshFailure(status: 1, stderr: diagnostic)
        }
    )

    do {
        _ = try connection.waitUntilReady(
            macAddress: "02:00:00:00:00:0f",
            timeout: 1.75,
            wait: clock.wait
        )
        Issue.record("Expected guest readiness to time out")
    } catch let error as MacOSGuestConnectionError {
        guard case let .guestReadinessTimedOut(address, lastError) = error else {
            Issue.record("Unexpected connection error: \(error)")
            return
        }
        #expect(address == "192.168.65.5")
        #expect(lastError != nil)
        #expect(error.localizedDescription.contains(diagnostic))
    }
    #expect(transportAttempts == 2)
    #expect(validationTimeouts == [0.75, 0.25])
    #expect(clock.waits == [0.5, 0.5, 0.5, 0.25])
    #expect(clock.value == 1.75)
}

@Test
func guestConnectionRetriesTransportFailuresDuringReadiness() throws {
    let clock = GuestConnectionClock()
    let request = ProcessRequest(executableURL: sshURL, arguments: [], timeout: 5)
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .failure(ProcessExecutionError.timedOut(request: request, result: processResult())),
        .success(processResult(stderr: "connection refused", status: 255)),
        .success(processResult()),
    ])
    let connection = MacOSGuestConnection(
        resolver: StubGuestAddressResolver(addresses: ["192.168.65.5"]),
        ssh: MacOSGuestSSH(templateURL: URL(fileURLWithPath: "/unused"), executor: executor),
        currentTime: clock.read
    )

    #expect(try connection.waitUntilReady(
        macAddress: "02:00:00:00:00:0f", wait: clock.wait
    ) == "192.168.65.5")
    #expect(executor.requests.count == 4)
    #expect(clock.waits == [0.5, 0.5])
}

@Test
func guestConnectionCancellationStopsGUIPolling() throws {
    let clock = GuestConnectionClock()
    var validationAttempts = 0
    let connection = MacOSGuestConnection(
        resolver: StubGuestAddressResolver(addresses: ["192.168.65.5"]),
        currentTime: clock.read,
        checkTransport: { _, _ in },
        validateGuest: { _, _ in
            validationAttempts += 1
            throw sshFailure(status: 1)
        }
    )

    #expect(throws: SignalInterruption(signal: SIGTERM)) {
        _ = try connection.waitUntilReady(
            macAddress: "02:00:00:00:00:0f",
            checkCancellation: {
                if validationAttempts > 0 { throw SignalInterruption(signal: SIGTERM) }
            },
            wait: clock.wait
        )
    }
    #expect(validationAttempts == 1)
    #expect(clock.waits == [0.5])
}

@Test
func guestConnectionPreservesReadinessProcessCancellation() throws {
    let clock = GuestConnectionClock()
    let request = ProcessRequest(executableURL: sshURL, arguments: [])
    let connection = MacOSGuestConnection(
        resolver: StubGuestAddressResolver(addresses: ["192.168.65.5"]),
        currentTime: clock.read,
        checkTransport: { _, _ in },
        validateGuest: { _, _ in
            throw ProcessExecutionError.cancelled(
                request: request, result: processResult(), underlying: SignalInterruption(signal: SIGTERM)
            )
        }
    )

    do {
        _ = try connection.waitUntilReady(macAddress: "02:00:00:00:00:0f", wait: clock.wait)
        Issue.record("Expected guest readiness to be cancelled")
    } catch let ProcessExecutionError.cancelled(actualRequest, _, underlying) {
        #expect(actualRequest == request)
        #expect(underlying as? SignalInterruption == SignalInterruption(signal: SIGTERM))
    }
    #expect(clock.waits.isEmpty)
}

@Test
func guestConnectionCancellationStopsDHCPPolling() throws {
    let resolver = StubGuestAddressResolver(addresses: [nil])
    let clock = GuestConnectionClock()
    var cancellationChecks = 0
    let connection = MacOSGuestConnection(
        resolver: resolver,
        currentTime: clock.read,
        checkTransport: { _, _ in Issue.record("SSH must not run without an address") },
        validateGuest: { _, _ in Issue.record("Guest validation must not run") }
    )

    #expect(throws: SignalInterruption(signal: SIGTERM)) {
        _ = try connection.waitUntilReady(
            macAddress: "02:00:00:00:00:0f",
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 2 {
                    throw SignalInterruption(signal: SIGTERM)
                }
            },
            wait: clock.wait
        )
    }
    #expect(clock.waits == [0.5])
}

@Test(arguments: ["configure-runner", "runner-control"])
func macOSGuestScriptsAreExecutableAndParseAsBash(filename: String) throws {
    let scriptURL = repositoryRoot
        .appendingPathComponent("Guest/macOS/\(filename)", isDirectory: false)
    #expect(FileManager.default.isExecutableFile(atPath: scriptURL.path))

    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-n", scriptURL.path]
    )
    try ProcessExecutor().execute(request).requireSuccess(for: request)
}

private func sshFailure(status: Int32 = 255, stderr: String = "connection refused") -> ProcessExecutionError {
    let request = ProcessRequest(executableURL: sshURL, arguments: [])
    return .nonZeroExit(
        request: request,
        result: processResult(stderr: stderr, status: status)
    )
}

private struct GuestSSHTemplateFixture {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "yieldd guest ssh %x \(UUID().uuidString)",
        isDirectory: true
    )

    var privateKeyURL: URL {
        url.appendingPathComponent(MacOSGuestSSH.privateKeyFilename)
    }

    var knownHostsURL: URL {
        url.appendingPathComponent(MacOSGuestSSH.knownHostsFilename)
    }

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("private-key".utf8).write(to: privateKeyURL)
        try Data("known-host".utf8).write(to: knownHostsURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: knownHostsURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class StubGuestAddressResolver: MacOSGuestAddressResolving {
    private var addresses: [String?]
    private(set) var calls = 0

    init(addresses: [String?]) {
        self.addresses = addresses
    }

    func address(for _: String) throws -> String? {
        calls += 1
        guard addresses.count > 1 else {
            return addresses.first ?? nil
        }
        return addresses.removeFirst()
    }
}

private final class GuestConnectionClock {
    private(set) var value: TimeInterval = 0
    private(set) var waits: [TimeInterval] = []

    func read() -> TimeInterval {
        value
    }

    func wait(_ interval: TimeInterval) {
        waits.append(interval)
        value += interval
    }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
