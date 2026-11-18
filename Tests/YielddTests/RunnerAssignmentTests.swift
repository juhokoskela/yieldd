import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

@Test
func jobStartEndsThePickupDeadline() throws {
    let backend = AssignmentBackend(statuses: [listening(false), listening(true), listening(true), exited(true)])
    var now: TimeInterval = 0
    var states: [RunnerSessionState] = []
    let job = ReservedRunnerJob(
        backend: backend, checkCancellation: {}, wait: { now += $0 }, stateChanged: { states.append($0) },
        currentTime: { now }
    )
    try job.run(id: assignmentID, pickupTimeout: 0.75)
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
        id: assignmentID, pickupTimeout: 300
    )
    #expect(states.contains(.jobStarted(assignmentID)))
    #expect(backend.commands == [["yieldd-runner-control", "start"], ["yieldd-runner-control", "status"]])
}

@Test
func runnerTimesOutWaitingForPickup() throws {
    let backend = AssignmentBackend(statuses: Array(repeating: listening(false), count: 4))
    var now: TimeInterval = 0
    let job = ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { now += $0 }, stateChanged: { _ in }, currentTime: { now })
    #expect(throws: RunnerAssignmentError.pickupTimedOut) {
        try job.run(id: assignmentID, pickupTimeout: 1)
    }
}

@Test(arguments: ["", "{}", "{\"phase\":\"exited\",\"jobStarted\":true}", "{\"phase\":\"exited\",\"jobStarted\":true,\"exitStatus\":256}", "{\"phase\":\"listening\",\"jobStarted\":true,\"exitStatus\":0}"])
func reservedRunnerRejectsMalformedStatus(_ status: String) throws {
    let backend = AssignmentBackend(statuses: [status])
    #expect(throws: RunnerAssignmentError.invalidStatus) {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300
        )
    }
}

@Test
func reservedRunnerDoesNotReportSuccessWhenNoJobRan() throws {
    let backend = AssignmentBackend(statuses: [exited(false)])
    #expect(throws: RunnerAssignmentError.exitedWithoutJob) {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300
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
    let outcomes: [Result<ProcessResult, any Error>] = [
        .success(processResult()), .success(processResult(stdout: exited(true, status: 7))), .success(replay),
    ]
    let (backend, _) = try readyLinuxBackend(outcomes: outcomes, containerURL: URL(fileURLWithPath: "/test/container"), id: assignmentID)
    let output = [replay.stdoutText, replay.stderrText]
        .filter { !$0.isEmpty }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(throws: RunnerAssignmentError.listenerFailed(7, output: output)) {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300
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
    let outcomes: [Result<ProcessResult, any Error>] = [
        .success(processResult()), .success(processResult(stdout: exited(true, status: 7))), .failure(expected),
    ]
    let (backend, _) = try readyLinuxBackend(outcomes: outcomes, containerURL: request.executableURL, id: assignmentID)
    do {
        try ReservedRunnerJob(backend: backend, checkCancellation: {}, wait: { _ in }, stateChanged: { _ in }).run(
            id: assignmentID, pickupTimeout: 300
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
            id: assignmentID, pickupTimeout: 300
        )
    }
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

private let assignmentID = RunnerID(value: "yieldd-reserved-test")
private func listening(_ started: Bool) -> String { "{\"phase\":\"listening\",\"jobStarted\":\(started)}" }
private func exited(_ started: Bool, status: Int32 = 0) -> String { "{\"phase\":\"exited\",\"jobStarted\":\(started),\"exitStatus\":\(status)}" }

private final class AssignmentBackend: RunnerBackend {
    let platform = RunnerPlatform.macOS
    var commands: [[String]] = []
    var statuses: [String]
    init(statuses: [String]) { self.statuses = statuses }
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws {}
    func exec(_ arguments: [String], standardInput: Data?, timeout: TimeInterval?, outputCapture: ProcessOutputCapture, as user: RunnerGuestUser, on id: RunnerID) throws -> ProcessResult {
        commands.append(arguments)
        if arguments == ["yieldd-runner-control", "status"] {
            guard !statuses.isEmpty else { throw TestFailure.unexpectedBackendCall }
            return processResult(stdout: statuses.removeFirst())
        }
        return processResult()
    }
    func destroy(_ id: RunnerID) throws {}
}
