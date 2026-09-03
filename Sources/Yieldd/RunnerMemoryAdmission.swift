import Foundation

struct RunnerMemoryRequirements: Equatable, Sendable {
    let constrainedBytes: UInt64
    let fullBytes: UInt64

    init(constrainedBytes: UInt64, fullBytes: UInt64) {
        precondition(constrainedBytes > 0)
        precondition(fullBytes >= constrainedBytes)
        self.constrainedBytes = constrainedBytes
        self.fullBytes = fullBytes
    }

    func bytes(for allocation: RunnerMemoryAllocation) -> UInt64 {
        switch allocation {
        case .constrained:
            constrainedBytes
        case .full:
            fullBytes
        }
    }
}

struct RunnerMemoryReservation: Equatable, Sendable {
    let allocation: RunnerMemoryAllocation
    let byteCount: UInt64
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

    func acquire(
        requirements: RunnerMemoryRequirements,
        checkCancellation: () throws -> Void = {}
    ) throws -> RunnerMemoryReservation {
        guard requirements.constrainedBytes <= budgetBytes else {
            throw RunnerMemoryAdmissionError.insufficientHostMemory(
                requiredBytes: requirements.constrainedBytes,
                budgetBytes: budgetBytes
            )
        }

        while true {
            try checkCancellation()
            condition.lock()
            if let allocation = availableAllocation(requirements: requirements) {
                let byteCount = requirements.bytes(for: allocation)
                let reservation = RunnerMemoryReservation(
                    allocation: allocation,
                    byteCount: byteCount
                )
                reservedBytes += byteCount
                condition.unlock()
                return reservation
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: Self.checkInterval))
            condition.unlock()
        }
    }

    func release(_ reservation: RunnerMemoryReservation) {
        condition.withLock {
            precondition(reservation.byteCount <= reservedBytes)
            reservedBytes -= reservation.byteCount
            condition.broadcast()
        }
    }

    private func availableAllocation(
        requirements: RunnerMemoryRequirements
    ) -> RunnerMemoryAllocation? {
        switch readMemoryPressure() {
        case .normal:
            if canReserve(requirements.fullBytes) {
                return .full
            }
            if canReserve(requirements.constrainedBytes) {
                return .constrained
            }
        case .warning, .unknown:
            if canReserve(requirements.constrainedBytes) {
                return .constrained
            }
        case .critical:
            break
        }
        return nil
    }

    private func canReserve(_ byteCount: UInt64) -> Bool {
        byteCount <= budgetBytes - reservedBytes
    }
}

enum RunnerMemoryAdmissionError: Error, Equatable, LocalizedError {
    case insufficientHostMemory(requiredBytes: UInt64, budgetBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case let .insufficientHostMemory(requiredBytes, budgetBytes):
            "Runner provisioning requires a \(formatBytes(requiredBytes)) memory reservation, "
                + "but this host permits \(formatBytes(budgetBytes))."
        }
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
