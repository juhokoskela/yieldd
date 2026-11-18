import ArgumentParser
import Foundation

struct MachineTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machine-test",
        abstract: "Validate a temporary Linux machine or macOS template clone."
    )

    @OptionGroup
    var machine: RunnerMachineOptions

    mutating func run() throws {
        try withRunnerOwnership(recoveringMachineTest: true) { leaseStore in
            let signalMonitor = try SignalMonitor()
            let executor = ProcessExecutor(checkCancellation: signalMonitor.check)
            let backend = try machine.makeBackend(
                leaseStore: leaseStore, executor: executor,
                checkCancellation: signalMonitor.check, wait: signalMonitor.wait
            )
            if backend.platform == .macOS {
                let locator = ExecutableLocator()
                try leaseStore.recoverMachineTest {
                    try AppleContainerBackend(containerURL: locator.locate("container"), executor: executor, stateDirectory: leaseStore.directory)
                }
                try removeUnleasedRunnerFiles(in: leaseStore.directory, keeping: [], checkCancellation: signalMonitor.check)
            } else {
                try leaseStore.recoverMachineTest { backend }
            }
            let id = backend.platform.makeTestRunnerID()

            try MachineTestRunner(
                backend: backend,
                memoryAdmission: RunnerMemoryAdmission(),
                checkCancellation: signalMonitor.check,
                waitingForMemory: {
                    print("Machine test is waiting for available host memory.")
                }
            ).run(id: id, journal: backend.platform == .linux ? leaseStore : nil)
            print("Machine test passed.")
        }
    }
}

struct MachineTestRunner {
    static let helloWorldTimeout: TimeInterval = 2 * 60

    let backend: any RunnerBackend
    private let memoryAdmission: RunnerMemoryAdmission
    private let checkCancellation: () throws -> Void
    private let waitingForMemory: () -> Void

    init(
        backend: any RunnerBackend,
        memoryAdmission: RunnerMemoryAdmission,
        checkCancellation: @escaping () throws -> Void = {},
        waitingForMemory: @escaping () -> Void = {}
    ) {
        self.backend = backend
        self.memoryAdmission = memoryAdmission
        self.checkCancellation = checkCancellation
        self.waitingForMemory = waitingForMemory
    }

    func run(id: RunnerID, journal: RunnerLeaseStore? = nil) throws {
        let reservation = try memoryAdmission.acquire(
            reserving: backend.platform.memoryReservationBytes,
            checkCancellation: checkCancellation,
            onBlocked: waitingForMemory
        )
        var machineMayExist = false
        let operation = Result<Void, any Error> {
            try checkCancellation()
            try backend.create(id: id, memory: reservation.allocation) {
                try journal?.recordMachineTest(id)
                machineMayExist = true
            }
            try checkCancellation()
            try RunnerGuestProtocol.validate(backend: backend, id: id)
            switch backend.platform {
            case .linux:
                try backend.exec(
                    ["docker", "run", "--rm", "hello-world"],
                    timeout: Self.helloWorldTimeout,
                    on: id
                )
            case .macOS:
                try MacOSTemplateValidation.run(backend: backend, id: id)
            }
        }

        let cleanup = machineMayExist
            ? Result<Void, any Error> {
                try backend.destroy(id)
                try journal?.clearMachineTest()
            }
            : .success(())
        if case .success = cleanup {
            memoryAdmission.release(reservation)
        }

        switch (operation, cleanup) {
        case (.success, .success):
            return
        case let (.failure(operationError), .success):
            throw operationError
        case let (.success, .failure(cleanupError)):
            throw cleanupError
        case let (.failure(operationError), .failure(cleanupError)):
            throw MachineTestError.operationAndCleanupFailed(
                operation: operationError,
                cleanup: cleanupError
            )
        }
    }
}

extension RunnerLeaseStore {
    private var machineTestFile: URL { directory.appendingPathComponent("linux-machine-test") }

    func recordMachineTest(_ id: RunnerID) throws {
        try writePrivateRunnerFile(Data(id.value.utf8), to: machineTestFile)
    }

    func pendingMachineTest() throws -> RunnerID? {
        guard let data = try readPrivateRunnerFile(machineTestFile, maximumBytes: 128) else { return nil }
        let name = String(decoding: data, as: UTF8.self)
        let prefix = "yieldd-test-"
        guard let uuid = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + uuid.uuidString.lowercased() else {
            throw RunnerLeaseError.invalidRunnerID(path: machineTestFile.path)
        }
        return RunnerID(value: name)
    }

    func recoverMachineTest(makeBackend: () throws -> any RunnerBackend) throws {
        guard let id = try pendingMachineTest() else { return }
        let backend = try makeBackend()
        try backend.prepare()
        try backend.destroy(id)
        try clearMachineTest()
    }

    func clearMachineTest() throws {
        try FileManager.default.removeItem(at: machineTestFile)
        try synchronizeRunnerState(directory)
    }
}

enum MachineTestError: Error {
    case recoveryRequired
    case operationAndCleanupFailed(operation: any Error, cleanup: any Error)
}

extension MachineTestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .recoveryRequired:
            "A Linux machine test needs cleanup. Run yieldd recover before changing storage or starting runners."
        case let .operationAndCleanupFailed(operation, cleanup):
            "Machine test failed: \(describeError(operation)). Cleanup also failed: \(describeError(cleanup))"
        }
    }
}
