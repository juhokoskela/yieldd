import Foundation
@testable import Yieldd

// Mock Container invocations must not consult the developer's real storage binding.
let unconfiguredContainerStateDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("yieldd-unconfigured-\(UUID().uuidString)")

extension AgentConfiguration {
    init(
        repositories: [GitHubRepository], macOSRepositories: [GitHubRepository] = [],
        macOSTemplateURL: URL? = nil, containerURL: URL?, ghURL: URL
    ) throws {
        try self.init(
            runners: RunnerServiceConfiguration(
                repositories: repositories, macOSRepositories: macOSRepositories, macOSTemplateURL: macOSTemplateURL
            ), containerURL: containerURL, ghURL: ghURL
        )
    }
}

extension RunnerMemoryAdmission {
    func acquireWithoutWaiting(reserving bytes: UInt64) throws -> RunnerMemoryReservation {
        var blocked = false
        return try acquire(reserving: bytes, checkCancellation: {
            if blocked { throw TestFailure.memoryAllocation }
        }, onBlocked: { blocked = true })
    }
}

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
    reason: Process.TerminationReason = .exit
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
    case memoryAllocation
    case dockerInfo
    case helloWorld
    case runnerJob
    case runnerStop
    case runnerConfiguration
    case registrationToken
    case cleanup
    case githubCleanup
    case machineCleanup
    case cancelled
    case unexpectedProcessRequest
    case unexpectedBackendCall
}
