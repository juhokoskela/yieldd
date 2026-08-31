import Darwin
import Foundation
import Testing
@testable import Yieldd

@Test
func capturesStandardOutput() throws {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: ["%s", "hello world"]
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.terminationReason == .exit)
    #expect(result.terminationStatus == 0)
    #expect(result.stdoutText == "hello world")
    #expect(result.stderr.isEmpty)
}

@Test
func returnsFailureOutputWithoutThrowing() throws {
    let missingPath = "/tmp/yieldd-missing-\(UUID().uuidString)"
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/ls"),
        arguments: [missingPath]
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.terminationReason == .exit)
    #expect(result.terminationStatus != 0)
    #expect(!result.stderr.isEmpty)
}

@Test
func requireSuccessAcceptsZeroExitStatus() throws {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: []
    )
    let result = ProcessResult(
        stdout: Data(),
        stderr: Data(),
        terminationReason: .exit,
        terminationStatus: 0
    )

    #expect(try result.requireSuccess(for: request) == result)
}

@Test
func requireSuccessPreservesNonzeroResult() {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        arguments: []
    )
    let result = ProcessResult(
        stdout: Data("out".utf8),
        stderr: Data("failure".utf8),
        terminationReason: .exit,
        terminationStatus: 9
    )

    #expect(throws: ProcessExecutionError.self) {
        try result.requireSuccess(for: request)
    }

    do {
        try result.requireSuccess(for: request)
        Issue.record("Expected a nonzero exit error")
    } catch let ProcessExecutionError.nonZeroExit(actualRequest, actualResult) {
        #expect(actualRequest == request)
        #expect(actualResult == result)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func requireSuccessPreservesSignalResult() {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        arguments: []
    )
    let result = ProcessResult(
        stdout: Data(),
        stderr: Data(),
        terminationReason: .uncaughtSignal,
        terminationStatus: 15
    )

    do {
        try result.requireSuccess(for: request)
        Issue.record("Expected a signal termination error")
    } catch let ProcessExecutionError.terminatedBySignal(actualRequest, actualResult) {
        #expect(actualRequest == request)
        #expect(actualResult == result)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func reportsLaunchFailure() {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/tmp/yieldd-does-not-exist-\(UUID().uuidString)"),
        arguments: []
    )

    do {
        _ = try ProcessExecutor().execute(request)
        Issue.record("Expected launch to fail")
    } catch let ProcessExecutionError.launchFailed(actualRequest, _) {
        #expect(actualRequest == request)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func drainsOutputLargerThanAPipeBuffer() throws {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
        arguments: ["1", "200000"]
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.count > 1_000_000)
}

@Test
func preservesArgumentsWithoutShellInterpretation() throws {
    let argument = "value with spaces; $(whoami) && `uname`"
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: ["%s", argument]
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.stdoutText == argument)
}

@Test
func writesStandardInputWithoutAddingItToArguments() throws {
    let standardInput = Data("secret value\nwith another line".utf8)
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/cat"),
        arguments: [],
        standardInput: standardInput
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.terminationStatus == 0)
    #expect(result.stdout == standardInput)
    #expect(request.arguments.isEmpty)
}

@Test
func childCanExitSuccessfullyWithoutReadingLargeInput() throws {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exec 0<&-; sleep 0.05"],
        standardInput: Data(repeating: 0, count: 1_000_000)
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.terminationReason == .exit)
    #expect(result.terminationStatus == 0)
}

@Test
func childFailureOutranksBrokenPipeError() throws {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exec 0<&-; echo 'machine not found' >&2; exit 7"],
        standardInput: Data(repeating: 0, count: 1_000_000)
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.terminationStatus == 7)
    #expect(result.stderrText.contains("machine not found"))
    #expect(throws: ProcessExecutionError.self) {
        try result.requireSuccess(for: request)
    }
}

@Test
func terminatesProcessAfterTimeout() {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "while :; do :; done"],
        timeout: 0.1
    )

    do {
        _ = try ProcessExecutor().execute(request)
        Issue.record("Expected the process to time out")
    } catch let ProcessExecutionError.timedOut(actualRequest, result) {
        #expect(actualRequest == request)
        #expect(result.terminationReason == .uncaughtSignal)
        #expect(result.terminationStatus == SIGTERM)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func killsProcessThatIgnoresTerminationAfterTimeoutGracePeriod() {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; while :; do :; done"],
        timeout: 0.1
    )

    do {
        _ = try ProcessExecutor(terminationGracePeriod: 0.05).execute(request)
        Issue.record("Expected the process to time out")
    } catch let ProcessExecutionError.timedOut(actualRequest, result) {
        #expect(actualRequest == request)
        #expect(result.terminationReason == .uncaughtSignal)
        #expect(result.terminationStatus == SIGKILL)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func timeoutIsNotHeldOpenByDescendantOutputDescriptors() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-process-tree-\(UUID().uuidString)", isDirectory: true)
    let childPIDURL = directory.appendingPathComponent("child.pid")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        terminateProcessRecorded(at: childPIDURL)
        try? FileManager.default.removeItem(at: directory)
    }

    let script = """
        /bin/sh -c 'trap "" HUP TERM; exec /bin/sleep 30' &
        echo $! > "$1"
        echo 'waiting forever' >&2
        trap '' TERM
        while :; do :; done
        """
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, "yieldd-timeout-test", childPIDURL.path],
        timeout: 0.2
    )
    let outcome = ProcessExecutionOutcome()
    let completion = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        outcome.store(Result {
            try ProcessExecutor(terminationGracePeriod: 0.05).execute(request)
        })
        completion.signal()
    }

    let completedWithoutClosingDescendant = completion.wait(timeout: .now() + 2)
    if completedWithoutClosingDescendant == .timedOut {
        terminateProcessRecorded(at: childPIDURL)
        _ = completion.wait(timeout: .now() + 2)
    }

    #expect(completedWithoutClosingDescendant == .success)
    guard let result = outcome.result() else {
        Issue.record("Process execution did not complete")
        return
    }
    do {
        _ = try result.get()
        Issue.record("Expected the process to time out")
    } catch let ProcessExecutionError.timedOut(actualRequest, result) {
        #expect(actualRequest == request)
        #expect(result.stderrText.contains("waiting forever"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func terminateProcessRecorded(at url: URL) {
    guard let contents = try? String(contentsOf: url, encoding: .utf8),
          let processIdentifier = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return
    }
    Darwin.kill(processIdentifier, SIGKILL)
}

private final class ProcessExecutionOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<ProcessResult, any Error>?

    func store(_ result: Result<ProcessResult, any Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }

    func result() -> Result<ProcessResult, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }
}
