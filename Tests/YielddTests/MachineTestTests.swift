import Darwin
import Foundation
import Testing
@testable import Yieldd

private let machineTestID = RunnerID(value: "yieldd-test-machine")

@Test
func machineTestRunsChecksAndCleanupInOrder() throws {
    let backend = RecordingRunnerBackend(
        execOutcomes: [.success(processResult(stdout: "hello world"))]
    )

    try MachineTestRunner(backend: backend).run(id: machineTestID)

    #expect(backend.calls == [
        .create(machineTestID, .constrained),
        .exec(machineTestID, ["docker", "run", "--rm", "hello-world"]),
        .destroy(machineTestID),
    ])
}

@Test
func failedHelloWorldStillCleansUp() {
    let backend = RecordingRunnerBackend(execOutcomes: [
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
        .create(machineTestID, .constrained),
        .destroy(machineTestID),
    ])
}

@Test
func cleanupFailureAfterSuccessfulChecksIsReported() {
    let backend = RecordingRunnerBackend(
        execOutcomes: [.success(processResult())],
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
        try MachineTestRunner(backend: backend).run(id: machineTestID)
        Issue.record("Expected operation and cleanup to fail")
    } catch let MachineTestError.operationAndCleanupFailed(operation, cleanup) {
        #expect(operation as? TestFailure == .create)
        #expect(cleanup as? TestFailure == .cleanup)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(backend.calls.filter { $0 == .destroy(machineTestID) }.count == 1)
}

@Test
func interruptionAfterCreateCleansUpWithoutRunningChecks() {
    let backend = RecordingRunnerBackend()
    var checks = 0
    let runner = MachineTestRunner(
        backend: backend,
        checkCancellation: {
            checks += 1
            if checks == 2 {
                throw SignalInterruption(signal: SIGTERM)
            }
        }
    )

    #expect(throws: SignalInterruption(signal: SIGTERM)) {
        try runner.run(id: machineTestID)
    }
    #expect(backend.calls == [
        .create(machineTestID, .constrained),
        .destroy(machineTestID),
    ])
}

private final class RecordingRunnerBackend: RunnerBackend {
    let memoryRequirements = RunnerMemoryRequirements(
        constrainedBytes: 1,
        fullBytes: 1
    )
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

    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws {
        calls.append(.create(id, memory))
        if let createError {
            throw createError
        }
    }

    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws -> ProcessResult {
        #expect(standardInput == nil)
        #expect(outputCapture == .all)
        #expect(user == .runner)
        #expect(timeout == MachineTestRunner.helloWorldTimeout)
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
    case create(RunnerID, RunnerMemoryAllocation)
    case exec(RunnerID, [String])
    case destroy(RunnerID)
}
