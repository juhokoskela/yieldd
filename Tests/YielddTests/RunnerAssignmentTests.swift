import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

@Test(arguments: ["", "yieldd-request-", "yieldd-macos", "yieldd-request-ABC", "yieldd-request-x,y", "yieldd-request-x\n", "yieldd-request-" + String(repeating: "x", count: 50)])
func reservedRunnerRejectsInvalidRoutingLabels(_ label: String) {
    #expect(throws: RunnerAssignmentError.invalidRoutingLabel) { try RunnerAssignment(routingLabel: label) }
}

@Test
func reservedRunnerUsesIndependentPickupAndExecutionDeadlines() throws {
    let backend = AssignmentBackend(statuses: [listening(false), listening(true), listening(true), exited(true)])
    var now: TimeInterval = 0
    var states: [RunnerSessionState] = []
    let job = ReservedRunnerJob(
        backend: backend, checkCancellation: {}, wait: { now += $0 }, stateChanged: { states.append($0) },
        currentTime: { now }
    )
    try job.run(id: assignmentID, pickupTimeout: 0.75, executionTimeout: 2)
    #expect(now > 0.75)
    #expect(states == [.listenerStarted(assignmentID), .jobStarted(assignmentID), .listenerExited(assignmentID, status: 0)])
}

@Test
func reservedRunnerObservesAJobThatFinishesBetweenPolls() throws {
    let backend = AssignmentBackend(statuses: [exited(true)])
    var states: [RunnerSessionState] = []
    try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in
        Issue.record("A completed listener must not wait")
    }, stateChanged: { states.append($0) }).run(
        id: assignmentID, pickupTimeout: 300, executionTimeout: 10
    )
    #expect(states.contains(.jobStarted(assignmentID)))
    #expect(backend.commands.last == ["yieldd-runner-control", "run"])
}

@Test(arguments: [false, true])
func reservedRunnerTimesOutInTheCorrectPhase(started: Bool) throws {
    let backend = AssignmentBackend(statuses: Array(repeating: listening(started), count: 4))
    var now: TimeInterval = 0
    let job = ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { now += $0 }, stateChanged: { _ in }, currentTime: { now })
    #expect(throws: started ? RunnerAssignmentError.executionTimedOut : .pickupTimedOut) {
        try job.run(id: assignmentID, pickupTimeout: 1, executionTimeout: 1)
    }
}

@Test(arguments: ["", "{}", "{\"phase\":\"exited\",\"jobStarted\":true}", "{\"phase\":\"exited\",\"jobStarted\":true,\"exitStatus\":256}", "{\"phase\":\"listening\",\"jobStarted\":true,\"exitStatus\":0}"])
func reservedRunnerRejectsMalformedStatus(_ status: String) throws {
    let backend = AssignmentBackend(statuses: [status])
    #expect(throws: RunnerAssignmentError.invalidStatus) {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300, executionTimeout: 10
        )
    }
}

@Test
func reservedRunnerDoesNotReportSuccessWhenNoJobRan() throws {
    let backend = AssignmentBackend(statuses: [exited(false)])
    #expect(throws: RunnerAssignmentError.exitedWithoutJob) {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300, executionTimeout: 10
        )
    }
}

@Test(arguments: [
    processResult(stdout: "fatal: runner crashed\n", status: 7),
    processResult(stderr: "fatal: hook failed\n", status: 7),
    processResult(stdout: "listener output\n", stderr: "runner warning\n", status: 7),
    processResult(status: 7),
])
func reservedRunnerReportsFailedListenerOutput(_ replay: ProcessResult) throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()), .success(processResult(stdout: exited(true, status: 7))), .success(replay),
    ])
    let backend = try readyLinuxBackend(executor: executor, containerURL: URL(fileURLWithPath: "/test/container"), id: assignmentID)
    let output = [replay.stdoutText, replay.stderrText]
        .filter { !$0.isEmpty }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(throws: RunnerAssignmentError.listenerFailed(7, output: output)) {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300, executionTimeout: 10
        )
    }
}

@Test(arguments: ["transport", "cancelled", "timeout", "signal"])
func reservedRunnerPreservesReplayTransportAndCancellationErrors(_ failure: String) throws {
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/test/ssh"), arguments: [])
    let result = processResult(stderr: "transport diagnostic", status: 255)
    let expected: ProcessExecutionError = switch failure {
    case "cancelled": .cancelled(request: request, result: result, underlying: CancellationError())
    case "timeout": .timedOut(request: request, result: result)
    case "signal": .terminatedBySignal(request: request, result: result)
    default: .nonZeroExit(request: request, result: result)
    }
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()), .success(processResult(stdout: exited(true, status: 7))), .failure(expected),
    ])
    let backend = try readyLinuxBackend(executor: executor, containerURL: request.executableURL, id: assignmentID)
    do {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300, executionTimeout: 10
        )
        Issue.record("Expected replay failure")
    } catch let error as ProcessExecutionError {
        #expect(describeError(error) == describeError(expected))
    }
}

@Test
func reservedRunnerRejectsReplayThatDisagreesWithTerminalStatus() throws {
    let backend = AssignmentBackend(statuses: [exited(true, status: 7)])
    #expect(throws: RunnerAssignmentError.invalidStatus) {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300, executionTimeout: 10
        )
    }
}

@Test(arguments: [false, true])
func reservedSessionReleasesCapacityOnlyAfterMachineRemoval(destructionFails: Bool) throws {
    let backend = AssignmentBackend(statuses: [exited(true)], destructionFails: destructionFails)
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 12 * 1024 * 1024 * 1024, readMemoryPressure: { .normal })
    var states: [RunnerSessionState] = []
    let session = EphemeralRunnerSession(
        backend: backend, github: AssignmentGitHub(), memoryAdmission: memory,
        stateChanged: {
            if $0 == .capacityReleased(assignmentID) { #expect(backend.destroyed) }
            states.append($0)
        }, assignment: try RunnerAssignment(routingLabel: "yieldd-request-test")
    )
    if destructionFails {
        do {
            try session.run(id: assignmentID, repository: GitHubRepository("owner/repo"))
            Issue.record("Expected machine cleanup failure")
        } catch let RunnerSessionError.cleanupFailed(failures) {
            #expect(failures.map(\.step) == [.machine])
        }
        #expect(!states.contains(.capacityReleased(assignmentID)))
        #expect(!states.contains(.cleanupCompleted(assignmentID)))
        #expect(throws: TestFailure.memoryAllocation) {
            try memory.acquireWithoutWaiting(reserving: RunnerPlatform.macOS.memoryReservationBytes)
        }
    } else {
        try session.run(id: assignmentID, repository: GitHubRepository("owner/repo"))
        #expect(states.suffix(2) == [.capacityReleased(assignmentID), .cleanupCompleted(assignmentID)])
        memory.release(try memory.acquireWithoutWaiting(reserving: RunnerPlatform.macOS.memoryReservationBytes))
    }
    #expect(backend.commands.first == ["yieldd-configure-runner", "owner/repo", assignmentID.value, "yieldd-request-test"])
}

@Test
func startupDeadlineDoesNotApplyToJobsOrCleanup() throws {
    var now: TimeInterval = 0
    let deadline = RunnerStartupDeadline(currentTime: { now }, checkCancellation: {})
    deadline.begin()
    now = 601
    #expect(throws: RunnerAssignmentError.startupTimedOut) { try deadline.check() }
    deadline.end()
    try deadline.check()
}

@Test(arguments: ["yieldd-configure-runner", "start", "status", "cancel"])
func reservedSessionCleansUpAfterSetupTransportOrCancellationFailure(_ failure: String) throws {
    let backend = AssignmentBackend(statuses: [listening(false)], failingCommand: failure)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 12 * 1024 * 1024 * 1024, readMemoryPressure: { .normal })
    let session = EphemeralRunnerSession(
        backend: backend, github: AssignmentGitHub(), memoryAdmission: memory,
        checkCancellation: {
            if failure == "cancel", backend.commands.contains(["yieldd-runner-control", "start"]) {
                throw CancellationError()
            }
        }, leaseStore: store, assignment: try RunnerAssignment(routingLabel: "yieldd-request-test")
    )
    do {
        try session.run(id: assignmentID, repository: GitHubRepository("owner/repo"))
        Issue.record("Expected the injected operation failure")
    } catch is CancellationError {
        #expect(failure == "cancel")
    } catch let error as TestFailure {
        #expect(error == .runnerJob)
    }
    #expect(backend.destroyed)
    #expect(try store.load().isEmpty)
    memory.release(try memory.acquireWithoutWaiting(reserving: RunnerPlatform.macOS.memoryReservationBytes))
}

@Test
func startupFailureEndsItsDeadlineBeforeSessionCleanup() throws {
    var now: TimeInterval = 0
    let deadline = RunnerStartupDeadline(currentTime: { now }, checkCancellation: {})
    let backend = AssignmentBackend(statuses: [])
    backend.onCreate = { now = 601; try deadline.check() }
    backend.onDestroy = { try deadline.check() }
    let session = EphemeralRunnerSession(
        backend: backend, github: AssignmentGitHub(),
        memoryAdmission: RunnerMemoryAdmission(physicalMemoryBytes: 12 * 1024 * 1024 * 1024, readMemoryPressure: { .normal }),
        checkCancellation: deadline.check,
        assignment: try RunnerAssignment(routingLabel: "yieldd-request-test"), startupDeadline: deadline
    )
    #expect(throws: RunnerAssignmentError.startupTimedOut) {
        try session.run(id: assignmentID, repository: GitHubRepository("owner/repo"))
    }
    #expect(backend.destroyed)
}

@Test
func reservedRunnerCLIValidatesAndForwardsAssignment() throws {
    let command = try RunnerTestCommand.parse(["owner/repo", "--routing-label", "yieldd-request-test", "--pickup-timeout", "2", "--timeout", "15"])
    #expect(try command.assignment()?.routingLabel == "yieldd-request-test")
    #expect(try command.assignment()?.pickupTimeout == 120)
    #expect(command.timeout == 15)
    var invalid = try RunnerTestCommand.parse(["owner/repo"])
    invalid.pickupTimeout = 1
    #expect(throws: ValidationError.self) { try invalid.validate() }
}

private let assignmentID = RunnerID(value: "yieldd-reserved-test")
private func listening(_ started: Bool) -> String { "{\"phase\":\"listening\",\"jobStarted\":\(started)}" }
private func exited(_ started: Bool, status: Int32 = 0) -> String { "{\"phase\":\"exited\",\"jobStarted\":\(started),\"exitStatus\":\(status)}" }

private final class AssignmentBackend: RunnerBackend {
    let platform = RunnerPlatform.macOS
    var commands: [[String]] = []
    var destroyed = false
    var statuses: [String]
    let destructionFails: Bool
    let failingCommand: String?
    var onCreate: () throws -> Void = {}
    var onDestroy: () throws -> Void = {}
    init(statuses: [String], destructionFails: Bool = false, failingCommand: String? = nil) {
        self.statuses = statuses
        self.destructionFails = destructionFails
        self.failingCommand = failingCommand
    }
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws { try onCreate() }
    func exec(_ arguments: [String], standardInput: Data?, timeout: TimeInterval?, outputCapture: ProcessOutputCapture, as user: RunnerGuestUser, on id: RunnerID) throws -> ProcessResult {
        commands.append(arguments)
        if let failingCommand, arguments.contains(failingCommand) { throw TestFailure.runnerJob }
        if arguments == ["yieldd-runner-control", "status"] {
            guard !statuses.isEmpty else { throw TestFailure.unexpectedBackendCall }
            return processResult(stdout: statuses.removeFirst())
        }
        return processResult()
    }
    func stopRunner(on id: RunnerID) throws {}
    func destroy(_ id: RunnerID) throws {
        try onDestroy()
        if destructionFails { throw TestFailure.machineCleanup }
        destroyed = true
    }
}

private struct AssignmentGitHub: GitHubRunnerManaging {
    func createRegistrationToken(for repository: GitHubRepository) throws -> String { "token" }
    func removeRunners(named name: String, from repository: GitHubRepository) throws {}
}
