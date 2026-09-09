import Foundation

// Shared by the session, its backend, and its process executor during provisioning only.
final class RunnerStartupDeadline {
    private let currentTime: () -> TimeInterval
    private let checkCancellation: () throws -> Void
    private var deadline: TimeInterval?

    init(
        currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void
    ) {
        self.currentTime = currentTime
        self.checkCancellation = checkCancellation
    }

    func begin() { deadline = currentTime() + 10 * 60 }
    func end() { deadline = nil }

    func check() throws {
        try checkCancellation()
        if let deadline, currentTime() >= deadline { throw RunnerAssignmentError.startupTimedOut }
    }
}
