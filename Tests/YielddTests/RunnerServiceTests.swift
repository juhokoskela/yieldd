import Darwin
import Foundation
import Testing
@testable import Yieldd

private let serviceRepository = try! GitHubRepository("owner/repository")

@Test
func serviceRunsOneSessionAtATimeUntilStopped() throws {
    var stopped = false
    let session = RecordingRunnerSession(
        outcomes: [.success(()), .success(())],
        onRun: { count in
            if count == 2 {
                stopped = true
            }
        }
    )
    var nextID = 0
    var states: [RunnerServiceState] = []

    try RunnerService(
        session: session,
        makeRunnerID: {
            nextID += 1
            return RunnerID(value: "runner-\(nextID)")
        },
        checkForStop: {
            if stopped {
                throw SignalInterruption(signal: SIGINT)
            }
        },
        waitUntilStopped: { _ in
            Issue.record("Successful sessions must not back off")
        },
        stateChanged: { states.append($0) }
    ).run(repository: serviceRepository)

    #expect(session.calls == [
        RunnerSessionCall(id: RunnerID(value: "runner-1"), repository: serviceRepository),
        RunnerSessionCall(id: RunnerID(value: "runner-2"), repository: serviceRepository),
    ])
    #expect(session.maximumActiveSessions == 1)
    #expect(states == [.stopping])
}

@Test
func successfulSessionResetsExponentialBackoff() throws {
    var stopped = false
    let session = RecordingRunnerSession(outcomes: [
        .failure(TestFailure.runnerJob),
        .failure(TestFailure.runnerJob),
        .success(()),
        .failure(TestFailure.runnerJob),
    ])
    var nextID = 0
    var delays: [TimeInterval] = []
    var states: [RunnerServiceState] = []
    var failures = 0

    try RunnerService(
        session: session,
        makeRunnerID: {
            nextID += 1
            return RunnerID(value: "runner-\(nextID)")
        },
        checkForStop: {
            if stopped {
                throw SignalInterruption(signal: SIGINT)
            }
        },
        waitUntilStopped: { delay in
            delays.append(delay)
            if delays.count == 3 {
                stopped = true
            }
        },
        stateChanged: { states.append($0) },
        sessionFailed: { _ in failures += 1 }
    ).run(repository: serviceRepository)

    #expect(session.calls.count == 4)
    #expect(delays == [1, 2, 1])
    #expect(failures == 3)
    #expect(states == [
        .backingOff(failures: 1, delay: 1),
        .backingOff(failures: 2, delay: 2),
        .backingOff(failures: 1, delay: 1),
        .stopping,
    ])
}

@Test
func backoffStopsGrowingAtMaximum() throws {
    var stopped = false
    let session = RecordingRunnerSession(
        outcomes: Array(repeating: .failure(TestFailure.runnerJob), count: 5)
    )
    var delays: [TimeInterval] = []

    try RunnerService(
        session: session,
        makeRunnerID: { RunnerID(value: UUID().uuidString) },
        checkForStop: {
            if stopped {
                throw SignalInterruption(signal: SIGINT)
            }
        },
        waitUntilStopped: { delay in
            delays.append(delay)
            if delays.count == 5 {
                stopped = true
            }
        },
        initialBackoff: 1,
        maximumBackoff: 4
    ).run(repository: serviceRepository)

    #expect(delays == [1, 2, 4, 4, 4])
}

@Test
func stopAfterSessionFailureSkipsRetry() throws {
    var stopped = false
    let session = RecordingRunnerSession(
        outcomes: [.failure(TestFailure.cancelled)],
        onRun: { _ in stopped = true }
    )
    var states: [RunnerServiceState] = []
    var reportedFailures = 0

    try RunnerService(
        session: session,
        makeRunnerID: { RunnerID(value: "runner-1") },
        checkForStop: {
            if stopped {
                throw SignalInterruption(signal: SIGINT)
            }
        },
        waitUntilStopped: { _ in
            Issue.record("A stopped service must not back off")
        },
        stateChanged: { states.append($0) },
        sessionFailed: { _ in reportedFailures += 1 }
    ).run(repository: serviceRepository)

    #expect(session.calls.count == 1)
    #expect(reportedFailures == 1)
    #expect(states == [.stopping])
}

@Test
func cleanupFailureStopsServiceBeforeAnotherRunnerStarts() {
    let cleanupFailure = RunnerSessionError.cleanupFailed([
        RunnerSessionCleanupFailure(step: .machine, error: TestFailure.machineCleanup),
    ])
    let session = RecordingRunnerSession(outcomes: [.failure(cleanupFailure)])
    var states: [RunnerServiceState] = []

    do {
        try RunnerService(
            session: session,
            makeRunnerID: { RunnerID(value: "runner-1") },
            checkForStop: {},
            waitUntilStopped: { _ in
                Issue.record("Cleanup failure must not be retried with a new runner")
            },
            stateChanged: { states.append($0) }
        ).run(repository: serviceRepository)
        Issue.record("Expected cleanup failure")
    } catch RunnerSessionError.cleanupFailed {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(session.calls.count == 1)
    #expect(states == [.stopping])
}

@Test
func deferredCleanupStopsWithoutReportingAFailure() throws {
    let runnerID = RunnerID(value: "runner-1")
    let session = RecordingRunnerSession(outcomes: [
        .failure(RunnerSessionError.cleanupDeferred(
            runnerID,
            operation: TestFailure.cancelled
        )),
    ])
    var states: [RunnerServiceState] = []
    var reportedFailures = 0

    try RunnerService(
        session: session,
        makeRunnerID: { runnerID },
        checkForStop: {},
        waitUntilStopped: { _ in
            Issue.record("Deferred cleanup must not back off")
        },
        stateChanged: { states.append($0) },
        sessionFailed: { _ in reportedFailures += 1 }
    ).run(repository: serviceRepository)

    #expect(session.calls.count == 1)
    #expect(reportedFailures == 0)
    #expect(states == [
        .cleanupDeferred(runnerID),
        .stopping,
    ])
}

@Test
func stopDuringBackoffSkipsNextSession() throws {
    let session = RecordingRunnerSession(outcomes: [.failure(TestFailure.runnerJob)])
    var states: [RunnerServiceState] = []

    try RunnerService(
        session: session,
        makeRunnerID: { RunnerID(value: "runner-1") },
        checkForStop: {},
        waitUntilStopped: { _ in throw SignalInterruption(signal: SIGTERM) },
        stateChanged: { states.append($0) }
    ).run(repository: serviceRepository)

    #expect(session.calls.count == 1)
    #expect(states == [
        .backingOff(failures: 1, delay: 1),
        .stopping,
    ])
}

@Test
func unexpectedStopCheckFailureIsPropagated() {
    let session = RecordingRunnerSession(outcomes: [])
    var states: [RunnerServiceState] = []

    #expect(throws: TestFailure.cancelled) {
        try RunnerService(
            session: session,
            makeRunnerID: { RunnerID(value: "runner-1") },
            checkForStop: { throw TestFailure.cancelled },
            waitUntilStopped: { _ in },
            stateChanged: { states.append($0) }
        ).run(repository: serviceRepository)
    }

    #expect(session.calls.isEmpty)
    #expect(states.isEmpty)
}

@Test
func unexpectedBackoffWaitFailureIsPropagated() {
    let session = RecordingRunnerSession(outcomes: [.failure(TestFailure.runnerJob)])
    var states: [RunnerServiceState] = []

    #expect(throws: TestFailure.cancelled) {
        try RunnerService(
            session: session,
            makeRunnerID: { RunnerID(value: "runner-1") },
            checkForStop: {},
            waitUntilStopped: { _ in throw TestFailure.cancelled },
            stateChanged: { states.append($0) }
        ).run(repository: serviceRepository)
    }

    #expect(session.calls.count == 1)
    #expect(states == [.backingOff(failures: 1, delay: 1)])
}

private struct RunnerSessionCall: Equatable {
    let id: RunnerID
    let repository: GitHubRepository
}

private final class RecordingRunnerSession: RunnerSessionRunning {
    private var outcomes: [Result<Void, any Error>]
    private let onRun: (Int) -> Void
    private(set) var calls: [RunnerSessionCall] = []
    private var activeSessions = 0
    private(set) var maximumActiveSessions = 0

    init(
        outcomes: [Result<Void, any Error>],
        onRun: @escaping (Int) -> Void = { _ in }
    ) {
        self.outcomes = outcomes
        self.onRun = onRun
    }

    func run(id: RunnerID, repository: GitHubRepository) throws {
        activeSessions += 1
        maximumActiveSessions = max(maximumActiveSessions, activeSessions)
        defer { activeSessions -= 1 }

        calls.append(RunnerSessionCall(id: id, repository: repository))
        onRun(calls.count)
        guard !outcomes.isEmpty else {
            throw TestFailure.unexpectedBackendCall
        }
        try outcomes.removeFirst().get()
    }
}
