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

    let reservation = try admission.acquire(reserving: 12 * gibibyte)

    #expect(reservation.allocation == .full)
}

@Test(arguments: [HostMemoryPressure.warning, HostMemoryPressure.unknown])
func uncertainPressureUsesConstrainedMemory(_ pressure: HostMemoryPressure) throws {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: { pressure }
    )

    let reservation = try admission.acquire(reserving: 12 * gibibyte)

    #expect(reservation.allocation == .constrained)
}

@Test
func concurrentAdmissionWaitsForRelease() throws {
    let blocked = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let result = MemoryReservationResult()
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: { .normal }
    )
    let first = try admission.acquire(reserving: 12 * gibibyte)

    DispatchQueue.global().async {
        result.store(Result {
            try admission.acquire(reserving: 12 * gibibyte, onBlocked: { blocked.signal() })
        })
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
    let blocked = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let result = MemoryReservationResult()
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: pressure.read
    )

    DispatchQueue.global().async {
        result.store(Result {
            try admission.acquire(reserving: 12 * gibibyte, onBlocked: { blocked.signal() })
        })
        finished.signal()
    }

    #expect(blocked.wait(timeout: .now() + 1) == .success)
    pressure.set(.normal)
    #expect(finished.wait(timeout: .now() + 1) == .success)
    let reservation = try result.value.get()
    #expect(reservation.allocation == .full)
}

@Test
func blockedNotificationIsEmittedOnlyOnce() throws {
    let pressure = LockedMemoryPressure(.critical)
    var notifications = 0
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: pressure.read
    )

    _ = try admission.acquire(reserving: 12 * gibibyte, onBlocked: {
        notifications += 1
        pressure.set(.normal)
    })

    #expect(notifications == 1)
}

@Test
func criticalPressureWaitCanBeCancelled() {
    let cancelled = LockedBoolean()
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 16 * gibibyte,
        readMemoryPressure: { .critical }
    )

    #expect(throws: CancellationError.self) {
        try admission.acquire(reserving: 12 * gibibyte, checkCancellation: {
            if cancelled.value {
                throw CancellationError()
            }
        }, onBlocked: cancelled.set)
    }
}

@Test
func impossibleReservationFailsImmediately() {
    let admission = RunnerMemoryAdmission(
        physicalMemoryBytes: 12 * gibibyte,
        readMemoryPressure: { .normal }
    )
    let expected = RunnerMemoryAdmissionError.insufficientHostMemory(
        requiredBytes: 10 * gibibyte,
        budgetBytes: 9 * gibibyte
    )

    #expect(throws: expected) {
        try admission.validateCapacity(reserving: 10 * gibibyte)
    }
    #expect(throws: expected) {
        try admission.acquire(reserving: 10 * gibibyte)
    }
}

@Test
func mixedReservationsShareOneBudgetAndReleaseTheirExactSizes() throws {
    let admission = RunnerMemoryAdmission(physicalMemoryBytes: 32 * gibibyte, readMemoryPressure: { .normal })
    let linux = try admission.acquire(reserving: 12 * gibibyte)
    let mac = try admission.acquire(reserving: 8 * gibibyte)
    #expect(linux.bytes == 12 * gibibyte)
    #expect(mac.bytes == 8 * gibibyte)
    admission.release(mac)
    let replacement = try admission.acquire(reserving: 8 * gibibyte)
    var blocked = false
    #expect(throws: CancellationError.self) {
        try admission.acquire(reserving: 8 * gibibyte, checkCancellation: {
            if blocked { throw CancellationError() }
        }, onBlocked: { blocked = true })
    }
    #expect(blocked)
    admission.release(linux)
    let secondMac = try admission.acquire(reserving: 8 * gibibyte)
    admission.release(replacement)
    admission.release(secondMac)
    let entireBudget = try admission.acquire(reserving: 24 * gibibyte)
    admission.release(entireBudget)
}

@Test
func twoMacOSReservationsFitOnA24GiBHost() throws {
    let admission = RunnerMemoryAdmission(physicalMemoryBytes: 24 * gibibyte, readMemoryPressure: { .normal })
    let first = try admission.acquire(reserving: RunnerPlatform.macOS.memoryReservationBytes)
    let second = try admission.acquire(reserving: RunnerPlatform.macOS.memoryReservationBytes)
    #expect(first.bytes + second.bytes == 16 * gibibyte)
    admission.release(first)
    admission.release(second)
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
