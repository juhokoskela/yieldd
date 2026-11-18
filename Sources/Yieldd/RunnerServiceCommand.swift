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

func validateRunnerServiceTemplate(_ templateURL: URL, stateDirectory: URL) throws {
    try RunnerStorage.required(in: stateDirectory).validateTemplateLocation(templateURL)
    try MacOSVirtualizationBackend.validateTemplate(at: templateURL)
}

func reportRunnerServiceState(_ state: RunnerSessionState, output: RunnerServiceOutput) {
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
    }
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
