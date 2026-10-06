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

    func prepend(_ results: [ProcessResult]) { outcomes.insert(contentsOf: results.map(Result.success), at: 0) }
    func clearRequests() { requests.removeAll() }
}

final class LinuxTestRelay: RunnerNetworkRelaying {
    let socketURL = URL(fileURLWithPath: "/private/test-relay/n")
    var sshSocketURL: URL { socketURL.appendingPathExtension("ssh") }
    var isRunning = true
    var stopFailure: (any Error)?
    var stopDeadline: DispatchTime?
    func check() throws { if !isRunning { throw TestFailure.cancelled } }
    func stop(deadline: DispatchTime?) throws {
        stopDeadline = deadline
        if let stopFailure { throw stopFailure }
        isRunning = false
    }
}

struct LinuxTestNetwork: RunnerNetworking {
    let relay: LinuxTestRelay
    init(relay: LinuxTestRelay = LinuxTestRelay()) { self.relay = relay }
    func start(for id: RunnerID, checkCancellation: () throws -> Void) throws -> any RunnerNetworkRelaying {
        try checkCancellation()
        return relay
    }
}

func linuxInspection(id: RunnerID) -> ProcessResult {
    processResult(stdout: "[{\"id\":\"\(id.value)\",\"homeMount\":\"none\",\"networkSocket\":\"/private/test-relay/n\"}]")
}

func readyLinuxBackend(executor: RecordingProcessExecutor, containerURL: URL, id: RunnerID) throws -> AppleContainerBackend {
    executor.prepend([processResult(), linuxInspection(id: id), processResult(), processResult()])
    let backend = AppleContainerBackend(containerURL: containerURL, executor: executor,
        stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { nil }, network: LinuxTestNetwork())
    try backend.create(id: id, memory: .full)
    executor.clearRequests()
    return backend
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
