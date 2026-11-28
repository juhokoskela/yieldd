import Foundation

private func destroyConnectedGuest(
    store: ConnectedRunnerStore,
    id: RunnerID,
    directory: URL,
    executor: ProcessExecutor,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)?,
    resolveContainer: () throws -> URL,
    maximumExecutionDeadline: @escaping () -> DispatchTime?
) throws {
    try withConnectedRunnerActivity(id.value) {
        switch store.platform {
        case .macOS:
            try removeMacOSRunnerFiles(id, in: directory, executor: executor, makeCloneStore: makeCloneStore)
        case .linux:
            let container = try resolveContainer()
            try AppleContainerSystem(containerURL: container, executor: executor, stateDirectory: directory).start()
            try AppleContainerBackend(containerURL: container, executor: executor, stateDirectory: directory,
                                      maximumExecutionDeadline: maximumExecutionDeadline).destroy(id)
        }
    }
}

/// Destroys any locally persisted guest machines/clones while holding runner ownership,
/// without requiring Keychain credentials or coordinator reachability, so a locked Keychain
/// cannot leave an orphaned Linux container running after a crash or reboot.
@discardableResult
func destroyLocalConnectedGuests(
    leaseStore: RunnerLeaseStore,
    server: URL, deviceID: String,
    confirmation: String? = nil,
    stop: RunnerPoolStop,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil,
    resolveContainer: () throws -> URL = { try ExecutableLocator().locate("container") },
    output: RunnerServiceOutput = .terminal, control: ConnectedAgentControl? = nil
) throws -> Set<String> {
    let directory = leaseStore.directory
    let leases = ConnectedRunnerStore.all(in: directory).compactMap { try? $0.load() }
    guard !leases.isEmpty else { return [] }
    control?.recovering(leases)
    var destroyed: Set<String> = []
    let executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
    for store in ConnectedRunnerStore.all(in: directory) {
        try stop.check()
        do {
            guard let lease = try store.load() else { continue }
            if let confirmation, lease.offer.runner != confirmation { continue }
            try lease.requireRecoveryIdentity(server: server.absoluteString, deviceID: deviceID)
            let id = RunnerID(value: lease.offer.runner)
            try destroyConnectedGuest(
                store: store,
                id: id,
                directory: directory,
                executor: executor,
                makeCloneStore: makeCloneStore,
                resolveContainer: resolveContainer,
                maximumExecutionDeadline: stop.executionDeadline
            )
            destroyed.insert(lease.offer.runner)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            output.error(describeError(error))
        }
    }
    return destroyed
}

func recoverConnectedPlatforms(
    directory: URL, server: URL, deviceID: String, token: String,
    confirmation: String?, stop: RunnerPoolStop,
    alreadyDestroyed: Set<String> = [],
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil,
    resolveContainer: () throws -> URL = { try ExecutableLocator().locate("container") },
    output: RunnerServiceOutput = .terminal, control: ConnectedAgentControl? = nil
) throws {
    control?.recovering(ConnectedRunnerStore.all(in: directory).compactMap { try? $0.load() })
    typealias Pending = (ConnectedRunnerStore, ConnectedOffer, ConnectedHTTPClient?)
    var pending: [Pending] = []
    var firstFailure: (any Error)?
    let executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
    for store in ConnectedRunnerStore.all(in: directory) {
        try stop.check()
        do {
            guard let lease = try store.load() else { continue }
            if let confirmation, lease.offer.runner != confirmation { continue }
            try lease.requireRecoveryIdentity(server: server.absoluteString, deviceID: deviceID)
            if !alreadyDestroyed.contains(lease.offer.runner) {
                let id = RunnerID(value: lease.offer.runner)
                try destroyConnectedGuest(
                    store: store,
                    id: id,
                    directory: directory,
                    executor: executor,
                    makeCloneStore: makeCloneStore,
                    resolveContainer: resolveContainer,
                    maximumExecutionDeadline: stop.executionDeadline
                )
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
