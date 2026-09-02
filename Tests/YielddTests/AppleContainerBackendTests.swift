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
            "--cpus", "4",
            "--memory", "12G",
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
func constructsRootCommandForCPUAllocation() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    _ = try backend.setCPUAllocation(.full, on: runnerID)

    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "run",
            "--name", runnerID.value,
            "--user", "root",
            "--",
            "yieldd-runner-control", "cpu", "full",
        ]
    )])
}

@Test
func constructsRootCommandForMemoryAllocation() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    _ = try backend.setMemoryAllocation(.constrained, on: runnerID)

    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "run",
            "--name", runnerID.value,
            "--user", "root",
            "--",
            "yieldd-runner-control", "memory", "constrained",
        ]
    )])
}

@Test
func stopRunnerUsesBoundedNoncancellableRootCommand() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    try backend.stopRunner(on: runnerID)

    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "run",
            "--name", runnerID.value,
            "--user", "root",
            "--",
            "yieldd-runner-control", "stop",
        ],
        timeout: AppleContainerBackend.runnerStopTimeout,
        cancellable: false
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
func passesStandardInputWithoutPuttingItInArguments() throws {
    let standardInput = Data("registration-token".utf8)
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    _ = try backend.exec(
        ["yieldd-configure-runner", "owner/repository", runnerID.value],
        standardInput: standardInput,
        on: runnerID
    )

    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "run",
            "--name", runnerID.value,
            "--user", "runner",
            "--interactive",
            "--",
            "yieldd-configure-runner", "owner/repository", runnerID.value,
        ],
        standardInput: standardInput
    )])
    #expect(!executor.requests[0].arguments.contains("registration-token"))
}

@Test
func passesTimeoutWithoutPuttingItInArguments() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor)

    _ = try backend.exec(
        ["/opt/actions-runner/run.sh"],
        timeout: 90,
        on: runnerID
    )

    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "run",
            "--name", runnerID.value,
            "--user", "runner",
            "--",
            "/opt/actions-runner/run.sh",
        ],
        timeout: 90
    )])
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
    #expect(executor.requests.allSatisfy { !$0.cancellable })
    #expect(executor.requests.allSatisfy { $0.timeout == 90 })
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
    #expect(executor.requests.allSatisfy { !$0.cancellable })
    #expect(executor.requests.allSatisfy { $0.timeout == 90 })
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
