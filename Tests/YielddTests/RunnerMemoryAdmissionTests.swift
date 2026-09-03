import Dispatch
import Foundation
import Testing
@testable import Yieldd

private let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

@Test
func normalPressureUsesFullMemoryWhenItFits() throws {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: { .normal }
    )

    let reservation = try admission.acquire(requirements: RunnerMemoryRequirements(
        constrainedBytes: 8 * gibibyte,
        fullBytes: 12 * gibibyte
    ))

    #expect(reservation.allocation == .full)
    #expect(reservation.byteCount == 12 * gibibyte)
}

@Test(arguments: [HostMemoryPressure.warning, HostMemoryPressure.unknown])
func uncertainPressureUsesConstrainedMemory(_ pressure: HostMemoryPressure) throws {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: { pressure }
    )

    let reservation = try admission.acquire(requirements: RunnerMemoryRequirements(
        constrainedBytes: 8 * gibibyte,
        fullBytes: 12 * gibibyte
    ))

    #expect(reservation.allocation == .constrained)
    #expect(reservation.byteCount == 8 * gibibyte)
}

@Test
func existingReservationCanReduceTheNextAllocation() throws {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 24 * gibibyte,
        readMemoryPressure: { .normal }
    )
    let requirements = RunnerMemoryRequirements(
        constrainedBytes: 6 * gibibyte,
        fullBytes: 12 * gibibyte
    )

    let first = try admission.acquire(requirements: requirements)
    let second = try admission.acquire(requirements: requirements)

    #expect(first.allocation == .full)
    #expect(second.allocation == .constrained)
}

@Test
func concurrentAdmissionWaitsForAnExistingReservation() throws {
    let pressureRead = DispatchSemaphore(value: 0)
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: {
            pressureRead.signal()
            return .normal
        }
    )
    let requirements = RunnerMemoryRequirements(
        constrainedBytes: 12 * gibibyte,
        fullBytes: 12 * gibibyte
    )
    let first = try admission.acquire(requirements: requirements)
    #expect(pressureRead.wait(timeout: .now() + 1) == .success)
    let finished = DispatchSemaphore(value: 0)
    let result = MemoryReservationResult()

    DispatchQueue.global().async {
        result.store(Result { try admission.acquire(requirements: requirements) })
        finished.signal()
    }

    #expect(pressureRead.wait(timeout: .now() + 1) == .success)
    #expect(finished.wait(timeout: .now()) == .timedOut)
    admission.release(first)
    #expect(finished.wait(timeout: .now() + 1) == .success)
    let second = try result.value.get()
    admission.release(second)
}

@Test
func criticalPressureWaitsUntilCancelled() {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: { .critical }
    )
    var checks = 0

    #expect(throws: CancellationError.self) {
        try admission.acquire(
            requirements: RunnerMemoryRequirements(
                constrainedBytes: 8 * gibibyte,
                fullBytes: 12 * gibibyte
            ),
            checkCancellation: {
                checks += 1
                if checks == 2 {
                    throw CancellationError()
                }
            }
        )
    }
    #expect(checks == 2)
}

@Test
func impossibleReservationFailsImmediately() {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 12 * gibibyte,
        readMemoryPressure: { .normal }
    )

    #expect(throws: RunnerMemoryAdmissionError.insufficientHostMemory(
        requiredBytes: 10 * gibibyte,
        budgetBytes: 9 * gibibyte
    )) {
        try admission.acquire(requirements: RunnerMemoryRequirements(
            constrainedBytes: 10 * gibibyte,
            fullBytes: 12 * gibibyte
        ))
    }
}

private final class MemoryReservationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<RunnerMemoryReservation, any Error>?

    var value: Result<RunnerMemoryReservation, any Error> {
        lock.withLock { stored! }
    }

    func store(_ result: Result<RunnerMemoryReservation, any Error>) {
        lock.withLock { stored = result }
    }
}
