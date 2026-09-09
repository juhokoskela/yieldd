import Dispatch
import Foundation

struct RunnerPool: Sendable {
    static let maximumSlots = 16

    private let stop: RunnerPoolStop
    private let runSlot: @Sendable (RunnerSlot, RunnerPoolStop) throws -> Void

    init(
        stop: RunnerPoolStop,
        runSlot: @escaping @Sendable (RunnerSlot, RunnerPoolStop) throws -> Void
    ) {
        self.stop = stop
        self.runSlot = runSlot
    }

    func run(slots: [RunnerSlot]) throws {
        precondition(!slots.isEmpty)

        let group = DispatchGroup()
        let failure = RunnerPoolFailure()
        for (index, slot) in slots.enumerated() {
            group.enter()
            DispatchQueue(label: "dev.yieldd.runner-slot.\(index)").async {
                defer { group.leave() }
                do {
                    try runSlot(slot, stop)
                } catch {
                    failure.record(error)
                    stop.request()
                }
            }
        }
        group.wait()

        if let error = failure.value {
            throw error
        }
    }
}

final class RunnerPoolStop: @unchecked Sendable {
    private static let checkInterval: TimeInterval = 0.1

    private let condition = NSCondition()
    private let shutdownTimeout: TimeInterval?
    private var requested = false
    private var stopDeadline: DispatchTime?
    private var signalMonitor: SignalMonitor?

    init(shutdownTimeout: TimeInterval? = nil) {
        if let shutdownTimeout {
            precondition(shutdownTimeout.isFinite && shutdownTimeout > 0)
        }
        self.shutdownTimeout = shutdownTimeout
    }

    static func monitoringSignals(
        shutdownTimeout: TimeInterval? = nil
    ) throws -> RunnerPoolStop {
        let stop = RunnerPoolStop(shutdownTimeout: shutdownTimeout)
        stop.signalMonitor = try SignalMonitor(signals: [SIGINT, SIGTERM, SIGHUP], signalReceived: { [weak stop] _ in
            stop?.request()
        })
        return stop
    }

    func request() {
        condition.withLock {
            guard !requested else {
                condition.broadcast()
                return
            }
            if let shutdownTimeout {
                stopDeadline = DispatchTime.now() + .milliseconds(
                    Int((shutdownTimeout * 1_000).rounded(.up))
                )
            }
            requested = true
            condition.broadcast()
        }
    }

    func check() throws {
        let shouldStop = condition.withLock { requested }
        if shouldStop {
            throw CancellationError()
        }
    }

    func executionDeadline() -> DispatchTime? {
        condition.withLock { stopDeadline }
    }

    func wait(for interval: TimeInterval) throws {
        precondition(interval.isFinite && interval >= 0)
        let deadline = ProcessInfo.processInfo.systemUptime + interval

        while true {
            try check()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                return
            }

            let shouldStop = condition.withLock {
                if !requested {
                    _ = condition.wait(
                        until: Date(timeIntervalSinceNow: min(remaining, Self.checkInterval))
                    )
                }
                return requested
            }
            if shouldStop {
                throw CancellationError()
            }
        }
    }
}

private final class RunnerPoolFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: (any Error)?

    var value: (any Error)? {
        lock.withLock { error }
    }

    func record(_ error: any Error) {
        lock.withLock {
            guard self.error == nil else {
                return
            }
            self.error = error
        }
    }
}
