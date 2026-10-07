import Foundation
import Testing
@testable import Yieldd

private let linuxNetworkID = RunnerID(value: "yieldd-network-test")
private let linuxContainer = URL(fileURLWithPath: "/test/container")

@Suite
struct LinuxRunnerNetworkTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YIELDD_TEST_RELAY"] != nil))
    func linuxBackendUsesAndStopsTheRealRelayWithoutBootingAVM() throws {
        let executable = try #require(ProcessInfo.processInfo.environment["YIELDD_TEST_RELAY"])
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let executor = RelayLinuxExecutor()
        let backend = try AppleContainerBackend(containerURL: linuxContainer, executor: executor,
            stateDirectory: fixture.directory, loadStorage: { nil },
            network: try RunnerNetwork(stateDirectory: fixture.directory, executableURL: URL(fileURLWithPath: executable)))
        defer { try? backend.destroy(linuxNetworkID) }
        try backend.create(id: linuxNetworkID, memory: .full)
        let socket = try #require(executor.socket)
        #expect(FileManager.default.fileExists(atPath: socket))
        #expect(executor.commands.first?.contains("--no-boot") == true)
        try backend.exec(["true"], on: linuxNetworkID)
        try backend.destroy(linuxNetworkID)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: socket).deletingLastPathComponent().path))
    }

    private final class RelayLinuxExecutor: ProcessExecuting {
        var commands: [[String]] = []
        var socket: String?
        func execute(_ request: ProcessRequest) throws -> ProcessResult {
            commands.append(request.arguments)
            if request.arguments.starts(with: ["machine", "create"]), let index = request.arguments.firstIndex(of: "--network-socket") {
                socket = request.arguments[index + 1]
            }
            if request.arguments.starts(with: ["machine", "inspect"]) {
                let payload = [["id": linuxNetworkID.value, "homeMount": "none", "networkSocket": try #require(socket)]]
                return ProcessResult(stdout: try JSONSerialization.data(withJSONObject: payload), stderr: Data(), terminationReason: .exit, terminationStatus: 0)
            }
            if request.arguments.starts(with: ["machine", "list"]) { return processResult(stdout: linuxNetworkID.value) }
            return processResult()
        }
    }

    @Test(arguments: ["", "machine create --home-mount <homeMount>"])
    func linuxPreflightRejectsTheStockContainerCLI(_ help: String) {
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult(stdout: help))])
        #expect(throws: AppleContainerBackendError.self) {
            try AppleContainerBackend.requireNetworkSupport(containerURL: linuxContainer, executor: executor)
        }
    }

    @Test(arguments: ["[]", "{}", "[{\"id\":\"yieldd-network-test\",\"homeMount\":\"none\"}]",
                      "[{\"id\":\"yieldd-network-test\",\"homeMount\":\"rw\",\"networkSocket\":\"/unused/network.sock\"}]",
                      "[{\"id\":\"yieldd-network-test\",\"homeMount\":\"none\",\"networkSocket\":\"/private/other/n\"}]",
                      "[{\"id\":\"another-machine\",\"homeMount\":\"none\",\"networkSocket\":\"/unused/network.sock\"}]"])
    func linuxRejectsUnverifiedNetworkBeforeBoot(_ inspection: String) throws {
        let relay = BackendRelay()
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult()), .success(processResult(stdout: inspection)),
                                                          .success(processResult(stdout: linuxNetworkID.value)), .success(processResult())])
        let backend = try AppleContainerBackend(containerURL: linuxContainer, executor: executor,
            stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil }, network: BackendNetwork(relay: relay))
        var recorded = false
        #expect(throws: AppleContainerBackendError.self) {
            try backend.create(id: linuxNetworkID, memory: .full, recordIntent: { recorded = true })
        }
        #expect(recorded)
        #expect(executor.requests.first?.arguments.contains("--no-boot") == true)
        #expect(!executor.requests.contains { $0.arguments.starts(with: ["machine", "run"]) })
        try backend.destroy(linuxNetworkID)
        #expect(!relay.isRunning)
        #expect(executor.requests.last?.arguments == ["machine", "delete", linuxNetworkID.value])
    }

    @Test
    func linuxRelayFailurePreventsGuestCommands() throws {
        let relay = BackendRelay()
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult()), .success(linuxInspection(id: linuxNetworkID)), .success(processResult()),
                                                          .success(processResult()), .success(processResult())])
        let backend = try AppleContainerBackend(containerURL: linuxContainer, executor: executor,
            stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil }, network: BackendNetwork(relay: relay))
        try backend.create(id: linuxNetworkID, memory: .full)
        relay.failure = RunnerNetworkRelayError.exited(status: 9)
        executor.clearRequests()
        let error = try #require(#expect(throws: RunnerNetworkRelayError.self) { try backend.exec(["true"], on: linuxNetworkID) })
        #expect(!isCancellation(error))
        #expect(executor.requests.isEmpty)
    }

    @Test
    func linuxStorageFailureCutsTheRelayWithoutTargetingAnotherContainerRoot() throws {
        let relay = BackendRelay()
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult()), .success(linuxInspection(id: linuxNetworkID)), .success(processResult()),
                                                          .success(processResult()), .success(processResult())])
        var storageMissing = false
        let backend = try AppleContainerBackend(containerURL: linuxContainer, executor: executor,
            stateDirectory: unconfiguredContainerStateDirectory, loadStorage: {
                if storageMissing { throw RunnerStorageError.notConfigured }
                return nil
            }, network: BackendNetwork(relay: relay))
        try backend.create(id: linuxNetworkID, memory: .full)
        storageMissing = true
        executor.clearRequests()
        #expect(throws: RunnerStorageError.notConfigured) { try backend.destroy(linuxNetworkID) }
        #expect(!relay.isRunning)
        #expect(executor.requests.isEmpty)
    }

    @Test
    func linuxCleanupAttemptsMachineDeletionAfterRelayStopFailureAndCanRetry() throws {
        let relay = BackendRelay()
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult()), .success(linuxInspection(id: linuxNetworkID)), .success(processResult()),
            .success(processResult()), .success(processResult()), .success(processResult(stdout: linuxNetworkID.value)),
            .success(processResult()), .success(processResult())])
        let deadline = DispatchTime.now() + 1
        let backend = try AppleContainerBackend(containerURL: linuxContainer, executor: executor,
            stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil }, network: BackendNetwork(relay: relay),
            maximumExecutionDeadline: { deadline })
        try backend.create(id: linuxNetworkID, memory: .full)
        relay.stopFailure = TestFailure.cleanup
        let failure = try #require(#expect(throws: RunnerSessionError.self) { try backend.destroy(linuxNetworkID) })
        guard case let .cleanupFailed(entries) = failure else { Issue.record("Expected network cleanup failure"); return }
        #expect(entries.count == 1 && entries[0].step == .network)
        #expect(executor.requests.last?.arguments == ["machine", "delete", linuxNetworkID.value])
        #expect(relay.stopDeadline == deadline)
        relay.stopFailure = nil
        try backend.destroy(linuxNetworkID)
        #expect(!relay.isRunning)
    }

    @Test
    func linuxRecoveryRemovesTheCrashedOwnersSocketDirectory() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let directories = try RunnerNetworkDirectories(stateDirectory: fixture.directory)
        let socketDirectory = try directories.create(for: linuxNetworkID)
        defer { try? directories.remove(linuxNetworkID) }
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
        let backend = try AppleContainerBackend(containerURL: linuxContainer, executor: executor,
            stateDirectory: fixture.directory, loadStorage: { nil })
        try backend.destroy(linuxNetworkID)
        #expect(!FileManager.default.fileExists(atPath: socketDirectory.path))
    }

    @Test
    func recoveryDoesNotBootAnUnownedGuestOrRequireTheFork() throws {
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult(stdout: linuxNetworkID.value)), .success(processResult())])
        let backend = try makeLinuxBackend(containerURL: linuxContainer, executor: executor)
        try backend.stopRunner(on: linuxNetworkID)
        #expect(executor.requests.isEmpty)
        try backend.destroy(linuxNetworkID)
        #expect(executor.requests.map(\.arguments) == [
            ["machine", "list", "--quiet"], ["machine", "delete", linuxNetworkID.value],
        ])
    }

    @Test
    func failedHeadlessBootDoesNotRunGuestReadinessOrStopTheListener() throws {
        let executor = RecordingProcessExecutor(outcomes: [
            .success(processResult()), .success(linuxInspection(id: linuxNetworkID)),
            .failure(TestFailure.create), .success(processResult(stdout: linuxNetworkID.value)), .success(processResult()),
        ])
        let backend = try makeLinuxBackend(containerURL: linuxContainer, executor: executor)
        #expect(throws: TestFailure.create) { try backend.create(id: linuxNetworkID, memory: .full) }
        try backend.stopRunner(on: linuxNetworkID)
        #expect(executor.requests.last?.arguments == ["machine", "boot", linuxNetworkID.value])
        #expect(executor.requests.last?.timeout == AppleContainerBackend.creationTimeout)
        try backend.destroy(linuxNetworkID)
        #expect(!executor.requests.contains { $0.arguments.starts(with: ["machine", "run"]) })
    }

    @Test
    func forkPreflightChecksCreationAndHeadlessBootExactlyOnce() throws {
        let executor = RecordingProcessExecutor(outcomes: [.success(processResult(stdout: "--network-socket")), .success(processResult())])
        try AppleContainerBackend.requireNetworkSupport(containerURL: linuxContainer, executor: executor)
        #expect(executor.requests.map(\.arguments) == [
            ["machine", "create", "--help"], ["machine", "boot", "--help"],
        ])
        #expect(executor.requests.allSatisfy { $0.timeout == AppleContainerBackend.preflightTimeout })
    }
}
