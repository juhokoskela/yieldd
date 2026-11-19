import Darwin
import Foundation
import Testing
@testable import Yieldd

@Suite struct RunnerNetworkRelayTests {
    @Test(arguments: [RunnerPlatform.linux, .macOS])
    func networkBindsDiagnosticsToGuestPlatform(platform: RunnerPlatform) throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let directories = try RunnerNetworkDirectories(stateDirectory: fixture.root)
        defer { try? FileManager.default.removeItem(at: directories.rootURL) }
        let id = RunnerID(value: "yieldd-diagnostic-platform")
        let directory = try directories.create(for: id)
        let arguments = fixture.root.appendingPathComponent("arguments")
        let ready = "{\"version\":2,\"ssh\":\"\(directory.appendingPathComponent("n.ssh").path)\"}"
        let executable = try fixture.script("printf '%s\\n' \"$@\" > '\(arguments.path)'\nprintf '%s\\n' '\(ready)'\nexec /bin/cat")
        let network = try RunnerNetwork(stateDirectory: fixture.root, platform: platform, executableURL: executable)
        let relay = try network.start(for: id, checkCancellation: {})
        defer { try? relay.stop(deadline: nil) }
        let captured = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(captured == ["--socket", relay.socketURL.path, "--runner", id.value, "--platform", platform.rawValue.lowercased()])
    }

    @Test(arguments: [("linux", "linux"), ("macOS", "macos"), ("macos", "macos")])
    func forwardsDiagnosticIdentityAsSeparateArguments(platform: String, expected: String) throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let arguments = fixture.root.appendingPathComponent("arguments")
        let executable = try fixture.script("printf '%s\\n' \"$@\" > '\(arguments.path)'\nprintf '%s\\n' '\(fixture.ready)'\nexec /bin/cat")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory,
            identity: (runner: "yieldd-diagnostic-test", platform: platform))
        defer { try? relay.stop() }
        let captured = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(captured == ["--socket", relay.socketURL.path, "--runner", "yieldd-diagnostic-test", "--platform", expected])
    }

    @Test func shutdownToleratesAnAlreadyRemovedDirectory() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("printf '%s\\n' '\(fixture.ready)'\nexec /bin/cat")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
        try FileManager.default.removeItem(at: fixture.directory)
        try relay.stop()
        try relay.stop()
        try fixture.requireExited()
    }

    @Test func readinessAndIdempotentShutdown() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("printf '%s\\n' '\(fixture.ready)'\nexec /bin/cat")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
        let directory = relay.socketURL.deletingLastPathComponent()
        #expect(relay.sshSocketURL == fixture.directory.appendingPathComponent("n.ssh"))
        try relay.check()
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        try relay.stop()
        try relay.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: RunnerNetworkRelayError.self) { try relay.check() }
        try fixture.requireExited()
    }

    @Test(arguments: [
        "not JSON", "{\"version\":2,\"ssh\":\"127.0.0.1:12345\"}",
        "{\"version\":1,\"ssh\":\"192.168.1.1:22\"}",
        "{\"version\":1,\"ssh\":\"127.0.0.1:0\"}",
        "{\"version\":1,\"ssh\":\"127.0.0.1:65536\"}", String(repeating: "x", count: 1_025),
    ])
    func rejectsReadinessAndReapsChild(payload: String) throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("printf '%s\\n' '\(payload)'\nexec /bin/cat")
        do {
            _ = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
            Issue.record("Accepted invalid relay readiness")
        } catch RunnerNetworkRelayError.invalidReadiness {}
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func startupTimeoutReapsChild() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("exec /bin/cat")
        do {
            _ = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory, startupTimeout: 0.1)
            Issue.record("Accepted a relay without readiness")
        } catch RunnerNetworkRelayError.startupTimedOut {}
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func closedReadinessPipeReapsChild() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("exec /bin/cat >/dev/null")
        do {
            _ = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
            Issue.record("Accepted a relay that closed readiness without a response")
        } catch RunnerNetworkRelayError.invalidReadiness {}
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func cancellationDuringStartupReapsChild() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("exec /bin/cat")
        struct Cancelled: Error {}
        do {
            _ = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory, checkCancellation: {
                if FileManager.default.fileExists(atPath: fixture.pid.path) { throw Cancelled() }
            })
            Issue.record("Startup ignored cancellation")
        } catch is Cancelled {}
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func launchFailureRemovesSocketDirectory() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        #expect(throws: (any Error).self) {
            try RunnerNetworkRelay.start(executableURL: fixture.root.appendingPathComponent("absent"), directory: fixture.directory)
        }
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func forceStopsAChildIgnoringEOFAndTERM() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("trap '' TERM\nprintf '%s\\n' '\(fixture.ready)'\nexec /usr/bin/tail -f /dev/null")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
        try relay.stop()
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func droppingTheOwnerStopsItsChild() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("printf '%s\\n' '\(fixture.ready)'\nexec /bin/cat")
        do {
            let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
            try relay.check()
            withExtendedLifetime(relay) {}
        }
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func droppingOwnerAfterAnExpiredStopStillCleansUp() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("trap '' TERM\nprintf '%s\\n' '\(fixture.ready)'\nexec /usr/bin/tail -f /dev/null")
        var relay: RunnerNetworkRelay? = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
        do { try #require(relay).stop(deadline: .now()) }
        catch RunnerNetworkRelayError.stopTimedOut {}
        relay = nil
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test(arguments: [0.0, 0.1])
    func shutdownRespectsTheRemainingBudget(seconds: TimeInterval) throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("trap '' TERM\nprintf '%s\\n' '\(fixture.ready)'\nexec /usr/bin/tail -f /dev/null")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
        defer { try? relay.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try relay.stop(deadline: .now() + seconds)
            #expect(try fixture.relayDirectories().isEmpty)
        } catch RunnerNetworkRelayError.stopTimedOut {
            #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < seconds + 0.25)
        // A later cleanup attempt gets a fresh budget and confirms termination.
        try relay.stop()
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func doesNotAdoptOrRemoveNonemptyDirectory() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let retained = fixture.directory.appendingPathComponent("retained")
        try Data("existing".utf8).write(to: retained)
        #expect(throws: POSIXError(.ENOTEMPTY)) {
            try RunnerNetworkRelay.start(executableURL: URL(fileURLWithPath: "/usr/bin/true"), directory: fixture.directory)
        }
        #expect(try String(contentsOf: retained, encoding: .utf8) == "existing")
    }

    @Test func reportsUnexpectedExitAndStillCleansUp() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("printf '%s\\n' '\(fixture.ready)'\nexec /bin/cat")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.directory)
        defer { try? relay.stop() }
        #expect(kill(try fixture.processID(), SIGKILL) == 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            do { try relay.check() } catch RunnerNetworkRelayError.exited(let status) {
                #expect(status == SIGKILL)
                break
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("Relay death was not reported")
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try relay.stop()
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YIELDD_TEST_RELAY"] != nil), arguments: [false, true])
    func actualRelayHandshakeAndShutdown(expiredDeadline: Bool) throws {
        let executable = try #require(ProcessInfo.processInfo.environment["YIELDD_TEST_RELAY"])
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let relay = try RunnerNetworkRelay.start(executableURL: URL(fileURLWithPath: executable), directory: fixture.directory,
            identity: (runner: "yieldd-diagnostic-test", platform: "macos"))
        defer { try? relay.stop() }
        try relay.check()
        #expect(FileManager.default.fileExists(atPath: relay.sshSocketURL.path))
        var info = stat()
        #expect(lstat(relay.socketURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        if expiredDeadline {
            do { try relay.stop(deadline: .now()) }
            catch RunnerNetworkRelayError.stopTimedOut {}
        }
        try relay.stop()
        #expect(!FileManager.default.fileExists(atPath: relay.socketURL.deletingLastPathComponent().path))
    }
}

private struct RelayProcessFixture {
    var ready: String { "{\"version\":2,\"ssh\":\"\(directory.path)/n.ssh\"}" }
    let root: URL
    var directory: URL { root.appendingPathComponent("net") }
    var pid: URL { root.appendingPathComponent("pid") }

    init() throws {
        var parent = FileManager.default.temporaryDirectory
        if parent.path.utf8.count + 48 >= 104 { parent = URL(fileURLWithPath: "/tmp") }
        root = parent.appendingPathComponent("yrt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func script(_ body: String) throws -> URL {
        let url = root.appendingPathComponent("relay")
        let pidPath = pid.path.replacingOccurrences(of: "'", with: "'\\''")
        try Data("#!/bin/sh\necho $$ > '\(pidPath)'\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func relayDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 == "net" }
    }

    func processID() throws -> Int32 {
        let value = try String(contentsOf: pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int32(value))
    }

    func requireExited() throws {
        let child = try processID()
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
