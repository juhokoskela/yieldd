import Foundation
@testable import Yieldd

// Mock Container invocations must not consult the developer's real storage binding.
let unconfiguredContainerStateDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("yieldd-unconfigured-\(UUID().uuidString)")

func testCloneStores(in directory: URL) -> (RunnerCloneKind) -> MacOSRunnerCloneStore {
    { MacOSRunnerCloneStore(rootURL: directory.appendingPathComponent($0.rawValue)) }
}

func saveTestStorageBinding(in directory: URL) throws {
    try RunnerStorage(volumePath: directory.resolvingSymlinksInPath().path, volumeUUID: UUID().uuidString).save(in: directory)
}

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

    func clearRequests() { requests.removeAll() }
}

final class BackendRelay: RunnerNetworkRelaying {
    static let socket = URL(fileURLWithPath: "/unused/network.sock")
    let socketURL = socket
    let sshSocketURL = socket.appendingPathExtension("ssh")
    var failure: (any Error)?
    var stopFailure: (any Error)?
    var stops = 0
    var stopDeadline: DispatchTime?
    var isRunning: Bool { failure == nil && !stopped }
    private var stopped = false
    func check() throws {
        if let failure { throw failure }
        if stopped { throw RunnerNetworkRelayError.exited(status: 0) }
    }
    func stop(deadline: DispatchTime?) throws {
        stops += 1
        stopDeadline = deadline
        if let stopFailure { throw stopFailure }
        stopped = true
    }
}

final class BackendNetwork: RunnerNetworking {
    var startError: (any Error)?
    var relays: [BackendRelay] = []
    var relayFailure: (any Error)?
    var relayStopFailure: (any Error)?
    private let fixedRelay: BackendRelay?
    init(relay: BackendRelay? = nil) { fixedRelay = relay }
    func start(for id: RunnerID, checkCancellation: () throws -> Void) throws -> any RunnerNetworkRelaying {
        try checkCancellation()
        if let startError { throw startError }
        let relay = fixedRelay ?? BackendRelay()
        relays.append(relay)
        if let relayFailure { relay.failure = relayFailure }
        if let relayStopFailure { relay.stopFailure = relayStopFailure }
        return relay
    }
}

func linuxInspection(id: RunnerID) -> ProcessResult {
    processResult(stdout: "[{\"id\":\"\(id.value)\",\"homeMount\":\"none\",\"networkSocket\":\"\(BackendRelay.socket.path)\"}]")
}

func makeLinuxBackend(containerURL: URL = URL(fileURLWithPath: "/usr/local/bin/container"),
                      executor: any ProcessExecuting,
                      dockerReadiness: DockerReadiness = DockerReadiness()) throws -> AppleContainerBackend {
    try AppleContainerBackend(containerURL: containerURL, executor: executor,
        stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil }, network: BackendNetwork(),
        dockerReadiness: dockerReadiness)
}

func readyLinuxBackend(outcomes: [Result<ProcessResult, any Error>], containerURL: URL, id: RunnerID) throws
    -> (backend: AppleContainerBackend, executor: RecordingProcessExecutor) {
    let executor = RecordingProcessExecutor(outcomes:
        [processResult(), linuxInspection(id: id), processResult(), processResult(), processResult()].map(Result.success) + outcomes)
    let backend = try makeLinuxBackend(containerURL: containerURL, executor: executor)
    try backend.create(id: id, memory: .full)
    executor.clearRequests()
    return (backend, executor)
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
