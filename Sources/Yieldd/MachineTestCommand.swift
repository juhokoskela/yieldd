import ArgumentParser
import Foundation

struct MachineTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machine-test",
        abstract: "Run a temporary Docker-in-machine integration test."
    )

    mutating func run() throws {
        let signalMonitor = try SignalMonitor()
        let containerURL = try ExecutableLocator().locate("container")
        let backend = AppleContainerBackend(
            containerURL: containerURL,
            executor: ProcessExecutor(checkCancellation: signalMonitor.check),
            wait: signalMonitor.wait,
            checkCancellation: signalMonitor.check
        )
        let id = RunnerID(value: "yieldd-test-\(UUID().uuidString.lowercased())")

        try MachineTestRunner(
            backend: backend,
            checkCancellation: signalMonitor.check
        ).run(id: id)
        print("Machine test passed.")
    }
}

struct MachineTestRunner {
    static let helloWorldTimeout: TimeInterval = 2 * 60

    let backend: any RunnerBackend
    private let checkCancellation: () throws -> Void

    init(
        backend: any RunnerBackend,
        checkCancellation: @escaping () throws -> Void = {}
    ) {
        self.backend = backend
        self.checkCancellation = checkCancellation
    }

    func run(id: RunnerID) throws {
        let operation = Result<Void, any Error> {
            try checkCancellation()
            try backend.create(id: id, memory: .constrained)
            try checkCancellation()
            _ = try backend.exec(
                ["docker", "run", "--rm", "hello-world"],
                timeout: Self.helloWorldTimeout,
                on: id
            )
        }

        let cleanup = Result<Void, any Error> {
            try backend.destroy(id)
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
