import Foundation
import Testing
@testable import Yieldd

@Test
func localAgentPlistRunsTheMainExecutableWithBoundedShutdown() throws {
    let plistURL = repositoryRoot
        .appendingPathComponent("Packaging/dev.yieldd.agent.plist", isDirectory: false)
    let data = try Data(contentsOf: plistURL)
    let plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    )

    #expect(plist["BundleProgram"] as? String == "Contents/MacOS/yieldd")
    #expect(plist["ProgramArguments"] as? [String] == ["yieldd", "agent", "run"])
    #expect(plist["ExitTimeOut"] as? Int == 60)
    #expect(plist["ThrottleInterval"] as? Int == 30)
    #expect(plist["KeepAlive"] as? Bool == true)
    #expect((plist["MachServices"] as? [String: Bool])?["dev.yieldd.agent.control"] == true)
    #expect(plist["AssociatedBundleIdentifiers"] == nil)
}

@Test
func localAgentEntitlementsEnableVirtualization() throws {
    let entitlementsURL = repositoryRoot
        .appendingPathComponent("Packaging/yieldd.entitlements", isDirectory: false)
    let data = try Data(contentsOf: entitlementsURL)
    let entitlements = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    )
    #expect(entitlements["com.apple.security.virtualization"] as? Bool == true)
}

@Test(arguments: ["macos", "linux", "update-linux", "update-macos", "unexpected", "failure"])
func localAgentInstallerPreservesConnectedInstallation(result: String) throws {
    let fixture = try InstallerFixture(preflightResult: result)
    defer { fixture.remove() }
    let execution = try fixture.run(arguments: fixture.arguments)
    let events = try String(contentsOf: fixture.logURL, encoding: .utf8)
    #expect(!events.contains("agent uninstall"))
    if result == "unexpected" || result == "failure" {
        #expect(execution.terminationStatus != 0)
        #expect(FileManager.default.fileExists(atPath: fixture.oldMarker.path))
    } else {
        #expect(execution.terminationStatus == 0, "\(execution.stderrText)")
        #expect(!FileManager.default.fileExists(atPath: fixture.oldMarker.path))
        #expect(events.contains("container:build") == result.hasSuffix("linux"))
        #expect(events.contains("old:agent drain") == result.hasPrefix("update-"))
        #expect(events.contains("new:agent resume") == result.hasPrefix("update-"))
        #expect(events.contains("new:agent install-connected --server") == !result.hasPrefix("update-"))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.applicationsURL.path) == ["yieldd.app"])
}

@Test(arguments: [false, true])
func failedConnectedUpgradeRestoresPreviousImageBundleAndAdmission(initiallyPaused: Bool) throws {
    let fixture = try InstallerFixture(preflightResult: "update-linux", failRestart: true, initiallyPaused: initiallyPaused)
    defer { fixture.remove() }
    let execution = try fixture.run(arguments: fixture.arguments)
    let events = try String(contentsOf: fixture.logURL, encoding: .utf8)
    #expect(execution.terminationStatus != 0)
    #expect(FileManager.default.fileExists(atPath: fixture.oldMarker.path))
    #expect(events.contains("container:image tag local/yieldd-guest:previous-"))
    #expect(events.contains("old:agent resume") == !initiallyPaused)
    #expect(!events.contains("agent uninstall"))
}

@Test(arguments: [false, true])
func agentPreflightBinaryRejectsMissingStorageBeforeReturningInstallerToken(linux: Bool) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let bin = fixture.rootURL.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in linux ? ["gh", "container"] : ["gh"] {
        let executable = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let arguments = ["--server", "https://example.test", "--device-id", "01234567-89ab-4def-8123-456789abcdef"]
            + (linux ? [] : ["--platform", "macos", "--macos-template", fixture.templateURL.path])
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["CFFIXED_USER_HOME=\(fixture.rootURL.path)", "PATH=\(bin.path)", repositoryRoot.appendingPathComponent(".build/debug/yieldd").path,
                    "agent", "install-connected", "--preflight-only"] + arguments,
        timeout: 15
    )
    let result = try ProcessExecutor().execute(request)
    let physicalMemory = ProcessInfo.processInfo.physicalMemory
    let budget = physicalMemory - physicalMemory / 4
    let required = (linux ? RunnerPlatform.linux : .macOS).memoryReservationBytes
    if required > budget {
        #expect(result.terminationReason == .exit)
        #expect(result.terminationStatus == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderrText.contains(describeError(RunnerMemoryAdmissionError.insufficientHostMemory(
            requiredBytes: required, budgetBytes: budget
        ))))
    } else {
        #expect(result.terminationStatus == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderrText.contains(describeError(RunnerStorageError.notConfigured)))
    }
}

private struct InstallerFixture {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("yieldd-installer-\(UUID().uuidString)")
    var logURL: URL { rootURL.appendingPathComponent("events") }
    var applicationsURL: URL { rootURL.appendingPathComponent("Applications") }
    var oldMarker: URL { applicationsURL.appendingPathComponent("yieldd.app/old-marker") }

    let arguments = ["--server", "https://example.test", "--device-id", "01234567-89ab-4def-8123-456789abcdef"]
    let failRestart: Bool
    var restart: URL { rootURL.appendingPathComponent("restart") }

    init(preflightResult: String, failRestart: Bool = false, initiallyPaused: Bool = false) throws {
        self.failRestart = failRestart
        let paused = rootURL.appendingPathComponent("paused")
        try executable("Scripts/build-local-app.sh", script: "echo build >> \(quote(logURL.path))")
        let status = """
        if [ "$2" = drain ]; then touch \(quote(paused.path)); fi
        if [ "$2" = status ]; then
            instance=old
            if [ -f \(quote(restart.path)) ]; then instance=$(cat \(quote(restart.path))); fi
            paused=false
            if [ -f \(quote(paused.path)) ]; then paused=true; fi
            echo "{\\"live\\":{\\"ready\\":true,\\"instanceID\\":\\"$instance\\",\\"paused\\":$paused,\\"activeAssignments\\":0,\\"resumeGeneration\\":0,\\"buildID\\":\\"new-build\\"}}"
        fi
        """
        try executable(".build/yieldd.app/Contents/MacOS/yieldd", script: """
        printf 'new:%s\\n' "$*" >> \(quote(logURL.path))
        if [ "$#" -ge 3 ] && [ "$3" = --preflight-only ]; then
            \(preflightResult == "failure" ? "exit 2" : "echo \(preflightResult)")
            exit 0
        fi
        \(status)
        """)
        let info = rootURL.appendingPathComponent(".build/yieldd.app/Contents/Info.plist")
        try Data(#"{"YielddBuildID":"new-build"}"#.utf8).write(to: info)
        try executable("Applications/yieldd.app/Contents/MacOS/yieldd", script: """
        printf 'old:%s\\n' "$*" >> \(quote(logURL.path))
        \(status)
        """)
        try Data("original installation".utf8).write(to: oldMarker)
        if initiallyPaused { try Data().write(to: paused) }
    }

    func run(arguments: [String]) throws -> ProcessResult {
        let original = try String(contentsOf: repositoryRoot.appendingPathComponent("Scripts/install-local-agent.sh"), encoding: .utf8)
        let scriptDirectoryAssignment = #"script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"#
        let applicationsDirectoryAssignment = #"applications_directory="${HOME:?}/Applications""#
        // Never execute the installer unless both real filesystem destinations are redirected.
        try #require(original.contains(scriptDirectoryAssignment))
        try #require(original.contains(applicationsDirectoryAssignment))
        let script = """
        launchctl() {
            if [ ! -f \(quote(restart.path)) ]; then
                echo new > \(quote(restart.path))
                return \(failRestart ? 1 : 0)
            fi
            echo restored > \(quote(restart.path))
        }
        codesign() { echo codesign >> \(quote(logURL.path)); }
        container() { printf 'container:%s\\n' "$*" >> \(quote(logURL.path)); }
        """ + "\n" + original
            .replacingOccurrences(
                of: scriptDirectoryAssignment,
                with: "script_directory=\(quote(rootURL.appendingPathComponent("Scripts").path))"
            )
            .replacingOccurrences(of: applicationsDirectoryAssignment,
                                  with: "applications_directory=\(quote(applicationsURL.path))")
        return try ProcessExecutor().execute(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-s", "--"] + arguments,
            standardInput: Data(script.utf8), timeout: 20
        ))
    }

    func remove() { try? FileManager.default.removeItem(at: rootURL) }

    private func executable(_ path: String, script: String) throws {
        let url = rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("#!/bin/sh\nset -eu\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
