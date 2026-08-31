import ArgumentParser
import Darwin
import Foundation

struct RunnerTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runner-test",
        abstract: "Run one GitHub Actions job on a temporary runner machine."
    )

    @Argument(help: "Repository in owner/name form.")
    var repository: String

    @Option(name: .long, help: "Maximum number of minutes to wait for a job.")
    var timeout = 120

    mutating func validate() throws {
        guard timeout > 0 else {
            throw ValidationError("--timeout must be greater than zero.")
        }
    }

    mutating func run() throws {
        let repository = try GitHubRepository(repository)
        let locator = ExecutableLocator()
        let executor = ProcessExecutor()
        let backend = AppleContainerBackend(
            containerURL: try locator.locate("container"),
            executor: executor
        )
        let github = GitHubRunnerClient(
            ghURL: try locator.locate("gh"),
            executor: executor
        )
        let id = RunnerID(value: "yieldd-test-\(UUID().uuidString.lowercased())")

        print("Starting ephemeral runner \(id.value) for \(repository.fullName).")
        print("Waiting for one job labeled 'self-hosted' and 'yieldd'.")

        let interruptMonitor = try RunnerTestInterruptMonitor()
        try RunnerTestRunner(
            backend: backend,
            github: github,
            jobTimeout: TimeInterval(timeout) * 60,
            checkCancellation: interruptMonitor.check
        ).run(
            id: id,
            repository: repository
        )
        print("Runner job completed and cleanup passed.")
    }
}

struct RunnerTestRunner {
    static let image = MachineTestRunner.image
    static let configurationTimeout: TimeInterval = 5 * 60

    let backend: any RunnerBackend
    let github: any GitHubRunnerManaging
    private let jobTimeout: TimeInterval
    private let dockerReadiness: DockerReadiness
    private let checkCancellation: () throws -> Void

    init(
        backend: any RunnerBackend,
        github: any GitHubRunnerManaging,
        jobTimeout: TimeInterval = 120 * 60,
        dockerInfoAttempts: Int = 30,
        retryDelay: TimeInterval = 1,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        checkCancellation: @escaping () throws -> Void = {}
    ) {
        precondition(jobTimeout.isFinite && jobTimeout > 0)
        self.backend = backend
        self.github = github
        self.jobTimeout = jobTimeout
        self.checkCancellation = checkCancellation
        dockerReadiness = DockerReadiness(
            backend: backend,
            attempts: dockerInfoAttempts,
            retryDelay: retryDelay,
            sleep: sleep,
            checkCancellation: checkCancellation
        )
    }

    func run(
        id: RunnerID,
        repository: GitHubRepository
    ) throws {
        let registrationToken = try github.createRegistrationToken(for: repository)
        try checkCancellation()
        let operation: Result<Void, any Error>
        do {
            try backend.create(id: id, image: Self.image)
            try checkCancellation()
            _ = try dockerReadiness.wait(on: id)
            try checkCancellation()
            _ = try backend.exec(
                ["yieldd-configure-runner", repository.fullName, id.value],
                standardInput: Data("\(registrationToken)\n".utf8),
                timeout: Self.configurationTimeout,
                on: id
            )
            try checkCancellation()
            _ = try backend.exec(
                ["/opt/actions-runner/run.sh"],
                timeout: jobTimeout,
                on: id
            )
            operation = .success(())
        } catch {
            operation = .failure(error)
        }

        var cleanupFailures: [RunnerTestCleanupFailure] = []
        do {
            try github.removeRunners(named: id.value, from: repository)
        } catch {
            cleanupFailures.append(RunnerTestCleanupFailure(step: .githubRunner, error: error))
        }

        do {
            try backend.destroy(id)
        } catch {
            cleanupFailures.append(RunnerTestCleanupFailure(step: .machine, error: error))
        }

        switch operation {
        case .success where cleanupFailures.isEmpty:
            return
        case .success:
            throw RunnerTestError.cleanupFailed(cleanupFailures)
        case let .failure(error) where cleanupFailures.isEmpty:
            throw error
        case let .failure(error):
            throw RunnerTestError.operationAndCleanupFailed(
                operation: error,
                cleanup: cleanupFailures
            )
        }
    }
}

// The monitor clears this descriptor before closing it and restoring the previous handler.
nonisolated(unsafe) private var runnerTestInterruptWriteDescriptor: Int32 = -1

private func runnerTestInterruptHandler(_: Int32) {
    let savedError = errno
    defer { errno = savedError }

    let descriptor = runnerTestInterruptWriteDescriptor
    guard descriptor >= 0 else {
        return
    }

    var byte: UInt8 = 1
    _ = Darwin.write(descriptor, &byte, 1)
}

private final class RunnerTestInterruptMonitor {
    private let readDescriptor: Int32
    private let writeDescriptor: Int32
    private let previousHandler: sig_t
    private var interrupted = false

    init() throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw Self.posixError()
        }

        do {
            try Self.setNonBlocking(descriptors[0])
            try Self.setNonBlocking(descriptors[1])
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }

        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        runnerTestInterruptWriteDescriptor = writeDescriptor
        // A caught handler keeps yieldd alive and resets to the default when a child calls exec.
        previousHandler = signal(SIGINT, runnerTestInterruptHandler)
    }

    deinit {
        runnerTestInterruptWriteDescriptor = -1
        signal(SIGINT, previousHandler)
        Darwin.close(readDescriptor)
        Darwin.close(writeDescriptor)
    }

    func check() throws {
        if interrupted {
            throw RunnerTestError.interrupted
        }

        var byte: UInt8 = 0
        let bytesRead = Darwin.read(readDescriptor, &byte, 1)
        switch bytesRead {
        case 1:
            interrupted = true
            throw RunnerTestError.interrupted
        case -1 where errno == EAGAIN || errno == EWOULDBLOCK:
            return
        case 0:
            return
        default:
            throw Self.posixError()
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw posixError()
        }
    }

    private static func posixError() -> POSIXError {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return POSIXError(code)
    }
}

struct RunnerTestCleanupFailure {
    let step: RunnerTestCleanupStep
    let error: any Error
}

enum RunnerTestCleanupStep: String, Equatable {
    case githubRunner = "GitHub runner"
    case machine
}

enum RunnerTestError: Error {
    case interrupted
    case cleanupFailed([RunnerTestCleanupFailure])
    case operationAndCleanupFailed(operation: any Error, cleanup: [RunnerTestCleanupFailure])
}

extension RunnerTestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .interrupted:
            "Runner test interrupted."
        case let .cleanupFailed(cleanup):
            "Runner job completed, but cleanup failed: \(describe(cleanup))"
        case let .operationAndCleanupFailed(operation, cleanup):
            "Runner test failed: \(describe(operation)). Cleanup also failed: \(describe(cleanup))"
        }
    }

    private func describe(_ failures: [RunnerTestCleanupFailure]) -> String {
        failures.map { failure in
            "\(failure.step.rawValue): \(describe(failure.error))"
        }.joined(separator: "; ")
    }

    private func describe(_ error: any Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
