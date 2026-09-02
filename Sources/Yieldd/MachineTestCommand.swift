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
            executor: ProcessExecutor(checkCancellation: signalMonitor.check)
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
    static let image = "local/yieldd-guest:dev"
    static let helloWorldTimeout: TimeInterval = 2 * 60

    let backend: any RunnerBackend
    private let dockerInfoAttempts: Int
    private let retryDelay: TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let checkCancellation: () throws -> Void

    init(
        backend: any RunnerBackend,
        dockerInfoAttempts: Int = 30,
        retryDelay: TimeInterval = 1,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        checkCancellation: @escaping () throws -> Void = {}
    ) {
        precondition(dockerInfoAttempts > 0)
        self.backend = backend
        self.dockerInfoAttempts = dockerInfoAttempts
        self.retryDelay = retryDelay
        self.sleep = sleep
        self.checkCancellation = checkCancellation
    }

    func run(id: RunnerID) throws {
        let operation = Result<Void, any Error> {
            try checkCancellation()
            try backend.create(id: id, image: Self.image)
            try checkCancellation()
            try DockerReadiness(
                backend: backend,
                attempts: dockerInfoAttempts,
                retryDelay: retryDelay,
                sleep: sleep,
                checkCancellation: checkCancellation
            ).wait(on: id)
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
