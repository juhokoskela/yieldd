import Foundation

func recoverConnectedPlatforms(
    directory: URL, server: URL, deviceID: String, token: String,
    confirmation: String?, stop: RunnerPoolStop,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil
) throws {
    var confirmed = false
    for platform in [RunnerPlatform.macOS, .linux] {
        let store = ConnectedRunnerStore(directory: directory, platform: platform)
        guard let lease = try store.load() else { continue }
        if let confirmation, lease.offer.runner != confirmation { continue }
        let client = ConnectedHTTPClient(server: server, deviceID: deviceID, token: token,
                                         platform: platform, checkCancellation: stop.check)
        while true {
            try stop.check()
            do {
                try recoverConnectedRunner(store: store, server: server.absoluteString, deviceID: deviceID,
                    confirmRegistrationRemoved: confirmation, destroy: { id in
                        switch platform {
                        case .macOS:
                            let clones = try (makeCloneStore ?? { try MacOSRunnerCloneStore(stateDirectory: directory, kind: $0) })(.runners)
                            try clones.remove(id)
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
                print("Coordinator request failed; retrying in five seconds. Outstanding cleanup must finish before new work.")
                try stop.wait(for: 5)
            }
        }
    }
    if confirmation != nil && !confirmed { throw ConnectedRunnerError.confirmationMismatch }
}
