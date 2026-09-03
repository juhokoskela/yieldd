import ArgumentParser
import Foundation

struct MachineTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machine-test",
        abstract: "Run a temporary Docker-in-machine integration test."
    )

    mutating func run() throws {
        try withRunnerOwnership { _ in
            let signalMonitor = try SignalMonitor()
            let containerURL = try ExecutableLocator().locate("container")
            let backend = AppleContainerBackend(
                containerURL: containerURL,
                executor: ProcessExecutor(checkCancellation: signalMonitor.check),
                dockerReadiness: DockerReadiness(
                    wait: signalMonitor.wait,
                    checkCancellation: signalMonitor.check
                )
            )
            let id = RunnerID(value: "yieldd-test-\(UUID().uuidString.lowercased())")

            try MachineTestRunner(
                backend: backend,
                memoryAdmission: RunnerMemoryAdmission(),
                checkCancellation: signalMonitor.check,
                waitingForMemory: {
                    print("Machine test is waiting for available host memory.")
                }
            ).run(id: id)
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

    func run(id: RunnerID) throws {
        let reservation = try memoryAdmission.acquire(
            checkCancellation: checkCancellation,
            onBlocked: waitingForMemory
        )
        var machineMayExist = false
        let operation = Result<Void, any Error> {
            try checkCancellation()
            machineMayExist = true
            try backend.create(id: id, memory: reservation.allocation)
            try checkCancellation()
            try backend.exec(
                ["docker", "run", "--rm", "hello-world"],
                timeout: Self.helloWorldTimeout,
                on: id
            )
        }

        let cleanup = machineMayExist
            ? Result<Void, any Error> { try backend.destroy(id) }
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

enum MachineTestError: Error {
    case operationAndCleanupFailed(operation: any Error, cleanup: any Error)
}

extension MachineTestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .operationAndCleanupFailed(operation, cleanup):
            "Machine test failed: \(describeError(operation)). Cleanup also failed: \(describeError(cleanup))"
        }
    }
}
