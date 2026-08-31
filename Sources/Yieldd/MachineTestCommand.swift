import ArgumentParser
import Foundation

struct MachineTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machine-test",
        abstract: "Run a temporary Docker-in-machine integration test."
    )

    mutating func run() throws {
        let containerURL = try ExecutableLocator().locate("container")
        let backend = AppleContainerBackend(
            containerURL: containerURL,
            executor: ProcessExecutor()
        )
        let id = RunnerID(value: "yieldd-test-\(UUID().uuidString.lowercased())")

        _ = try MachineTestRunner(backend: backend).run(id: id)
        print("Machine test passed.")
    }
}

struct MachineTestRunner {
    static let image = "local/yieldd-guest:dev"

    let backend: any RunnerBackend
    private let dockerInfoAttempts: Int
    private let retryDelay: TimeInterval
    private let sleep: (TimeInterval) -> Void

    init(
        backend: any RunnerBackend,
        dockerInfoAttempts: Int = 30,
        retryDelay: TimeInterval = 1,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) {
        precondition(dockerInfoAttempts > 0)
        self.backend = backend
        self.dockerInfoAttempts = dockerInfoAttempts
        self.retryDelay = retryDelay
        self.sleep = sleep
    }

    func run(id: RunnerID) throws -> MachineTestResult {
        let operation: Result<MachineTestResult, any Error>
        do {
            try backend.create(id: id, image: Self.image)
            let dockerInfo = try DockerReadiness(
                backend: backend,
                attempts: dockerInfoAttempts,
                retryDelay: retryDelay,
                sleep: sleep
            ).wait(on: id)
            let helloWorld = try backend.exec(
                ["docker", "run", "--rm", "hello-world"],
                on: id
            )
            operation = .success(MachineTestResult(
                dockerInfo: dockerInfo,
                helloWorld: helloWorld
            ))
        } catch {
            operation = .failure(error)
        }

        let cleanup: Result<Void, any Error>
        do {
            try backend.destroy(id)
            cleanup = .success(())
        } catch {
            cleanup = .failure(error)
        }

        switch (operation, cleanup) {
        case let (.success(result), .success):
            return result
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

struct MachineTestResult: Equatable {
    let dockerInfo: ProcessResult
    let helloWorld: ProcessResult
}

enum MachineTestError: Error {
    case operationAndCleanupFailed(operation: any Error, cleanup: any Error)
}

extension MachineTestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .operationAndCleanupFailed(operation, cleanup):
            "Machine test failed: \(describe(operation)). Cleanup also failed: \(describe(cleanup))"
        }
    }

    private func describe(_ error: any Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
