import Darwin
import Foundation
import Testing
@testable import Yieldd

private let macOSBackendID = RunnerID(value: "yieldd-macos-test")

@Test
func macOSBackendPinsSSHToResolvedTemplateAfterSymlinkRetargeting() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let link = fixture.rootURL.appendingPathComponent("Current.bundle")
    let replacement = fixture.rootURL.appendingPathComponent("Replacement.bundle")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.templateURL)
    let executor = RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 4))
    let backend = try MacOSVirtualizationBackend(
        templateURL: link, cloneRootURL: fixture.cloneRootURL,
        executor: executor, resolver: BackendAddressResolver(), requireEntitlement: {},
        makeMachine: { url, _ in
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: executor, resolver: BackendAddressResolver(), requireEntitlement: {},
        makeMachine: { url, memory in
            #expect(url.lastPathComponent == "yieldd-macos-test.bundle")
            #expect(!FileManager.default.fileExists(atPath: fixture.cloneRootURL.appendingPathComponent("yieldd-macos-test.creating").path))
            #expect(memory == MacOSVirtualMachineLifecycle.constrainedMemoryBytes)
            return machine
        }
    )
    try backend.create(id: macOSBackendID, memory: .constrained)
    try backend.create(id: macOSBackendID, memory: .constrained)
    #expect(machine.startCount == 1)
    #expect(executor.requests.count == 2)
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: []), requireEntitlement: {},
        makeMachine: { _, _ in
            if !failBoot { throw TestFailure.create }
            return machine
        }
    )
    #expect(throws: TestFailure.create) {
        try backend.create(id: macOSBackendID, memory: .full)
    }
    #expect(machine.stopCount == (failBoot ? 1 : 0))
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendStopsAndRemovesCloneAfterReadinessFailure() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()), .failure(TestFailure.runnerConfiguration),
    ])
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: executor, resolver: BackendAddressResolver(), requireEntitlement: {},
        makeMachine: { _, _ in machine }
    )
    #expect(throws: TestFailure.runnerConfiguration) {
        try backend.create(id: macOSBackendID, memory: .full)
    }
    #expect(machine.stopCount == 1)
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func macOSBackendCancellationDuringReadinessStillCleansUp() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    var cancelled = false
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: []),
        resolver: BackendAddressResolver(addressValue: nil),
        checkCancellation: { if cancelled { throw TestFailure.cancelled } },
        wait: { _ in cancelled = true }, requireEntitlement: {},
        makeMachine: { _, _ in machine }
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        resolver: BackendAddressResolver(), requireEntitlement: {}, makeMachine: { _, _ in machine }
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: executor, resolver: BackendAddressResolver(), requireEntitlement: {},
        makeMachine: { _, _ in machine }
    )
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 24 * 1_024 * 1_024 * 1_024,
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
    #expect(executor.requests[3].arguments.contains("runner@192.168.64.2"))
    let reservation = try admission.acquire()
    admission.release(reservation)
}

private struct BackendAddressResolver: MacOSGuestAddressResolving {
    var addressValue: String? = "192.168.64.2"
    func address(for macAddress: String) throws -> String? { addressValue }
}

@Test(arguments: [false, true])
func macOSBackendReleasesTerminallyFailedMachine(replaceDirectly: Bool) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    weak var firstMachine: ProbeVirtualMachine?
    var creations = 0
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 4)),
        resolver: BackendAddressResolver(), requireEntitlement: {},
        makeMachine: { _, _ in
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: []), requireEntitlement: {},
        makeMachine: { _, _ in ProbeVirtualMachine(stateAfterStart: .failed(TestFailure.runnerJob)) }
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        resolver: BackendAddressResolver(), requireEntitlement: {},
        makeMachine: { _, _ in
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        resolver: BackendAddressResolver(), requireEntitlement: {},
        makeMachine: { url, _ in
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: []), bootTimeout: 0.001,
        requireEntitlement: {}, makeMachine: { _, _ in machine }
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
    var expired = false
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: RecordingProcessExecutor(outcomes: Array(repeating: .success(processResult()), count: 2)),
        resolver: BackendAddressResolver(), maximumExecutionDeadline: { expired ? .now() : nil },
        requireEntitlement: {}, makeMachine: { _, _ in machine }
    )
    try backend.create(id: macOSBackendID, memory: .full)
    expired = true
    #expect(throws: MacOSVirtualizationProbeError.self) { try backend.destroy(macOSBackendID) }
    #expect(machine.stopCount == 0)
    #expect(try fixture.cloneRootContents().count == 1)
    expired = false
    try backend.destroy(macOSBackendID)
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: executor, resolver: BackendAddressResolver(),
        maximumExecutionDeadline: { deadline }, requireEntitlement: {},
        makeMachine: { _, _ in machine }
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
    let backend = try MacOSVirtualizationBackend(
        templateURL: fixture.templateURL, cloneRootURL: fixture.cloneRootURL,
        executor: executor, resolver: BackendAddressResolver(), requireEntitlement: {},
        makeMachine: { _, _ in machine }
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
