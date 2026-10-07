import Foundation
import Testing
@testable import Yieldd

@Test(arguments: ["configure-runner", "runner-control", "macOS/configure-runner", "macOS/runner-control"])
func guestScriptsReportProtocolWithoutGuestSetup(_ script: String) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [root.appendingPathComponent("Guest/\(script)").path, "--protocol-version"],
        timeout: 5, outputCapture: .tail(maxBytes: 1024))
    let result = try ProcessExecutor().execute(request).requireSuccess(for: request)
    #expect(result.stdoutText == "1\n")
    #expect(result.stderrText.isEmpty)
}

@Test(arguments: ["1\n", "2\n", "", "usage", "old-script"])
func guestProtocolRejectsOutdatedScriptsWithoutSendingCredentials(_ response: String) throws {
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/test/container"), arguments: [])
    let outcome: Result<ProcessResult, any Error> = response == "old-script"
        ? .failure(ProcessExecutionError.nonZeroExit(request: request, result: processResult(stderr: "usage: yieldd-configure-runner OWNER/REPO NAME", status: 2)))
        : .success(processResult(stdout: response))
    let outcomes: [Result<ProcessResult, any Error>] = [outcome, outcome]
    let (backend, executor) = try readyLinuxBackend(outcomes: outcomes, containerURL: request.executableURL, id: RunnerID(value: "yieldd-test"))
    if response == "1\n" {
        try RunnerGuestProtocol.validate(backend: backend, id: RunnerID(value: "yieldd-test"))
        #expect(executor.requests.count == 2)
    } else {
        #expect(throws: RunnerGuestProtocolError.incompatible("yieldd-configure-runner")) {
            try RunnerGuestProtocol.validate(backend: backend, id: RunnerID(value: "yieldd-test"))
        }
        #expect(executor.requests.count == 1)
    }
    #expect(executor.requests.allSatisfy { $0.standardInput == nil && $0.timeout == 5 && $0.outputCapture == .tail(maxBytes: 1024) })
}

@Test(arguments: [0, 1])
func guestProtocolTimeoutIdentifiesTheHelperAndPreservesDiagnostics(completedChecks: Int) throws {
    let helper = ["yieldd-configure-runner", "yieldd-runner-control"][completedChecks]
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        arguments: [], timeout: 5)
    let outcomes: [Result<ProcessResult, any Error>] = Array(repeating: .success(processResult(stdout: "1\n")), count: completedChecks) + [
            .failure(ProcessExecutionError.timedOut(request: request,
                result: processResult(stderr: "SSH diagnostic tail"))),
        ]
    let (backend, executor) = try readyLinuxBackend(outcomes: outcomes, containerURL: URL(fileURLWithPath: "/test/container"), id: RunnerID(value: "yieldd-test"))

    do {
        try RunnerGuestProtocol.validate(backend: backend, id: RunnerID(value: "yieldd-test"))
        Issue.record("Expected the protocol probe to time out")
    } catch let error as RunnerGuestProtocolError {
        guard case let .timedOut(actualHelper, _) = error else {
            Issue.record("Unexpected protocol error: \(error)")
            return
        }
        #expect(actualHelper == helper)
        #expect(error.localizedDescription.contains("\(helper) --protocol-version"))
        #expect(error.localizedDescription.contains("timed out after 5.0 seconds"))
        #expect(error.localizedDescription.contains("SSH diagnostic tail"))
    }
    #expect(executor.requests.count == completedChecks + 1)
}

@Test
func guestProtocolPreservesProcessCancellation() throws {
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/test/container"), arguments: [])
    let outcomes: [Result<ProcessResult, any Error>] = [
        .failure(ProcessExecutionError.cancelled(request: request, result: processResult(),
            underlying: CancellationError())),
    ]
    let (backend, executor) = try readyLinuxBackend(outcomes: outcomes, containerURL: request.executableURL, id: RunnerID(value: "yieldd-test"))

    do {
        try RunnerGuestProtocol.validate(backend: backend, id: RunnerID(value: "yieldd-test"))
        Issue.record("Expected the protocol probe to be cancelled")
    } catch let error as ProcessExecutionError {
        guard case let .cancelled(actualRequest, _, underlying) = error else {
            Issue.record("Unexpected process error: \(error)")
            return
        }
        #expect(actualRequest == request)
        #expect(underlying is CancellationError)
        #expect(isCancellation(error))
    }
    #expect(executor.requests.count == 1)
}

@Test(arguments: [Int32(1), 2, 255])
func guestProtocolPreservesTransportAndDaemonDiagnostics(status: Int32) throws {
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/test/container"), arguments: [])
    let result = processResult(stderr: "transport connection unavailable", status: status)
    let outcomes: [Result<ProcessResult, any Error>] = [.success(result)]
    let (backend, _) = try readyLinuxBackend(outcomes: outcomes, containerURL: request.executableURL, id: RunnerID(value: "yieldd-test"))
    let error = try #require(#expect(throws: ProcessExecutionError.self) {
        try RunnerGuestProtocol.validate(backend: backend, id: RunnerID(value: "yieldd-test"))
    })
    #expect(describeError(error).contains(result.stderrText))
    #expect(!describeError(error).contains("outdated"))
}
