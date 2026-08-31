import Foundation

struct DockerReadiness {
    let backend: any RunnerBackend
    private let attempts: Int
    private let retryDelay: TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let checkCancellation: () throws -> Void

    init(
        backend: any RunnerBackend,
        attempts: Int = 30,
        retryDelay: TimeInterval = 1,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        checkCancellation: @escaping () throws -> Void = {}
    ) {
        precondition(attempts > 0)
        self.backend = backend
        self.attempts = attempts
        self.retryDelay = retryDelay
        self.sleep = sleep
        self.checkCancellation = checkCancellation
    }

    func wait(on id: RunnerID) throws -> ProcessResult {
        var lastError: (any Error)?

        for attempt in 1...attempts {
            try checkCancellation()
            do {
                return try backend.exec(["docker", "info"], on: id)
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
                sleep(retryDelay)
            }
        }

        guard let lastError else {
            preconditionFailure("Docker readiness loop ran without an attempt")
        }
        throw lastError
    }
}
