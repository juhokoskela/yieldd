import Foundation

func recoverConnectedPlatforms(
    directory: URL, server: URL, deviceID: String, token: String,
    confirmation: String?, stop: RunnerPoolStop,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil
) throws {
    var confirmed = false
    for store in ConnectedRunnerStore.all(in: directory) {
        let platform = store.platform
        guard let lease = try store.load() else { continue }
        if let confirmation, lease.offer.runner != confirmation { continue }
        let client = ConnectedHTTPClient(server: server, deviceID: deviceID, token: token,
                                         platform: platform, slot: store.slot, checkCancellation: stop.check)
        while true {
            try stop.check()
            do {
                try recoverConnectedRunner(store: store, server: server.absoluteString, deviceID: deviceID,
                    confirmRegistrationRemoved: confirmation, destroy: { id in
                        switch platform {
                        case .macOS:
                            try removeMacOSRunnerFiles(id, in: directory, makeCloneStore: makeCloneStore)
                        case .linux:
                            let container = try ExecutableLocator().locate("container")
                            let executor = ProcessExecutor(checkCancellation: stop.check)
                            try AppleContainerSystem(containerURL: container, executor: executor, stateDirectory: directory).start()
                            try AppleContainerBackend(containerURL: container, executor: executor, stateDirectory: directory).destroy(id)
                        }
                    }, complete: client.complete)
                confirmed = true
                break
            } catch where isTransientConnectedFailure(error) {
                print("Retrying \(platform.rawValue) slot \(store.slot) cleanup in five seconds: \(describeError(error))")
                try stop.wait(for: 5)
            }
        }
    }
    if confirmation != nil && !confirmed { throw ConnectedRunnerError.confirmationMismatch }
}
