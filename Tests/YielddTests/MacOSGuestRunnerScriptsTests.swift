import Darwin
import Foundation
import Testing
@testable import Yieldd

@Test
func macOSJITIsPrivateConsumedOnceAndReportsPickup() throws {
    let fixture = try MacOSGuestRunnerFixture(runScript: """
        #!/bin/bash
        test "$ACTIONS_RUNNER_INPUT_JITCONFIG" = private-jit || exit 9
        test ! -f "$HOME/actions-runner/.yieldd-runner/jit-config" || exit 10
        "$ACTIONS_RUNNER_HOOK_JOB_STARTED"
        printf 'started\n' >> "$HOME/runner-starts"
        """, configScript: "#!/bin/bash\nexit 11\n")
    defer { fixture.remove() }
    let premature = try ProcessExecutor().execute(fixture.controlRequest("output"))
    #expect(premature.terminationStatus != 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.homeURL.appendingPathComponent("runner-starts").path))
    let configure = fixture.request(script: macOSConfigureRunnerURL, arguments: ["--jit"],
                                    standardInput: Data("private-jit\n".utf8))
    let result = try ProcessExecutor().execute(configure).requireSuccess(for: configure)
    #expect(result.stdout.isEmpty && result.stderr.isEmpty)
    let file = fixture.diagnosticsDirectory.appendingPathComponent("jit-config")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try ProcessExecutor().execute(configure).terminationStatus == 2)
    try fixture.startAndWaitForExit()
    let run = fixture.controlRequest("output")
    try ProcessExecutor().execute(run).requireSuccess(for: run)
    try ProcessExecutor().execute(run).requireSuccess(for: run)
    #expect(try fixture.recordedLines(filename: "runner-starts").count == 1)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try ProcessExecutor().execute(fixture.controlRequest("status")).stdoutText.contains("\"jobStarted\":true"))
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

    try fixture.configure()
    try fixture.startAndWaitForExit()
    let firstResult = try ProcessExecutor().execute(fixture.controlRequest("output"))
    let secondResult = try ProcessExecutor().execute(fixture.controlRequest("output"))

    for result in [firstResult, secondResult] {
        #expect(result.terminationReason == .exit)
        #expect(result.terminationStatus == 0)
        #expect(result.stdoutText == "job output\n")
        #expect(result.stderr.isEmpty)
    }
    #expect(try fixture.recordedLines(filename: "runner-starts").count == 1)
}

@Test
func macOSReservedRunnerPublishesJobStartAndImmutableCompletion() throws {
    let fixture = try MacOSGuestRunnerFixture(runScript: """
        #!/bin/bash
        "$ACTIONS_RUNNER_HOOK_JOB_STARTED"
        printf 'reserved job output\n'
        exit 7
        """, configScript: """
        #!/bin/bash
        printf '%s\n' "$@" > "$HOME/config-arguments"
        """)
    defer { fixture.remove() }
    let configure = fixture.request(script: macOSConfigureRunnerURL, arguments: ["--jit"], standardInput: Data("token\n".utf8))
    try ProcessExecutor().execute(configure).requireSuccess(for: configure)
    let start = fixture.controlRequest("start")
    try ProcessExecutor().execute(start).requireSuccess(for: start)
    try waitForFile(fixture.diagnosticsDirectory.appendingPathComponent("exit-status"), diagnosticsDirectory: fixture.diagnosticsDirectory)
    let status = fixture.controlRequest("status")
    let first = try ProcessExecutor().execute(status).requireSuccess(for: status)
    #expect(first.stdoutText == "{\"phase\":\"exited\",\"jobStarted\":true,\"exitStatus\":7}\n")
    try ProcessExecutor().execute(start).requireSuccess(for: start)
    #expect(try ProcessExecutor().execute(status).stdout == first.stdout)
    #expect(try ProcessExecutor().execute(configure).terminationStatus == 2)
}

@Test
func macOSRunnerControlKeepsOneListenerAliveAcrossClientDisconnects() throws {
    let fixture = try MacOSGuestRunnerFixture(runScript: """
        #!/bin/bash
        printf 'started\n' >> "$HOME/runner-starts"
        sleep 1.5
        """)
    defer { fixture.remove() }
    try fixture.configure()

    try fixture.start()
    try waitForFile(
        fixture.homeURL.appendingPathComponent("runner-starts"),
        diagnosticsDirectory: fixture.homeURL.appendingPathComponent(
            "actions-runner/.yieldd-runner",
            isDirectory: true
        )
    )
    let processGroup = try #require(fixture.recordedProcessGroup())
    #expect(processGroupIsRunning(processGroup))

    try fixture.start()
    let starts = try String(
        contentsOf: fixture.homeURL.appendingPathComponent("runner-starts"),
        encoding: .utf8
    ).split(separator: "\n")
    #expect(starts.count == 1)
    #expect(processGroupIsRunning(processGroup))

    try waitForFile(fixture.diagnosticsDirectory.appendingPathComponent("exit-status"), diagnosticsDirectory: fixture.diagnosticsDirectory)
}

@Test
func macOSRunnerControlSerializesConcurrentStarts() throws {
    let fixture = try MacOSGuestRunnerFixture(runScript: """
        #!/bin/bash
        printf 'started\n' >> "$HOME/runner-starts"
        /bin/ps -o pgid= -p "$$" | tr -d ' ' >> "$HOME/runner-groups"
        sleep 1.5
        """)
    defer { fixture.remove() }
    try fixture.configure()
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
            "-c",
            """
            for _ in {1..20}; do
                HOME="$1" "$2" start >/dev/null 2>&1 &
            done
            for _ in {1..300}; do
                [[ -f "$1/runner-starts" ]] && break
                sleep 0.01
            done
            sleep 0.25
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
    try waitForFile(fixture.diagnosticsDirectory.appendingPathComponent("exit-status"), diagnosticsDirectory: fixture.diagnosticsDirectory)
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

    try fixture.configure()
    try fixture.startAndWaitForExit()
    let request = fixture.controlRequest("output", timeout: 15)
    let result = try ProcessExecutor().execute(request)
    try result.requireSuccess(for: request)

    #expect(result.stdout.count <= 1_024 * 1_024)
    #expect(result.stdoutText.hasSuffix("final output\n"))
    let retainedOutput = try Data(
        contentsOf: fixture.diagnosticsDirectory.appendingPathComponent("output.log")
    )
    #expect(retainedOutput == result.stdout)
}

private func waitForFile(_ url: URL, diagnosticsDirectory: URL, timeout: TimeInterval = 3) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
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

    var diagnosticsDirectory: URL {
        runnerDirectory.appendingPathComponent(".yieldd-runner", isDirectory: true)
    }

    private var processGroupURL: URL {
        runnerDirectory.appendingPathComponent(".yieldd-runner/process-group")
    }

    init(
        runScript: String = "#!/bin/bash\nexit 0\n",
        configScript: String = "#!/bin/bash\nexit 0\n"
    ) throws {
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

    func configure() throws {
        let command = request(script: macOSConfigureRunnerURL, arguments: ["--jit"], standardInput: Data("token\n".utf8))
        try ProcessExecutor().execute(command).requireSuccess(for: command)
    }

    func start() throws {
        let command = controlRequest("start")
        try ProcessExecutor().execute(command).requireSuccess(for: command)
    }

    func startAndWaitForExit() throws {
        try start()
        try waitForFile(diagnosticsDirectory.appendingPathComponent("exit-status"), diagnosticsDirectory: diagnosticsDirectory, timeout: 15)
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
