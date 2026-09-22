import Darwin
import Foundation
import Testing
@testable import Yieldd

private let macOSBackendID = RunnerID(value: "yieldd-macos-test")

private func makeBackend(
    _ fixture: ProbeBundleFixture,
    templateURL: URL? = nil,
    executor: any ProcessExecuting,
    network: BackendNetwork = BackendNetwork(),
    checkCancellation: @escaping () throws -> Void = {},
    wait: @escaping (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:),
    maximumExecutionDeadline: @escaping () -> DispatchTime? = { nil },
    bootTimeout: TimeInterval = MacOSVirtualMachineLifecycle.bootTimeout,
    stopTimeout: TimeInterval = MacOSVirtualMachineLifecycle.stopTimeout,
    requireRelay: @escaping () throws -> Void = {},
    loadStorage: @escaping () throws -> RunnerStorage? = { nil },
    makeMachine: @escaping (URL, UInt64, URL) throws -> any MacOSVirtualMachineControlling
) throws -> MacOSVirtualizationBackend {
    try MacOSVirtualizationBackend(
        stateDirectory: fixture.rootURL, templateURL: templateURL ?? fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: executor, network: network, checkCancellation: checkCancellation, wait: wait,
        maximumExecutionDeadline: maximumExecutionDeadline, bootTimeout: bootTimeout, stopTimeout: stopTimeout,
        requireEntitlement: {}, requireRelay: requireRelay, loadStorage: loadStorage, makeMachine: makeMachine
    )
}

@Test
func macOSStorageLossStopsVMButRetainsCleanupObligation() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    var unavailable = false
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 3)),
        loadStorage: {
            if unavailable {
                throw RunnerStorageError.volumeUnavailable(path: "/Volumes/Guest")
            }
            return nil
        }, makeMachine: { _, _, _ in machine }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    unavailable = true
    #expect(throws: RunnerStorageError.volumeUnavailable(path: "/Volumes/Guest")) { try backend.destroy(macOSBackendID) }
    #expect(machine.stopCount == 1)
    #expect(try !fixture.cloneRootContents().isEmpty)
    unavailable = false
    try backend.destroy(macOSBackendID)
    #expect(machine.stopCount == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendPinsSSHToResolvedTemplateAfterSymlinkRetargeting() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let link = fixture.rootURL.appendingPathComponent("Current.bundle")
    let replacement = fixture.rootURL.appendingPathComponent("Replacement.bundle")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.templateURL)
    let executor = RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 4))
    let backend = try makeBackend(fixture, templateURL: link,
        executor: executor, makeMachine: { url, _, _ in
            let disk = try Data(contentsOf: url.appendingPathComponent("Disk.img"))
            #expect(disk == fixture.disk)
            return ProbeVirtualMachine()
        }
    )
    defer { try? backend.destroy(macOSBackendID) }
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)

    try backend.create(id: macOSBackendID, memory: .full)
    try backend.exec(["/usr/bin/true"], on: macOSBackendID)
    try backend.stopRunner(on: macOSBackendID)
    #expect(executor.requests.count == 4)
    let resolved = fixture.templateURL.resolvingSymlinksInPath()
    for request in executor.requests {
        #expect(request.arguments.contains(resolved.appendingPathComponent("SSHPrivateKey").path))
        #expect(request.arguments.contains("UserKnownHostsFile=\"\(resolved.appendingPathComponent("SSHKnownHosts").path)\""))
    }
}

@Test
func macOSBackendCreatesOnceAndDestroysRepeatedly() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let executor = RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 3))
    let backend = try makeBackend(fixture,
        executor: executor, makeMachine: { url, memory, socket in
            #expect(socket == BackendRelay.socket)
            #expect(url.lastPathComponent == "yieldd-macos-test.bundle")
            #expect(!FileManager.default.fileExists(atPath: fixture.cloneRootURL.appendingPathComponent("yieldd-macos-test.creating").path))
            #expect(memory == MacOSVirtualMachineLifecycle.constrainedMemoryBytes)
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("MACAddress").path))
            return machine
        }
    )
    try backend.create(id: macOSBackendID, memory: .constrained)
    try backend.create(id: macOSBackendID, memory: .constrained)
    #expect(machine.startCount == 1)
    #expect(executor.requests.count == 2)
    for request in executor.requests {
        #expect(request.arguments.contains("runner@yieldd-macos-template"))
        #expect(request.arguments.contains("ProxyCommand=/usr/bin/nc -U '\(BackendRelay.socket.path).ssh'"))
        #expect(request.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(request.arguments.contains("HostKeyAlias=yieldd-macos-template"))
    }
    try backend.stopRunner(on: macOSBackendID)
    let stop = try #require(executor.requests.last)
    #expect(!stop.cancellable)
    #expect(stop.timeout == 20)
    try backend.destroy(macOSBackendID)
    try backend.destroy(macOSBackendID)
    #expect(machine.stopCount == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test(arguments: [false, true])
func macOSBackendCleansCloneAfterCreationOrBootFailure(failBoot: Bool) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(startError: TestFailure.create)
    let network = BackendNetwork()
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: []), network: network, makeMachine: { _, _, _ in
            if !failBoot { throw TestFailure.create }
            return machine
        }
    )
    #expect(throws: TestFailure.create) {
        try backend.create(id: macOSBackendID, memory: .full)
    }
    #expect(machine.stopCount == (failBoot ? 1 : 0))
    #expect(network.relays.first?.stops == 1)
    #expect(network.removed.last == macOSBackendID)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendStopsAndRemovesCloneAfterReadinessFailure() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let network = BackendNetwork()
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()), .failure(TestFailure.runnerConfiguration),
    ])
    let backend = try makeBackend(fixture,
        executor: executor, network: network, makeMachine: { _, _, _ in machine }
    )
    #expect(throws: TestFailure.runnerConfiguration) {
        try backend.create(id: macOSBackendID, memory: .full)
    }
    #expect(machine.stopCount == 1)
    #expect(machine.isStopped)
    #expect(network.relays.first?.stops == 1)
    #expect(network.removed.last == macOSBackendID)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendCancellationDuringReadinessStillCleansUp() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    var cancelled = false
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: [.success(processResult(status: 255))]),
        checkCancellation: { if cancelled { throw TestFailure.cancelled } },
        wait: { _ in cancelled = true }, makeMachine: { _, _, _ in machine }
    )
    #expect(throws: TestFailure.cancelled) {
        try backend.create(id: macOSBackendID, memory: .full)
    }
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendRetainsMachineAndCloneWhenForcedStopFails() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(stopError: TestFailure.cleanup)
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        makeMachine: { _, _, _ in machine }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    for _ in 0..<2 {
        #expect(throws: TestFailure.cleanup) { try backend.destroy(macOSBackendID) }
    }
    #expect(machine.stopCount == 2)
    #expect(try fixture.cloneRootContents().count == 1)
}

@Test
func macOSCloneStoreRecoversBothPathsWithoutATemplate() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL)
    for url in try [store.creatingURL(for: macOSBackendID), store.bundleURL(for: macOSBackendID)] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try FileManager.default.removeItem(at: fixture.templateURL)
    try store.remove(macOSBackendID)
    try store.remove(macOSBackendID)
    #expect(try fixture.cloneRootContents().isEmpty)
    #expect(throws: RunnerLeaseError.self) { try store.remove(RunnerID(value: "yieldd-../../Template")) }
}

@Test
func macOSBackendRunsThroughTheExistingSession() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let github = BackendGitHub()
    let executor = RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 4))
    let backend = try makeBackend(fixture,
        executor: executor, makeMachine: { _, _, _ in machine }
    )
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 12 * 1_024 * 1_024 * 1_024,
        readMemoryPressure: { .normal }
    )
    try EphemeralRunnerSession(
        backend: backend, github: github, memoryAdmission: admission, jobTimeout: 60
    ).run(id: macOSBackendID, repository: GitHubRepository("owner/repo"))
    #expect(github.removed == [macOSBackendID.value])
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
    #expect(executor.requests[2].standardInput == Data("token\n".utf8))
    #expect(executor.requests[2].arguments.last == "'/Users/runner/bin/yieldd-configure-runner' 'owner/repo' 'yieldd-macos-test'")
    #expect(executor.requests[3].arguments.last == "'/Users/runner/bin/yieldd-runner-control' 'run'")
    #expect(executor.requests[3].arguments.contains("runner@yieldd-macos-template"))
    let reservation = try admission.acquireWithoutWaiting(reserving: RunnerPlatform.macOS.memoryReservationBytes)
    admission.release(reservation)
}

private final class BackendNetwork: MacOSRunnerNetworking {
    var startError: (any Error)?
    var relays: [BackendRelay] = []
    var removed: [RunnerID] = []
    var onStart: (BackendRelay) -> Void = { _ in }
    func start(for id: RunnerID, checkCancellation: () throws -> Void) throws -> any RunnerNetworkRelaying {
        try checkCancellation()
        if let startError { throw startError }
        let relay = BackendRelay()
        relays.append(relay)
        onStart(relay)
        return relay
    }
    func remove(_ id: RunnerID) throws { removed.append(id) }
}

private final class BackendRelay: RunnerNetworkRelaying {
    static let socket = URL(fileURLWithPath: "/unused/network.sock")
    let socketURL = socket
    let sshSocketURL = socket.appendingPathExtension("ssh")
    var failure: (any Error)?
    var stopFailure: (any Error)?
    var stops = 0
    var stopDeadline: DispatchTime?
    func check() throws { if let failure { throw failure } }
    func stop(deadline: DispatchTime?) throws {
        stops += 1
        stopDeadline = deadline
        if let stopFailure { throw stopFailure }
    }
}

@Test
func macOSBackendRejectsMissingRelayBeforeRecordingIntent() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let network = BackendNetwork()
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: []), network: network,
        requireRelay: { throw TestFailure.create },
        makeMachine: { _, _, _ in Issue.record("VM must not be constructed"); throw TestFailure.create }
    )
    var recorded = false
    #expect(throws: TestFailure.create) {
        try backend.create(id: macOSBackendID, memory: .full, recordIntent: { recorded = true })
    }
    #expect(!recorded)
    #expect(network.relays.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.cloneRootURL.path))
}

@Test
func macOSBackendRelayStartupFailureDoesNotBootOrRetainClone() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let network = BackendNetwork()
    network.startError = TestFailure.create
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: []), network: network,
        makeMachine: { _, _, _ in Issue.record("No NAT fallback may boot"); throw TestFailure.runnerJob }
    )
    #expect(throws: TestFailure.create) { try backend.create(id: macOSBackendID, memory: .full) }
    #expect(network.removed.last == macOSBackendID)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendChecksRelayWhileVMStartupIsPending() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let network = BackendNetwork()
    network.onStart = { $0.failure = TestFailure.runnerJob }
    let machine = ProbeVirtualMachine(completesStart: false)
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: []), network: network, bootTimeout: 0.1,
        makeMachine: { _, _, _ in machine }
    )
    #expect(throws: TestFailure.runnerJob) { try backend.create(id: macOSBackendID, memory: .full) }
    #expect(machine.isStopped)
    #expect(network.relays.first?.stops == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendDoesNotSendCommandsAfterRelayExit() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let network = BackendNetwork()
    let machine = ProbeVirtualMachine()
    let executor = RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2))
    let backend = try makeBackend(fixture,
        executor: executor, network: network, makeMachine: { _, _, _ in machine }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    let relay = try #require(network.relays.first)
    relay.failure = TestFailure.runnerJob
    #expect(throws: TestFailure.runnerJob) { try backend.exec(["true"], on: macOSBackendID) }
    #expect(throws: TestFailure.runnerJob) { try backend.stopRunner(on: macOSBackendID) }
    #expect(executor.requests.count == 2)
    try backend.destroy(macOSBackendID)
    #expect(machine.isStopped)
    #expect(relay.stops == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendRelayCleanupFailureRetainsSessionLeaseAndCapacity() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let network = BackendNetwork()
    network.onStart = { $0.stopFailure = TestFailure.cleanup }
    let machine = ProbeVirtualMachine()
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: [
            .success(processResult()), .success(processResult()), .failure(TestFailure.runnerConfiguration),
        ]), network: network, makeMachine: { _, _, _ in machine }
    )
    let leaseStore = try RunnerLeaseStore(directory: fixture.rootURL)
    let memory = RunnerMemoryAdmission(physicalMemoryBytes: 12 * 1_024 * 1_024 * 1_024, readMemoryPressure: { .normal })
    let session = EphemeralRunnerSession(backend: backend, github: BackendGitHub(), memoryAdmission: memory, leaseStore: leaseStore)
    #expect(throws: RunnerSessionError.self) { try session.run(id: macOSBackendID, repository: GitHubRepository("owner/repo")) }
    #expect(machine.isStopped)
    #expect(try leaseStore.load().map(\.runnerID) == [macOSBackendID])
    #expect(throws: TestFailure.memoryAllocation) {
        _ = try memory.acquireWithoutWaiting(reserving: RunnerPlatform.macOS.memoryReservationBytes)
    }
    network.relays.first?.stopFailure = nil
    try backend.destroy(macOSBackendID)
}

@Test
func macOSBackendRelayStopFailureStillStopsVMAndRetainsCleanup() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let network = BackendNetwork()
    let machine = ProbeVirtualMachine()
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        network: network, makeMachine: { _, _, _ in machine }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    let relay = try #require(network.relays.first)
    relay.stopFailure = TestFailure.cleanup
    network.removed = []
    #expect(throws: TestFailure.cleanup) { try backend.destroy(macOSBackendID) }
    #expect(machine.isStopped)
    #expect(network.removed.isEmpty)
    #expect(try !fixture.cloneRootContents().isEmpty)
    relay.stopFailure = nil
    try backend.destroy(macOSBackendID)
    #expect(relay.stops == 2)
    #expect(network.removed == [macOSBackendID])
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test(arguments: [false, true])
func macOSBackendReleasesTerminallyFailedMachine(replaceDirectly: Bool) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    weak var firstMachine: ProbeVirtualMachine?
    var creations = 0
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 4)),
        makeMachine: { _, _, _ in
            let machine = ProbeVirtualMachine()
            if creations == 0 { firstMachine = machine }
            creations += 1
            return machine
        }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    firstMachine?.setState(.failed(TestFailure.runnerJob))
    try backend.stopRunner(on: macOSBackendID)
    if !replaceDirectly {
        try backend.destroy(macOSBackendID)
        try backend.destroy(macOSBackendID)
        #expect(firstMachine == nil)
        #expect(try fixture.cloneRootContents().isEmpty)
    }
    try backend.create(id: macOSBackendID, memory: .full)
    #expect(firstMachine == nil)
    #expect(creations == 2)
    try backend.destroy(macOSBackendID)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendTerminalFailurePreservesSessionErrorAndReleasesReservation() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: []), makeMachine: { _, _, _ in ProbeVirtualMachine(stateAfterStart: .failed(TestFailure.runnerJob)) }
    )
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 12 * 1_024 * 1_024 * 1_024, readMemoryPressure: { .normal }
    )
    do {
        try EphemeralRunnerSession(
            backend: backend, github: BackendGitHub(), memoryAdmission: admission, jobTimeout: 60
        ).run(id: macOSBackendID, repository: GitHubRepository("owner/repo"))
        Issue.record("Expected the original VM failure")
    } catch let MacOSVirtualizationProbeError.virtualMachineFailed(error) {
        #expect(error as? TestFailure == .runnerJob)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(try fixture.cloneRootContents().isEmpty)
    var blocked = false
    let reservation = try admission.acquire(
        reserving: MacOSVirtualMachineLifecycle.memoryBytes,
        checkCancellation: { if blocked { throw TestFailure.cancelled } },
        onBlocked: { blocked = true }
    )
    admission.release(reservation)
}

@Test
func macOSBackendReleasesMachineThatFailsDuringForcedStop() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    weak var machine: ProbeVirtualMachine?
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        makeMachine: { _, _, _ in
            let created = ProbeVirtualMachine(onForceStop: { machine?.setState(.failed(TestFailure.cleanup)) })
            machine = created
            return created
        }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    try backend.destroy(macOSBackendID)
    #expect(machine == nil)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendReplacesIncompleteCloneBeforeBoot() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let store = MacOSRunnerCloneStore(rootURL: fixture.cloneRootURL)
    for url in try [store.creatingURL(for: macOSBackendID), store.bundleURL(for: macOSBackendID)] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: url.appendingPathComponent("stale"))
    }
    let machine = ProbeVirtualMachine()
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        makeMachine: { url, _, _ in
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("stale").path))
            return machine
        }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    try backend.destroy(macOSBackendID)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendTimesOutBootAndCleansUp() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(completesStart: false)
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: []), bootTimeout: 0.001,
        makeMachine: { _, _, _ in machine }
    )
    #expect(throws: MacOSVirtualizationProbeError.self) {
        try backend.create(id: macOSBackendID, memory: .full)
    }
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendHonorsShutdownDeadlineAndRetainsCleanupState() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let network = BackendNetwork()
    var expired = false
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        network: network, maximumExecutionDeadline: { expired ? .now() : nil },
        makeMachine: { _, _, _ in machine }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    expired = true
    #expect(throws: MacOSVirtualizationProbeError.self) { try backend.destroy(macOSBackendID) }
    #expect(machine.stopCount == 0)
    let relayDeadline = try #require(network.relays.first?.stopDeadline)
    #expect(relayDeadline <= .now())
    #expect(try fixture.cloneRootContents().count == 1)
    expired = false
    try backend.destroy(macOSBackendID)
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendReplacesRunningGuestAfterRelayDeath() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let network = BackendNetwork()
    var machines: [ProbeVirtualMachine] = []
    let backend = try makeBackend(fixture,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 4)),
        network: network, makeMachine: { _, _, _ in
            let machine = ProbeVirtualMachine()
            machines.append(machine)
            return machine
        }
    )
    defer { try? backend.destroy(macOSBackendID) }
    try backend.create(id: macOSBackendID, memory: .full)
    let failedRelay = try #require(network.relays.first)
    failedRelay.failure = TestFailure.runnerJob
    try backend.create(id: macOSBackendID, memory: .full)
    #expect(machines.count == 2)
    #expect(machines.first?.isStopped == true)
    #expect(machines.last?.isStopped == false)
    #expect(failedRelay.stops == 1)
    #expect(network.relays.count == 2)
}

@Test
func macOSClonePublicationDoesNotOverwriteExistingBundle() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let clone = try MacOSVirtualizationProbeClone.create(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL, id: macOSBackendID
    )
    let identityURL = clone.url.appendingPathComponent("MachineIdentifier")
    let identity = try Data(contentsOf: identityURL)
    #expect(throws: (any Error).self) {
        _ = try MacOSVirtualizationProbeClone.create(
            templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL, id: macOSBackendID
        )
    }
    #expect(try Data(contentsOf: identityURL) == identity)
    #expect(try fixture.cloneRootContents().map(\.lastPathComponent) == [clone.url.lastPathComponent])
}

private final class BackendGitHub: GitHubRunnerManaging {
    var removed: [String] = []
    func createRegistrationToken(for repository: GitHubRepository) throws -> String { "token" }
    func removeRunners(named name: String, from repository: GitHubRepository) throws { removed.append(name) }
}

@Test
func macOSBackendBoundsRunnerStopByRemainingShutdownTime() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let executor = RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 3))
    var deadline: DispatchTime?
    let backend = try makeBackend(fixture,
        executor: executor, maximumExecutionDeadline: { deadline }, makeMachine: { _, _, _ in machine }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    deadline = .now() + 5
    try backend.stopRunner(on: macOSBackendID)
    let timeout = try #require(executor.requests.last?.timeout)
    #expect(timeout > 0 && timeout <= 5)
    deadline = .now()
    #expect(throws: MacOSVirtualizationProbeError.self) { try backend.stopRunner(on: macOSBackendID) }
    #expect(executor.requests.count == 3)
    deadline = nil
    try backend.destroy(macOSBackendID)
}

@Test
func macOSBackendSerializesConcurrentCreationForOneID() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let executor = RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2))
    let backend = try makeBackend(fixture,
        executor: executor, makeMachine: { _, _, _ in machine }
    )
    let creator = ConcurrentBackendCreator(backend: backend)
    DispatchQueue.concurrentPerform(iterations: 20) { _ in creator.create() }
    #expect(machine.startCount == 1)
    #expect(executor.requests.count == 2)
    #expect(try fixture.cloneRootContents().count == 1)
    try backend.destroy(macOSBackendID)
    #expect(try fixture.cloneRootContents().isEmpty)
}

// Only create crosses threads here; the backend lock protects it and its test dependencies.
private final class ConcurrentBackendCreator: @unchecked Sendable {
    let backend: MacOSVirtualizationBackend

    init(backend: MacOSVirtualizationBackend) { self.backend = backend }

    func create() {
        do {
            try backend.create(id: macOSBackendID, memory: .full)
        } catch {
            Issue.record(error)
        }
    }
}
