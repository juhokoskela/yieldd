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
        try withRunnerOwnership { leaseStore in
            let signalMonitor = try SignalMonitor(signals: [SIGINT, SIGTERM, SIGHUP])
            let executor = ProcessExecutor(checkCancellation: signalMonitor.check)
            let backend = try machine.makeBackend(
                leaseStore: leaseStore, signalMonitor: signalMonitor, executor: executor
            )
            if backend.platform == .macOS {
                if try leaseStore.load().isEmpty {
                    try MacOSRunnerCloneStore(stateDirectory: leaseStore.directory)
                        .removeUnleased(keeping: [], checkCancellation: signalMonitor.check)
                } else {
                    let locator = ExecutableLocator()
                    let recovery = RunnerRecovery(
                        linuxBackend: {
                            AppleContainerBackend(containerURL: try locator.locate("container"), executor: executor)
                        },
                        github: GitHubRunnerClient(ghURL: try locator.locate("gh"), executor: executor),
                        leaseStore: leaseStore,
                        recoveryWait: signalMonitor.wait,
                        checkCancellation: signalMonitor.check,
                        stateChanged: { reportRunnerRecoveryState($0) }
                    )
                    for id in try recovery.run() {
                        print("Cleaned up abandoned runner \(id.value).")
                    }
                }
            }
            let id = backend.platform.makeTestRunnerID()

            try MachineTestRunner(
                backend: backend,
                memoryAdmission: RunnerMemoryAdmission(reservationBytes: backend.platform.memoryReservationBytes),
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
