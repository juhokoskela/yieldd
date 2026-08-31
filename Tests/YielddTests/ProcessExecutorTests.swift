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
