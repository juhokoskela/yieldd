import Foundation

struct RunnerAssignment {
    let routingLabel: String
    let pickupTimeout: TimeInterval

    init(routingLabel: String, pickupTimeout: TimeInterval = 5 * 60) throws {
        let suffix = routingLabel.dropFirst("yieldd-request-".count)
        guard routingLabel.hasPrefix("yieldd-request-"), !suffix.isEmpty,
              routingLabel.utf8.count <= 63,
              suffix.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw RunnerAssignmentError.invalidRoutingLabel
        }
        guard pickupTimeout.isFinite, pickupTimeout > 0 else {
            throw RunnerAssignmentError.invalidPickupTimeout
        }
        self.routingLabel = routingLabel
        self.pickupTimeout = pickupTimeout
    }
}

struct ReservedRunnerJob {
    let backend: any RunnerBackend
    let checkCancellation: () throws -> Void
    let wait: (TimeInterval) throws -> Void
    let stateChanged: (RunnerSessionState) -> Void
    var currentTime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func run(id: RunnerID, pickupTimeout: TimeInterval, executionTimeout: TimeInterval?) throws {
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
                throw jobStarted ? RunnerAssignmentError.executionTimedOut : RunnerAssignmentError.pickupTimedOut
            }
            let result = try backend.exec(
                ["yieldd-runner-control", "status"], timeout: min(10, remaining),
                outputCapture: .tail(maxBytes: 4096), as: .root, on: id
            )
            let status = try RunnerListenerStatus.decode(result.stdout)
            if status.jobStarted && !jobStarted {
                jobStarted = true
                deadline = executionTimeout.map { currentTime() + $0 } ?? .infinity
                stateChanged(.jobStarted(id))
            }
            if let exitStatus = status.exitStatus {
                stateChanged(.listenerExited(id, status: exitStatus))
                let replay: ProcessResult
                do {
                    replay = try backend.exec(
                        ["yieldd-runner-control", "run"], timeout: 30,
                        outputCapture: .tail(maxBytes: EphemeralRunnerSession.jobOutputTailBytes),
                        as: .root, on: id
                    )
                } catch let ProcessExecutionError.nonZeroExit(_, result) where result.terminationStatus == exitStatus {
                    replay = result
                }
                guard replay.terminationStatus == exitStatus else { throw RunnerAssignmentError.invalidStatus }
                guard exitStatus == 0 else {
                    let output = [replay.stdoutText, replay.stderrText]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    throw RunnerAssignmentError.listenerFailed(exitStatus, output: output)
                }
                guard jobStarted else { throw RunnerAssignmentError.exitedWithoutJob }
                return
            }
            if !status.jobStarted && jobStarted { throw RunnerAssignmentError.invalidStatus }
            try wait(min(0.5, max(0, deadline - currentTime())))
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
    case invalidRoutingLabel, invalidPickupTimeout, pickupTimedOut, executionTimedOut, startupTimedOut
    case invalidStatus, exitedWithoutJob, listenerFailed(Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .invalidRoutingLabel:
            "Routing labels must start with yieldd-request-, contain only lowercase letters, digits, and hyphens, and be at most 63 characters."
        case .invalidPickupTimeout: "The job pickup timeout must be greater than zero."
        case .pickupTimedOut: "Timed out waiting for the reserved job. This does not prove that the job never started."
        case .executionTimedOut: "The reserved job exceeded its execution timeout."
        case .startupTimedOut: "Runner startup exceeded its ten-minute timeout."
        case .invalidStatus: "The guest returned invalid runner lifecycle status. Update the guest scripts before retrying."
        case .exitedWithoutJob: "The runner exited without reporting a job start."
        case let .listenerFailed(status, output):
            output.isEmpty
                ? "The runner listener exited with status \(status)."
                : "The runner listener exited with status \(status): \(terminalSafeOutput(output))"
        }
    }
}
