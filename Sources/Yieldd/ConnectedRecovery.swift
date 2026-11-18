import Foundation

func recoverConnectedPlatforms(
    directory: URL, server: URL, deviceID: String, token: String,
    confirmation: String?, stop: RunnerPoolStop,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil,
    resolveContainer: () throws -> URL = { try ExecutableLocator().locate("container") },
    output: RunnerServiceOutput = .terminal, control: ConnectedAgentControl? = nil
) throws {
    control?.recovering(ConnectedRunnerStore.all(in: directory).compactMap { try? $0.load() })
    var confirmed = false
    for store in ConnectedRunnerStore.all(in: directory) {
        let platform = store.platform
        guard let lease = try store.load() else { continue }
        if let confirmation, lease.offer.runner != confirmation { continue }
        let workerID = platform.connectedWorkerID(slot: store.slot)
        let client = ConnectedHTTPClient(server: server, deviceID: deviceID, token: token,
                                         platform: platform, slot: store.slot, checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline,
            connectionChanged: { state, error in control?.connection(worker: workerID, state: state, error: error) })
        while true {
            try stop.check()
            do {
                try recoverConnectedRunner(store: store, server: server.absoluteString, deviceID: deviceID,
                    confirmRegistrationRemoved: confirmation, destroy: { id in
                        switch platform {
                        case .macOS:
                            try removeMacOSRunnerFiles(id, in: directory, makeCloneStore: makeCloneStore)
                        case .linux:
                            let container = try resolveContainer()
                            let executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
                            try AppleContainerSystem(containerURL: container, executor: executor, stateDirectory: directory).start()
                            try AppleContainerBackend(containerURL: container, executor: executor, stateDirectory: directory, maximumExecutionDeadline: stop.executionDeadline).destroy(id)
                        }
                    }, complete: client.complete)
                control?.finishAssignment(worker: workerID)
                confirmed = true
                break
            } catch where isTransientConnectedFailure(error) {
                output.info("Retrying \(platform.rawValue) slot \(store.slot) cleanup in five seconds: \(describeError(error))")
                try stop.wait(for: 5)
            }
        }
    }
    if confirmation != nil && !confirmed { throw ConnectedRunnerError.confirmationMismatch }
}
