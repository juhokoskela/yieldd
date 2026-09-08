import Darwin
import Foundation
import Testing
@testable import Yieldd

private let machineTestID = RunnerID(value: "yieldd-test-machine")

private func machineTestMemoryAdmission() -> RunnerMemoryAdmission {
    RunnerMemoryAdmission(
        physicalMemoryBytes: 4,
        reservationBytes: 1,
        readMemoryPressure: { .normal }
    )
}

private func machineTestRunner(backend: any RunnerBackend) -> MachineTestRunner {
    MachineTestRunner(
        backend: backend,
        memoryAdmission: machineTestMemoryAdmission()
    )
}

@Test
func machineTestRunsChecksAndCleanupInOrder() throws {
    let backend = RecordingRunnerBackend(
        execOutcomes: [.success(())]
    )

    try machineTestRunner(backend: backend).run(id: machineTestID)

    #expect(backend.calls == [
        .create(machineTestID, .full),
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
        try machineTestRunner(backend: backend).run(id: machineTestID)
    }
    #expect(backend.calls.last == .destroy(machineTestID))
    #expect(backend.calls.filter { $0 == .destroy(machineTestID) }.count == 1)
}

@Test(arguments: [false, true])
func macOSMachineValidationAlwaysDestroysClone(validationFails: Bool) throws {
    let backend = RecordingRunnerBackend(
        platform: .macOS,
        execOutcomes: [validationFails ? .failure(TestFailure.helloWorld) : .success(())]
    )
    if validationFails {
        #expect(throws: TestFailure.helloWorld) {
            try machineTestRunner(backend: backend).run(id: machineTestID)
        }
    } else {
        try machineTestRunner(backend: backend).run(id: machineTestID)
    }
    #expect(backend.calls == [
        .create(machineTestID, .full),
        .exec(machineTestID, ["/bin/bash", "-s"]),
        .destroy(machineTestID),
    ])
}

@Test
func failedCreateStillAttemptsCleanup() {
    let backend = RecordingRunnerBackend(createError: TestFailure.create)

    #expect(throws: TestFailure.create) {
        try machineTestRunner(backend: backend).run(id: machineTestID)
    }
    #expect(backend.calls == [
        .create(machineTestID, .full),
        .destroy(machineTestID),
    ])
}

@Test
func cleanupFailureAfterSuccessfulChecksIsReported() {
    let backend = RecordingRunnerBackend(
        execOutcomes: [.success(())],
        destroyError: TestFailure.cleanup
    )

    #expect(throws: TestFailure.cleanup) {
        try machineTestRunner(backend: backend).run(id: machineTestID)
    }
}

@Test
func operationAndCleanupFailuresAreBothRetained() {
    let backend = RecordingRunnerBackend(
        createError: TestFailure.create,
        destroyError: TestFailure.cleanup
    )

    do {
        try machineTestRunner(backend: backend).run(id: machineTestID)
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
        memoryAdmission: machineTestMemoryAdmission(),
        checkCancellation: {
            checks += 1
            if checks == 3 {
                throw SignalInterruption(signal: SIGTERM)
            }
        }
    )

    #expect(throws: SignalInterruption(signal: SIGTERM)) {
        try runner.run(id: machineTestID)
    }
    #expect(backend.calls == [
        .create(machineTestID, .full),
        .destroy(machineTestID),
    ])
}

private final class RecordingRunnerBackend: RunnerBackend {
    let platform: RunnerPlatform
    private(set) var calls: [RunnerBackendCall] = []
    private let createError: (any Error)?
    private var execOutcomes: [Result<Void, any Error>]
    private let destroyError: (any Error)?

    init(
        platform: RunnerPlatform = .linux,
        createError: (any Error)? = nil,
        execOutcomes: [Result<Void, any Error>] = [],
        destroyError: (any Error)? = nil
    ) {
        self.platform = platform
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
    ) throws {
        if platform == .macOS {
            #expect(standardInput == Data(MacOSTemplateValidation.script.utf8))
            #expect(outputCapture == .tail(maxBytes: MacOSGuestSSH.outputTailBytes))
            #expect(timeout == MacOSTemplateValidation.timeout)
        } else {
            #expect(standardInput == nil)
            #expect(outputCapture == .all)
            #expect(timeout == MachineTestRunner.helloWorldTimeout)
        }
        #expect(user == .runner)
        calls.append(.exec(id, arguments))
        guard !execOutcomes.isEmpty else {
            throw TestFailure.unexpectedBackendCall
        }
        try execOutcomes.removeFirst().get()
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
