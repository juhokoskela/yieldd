import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import Yieldd

private let runnerTestID = RunnerID(value: "yieldd-test-runner")
private let runnerTestRepository = try! GitHubRepository("owner/repository")
private let runnerTestMemoryRequirements = RunnerMemoryRequirements(
    constrainedBytes: 1_024,
    fullBytes: 1_024
)

private func runnerTestMemoryAdmission(
    pressure: HostMemoryPressure = .normal
) -> RunnerMemoryAdmission {
    RunnerMemoryAdmission(
        physicalMemoryBytes: 4_096,
        readMemoryPressure: { pressure }
    )
}

private func singleRunnerMemoryAdmission() -> RunnerMemoryAdmission {
    RunnerMemoryAdmission(
        physicalMemoryBytes: 1_366,
        readMemoryPressure: { .normal }
    )
}

@Test(arguments: [0, -1, RunnerTestCommand.maximumTimeoutMinutes + 1])
func rejectsInvalidRunnerTestTimeout(_ timeout: Int) {
    var command = RunnerTestCommand()
    command.repository = runnerTestRepository.fullName
    command.timeout = timeout

    #expect(throws: ValidationError.self) {
        try command.validate()
    }
}

@Test
func runnerTestConfiguresOneJobAndCleansUp() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    var states: [RunnerSessionState] = []
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult(stdout: "configured")),
            .success(processResult(stdout: "job complete")),
        ]
    )
    let github = RunnerTestGitHub(events: events)
    let memoryAdmission = singleRunnerMemoryAdmission()

    try EphemeralRunnerSession(
        backend: backend,
        github: github,
        memoryAdmission: memoryAdmission,
        jobTimeout: 90,
        stateChanged: { states.append($0) },
        leaseStore: leaseStore
    ).run(
        id: runnerTestID,
        repository: runnerTestRepository
    )

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, .full),
        .exec(
            runnerTestID,
            ["yieldd-configure-runner", runnerTestRepository.fullName, runnerTestID.value],
            Data("registration-token\n".utf8),
            EphemeralRunnerSession.configurationTimeout,
            .runner
        ),
        .exec(runnerTestID, ["yieldd-runner-control", "run"], nil, 90, .root),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
    #expect(backend.outputCaptures == [
        .all,
        .tail(maxBytes: EphemeralRunnerSession.jobOutputTailBytes),
    ])
    #expect(states == [
        .preparing(runnerTestID),
        .waitingForJob(runnerTestID),
        .cleaningUp(runnerTestID),
    ])
    #expect(!events.values.description.contains("registration-token"))
    #expect(try leaseStore.load().isEmpty)
    let nextReservation = try memoryAdmission.acquire(
        requirements: runnerTestMemoryRequirements
    )
    memoryAdmission.release(nextReservation)
}

@Test
func successfulJobWaitsUntilGitHubReleasesItsBusyRunner() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: Array(repeating: .success(processResult()), count: 2)
    )
    let github = RunnerTestGitHub(
        events: events,
        removeOutcomes: [
            .failure(GitHubRunnerClientError.runnerBusy(name: runnerTestID.value)),
            .success(()),
        ]
    )
    var retryDelays: [TimeInterval] = []
    var states: [RunnerSessionState] = []

    try EphemeralRunnerSession(
        backend: backend,
        github: github,
        memoryAdmission: runnerTestMemoryAdmission(),
        recoveryWait: { retryDelays.append($0) },
        stateChanged: { states.append($0) },
        leaseStore: leaseStore
    ).run(id: runnerTestID, repository: runnerTestRepository)

    #expect(events.values.suffix(3) == [
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
    ])
    #expect(retryDelays == [1])
    #expect(states.suffix(2) == [
        .cleaningUp(runnerTestID),
        .waitingForGitHubCleanup(runnerTestID, retryDelay: 1),
    ])
    #expect(try leaseStore.load().isEmpty)
}

@Test
func leaseClearFailureAfterSuccessfulCleanupIsAWarning() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stateDirectory.path
        )
        try? FileManager.default.removeItem(at: stateDirectory)
    }
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: Array(repeating: .success(processResult()), count: 2)
    )
    var states: [RunnerSessionState] = []
    var madeDirectoryReadOnly = false

    try EphemeralRunnerSession(
        backend: backend,
        github: RunnerTestGitHub(events: events),
        memoryAdmission: runnerTestMemoryAdmission(),
        stateChanged: { state in
            states.append(state)
            guard case .cleaningUp = state else {
                return
            }
            madeDirectoryReadOnly = (try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: stateDirectory.path
            )) != nil
        },
        leaseStore: leaseStore
    ).run(id: runnerTestID, repository: runnerTestRepository)

    #expect(madeDirectoryReadOnly)
    guard case let .leaseCleanupFailed(id, reason) = states.last else {
        Issue.record("Expected a lease cleanup warning")
        return
    }
    #expect(id == runnerTestID)
    #expect(!reason.isEmpty)
    #expect(try leaseStore.load().count == 1)
}

@Test
func recoversAbandonedRunnersAndClearsTheirLeases() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    try leaseStore.save(RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository))
    let secondID = RunnerID(value: "yieldd-test-runner-two")
    let secondRepository = try GitHubRepository("other/repository")
    try leaseStore.save(RunnerLease(runnerID: secondID, repository: secondRepository))
    let events = RunnerTestEventRecorder()
    let session = EphemeralRunnerSession(
        backend: RunnerTestBackend(events: events),
        github: RunnerTestGitHub(events: events),
        memoryAdmission: runnerTestMemoryAdmission(),
        leaseStore: leaseStore
    )

    let recoveredIDs = try session.recoverAbandonedRunners()

    #expect(recoveredIDs == [runnerTestID, secondID])
    #expect(events.values == [
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
        .stopRunner(secondID),
        .removeGitHubRunner(secondID.value, secondRepository),
        .destroy(secondID),
    ])
    #expect(try leaseStore.load().isEmpty)
}

@Test
func recoveryCleansEveryLeaseBeforeRetryingBusyRegistration() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let secondID = RunnerID(value: "yieldd-test-runner-two")
    let secondRepository = try GitHubRepository("other/repository")
    try leaseStore.save(RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository))
    try leaseStore.save(RunnerLease(runnerID: secondID, repository: secondRepository))
    let events = RunnerTestEventRecorder()
    let github = RunnerTestGitHub(
        events: events,
        removeOutcomes: [
            .failure(GitHubRunnerClientError.runnerBusy(name: runnerTestID.value)),
            .success(()),
            .success(()),
        ]
    )
    let session = EphemeralRunnerSession(
        backend: RunnerTestBackend(events: events),
        github: github,
        memoryAdmission: runnerTestMemoryAdmission(),
        recoveryWait: { _ in },
        leaseStore: leaseStore
    )

    let recoveredIDs = try session.recoverAbandonedRunners()

    #expect(recoveredIDs == [runnerTestID, secondID])
    #expect(events.values == [
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
        .stopRunner(secondID),
        .removeGitHubRunner(secondID.value, secondRepository),
        .destroy(secondID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
    ])
    #expect(try leaseStore.load().isEmpty)
}

@Test
func recoveryAttemptsLaterLeasesBeforeReportingCleanupFailures() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let secondID = RunnerID(value: "yieldd-test-runner-two")
    let secondRepository = try GitHubRepository("other/repository")
    let firstLease = RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository)
    try leaseStore.save(firstLease)
    try leaseStore.save(RunnerLease(runnerID: secondID, repository: secondRepository))
    let events = RunnerTestEventRecorder()
    let session = EphemeralRunnerSession(
        backend: RunnerTestBackend(events: events),
        github: RunnerTestGitHub(
            events: events,
            removeOutcomes: [
                .failure(TestFailure.githubCleanup),
                .success(()),
            ]
        ),
        memoryAdmission: runnerTestMemoryAdmission(),
        leaseStore: leaseStore
    )

    do {
        _ = try session.recoverAbandonedRunners()
        Issue.record("Expected recovery cleanup to fail")
    } catch let RunnerSessionError.cleanupFailed(failures) {
        #expect(failures.count == 1)
        #expect(failures.first?.step == .githubRunner)
        #expect(failures.first?.error as? TestFailure == .githubCleanup)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values == [
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
        .stopRunner(secondID),
        .removeGitHubRunner(secondID.value, secondRepository),
        .destroy(secondID),
    ])
    #expect(try leaseStore.load() == [firstLease])
}

@Test
func recoveryWaitsUntilGitHubReleasesABusyRunner() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    try leaseStore.save(RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository))
    let events = RunnerTestEventRecorder()
    let github = RunnerTestGitHub(
        events: events,
        removeOutcomes: [
            .failure(GitHubRunnerClientError.runnerBusy(name: runnerTestID.value)),
            .failure(GitHubRunnerClientError.runnerBusy(name: runnerTestID.value)),
            .failure(GitHubRunnerClientError.runnerBusy(name: runnerTestID.value)),
            .success(()),
        ]
    )
    var retryDelays: [TimeInterval] = []
    var states: [RunnerSessionState] = []
    let session = EphemeralRunnerSession(
        backend: RunnerTestBackend(events: events),
        github: github,
        memoryAdmission: runnerTestMemoryAdmission(),
        recoveryWait: { retryDelays.append($0) },
        stateChanged: { states.append($0) },
        leaseStore: leaseStore
    )

    let recoveredIDs = try session.recoverAbandonedRunners()

    #expect(recoveredIDs == [runnerTestID])
    #expect(events.values == [
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
    ])
    #expect(retryDelays == [1, 2, 4])
    #expect(states == [
        .waitingForGitHubCleanup(runnerTestID, retryDelay: 1),
        .waitingForGitHubCleanup(runnerTestID, retryDelay: 2),
        .waitingForGitHubCleanup(runnerTestID, retryDelay: 4),
    ])
    #expect(try leaseStore.load().isEmpty)
}

@Test
func interruptedRecoveryKeepsTheLease() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let lease = RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository)
    try leaseStore.save(lease)
    let events = RunnerTestEventRecorder()
    let github = RunnerTestGitHub(
        events: events,
        removeOutcomes: [
            .failure(GitHubRunnerClientError.runnerBusy(name: runnerTestID.value)),
        ]
    )
    let session = EphemeralRunnerSession(
        backend: RunnerTestBackend(events: events),
        github: github,
        memoryAdmission: runnerTestMemoryAdmission(),
        recoveryWait: { _ in throw SignalInterruption(signal: SIGINT) },
        leaseStore: leaseStore
    )

    #expect(throws: SignalInterruption(signal: SIGINT)) {
        _ = try session.recoverAbandonedRunners()
    }

    #expect(events.values == [
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
    #expect(try leaseStore.load() == [lease])
}

@Test
func failedRecoveryKeepsTheLease() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let lease = RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository)
    try leaseStore.save(lease)
    let events = RunnerTestEventRecorder()
    let session = EphemeralRunnerSession(
        backend: RunnerTestBackend(
            events: events,
            stopError: TestFailure.runnerStop,
            destroyError: TestFailure.machineCleanup
        ),
        github: RunnerTestGitHub(events: events),
        memoryAdmission: runnerTestMemoryAdmission(),
        leaseStore: leaseStore
    )

    #expect(throws: RunnerSessionError.self) {
        _ = try session.recoverAbandonedRunners()
    }

    #expect(events.values == [
        .stopRunner(runnerTestID),
        .destroy(runnerTestID),
    ])
    #expect(try leaseStore.load() == [lease])
}

@Test
func sessionCleanupFailureKeepsTheLease() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    let memoryAdmission = singleRunnerMemoryAdmission()
    let session = EphemeralRunnerSession(
        backend: RunnerTestBackend(
            events: events,
            createError: TestFailure.create,
            destroyError: TestFailure.machineCleanup
        ),
        github: RunnerTestGitHub(events: events),
        memoryAdmission: memoryAdmission,
        leaseStore: leaseStore
    )

    #expect(throws: RunnerSessionError.self) {
        try session.run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(try leaseStore.load() == [RunnerLease(
        runnerID: runnerTestID,
        repository: runnerTestRepository
    )])
    var checks = 0
    #expect(throws: CancellationError.self) {
        try memoryAdmission.acquire(
            requirements: runnerTestMemoryRequirements,
            checkCancellation: {
                checks += 1
                if checks == 2 {
                    throw CancellationError()
                }
            }
        )
    }
}

@Test
func runnerTimeoutStillRemovesRegistrationAndMachine() {
    let events = RunnerTestEventRecorder()
    let timeoutRequest = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/container"),
        arguments: ["machine", "run"],
        timeout: 0.1
    )
    let timeoutResult = processResult(status: SIGTERM, reason: .uncaughtSignal)
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .failure(ProcessExecutionError.timedOut(
                request: timeoutRequest,
                result: timeoutResult
            )),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    do {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission(),
            jobTimeout: 0.1
        ).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
        Issue.record("Expected runner job to time out")
    } catch let ProcessExecutionError.timedOut(request, result) {
        #expect(request == timeoutRequest)
        #expect(result == timeoutResult)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values.suffix(4) == [
        .exec(runnerTestID, ["yieldd-runner-control", "run"], nil, 0.1, .root),
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
}

@Test
func cancelledRunnerCommandStillRemovesRegistrationAndMachine() {
    let events = RunnerTestEventRecorder()
    let cancelledRequest = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/container"),
        arguments: ["machine", "run"]
    )
    let cancelledResult = processResult(status: SIGTERM, reason: .uncaughtSignal)
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .failure(ProcessExecutionError.cancelled(
                request: cancelledRequest,
                result: cancelledResult,
                underlying: SignalInterruption(signal: SIGINT)
            )),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    do {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission()
        ).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
        Issue.record("Expected runner job to be cancelled")
    } catch let ProcessExecutionError.cancelled(request, result, underlying) {
        #expect(request == cancelledRequest)
        #expect(result == cancelledResult)
        #expect((underlying as? SignalInterruption)?.signal == SIGINT)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values.suffix(4) == [
        .exec(runnerTestID, ["yieldd-runner-control", "run"], nil, nil, .root),
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
}

@Test
func busyGitHubRunnerDefersCleanupAndKeepsLease() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    let cancelledRequest = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/container"),
        arguments: ["machine", "run"]
    )
    let cancellation = ProcessExecutionError.cancelled(
        request: cancelledRequest,
        result: processResult(status: SIGTERM, reason: .uncaughtSignal),
        underlying: SignalInterruption(signal: SIGINT)
    )
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .failure(cancellation),
        ]
    )
    let github = RunnerTestGitHub(
        events: events,
        removeOutcomes: [
            .failure(GitHubRunnerClientError.runnerBusy(name: runnerTestID.value)),
        ]
    )

    do {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission(),
            leaseStore: leaseStore
        ).run(id: runnerTestID, repository: runnerTestRepository)
        Issue.record("Expected runner cleanup to be deferred")
    } catch let RunnerSessionError.cleanupDeferred(id, operation) {
        #expect(id == runnerTestID)
        #expect(operation is ProcessExecutionError)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values.suffix(4) == [
        .exec(runnerTestID, ["yieldd-runner-control", "run"], nil, nil, .root),
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
    #expect(try leaseStore.load() == [RunnerLease(
        runnerID: runnerTestID,
        repository: runnerTestRepository
    )])
}

@Test
func runnerFailureStillRemovesRegistrationAndMachine() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .failure(TestFailure.runnerJob),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    #expect(throws: TestFailure.runnerJob) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission()
        ).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
    }

    #expect(events.values.suffix(3) == [
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
    #expect(events.values.contains(
        .exec(runnerTestID, ["yieldd-runner-control", "run"], nil, nil, .root)
    ))
}

@Test
func failedRunnerStopDestroysMachineBeforeRemovingRegistration() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .failure(TestFailure.runnerJob),
        ],
        stopError: TestFailure.runnerStop
    )
    let github = RunnerTestGitHub(events: events)

    #expect(throws: TestFailure.runnerJob) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission()
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(events.values.suffix(3) == [
        .stopRunner(runnerTestID),
        .destroy(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
    ])
}

@Test
func failedRunnerStopAndMachineDestroySkipGitHubCleanup() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .failure(TestFailure.runnerJob),
        ],
        stopError: TestFailure.runnerStop,
        destroyError: TestFailure.machineCleanup
    )
    let github = RunnerTestGitHub(events: events)

    do {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission()
        ).run(id: runnerTestID, repository: runnerTestRepository)
        Issue.record("Expected runner session cleanup to fail")
    } catch let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) {
        #expect(operation as? TestFailure == .runnerJob)
        #expect(cleanup.count == 2)
        if cleanup.count == 2 {
            #expect(cleanup[0].step == .runnerProcess)
            #expect(cleanup[0].error as? TestFailure == .runnerStop)
            #expect(cleanup[1].step == .machine)
            #expect(cleanup[1].error as? TestFailure == .machineCleanup)
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values.suffix(2) == [
        .stopRunner(runnerTestID),
        .destroy(runnerTestID),
    ])
    #expect(!events.values.contains(
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository)
    ))
}

@Test
func failureBeforeRunnerConfigurationSkipsGitHubCleanup() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        createError: TestFailure.create
    )
    let github = RunnerTestGitHub(
        events: events,
        removeOutcomes: [.failure(TestFailure.githubCleanup)]
    )

    #expect(throws: TestFailure.create) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission()
        ).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, .full),
        .destroy(runnerTestID),
    ])
}

@Test(arguments: [
    HostMemoryPressure.warning,
    HostMemoryPressure.unknown,
])
func elevatedOrUnknownMemoryPressureKeepsConstrainedAllocation(
    _ pressure: HostMemoryPressure
) throws {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: Array(repeating: .success(processResult()), count: 2)
    )
    let github = RunnerTestGitHub(events: events)

    try EphemeralRunnerSession(
        backend: backend,
        github: github,
        memoryAdmission: runnerTestMemoryAdmission(pressure: pressure)
    ).run(id: runnerTestID, repository: runnerTestRepository)

    #expect(events.values.contains(.create(runnerTestID, .constrained)))
}

@Test
func backendProvisioningFailureSkipsGitHubCleanupAndDestroysMachine() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        createError: TestFailure.memoryAllocation
    )
    let github = RunnerTestGitHub(events: events)

    #expect(throws: TestFailure.memoryAllocation) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission()
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(events.values.suffix(2) == [
        .create(runnerTestID, .full),
        .destroy(runnerTestID),
    ])
}

@Test
func runnerTestRetainsOperationAndBothCleanupFailures() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [.failure(TestFailure.runnerConfiguration)],
        destroyError: TestFailure.machineCleanup
    )
    let github = RunnerTestGitHub(
        events: events,
        removeOutcomes: [.failure(TestFailure.githubCleanup)]
    )

    do {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission()
        ).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
        Issue.record("Expected runner test to fail")
    } catch let RunnerSessionError.operationAndCleanupFailed(operation, cleanup) {
        #expect(operation as? TestFailure == .runnerConfiguration)
        #expect(cleanup.count == 2)
        if cleanup.count == 2 {
            #expect(cleanup[0].step == .githubRunner)
            #expect(cleanup[0].error as? TestFailure == .githubCleanup)
            #expect(cleanup[1].step == .machine)
            #expect(cleanup[1].error as? TestFailure == .machineCleanup)
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, .full),
        .exec(
            runnerTestID,
            ["yieldd-configure-runner", runnerTestRepository.fullName, runnerTestID.value],
            Data("registration-token\n".utf8),
            EphemeralRunnerSession.configurationTimeout,
            .runner
        ),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
}

@Test
func registrationTokenFailureReleasesReservedMachineCapacity() throws {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(events: events)
    let github = RunnerTestGitHub(events: events, tokenError: TestFailure.registrationToken)
    let memoryAdmission = singleRunnerMemoryAdmission()

    #expect(throws: TestFailure.registrationToken) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: memoryAdmission
        ).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .destroy(runnerTestID),
    ])
    let nextReservation = try memoryAdmission.acquire(
        requirements: runnerTestMemoryRequirements
    )
    memoryAdmission.release(nextReservation)
}

private final class RunnerTestEventRecorder {
    var values: [RunnerTestEvent] = []
}

private final class RunnerTestBackend: RunnerBackend {
    let memoryRequirements = runnerTestMemoryRequirements
    private(set) var outputCaptures: [ProcessOutputCapture] = []
    private let events: RunnerTestEventRecorder
    private let createError: (any Error)?
    private var execOutcomes: [Result<ProcessResult, any Error>]
    private let stopError: (any Error)?
    private let destroyError: (any Error)?

    init(
        events: RunnerTestEventRecorder,
        createError: (any Error)? = nil,
        execOutcomes: [Result<ProcessResult, any Error>] = [],
        stopError: (any Error)? = nil,
        destroyError: (any Error)? = nil
    ) {
        self.events = events
        self.createError = createError
        self.execOutcomes = execOutcomes
        self.stopError = stopError
        self.destroyError = destroyError
    }

    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws {
        events.values.append(.create(id, memory))
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
        outputCaptures.append(outputCapture)
        events.values.append(.exec(id, arguments, standardInput, timeout, user))
        guard !execOutcomes.isEmpty else {
            throw TestFailure.unexpectedBackendCall
        }
        return try execOutcomes.removeFirst().get()
    }

    func destroy(_ id: RunnerID) throws {
        events.values.append(.destroy(id))
        if let destroyError {
            throw destroyError
        }
    }

    func stopRunner(on id: RunnerID) throws {
        events.values.append(.stopRunner(id))
        if let stopError {
            throw stopError
        }
    }
}

private final class RunnerTestGitHub: GitHubRunnerManaging {
    private let events: RunnerTestEventRecorder
    private let registrationToken: String
    private let tokenError: (any Error)?
    private var removeOutcomes: [Result<Void, any Error>]

    init(
        events: RunnerTestEventRecorder,
        registrationToken: String = "registration-token",
        tokenError: (any Error)? = nil,
        removeOutcomes: [Result<Void, any Error>] = []
    ) {
        self.events = events
        self.registrationToken = registrationToken
        self.tokenError = tokenError
        self.removeOutcomes = removeOutcomes
    }

    func createRegistrationToken(for repository: GitHubRepository) throws -> String {
        events.values.append(.createRegistrationToken(repository))
        if let tokenError {
            throw tokenError
        }
        return registrationToken
    }

    func removeRunners(named name: String, from repository: GitHubRepository) throws {
        events.values.append(.removeGitHubRunner(name, repository))
        if !removeOutcomes.isEmpty {
            try removeOutcomes.removeFirst().get()
        }
    }
}

private enum RunnerTestEvent: Equatable {
    case createRegistrationToken(GitHubRepository)
    case create(RunnerID, RunnerMemoryAllocation)
    case exec(RunnerID, [String], Data?, TimeInterval?, RunnerGuestUser)
    case removeGitHubRunner(String, GitHubRepository)
    case stopRunner(RunnerID)
    case destroy(RunnerID)
}

private func makeRunnerLeaseStore() throws -> (RunnerLeaseStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-runner-test-\(UUID().uuidString)", isDirectory: true)
    return (try RunnerLeaseStore(directory: directory), directory)
}
