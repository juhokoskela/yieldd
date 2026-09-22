import Foundation
import Testing
import Virtualization

@MainActor
struct MacProbeLifecycleTests {
    @Test func missingStartupCallbackTimesOutAndStopsTheVM() async throws {
        let machine = ProbeMachine()
        machine.onWait = { $0.state = .running }
        do {
            try await machine.run()
            Issue.record("Accepted startup without its callback")
        } catch MacProbeLifecycleError.startupTimedOut {}
        #expect(machine.elapsed == .seconds(120))
        #expect(machine.stopCount == 1)
        #expect(machine.state == .stopped)
        #expect(!machine.reportedStarted)
    }

    @Test(arguments: [false, true])
    func interruptionDuringStartupStopsWithoutWaitingForTheCallback(relayFailure: Bool) async throws {
        let machine = ProbeMachine()
        machine.onWait = { $0.state = .running }
        do {
            try await machine.run(check: {
                if machine.elapsed > .zero {
                    if relayFailure { throw ProbeFailure.relay }
                    throw CancellationError()
                }
            })
            Issue.record("Ignored interruption during startup")
        } catch is CancellationError {
            #expect(!relayFailure)
        } catch ProbeFailure.relay {
            #expect(relayFailure)
        }
        #expect(machine.elapsed == .seconds(1))
        #expect(machine.stopCount == 1)
        #expect(machine.state == .stopped)
        #expect(!machine.reportedStarted)
    }

    @Test func interruptionBeforeStartupDoesNotStartTheVM() async throws {
        let machine = ProbeMachine()
        do {
            try await machine.run(check: { throw CancellationError() })
            Issue.record("Ignored interruption before startup")
        } catch is CancellationError {}
        #expect(machine.startCount == 0)
        #expect(machine.stopCount == 0)
        #expect(machine.elapsed == .zero)
    }

    @Test func permanentlyStartingVMHasBoundedCleanup() async throws {
        let machine = ProbeMachine()
        do {
            try await machine.run()
            Issue.record("Accepted a permanently starting VM")
        } catch let MacProbeLifecycleError.operationAndCleanupFailed(operation, cleanup) {
            guard case MacProbeLifecycleError.startupTimedOut = operation,
                  case MacProbeLifecycleError.stopTimedOut = cleanup else {
                Issue.record("Lost startup or cleanup timeout: \(operation), \(cleanup)")
                return
            }
        }
        #expect(machine.elapsed == .seconds(135))
        #expect(machine.state == .starting)
        #expect(machine.stopCount == 0)
    }

    @Test func lateStartupAfterInterruptionIsStillStopped() async throws {
        let machine = ProbeMachine()
        machine.onWait = {
            if $0.elapsed == .seconds(2) { $0.finishStart(.success(())) }
        }
        do {
            try await machine.run(check: {
                if machine.elapsed > .zero { throw CancellationError() }
            })
            Issue.record("Ignored interruption while waiting for startup")
        } catch is CancellationError {}
        #expect(machine.elapsed == .seconds(2))
        #expect(machine.stopCount == 1)
        #expect(machine.state == .stopped)
        #expect(!machine.reportedStarted)
    }

    @Test func startupConsumesTheRuntimeBudget() async throws {
        let machine = ProbeMachine()
        machine.onWait = {
            if $0.elapsed == .seconds(30) { $0.finishStart(.success(())) }
        }
        try await machine.run()
        #expect(machine.elapsed == .seconds(120))
        #expect(machine.reportedStarted)
        #expect(machine.stopCount == 1)
        #expect(machine.state == .stopped)
    }

    @Test func missingStopCallbackTimesOut() async throws {
        let machine = ProbeMachine()
        machine.onStart = { $0.finishStart(.success(())) }
        machine.onStop = { _, _ in }
        do {
            try await machine.run()
            Issue.record("Accepted shutdown without its callback")
        } catch MacProbeLifecycleError.stopTimedOut {}
        #expect(machine.elapsed == .seconds(135))
        #expect(machine.stopCount == 1)
        #expect(machine.state == .stopping)
    }

    @Test func startupAndStopFailuresArePreserved() async throws {
        let machine = ProbeMachine()
        machine.onStart = {
            $0.state = .running
            $0.startCompletion?(.failure(ProbeFailure.start))
        }
        machine.onStop = { _, completion in completion(ProbeFailure.stop) }
        do {
            try await machine.run()
            Issue.record("Accepted failed startup and shutdown")
        } catch let MacProbeLifecycleError.operationAndCleanupFailed(operation, cleanup) {
            #expect(operation as? ProbeFailure == .start)
            #expect(cleanup as? ProbeFailure == .stop)
        }
        #expect(machine.elapsed == .zero)
        #expect(machine.stopCount == 1)
        #expect(!machine.reportedStarted)
    }

    @Test func terminalFailureDoesNotRequireStopping() async throws {
        let machine = ProbeMachine()
        machine.onStart = { $0.finishStart(.failure(ProbeFailure.start)) }
        do {
            try await machine.run()
            Issue.record("Accepted failed startup")
        } catch ProbeFailure.start {}
        #expect(machine.stopCount == 0)
        #expect(machine.state == .error)
    }
}

private enum ProbeFailure: Error { case start, stop, relay }

@MainActor
private final class ProbeMachine {
    var state = VZVirtualMachine.State.stopped
    let origin = ContinuousClock.now
    var elapsed = Duration.zero
    var startCount = 0
    var stopCount = 0
    var reportedStarted = false
    var startCompletion: ((Result<Void, any Error>) -> Void)?
    var onStart: (ProbeMachine) -> Void = { _ in }
    var onWait: (ProbeMachine) -> Void = { _ in }
    var onStop: (ProbeMachine, ((any Error)?) -> Void) -> Void = { machine, completion in
        machine.state = .stopped
        completion(nil)
    }

    func finishStart(_ result: Result<Void, any Error>) {
        switch result {
        case .success: state = .running
        case .failure: state = .error
        }
        startCompletion?(result)
    }

    func run(check: () throws -> Void = {}) async throws {
        let lifecycle = MacProbeLifecycle(
            start: {
                self.startCount += 1
                self.state = .starting
                self.startCompletion = $0
                self.onStart(self)
            },
            state: { self.state },
            canStop: { self.state == .running },
            stop: {
                self.stopCount += 1
                self.state = .stopping
                self.onStop(self, $0)
            },
            now: { self.origin.advanced(by: self.elapsed) },
            wait: {
                self.elapsed += .seconds(1)
                self.onWait(self)
            }
        )
        try await lifecycle.run(checkCancellation: check, started: { self.reportedStarted = true })
    }
}
