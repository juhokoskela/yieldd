import Foundation

struct RunnerMemoryReservation: Equatable, Sendable {
    let allocation: RunnerMemoryAllocation
}

enum RunnerMemoryWaitReason: Equatable {
    case capacity
    case pressure
}

final class RunnerMemoryAdmission: @unchecked Sendable {
    static let slotGibibytes: UInt64 = 12
    static let slotBytes = slotGibibytes * 1_024 * 1_024 * 1_024
    static let machineMemoryArgument = "\(slotGibibytes)G"

    private static let pressureCheckInterval: TimeInterval = 0.1

    private let condition = NSCondition()
    private let reservationBytes: UInt64
    private let budgetBytes: UInt64
    private let readMemoryPressure: @Sendable () -> HostMemoryPressure
    private let wait: (NSCondition, RunnerMemoryWaitReason) -> Void
    private var reservedBytes: UInt64 = 0

    init(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        reservationBytes: UInt64 = RunnerMemoryAdmission.slotBytes,
        readMemoryPressure: @escaping @Sendable () -> HostMemoryPressure = HostMemoryPressure.current,
        wait: @escaping (NSCondition, RunnerMemoryWaitReason) -> Void = RunnerMemoryAdmission.wait
    ) {
        precondition(reservationBytes > 0)
        self.reservationBytes = reservationBytes
        budgetBytes = physicalMemoryBytes - physicalMemoryBytes / 4
        self.readMemoryPressure = readMemoryPressure
        self.wait = wait
    }

    func validateCapacity() throws {
        guard reservationBytes <= budgetBytes else {
            throw RunnerMemoryAdmissionError.insufficientHostMemory(
                requiredBytes: reservationBytes,
                budgetBytes: budgetBytes
            )
        }
    }

    func acquire(
        checkCancellation: () throws -> Void = {},
        onBlocked: () -> Void = {}
    ) throws -> RunnerMemoryReservation {
        try validateCapacity()

        return try condition.withLock {
            var reportedBlocked = false
            while true {
                try checkCancellation()
                switch admissionDecision() {
                case let .admit(allocation):
                    reservedBytes += reservationBytes
                    return RunnerMemoryReservation(allocation: allocation)
                case let .wait(reason):
                    if !reportedBlocked {
                        onBlocked()
                        reportedBlocked = true
                    }
                    wait(condition, reason)
                }
            }
        }
    }

    func release(_: RunnerMemoryReservation) {
        condition.withLock {
            precondition(reservationBytes <= reservedBytes)
            reservedBytes -= reservationBytes
            condition.broadcast()
        }
    }

    func wakeWaiters() {
        condition.withLock {
            condition.broadcast()
        }
    }

    private func admissionDecision() -> AdmissionDecision {
        guard reservationBytes <= budgetBytes - reservedBytes else {
            return .wait(.capacity)
        }

        switch readMemoryPressure() {
        case .normal:
            return .admit(.full)
        case .warning, .unknown:
            return .admit(.constrained)
        case .critical:
            return .wait(.pressure)
        }
    }

    private static func wait(
        condition: NSCondition,
        reason: RunnerMemoryWaitReason
    ) {
        switch reason {
        case .capacity:
            condition.wait()
        case .pressure:
            _ = condition.wait(
                until: Date(timeIntervalSinceNow: pressureCheckInterval)
            )
        }
    }
}

private enum AdmissionDecision {
    case admit(RunnerMemoryAllocation)
    case wait(RunnerMemoryWaitReason)
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
