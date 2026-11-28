import Foundation

struct ReservedRunnerJob {
    let backend: any RunnerBackend
    let checkCancellation: () throws -> Void
    let wait: (TimeInterval) throws -> Void
    let stateChanged: (RunnerSessionState) -> Void
    var currentTime: () -> TimeInterval = continuousMonotonicSeconds

    func run(id: RunnerID, pickupTimeout: TimeInterval) throws {
        try checkCancellation()
        try backend.exec(["yieldd-runner-control", "start"], timeout: 30,
                         outputCapture: .tail(maxBytes: 4096), as: .root, on: id)
        stateChanged(.listenerStarted(id))
        var deadline = currentTime() + pickupTimeout
        var jobStarted = false
        while true {
            try checkCancellation()
            let remaining = deadline - currentTime()
            guard remaining > 0 else {
                throw RunnerAssignmentError.pickupTimedOut
            }
            let result = try backend.exec(
                ["yieldd-runner-control", "status"], timeout: min(10, remaining),
                outputCapture: .tail(maxBytes: 4096), as: .root, on: id
            )
            let status = try RunnerListenerStatus.decode(result.stdout)
            if status.jobStarted && !jobStarted {
                jobStarted = true
                deadline = .infinity
                stateChanged(.jobStarted(id))
            }
            if let exitStatus = status.exitStatus {
                stateChanged(.listenerExited(id, status: exitStatus))
                if exitStatus == 0 {
                    guard jobStarted else { throw RunnerAssignmentError.exitedWithoutJob }
                    return
                }
                let replay = try backend.exec(
                    ["yieldd-runner-control", "output"], timeout: 30,
                    outputCapture: .tail(maxBytes: 1_024 * 1_024),
                    as: .root, on: id
                )
                let output = [replay.stdoutText, replay.stderrText]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                throw RunnerAssignmentError.listenerFailed(exitStatus, output: output)
            }
            if !status.jobStarted && jobStarted { throw RunnerAssignmentError.invalidStatus }
            try wait(min(jobStarted ? 2 : 0.5, max(0, deadline - currentTime())))
        }
    }
}

private struct RunnerListenerStatus: Decodable {
    enum Phase: String, Decodable { case listening, exited }
    let phase: Phase
    let jobStarted: Bool
    let exitStatus: Int32?

    static func decode(_ data: Data) throws -> Self {
        guard let status = try? JSONDecoder().decode(Self.self, from: data) else {
            throw RunnerAssignmentError.invalidStatus
        }
        switch status.phase {
        case .listening:
            guard status.exitStatus == nil else { throw RunnerAssignmentError.invalidStatus }
        case .exited:
            guard let value = status.exitStatus, (0...255).contains(value) else {
                throw RunnerAssignmentError.invalidStatus
            }
        }
        return status
    }
}

enum RunnerAssignmentError: Error, Equatable, LocalizedError {
    case pickupTimedOut
    case invalidStatus, exitedWithoutJob, listenerFailed(Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .pickupTimedOut: "Timed out waiting for the reserved job. This does not prove that the job never started."
        case .invalidStatus: "The guest returned invalid runner lifecycle status. Update the guest scripts before retrying."
        case .exitedWithoutJob: "The runner exited without reporting a job start."
        case let .listenerFailed(status, output):
            output.isEmpty
                ? "The runner listener exited with status \(status)."
                : "The runner listener exited with status \(status): \(terminalSafeOutput(output))"
        }
    }
}
