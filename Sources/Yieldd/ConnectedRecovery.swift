import Foundation

func recoverConnectedPlatforms(
    directory: URL, server: URL, deviceID: String, token: String,
    confirmation: String?, stop: RunnerPoolStop,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil,
    resolveContainer: () throws -> URL = { try ExecutableLocator().locate("container") },
    output: RunnerServiceOutput = .terminal, control: ConnectedAgentControl? = nil
) throws {
    control?.recovering(ConnectedRunnerStore.all(in: directory).compactMap { try? $0.load() })
    var pending: [(ConnectedRunnerStore, ConnectedOffer)] = []
    var firstFailure: (any Error)?
    for store in ConnectedRunnerStore.all(in: directory) {
        try stop.check()
        do {
            guard let lease = try store.load() else { continue }
            if let confirmation, lease.offer.runner != confirmation { continue }
            try lease.requireRecoveryIdentity(server: server.absoluteString, deviceID: deviceID, confirmation: confirmation)
            let id = RunnerID(value: lease.offer.runner)
            try withConnectedRunnerActivity(id.value) {
                switch store.platform {
                case .macOS:
                    try removeMacOSRunnerFiles(id, in: directory, makeCloneStore: makeCloneStore)
                case .linux:
                    let container = try resolveContainer()
                    let executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
                    try AppleContainerSystem(containerURL: container, executor: executor, stateDirectory: directory).start()
                    try AppleContainerBackend(containerURL: container, executor: executor, stateDirectory: directory,
                                              maximumExecutionDeadline: stop.executionDeadline).destroy(id)
                }
            }
            pending.append((store, lease.offer))
        } catch {
            firstFailure = firstFailure ?? error
            output.error(describeError(error))
        }
    }
    if pending.isEmpty, confirmation != nil, firstFailure == nil { throw ConnectedRunnerError.confirmationMismatch }
    while !pending.isEmpty {
        var retry: [(ConnectedRunnerStore, ConnectedOffer)] = []
        for (store, offer) in pending {
            try stop.check()
            let workerID = store.platform.connectedWorkerID(slot: store.slot)
            do {
                if confirmation == nil {
                    let client = ConnectedHTTPClient(server: server, deviceID: deviceID, token: token,
                        platform: store.platform, slot: store.slot, checkCancellation: stop.check,
                        maximumExecutionDeadline: stop.executionDeadline,
                        connectionChanged: { state, error in control?.connection(worker: workerID, state: state, error: error) })
                    try acknowledgeConnectedRunner(offer, complete: client.complete)
                }
                try store.clear()
                control?.finishAssignment(worker: workerID)
            } catch where isTransientConnectedFailure(error) {
                retry.append((store, offer))
                output.info("Retrying cleanup acknowledgement for \(offer.runner): \(describeError(error))")
            } catch {
                firstFailure = firstFailure ?? error
                output.error(describeError(error))
            }
        }
        if let firstFailure { throw firstFailure }
        pending = retry
        if !pending.isEmpty { try stop.wait(for: 5) }
    }
    if let firstFailure { throw firstFailure }
}
