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

    func validateCapacity(reserving reservationBytes: UInt64 = AppleContainerBackend.memoryBytes) throws {
        precondition(reservationBytes > 0)
        guard reservationBytes <= budgetBytes else {
            throw RunnerMemoryAdmissionError.insufficientHostMemory(
                requiredBytes: reservationBytes,
                budgetBytes: budgetBytes
            )
        }
    }

    func acquire(
        reserving reservationBytes: UInt64 = AppleContainerBackend.memoryBytes,
        checkCancellation: () throws -> Void = {},
        onBlocked: () -> Void = {}
    ) throws -> RunnerMemoryReservation {
        try validateCapacity(reserving: reservationBytes)

        var reportedBlocked = false
        while true {
            try checkCancellation()
            let allocation: RunnerMemoryAllocation? = condition.withLock {
                switch admissionDecision(reserving: reservationBytes) {
                case let .admit(allocation):
                    reservedBytes += reservationBytes
                    return allocation
                case .wait:
                    return nil
                }
            }
            if let allocation {
                return RunnerMemoryReservation(allocation: allocation, bytes: reservationBytes)
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

    private func admissionDecision(reserving reservationBytes: UInt64) -> AdmissionDecision {
        guard reservationBytes <= budgetBytes - reservedBytes else {
            return .wait
        }

        switch readMemoryPressure() {
        case .normal:
            return .admit(.full)
        case .warning, .unknown:
            return .admit(.constrained)
        case .critical:
            return .wait
        }
    }
}

private enum AdmissionDecision {
    case admit(RunnerMemoryAllocation)
    case wait
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
