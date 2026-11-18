import ArgumentParser
import Foundation

struct RunnerServiceOutput: Sendable {
    let info: @Sendable (String) -> Void
    let warning: @Sendable (String) -> Void
    let error: @Sendable (String) -> Void

    static let terminal = RunnerServiceOutput(
        info: { print($0) },
        warning: { writeToStandardError("Warning: \($0)\n") },
        error: { writeToStandardError("\($0)\n") }
    )
}

enum RunnerSlotBackend: Sendable {
    case linux(containerURL: URL)
    case macOS(templateURL: URL)

    var platform: RunnerPlatform {
        switch self {
        case .linux: .linux
        case .macOS: .macOS
        }
    }
}

func makeRunnerRecovery(
    leaseStore: RunnerLeaseStore,
    resolveContainer: @escaping () throws -> URL,
    ghURL: URL,
    stop: RunnerPoolStop,
    executor: any ProcessExecuting,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil,
    stateChanged: @escaping (RunnerSessionState) -> Void
) -> RunnerRecovery {
    return RunnerRecovery(
        linuxBackend: {
            try AppleContainerBackend(containerURL: try resolveContainer(), executor: executor, stateDirectory: leaseStore.directory)
        },
        github: GitHubRunnerClient(ghURL: ghURL, executor: executor),
        leaseStore: leaseStore,
        makeCloneStore: makeCloneStore,
        recoveryWait: stop.wait,
        checkCancellation: stop.check,
        stateChanged: stateChanged
    )
}

func validateRunnerServiceTemplate(_ templateURL: URL, stateDirectory: URL) throws {
    try RunnerStorage.required(in: stateDirectory).validateTemplateLocation(templateURL)
    try MacOSVirtualizationBackend.validateTemplate(at: templateURL)
}

func reportRunnerServiceState(_ state: RunnerSessionState, platform: RunnerPlatform, output: RunnerServiceOutput) {
    switch state {
    case let .listenerStarted(id):
        output.info("Runner listener \(id.value) started; waiting for job pickup.")
    case let .jobStarted(id):
        output.info("Runner \(id.value) reported job start.")
    case let .listenerExited(id, status):
        output.info("Runner listener \(id.value) exited with status \(status).")
    case let .executionStopped(id, reason):
        output.warning("Stopping runner \(id.value): \(reason)")
    case let .capacityReleased(id):
        output.info("Machine capacity released for \(id.value).")
    case let .cleanupCompleted(id):
        output.info("Runner cleanup completed for \(id.value).")
    case let .preparing(id):
        output.info("Preparing ephemeral runner \(id.value).")
    case let .waitingForMemory(id):
        output.info("Runner \(id.value) is waiting for available host memory.")
    case let .waitingForJob(id):
        output.info("Runner \(id.value) is waiting for one job labeled '\(platform.runnerLabel)'.")
    case .waitingForGitHubCleanup, .leaseCleanupFailed:
        reportRunnerRecoveryState(state, output: output)
    case let .cleaningUp(id):
        output.info("Cleaning up runner \(id.value).")
    }
}

func reportRunnerRecoveryState(_ state: RunnerSessionState, output: RunnerServiceOutput = .terminal) {
    switch state {
    case let .waitingForGitHubCleanup(id, retryDelay):
        output.info(githubCleanupRetryMessage(id: id, delay: retryDelay))
    case let .leaseCleanupFailed(id, reason):
        output.warning("Could not clear runner lease for \(id.value): \(reason)")
    case .waitingForMemory, .preparing, .waitingForJob, .cleaningUp,
         .listenerStarted, .jobStarted, .listenerExited, .executionStopped, .capacityReleased, .cleanupCompleted:
        break
    }
}

func githubCleanupRetryMessage(id: RunnerID, delay: TimeInterval) -> String {
    let unit = delay == 1 ? "second" : "seconds"
    return "GitHub still considers runner \(id.value) busy; retrying cleanup in \(Int(delay)) \(unit)."
}

func isCancellation(_ error: any Error) -> Bool {
    if error is SignalInterruption || error is CancellationError {
        return true
    }
    if let error = error as? ProcessExecutionError {
        switch error {
        case .cancelled, .executionDeadlineExceeded:
            return true
        default:
            break
        }
    }
    return false
}

func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}
