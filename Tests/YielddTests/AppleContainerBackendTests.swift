import Foundation
import Testing
@testable import Yieldd

private let containerURL = URL(fileURLWithPath: "/usr/local/bin/container")
private let runnerID = RunnerID(value: "yieldd-test-123")

@Test
func constructsCreateCommand() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    try backend.create(id: runnerID, image: "local/yieldd-guest:dev")

    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "create",
            "--name", runnerID.value,
            "--home-mount", "none",
            "local/yieldd-guest:dev",
        ]
    )])
}

@Test
func constructsExecCommandWithoutInterpretingArguments() throws {
    let expected = processResult(stdout: "ok")
    let executor = RecordingProcessExecutor(outcomes: [.success(expected)])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)
    let arguments = ["printf", "%s", "value with spaces; $(whoami)"]

    let result = try backend.exec(arguments, on: runnerID)

    #expect(result == expected)
    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "run",
            "--name", runnerID.value,
            "--user", "runner",
            "--",
        ] + arguments
    )])
}

@Test
func rejectsEmptyGuestCommand() {
    let executor = RecordingProcessExecutor(outcomes: [])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    #expect(throws: RunnerBackendError.emptyCommand) {
        try backend.exec([], on: runnerID)
    }
    #expect(executor.requests.isEmpty)
}

@Test
func destroyReturnsWhenMachineIsAbsent() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "another-machine\n")),
    ])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    try backend.destroy(runnerID)

    #expect(executor.requests.map(\.arguments) == [
        ["machine", "list", "--quiet"],
    ])
}

@Test
func destroyDeletesOnlyAnExactMachineID() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "prefix-\(runnerID.value)\n\(runnerID.value)\n")),
        .success(processResult()),
    ])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    try backend.destroy(runnerID)

    #expect(executor.requests.map(\.arguments) == [
        ["machine", "list", "--quiet"],
        ["machine", "delete", runnerID.value],
    ])
}

@Test
func backendPreservesProcessFailureResult() {
    let failure = processResult(stdout: "partial", stderr: "failed", status: 7)
    let executor = RecordingProcessExecutor(outcomes: [.success(failure)])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    do {
        try backend.create(id: runnerID, image: "local/yieldd-guest:dev")
        Issue.record("Expected create to fail")
    } catch let ProcessExecutionError.nonZeroExit(request, result) {
        #expect(request == executor.requests[0])
        #expect(result == failure)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
