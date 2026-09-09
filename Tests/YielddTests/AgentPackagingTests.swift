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

@Test(arguments: ["macos", "linux", "unexpected", "failure"])
func localAgentInstallerPreflightsBeforeReplacingAndBuildsOnlyForLinux(result: String) throws {
    let fixture = try InstallerFixture(preflightResult: result)
    defer { fixture.remove() }
    let arguments = result == "linux"
        ? ["owner/linux", "--macos", "owner/mac", "--macos-template", "/template with spaces.bundle"]
        : ["--macos", "owner/mac", "--macos-template", "/template with spaces.bundle"]
    let execution = try fixture.run(arguments: arguments)
    let events = try String(contentsOf: fixture.logURL, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(events.prefix(3) == ["build", "codesign", "new:agent install --preflight-only \(arguments.joined(separator: " "))"])
    if result == "macos" || result == "linux" {
        #expect(execution.terminationStatus == 0, "\(execution.stderrText)")
        #expect(events.contains("old:agent uninstall"))
        #expect(events.last == "new:agent install \(arguments.joined(separator: " "))")
        #expect(!FileManager.default.fileExists(atPath: fixture.oldMarker.path))
        if result == "linux" {
            let operations = events.filter { $0.hasPrefix("container:") }
            try #require(operations.count == 5)
            #expect(operations[0].hasPrefix("container:build -t local/yieldd-guest:installing-"))
            #expect(operations[1] == "container:builder stop")
            #expect(operations[2] == "container:image delete --force local/yieldd-guest:dev")
            #expect(operations[3].hasPrefix("container:image tag local/yieldd-guest:installing-"))
            #expect(operations[4].hasPrefix("container:image delete local/yieldd-guest:installing-"))
            #expect(try #require(events.firstIndex(of: operations[1])) < #require(events.firstIndex(of: "old:agent uninstall")))
        } else {
            #expect(!events.contains { $0.hasPrefix("container:") })
        }
    } else {
        #expect(execution.terminationStatus == (result == "failure" ? 2 : 1))
        #expect(events.count == 3)
        #expect(FileManager.default.fileExists(atPath: fixture.oldMarker.path))
    }
    let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.applicationsURL.path)
    #expect(remaining == ["yieldd.app"])
}

@Test(arguments: [false, true])
func agentPreflightBinaryEmitsInstallerProtocolToken(linux: Bool) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let bin = fixture.rootURL.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in linux ? ["gh", "container"] : ["gh"] {
        let executable = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let arguments = linux ? ["owner/repo"] : ["--macos", "owner/repo", "--macos-template", fixture.templateURL.path]
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["PATH=\(bin.path)", repositoryRoot.appendingPathComponent(".build/debug/yieldd").path,
                    "agent", "install", "--preflight-only"] + arguments,
        timeout: 15
    )
    let result = try ProcessExecutor().execute(request).requireSuccess(for: request)
    #expect(result.stdoutText == (linux ? "linux\n" : "macos\n"))
    #expect(result.stderr.isEmpty)
}

private struct InstallerFixture {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("yieldd-installer-\(UUID().uuidString)")
    var logURL: URL { rootURL.appendingPathComponent("events") }
    var applicationsURL: URL { rootURL.appendingPathComponent("Applications") }
    var oldMarker: URL { applicationsURL.appendingPathComponent("yieldd.app/old-marker") }

    init(preflightResult: String) throws {
        try executable("Scripts/build-local-app.sh", script: "echo build >> \(quote(logURL.path))")
        try executable(".build/yieldd.app/Contents/MacOS/yieldd", script: """
        printf 'new:%s\\n' "$*" >> \(quote(logURL.path))
        if [ "${3-}" = --preflight-only ]; then
            \(preflightResult == "failure" ? "exit 2" : "echo \(preflightResult)")
        fi
        """)
        try executable("Applications/yieldd.app/Contents/MacOS/yieldd", script: "printf 'old:%s\\n' \"$*\" >> \(quote(logURL.path))")
        try Data("original installation".utf8).write(to: oldMarker)
    }

    func run(arguments: [String]) throws -> ProcessResult {
        let original = try String(contentsOf: repositoryRoot.appendingPathComponent("Scripts/install-local-agent.sh"), encoding: .utf8)
        let scriptDirectoryAssignment = #"script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"#
        let applicationsDirectoryAssignment = #"applications_directory="${HOME:?}/Applications""#
        // Never execute the installer unless both real filesystem destinations are redirected.
        try #require(original.contains(scriptDirectoryAssignment))
        try #require(original.contains(applicationsDirectoryAssignment))
        let script = """
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
