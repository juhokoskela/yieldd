import Foundation

struct RunnerPool: Sendable {
    private let stop: RunnerPoolStop
    private let runSlot: @Sendable (GitHubRepository, RunnerPoolStop) throws -> Void

    init(
        stop: RunnerPoolStop,
        runSlot: @escaping @Sendable (GitHubRepository, RunnerPoolStop) throws -> Void
    ) {
        self.stop = stop
        self.runSlot = runSlot
    }

    func run(repositories: [GitHubRepository]) throws {
        precondition(!repositories.isEmpty)

        let group = DispatchGroup()
        let failure = RunnerPoolFailure()
        for (index, repository) in repositories.enumerated() {
            group.enter()
            DispatchQueue(label: "dev.yieldd.runner-slot.\(index)").async {
                defer { group.leave() }
                do {
                    try runSlot(repository, stop)
                } catch {
                    if failure.record(error) {
                        stop.request()
                    }
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
    private let checkExternal: () throws -> Void
    private var requested = false

    // The external checker must support concurrent calls. Internal state is protected by condition.
    init(checkExternal: @escaping () throws -> Void = {}) {
        self.checkExternal = checkExternal
    }

    func request() {
        condition.lock()
        requested = true
        condition.broadcast()
        condition.unlock()
    }

    func check() throws {
        try checkExternal()
        condition.lock()
        let shouldStop = requested
        condition.unlock()
        if shouldStop {
            throw CancellationError()
        }
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

            condition.lock()
            if !requested {
                _ = condition.wait(
                    until: Date(timeIntervalSinceNow: min(remaining, Self.checkInterval))
                )
            }
            let shouldStop = requested
            condition.unlock()
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

    func record(_ error: any Error) -> Bool {
        lock.withLock {
            guard self.error == nil else {
                return false
            }
            self.error = error
            return true
        }
    }
}
