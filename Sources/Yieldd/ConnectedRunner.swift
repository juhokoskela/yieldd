import Foundation

struct ConnectedRunner {
    let backend: any RunnerBackend
    let store: ConnectedRunnerStore
    let server: String
    let deviceID: String
    let accept: (ConnectedOffer) throws -> String
    let complete: (ConnectedOffer) throws -> Void
    let authorization: ConnectedExecutionAuthorization
    let wait: (TimeInterval) throws -> Void
    var stateChanged: (RunnerSessionState) -> Void = { _ in }
    var currentTime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func recover(confirmRegistrationRemoved runner: String? = nil) throws {
        guard store.platform == backend.platform else { throw ConnectedRunnerError.invalidState }
        try recoverConnectedRunner(store: store, server: server, deviceID: deviceID,
                                   confirmRegistrationRemoved: runner, destroy: backend.destroy, complete: complete)
    }

    func run(_ offer: ConnectedOffer, memory: RunnerMemoryAllocation, releaseCapacity: () -> Void = {}) throws {
        var releaseOnExit = true
        defer { if releaseOnExit { releaseCapacity() } }
        guard offer.runnerPlatform == backend.platform else { throw ConnectedRunnerError.invalidOffer }
        guard try store.load() == nil else { throw ConnectedRunnerError.recoveryRequired }
        let id = RunnerID(value: offer.runner)
        let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "yieldd runner \(id.value)")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try store.save(ConnectedLease(server: server, deviceID: deviceID, offer: offer))
        var failure: (any Error)?
        do {
            try authorization.check()
            let jit = try accept(offer)
            authorization.start(offer)
            try validateConnectedJIT(jit, runner: offer.runner)
            try authorization.check()
            // Creation can fail after allocating a guest. Retain capacity until destruction succeeds.
            releaseOnExit = false
            try backend.create(id: id, memory: memory)
            try authorization.check()
            try RunnerGuestProtocol.validate(backend: backend, id: id)
            try backend.exec(["yieldd-configure-runner", "--jit"], standardInput: Data("\(jit)\n".utf8),
                             timeout: EphemeralRunnerSession.configurationTimeout, on: id)
            try ReservedRunnerJob(backend: backend, checkCancellation: authorization.check, wait: wait,
                                  stateChanged: stateChanged, currentTime: currentTime)
                .run(id: id, pickupTimeout: 5 * 60, executionTimeout: nil)
        } catch {
            failure = authorization.failure ?? error
        }
        authorization.stop()
        if let failure = failure as? ConnectedExecutionError {
            stateChanged(.executionStopped(id, reason: describeError(failure)))
        }
        try cleanUp(step: .machine, after: failure) { try backend.destroy(id) }
        releaseOnExit = false
        releaseCapacity()
        stateChanged(.capacityReleased(id))
        try cleanUp(step: .githubRunner, after: failure) { try acknowledgeConnectedRunner(offer, complete: complete) }
        try cleanUp(step: .leaseRecord, after: failure) { try store.clear() }
        stateChanged(.cleanupCompleted(id))
        if let failure, !(failure is ConnectedExecutionError), (failure as? ConnectedRunnerError) != .http(410) { throw failure }
    }

    private func cleanUp(step: RunnerSessionCleanupStep, after failure: (any Error)?, operation: () throws -> Void) throws {
        do { try operation() } catch {
            guard let failure else { throw error }
            throw RunnerSessionError.operationAndCleanupFailed(operation: failure, cleanup: [.init(step: step, error: error)])
        }
    }
}

func recoverConnectedRunner(
    store: ConnectedRunnerStore, server: String, deviceID: String,
    confirmRegistrationRemoved runner: String? = nil,
    destroy: (RunnerID) throws -> Void, complete: (ConnectedOffer) throws -> Void
) throws {
    guard let lease = try store.load() else {
        if runner != nil { throw ConnectedRunnerError.confirmationMismatch }
        return
    }
    guard try ConnectedHTTPClient.serverURL(lease.server) == ConnectedHTTPClient.serverURL(server),
          lease.deviceID == deviceID else { throw ConnectedRunnerError.identityChanged }
    if let runner, runner != lease.offer.runner { throw ConnectedRunnerError.confirmationMismatch }
    let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "yieldd runner \(lease.offer.runner)")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    // A restart never resumes execution, even if the acceptance response was lost.
    try destroy(RunnerID(value: lease.offer.runner))
    if runner == nil { try acknowledgeConnectedRunner(lease.offer, complete: complete) }
    try store.clear()
}

private func acknowledgeConnectedRunner(_ offer: ConnectedOffer, complete: (ConnectedOffer) throws -> Void) throws {
    do { try complete(offer) } catch ConnectedRunnerError.http(409) {
        throw ConnectedRunnerError.registrationReconciliationRequired(offer.runner)
    }
}
