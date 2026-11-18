import Foundation

func recoverConnectedPlatforms(
    directory: URL, server: URL, deviceID: String, token: String,
    confirmation: String?, stop: RunnerPoolStop,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil,
    resolveContainer: () throws -> URL = { try ExecutableLocator().locate("container") },
    output: RunnerServiceOutput = .terminal, control: ConnectedAgentControl? = nil
) throws {
    control?.recovering(ConnectedRunnerStore.all(in: directory).compactMap { try? $0.load() })
    typealias Pending = (ConnectedRunnerStore, ConnectedOffer, ConnectedHTTPClient?)
    var pending: [Pending] = []
    var firstFailure: (any Error)?
    for store in ConnectedRunnerStore.all(in: directory) {
        try stop.check()
        do {
            guard let lease = try store.load() else { continue }
            if let confirmation, lease.offer.runner != confirmation { continue }
            try lease.requireRecoveryIdentity(server: server.absoluteString, deviceID: deviceID)
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
                try NativeCacheStore.recover(in: directory, platform: store.platform, id: id)
            }
            let workerID = store.platform.connectedWorkerID(slot: store.slot)
            let client = confirmation == nil ? ConnectedHTTPClient(server: server, deviceID: deviceID, token: token,
                platform: store.platform, slot: store.slot, checkCancellation: stop.check,
                maximumExecutionDeadline: stop.executionDeadline,
                connectionChanged: { state, error in control?.connection(worker: workerID, state: state, error: error) }) : nil
            pending.append((store, lease.offer, client))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            firstFailure = firstFailure ?? error
            output.error(describeError(error))
        }
    }
    if pending.isEmpty, confirmation != nil, firstFailure == nil { throw ConnectedRunnerError.confirmationMismatch }
    while !pending.isEmpty {
        var retry: [Pending] = []
        for (store, offer, client) in pending {
            try stop.check()
            let workerID = store.platform.connectedWorkerID(slot: store.slot)
            do {
                if let client {
                    try acknowledgeConnectedRunner(offer, complete: client.complete)
                }
                try store.clear()
                control?.finishAssignment(worker: workerID)
            } catch where isTransientConnectedFailure(error) {
                retry.append((store, offer, client))
                output.info("Retrying cleanup acknowledgement for \(offer.runner): \(describeError(error))")
            } catch {
                firstFailure = firstFailure ?? error
                output.error(describeError(error))
            }
        }
        pending = retry
        if !pending.isEmpty { try stop.wait(for: 5) }
    }
    if let firstFailure { throw firstFailure }
}
