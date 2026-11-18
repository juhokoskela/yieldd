import ArgumentParser
import Dispatch
import Foundation
import Testing
@testable import Yieldd

private let firstPoolRepository = try! GitHubRepository("owner/first")
private let secondPoolRepository = try! GitHubRepository("owner/second")

@Test
func poolRunsConcurrentMixedPlatformSlots() throws {
    let gate = ConcurrentSlotGate(expected: 2)

    try RunnerPool(stop: RunnerPoolStop()).run(slots: [RunnerPlatform.linux, .macOS]) { platform, _ in
        try gate.enter(platform == .linux ? firstPoolRepository : secondPoolRepository)
    }

    #expect(Set(gate.repositories.map(\.fullName)) == [
        firstPoolRepository.fullName,
        secondPoolRepository.fullName,
    ])
    #expect(gate.maximumActiveSlots == 2)
}

@Test
func poolPreservesRepeatedRepositorySlots() throws {
    let gate = ConcurrentSlotGate(expected: 2)

    try RunnerPool(stop: RunnerPoolStop()).run(slots: [firstPoolRepository, firstPoolRepository]) { repository, _ in
        try gate.enter(repository)
    }

    #expect(gate.repositories == [firstPoolRepository, firstPoolRepository])
    #expect(gate.maximumActiveSlots == 2)
}

@Test
func poolFailureCancelsOtherSlotsAndPreservesTheFirstError() {
    let gate = ConcurrentSlotGate(expected: 2)
    let peerWasCancelled = LockedFlag()

    #expect(throws: TestFailure.runnerJob) {
        try RunnerPool(stop: RunnerPoolStop()).run(slots: [firstPoolRepository, secondPoolRepository]) { repository, stop in
            try gate.enter(repository)
            if repository == firstPoolRepository {
                throw TestFailure.runnerJob
            }
            do {
                try stop.wait(for: 5)
                throw RunnerPoolTestError.cancellationMissing
            } catch is CancellationError {
                peerWasCancelled.set()
            }
        }
    }

    #expect(peerWasCancelled.value)
}

@Test
func poolStopStartsOneShutdownDeadline() throws {
    let stop = RunnerPoolStop(shutdownTimeout: 1)
    #expect(stop.executionDeadline() == nil)

    stop.request()
    let deadline = try #require(stop.executionDeadline())
    stop.request()

    #expect(stop.executionDeadline() == deadline)
    #expect(throws: CancellationError.self) {
        try stop.check()
    }
}

@Test
func capacityWaitObservesPoolStop() throws {
    let blocked = DispatchSemaphore(value: 0)
    let cancelled = DispatchSemaphore(value: 0)
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
        readMemoryPressure: { .normal }
    )
    let reservation = try admission.acquire(reserving: RunnerPlatform.linux.memoryReservationBytes)
    let stop = RunnerPoolStop()

    DispatchQueue.global().async {
        do {
            _ = try admission.acquire(
                reserving: RunnerPlatform.linux.memoryReservationBytes,
                checkCancellation: stop.check,
                onBlocked: { blocked.signal() }
            )
            Issue.record("Stopped admission must not succeed")
        } catch is CancellationError {
            cancelled.signal()
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    #expect(blocked.wait(timeout: .now() + 1) == .success)
    stop.request()
    #expect(cancelled.wait(timeout: .now() + 1) == .success)
    admission.release(reservation)
}

private final class ConcurrentSlotGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let expected: Int
    private var recordedRepositories: [GitHubRepository] = []
    private var activeSlots = 0
    private var maximumSlots = 0

    init(expected: Int) {
        self.expected = expected
    }

    var repositories: [GitHubRepository] {
        condition.withLock { recordedRepositories }
    }

    var maximumActiveSlots: Int {
        condition.withLock { maximumSlots }
    }

    func enter(_ repository: GitHubRepository) throws {
        condition.lock()
        recordedRepositories.append(repository)
        activeSlots += 1
        maximumSlots = max(maximumSlots, activeSlots)
        if recordedRepositories.count == expected {
            condition.broadcast()
        }

        let deadline = Date(timeIntervalSinceNow: 1)
        while recordedRepositories.count < expected {
            guard condition.wait(until: deadline) else {
                activeSlots -= 1
                condition.unlock()
                throw RunnerPoolTestError.concurrentStartTimedOut
            }
        }
        activeSlots -= 1
        condition.unlock()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.withLock { storedValue }
    }

    func set() {
        lock.withLock { storedValue = true }
    }
}

private enum RunnerPoolTestError: Error {
    case cancellationMissing
    case concurrentStartTimedOut
}
