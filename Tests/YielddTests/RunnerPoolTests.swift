import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

private let firstPoolRepository = try! GitHubRepository("owner/first")
private let secondPoolRepository = try! GitHubRepository("owner/second")

@Test
func poolRunsOneConcurrentSlotPerRepository() throws {
    let gate = ConcurrentSlotGate(expected: 2)

    try RunnerPool(stop: RunnerPoolStop()) { repository, _ in
        try gate.enter(repository)
    }.run(repositories: [firstPoolRepository, secondPoolRepository])

    #expect(Set(gate.repositories.map(\.fullName)) == [
        firstPoolRepository.fullName,
        secondPoolRepository.fullName,
    ])
    #expect(gate.maximumActiveSlots == 2)
}

@Test
func poolPreservesRepeatedRepositorySlots() throws {
    let gate = ConcurrentSlotGate(expected: 2)

    try RunnerPool(stop: RunnerPoolStop()) { repository, _ in
        try gate.enter(repository)
    }.run(repositories: [firstPoolRepository, firstPoolRepository])

    #expect(gate.repositories == [firstPoolRepository, firstPoolRepository])
    #expect(gate.maximumActiveSlots == 2)
}

@Test
func poolFailureCancelsOtherSlotsAndPreservesTheFirstError() {
    let gate = ConcurrentSlotGate(expected: 2)
    let peerWasCancelled = LockedFlag()

    #expect(throws: TestFailure.runnerJob) {
        try RunnerPool(stop: RunnerPoolStop()) { repository, stop in
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
        }.run(repositories: [firstPoolRepository, secondPoolRepository])
    }

    #expect(peerWasCancelled.value)
}

@Test
func serviceCommandPreservesRepeatedRepositories() throws {
    let command = try RunnerServiceCommand.parse([
        firstPoolRepository.fullName,
        firstPoolRepository.fullName,
    ])

    #expect(command.repositories == [
        firstPoolRepository.fullName,
        firstPoolRepository.fullName,
    ])
}

@Test
func serviceCommandRejectsTooManyRunnerSlots() {
    let arguments = Array(
        repeating: firstPoolRepository.fullName,
        count: RunnerServiceCommand.maximumSlots + 1
    )

    do {
        _ = try RunnerServiceCommand.parse(arguments)
        Issue.record("Expected excessive runner slots to be rejected")
    } catch {
        #expect(String(describing: error).contains(
            "at most \(RunnerServiceCommand.maximumSlots) runner slots"
        ))
    }
}

@Test
func serviceCommandAcceptsMaximumRunnerSlots() throws {
    let arguments = Array(
        repeating: firstPoolRepository.fullName,
        count: RunnerServiceCommand.maximumSlots
    )

    _ = try RunnerServiceCommand.parse(arguments)
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
