import Foundation
@testable import Yieldd

final class RecordingProcessExecutor: ProcessExecuting {
    private(set) var requests: [ProcessRequest] = []
    private var outcomes: [Result<ProcessResult, any Error>]

    init(outcomes: [Result<ProcessResult, any Error>]) {
        self.outcomes = outcomes
    }

    func execute(_ request: ProcessRequest) throws -> ProcessResult {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw TestFailure.unexpectedProcessRequest
        }
        return try outcomes.removeFirst().get()
    }
}

func processResult(
    stdout: String = "",
    stderr: String = "",
    status: Int32 = 0,
    reason: ProcessTerminationReason = .exit
) -> ProcessResult {
    ProcessResult(
        stdout: Data(stdout.utf8),
        stderr: Data(stderr.utf8),
        terminationReason: reason,
        terminationStatus: status
    )
}

enum TestFailure: Error, Equatable {
    case create
    case dockerInfo
    case helloWorld
    case runnerJob
    case registrationToken
    case cleanup
    case githubCleanup
    case machineCleanup
    case cancelled
    case unexpectedProcessRequest
    case unexpectedBackendCall
}
