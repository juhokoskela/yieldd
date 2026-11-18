import Darwin
import Foundation
import Testing
@testable import Yieldd

private let machineTestID = RunnerID(value: "yieldd-test-machine")

private func machineTestMemoryAdmission() -> RunnerMemoryAdmission {
    RunnerMemoryAdmission(
        physicalMemoryBytes: 4 * AppleContainerBackend.memoryBytes,
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
        .exec(machineTestID, ["yieldd-configure-runner", "--protocol-version"]),
        .exec(machineTestID, ["yieldd-runner-control", "--protocol-version"]),
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
        .exec(machineTestID, ["yieldd-configure-runner", "--protocol-version"]),
        .exec(machineTestID, ["yieldd-runner-control", "--protocol-version"]),
        .exec(machineTestID, ["/bin/bash", "-s"]),
        .destroy(machineTestID),
    ])
}

@Test(arguments: [
    RunnerStorageError.notConfigured,
    .volumeUnavailable(path: "/Volumes/YielddRunners"),
    .containerRootMismatch(path: "/Volumes/YielddRunners/container"),
])
func machineTestPreflightFailurePreservesErrorAndReleasesMemory(
    failure: RunnerStorageError
) throws {
    let executor = RecordingProcessExecutor(outcomes: [])
    var storageChecks = 0
    let backend = try AppleContainerBackend(
        containerURL: URL(fileURLWithPath: "/test/container"), executor: executor,
        stateDirectory: unconfiguredContainerStateDirectory,
        loadStorage: {
            storageChecks += 1
            throw failure
        }
    )
    let reservationBytes = backend.platform.memoryReservationBytes
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: reservationBytes * 4 / 3,
        readMemoryPressure: { .normal }
    )
    let runner = MachineTestRunner(backend: backend, memoryAdmission: admission)

    #expect(throws: failure) { try runner.run(id: machineTestID) }
    #expect(storageChecks == 1)
    #expect(executor.requests.isEmpty)
    let reservation = try #require(try admission.tryAcquire(reserving: reservationBytes))
    admission.release(reservation)
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
    var onCreate: () throws -> Void = {}
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
        try onCreate()
        if let createError {
            throw createError
        }
    }

    @discardableResult func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws -> ProcessResult {
        calls.append(.exec(id, arguments))
        if arguments.last == "--protocol-version" { return processResult(stdout: "1\n") }
        if platform == .macOS {
            #expect(standardInput == Data(MacOSTemplateValidation.script.utf8))
            #expect(outputCapture == .tail(maxBytes: MacOSGuestSSH.outputTailBytes))
            #expect(timeout == MacOSTemplateValidation.timeout)
        } else {
            #expect(standardInput == nil)
            #expect(outputCapture == .tail(maxBytes: 64 * 1_024))
            #expect(timeout == MachineTestRunner.helloWorldTimeout)
        }
        #expect(user == .runner)
        guard !execOutcomes.isEmpty else {
            throw TestFailure.unexpectedBackendCall
        }
        try execOutcomes.removeFirst().get()
        return processResult()
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

@Test(arguments: [false, true])
func interruptedLinuxMachineTestRetainsExactGuestUntilDeletion(createFailed: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    let id = RunnerPlatform.linux.makeTestRunnerID()
    let backend = RecordingRunnerBackend(createError: createFailed ? TestFailure.helloWorld : nil,
        execOutcomes: [.success(())], destroyError: TestFailure.machineCleanup)
    #expect(throws: (any Error).self) { try machineTestRunner(backend: backend).run(id: id, journal: store) }
    #expect(try store.pendingMachineTest() == id)
    #expect(throws: MachineTestError.self) {
        try withRunnerOwnership(in: directory, connected: true) { _ in Issue.record("Outstanding guest was bypassed") }
    }
    let recovery = RecordingRunnerBackend()
    try withRunnerOwnership(in: directory, recoveringMachineTest: true) { reopened in
        try reopened.recoverMachineTest { recovery }
        try reopened.recoverMachineTest { throw TestFailure.unexpectedBackendCall }
    }
    #expect(recovery.calls == [.destroy(id)])
    #expect(try store.pendingMachineTest() == nil)
}

@Test
func machineTestRecoveryRejectsOtherMachineNames() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    try writePrivateRunnerFile(Data("someone-elses-machine".utf8), to: directory.appendingPathComponent("linux-machine-test"))
    #expect(throws: RunnerLeaseError.self) { try store.recoverMachineTest { throw TestFailure.unexpectedBackendCall } }
}

@Test
func machineTestJournalAndOwnershipSurviveKilledCreator() async throws {
    let result = try await #require(processExitsWith: .signal(SIGKILL), observing: [\.standardOutputContent]) {
        let uuid = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("machine-crash-\(uuid)")
        try withRunnerOwnership(in: directory, recoveringMachineTest: true) { store in
            let backend = RecordingRunnerBackend()
            backend.onCreate = {
                try FileHandle.standardOutput.write(contentsOf: Data(uuid.uuidString.utf8))
                raise(SIGKILL)
            }
            try machineTestRunner(backend: backend).run(
                id: RunnerID(value: "yieldd-test-\(uuid.uuidString.lowercased())"), journal: store)
        }
    }
    let uuid = try #require(UUID(uuidString: String(decoding: result.standardOutputContent, as: UTF8.self)))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("machine-crash-\(uuid)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovered = RecordingRunnerBackend()
    try withRunnerOwnership(in: directory, recoveringMachineTest: true) { store in
        try store.recoverMachineTest { recovered }
        #expect(try store.pendingMachineTest() == nil)
    }
    #expect(recovered.calls == [.destroy(RunnerID(value: "yieldd-test-\(uuid.uuidString.lowercased())"))])
}
