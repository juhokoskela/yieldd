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
        guard offer.runnerPlatform == backend.platform, offer.slot == store.slot else { throw ConnectedRunnerError.invalidOffer }
        guard try store.load() == nil else { throw ConnectedRunnerError.recoveryRequired }
        try backend.prepare()
        let id = RunnerID(value: offer.runner)
        let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "yieldd runner \(id.value)")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try store.save(ConnectedLease(server: server, deviceID: deviceID, offer: offer))
        var failure: (any Error)?
        var machineMayExist = false
        var jobStarted = false
        do {
            try authorization.check()
            let jit = try accept(offer)
            authorization.start(offer)
            try validateConnectedJIT(jit, runner: offer.runner)
            try authorization.check()
            // Creation can fail after allocating a guest. Retain capacity until destruction succeeds.
            try backend.create(id: id, memory: memory) {
                releaseOnExit = false
                machineMayExist = true
            }
            try authorization.check()
            try RunnerGuestProtocol.validate(backend: backend, id: id)
            try backend.exec(["yieldd-configure-runner", "--jit"], standardInput: Data("\(jit)\n".utf8),
                             timeout: EphemeralRunnerSession.configurationTimeout, on: id)
            try ReservedRunnerJob(backend: backend, checkCancellation: authorization.check, wait: wait,
                                  stateChanged: { state in
                                      if case .jobStarted = state { jobStarted = true }
                                      stateChanged(state)
                                  }, currentTime: currentTime)
                .run(id: id, pickupTimeout: 5 * 60, executionTimeout: nil)
        } catch {
            let operation: any Error = jobStarted ? (ConnectedAssignmentFailure(error) ?? error) : error
            failure = authorization.failure ?? operation
        }
        authorization.stop()
        if let failure, isContainedConnectedFailure(failure), (failure as? ConnectedRunnerError)?.httpStatus != 410 {
            stateChanged(.executionStopped(id, reason: describeError(failure)))
        }
        if machineMayExist {
            try cleanUp(step: .machine, after: failure) { try backend.destroy(id) }
        }
        releaseOnExit = false
        releaseCapacity()
        stateChanged(.capacityReleased(id))
        try cleanUp(step: .githubRunner, after: failure) { try acknowledgeConnectedRunner(offer, complete: complete) }
        try cleanUp(step: .leaseRecord, after: failure) { try store.clear() }
        stateChanged(.cleanupCompleted(id))
        if let failure, !isContainedConnectedFailure(failure) { throw failure }
    }

    private func cleanUp(step: RunnerSessionCleanupStep, after failure: (any Error)?, operation: () throws -> Void) throws {
        do { try operation() } catch {
            guard let failure else { throw error }
            throw RunnerSessionError.operationAndCleanupFailed(operation: failure, cleanup: [.init(step: step, error: error)])
        }
    }
}

// Created only after observing job start. Runtime transport failures cannot identify
// whether the guest or host stalled; both require confirmed cleanup before reuse.
struct ConnectedAssignmentFailure: Error, LocalizedError {
    let underlying: any Error

    init?(_ error: any Error) {
        switch error {
        case ProcessExecutionError.timedOut, ProcessExecutionError.nonZeroExit, ProcessExecutionError.terminatedBySignal,
             RunnerAssignmentError.invalidStatus, RunnerAssignmentError.listenerFailed,
             RunnerNetworkRelayError.exited,
             MacOSVirtualizationProbeError.stoppedUnexpectedly, MacOSVirtualizationProbeError.virtualMachineFailed:
            underlying = error
        default: return nil
        }
    }

    var errorDescription: String? { describeError(underlying) }
}

func isContainedConnectedFailure(_ error: any Error) -> Bool {
    error is ConnectedExecutionError || error is ConnectedAssignmentFailure
        || (error as? ConnectedRunnerError)?.httpStatus == 410
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
    do { try complete(offer) } catch ConnectedRunnerError.http(409, _, _) {
        throw ConnectedRunnerError.registrationReconciliationRequired(offer.runner)
    }
}
