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

    try RunnerPool(stop: RunnerPoolStop()) { slot, _ in
        #expect(slot.platform == (slot.repository == firstPoolRepository ? .linux : .macOS))
        try gate.enter(slot.repository)
    }.run(slots: [
        RunnerSlot(repository: firstPoolRepository, platform: .linux),
        RunnerSlot(repository: secondPoolRepository, platform: .macOS),
    ])

    #expect(Set(gate.repositories.map(\.fullName)) == [
        firstPoolRepository.fullName,
        secondPoolRepository.fullName,
    ])
    #expect(gate.maximumActiveSlots == 2)
}

@Test
func poolPreservesRepeatedRepositorySlots() throws {
    let gate = ConcurrentSlotGate(expected: 2)

    try RunnerPool(stop: RunnerPoolStop()) { slot, _ in
        try gate.enter(slot.repository)
    }.run(slots: [firstPoolRepository, firstPoolRepository].map { RunnerSlot(repository: $0, platform: .linux) })

    #expect(gate.repositories == [firstPoolRepository, firstPoolRepository])
    #expect(gate.maximumActiveSlots == 2)
}

@Test
func poolFailureCancelsOtherSlotsAndPreservesTheFirstError() {
    let gate = ConcurrentSlotGate(expected: 2)
    let peerWasCancelled = LockedFlag()

    #expect(throws: TestFailure.runnerJob) {
        try RunnerPool(stop: RunnerPoolStop()) { slot, stop in
            try gate.enter(slot.repository)
            if slot.repository == firstPoolRepository {
                throw TestFailure.runnerJob
            }
            do {
                try stop.wait(for: 5)
                throw RunnerPoolTestError.cancellationMissing
            } catch is CancellationError {
                peerWasCancelled.set()
            }
        }.run(slots: [firstPoolRepository, secondPoolRepository].map { RunnerSlot(repository: $0, platform: .linux) })
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
    let reservation = try admission.acquire()
    let stop = RunnerPoolStop()

    DispatchQueue.global().async {
        do {
            _ = try admission.acquire(
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

@Test
func serviceCommandPreservesRepeatedRepositories() throws {
    let command = try RunnerServiceCommand.parse([
        firstPoolRepository.fullName,
        firstPoolRepository.fullName,
    ])

    #expect(command.runners.repositories == [
        firstPoolRepository.fullName,
        firstPoolRepository.fullName,
    ])
}

@Test
func serviceCommandRejectsTooManyRunnerSlots() {
    let arguments = Array(
        repeating: firstPoolRepository.fullName,
        count: RunnerPool.maximumSlots + 1
    )

    do {
        _ = try RunnerServiceCommand.parse(arguments)
        Issue.record("Expected excessive runner slots to be rejected")
    } catch {
        #expect(String(describing: error).contains(
            "at most \(RunnerPool.maximumSlots) runner slots"
        ))
    }
}

@Test
func serviceCommandAcceptsMaximumRunnerSlots() throws {
    let arguments = Array(
        repeating: firstPoolRepository.fullName,
        count: RunnerPool.maximumSlots
    )

    _ = try RunnerServiceCommand.parse(arguments)
}

@Test
func serviceRejectsImpossibleMemoryBudgetBeforeStartingPool() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-service-memory-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memoryAdmission = RunnerMemoryAdmission(
        physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        readMemoryPressure: { .normal }
    )
    let output = RunnerServiceOutput(
        info: { _ in Issue.record("The runner pool must not start") },
        warning: { _ in },
        error: { _ in }
    )
    let orphan = try MacOSRunnerCloneStore(stateDirectory: directory)
        .creatingURL(for: RunnerID(value: "yieldd-macos-orphan"))
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

    #expect(throws: RunnerMemoryAdmissionError.insufficientHostMemory(
        requiredBytes: AppleContainerBackend.memoryBytes,
        budgetBytes: 6 * 1_024 * 1_024 * 1_024
    )) {
        try runRunnerService(
            configuration: RunnerServiceConfiguration(repositories: [firstPoolRepository]),
            leaseStore: RunnerLeaseStore(directory: directory),
            containerURL: URL(fileURLWithPath: "/missing/container"),
            ghURL: URL(fileURLWithPath: "/missing/gh"),
            stop: RunnerPoolStop(),
            output: output,
            memoryAdmission: memoryAdmission
        )
    }
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
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
