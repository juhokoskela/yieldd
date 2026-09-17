import Foundation

struct ConnectedRunner {
    let backend: any RunnerBackend
    let store: ConnectedRunnerStore
    let server: String
    let deviceID: String
    let accept: (ConnectedOffer) throws -> String
    let complete: (ConnectedOffer) throws -> Void
    let checkCancellation: () throws -> Void
    let wait: (TimeInterval) throws -> Void
    var stateChanged: (RunnerSessionState) -> Void = { _ in }

    func recover(confirmRegistrationRemoved runner: String? = nil) throws {
        guard let lease = try store.load() else {
            if runner != nil { throw ConnectedRunnerError.confirmationMismatch }
            return
        }
        guard try ConnectedHTTPClient.serverURL(lease.server) == ConnectedHTTPClient.serverURL(server),
              lease.deviceID == deviceID else { throw ConnectedRunnerError.identityChanged }
        if let runner, runner != lease.offer.runner { throw ConnectedRunnerError.confirmationMismatch }
        // A restart never resumes execution, even if the acceptance response was lost.
        try backend.destroy(RunnerID(value: lease.offer.runner))
        if runner == nil { try acknowledge(lease.offer) }
        try store.clear()
    }

    func run(_ offer: ConnectedOffer, memory: RunnerMemoryAllocation, releaseCapacity: () -> Void = {}) throws {
        guard try store.load() == nil else { throw ConnectedRunnerError.recoveryRequired }
        let id = RunnerID(value: offer.runner)
        try store.save(ConnectedLease(server: server, deviceID: deviceID, offer: offer))
        var failure: (any Error)?
        do {
            try checkCancellation()
            let jit = try accept(offer)
            try validateConnectedJIT(jit, runner: offer.runner)
            try checkCancellation()
            try backend.create(id: id, memory: memory)
            try checkCancellation()
            try backend.exec(["yieldd-configure-runner", "--jit"], standardInput: Data("\(jit)\n".utf8),
                             timeout: EphemeralRunnerSession.configurationTimeout, on: id)
            try ReservedRunnerJob(backend: backend, checkCancellation: checkCancellation, wait: wait, stateChanged: stateChanged)
                .run(id: id, pickupTimeout: 5 * 60, executionTimeout: 15 * 60)
        } catch {
            failure = error
        }
        try cleanUp(step: .machine, after: failure) { try backend.destroy(id) }
        releaseCapacity()
        stateChanged(.capacityReleased(id))
        try cleanUp(step: .githubRunner, after: failure) { try acknowledge(offer) }
        try cleanUp(step: .leaseRecord, after: failure) { try store.clear() }
        stateChanged(.cleanupCompleted(id))
        if let failure, (failure as? ConnectedRunnerError) != .http(410) { throw failure }
    }

    private func acknowledge(_ offer: ConnectedOffer) throws {
        do { try complete(offer) } catch ConnectedRunnerError.http(409) {
            throw ConnectedRunnerError.registrationReconciliationRequired(offer.runner)
        }
    }

    private func cleanUp(step: RunnerSessionCleanupStep, after failure: (any Error)?, operation: () throws -> Void) throws {
        do { try operation() } catch {
            guard let failure else { throw error }
            throw RunnerSessionError.operationAndCleanupFailed(operation: failure, cleanup: [.init(step: step, error: error)])
        }
    }
}
