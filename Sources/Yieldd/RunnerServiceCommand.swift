import ArgumentParser
import Foundation

struct RunnerServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Continuously run one ephemeral GitHub Actions runner at a time."
    )

    @Argument(help: "Repository in owner/name form.")
    var repository: String

    mutating func run() throws {
        let repository = try GitHubRepository(repository)
        let signalMonitor = try SignalMonitor()
        let locator = ExecutableLocator()
        let executor = ProcessExecutor(checkCancellation: signalMonitor.check)
        let backend = AppleContainerBackend(
            containerURL: try locator.locate("container"),
            executor: executor
        )
        let github = GitHubRunnerClient(
            ghURL: try locator.locate("gh"),
            executor: executor
        )
        let sessionStateChanged: (RunnerSessionState) -> Void = { state in
            switch state {
            case let .preparing(id):
                print("Preparing ephemeral runner \(id.value).")
            case let .waitingForJob(id):
                print("Runner \(id.value) is waiting for one job labeled 'yieldd'.")
            case let .cleaningUp(id):
                print("Cleaning up runner \(id.value).")
            }
        }
        let session = EphemeralRunnerSession(
            backend: backend,
            github: github,
            checkCancellation: signalMonitor.check,
            stateChanged: sessionStateChanged
        )

        print("Serving ephemeral runners for \(repository.fullName). Press Ctrl+C to stop.")
        try RunnerService(
            session: session,
            makeRunnerID: {
                RunnerID(value: "yieldd-\(UUID().uuidString.lowercased())")
            },
            checkForStop: signalMonitor.check,
            waitUntilStopped: signalMonitor.wait,
            stateChanged: { state in
                switch state {
                case let .backingOff(failures, delay):
                    let unit = delay == 1 ? "second" : "seconds"
                    print("Runner session failed \(failures) time(s); retrying in \(Int(delay)) \(unit).")
                case .stopping:
                    print("Stopping yieldd.")
                }
            },
            sessionFailed: { error in
                if !isCancellation(error) {
                    writeToStandardError("Runner session failed: \(describe(error))\n")
                }
            }
        ).run(repository: repository)
    }
}

private func isCancellation(_ error: any Error) -> Bool {
    if error is SignalInterruption {
        return true
    }
    if case ProcessExecutionError.cancelled = error {
        return true
    }
    return false
}

private func describe(_ error: any Error) -> String {
    if let localizedError = error as? any LocalizedError,
       let description = localizedError.errorDescription {
        return description
    }
    return String(describing: error)
}

private func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}
