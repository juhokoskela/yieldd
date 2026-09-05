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
        printf 'started\n' >> "$HOME/runner-starts"
        printf 'job output\n'
        exit 7
        """)
    defer { fixture.remove() }

    let firstResult = try ProcessExecutor().execute(fixture.controlRequest("run"))
    let secondResult = try ProcessExecutor().execute(fixture.controlRequest("run"))

    for result in [firstResult, secondResult] {
        #expect(result.terminationReason == .exit)
        #expect(result.terminationStatus == 7)
        #expect(result.stdoutText == "job output\n")
        #expect(result.stderr.isEmpty)
    }
    #expect(try fixture.recordedLines(filename: "runner-starts").count == 1)
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

@Test
func macOSRunnerControlSerializesConcurrentStarts() throws {
    let fixture = try MacOSGuestRunnerFixture(runScript: """
        #!/bin/bash
        printf 'started\n' >> "$HOME/runner-starts"
        /bin/ps -o pgid= -p "$$" | tr -d ' ' >> "$HOME/runner-groups"
        trap 'exit 0' TERM
        while :; do sleep 1; done
        """)
    defer { fixture.remove() }
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
            "-c",
            """
            for _ in {1..20}; do
                HOME="$1" "$2" run >/dev/null 2>&1 &
            done
            for _ in {1..300}; do
                [[ -f "$1/runner-starts" ]] && break
                sleep 0.01
            done
            sleep 0.25
            HOME="$1" "$2" stop
            wait || true
            """,
            "parallel-runner-starts",
            fixture.homeURL.path,
            macOSRunnerControlURL.path,
        ],
        timeout: 10
    )

    try ProcessExecutor().execute(request).requireSuccess(for: request)

    #expect(try fixture.recordedLines(filename: "runner-starts").count == 1)
    let processGroups = try fixture.recordedPIDs(filename: "runner-groups")
    #expect(processGroups.count == 1)
    if let processGroup = processGroups.first {
        #expect(!processGroupIsRunning(processGroup))
    }
}

@Test
func macOSRunnerControlStopsTheActualListenerProcessGroup() throws {
    let fixture = try MacOSGuestRunnerFixture(
        runScript: """
            #!/bin/bash
            if [[ "${RUNNER_MANUALLY_TRAP_SIG:-}" == 1 ]]; then
                set -m
                trap 'kill -INT -$PID' INT TERM
                ./run-helper.sh &
                PID=$!
                wait "$PID"
                exit $?
            fi
            ./run-helper.sh
            """,
        runHelperScript: """
            #!/bin/bash
            printf '%s\n' "$$" > "$HOME/helper-pid"
            trap '' INT
            trap 'exit 0' TERM
            while :; do sleep 1; done
            """
    )
    defer { fixture.remove() }

    try expectTimeout(fixture.controlRequest("run", timeout: 0.25))
    try waitForFile(
        fixture.homeURL.appendingPathComponent("helper-pid"),
        diagnosticsDirectory: fixture.diagnosticsDirectory
    )
    let helperPID = try #require(fixture.recordedPID(filename: "helper-pid"))
    #expect(processIsRunning(helperPID))

    let stopRequest = fixture.controlRequest("stop", timeout: 5)
    try ProcessExecutor().execute(stopRequest).requireSuccess(for: stopRequest)

    try waitForProcessToStop(helperPID)
}

@Test
func macOSRunnerControlBoundsRetainedOutput() throws {
    let fixture = try MacOSGuestRunnerFixture(runScript: """
        #!/bin/bash
        for ((index = 0; index < 200000; index++)); do
            printf '0123456789abcdef'
        done
        printf 'final output\n'
        """)
    defer { fixture.remove() }

    let request = fixture.controlRequest("run", timeout: 15)
    let result = try ProcessExecutor().execute(request)
    try result.requireSuccess(for: request)

    #expect(result.stdout.count <= 1_024 * 1_024)
    #expect(result.stdoutText.hasSuffix("final output\n"))
    let retainedOutput = try Data(
        contentsOf: fixture.diagnosticsDirectory.appendingPathComponent("output.log")
    )
    #expect(retainedOutput == result.stdout)
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

private func processIsRunning(_ process: pid_t) -> Bool {
    Darwin.kill(process, 0) == 0 || errno == EPERM
}

private func waitForProcessToStop(_ process: pid_t) throws {
    for _ in 0..<300 {
        if !processIsRunning(process) {
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw MacOSGuestRunnerTestError.processDidNotStop(process)
}

private struct MacOSGuestRunnerFixture {
    let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "yieldd-macos-runner-\(UUID().uuidString)",
        isDirectory: true
    )

    private var runnerDirectory: URL {
        homeURL.appendingPathComponent("actions-runner", isDirectory: true)
    }

    var diagnosticsDirectory: URL {
        runnerDirectory.appendingPathComponent(".yieldd-runner", isDirectory: true)
    }

    private var processGroupURL: URL {
        runnerDirectory.appendingPathComponent(".yieldd-runner/process-group")
    }

    init(
        runScript: String = "#!/bin/bash\nexit 0\n",
        runHelperScript: String? = nil,
        configScript: String = "#!/bin/bash\nexit 0\n"
    ) throws {
        try FileManager.default.createDirectory(
            at: runnerDirectory,
            withIntermediateDirectories: true
        )
        try writeExecutable(runScript, to: runnerDirectory.appendingPathComponent("run.sh"))
        if let runHelperScript {
            try writeExecutable(
                runHelperScript,
                to: runnerDirectory.appendingPathComponent("run-helper.sh")
            )
        }
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
        recordedPID(at: processGroupURL)
    }

    func recordedPID(filename: String) -> pid_t? {
        recordedPID(at: homeURL.appendingPathComponent(filename))
    }

    func recordedPIDs(filename: String) throws -> [pid_t] {
        try recordedLines(filename: filename).compactMap { line in
            let process = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines))
            return process.flatMap { $0 > 1 ? $0 : nil }
        }
    }

    func recordedLines(filename: String) throws -> [Substring] {
        try String(
            contentsOf: homeURL.appendingPathComponent(filename),
            encoding: .utf8
        ).split(separator: "\n")
    }

    private func recordedPID(at url: URL) -> pid_t? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              let process = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              process > 1
        else {
            return nil
        }
        return process
    }

    func remove() {
        if let processGroup = recordedProcessGroup() {
            _ = Darwin.kill(-processGroup, SIGKILL)
        }
        if let processGroups = try? recordedPIDs(filename: "runner-groups") {
            for processGroup in Set(processGroups) where processGroup != Darwin.getpgrp() {
                _ = Darwin.kill(-processGroup, SIGKILL)
            }
        }
        if let helperPID = recordedPID(filename: "helper-pid") {
            if Darwin.getpgid(helperPID) == helperPID {
                _ = Darwin.kill(-helperPID, SIGKILL)
            }
            _ = Darwin.kill(helperPID, SIGKILL)
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
    case processDidNotStop(pid_t)
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
