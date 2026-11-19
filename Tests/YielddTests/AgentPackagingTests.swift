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

@Test(arguments: ["linux", "macos", "unexpected", "failure"])
func freshAgentInstallerChecksPreflightBeforeEnrollment(result: String) throws {
    let fixture = try InstallerFixture(preflightResult: result)
    defer { fixture.remove() }
    let execution = try fixture.run(arguments: fixture.arguments)
    let events = try String(contentsOf: fixture.logURL, encoding: .utf8)
    let valid = result == "linux" || result == "macos"
    #expect((execution.terminationStatus == 0) == valid)
    #expect(events.contains("container:build") == (result == "linux"))
    #expect(events.contains("new:agent install --server") == valid)
    #expect(FileManager.default.fileExists(atPath: fixture.applicationsURL.appendingPathComponent("yieldd.app").path) == valid)
}

@Test
func interruptedImageBuildStopsTheBuilderBeforeRemovingStaging() throws {
    let fixture = try InstallerFixture(preflightResult: "linux")
    defer { fixture.remove() }
    let result = try fixture.run(arguments: fixture.arguments, interruptBuild: true)
    #expect(result.terminationStatus == 143)
    let events = try String(contentsOf: fixture.logURL, encoding: .utf8)
    #expect(events.contains("container:builder stop"))
    #expect(!events.contains("new:agent install --server"))
    #expect(!FileManager.default.fileExists(atPath: fixture.applicationsURL.appendingPathComponent(".yieldd-installer").path))
}

@Test
func installerRefusesAnExistingAppBeforePreflightOrImageBuild() throws {
    let fixture = try InstallerFixture(preflightResult: "linux")
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.oldMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("original".utf8).write(to: fixture.oldMarker)
    #expect(try fixture.run(arguments: fixture.arguments).terminationStatus != 0)
    #expect(try String(contentsOf: fixture.oldMarker, encoding: .utf8) == "original")
    #expect(!FileManager.default.fileExists(atPath: fixture.logURL.path))
}

@Test
func failedEnrollmentKeepsTheInstalledBundleForRecovery() throws {
    let fixture = try InstallerFixture(preflightResult: "macos", enrollmentFails: true)
    defer { fixture.remove() }
    #expect(try fixture.run(arguments: fixture.arguments).terminationStatus != 0)
    let executable = fixture.applicationsURL.appendingPathComponent("yieldd.app/Contents/MacOS/yieldd")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    let events = try String(contentsOf: fixture.logURL, encoding: .utf8)
    #expect(events.contains("new:agent install --server"))
    #expect(try fixture.run(arguments: fixture.arguments).terminationStatus != 0)
    #expect(try String(contentsOf: fixture.logURL, encoding: .utf8) == events)
}

@Test(arguments: [false, true])
func agentPreflightBinaryRejectsMissingStorageBeforeReturningInstallerToken(linux: Bool) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let bin = fixture.rootURL.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in linux ? ["container"] : [] {
        let executable = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let arguments = ["--server", "https://example.test", "--device-id", "01234567-89ab-4def-8123-456789abcdef"]
            + (linux ? [] : ["--platform", "macos", "--macos-template", fixture.templateURL.path])
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["CFFIXED_USER_HOME=\(fixture.rootURL.path)", "PATH=\(bin.path)", repositoryRoot.appendingPathComponent(".build/debug/yieldd").path,
                    "agent", "install", "--preflight-only"] + arguments,
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
    init(preflightResult: String, enrollmentFails: Bool = false) throws {
        try executable("Scripts/build-local-app.sh", script: "echo build >> \(quote(logURL.path))")
        try executable(".build/yieldd.app/Contents/MacOS/yieldd", script: """
        printf 'new:%s\\n' "$*" >> \(quote(logURL.path))
        if [ "$#" -ge 3 ] && [ "$3" = --preflight-only ]; then
            \(preflightResult == "failure" ? "exit 2" : "echo \(preflightResult)")
            exit 0
        fi
        exit \(enrollmentFails ? 1 : 0)
        """)
    }

    func run(arguments: [String], interruptBuild: Bool = false) throws -> ProcessResult {
        let original = try String(contentsOf: repositoryRoot.appendingPathComponent("Scripts/install-local-agent.sh"), encoding: .utf8)
        let scriptDirectoryAssignment = #"script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"#
        let applicationsDirectoryAssignment = #"applications_directory="${HOME:?}/Applications""#
        // Never execute the installer unless both real filesystem destinations are redirected.
        try #require(original.contains(scriptDirectoryAssignment))
        try #require(original.contains(applicationsDirectoryAssignment))
        let script = """
        codesign() { echo codesign >> \(quote(logURL.path)); }
        container() {
            printf 'container:%s\\n' "$*" >> \(quote(logURL.path))
            if [ "$1" = build ] && \(interruptBuild ? "true" : "false"); then kill -TERM "$$"; fi
        }
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
