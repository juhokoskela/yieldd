import Foundation
import Testing
@testable import Yieldd

@Test
func linuxReservedRunnerUsesTheHookAndPreservesListenerResult() throws {
    let fixture = try LinuxRunnerScriptFixture()
    defer { fixture.remove() }
    let configure = fixture.request("configure", ["owner/repo", "yieldd-test", "yieldd-request-test"], input: "token\n")
    try ProcessExecutor().execute(configure).requireSuccess(for: configure)
    let arguments = try String(contentsOf: fixture.directory.appendingPathComponent("config-arguments"), encoding: .utf8)
    #expect(arguments.contains("--labels\nyieldd-request-test\n"))
    #expect(!arguments.contains("--labels\nyieldd\n"))
    let start = fixture.request("control", ["start"])
    try ProcessExecutor().execute(start).requireSuccess(for: start)
    try ProcessExecutor().execute(start).requireSuccess(for: start)
    let status = fixture.request("control", ["status"])
    #expect(try ProcessExecutor().execute(status).requireSuccess(for: status).stdoutText ==
            "{\"phase\":\"exited\",\"jobStarted\":true,\"exitStatus\":7}\n")
    let replay = try ProcessExecutor().execute(fixture.request("control", ["run"]))
    #expect(replay.terminationStatus == 7)
    #expect(replay.stdoutText == "listener output\n")
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .success(try ProcessExecutor().execute(status)),
        .success(replay),
    ])
    let backend = AppleContainerBackend(containerURL: URL(fileURLWithPath: "/test/container"), executor: executor)
    do {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in
            Issue.record("The listener has already completed")
        }, stateChanged: { _ in }).run(
            id: RunnerID(value: "yieldd-test"),
            assignment: RunnerAssignment(routingLabel: "yieldd-request-test"), executionTimeout: 10
        )
        Issue.record("Expected listener failure")
    } catch let error as RunnerAssignmentError {
        #expect(error == .listenerFailed(7, output: "listener output"))
        #expect(describeError(error).contains("listener output"))
        #expect(describeError(error).contains("listener exited with status 7"))
    }
    #expect(executor.requests.last?.outputCapture == .tail(maxBytes: EphemeralRunnerSession.jobOutputTailBytes))
    #expect(try String(contentsOf: fixture.directory.appendingPathComponent("starts"), encoding: .utf8) == "start\n")
    #expect(try ProcessExecutor().execute(configure).terminationStatus == 2)
}

// Exercise the shipped script protocol with systemd, ownership, and Linux paths substituted.
private struct LinuxRunnerScriptFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yieldd-linux-script-\(UUID().uuidString)")

    init() throws {
        let bin = directory.appendingPathComponent("bin")
        let runner = directory.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runner, withIntermediateDirectories: true)
        let guest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Guest")
        for (source, destination) in [("configure-runner", "configure"), ("runner-control", "control")] {
            let contents = try String(contentsOf: guest.appendingPathComponent(source), encoding: .utf8)
                .replacingOccurrences(of: "/opt/actions-runner", with: runner.path)
                .replacingOccurrences(of: "/home/runner", with: directory.path)
                .replacingOccurrences(of: "/usr/local/bin/yieldd-runner-control", with: directory.appendingPathComponent("control").path)
            try executable(contents, at: directory.appendingPathComponent(destination))
        }
        try executable("#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$HOME/config-arguments\"\n", at: runner.appendingPathComponent("config.sh"))
        try executable("""
            #!/bin/bash
            printf 'start\n' >> "$HOME/starts"
            "$ACTIONS_RUNNER_HOOK_JOB_STARTED"
            printf 'listener output\n'
            exit 7
            """, at: runner.appendingPathComponent("run.sh"))
        try executable("#!/bin/bash\nmkdir -p \"${@: -1}\"\n", at: bin.appendingPathComponent("install"))
        try executable("#!/bin/bash\nshift\nexec \"$@\"\n", at: bin.appendingPathComponent("flock"))
        try executable("#!/bin/bash\nexit 1\n", at: bin.appendingPathComponent("systemctl"))
        try executable("""
            #!/bin/bash
            "${@: -2:1}" "${@: -1}" || true
            """, at: bin.appendingPathComponent("systemd-run"))
    }

    func request(_ script: String, _ arguments: [String], input: String? = nil) -> ProcessRequest {
        ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "HOME=\(directory.path)", "PATH=\(directory.appendingPathComponent("bin").path):/usr/bin:/bin",
            directory.appendingPathComponent(script).path,
        ] + arguments, standardInput: input.map { Data($0.utf8) }, timeout: 10)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private func executable(_ contents: String, at url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
