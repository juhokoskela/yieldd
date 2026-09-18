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
        ? .failure(ProcessExecutionError.nonZeroExit(request: request, result: processResult(status: 2)))
        : .success(processResult(stdout: response))
    let executor = RecordingProcessExecutor(outcomes: [outcome, outcome])
    let backend = AppleContainerBackend(containerURL: request.executableURL, executor: executor)
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
