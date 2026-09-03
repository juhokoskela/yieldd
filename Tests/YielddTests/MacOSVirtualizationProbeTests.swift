import Foundation
import Testing
@testable import Yieldd

@Test
func virtualizationProbeCloneIsPrivateAndUsesFreshIdentity() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let clone = try MacOSVirtualizationProbeClone.create(
        templateURL: fixture.templateURL,
        cloneRootURL: fixture.cloneRootURL
    )

    #expect(clone.url != fixture.templateURL)
    #expect(
        try Data(contentsOf: clone.url.appendingPathComponent("HardwareModel"))
            == fixture.hardwareModel
    )
    #expect(
        try Data(contentsOf: clone.url.appendingPathComponent("MachineIdentifier"))
            != fixture.machineIdentifier
    )

    try Data("changed-disk".utf8).write(to: clone.url.appendingPathComponent("Disk.img"))
    try Data("changed-auxiliary".utf8).write(
        to: clone.url.appendingPathComponent("AuxiliaryStorage")
    )
    #expect(
        try Data(contentsOf: fixture.templateURL.appendingPathComponent("Disk.img"))
            == fixture.disk
    )
    #expect(
        try Data(
            contentsOf: fixture.templateURL.appendingPathComponent("AuxiliaryStorage")
        ) == fixture.auxiliaryStorage
    )
    #expect(
        try Data(
            contentsOf: fixture.templateURL.appendingPathComponent("MachineIdentifier")
        ) == fixture.machineIdentifier
    )
}

@Test
func virtualizationProbeChecksEntitlementBeforeCloning() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    var madeMachine = false
    let probe = MacOSVirtualizationProbe(
        requireEntitlement: { throw TestFailure.cancelled },
        makeMachine: { _ in
            madeMachine = true
            return ProbeVirtualMachine()
        }
    )

    #expect(throws: TestFailure.cancelled) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL
        )
    }
    #expect(!madeMachine)
    #expect(!FileManager.default.fileExists(atPath: fixture.cloneRootURL.path))
}

@Test
func virtualizationProbeStartsAndForceStopsMachine() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let probe = MacOSVirtualizationProbe(
        requireEntitlement: {},
        makeMachine: { cloneURL in
            #expect(cloneURL != fixture.templateURL)
            return machine
        }
    )

    try probe.run(
        templateURL: fixture.templateURL,
        cloneRootURL: fixture.cloneRootURL,
        wait: { _ in }
    )

    #expect(machine.startCount == 1)
    #expect(machine.stopCount == 1)
    #expect(machine.state == .stopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeDeletesCloneAfterMachineCreationFailure() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let probe = MacOSVirtualizationProbe(
        requireEntitlement: {},
        makeMachine: { _ in throw TestFailure.create }
    )

    #expect(throws: TestFailure.create) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL
        )
    }
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeForceStopsMachineAfterCancellation() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let probe = MacOSVirtualizationProbe(
        requireEntitlement: {},
        makeMachine: { _ in machine }
    )

    #expect(throws: SignalInterruption(signal: SIGINT)) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            wait: { _ in throw SignalInterruption(signal: SIGINT) }
        )
    }
    #expect(machine.stopCount == 1)
    #expect(machine.state == .stopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeReportsSignalReceivedDuringForcedStop() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let interruption = ProbeInterruption()
    let machine = ProbeVirtualMachine(onForceStop: interruption.record)
    let probe = MacOSVirtualizationProbe(
        requireEntitlement: {},
        makeMachine: { _ in machine }
    )

    #expect(throws: SignalInterruption(signal: SIGTERM)) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            checkCancellation: interruption.check,
            wait: { _ in }
        )
    }
    #expect(machine.state == .stopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeDoesNotStopAnAlreadyStoppedMachine() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(stateAfterStart: .stopped)
    let probe = MacOSVirtualizationProbe(
        requireEntitlement: {},
        makeMachine: { _ in machine }
    )

    #expect(throws: MacOSVirtualizationProbeError.self) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            wait: { _ in }
        )
    }
    #expect(machine.stopCount == 0)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbePreservesOperationAndCleanupFailures() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(stopError: TestFailure.cleanup)
    let probe = MacOSVirtualizationProbe(
        requireEntitlement: {},
        makeMachine: { _ in machine }
    )

    do {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            wait: { _ in throw TestFailure.cancelled }
        )
        Issue.record("Expected operation and cleanup to fail")
    } catch let MacOSVirtualizationProbeError.operationAndCleanupFailed(
        operation,
        cleanup
    ) {
        #expect(operation as? TestFailure == .cancelled)
        #expect(cleanup as? TestFailure == .cleanup)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private struct ProbeBundleFixture {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "yieldd-macos-probe-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    let hardwareModel = Data("hardware".utf8)
    let machineIdentifier = Data("template-identifier".utf8)
    let auxiliaryStorage = Data("auxiliary".utf8)
    let disk = Data("disk".utf8)

    var templateURL: URL {
        rootURL.appendingPathComponent("Template.bundle", isDirectory: true)
    }

    var cloneRootURL: URL {
        rootURL.appendingPathComponent("Clones", isDirectory: true)
    }

    init() throws {
        try FileManager.default.createDirectory(
            at: templateURL,
            withIntermediateDirectories: true
        )
        try hardwareModel.write(to: templateURL.appendingPathComponent("HardwareModel"))
        try machineIdentifier.write(
            to: templateURL.appendingPathComponent("MachineIdentifier")
        )
        try auxiliaryStorage.write(
            to: templateURL.appendingPathComponent("AuxiliaryStorage")
        )
        try disk.write(to: templateURL.appendingPathComponent("Disk.img"))
    }

    func cloneRootContents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: cloneRootURL,
            includingPropertiesForKeys: nil
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class ProbeVirtualMachine: @unchecked Sendable,
    MacOSVirtualMachineControlling
{
    private let lock = NSLock()
    private let stateAfterStart: MacOSVirtualMachineState
    private let onForceStop: () -> Void
    private let stopError: (any Error)?
    private var storedState: MacOSVirtualMachineState = .stopped
    private var starts = 0
    private var stops = 0

    init(
        stateAfterStart: MacOSVirtualMachineState = .running,
        onForceStop: @escaping () -> Void = {},
        stopError: (any Error)? = nil
    ) {
        self.stateAfterStart = stateAfterStart
        self.onForceStop = onForceStop
        self.stopError = stopError
    }

    var state: MacOSVirtualMachineState {
        lock.withLock { storedState }
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    func start(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        lock.withLock {
            starts += 1
            storedState = stateAfterStart
        }
        completion(.success(()))
    }

    func forceStop(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        onForceStop()
        if let stopError {
            completion(.failure(stopError))
            return
        }
        lock.withLock {
            stops += 1
            storedState = .stopped
        }
        completion(.success(()))
    }
}

private final class ProbeInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false

    func record() {
        lock.withLock {
            interrupted = true
        }
    }

    func check() throws {
        if lock.withLock({ interrupted }) {
            throw SignalInterruption(signal: SIGTERM)
        }
    }
}
