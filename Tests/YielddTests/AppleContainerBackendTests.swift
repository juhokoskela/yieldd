import Darwin
import Foundation
import Testing
@testable import Yieldd

private let containerURL = URL(fileURLWithPath: "/usr/local/bin/container")
private let runnerID = RunnerID(value: "yieldd-test-123")

@Test
func createBuildsMachineWaitsForDockerAndConfiguresMemory() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult()), .success(linuxInspection(id: runnerID)), .success(processResult()),
                                                     .success(processResult()), .success(processResult())])
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

    try backend.create(id: runnerID, memory: .full)

    #expect(executor.requests == [
        ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "machine", "create",
                "--name", runnerID.value,
                "--no-boot",
                "--network-socket", "/unused/network.sock",
                "--home-mount", "none",
                "--cpus", "4",
                "--memory", "12G",
                "local/yieldd-guest:dev",
            ],
            timeout: AppleContainerBackend.creationTimeout
        ),
        ProcessRequest(executableURL: containerURL, arguments: ["machine", "inspect", runnerID.value],
                       timeout: 10, outputCapture: .tail(maxBytes: 64 * 1_024)),
        ProcessRequest(executableURL: containerURL, arguments: ["machine", "boot", runnerID.value],
                       timeout: AppleContainerBackend.creationTimeout),
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
    let outcomes: [Result<ProcessResult, any Error>] = [.success(processResult(stdout: "ok"))]
    let (backend, executor) = try readyLinuxBackend(outcomes: outcomes, containerURL: containerURL, id: runnerID)
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
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult()), .success(linuxInspection(id: runnerID)), .success(processResult()),
                                                     .success(processResult()), .success(processResult())])
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

    try backend.create(id: runnerID, memory: .constrained)

    #expect(executor.requests.last?.arguments.suffix(3) == [
        "yieldd-runner-control", "memory", "constrained",
    ])
}

@Test
func createRetriesDockerReadinessBeforeApplyingMemory() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .success(linuxInspection(id: runnerID)), .success(processResult()),
        .failure(TestFailure.dockerInfo),
        .success(processResult()),
        .success(processResult()),
    ])
    var waits: [TimeInterval] = []
    let backend = try makeLinuxBackend(
        containerURL: containerURL,
        executor: executor,
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
func createReportsFinalDockerReadinessFailureWithoutConfiguringMemory() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .success(linuxInspection(id: runnerID)), .success(processResult()),
        .failure(TestFailure.dockerInfo),
        .failure(TestFailure.cleanup),
    ])
    let backend = try makeLinuxBackend(
        containerURL: containerURL,
        executor: executor,
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
func createDoesNotRetryDockerLaunchFailure() throws {
    let request = ProcessRequest(
        executableURL: containerURL,
        arguments: ["machine", "run"]
    )
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .success(linuxInspection(id: runnerID)), .success(processResult()),
        .failure(ProcessExecutionError.launchFailed(
            request: request,
            underlying: TestFailure.dockerInfo
        )),
    ])
    var waits: [TimeInterval] = []
    let backend = try makeLinuxBackend(
        containerURL: containerURL,
        executor: executor,
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
    #expect(executor.requests.count == 4)
}

@Test
func cancellationDuringDockerReadinessStopsRetries() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .success(linuxInspection(id: runnerID)), .success(processResult()),
        .failure(TestFailure.dockerInfo),
    ])
    var cancellationChecks = 0
    let backend = try makeLinuxBackend(
        containerURL: containerURL,
        executor: executor,
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
    #expect(executor.requests.count == 4)
}

@Test
func stopRunnerRejectsAChangedContainerRoot() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let storage = RunnerStorage(volumePath: fixture.directory.resolvingSymlinksInPath().path,
                                volumeUUID: UUID().uuidString)
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()), .success(linuxInspection(id: runnerID)), .success(processResult()),
        .success(processResult()), .success(processResult()),
        .success(processResult(stdout: "{\"status\":\"running\",\"paths\":{\"appRoot\":\"\(fixture.directory.path)\"}}")),
    ])
    var rootChanged = false
    let backend = try AppleContainerBackend(containerURL: containerURL, executor: executor,
        stateDirectory: fixture.directory, loadStorage: {
            if !rootChanged { return nil }
            try storage.validateContainer(containerExecutable: containerURL, executor: executor)
            return storage
        }, network: BackendNetwork())
    try backend.create(id: runnerID, memory: .full)
    rootChanged = true
    executor.clearRequests()

    #expect(throws: RunnerStorageError.containerRootMismatch(path: storage.containerURL.path)) {
        try backend.stopRunner(on: runnerID)
    }
    #expect(executor.requests.map(\.arguments) == [["system", "status", "--format", "json"]])
}

@Test
func stopRunnerDoesNotReadStorageOrBootAnUnownedGuest() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let backend = try AppleContainerBackend(containerURL: containerURL, executor: executor,
                                         stateDirectory: fixture.directory)

    try backend.stopRunner(on: runnerID)
    #expect(executor.requests.isEmpty)
}

@Test
func stopRunnerUsesBoundedNoncancellableRootCommand() throws {
    let (backend, executor) = try readyLinuxBackend(outcomes: [.success(processResult())], containerURL: containerURL, id: runnerID)

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
    let outcomes: [Result<ProcessResult, any Error>] = [.success(processResult())]
    let (backend, executor) = try readyLinuxBackend(outcomes: outcomes, containerURL: containerURL, id: runnerID)
    try backend.exec(["yieldd-configure-runner", "--jit"], on: runnerID)
    #expect(executor.requests.first?.outputCapture == .tail(maxBytes: 64 * 1_024))
}

@Test
func rejectsEmptyGuestCommand() throws {
    let executor = RecordingProcessExecutor(outcomes: [])
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

    #expect(throws: RunnerBackendError.emptyCommand) {
        try backend.exec([], on: runnerID)
    }
    #expect(executor.requests.isEmpty)
}

@Test
func passesStandardInputWithoutPuttingItInArguments() throws {
    let standardInput = Data("registration-token".utf8)
    let outcomes: [Result<ProcessResult, any Error>] = [.success(processResult())]
    let (backend, executor) = try readyLinuxBackend(outcomes: outcomes, containerURL: containerURL, id: runnerID)

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
    let outcomes: [Result<ProcessResult, any Error>] = [.success(processResult())]
    let (backend, executor) = try readyLinuxBackend(outcomes: outcomes, containerURL: containerURL, id: runnerID)

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
    let outcomes: [Result<ProcessResult, any Error>] = [.success(processResult())]
    let (backend, executor) = try readyLinuxBackend(outcomes: outcomes, containerURL: containerURL, id: runnerID)

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
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

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
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

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
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

    try backend.destroy(runnerID)

    #expect(executor.requests.map(\.arguments) == [
        ["machine", "list", "--quiet"],
        ["machine", "delete", runnerID.value],
        ["machine", "list", "--quiet"],
    ])
}

@Test
func destroyPreservesDeleteFailureWhenMachineStillExists() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "\(runnerID.value)\n")),
        .failure(TestFailure.machineCleanup),
        .success(processResult(stdout: "\(runnerID.value)\n")),
    ])
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

    #expect(throws: TestFailure.machineCleanup) {
        try backend.destroy(runnerID)
    }
    #expect(executor.requests.count == 3)
}

@Test
func destroyPreservesDeleteFailureWhenReconciliationFails() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: "\(runnerID.value)\n")),
        .failure(TestFailure.machineCleanup),
        .failure(TestFailure.unexpectedProcessRequest),
    ])
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

    #expect(throws: TestFailure.machineCleanup) {
        try backend.destroy(runnerID)
    }
    #expect(executor.requests.count == 3)
}

@Test
func backendPreservesProcessFailureResult() throws {
    let failure = processResult(stdout: "partial", stderr: "failed", status: 7)
    let executor = RecordingProcessExecutor(outcomes: [.success(failure)])
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)

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
