import Dispatch
import Foundation
import Testing
@testable import Yieldd

private let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

@Test
func normalPressureUsesFullMemory() throws {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: { .normal }
    )

    let reservation = try admission.acquire()

    #expect(reservation.allocation == .full)
}

@Test(arguments: [HostMemoryPressure.warning, HostMemoryPressure.unknown])
func uncertainPressureUsesConstrainedMemory(_ pressure: HostMemoryPressure) throws {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: { pressure }
    )

    let reservation = try admission.acquire()

    #expect(reservation.allocation == .constrained)
}

@Test
func concurrentAdmissionWaitsForReleaseWithoutPolling() throws {
    let blocked = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let result = MemoryReservationResult()
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 4,
        reservationBytes: 3,
        readMemoryPressure: { .normal },
        wait: { condition, reason in
            #expect(reason == .capacity)
            blocked.signal()
            condition.wait()
        }
    )
    let first = try admission.acquire()

    DispatchQueue.global().async {
        result.store(Result { try admission.acquire() })
        finished.signal()
    }

    #expect(blocked.wait(timeout: .now() + 1) == .success)
    admission.release(first)
    #expect(finished.wait(timeout: .now() + 1) == .success)
    admission.release(try result.value.get())
}

@Test
func criticalPressureRetriesUntilItReturnsToNormal() throws {
    let pressure = LockedMemoryPressure(.critical)
    var waits: [RunnerMemoryWaitReason] = []
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 4,
        reservationBytes: 3,
        readMemoryPressure: pressure.read,
        wait: { _, reason in
            waits.append(reason)
            pressure.set(.normal)
        }
    )

    let reservation = try admission.acquire()

    #expect(reservation.allocation == .full)
    #expect(waits == [.pressure])
}

@Test
func blockedNotificationIsEmittedOnlyOnce() throws {
    let pressure = LockedMemoryPressure(.critical)
    var waits = 0
    var notifications = 0
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 4,
        reservationBytes: 3,
        readMemoryPressure: pressure.read,
        wait: { _, reason in
            #expect(reason == .pressure)
            waits += 1
            if waits == 2 {
                pressure.set(.normal)
            }
        }
    )

    _ = try admission.acquire(onBlocked: { notifications += 1 })

    #expect(waits == 2)
    #expect(notifications == 1)
}

@Test
func criticalPressureWaitCanBeCancelledDeterministically() {
    let cancelled = LockedBoolean()
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 4,
        reservationBytes: 3,
        readMemoryPressure: { .critical },
        wait: { _, reason in
            #expect(reason == .pressure)
            cancelled.set()
        }
    )

    #expect(throws: CancellationError.self) {
        try admission.acquire(checkCancellation: {
            if cancelled.value {
                throw CancellationError()
            }
        })
    }
}

@Test
func impossibleReservationFailsImmediately() {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 12 * gibibyte,
        reservationBytes: 10 * gibibyte,
        readMemoryPressure: { .normal }
    )
    let expected = RunnerMemoryAdmissionError.insufficientHostMemory(
        requiredBytes: 10 * gibibyte,
        budgetBytes: 9 * gibibyte
    )

    #expect(throws: expected) {
        try admission.validateCapacity()
    }
    #expect(throws: expected) {
        try admission.acquire()
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

private final class LockedMemoryPressure: @unchecked Sendable {
    private let lock = NSLock()
    private var pressure: HostMemoryPressure

    init(_ pressure: HostMemoryPressure) {
        self.pressure = pressure
    }

    func read() -> HostMemoryPressure {
        lock.withLock { pressure }
    }

    func set(_ pressure: HostMemoryPressure) {
        lock.withLock { self.pressure = pressure }
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.withLock { stored }
    }

    func set() {
        lock.withLock { stored = true }
    }
}
