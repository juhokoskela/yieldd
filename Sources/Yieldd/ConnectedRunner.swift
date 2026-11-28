import Foundation

final class ConnectedRunner {
    let backend: any RunnerBackend
    let store: ConnectedRunnerStore
    let server: String
    let deviceID: String
    let accept: (ConnectedOffer) throws -> String
    let complete: (ConnectedOffer) throws -> Void
    let authorization: ConnectedExecutionAuthorization
    let localCache: Bool
    let wait: (TimeInterval) throws -> Void
    var stateChanged: (RunnerSessionState) -> Void
    var currentTime: () -> TimeInterval
    var initialLinuxCPUs: () -> Int
    var onWarning: (String) -> Void

    // Valid only for this worker process. A restart must prove absence again.
    private var absent: RunnerID?

    init(backend: any RunnerBackend, store: ConnectedRunnerStore, server: String, deviceID: String,
         accept: @escaping (ConnectedOffer) throws -> String, complete: @escaping (ConnectedOffer) throws -> Void,
         authorization: ConnectedExecutionAuthorization, wait: @escaping (TimeInterval) throws -> Void,
         localCache: Bool = false,
         stateChanged: @escaping (RunnerSessionState) -> Void = { _ in },
         currentTime: @escaping () -> TimeInterval = continuousMonotonicSeconds,
         initialLinuxCPUs: @escaping () -> Int = { AppleContainerBackend.virtualCPUs },
         onWarning: @escaping (String) -> Void = { _ in }) {
        self.backend = backend
        self.store = store
        self.server = server
        self.deviceID = deviceID
        self.accept = accept
        self.complete = complete
        self.authorization = authorization
        self.localCache = localCache
        self.wait = wait
        self.stateChanged = stateChanged
        self.currentTime = currentTime
        self.initialLinuxCPUs = initialLinuxCPUs
        self.onWarning = onWarning
    }

    func recover() throws {
        guard store.platform == backend.platform else { throw ConnectedRunnerError.invalidState }
        guard let lease = try store.load() else { return }
        try lease.requireRecoveryIdentity(server: server, deviceID: deviceID)
        try withConnectedRunnerActivity(lease.offer.runner) {
            let id = RunnerID(value: lease.offer.runner)
            if absent != id {
                try backend.destroy(id)
                absent = id
            }
            try acknowledgeConnectedRunner(lease.offer, complete: complete)
            try store.clear()
            absent = nil
        }
    }

    func run(_ offer: ConnectedOffer, memory: RunnerMemoryAllocation, releaseCapacity: () -> Void = {}) throws {
        var releaseOnExit = true
        defer { if releaseOnExit { releaseCapacity() } }
        guard offer.runnerPlatform == backend.platform, offer.slot == store.slot else { throw ConnectedRunnerError.invalidOffer }
        guard try store.load() == nil else { throw ConnectedRunnerError.recoveryRequired }
        absent = nil
        try backend.prepare()
        let id = RunnerID(value: offer.runner)
        let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "yieldd runner \(id.value)")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try store.save(ConnectedLease(server: server, deviceID: deviceID, offer: offer))
        var failure: (any Error)?
        var machineMayExist = false
        var jobStarted = false
        do {
            authorization.prepare(runner: offer.runner)
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
            try RunnerGuestProtocol.validate(backend: backend, id: id, localCache: localCache)
            if backend.platform == .linux {
                var targetCPUs = initialLinuxCPUs()
                if targetCPUs < AppleContainerBackend.virtualCPUs {
                    do {
                        try backend.applyCPUQuota(targetCPUs, on: id)
                        // Re-check policy after applying startup quota so a concurrent Meeting Mode
                        // disable/change cannot be overwritten by an earlier startup cap.
                        let latestCPUs = initialLinuxCPUs()
                        if latestCPUs != targetCPUs {
                            targetCPUs = latestCPUs
                            try backend.applyCPUQuota(targetCPUs, on: id)
                        }
                    } catch let ProcessExecutionError.nonZeroExit(_, result) where result.terminationStatus == 2 {
                        onWarning("Guest image for \(id.value) does not support runtime CPU quotas (yieldd-runner-control cpu exited 2); rebuild the Linux guest image to enable Meeting Mode CPU caps.")
                    }
                }
            }
            let configure = ["yieldd-configure-runner", "--jit"] + (localCache ? ["--local-cache"] : [])
            try backend.exec(configure, standardInput: Data("\(jit)\n".utf8),
                             timeout: 5 * 60, on: id)
            try ReservedRunnerJob(backend: backend, checkCancellation: authorization.check, wait: wait,
                                  stateChanged: { state in
                                      if case .jobStarted = state {
                                          jobStarted = true
                                          self.authorization.markJobStarted()
                                      }
                                      self.stateChanged(state)
                                  }, currentTime: currentTime)
                .run(id: id, pickupTimeout: 5 * 60)
        } catch {
            let operation: any Error = jobStarted ? (ConnectedAssignmentFailure(error) ?? error) : error
            failure = authorization.failure ?? operation
        }
        let stoppedForReclaimOrShutdown = (failure as? ConnectedExecutionError) == .reclaimed
            || (failure.map(isCancellation) ?? false)
        authorization.stop()
        if let failure, !isCancellation(failure), (failure as? ConnectedRunnerError)?.httpStatus != 410 {
            stateChanged(.executionStopped(id, reason: describeError(failure)))
        }
        if machineMayExist {
            if stoppedForReclaimOrShutdown {
                // Best-effort bounded graceful stop with relay still attached so GitHub
                // marks the runner idle in seconds instead of waiting for a 5-10m timeout.
                backend.gracefulStopRunner(id)
            }
            try cleanUp(step: .machine, after: failure) { try backend.destroy(id) }
        }
        absent = id
        releaseOnExit = false
        releaseCapacity()
        stateChanged(.capacityReleased(id))
        try cleanUp(step: .githubRunner, after: failure) { try acknowledgeConnectedRunner(offer, complete: complete) }
        try cleanUp(step: .leaseRecord, after: failure) { try store.clear() }
        absent = nil
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

extension ConnectedLease {
    func requireRecoveryIdentity(server: String, deviceID: String) throws {
        guard try ConnectedHTTPClient.serverURL(self.server) == ConnectedHTTPClient.serverURL(server),
              self.deviceID == deviceID else { throw ConnectedRunnerError.identityChanged }
    }
}

func withConnectedRunnerActivity(_ runner: String, operation: () throws -> Void) rethrows {
    let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "yieldd runner \(runner)")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    try operation()
}

func acknowledgeConnectedRunner(_ offer: ConnectedOffer, complete: (ConnectedOffer) throws -> Void) throws {
    do { try complete(offer) } catch ConnectedRunnerError.http(409, _, _) {
        throw ConnectedRunnerError.registrationReconciliationRequired(offer.runner)
    }
}
