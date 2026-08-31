import Darwin
import Foundation
import Testing
@testable import Yieldd

private let runnerTestID = RunnerID(value: "yieldd-test-runner")
private let runnerTestRepository = try! GitHubRepository("owner/repository")

@Test
func runnerTestConfiguresOneJobAndCleansUp() throws {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: [
            .success(processResult(stdout: "docker info")),
            .success(processResult(stdout: "configured")),
            .success(processResult(stdout: "job complete")),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    try RunnerTestRunner(backend: backend, github: github, jobTimeout: 90).run(
        id: runnerTestID,
        repository: runnerTestRepository
    )

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, RunnerTestRunner.image),
        .exec(runnerTestID, ["docker", "info"], nil, DockerReadiness.probeTimeout),
        .exec(
            runnerTestID,
            ["yieldd-configure-runner", runnerTestRepository.fullName, runnerTestID.value],
            Data("registration-token\n".utf8),
            RunnerTestRunner.configurationTimeout
        ),
        .exec(runnerTestID, ["/opt/actions-runner/run.sh"], nil, 90),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
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
    let runner = RunnerTestRunner(
        backend: backend,
        github: github,
        dockerInfoAttempts: 30,
        sleep: { _ in
            Issue.record("Interrupted readiness must not sleep or retry")
        },
        checkCancellation: {
            cancellationChecks += 1
            if cancellationChecks == 4 {
                throw RunnerTestError.interrupted
            }
        }
    )

    do {
        try runner.run(id: runnerTestID, repository: runnerTestRepository)
        Issue.record("Expected runner test to be interrupted")
    } catch RunnerTestError.interrupted {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, RunnerTestRunner.image),
        .exec(runnerTestID, ["docker", "info"], nil, DockerReadiness.probeTimeout),
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
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
            .failure(ProcessExecutionError.timedOut(
                request: timeoutRequest,
                result: timeoutResult
            )),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    do {
        try RunnerTestRunner(backend: backend, github: github, jobTimeout: 0.1).run(
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

    #expect(events.values.suffix(3) == [
        .exec(runnerTestID, ["/opt/actions-runner/run.sh"], nil, 0.1),
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
            .failure(TestFailure.runnerJob),
        ]
    )
    let github = RunnerTestGitHub(events: events)

    #expect(throws: TestFailure.runnerJob) {
        try RunnerTestRunner(backend: backend, github: github).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
    }

    #expect(events.values.suffix(2) == [
        .removeGitHubRunner(runnerTestID.value, runnerTestRepository),
        .destroy(runnerTestID),
    ])
}

@Test
func runnerTestRetainsOperationAndBothCleanupFailures() {
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        createError: TestFailure.create,
        destroyError: TestFailure.machineCleanup
    )
    let github = RunnerTestGitHub(events: events, removeError: TestFailure.githubCleanup)

    do {
        try RunnerTestRunner(backend: backend, github: github).run(
            id: runnerTestID,
            repository: runnerTestRepository
        )
        Issue.record("Expected runner test to fail")
    } catch let RunnerTestError.operationAndCleanupFailed(operation, cleanup) {
        #expect(operation as? TestFailure == .create)
        #expect(cleanup.count == 2)
        #expect(cleanup[0].step == .githubRunner)
        #expect(cleanup[0].error as? TestFailure == .githubCleanup)
        #expect(cleanup[1].step == .machine)
        #expect(cleanup[1].error as? TestFailure == .machineCleanup)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, RunnerTestRunner.image),
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
        try RunnerTestRunner(backend: backend, github: github).run(
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
    private let destroyError: (any Error)?

    init(
        events: RunnerTestEventRecorder,
        createError: (any Error)? = nil,
        execOutcomes: [Result<ProcessResult, any Error>] = [],
        destroyError: (any Error)? = nil
    ) {
        self.events = events
        self.createError = createError
        self.execOutcomes = execOutcomes
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
        on id: RunnerID
    ) throws -> ProcessResult {
        events.values.append(.exec(id, arguments, standardInput, timeout))
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
    case exec(RunnerID, [String], Data?, TimeInterval?)
    case removeGitHubRunner(String, GitHubRepository)
    case destroy(RunnerID)
}
