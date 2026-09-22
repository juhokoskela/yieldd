import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import Yieldd

#if arch(arm64)
import Virtualization

@Test
func virtualMachineAudioExposesOnlyASilentOutput() throws {
    let device = MacOSVirtualMachineLifecycle.makeAudioDevice()
    #expect(device.streams.count == 1)
    let output = try #require(device.streams.first as? VZVirtioSoundDeviceOutputStreamConfiguration)
    #expect(output.sink == nil)
}
#endif

@Test
func virtualizationProbeCloneIsPrivateAndUsesFreshIdentity() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
        at: fixture.cloneRootURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755]
    )
    for fileURL in fixture.requiredFileURLs {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: fileURL.path
        )
    }
    let macAddress = try MacOSVirtualizationProbeClone.macAddressString()
    let clone = try MacOSVirtualizationProbeClone.create(
        templateURL: fixture.templateURL,
        cloneRootURL: fixture.cloneRootURL,
        macAddress: macAddress
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
    #expect(try permissions(of: fixture.cloneRootURL) == 0o700)
    #expect(try permissions(of: clone.url) == 0o700)
    for filename in [
        "HardwareModel",
        "MachineIdentifier",
        "MACAddress",
        "AuxiliaryStorage",
        "Disk.img",
    ] {
        #expect(try permissions(of: clone.url.appendingPathComponent(filename)) == 0o600)
    }
    #expect(MacOSGuestAddressResolver.parseMACAddress(macAddress) != nil)
    #expect(
        try String(contentsOf: clone.url.appendingPathComponent("MACAddress"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == macAddress
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
func virtualizationProbeRejectsTemplateFIFOWithoutBlocking() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let diskURL = fixture.templateURL.appendingPathComponent("Disk.img")
    try FileManager.default.removeItem(at: diskURL)
    #expect(Darwin.mkfifo(diskURL.path, 0o600) == 0)

    do {
        _ = try MacOSVirtualizationProbeClone.create(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL
        )
        Issue.record("Expected the FIFO to be rejected")
    } catch let MacOSVirtualizationProbeError.templateFileIsNotRegular(path) {
        #expect(path == diskURL.path)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.cloneRootURL.path))
}

@Test
func virtualizationProbeReportsTheMissingTemplateFilePath() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let diskURL = fixture.templateURL.appendingPathComponent("Disk.img")
    try FileManager.default.removeItem(at: diskURL)

    do {
        try MacOSVirtualizationProbeClone.validateTemplate(at: fixture.templateURL)
        Issue.record("Expected template validation to fail")
    } catch let MacOSVirtualizationProbeError.fileOperationFailed(_, path, code) {
        #expect(path == diskURL.path)
        #expect(code == .ENOENT)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func virtualizationProbeExplainsCrossVolumeCloneFailure() {
    let templateURL = URL(fileURLWithPath: "/template.bundle")
    let cloneRootURL = URL(fileURLWithPath: "/clones")
    let error = MacOSVirtualizationProbeClone.cloneError(
        errorNumber: EXDEV,
        templateURL: templateURL,
        cloneRootURL: cloneRootURL,
        destinationURL: cloneRootURL.appendingPathComponent("Disk.img")
    )

    guard case .cloneRequiresSameVolume(let templatePath, let cloneRootPath) = error else {
        Issue.record("Unexpected error: \(error)")
        return
    }
    #expect(templatePath == templateURL.path)
    #expect(cloneRootPath == cloneRootURL.path)
}

@Test
func virtualizationProbeExplainsUnsupportedCloneFilesystem() {
    let templateURL = URL(fileURLWithPath: "/template.bundle")
    let cloneRootURL = URL(fileURLWithPath: "/clones")
    let error = MacOSVirtualizationProbeClone.cloneError(
        errorNumber: ENOTSUP,
        templateURL: templateURL,
        cloneRootURL: cloneRootURL,
        destinationURL: cloneRootURL.appendingPathComponent("Disk.img")
    )

    guard case .cloneUnsupported(let templatePath, let cloneRootPath) = error else {
        Issue.record("Unexpected error: \(error)")
        return
    }
    #expect(templatePath == templateURL.path)
    #expect(cloneRootPath == cloneRootURL.path)
}

@Test
func virtualizationProbeChecksEntitlementBeforeCloning() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    var madeMachine = false
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: { throw TestFailure.cancelled },
        makeMachine: { _, _ in
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
    var reportedStarted = false
    var reportedMACAddress: String?
    var waitedFor: TimeInterval?
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { cloneURL, memoryBytes in
            #expect(cloneURL != fixture.templateURL)
            #expect(memoryBytes == MacOSVirtualMachineLifecycle.memoryBytes)
            return machine
        }
    )

    try probe.run(
        templateURL: fixture.templateURL,
        cloneRootURL: fixture.cloneRootURL,
        wait: { waitedFor = $0 },
        waitUntilGuestReady: { macAddress, _ in reportedMACAddress = macAddress },
        started: { reportedStarted = true }
    )

    #expect(machine.startCount == 1)
    #expect(machine.stopCount == 1)
    #expect(machine.isStopped)
    #expect(reportedStarted)
    #expect(reportedMACAddress.flatMap(MacOSGuestAddressResolver.parseMACAddress) != nil)
    #expect(waitedFor == MacOSVirtualizationProbe.runDuration)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeUsesConstrainedBootMemory() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    var configuredMemory: UInt64?
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, memoryBytes in
            configuredMemory = memoryBytes
            return machine
        }
    )

    try probe.run(
        templateURL: fixture.templateURL,
        cloneRootURL: fixture.cloneRootURL,
        memory: .constrained,
        wait: { _ in }
    )

    #expect(configuredMemory == MacOSVirtualMachineLifecycle.constrainedMemoryBytes)
}

@Test
func virtualizationProbeCommandValidatesTheTemplateBeforeRunning() throws {
    let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "missing-yieldd-template-\(UUID().uuidString).bundle",
        isDirectory: true
    )
    var command = AgentVirtualizationProbeCommand()
    command.bundlePath = missingURL.path

    do {
        try command.validate()
        Issue.record("Expected template validation to fail")
    } catch let error as ValidationError {
        #expect(String(describing: error).contains(missingURL.path))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test(arguments: [
    "HardwareModel",
    "MachineIdentifier",
    "AuxiliaryStorage",
    "Disk.img",
    "SSHPrivateKey",
    "SSHKnownHosts",
])
func virtualizationProbeCommandRequiresEveryTemplateFile(_ filename: String) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let missingURL = fixture.templateURL.appendingPathComponent(filename)
    try FileManager.default.removeItem(at: missingURL)
    var command = AgentVirtualizationProbeCommand()
    command.bundlePath = fixture.templateURL.path

    do {
        try command.validate()
        Issue.record("Expected template validation to fail")
    } catch let error as ValidationError {
        #expect(String(describing: error).contains(missingURL.path))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func virtualizationProbeGuestReadinessFailureStillStopsAndDeletesTheClone() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    #expect(throws: TestFailure.create) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            waitUntilGuestReady: { _, _ in throw TestFailure.create }
        )
    }
    #expect(machine.stopCount == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func heldVirtualizationProbeChecksMachineStateBetweenReadinessAttempts() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    var attempts = 0
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    expectStoppedUnexpectedly {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            hold: true,
            waitUntilGuestReady: { macAddress, timeout in
                attempts += 1
                #expect(timeout == MacOSVirtualizationProbe.runDuration)
                if attempts == 2 {
                    machine.setState(.stopped)
                }
                throw MacOSGuestConnectionError.addressTimedOut(macAddress: macAddress)
            }
        )
    }
    #expect(attempts == 2)
    #expect(machine.stopCount == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func heldVirtualizationProbeChecksMachineStateAfterReadiness() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    var waits = 0
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    expectStoppedUnexpectedly {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            hold: true,
            wait: { interval in
                #expect(interval == MacOSVirtualizationProbe.runDuration)
                waits += 1
                machine.setState(.stopped)
            }
        )
    }
    #expect(waits == 1)
    #expect(machine.stopCount == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeDeletesCloneAfterMachineCreationFailure() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in throw TestFailure.create }
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
func virtualizationProbeDeletesCloneAfterStartFailure() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(startError: TestFailure.create)
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    #expect(throws: TestFailure.create) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL
        )
    }
    #expect(machine.stopCount == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeTimesOutBootAndDeletesClone() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(completesStart: false)
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    do {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            bootTimeout: 0.001
        )
        Issue.record("Expected VM startup to time out")
    } catch let MacOSVirtualizationProbeError.timedOut(operation) {
        #expect(operation == "starting the macOS virtual machine")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(machine.stopCount == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeDeletesCloneWhenBootAndStopTimeOut() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(
        stateAfterStart: .transitioning,
        completesStart: false,
        leavesTransitioningState: false
    )
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    do {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            bootTimeout: 0.001,
            stopTimeout: 0.001
        )
        Issue.record("Expected VM startup and cleanup to time out")
    } catch let MacOSVirtualizationProbeError.operationAndCleanupFailed(
        operation,
        cleanup
    ) {
        guard case MacOSVirtualizationProbeError.timedOut(let operationName) = operation
        else {
            Issue.record("Unexpected operation error: \(operation)")
            return
        }
        guard case MacOSVirtualizationProbeError.timedOut(let cleanupName) = cleanup
        else {
            Issue.record("Unexpected cleanup error: \(cleanup)")
            return
        }
        #expect(operationName == "starting the macOS virtual machine")
        #expect(cleanupName == "stopping the macOS virtual machine")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeReportsVirtualMachineError() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(stateAfterStart: .failed(TestFailure.runnerJob))
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    do {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            wait: { _ in }
        )
        Issue.record("Expected the VM error to fail the probe")
    } catch let MacOSVirtualizationProbeError.virtualMachineFailed(underlying) {
        #expect(underlying as? TestFailure == .runnerJob)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeRetriesStopAfterTransitioningState() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(stateAfterStart: .transitioning)
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    expectStoppedUnexpectedly {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            wait: { _ in }
        )
    }
    #expect(machine.stopCount == 2)
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeStopsAStoppableMachine() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(stateAfterStart: .stoppable)
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    expectStoppedUnexpectedly {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            wait: { _ in }
        )
    }
    #expect(machine.stopCount == 1)
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeForceStopsMachineAfterCancellation() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine()
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    #expect(throws: SignalInterruption(signal: SIGINT)) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            wait: { _ in throw SignalInterruption(signal: SIGINT) }
        )
    }
    #expect(machine.stopCount == 1)
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeFinishesForcedStopBeforeReportingCancellation() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let interruption = ProbeInterruption()
    let machine = ProbeVirtualMachine(
        onForceStop: interruption.record,
        completesStopAsynchronously: true
    )
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    #expect(throws: SignalInterruption(signal: SIGTERM)) {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            checkCancellation: interruption.check,
            wait: { _ in }
        )
    }
    #expect(machine.isStopped)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbeAcceptsAnAlreadyStoppedMachineDuringCleanup() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(stateAfterStart: .stopped)
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
    )

    do {
        try probe.run(
            templateURL: fixture.templateURL,
            cloneRootURL: fixture.cloneRootURL,
            wait: { _ in }
        )
        Issue.record("Expected the stopped machine to fail the probe")
    } catch MacOSVirtualizationProbeError.stoppedUnexpectedly {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(machine.stopCount == 1)
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualizationProbePreservesOperationAndCleanupFailures() throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let machine = ProbeVirtualMachine(stopError: TestFailure.cleanup)
    let probe = MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory,
        requireEntitlement: {}, loadStorage: { nil },
        makeMachine: { _, _ in machine }
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
    #expect(try fixture.cloneRootContents().isEmpty)
}

@Test
func virtualMachineCompletionReceivesCrossThreadResult() throws {
    let completion = VirtualMachineCompletion<Int>()
    DispatchQueue.global().async {
        completion.complete(.success(42))
    }

    #expect(
        try completion.wait(
            operation: "testing asynchronous completion",
            deadline: ProcessInfo.processInfo.systemUptime + 1,
            checkCancellation: {}
        ) == 42)
}

@Test
func virtualMachineCompletionTimesOut() throws {
    let completion = VirtualMachineCompletion<Void>()

    do {
        try completion.wait(
            operation: "testing timeout",
            deadline: ProcessInfo.processInfo.systemUptime + 0.001,
            checkCancellation: {}
        )
        Issue.record("Expected completion to time out")
    } catch let MacOSVirtualizationProbeError.timedOut(operation) {
        #expect(operation == "testing timeout")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func virtualizationProbeChecksTheRealEntitlementBeforeFileAccess() throws {
    let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "missing-yieldd-template-\(UUID().uuidString).bundle",
        isDirectory: true
    )

    do {
        try MacOSVirtualizationProbe(stateDirectory: unconfiguredContainerStateDirectory, ).run(
            templateURL: missingURL,
            cloneRootURL: missingURL.deletingLastPathComponent()
        )
        Issue.record("Expected the test process to lack the virtualization entitlement")
    } catch MacOSVirtualizationProbeError.missingEntitlement {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

struct ProbeBundleFixture {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "yieldd-macos-probe-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    let hardwareModel = Data("hardware".utf8)
    let machineIdentifier = Data("template-identifier".utf8)
    let auxiliaryStorage = Data("auxiliary".utf8)
    let disk = Data("disk".utf8)
    let privateKey = Data("private-key".utf8)
    let knownHosts = Data("known-host".utf8)

    var templateURL: URL {
        rootURL.appendingPathComponent("Template.bundle", isDirectory: true)
    }

    var cloneRootURL: URL {
        rootURL.appendingPathComponent("Clones", isDirectory: true)
    }

    var requiredFileURLs: [URL] {
        [
            "HardwareModel",
            "MachineIdentifier",
            "AuxiliaryStorage",
            "Disk.img",
            "SSHPrivateKey",
            "SSHKnownHosts",
        ]
            .map(templateURL.appendingPathComponent)
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
        let privateKeyURL = templateURL.appendingPathComponent("SSHPrivateKey")
        try privateKey.write(to: privateKeyURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )
        try knownHosts.write(to: templateURL.appendingPathComponent("SSHKnownHosts"))
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

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
}

private func expectStoppedUnexpectedly(_ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected the virtual machine to stop unexpectedly")
    } catch MacOSVirtualizationProbeError.stoppedUnexpectedly {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

final class ProbeVirtualMachine: @unchecked Sendable,
    MacOSVirtualMachineControlling
{
    private let lock = NSLock()
    private let stateAfterStart: MacOSVirtualMachineState
    private let onForceStop: () -> Void
    private let startError: (any Error)?
    private let stopError: (any Error)?
    private let completesStart: Bool
    private let completesStopAsynchronously: Bool
    private let leavesTransitioningState: Bool
    private var storedState: MacOSVirtualMachineState = .stopped
    private var starts = 0
    private var stops = 0

    init(
        stateAfterStart: MacOSVirtualMachineState = .running,
        onForceStop: @escaping () -> Void = {},
        startError: (any Error)? = nil,
        stopError: (any Error)? = nil,
        completesStart: Bool = true,
        completesStopAsynchronously: Bool = false,
        leavesTransitioningState: Bool = true
    ) {
        self.stateAfterStart = stateAfterStart
        self.onForceStop = onForceStop
        self.startError = startError
        self.stopError = stopError
        self.completesStart = completesStart
        self.completesStopAsynchronously = completesStopAsynchronously
        self.leavesTransitioningState = leavesTransitioningState
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

    var isStopped: Bool {
        lock.withLock {
            if case .stopped = storedState {
                return true
            }
            return false
        }
    }

    func setState(_ state: MacOSVirtualMachineState) {
        lock.withLock { storedState = state }
    }

    func start(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        lock.withLock {
            starts += 1
            if startError == nil {
                storedState = stateAfterStart
            }
        }
        guard completesStart else {
            return
        }
        if let startError {
            completion(.failure(startError))
        } else {
            completion(.success(()))
        }
    }

    func forceStop(
        completion:
            @escaping @Sendable (
                Result<MacOSVirtualMachineStopOutcome, any Error>
            ) -> Void
    ) {
        onForceStop()
        lock.withLock {
            stops += 1
        }
        guard completesStopAsynchronously else {
            completeStop(completion)
            return
        }
        DispatchQueue.global().async {
            self.completeStop(completion)
        }
    }

    private func completeStop(
        _ completion:
            @escaping @Sendable (
                Result<MacOSVirtualMachineStopOutcome, any Error>
            ) -> Void
    ) {
        if let stopError {
            completion(.failure(stopError))
            return
        }
        let outcome: Result<MacOSVirtualMachineStopOutcome, any Error> = lock.withLock {
            switch storedState {
            case .stopped:
                return .success(.stopped)
            case .running, .stoppable:
                storedState = .stopped
                return .success(.stopped)
            case .transitioning:
                if leavesTransitioningState {
                    storedState = .running
                }
                return .success(.retry)
            case .failed(let error):
                return .failure(error)
            }
        }
        completion(outcome)
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
