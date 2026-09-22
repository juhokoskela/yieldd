import Darwin
import Foundation
import Testing
@testable import Yieldd

@Suite struct RunnerNetworkRelayTests {
    @Test func readinessAndIdempotentShutdown() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("printf '%s\\n' '\(RelayProcessFixture.ready)'\nexec /bin/cat >/dev/null")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.root)
        let directory = relay.socketURL.deletingLastPathComponent()
        #expect(relay.sshPort == 12345)
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
        let executable = try fixture.script("printf '%s\\n' '\(payload)'\nexec /bin/cat >/dev/null")
        do {
            _ = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.root)
            Issue.record("Accepted invalid relay readiness")
        } catch RunnerNetworkRelayError.invalidReadiness {}
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func startupTimeoutReapsChild() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("exec /bin/cat >/dev/null")
        do {
            _ = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.root, startupTimeout: 0.1)
            Issue.record("Accepted a relay without readiness")
        } catch RunnerNetworkRelayError.startupTimedOut {}
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func cancellationDuringStartupReapsChild() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("exec /bin/cat >/dev/null")
        struct Cancelled: Error {}
        do {
            _ = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.root, checkCancellation: {
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
            try RunnerNetworkRelay.start(executableURL: fixture.root.appendingPathComponent("absent"), directory: fixture.root)
        }
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func forceStopsAChildIgnoringEOFAndTERM() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("trap '' TERM\nprintf '%s\\n' '\(RelayProcessFixture.ready)'\nexec /usr/bin/tail -f /dev/null")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.root)
        try relay.stop()
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func droppingTheOwnerStopsItsChild() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("printf '%s\\n' '\(RelayProcessFixture.ready)'\nexec /bin/cat >/dev/null")
        do {
            let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.root)
            try relay.check()
            withExtendedLifetime(relay) {}
        }
        try fixture.requireExited()
        #expect(try fixture.relayDirectories().isEmpty)
    }

    @Test func reportsUnexpectedExitAndStillCleansUp() throws {
        let fixture = try RelayProcessFixture()
        defer { fixture.remove() }
        let executable = try fixture.script("printf '%s\\n' '\(RelayProcessFixture.ready)'\nexec /bin/cat >/dev/null")
        let relay = try RunnerNetworkRelay.start(executableURL: executable, directory: fixture.root)
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YIELDD_TEST_RELAY"] != nil))
    func actualRelayHandshakeAndShutdown() throws {
        let executable = try #require(ProcessInfo.processInfo.environment["YIELDD_TEST_RELAY"])
        let relay = try RunnerNetworkRelay.start(executableURL: URL(fileURLWithPath: executable))
        defer { try? relay.stop() }
        try relay.check()
        #expect(relay.sshPort > 0)
        var info = stat()
        #expect(lstat(relay.socketURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        try relay.stop()
        #expect(!FileManager.default.fileExists(atPath: relay.socketURL.deletingLastPathComponent().path))
    }
}

private struct RelayProcessFixture {
    static let ready = "{\"version\":1,\"ssh\":\"127.0.0.1:12345\"}"
    let root: URL
    var pid: URL { root.appendingPathComponent("pid") }

    init() throws {
        var parent = FileManager.default.temporaryDirectory
        if parent.path.utf8.count + 48 >= 104 { parent = URL(fileURLWithPath: "/tmp") }
        root = parent.appendingPathComponent("yrt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func script(_ body: String) throws -> URL {
        let url = root.appendingPathComponent("relay")
        let pidPath = pid.path.replacingOccurrences(of: "'", with: "'\\''")
        try Data("#!/bin/sh\necho $$ > '\(pidPath)'\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func relayDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("yieldd-net-") }
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
