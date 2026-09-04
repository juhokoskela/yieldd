import Darwin
import Foundation
import Testing
@testable import Yieldd

@Test
func macOSConfigureRunnerUsesTheEphemeralMacOSLabel() throws {
    let fixture = try MacOSGuestRunnerFixture(configScript: """
        #!/bin/bash
        printf '%s\n' "$@" > "$HOME/config-arguments"
        """)
    defer { fixture.remove() }

    let request = fixture.request(
        script: macOSConfigureRunnerURL,
        arguments: ["owner/repository", "yieldd-macos-test"],
        standardInput: Data("registration-token\n".utf8)
    )
    let result = try ProcessExecutor().execute(request)
    try result.requireSuccess(for: request)

    let arguments = try String(
        contentsOf: fixture.homeURL.appendingPathComponent("config-arguments"),
        encoding: .utf8
    ).split(separator: "\n").map(String.init)
    #expect(arguments == [
        "--unattended",
        "--ephemeral",
        "--url", "https://github.com/owner/repository",
        "--token", "registration-token",
        "--name", "yieldd-macos-test",
        "--no-default-labels",
        "--labels", "yieldd-macos",
        "--work", "_work",
    ])
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
}

@Test
func macOSRunnerControlReturnsTheListenerOutputAndStatus() throws {
    let fixture = try MacOSGuestRunnerFixture(runScript: """
        #!/bin/bash
        printf 'job output\n'
        exit 7
        """)
    defer { fixture.remove() }

    let result = try ProcessExecutor().execute(fixture.controlRequest("run"))

    #expect(result.terminationReason == .exit)
    #expect(result.terminationStatus == 7)
    #expect(result.stdoutText == "job output\n")
    #expect(result.stderr.isEmpty)
}

@Test
func macOSRunnerControlKeepsOneListenerAliveAcrossClientDisconnects() throws {
    let fixture = try MacOSGuestRunnerFixture(runScript: """
        #!/bin/bash
        printf 'started\n' >> "$HOME/runner-starts"
        trap 'exit 0' TERM
        while :; do sleep 1; done
        """)
    defer { fixture.remove() }

    try expectTimeout(fixture.controlRequest("run", timeout: 0.25))
    try waitForFile(
        fixture.homeURL.appendingPathComponent("runner-starts"),
        diagnosticsDirectory: fixture.homeURL.appendingPathComponent(
            "actions-runner/.yieldd-runner",
            isDirectory: true
        )
    )
    let processGroup = try #require(fixture.recordedProcessGroup())
    #expect(processGroupIsRunning(processGroup))

    try expectTimeout(fixture.controlRequest("run", timeout: 0.25))
    let starts = try String(
        contentsOf: fixture.homeURL.appendingPathComponent("runner-starts"),
        encoding: .utf8
    ).split(separator: "\n")
    #expect(starts.count == 1)
    #expect(processGroupIsRunning(processGroup))

    let stopRequest = fixture.controlRequest("stop", timeout: 5)
    try ProcessExecutor().execute(stopRequest).requireSuccess(for: stopRequest)
    #expect(!processGroupIsRunning(processGroup))
}

private func expectTimeout(_ request: ProcessRequest) throws {
    do {
        _ = try ProcessExecutor(
            terminationGracePeriod: 0.05,
            cancellationPollInterval: 0.01
        ).execute(request)
        Issue.record("Expected the runner client to time out")
    } catch ProcessExecutionError.timedOut {
        return
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func waitForFile(_ url: URL, diagnosticsDirectory: URL) throws {
    for _ in 0..<300 {
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    let entries = (try? FileManager.default.contentsOfDirectory(
        atPath: diagnosticsDirectory.path
    )) ?? []
    let output = (try? String(
        contentsOf: diagnosticsDirectory.appendingPathComponent("output.log"),
        encoding: .utf8
    )) ?? ""
    throw MacOSGuestRunnerTestError.fileDidNotAppear(
        "\(url.path); state: \(entries.sorted()); output: \(output)"
    )
}

private func processGroupIsRunning(_ processGroup: pid_t) -> Bool {
    Darwin.kill(-processGroup, 0) == 0 || errno == EPERM
}

private struct MacOSGuestRunnerFixture {
    let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "yieldd-macos-runner-\(UUID().uuidString)",
        isDirectory: true
    )

    private var runnerDirectory: URL {
        homeURL.appendingPathComponent("actions-runner", isDirectory: true)
    }

    private var processGroupURL: URL {
        runnerDirectory.appendingPathComponent(".yieldd-runner/process-group")
    }

    init(runScript: String = "#!/bin/bash\nexit 0\n", configScript: String = "#!/bin/bash\nexit 0\n") throws {
        try FileManager.default.createDirectory(
            at: runnerDirectory,
            withIntermediateDirectories: true
        )
        try writeExecutable(runScript, to: runnerDirectory.appendingPathComponent("run.sh"))
        try writeExecutable(configScript, to: runnerDirectory.appendingPathComponent("config.sh"))
    }

    func request(
        script: URL,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = 5
    ) -> ProcessRequest {
        ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["HOME=\(homeURL.path)", script.path] + arguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    func controlRequest(_ command: String, timeout: TimeInterval? = 5) -> ProcessRequest {
        request(
            script: macOSRunnerControlURL,
            arguments: [command],
            timeout: timeout
        )
    }

    func recordedProcessGroup() -> pid_t? {
        guard let contents = try? String(contentsOf: processGroupURL, encoding: .utf8),
              let processGroup = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return processGroup
    }

    func remove() {
        if let processGroup = recordedProcessGroup() {
            _ = Darwin.kill(-processGroup, SIGKILL)
        }
        try? FileManager.default.removeItem(at: homeURL)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

private enum MacOSGuestRunnerTestError: Error {
    case fileDidNotAppear(String)
}

private let macOSGuestDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Guest/macOS", isDirectory: true)
private let macOSConfigureRunnerURL = macOSGuestDirectory
    .appendingPathComponent("configure-runner", isDirectory: false)
private let macOSRunnerControlURL = macOSGuestDirectory
    .appendingPathComponent("runner-control", isDirectory: false)
