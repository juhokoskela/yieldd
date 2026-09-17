import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import Yieldd

private let runnerTestID = RunnerID(value: "yieldd-test-runner")
private let runnerTestRepository = try! GitHubRepository("owner/repository")
private let runnerTestMemoryBytes = AppleContainerBackend.memoryBytes

private func runnerTestMemoryAdmission(
    pressure: HostMemoryPressure = .normal
) -> RunnerMemoryAdmission {
    RunnerMemoryAdmission(
        physicalMemoryBytes: 4 * runnerTestMemoryBytes,
        readMemoryPressure: { pressure }
    )
}

private func singleRunnerMemoryAdmission() -> RunnerMemoryAdmission {
    RunnerMemoryAdmission(
        physicalMemoryBytes: runnerTestMemoryBytes * 4 / 3 + 1,
        readMemoryPressure: { .normal }
    )
}

@Test(arguments: ["success", "cancel", "run", "destroy"])
func runnerSessionHoldsSleepAssertionUntilItReturns(_ stage: String) throws {
    let id = RunnerPlatform.linux.makeTestRunnerID()
    let events = RunnerTestEventRecorder()
    var created = false
    let backend = RunnerTestBackend(events: events, onCreate: {
        try expectRunnerPreventsIdleSleep(id)
        created = true
    }, execOutcomes: [.success(()), stage == "run" ? .failure(TestFailure.runnerJob) : .success(())],
        destroyError: stage == "destroy" ? TestFailure.machineCleanup : nil)
    let github = RunnerTestGitHub(events: events, onCreateRegistrationToken: { try expectRunnerPreventsIdleSleep(id) })
    var observedCleanup = false
    let session = EphemeralRunnerSession(backend: backend, github: github, memoryAdmission: runnerTestMemoryAdmission(),
        checkCancellation: {
            if created, stage == "cancel" { throw CancellationError() }
        }, stateChanged: { state in
            if case .preparing = state {
                #expect(throws: Never.self) {
                    let assertions = try runnerSleepAssertions(id)
                    #expect(assertions.isEmpty)
                }
            }
            if case .cleaningUp = state {
                #expect(throws: Never.self) { try expectRunnerPreventsIdleSleep(id) }
                observedCleanup = true
            }
        })
    switch stage {
    case "success": try session.run(id: id, repository: runnerTestRepository)
    case "cancel": #expect(throws: CancellationError.self) { try session.run(id: id, repository: runnerTestRepository) }
    case "run": #expect(throws: TestFailure.runnerJob) { try session.run(id: id, repository: runnerTestRepository) }
    default: #expect(throws: RunnerSessionError.self) { try session.run(id: id, repository: runnerTestRepository) }
    }
    #expect(observedCleanup)
    #expect(try runnerSleepAssertions(id).isEmpty)
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
            .success(()),
            .success(()),
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
    let nextReservation = try memoryAdmission.acquire(reserving: RunnerPlatform.linux.memoryReservationBytes)
    memoryAdmission.release(nextReservation)
}

@Test
func successfulJobWaitsUntilGitHubReleasesItsBusyRunner() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    let backend = RunnerTestBackend(
        events: events,
        execOutcomes: Array(repeating: .success(()), count: 2)
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
        execOutcomes: Array(repeating: .success(()), count: 2)
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
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) },
        github: RunnerTestGitHub(events: events),
        leaseStore: leaseStore,
    )

    let recoveredIDs = try recovery.run()

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
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) },
        github: github,
        leaseStore: leaseStore,
        recoveryWait: { _ in },
    )

    let recoveredIDs = try recovery.run()

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
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) },
        github: RunnerTestGitHub(
            events: events,
            removeOutcomes: [
                .failure(TestFailure.githubCleanup),
                .success(()),
            ]
        ),
        leaseStore: leaseStore,
    )

    do {
        _ = try recovery.run()
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
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) },
        github: github,
        leaseStore: leaseStore,
        recoveryWait: { retryDelays.append($0) },
        stateChanged: { states.append($0) },
    )

    let recoveredIDs = try recovery.run()

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
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) },
        github: github,
        leaseStore: leaseStore,
        recoveryWait: { _ in throw SignalInterruption(signal: SIGINT) },
    )

    #expect(throws: SignalInterruption(signal: SIGINT)) {
        _ = try recovery.run()
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
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(
            events: events,
            stopError: TestFailure.runnerStop,
            destroyError: TestFailure.machineCleanup
        ) },
        github: RunnerTestGitHub(events: events),
        leaseStore: leaseStore,
    )

    #expect(throws: RunnerSessionError.self) {
        _ = try recovery.run()
    }

    #expect(events.values == [
        .stopRunner(runnerTestID),
        .destroy(runnerTestID),
    ])
    #expect(try leaseStore.load() == [lease])
}

@Test
func recoveryRoutesMixedLeasesAndRemovesClonesBeforeBusyRetry() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let macID = RunnerID(value: "yieldd-aaa-macos")
    let macLease = RunnerLease(runnerID: macID, repository: runnerTestRepository, platform: .macOS)
    try leaseStore.save(macLease)
    try leaseStore.save(RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository))
    let clones = MacOSRunnerCloneStore(stateDirectory: stateDirectory)
    for url in try [clones.creatingURL(for: macID), clones.bundleURL(for: macID), clones.bundleURL(for: RunnerID(value: "yieldd-macos-orphan"))] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let events = RunnerTestEventRecorder()
    let github = RunnerTestGitHub(events: events, removeOutcomes: [
        .failure(GitHubRunnerClientError.runnerBusy(name: macID.value)), .success(()), .success(()),
    ])
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) }, github: github, leaseStore: leaseStore,
        recoveryWait: { _ in
            let contents = try FileManager.default.contentsOfDirectory(atPath: clones.rootURL.path)
            #expect(contents.isEmpty)
            let remaining = try leaseStore.load()
            #expect(remaining == [macLease])
            #expect(events.values.last == .destroy(runnerTestID))
        }
    )
    #expect(try recovery.run() == [macID, runnerTestID])
    #expect(events.values == [
        .removeGitHubRunner(macID.value, runnerTestRepository),
        .stopRunner(runnerTestID), .removeGitHubRunner(runnerTestID.value, runnerTestRepository), .destroy(runnerTestID),
        .removeGitHubRunner(macID.value, runnerTestRepository),
    ])
    #expect(try leaseStore.load().isEmpty)
}

@Test
func recoveryRetainsFailedMacOSLeaseAndStillRecoversLinux() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let macID = RunnerID(value: "yieldd-aaa-macos")
    let macLease = RunnerLease(runnerID: macID, repository: runnerTestRepository, platform: .macOS)
    try leaseStore.save(macLease)
    try leaseStore.save(RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository))
    let clones = MacOSRunnerCloneStore(stateDirectory: stateDirectory)
    let bundle = try clones.bundleURL(for: macID)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data("state".utf8).write(to: bundle.appendingPathComponent("state"))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bundle.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundle.path) }
    let events = RunnerTestEventRecorder()
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) }, github: RunnerTestGitHub(events: events), leaseStore: leaseStore
    )
    #expect(throws: RunnerSessionError.self) { try recovery.run() }
    #expect(try leaseStore.load() == [macLease])
    #expect(events.values == [
        .removeGitHubRunner(macID.value, runnerTestRepository),
        .stopRunner(runnerTestID), .removeGitHubRunner(runnerTestID.value, runnerTestRepository), .destroy(runnerTestID),
    ])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundle.path)
    #expect(try recovery.run() == [macID])
    #expect(try leaseStore.load().isEmpty)
}

@Test
func recoverySweepsOrphansWhenNoLeasesExist() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let clones = MacOSRunnerCloneStore(stateDirectory: stateDirectory)
    let orphan = try clones.creatingURL(for: RunnerID(value: "yieldd-macos-orphan"))
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let events = RunnerTestEventRecorder()
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) }, github: RunnerTestGitHub(events: events), leaseStore: leaseStore
    )
    #expect(try recovery.run().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(events.values.isEmpty)
}

@Test(arguments: [false, true])
func macOSRecoveryDoesNotDependOnLinuxTools(hasLinuxLease: Bool) throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let macID = RunnerID(value: "yieldd-macos-test")
    try leaseStore.save(RunnerLease(runnerID: macID, repository: runnerTestRepository, platform: .macOS))
    let linuxLease = RunnerLease(runnerID: RunnerID(value: "yieldd-linux-test"), repository: runnerTestRepository)
    if hasLinuxLease { try leaseStore.save(linuxLease) }
    let clones = MacOSRunnerCloneStore(stateDirectory: stateDirectory)
    let clone = try clones.bundleURL(for: macID)
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    let events = RunnerTestEventRecorder()
    var linuxBackendRequests = 0
    let recovery = RunnerRecovery(
        linuxBackend: {
            linuxBackendRequests += 1
            throw TestFailure.create
        },
        github: RunnerTestGitHub(events: events), leaseStore: leaseStore
    )
    if hasLinuxLease {
        let error = try #require(#expect(throws: RunnerSessionError.self) { try recovery.run() })
        guard case let .cleanupFailed(failures) = error,
              failures.count == 1,
              case let RunnerRecoveryError.linuxBackendUnavailable(underlying) = failures[0].error else {
            Issue.record("Expected a Linux backend recovery failure")
            return
        }
        #expect(failures[0].step == .machine)
        #expect((underlying as? TestFailure) == .create)
        #expect(describeError(error).contains("Linux lease recovery could not prepare Apple Container"))
    } else {
        #expect(try recovery.run() == [macID])
    }
    #expect(linuxBackendRequests == (hasLinuxLease ? 1 : 0))
    #expect(try leaseStore.load() == (hasLinuxLease ? [linuxLease] : []))
    #expect(events.values == [.removeGitHubRunner(macID.value, runnerTestRepository)])
    #expect(!FileManager.default.fileExists(atPath: clone.path))
}

@Test
func recoveryRejectsInvalidLeaseBeforeSweepingClones() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    try Data(#"[{"runnerID":"yieldd-macos-runner","repository":"owner/repository","platform":"unknown"}]"#.utf8)
        .write(to: leaseStore.fileURL)
    let clones = MacOSRunnerCloneStore(stateDirectory: stateDirectory)
    let orphan = try clones.bundleURL(for: RunnerID(value: "yieldd-macos-orphan"))
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let events = RunnerTestEventRecorder()
    let recovery = RunnerRecovery(
        linuxBackend: { RunnerTestBackend(events: events) }, github: RunnerTestGitHub(events: events), leaseStore: leaseStore
    )
    #expect(throws: RunnerLeaseError.self) { try recovery.run() }
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    #expect(events.values.isEmpty)
}

@Test
func sharedReporterEmitsRecoveryRetriesAndLeaseClearFailures() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        try? FileManager.default.removeItem(at: stateDirectory)
    }
    let lease = RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository, platform: .macOS)
    try leaseStore.save(lease)
    let messages = RecoveryMessages()
    let events = RunnerTestEventRecorder()
    let output = RunnerServiceOutput(
        info: { messages.append("info: \($0)") },
        warning: { messages.append("warning: \($0)") },
        error: { messages.append("error: \($0)") }
    )
    var states: [RunnerSessionState] = []
    let recovery = RunnerRecovery(
        linuxBackend: { throw TestFailure.create },
        github: RunnerTestGitHub(events: events, removeOutcomes: [
            .failure(GitHubRunnerClientError.runnerBusy(name: runnerTestID.value)), .success(()),
        ]),
        leaseStore: leaseStore,
        recoveryWait: { delay in
            #expect(delay == 1)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDirectory.path)
        },
        stateChanged: {
            states.append($0)
            reportRunnerRecoveryState($0, output: output)
        }
    )
    #expect(try recovery.run() == [runnerTestID])
    #expect(states.first == .waitingForGitHubCleanup(runnerTestID, retryDelay: 1))
    guard case let .leaseCleanupFailed(id, reason) = states.last else {
        Issue.record("Expected a lease-clear failure after the busy-runner retry")
        return
    }
    #expect(id == runnerTestID)
    #expect(!reason.isEmpty)
    #expect(messages.values == [
        "info: \(githubCleanupRetryMessage(id: runnerTestID, delay: 1))",
        "warning: Could not clear runner lease for \(runnerTestID.value): \(reason)",
    ])
    #expect(try leaseStore.load() == [lease])
}

@Test(arguments: [false, true])
func recoveryFactoryPreservesCancellationIdentity(signal: Bool) throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let lease = RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository)
    try leaseStore.save(lease)
    let events = RunnerTestEventRecorder()
    let recovery = RunnerRecovery(
        linuxBackend: {
            if signal { throw SignalInterruption(signal: SIGHUP) }
            throw CancellationError()
        },
        github: RunnerTestGitHub(events: events), leaseStore: leaseStore
    )
    let error = try #require(#expect(throws: (any Error).self) { try recovery.run() })
    if signal {
        #expect((error as? SignalInterruption)?.signal == SIGHUP)
    } else {
        #expect(error is CancellationError)
    }
    #expect(try leaseStore.load() == [lease])
    #expect(events.values.isEmpty)
}

@Test
func sharedRecoveryReporterLeavesCommandSpecificStatesSilent() {
    let messages = RecoveryMessages()
    let output = RunnerServiceOutput(info: messages.append, warning: messages.append, error: messages.append)
    let states: [RunnerSessionState] = [
        .preparing(runnerTestID), .waitingForMemory(runnerTestID),
        .waitingForJob(runnerTestID), .cleaningUp(runnerTestID),
    ]
    for state in states { reportRunnerRecoveryState(state, output: output) }
    #expect(messages.values.isEmpty)
}

private final class RecoveryMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var values: [String] { lock.withLock { messages } }
    func append(_ message: String) { lock.withLock { messages.append(message) } }
}

@Test(arguments: [false, true])
func templateInsideCloneRootIsRejectedBeforeRecovery(symlink: Bool) throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let clones = MacOSRunnerCloneStore(stateDirectory: stateDirectory)
    let template = try clones.bundleURL(for: RunnerID(value: "yieldd-template"))
    try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
    let contents = Data("template must survive".utf8)
    let disk = template.appendingPathComponent("Disk.img")
    try contents.write(to: disk)
    let alias = stateDirectory.appendingPathComponent("Template.bundle")
    if symlink { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: template) }
    let events = RunnerTestEventRecorder()
    let executor = RecordingProcessExecutor(outcomes: [])
    let error = try #require(#expect(throws: MacOSVirtualizationBackendError.self) {
        _ = try MacOSVirtualizationBackend(
            templateURL: symlink ? alias : template, cloneRootURL: clones.rootURL, executor: executor
        )
        try recoverAbandonedRunners(
            leaseStore: leaseStore,
            makeGitHub: { RunnerTestGitHub(events: events) },
            makeLinuxBackend: { RunnerTestBackend(events: events) },
            checkCancellation: {}, wait: { _ in }
        )
    })
    guard case .templateInsideCloneRoot = error else {
        Issue.record("Expected template location rejection")
        return
    }
    #expect(describeError(error).contains("Move the macOS template"))
    #expect(describeError(error).contains("Subsequent recovery commands may delete"))
    #expect(try Data(contentsOf: disk) == contents)
    #expect(executor.requests.isEmpty)
    #expect(events.values.isEmpty)
    // Confirm this fixture really would be swept if initialization allowed recovery to run.
    try clones.removeUnleased(keeping: [])
    #expect(!FileManager.default.fileExists(atPath: template.path))
}

@Test
func sessionCleanupFailureKeepsTheLeaseAndMemoryReservation() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    var waitedForCapacity = false
    let memoryAdmission = RunnerMemoryAdmission(
        physicalMemoryBytes: runnerTestMemoryBytes * 4 / 3 + 1,
        readMemoryPressure: { .normal }
    )
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
    #expect(throws: CancellationError.self) {
        try memoryAdmission.acquire(reserving: RunnerPlatform.linux.memoryReservationBytes, checkCancellation: {
            if waitedForCapacity {
                throw CancellationError()
            }
        }, onBlocked: { waitedForCapacity = true })
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
            .success(()),
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
            .success(()),
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
            .success(()),
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
            .success(()),
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
            .success(()),
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
            .success(()),
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

@Test
func cancellationWhileWaitingForMemorySkipsMachineCleanupAndLeasePersistence() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    var blocked = false
    var states: [RunnerSessionState] = []
    let memoryAdmission = RunnerMemoryAdmission(
        physicalMemoryBytes: 4 * runnerTestMemoryBytes,
        readMemoryPressure: { .critical }
    )

    #expect(throws: CancellationError.self) {
        try EphemeralRunnerSession(
            backend: RunnerTestBackend(events: events),
            github: RunnerTestGitHub(events: events),
            memoryAdmission: memoryAdmission,
            checkCancellation: {
                if blocked {
                    throw CancellationError()
                }
            },
            stateChanged: { state in
                states.append(state)
                if case .waitingForMemory = state {
                    blocked = true
                }
            },
            leaseStore: leaseStore
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(events.values.isEmpty)
    #expect(states == [
        .preparing(runnerTestID),
        .waitingForMemory(runnerTestID),
    ])
    #expect(try leaseStore.load().isEmpty)
}

@Test
func insufficientHostMemoryFailsBeforeProvisioning() throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    let memoryAdmission = RunnerMemoryAdmission(
        physicalMemoryBytes: 2,
        readMemoryPressure: { .normal }
    )

    #expect(throws: RunnerMemoryAdmissionError.insufficientHostMemory(
        requiredBytes: runnerTestMemoryBytes,
        budgetBytes: 2
    )) {
        try EphemeralRunnerSession(
            backend: RunnerTestBackend(events: events),
            github: RunnerTestGitHub(events: events),
            memoryAdmission: memoryAdmission,
            leaseStore: leaseStore
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(events.values.isEmpty)
    #expect(try leaseStore.load().isEmpty)
}

@Test
func memoryAdmissionPrecedesRegistrationTokenCreation() {
    let events = RunnerTestEventRecorder()
    let memoryAdmission = RunnerMemoryAdmission(
        physicalMemoryBytes: 4 * runnerTestMemoryBytes,
        readMemoryPressure: {
            events.values.append(.memoryAdmission)
            return .normal
        }
    )

    #expect(throws: TestFailure.create) {
        try EphemeralRunnerSession(
            backend: RunnerTestBackend(events: events, createError: TestFailure.create),
            github: RunnerTestGitHub(events: events),
            memoryAdmission: memoryAdmission
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(events.values.prefix(2) == [
        .memoryAdmission,
        .createRegistrationToken(runnerTestRepository),
    ])
}

@Test(arguments: [RunnerPlatform.linux, .macOS])
func leaseIsPersistedImmediatelyBeforeMachineCreationAndClearedAfterFailure(platform: RunnerPlatform) throws {
    let (leaseStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let events = RunnerTestEventRecorder()
    let lease = RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository, platform: platform)
    let github = RunnerTestGitHub(
        events: events,
        onCreateRegistrationToken: {
            let leases = try leaseStore.load()
            #expect(leases.isEmpty)
        }
    )
    let backend = RunnerTestBackend(
        events: events,
        platform: platform,
        createError: TestFailure.create,
        onCreate: {
            let leases = try leaseStore.load()
            #expect(leases == [lease])
        }
    )

    #expect(throws: TestFailure.create) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: runnerTestMemoryAdmission(),
            leaseStore: leaseStore
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .create(runnerTestID, .full),
        .destroy(runnerTestID),
    ])
    #expect(try leaseStore.load().isEmpty)
}

@Test(arguments: [RunnerPlatform.linux, .macOS])
func leaseSynchronizationFailureClearsPublishedLeaseBeforeReturning(platform: RunnerPlatform) throws {
    let (readStore, stateDirectory) = try makeRunnerLeaseStore()
    defer { try? FileManager.default.removeItem(at: stateDirectory) }
    let alias = stateDirectory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: stateDirectory)
    // Publication succeeds through the alias, but synchronizing it with O_NOFOLLOW fails.
    let leaseStore = try RunnerLeaseStore(directory: alias)
    let events = RunnerTestEventRecorder()
    let memoryAdmission = singleRunnerMemoryAdmission()
    var publishedLeases: Result<[RunnerLease], any Error>?

    #expect(throws: POSIXError(.ELOOP)) {
        try EphemeralRunnerSession(
            backend: RunnerTestBackend(events: events, platform: platform),
            github: RunnerTestGitHub(events: events),
            memoryAdmission: memoryAdmission,
            stateChanged: { state in
                if case .cleaningUp = state {
                    publishedLeases = Result { try readStore.load() }
                }
            },
            leaseStore: leaseStore
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    let observedLeases = try #require(publishedLeases).get()
    #expect(observedLeases == [
        RunnerLease(runnerID: runnerTestID, repository: runnerTestRepository, platform: platform),
    ])
    #expect(events.values == [
        .createRegistrationToken(runnerTestRepository),
        .destroy(runnerTestID),
    ])
    #expect(try readStore.load().isEmpty)
    var blocked = false
    let reservation = try memoryAdmission.acquire(
        reserving: platform.memoryReservationBytes,
        checkCancellation: { if blocked { throw CancellationError() } },
        onBlocked: { blocked = true }
    )
    memoryAdmission.release(reservation)
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
        execOutcomes: Array(repeating: .success(()), count: 2)
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
func backendProvisioningFailureReleasesMemoryAfterDestroyingMachine() throws {
    let events = RunnerTestEventRecorder()
    let memoryAdmission = singleRunnerMemoryAdmission()
    let backend = RunnerTestBackend(
        events: events,
        createError: TestFailure.memoryAllocation
    )
    let github = RunnerTestGitHub(events: events)

    #expect(throws: TestFailure.memoryAllocation) {
        try EphemeralRunnerSession(
            backend: backend,
            github: github,
            memoryAdmission: memoryAdmission
        ).run(id: runnerTestID, repository: runnerTestRepository)
    }

    #expect(events.values.suffix(2) == [
        .create(runnerTestID, .full),
        .destroy(runnerTestID),
    ])
    memoryAdmission.release(try memoryAdmission.acquire(reserving: RunnerPlatform.linux.memoryReservationBytes))
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
    ])
    let nextReservation = try memoryAdmission.acquire(reserving: RunnerPlatform.linux.memoryReservationBytes)
    memoryAdmission.release(nextReservation)
}

private final class RunnerTestEventRecorder: @unchecked Sendable {
    var values: [RunnerTestEvent] = []
}

private final class RunnerTestBackend: RunnerBackend {
    let platform: RunnerPlatform
    private(set) var outputCaptures: [ProcessOutputCapture] = []
    private let events: RunnerTestEventRecorder
    private let createError: (any Error)?
    private let onCreate: () throws -> Void
    private var execOutcomes: [Result<Void, any Error>]
    private let stopError: (any Error)?
    private let destroyError: (any Error)?

    init(
        events: RunnerTestEventRecorder,
        platform: RunnerPlatform = .linux,
        createError: (any Error)? = nil,
        onCreate: @escaping () throws -> Void = {},
        execOutcomes: [Result<Void, any Error>] = [],
        stopError: (any Error)? = nil,
        destroyError: (any Error)? = nil
    ) {
        self.events = events
        self.platform = platform
        self.createError = createError
        self.onCreate = onCreate
        self.execOutcomes = execOutcomes
        self.stopError = stopError
        self.destroyError = destroyError
    }

    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws {
        events.values.append(.create(id, memory))
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
        outputCaptures.append(outputCapture)
        events.values.append(.exec(id, arguments, standardInput, timeout, user))
        guard !execOutcomes.isEmpty else {
            throw TestFailure.unexpectedBackendCall
        }
        try execOutcomes.removeFirst().get()
        return processResult()
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
    private let onCreateRegistrationToken: () throws -> Void
    private var removeOutcomes: [Result<Void, any Error>]

    init(
        events: RunnerTestEventRecorder,
        registrationToken: String = "registration-token",
        tokenError: (any Error)? = nil,
        onCreateRegistrationToken: @escaping () throws -> Void = {},
        removeOutcomes: [Result<Void, any Error>] = []
    ) {
        self.events = events
        self.registrationToken = registrationToken
        self.tokenError = tokenError
        self.onCreateRegistrationToken = onCreateRegistrationToken
        self.removeOutcomes = removeOutcomes
    }

    func createRegistrationToken(for repository: GitHubRepository) throws -> String {
        events.values.append(.createRegistrationToken(repository))
        try onCreateRegistrationToken()
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
    case memoryAdmission
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
