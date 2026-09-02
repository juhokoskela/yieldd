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
func retainsOnlyConfiguredOutputTails() throws {
    let stdout = String(repeating: "stdout-", count: 1_000) + "stdout tail"
    let stderr = String(repeating: "stderr-", count: 1_000) + "stderr tail"
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf '%s' \"$1\"; printf '%s' \"$2\" >&2", "yieldd-tail", stdout, stderr],
        outputCapture: .tail(maxBytes: 128)
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.stdout.count == 128)
    #expect(result.stderr.count == 128)
    #expect(stdout.hasSuffix(result.stdoutText))
    #expect(stderr.hasSuffix(result.stderrText))
    #expect(result.stdoutText.hasSuffix("stdout tail"))
    #expect(result.stderrText.hasSuffix("stderr tail"))
}

@Test
func retainsOutputTailAcrossMultipleReadChunks() throws {
    let expected = (1...200_000).map(String.init).joined(separator: "\n") + "\n"
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
        arguments: ["1", "200000"],
        outputCapture: .tail(maxBytes: 1_024)
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.stdout == Data(expected.utf8.suffix(1_024)))
}

@Test
func hugeTimeoutDoesNotTrapDeadlineConversion() throws {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        timeout: .greatestFiniteMagnitude
    )

    let result = try ProcessExecutor().execute(request)

    #expect(result.terminationStatus == 0)
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
func cancellationTerminatesProcessAndPreservesOutput() {
    var checks = 0
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "echo 'started' >&2; while :; do :; done"]
    )
    let executor = ProcessExecutor(
        terminationGracePeriod: 0.05,
        cancellationPollInterval: 0.01,
        checkCancellation: {
            checks += 1
            if checks == 3 {
                throw TestFailure.cancelled
            }
        }
    )

    do {
        _ = try executor.execute(request)
        Issue.record("Expected the process to be cancelled")
    } catch let ProcessExecutionError.cancelled(actualRequest, result, underlying) {
        #expect(actualRequest == request)
        #expect(result.terminationReason == .uncaughtSignal)
        #expect(result.terminationStatus == SIGTERM)
        #expect(result.stderrText.contains("started"))
        #expect(underlying as? TestFailure == .cancelled)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func cancellationTerminatesTheOwnedProcessGroup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-cancel-tree-\(UUID().uuidString)", isDirectory: true)
    let processGroupURL = directory.appendingPathComponent("group.pid")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        terminateProcessGroupRecorded(at: processGroupURL)
        try? FileManager.default.removeItem(at: directory)
    }

    let script = """
        /bin/sh -c 'trap "" HUP TERM; while :; do :; done' &
        echo $$ > "$1"
        trap '' TERM
        while :; do :; done
        """
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, "yieldd-cancel-test", processGroupURL.path]
    )
    let executor = ProcessExecutor(
        terminationGracePeriod: 0.05,
        cancellationPollInterval: 0.01,
        checkCancellation: {
            if FileManager.default.fileExists(atPath: processGroupURL.path) {
                throw TestFailure.cancelled
            }
        }
    )

    do {
        _ = try executor.execute(request)
        Issue.record("Expected the process to be cancelled")
    } catch let ProcessExecutionError.cancelled(_, result, underlying) {
        #expect(result.terminationReason == .uncaughtSignal)
        #expect(result.terminationStatus == SIGKILL)
        #expect(underlying as? TestFailure == .cancelled)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let processGroup = try #require(processIdentifierRecorded(at: processGroupURL))
    #expect(!processGroupExists(processGroup))
}

@Test
func noncancellableRequestIgnoresCancellationChecker() throws {
    var checked = false
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        cancellable: false
    )
    let executor = ProcessExecutor(checkCancellation: {
        checked = true
        throw TestFailure.cancelled
    })

    let result = try executor.execute(request)

    #expect(result.terminationStatus == 0)
    #expect(!checked)
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
func timeoutClosesDescriptorsHeldByDescendantAfterTerminatingParent() throws {
    let execution = try executeWithDescendantHoldingOutput(parentAction: .wait)

    try expectTimeout(
        execution,
        terminationReason: .uncaughtSignal,
        terminationStatus: SIGKILL
    )
}

@Test
func timeoutRemainsActiveWhileDrainingPipesAfterParentExits() throws {
    let execution = try executeWithDescendantHoldingOutput(parentAction: .exit)

    try expectTimeout(
        execution,
        terminationReason: .exit,
        terminationStatus: 0
    )
}

private func executeWithDescendantHoldingOutput(
    parentAction: RetainedDescriptorParentAction
) throws -> RetainedDescriptorExecution {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-process-tree-\(UUID().uuidString)", isDirectory: true)
    let processGroupURL = directory.appendingPathComponent("group.pid")
    let childPIDURL = directory.appendingPathComponent("child.pid")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        terminateProcessRecorded(at: childPIDURL)
        try? FileManager.default.removeItem(at: directory)
    }

    let script = """
        /bin/sh -c 'trap "" HUP TERM; exec /bin/sleep 30' &
        echo $$ > "$1"
        echo $! > "$2"
        echo 'waiting forever' >&2
        if [ "$3" = exit ]; then
            exit 0
        fi
        trap '' TERM
        while :; do :; done
        """
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c", script, "yieldd-timeout-test",
            processGroupURL.path, childPIDURL.path, parentAction.rawValue,
        ],
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

    guard let result = outcome.result() else {
        throw RetainedDescriptorTestError.didNotComplete
    }

    return RetainedDescriptorExecution(
        request: request,
        completedWithoutClosingDescendant: completedWithoutClosingDescendant,
        processGroupSurvived: processIdentifierRecorded(at: processGroupURL)
            .map(processGroupExists) ?? false,
        result: result
    )
}

private func expectTimeout(
    _ execution: RetainedDescriptorExecution,
    terminationReason: Process.TerminationReason,
    terminationStatus: Int32
) throws {
    #expect(execution.completedWithoutClosingDescendant == .success)
    #expect(!execution.processGroupSurvived)
    do {
        _ = try execution.result.get()
        Issue.record("Expected the process to time out")
    } catch let ProcessExecutionError.timedOut(actualRequest, result) {
        #expect(actualRequest == execution.request)
        #expect(result.terminationReason == terminationReason)
        #expect(result.terminationStatus == terminationStatus)
        #expect(result.stderrText.contains("waiting forever"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private struct RetainedDescriptorExecution {
    let request: ProcessRequest
    let completedWithoutClosingDescendant: DispatchTimeoutResult
    let processGroupSurvived: Bool
    let result: Result<ProcessResult, any Error>
}

private enum RetainedDescriptorTestError: Error {
    case didNotComplete
}

private enum RetainedDescriptorParentAction: String {
    case wait
    case exit
}

private func terminateProcessRecorded(at url: URL) {
    guard let processIdentifier = processIdentifierRecorded(at: url) else {
        return
    }
    Darwin.kill(processIdentifier, SIGKILL)
}

private func terminateProcessGroupRecorded(at url: URL) {
    guard let processGroup = processIdentifierRecorded(at: url) else {
        return
    }
    Darwin.kill(-processGroup, SIGKILL)
}

private func processIdentifierRecorded(at url: URL) -> Int32? {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        return nil
    }
    return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func processGroupExists(_ processGroup: Int32) -> Bool {
    if Darwin.kill(-processGroup, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private final class ProcessExecutionOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<ProcessResult, any Error>?

    func store(_ result: Result<ProcessResult, any Error>) {
        lock.withLock {
            storedResult = result
        }
    }

    func result() -> Result<ProcessResult, any Error>? {
        lock.withLock { storedResult }
    }
}
