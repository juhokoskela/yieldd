import Darwin
import Foundation
import Testing
@testable import Yieldd

private let containerURL = URL(fileURLWithPath: "/usr/local/bin/container")
private let runnerID = RunnerID(value: "yieldd-test-123")

@Test
func createBuildsMachineWaitsForDockerAndConfiguresMemory() throws {
    let executor = RecordingProcessExecutor(outcomes: Array(
        repeating: .success(processResult()),
        count: 3
    ))
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    try backend.create(id: runnerID, memory: .full)

    #expect(executor.requests == [
        ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "machine", "create",
                "--name", runnerID.value,
                "--home-mount", "none",
                "--cpus", "4",
                "--memory", "12G",
                "local/yieldd-guest:dev",
            ],
            timeout: AppleContainerBackend.creationTimeout
        ),
        ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "machine", "run",
                "--name", runnerID.value,
                "--user", "runner",
                "--",
                "docker", "info",
            ],
            timeout: DockerReadiness.probeTimeout,
            outputCapture: .tail(maxBytes: 64 * 1_024)
        ),
        ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "machine", "run",
                "--name", runnerID.value,
                "--user", "root",
                "--",
                "yieldd-runner-control", "memory", "full",
            ],
            timeout: AppleContainerBackend.memoryConfigurationTimeout,
            outputCapture: .tail(maxBytes: 64 * 1_024)
        ),
    ])
}

@Test
func constructsExecCommandWithoutInterpretingArguments() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult(stdout: "ok"))])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })
    let arguments = ["printf", "%s", "value with spaces; $(whoami)"]

    try backend.exec(arguments, on: runnerID)

    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "run",
            "--name", runnerID.value,
            "--user", "runner",
            "--",
        ] + arguments,
        outputCapture: .tail(maxBytes: 64 * 1_024)
    )])
}

@Test
func createAppliesConstrainedMemoryAllocation() throws {
    let executor = RecordingProcessExecutor(outcomes: Array(
        repeating: .success(processResult()),
        count: 3
    ))
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    try backend.create(id: runnerID, memory: .constrained)

    #expect(executor.requests.last?.arguments.suffix(3) == [
        "yieldd-runner-control", "memory", "constrained",
    ])
}

@Test
func createRetriesDockerReadinessBeforeApplyingMemory() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .failure(TestFailure.dockerInfo),
        .success(processResult()),
        .success(processResult()),
    ])
    var waits: [TimeInterval] = []
    let backend = AppleContainerBackend(
        containerURL: containerURL,
        executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil },
        dockerReadiness: DockerReadiness(
            attempts: 2,
            retryDelay: 0.25,
            wait: { waits.append($0) }
        )
    )

    try backend.create(id: runnerID, memory: .full)

    #expect(waits == [0.25])
    #expect(executor.requests.map(\.arguments).filter {
        $0.suffix(2) == ["docker", "info"]
    }.count == 2)
    #expect(executor.requests.last?.arguments.suffix(3) == [
        "yieldd-runner-control", "memory", "full",
    ])
}

@Test
func createReportsFinalDockerReadinessFailureWithoutConfiguringMemory() {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .failure(TestFailure.dockerInfo),
        .failure(TestFailure.cleanup),
    ])
    let backend = AppleContainerBackend(
        containerURL: containerURL,
        executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil },
        dockerReadiness: DockerReadiness(
            attempts: 2,
            retryDelay: 0,
            wait: { _ in }
        )
    )

    #expect(throws: TestFailure.cleanup) {
        try backend.create(id: runnerID, memory: .full)
    }
    #expect(executor.requests.map(\.arguments).filter {
        $0.suffix(2) == ["docker", "info"]
    }.count == 2)
    #expect(!executor.requests.contains {
        $0.arguments.contains("memory")
    })
}

@Test
func createDoesNotRetryDockerLaunchFailure() {
    let request = ProcessRequest(
        executableURL: containerURL,
        arguments: ["machine", "run"]
    )
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .failure(ProcessExecutionError.launchFailed(
            request: request,
            underlying: TestFailure.dockerInfo
        )),
    ])
    var waits: [TimeInterval] = []
    let backend = AppleContainerBackend(
        containerURL: containerURL,
        executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil },
        dockerReadiness: DockerReadiness(wait: { waits.append($0) })
    )

    do {
        try backend.create(id: runnerID, memory: .full)
        Issue.record("Expected process launch to fail")
    } catch let ProcessExecutionError.launchFailed(actualRequest, _) {
        #expect(actualRequest == request)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(waits.isEmpty)
    #expect(executor.requests.count == 2)
}

@Test
func cancellationDuringDockerReadinessStopsRetries() {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .failure(TestFailure.dockerInfo),
    ])
    var cancellationChecks = 0
    let backend = AppleContainerBackend(
        containerURL: containerURL,
        executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil },
        dockerReadiness: DockerReadiness(
            wait: { _ in Issue.record("Cancelled readiness must not wait") },
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 2 {
                    throw SignalInterruption(signal: SIGINT)
                }
            }
        )
    )

    #expect(throws: SignalInterruption(signal: SIGINT)) {
        try backend.create(id: runnerID, memory: .full)
    }
    #expect(executor.requests.count == 2)
}

@Test
func stopRunnerUsesBoundedNoncancellableRootCommand() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

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
        outputCapture: .tail(maxBytes: 64 * 1_024),
        cancellable: false
    )])
}

@Test
func guestCommandsDefaultToBoundedOutput() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })
    try backend.exec(["yieldd-configure-runner", "--jit"], on: runnerID)
    #expect(executor.requests.first?.outputCapture == .tail(maxBytes: 64 * 1_024))
}

@Test
func rejectsEmptyGuestCommand() {
    let executor = RecordingProcessExecutor(outcomes: [])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    #expect(throws: RunnerBackendError.emptyCommand) {
        try backend.exec([], on: runnerID)
    }
    #expect(executor.requests.isEmpty)
}

@Test
func passesStandardInputWithoutPuttingItInArguments() throws {
    let standardInput = Data("registration-token".utf8)
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    try backend.exec(
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
        standardInput: standardInput,
        outputCapture: .tail(maxBytes: 64 * 1_024)
    )])
    #expect(!executor.requests[0].arguments.contains("registration-token"))
}

@Test
func passesTimeoutWithoutPuttingItInArguments() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    try backend.exec(
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
        timeout: 90,
        outputCapture: .tail(maxBytes: 64 * 1_024)
    )])
}

@Test
func passesBoundedOutputCaptureWithoutPuttingItInArguments() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    try backend.exec(
        ["yieldd-runner-control", "run"],
        timeout: nil,
        outputCapture: .tail(maxBytes: 1_024),
        as: .root,
        on: runnerID
    )

    #expect(executor.requests == [ProcessRequest(
        executableURL: containerURL,
        arguments: [
            "machine", "run",
            "--name", runnerID.value,
            "--user", "root",
            "--",
            "yieldd-runner-control", "run",
        ],
        outputCapture: .tail(maxBytes: 1_024)
    )])
}

@Test
func destroyReturnsWhenMachineIsAbsent() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "another-machine\n")),
    ])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

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
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    try backend.destroy(runnerID)

    #expect(executor.requests.map(\.arguments) == [
        ["machine", "list", "--quiet"],
        ["machine", "delete", runnerID.value],
    ])
    #expect(executor.requests.allSatisfy { !$0.cancellable })
    #expect(executor.requests.allSatisfy { $0.timeout == 90 })
}

@Test
func destroyAcceptsDeleteFailureWhenMachineIsConfirmedAbsent() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "\(runnerID.value)\n")),
        .failure(TestFailure.machineCleanup),
        .success(processResult(stdout: "another-machine\n")),
    ])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    try backend.destroy(runnerID)

    #expect(executor.requests.map(\.arguments) == [
        ["machine", "list", "--quiet"],
        ["machine", "delete", runnerID.value],
        ["machine", "list", "--quiet"],
    ])
}

@Test
func destroyPreservesDeleteFailureWhenMachineStillExists() {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "\(runnerID.value)\n")),
        .failure(TestFailure.machineCleanup),
        .success(processResult(stdout: "\(runnerID.value)\n")),
    ])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    #expect(throws: TestFailure.machineCleanup) {
        try backend.destroy(runnerID)
    }
    #expect(executor.requests.count == 3)
}

@Test
func destroyPreservesDeleteFailureWhenReconciliationFails() {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "\(runnerID.value)\n")),
        .failure(TestFailure.machineCleanup),
        .failure(TestFailure.unexpectedProcessRequest),
    ])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    #expect(throws: TestFailure.machineCleanup) {
        try backend.destroy(runnerID)
    }
    #expect(executor.requests.count == 3)
}

@Test
func backendPreservesProcessFailureResult() {
    let failure = processResult(stdout: "partial", stderr: "failed", status: 7)
    let executor = RecordingProcessExecutor(outcomes: [.success(failure)])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil })

    do {
        try backend.create(id: runnerID, memory: .full)
        Issue.record("Expected create to fail")
    } catch let ProcessExecutionError.nonZeroExit(request, result) {
        #expect(request == executor.requests[0])
        #expect(result == failure)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
