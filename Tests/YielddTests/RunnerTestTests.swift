import Darwin
import Foundation
import Testing
@testable import Yieldd

private let runnerTestID = RunnerID(value: "yieldd-test-runner")
private let runnerTestRepository = try! GitHubRepository("owner/repository")

@Test
func runnerTestConfiguresOneJobAndCleansUp() throws {
    let events = RunnerTestEventRecorder()
    var states: [RunnerSessionState] = []
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult(stdout: "docker info")),
            .success(processResult(stdout: "cpu allocation set")),
            .success(processResult(stdout: "memory allocation set")),
            .success(processResult(stdout: "configured")),
            .success(processResult(stdout: "job complete")),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    try EphemeralRunnerSession(
        backend: backend,
        github: github,
        jobTimeout: 90,
        readMemoryPressure: { .normal },
        stateChanged: { states.append($0) }
    ).run(
        id: runnerTestID,
        repository: runnerTestRepository
    )

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, EphemeralRunnerSession.image),
        .exec(runnerTestID, ["docker", "info"], nil, DockerReadiness.probeTimeout, .runner),
        .exec(runnerTestID, ["yieldd-runner-control", "cpu", "constrained"], nil, nil, .root),
        .exec(runnerTestID, ["yieldd-runner-control", "memory", "full"], nil, nil, .root),
        .exec(
            runnerTestID,
            ["yieldd-configure-runner", runnerTestRepository.fullName, runnerTestID.value],
            Data("registration-token\n".utf8),
            EphemeralRunnerSession.configurationTimeout,
            .runner
        ),
        .exec(runnerTestID, ["yieldd-runner-control", "run"], nil, 90, .root),
        .stopRunner(runnerTestID),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
    #expect(states == [
        .preparing(runnerTestID),
        .waitingForJob(runnerTestID),
        .cleaningUp(runnerTestID),
    ])
    #expect(!events.values.description.contains("registration-token"))
}

@Test
func interruptionDuringDockerReadinessStopsRetriesAndCleansUp() {
    let events = RunnerTestEventRecorder()
    let interruptedRequest = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/container"),
        arguments: ["machine", "run"]
    )
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .failure(ProcessExecutionError.terminatedBySignal(
                request: interruptedRequest,
                result: processResult(status: SIGINT, reason: .uncaughtSignal)
            )),
        ]
    )
    let github = RunnerTestGitHub(events: events)
    var cancellationChecks = 0
    let runner = EphemeralRunnerSession(
        backend: backend,
        github: github,
        dockerInfoAttempts: 30,
        sleep: { _ in
            Issue.record("Interrupted readiness must not sleep or retry")
        },
        checkCancellation: {
            cancellationChecks += 1
            if cancellationChecks == 4 {
                throw SignalInterruption(signal: SIGINT)
            }
        }
    )

    do {
        try runner.run(id: runnerTestID, repository: runnerTestRepository)
        Issue.record("Expected runner test to be interrupted")
    } catch let interruption as SignalInterruption {
        #expect(interruption.signal == SIGINT)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, EphemeralRunnerSession.image),
        .exec(runnerTestID, ["docker", "info"], nil, DockerReadiness.probeTimeout, .runner),
        .destroy(runnerTestID),
    ])
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
            .success(processResult()),
            .success(processResult()),
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
            jobTimeout: 0.1,
            readMemoryPressure: { .normal }
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
            .success(processResult()),
            .success(processResult()),
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
            readMemoryPressure: { .normal }
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
func runnerFailureStillRemovesRegistrationAndMachine() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .success(processResult()),
            .success(processResult()),
            .success(processResult()),
            .failure(TestFailure.runnerJob),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    #expect(throws: TestFailure.runnerJob) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            readMemoryPressure: { .normal }
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
            .success(processResult()),
            .success(processResult()),
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
            readMemoryPressure: { .normal }
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
            .success(processResult()),
            .success(processResult()),
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
            readMemoryPressure: { .normal }
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
    let github = RunnerTestGitHub(events: events, removeError: TestFailure.githubCleanup)

    #expect(throws: TestFailure.create) {
        try EphemeralRunnerSession(backend: backend, github: github).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, EphemeralRunnerSession.image),
        .destroy(runnerTestID),
    ])
}

@Test
func cpuAllocationFailureSkipsGitHubCleanupAndDestroysMachine() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .failure(TestFailure.cpuAllocation),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    #expect(throws: TestFailure.cpuAllocation) {
        try EphemeralRunnerSession(backend: backend, github: github).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, EphemeralRunnerSession.image),
        .exec(runnerTestID, ["docker", "info"], nil, DockerReadiness.probeTimeout, .runner),
        .exec(runnerTestID, ["yieldd-runner-control", "cpu", "constrained"], nil, nil, .root),
        .destroy(runnerTestID),
    ])
}

@Test(arguments: [
    HostMemoryPressure.warning,
    HostMemoryPressure.critical,
    HostMemoryPressure.unknown,
])
func elevatedOrUnknownMemoryPressureKeepsConstrainedAllocation(
    _ pressure: HostMemoryPressure
) throws {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: Array(repeating: .success(processResult()), count: 5)
    )
    let github = RunnerTestGitHub(events: events)

    try EphemeralRunnerSession(
        backend: backend,
        github: github,
        readMemoryPressure: { pressure }
    ).run(id: runnerTestID, repository: runnerTestRepository)

    #expect(events.values.contains(
        .exec(
            runnerTestID,
            ["yieldd-runner-control", "memory", "constrained"],
            nil,
            nil,
            .root
        )
    ))
}

@Test
func memoryAllocationFailureSkipsGitHubCleanupAndDestroysMachine() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .success(processResult()),
            .failure(TestFailure.memoryAllocation),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    #expect(throws: TestFailure.memoryAllocation) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            readMemoryPressure: { .normal }
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(events.values.suffix(2) == [
        .exec(runnerTestID, ["yieldd-runner-control", "memory", "full"], nil, nil, .root),
        .destroy(runnerTestID),
    ])
}

@Test
func runnerTestRetainsOperationAndBothCleanupFailures() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult()),
            .success(processResult()),
            .success(processResult()),
            .failure(TestFailure.runnerConfiguration),
        ],
        destroyError: TestFailure.machineCleanup
    )
    let github = RunnerTestGitHub(events: events, removeError: TestFailure.githubCleanup)

    do {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            readMemoryPressure: { .normal }
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
        .create(runnerTestID, EphemeralRunnerSession.image),
        .exec(runnerTestID, ["docker", "info"], nil, DockerReadiness.probeTimeout, .runner),
        .exec(runnerTestID, ["yieldd-runner-control", "cpu", "constrained"], nil, nil, .root),
        .exec(runnerTestID, ["yieldd-runner-control", "memory", "full"], nil, nil, .root),
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
func registrationTokenFailureCreatesNothingToCleanUp() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(events: events)
    let github = RunnerTestGitHub(events: events, tokenError: TestFailure.registrationToken)

    #expect(throws: TestFailure.registrationToken) {
        try EphemeralRunnerSession(backend: backend, github: github).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
    }

    #expect(events.values == [.createRegistrationToken(runnerTestRepository)])
}

private final class RunnerTestEventRecorder {
    var values: [RunnerTestEvent] = []
}

private final class RunnerTestBackend: RunnerBackend {
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

    func create(id: RunnerID, image: String) throws {
        events.values.append(.create(id, image))
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
    private let removeError: (any Error)?

    init(
        events: RunnerTestEventRecorder,
        registrationToken: String = "registration-token",
        tokenError: (any Error)? = nil,
        removeError: (any Error)? = nil
    ) {
        self.events = events
        self.registrationToken = registrationToken
        self.tokenError = tokenError
        self.removeError = removeError
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
        if let removeError {
            throw removeError
        }
    }
}

private enum RunnerTestEvent: Equatable {
    case createRegistrationToken(GitHubRepository)
    case create(RunnerID, String)
    case exec(RunnerID, [String], Data?, TimeInterval?, RunnerGuestUser)
    case removeGitHubRunner(String, GitHubRepository)
    case stopRunner(RunnerID)
    case destroy(RunnerID)
}
