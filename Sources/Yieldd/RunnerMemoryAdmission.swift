import Foundation

struct RunnerMemoryReservation: Equatable, Sendable {
    let allocation: RunnerMemoryAllocation
    let bytes: UInt64
}

final class RunnerMemoryAdmission: @unchecked Sendable {
    private static let checkInterval: TimeInterval = 0.1

    private let condition = NSCondition()
    private let budgetBytes: UInt64
    private let readMemoryPressure: @Sendable () -> HostMemoryPressure
    private var reservedBytes: UInt64 = 0

    init(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        readMemoryPressure: @escaping @Sendable () -> HostMemoryPressure = HostMemoryPressure.current
    ) {
        budgetBytes = physicalMemoryBytes - physicalMemoryBytes / 4
        self.readMemoryPressure = readMemoryPressure
    }

    func connectedWorkerCount(for platform: RunnerPlatform) -> Int {
        let limit = platform == .macOS ? RunnerServiceConfiguration.maximumMacOSSlots : RunnerPool.maximumSlots
        return Int(min(UInt64(limit), budgetBytes / platform.memoryReservationBytes))
    }

    func validateCapacity(reserving reservationBytes: UInt64) throws {
        precondition(reservationBytes > 0)
        guard reservationBytes <= budgetBytes else {
            throw RunnerMemoryAdmissionError.insufficientHostMemory(
                requiredBytes: reservationBytes,
                budgetBytes: budgetBytes
            )
        }
    }

    func acquire(
        reserving reservationBytes: UInt64,
        checkCancellation: () throws -> Void = {},
        onBlocked: () -> Void = {}
    ) throws -> RunnerMemoryReservation {
        var reportedBlocked = false
        while true {
            try checkCancellation()
            if let reservation = try tryAcquire(reserving: reservationBytes) {
                return reservation
            }

            if !reportedBlocked {
                onBlocked()
                reportedBlocked = true
            }
            condition.withLock {
                _ = condition.wait(
                    until: Date(timeIntervalSinceNow: Self.checkInterval)
                )
            }
        }
    }

    func release(_ reservation: RunnerMemoryReservation) {
        condition.withLock {
            precondition(reservation.bytes <= reservedBytes)
            reservedBytes -= reservation.bytes
            condition.broadcast()
        }
    }

    func isAvailable(reserving bytes: UInt64) -> Bool {
        condition.withLock { availableAllocation(reserving: bytes) != nil }
    }

    func tryAcquire(reserving bytes: UInt64) throws -> RunnerMemoryReservation? {
        try validateCapacity(reserving: bytes)
        return condition.withLock {
            guard let allocation = availableAllocation(reserving: bytes) else { return nil }
            reservedBytes += bytes
            return RunnerMemoryReservation(allocation: allocation, bytes: bytes)
        }
    }

    private func availableAllocation(reserving reservationBytes: UInt64) -> RunnerMemoryAllocation? {
        guard reservationBytes <= budgetBytes - reservedBytes else {
            return nil
        }

        switch readMemoryPressure() {
        case .normal:
            return .full
        case .warning, .unknown:
            return .constrained
        case .critical:
            return nil
        }
    }
}

enum RunnerMemoryAdmissionError: Error, Equatable, LocalizedError {
    case insufficientHostMemory(requiredBytes: UInt64, budgetBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case let .insufficientHostMemory(requiredBytes, budgetBytes):
            "Runner provisioning requires a \(formatBytes(requiredBytes)) memory reservation, "
                + "but this host permits \(formatBytes(budgetBytes)). Configure fewer runner slots or use a host with more memory."
        }
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
