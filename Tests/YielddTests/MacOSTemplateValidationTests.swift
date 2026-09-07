import Foundation
import Testing
@testable import Yieldd

// Limit subprocess load so these fixtures do not starve concurrent lifecycle tests.
@Suite(.serialized)
struct MacOSTemplateValidationTests {
    @Test(arguments: [false, true], [false, true])
    func simulatorSelectionAcceptsAnyAvailableCompatiblePair(reverseRuntimes: Bool, reverseDevices: Bool) throws {
        let fixture = try SimulatorScriptFixture()
        defer { fixture.remove() }
        var runtimes = [
            SimulatorRuntime("iOS-18-0", devices: ["iPhone-16", "iPhone-16-Pro", "iPad-Pro"]),
            SimulatorRuntime("iOS-26-0", devices: ["iPad-Air", "iPhone-17", "iPhone-17-Pro"]),
            SimulatorRuntime("iOS-27-0", available: false, devices: ["iPhone-18"]),
            SimulatorRuntime("tvOS-26-0", devices: ["Apple-TV"]),
            SimulatorRuntime("iOS-17-0", devices: ["iPad-Pro"]),
        ]
        if reverseRuntimes { runtimes.reverse() }
        if reverseDevices {
            for index in runtimes.indices { runtimes[index].supportedDeviceTypes.reverse() }
        }
        try JSONEncoder().encode(SimulatorMetadata(runtimes: runtimes)).write(to: fixture.metadata)
        let result = try fixture.select()
        #expect(result.terminationStatus == 0)
        let allowed = Set([
            "iOS-18-0 iPhone-16", "iOS-18-0 iPhone-16-Pro",
            "iOS-26-0 iPhone-17", "iOS-26-0 iPhone-17-Pro",
        ].map { pair in
            let parts = pair.split(separator: " ")
            return "com.apple.CoreSimulator.SimRuntime.\(parts[0]) com.apple.CoreSimulator.SimDeviceType.\(parts[1])"
        })
        #expect(allowed.contains(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test(arguments: [
        "missing", "{", "null", "{}", #"{"runtimes":{}}"#,
        #"{"runtimes":[null]}"#,
        #"{"runtimes":[{"identifier":42,"isAvailable":true}]}"#,
        #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-0","isAvailable":true}]}"#,
    ])
    func simulatorSelectionDiagnosesMetadataFailures(metadata: String) throws {
        let fixture = try SimulatorScriptFixture()
        defer { fixture.remove() }
        if metadata != "missing" { try Data(metadata.utf8).write(to: fixture.metadata) }
        let result = try fixture.select()
        #expect(result.terminationStatus != 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderrText.contains(metadata == "missing"
            ? "Could not read simulator runtime metadata"
            : "Malformed simulator runtime metadata"))
        #expect(!result.stderrText.contains("No available compatible iPhone simulator"))
    }

    @Test
    func simulatorSelectionReportsNoCompatibleAvailablePair() throws {
        let fixture = try SimulatorScriptFixture()
        defer { fixture.remove() }
        try JSONEncoder().encode(SimulatorMetadata(runtimes: [
            SimulatorRuntime("iOS-26-0", available: false, devices: ["iPhone-17"]),
            SimulatorRuntime("iOS-18-0", devices: ["iPad-Pro"]),
            SimulatorRuntime("tvOS-26-0", devices: ["Apple-TV"]),
        ])).write(to: fixture.metadata)
        let result = try fixture.select()
        #expect(result.terminationStatus != 0)
        #expect(result.stderrText.contains("No available compatible iPhone simulator was found"))
        #expect(!result.stderrText.contains("Malformed simulator runtime metadata"))
    }

    @Test(arguments: ["success", "xcode-version", "first-launch", "swift-version", "find-simctl", "list", "metadata", "create", "bootstatus", "screenshot", "empty-screenshot"])
    func templateValidationExecutesComposedScriptAndPropagatesFailures(failure: String) throws {
        let fixture = try SimulatorScriptFixture()
        defer { fixture.remove() }
        let log = fixture.directory.appendingPathComponent("commands.log")
        let simctl = fixture.directory.appendingPathComponent("simctl")
        let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
        let deviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
        let metadata = failure == "metadata" ? "{" : String(decoding: try JSONEncoder().encode(
            SimulatorMetadata(runtimes: [SimulatorRuntime("iOS-26-0", devices: ["iPhone-17"])])
        ), as: UTF8.self)
        let prelude = #"""
        #!/bin/bash
        set -euo pipefail
        record() {
            printf '%s\n' "$1" >> '\#(log.path)'
            if [[ "$1" == '\#(failure)' ]]; then exit 7; fi
        }
        """# + "\n"
        let xcodebuild = try fixture.executable("xcodebuild", script: prelude + #"""
        case "$*" in
            -version) record xcode-version ;;
            -checkFirstLaunchStatus) record first-launch ;;
            *) exit 99 ;;
        esac
        """#)
        let xcrun = try fixture.executable("xcrun", script: prelude + #"""
        case "$*" in
            'swift --version') record swift-version ;;
            '--find simctl') record find-simctl; printf '%s\n' '\#(simctl.path)' ;;
            *) exit 99 ;;
        esac
        """#)
        let mktemp = try fixture.executable("mktemp", script: prelude + #"""
        [[ "$*" == '-d /tmp/yieldd-template-test.XXXXXX' ]] || exit 99
        printf '%s\n' '\#(fixture.directory.path)'
        """#)
        _ = try fixture.executable("simctl", script: prelude + #"""
        case "$*" in
            'list runtimes --json') record list; printf '%s\n' '\#(metadata)' ;;
            'create yieldd-template-test \#(deviceType) \#(runtime)') record create; printf '%s\n' 'test-device' ;;
            'bootstatus test-device -b') record bootstatus ;;
            'io test-device screenshot \#(fixture.directory.path)/screenshot.png')
                record screenshot
                : > "$4"
                if [[ '\#(failure)' != 'empty-screenshot' ]]; then printf png > "$4"; fi ;;
            *) exit 99 ;;
        esac
        """#)
        let script = MacOSTemplateValidation.script
            .replacingOccurrences(of: "/usr/bin/xcodebuild", with: "'\(xcodebuild.path)'")
            .replacingOccurrences(of: "/usr/bin/xcrun", with: "'\(xcrun.path)'")
            .replacingOccurrences(of: "/usr/bin/mktemp", with: "'\(mktemp.path)'")
        let result = try ProcessExecutor().execute(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-s"],
            standardInput: Data(script.utf8), timeout: 10
        ))
        let stages = ["xcode-version", "first-launch", "swift-version", "find-simctl", "list", "create", "bootstatus", "screenshot"]
        let lastStage = failure == "metadata" ? 4 : stages.firstIndex(of: failure) ?? (stages.count - 1)
        let commands = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(commands == Array(stages.prefix(lastStage + 1)))
        #expect(result.stdout.isEmpty)
        if failure == "success" {
            #expect(result.terminationStatus == 0)
            #expect(result.stderr.isEmpty)
            #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("screenshot.png")) == Data("png".utf8))
        } else {
            #expect(result.terminationStatus != 0)
            let diagnostics = [
                "xcode-version": "Install full Xcode", "first-launch": "accept its license",
                "swift-version": "toolchain is incomplete", "find-simctl": "Command Line Tools alone",
                "list": "CoreSimulator cannot list runtimes", "metadata": "Malformed simulator runtime metadata",
                "create": "CoreSimulator could not create a device", "bootstatus": "Simulator boot or startup failed",
                "screenshot": "Simulator screenshot failed", "empty-screenshot": "CoreSimulator produced an empty screenshot",
            ]
            #expect(result.stderrText.contains(try #require(diagnostics[failure])))
        }
    }
}

private struct SimulatorMetadata: Encodable {
    let runtimes: [SimulatorRuntime]
}

private struct SimulatorRuntime: Encodable {
    struct Device: Encodable { let identifier: String }
    let identifier: String
    let isAvailable: Bool
    var supportedDeviceTypes: [Device]

    init(_ runtime: String, available: Bool = true, devices: [String]) {
        identifier = "com.apple.CoreSimulator.SimRuntime.\(runtime)"
        isAvailable = available
        supportedDeviceTypes = devices.map { Device(identifier: "com.apple.CoreSimulator.SimDeviceType.\($0)") }
    }
}

private struct SimulatorScriptFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yieldd-simulator-\(UUID().uuidString)")
    var metadata: URL { directory.appendingPathComponent("runtimes.json") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func select() throws -> ProcessResult {
        try ProcessExecutor().execute(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-l", "JavaScript", "-", metadata.path],
            standardInput: Data(MacOSTemplateValidation.simulatorSelectionScript.utf8), timeout: 10
        ))
    }

    func executable(_ name: String, script: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
