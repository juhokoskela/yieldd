import Foundation

struct DockerReadiness {
    static let probeTimeout: TimeInterval = 5

    private let attempts: Int
    private let retryDelay: TimeInterval
    private let wait: (TimeInterval) throws -> Void
    private let checkCancellation: () throws -> Void

    init(
        attempts: Int = 30,
        retryDelay: TimeInterval = 1,
        wait: @escaping (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:),
        checkCancellation: @escaping () throws -> Void = {}
    ) {
        precondition(attempts > 0)
        self.attempts = attempts
        self.retryDelay = retryDelay
        self.wait = wait
        self.checkCancellation = checkCancellation
    }

    func wait(probe: () throws -> Void) throws {
        var lastError: (any Error)?

        for attempt in 1...attempts {
            try checkCancellation()
            do {
                try probe()
                return
            } catch let error as ProcessExecutionError {
                if case .launchFailed = error {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }

            try checkCancellation()
            if attempt < attempts {
                try wait(retryDelay)
            }
        }

        guard let lastError else {
            preconditionFailure("Docker readiness loop ran without an attempt")
        }
        throw lastError
    }
}
