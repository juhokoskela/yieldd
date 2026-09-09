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

@Test
func guestConnectionPropagatesGuestValidationFailureWithoutRetry() throws {
    let resolver = StubGuestAddressResolver(addresses: ["192.168.65.5"])
    let clock = GuestConnectionClock()
    let validationError = sshFailure(status: 1)
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
        #expect(result.terminationStatus == 1)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(transportAttempts == 1)
    #expect(validationAttempts == 1)
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

private func sshFailure(status: Int32 = 255) -> ProcessExecutionError {
    let request = ProcessRequest(executableURL: sshURL, arguments: [])
    return .nonZeroExit(
        request: request,
        result: processResult(stderr: "connection refused", status: status)
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
