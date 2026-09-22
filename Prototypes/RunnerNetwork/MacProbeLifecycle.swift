import Foundation
import Virtualization

@MainActor
struct MacProbeLifecycle {
    let start: (@escaping (Result<Void, any Error>) -> Void) -> Void
    let state: () -> VZVirtualMachine.State
    let canStop: () -> Bool
    let stop: (@escaping ((any Error)?) -> Void) -> Void
    var now: () -> ContinuousClock.Instant = { .now }
    var wait: () async -> Void = {
        // Cleanup must still yield when the caller's task has been cancelled.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
        }
    }

    func run(checkCancellation: () throws -> Void, started: () -> Void) async throws {
        let deadline = now().advanced(by: .seconds(120))
        func check() throws {
            try Task.checkCancellation()
            try checkCancellation()
        }
        var operationError: (any Error)?
        do {
            try check()
            let completion = Completion()
            start { completion.result = $0 }
            try await awaitCompletion(completion, until: deadline, timeout: .startupTimedOut, check: check)
            started()
            while state() == .running && now() < deadline {
                try check()
                await wait()
            }
            try check()
        } catch {
            operationError = error
        }
        do {
            try await stopMachine()
        } catch {
            if let operationError {
                throw MacProbeLifecycleError.operationAndCleanupFailed(operation: operationError, cleanup: error)
            }
            throw error
        }
        if let operationError { throw operationError }
        if state() == .error { throw MacProbeLifecycleError.virtualMachineFailed }
    }

    private var isStopped: Bool { state() == .stopped || state() == .error }

    private func stopMachine() async throws {
        let deadline = now().advanced(by: .seconds(15))
        while !isStopped {
            guard now() < deadline else { throw MacProbeLifecycleError.stopTimedOut }
            guard canStop() else {
                await wait()
                continue
            }
            let completion = Completion()
            stop { error in
                completion.result = error.map { .failure($0) } ?? .success(())
            }
            do {
                try await awaitCompletion(completion, until: deadline, timeout: .stopTimedOut, check: {})
            } catch {
                if !isStopped { throw error }
            }
        }
    }

    private func awaitCompletion(
        _ completion: Completion,
        until deadline: ContinuousClock.Instant,
        timeout: MacProbeLifecycleError,
        check: () throws -> Void
    ) async throws {
        while true {
            try check()
            guard now() < deadline else { throw timeout }
            if let result = completion.result { return try result.get() }
            await wait()
        }
    }

    // VZ callbacks and polling share the VM's main queue. A late callback only
    // updates this box; timeout/cancellation never waits for that callback.
    private final class Completion {
        var result: Result<Void, any Error>?
    }
}

enum MacProbeLifecycleError: Error, LocalizedError {
    case virtualMachineFailed
    case startupTimedOut
    case stopTimedOut
    case operationAndCleanupFailed(operation: any Error, cleanup: any Error)

    var errorDescription: String? {
        switch self {
        case .virtualMachineFailed: "The prototype VM entered an error state."
        case .startupTimedOut: "The prototype VM did not start within its two-minute budget."
        case .stopTimedOut: "The prototype VM did not stop within 15 seconds. Its clone was retained."
        case let .operationAndCleanupFailed(operation, cleanup):
            "Prototype VM failed: \(operation.localizedDescription). Cleanup also failed: \(cleanup.localizedDescription)"
        }
    }
}
