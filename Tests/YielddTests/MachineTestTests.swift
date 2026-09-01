import Foundation
import Testing
@testable import Yieldd

private let machineTestID = RunnerID(value: "yieldd-test-machine")

@Test
func machineTestRunsChecksAndCleanupInOrder() throws {
    let backend = RecordingRunnerBackend(
        execOutcomes: [
            .success(processResult(stdout: "docker info")),
            .success(processResult(stdout: "hello world")),
        ]
    )

    let result = try MachineTestRunner(backend: backend).run(id: machineTestID)

    #expect(result.dockerInfo.stdoutText == "docker info")
    #expect(result.helloWorld.stdoutText == "hello world")
    #expect(backend.calls == [
        .create(machineTestID, MachineTestRunner.image),
        .exec(machineTestID, ["docker", "info"]),
        .exec(machineTestID, ["docker", "run", "--rm", "hello-world"]),
        .destroy(machineTestID),
    ])
}

@Test
func failedDockerInfoSkipsHelloWorldAndCleansUp() {
    let backend = RecordingRunnerBackend(execOutcomes: [.failure(TestFailure.dockerInfo)])
    let runner = MachineTestRunner(
        backend: backend,
        dockerInfoAttempts: 1,
        sleep: { _ in }
    )

    #expect(throws: TestFailure.dockerInfo) {
        try runner.run(id: machineTestID)
    }
    #expect(backend.calls == [
        .create(machineTestID, MachineTestRunner.image),
        .exec(machineTestID, ["docker", "info"]),
        .destroy(machineTestID),
    ])
}

@Test
func retriesDockerInfoWhileTheMachineBoots() throws {
    let backend = RecordingRunnerBackend(execOutcomes: [
        .failure(TestFailure.dockerInfo),
        .success(processResult(stdout: "docker info")),
        .success(processResult(stdout: "hello world")),
    ])
    var delays: [TimeInterval] = []
    let runner = MachineTestRunner(
        backend: backend,
        dockerInfoAttempts: 2,
        retryDelay: 0.25,
        sleep: { delays.append($0) }
    )

    _ = try runner.run(id: machineTestID)

    #expect(delays == [0.25])
    #expect(backend.calls == [
        .create(machineTestID, MachineTestRunner.image),
        .exec(machineTestID, ["docker", "info"]),
        .exec(machineTestID, ["docker", "info"]),
        .exec(machineTestID, ["docker", "run", "--rm", "hello-world"]),
        .destroy(machineTestID),
    ])
}

@Test
func launchFailureDoesNotRetryDockerInfo() {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/container"),
        arguments: ["machine", "run"]
    )
    let backend = RecordingRunnerBackend(execOutcomes: [
        .failure(ProcessExecutionError.launchFailed(
            request: request,
            underlying: TestFailure.dockerInfo
        )),
    ])
    var delays: [TimeInterval] = []
    let runner = MachineTestRunner(
        backend: backend,
        dockerInfoAttempts: 30,
        sleep: { delays.append($0) }
    )

    do {
        _ = try runner.run(id: machineTestID)
        Issue.record("Expected process launch to fail")
    } catch let ProcessExecutionError.launchFailed(actualRequest, _) {
        #expect(actualRequest == request)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(delays.isEmpty)
    #expect(backend.calls == [
        .create(machineTestID, MachineTestRunner.image),
        .exec(machineTestID, ["docker", "info"]),
        .destroy(machineTestID),
    ])
}

@Test
func failedHelloWorldStillCleansUp() {
    let backend = RecordingRunnerBackend(execOutcomes: [
        .success(processResult()),
        .failure(TestFailure.helloWorld),
    ])

    #expect(throws: TestFailure.helloWorld) {
        try MachineTestRunner(backend: backend).run(id: machineTestID)
    }
    #expect(backend.calls.last == .destroy(machineTestID))
    #expect(backend.calls.filter { $0 == .destroy(machineTestID) }.count == 1)
}

@Test
func failedCreateStillAttemptsCleanup() {
    let backend = RecordingRunnerBackend(createError: TestFailure.create)

    #expect(throws: TestFailure.create) {
        try MachineTestRunner(backend: backend).run(id: machineTestID)
    }
    #expect(backend.calls == [
        .create(machineTestID, MachineTestRunner.image),
        .destroy(machineTestID),
    ])
}

@Test
func cleanupFailureAfterSuccessfulChecksIsReported() {
    let backend = RecordingRunnerBackend(
        execOutcomes: [.success(processResult()), .success(processResult())],
        destroyError: TestFailure.cleanup
    )

    #expect(throws: TestFailure.cleanup) {
        try MachineTestRunner(backend: backend).run(id: machineTestID)
    }
}

@Test
func operationAndCleanupFailuresAreBothRetained() {
    let backend = RecordingRunnerBackend(
        createError: TestFailure.create,
        destroyError: TestFailure.cleanup
    )

    do {
        _ = try MachineTestRunner(backend: backend).run(id: machineTestID)
        Issue.record("Expected operation and cleanup to fail")
    } catch let MachineTestError.operationAndCleanupFailed(operation, cleanup) {
        #expect(operation as? TestFailure == .create)
        #expect(cleanup as? TestFailure == .cleanup)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(backend.calls.filter { $0 == .destroy(machineTestID) }.count == 1)
}

private final class RecordingRunnerBackend: RunnerBackend {
    private(set) var calls: [RunnerBackendCall] = []
    private let createError: (any Error)?
    private var execOutcomes: [Result<ProcessResult, any Error>]
    private let destroyError: (any Error)?

    init(
        createError: (any Error)? = nil,
        execOutcomes: [Result<ProcessResult, any Error>] = [],
        destroyError: (any Error)? = nil
    ) {
        self.createError = createError
        self.execOutcomes = execOutcomes
        self.destroyError = destroyError
    }

    func create(id: RunnerID, image: String) throws {
        calls.append(.create(id, image))
        if let createError {
            throw createError
        }
    }

    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws -> ProcessResult {
        #expect(standardInput == nil)
        #expect(user == .runner)
        if arguments == ["docker", "info"] {
            #expect(timeout == DockerReadiness.probeTimeout)
        } else {
            #expect(timeout == nil)
        }
        calls.append(.exec(id, arguments))
        guard !execOutcomes.isEmpty else {
            throw TestFailure.unexpectedBackendCall
        }
        return try execOutcomes.removeFirst().get()
    }

    func destroy(_ id: RunnerID) throws {
        calls.append(.destroy(id))
        if let destroyError {
            throw destroyError
        }
    }

    func stopRunner(on id: RunnerID) throws {
        Issue.record("Machine tests must not stop a runner")
    }
}

private enum RunnerBackendCall: Equatable {
    case create(RunnerID, String)
    case exec(RunnerID, [String])
    case destroy(RunnerID)
}
