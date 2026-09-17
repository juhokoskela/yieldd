import ArgumentParser
import Foundation

struct ConnectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "connect", abstract: "Offer one Linux ARM64 container slot to a coordinator.")

    @Option(name: .long, help: "Coordinator HTTPS origin. Loopback HTTP is allowed for local tests.")
    var server: String

    @Option(name: .long, help: "Lowercase device UUID configured on the coordinator.")
    var deviceID: String

    @Option(name: .long, help: "After manually removing this exact GitHub runner registration, destroy its local guest, clear the matching journal, and exit. Use only when original coordinator recovery is impossible.")
    var confirmRegistrationRemoved: String?

    mutating func validate() throws {
        do { _ = try ConnectedHTTPClient.serverURL(server) } catch { throw ValidationError(describeError(error)) }
        guard UUID(uuidString: deviceID)?.uuidString.lowercased() == deviceID else {
            throw ValidationError("--device-id must be a lowercase UUID.")
        }
    }

    mutating func run() throws {
        let serverURL = try ConnectedHTTPClient.serverURL(server)
        let token = ProcessInfo.processInfo.environment["YIELDD_CLIENT_TOKEN"] ?? ""
        if confirmRegistrationRemoved == nil { try ConnectedHTTPClient.validateToken(token) }
        #if !arch(arm64)
        throw ValidationError("Connected Linux execution requires an Apple Silicon Mac.")
        #endif
        do {
            try withRunnerOwnership(connected: true) { leaseStore in
                guard try leaseStore.load().isEmpty else {
                    throw ValidationError("Run recover to clean up standalone runner leases before connecting.")
                }
                let signals = try SignalMonitor()
                let executor = ProcessExecutor(checkCancellation: signals.check)
                let container = try ExecutableLocator().locate("container")
                let backend = AppleContainerBackend(containerURL: container, executor: executor,
                    dockerReadiness: DockerReadiness(wait: signals.wait, checkCancellation: signals.check))
                let memory = RunnerMemoryAdmission()
                let client = ConnectedHTTPClient(server: serverURL, deviceID: deviceID, token: token, checkCancellation: signals.check)
                let runner = ConnectedRunner(backend: backend, store: ConnectedRunnerStore(directory: leaseStore.directory),
                    server: serverURL.absoluteString, deviceID: deviceID, accept: client.accept, complete: client.complete,
                    checkCancellation: signals.check, wait: signals.wait,
                    stateChanged: { reportRunnerServiceState($0, platform: .linux, output: .terminal) })
                try AppleContainerSystem(containerURL: container, executor: executor).start()
                if let confirmRegistrationRemoved {
                    try runner.recover(confirmRegistrationRemoved: confirmRegistrationRemoved)
                    print("Local guest destroyed and connected journal cleared after operator-confirmed registration removal.")
                    return
                }
                try memory.validateCapacity(reserving: RunnerPlatform.linux.memoryReservationBytes)
                print("Connecting one Linux ARM64 slot. Recovery must finish before new work is accepted.")
                try runConnectedClient(checkCancellation: signals.check, recover: {
                    try runner.recover()
                    print("Connected Linux ARM64 slot ready. No guest is started until an offer is accepted.")
                }, acquire: {
                    try memory.acquire(reserving: RunnerPlatform.linux.memoryReservationBytes, checkCancellation: signals.check,
                        onBlocked: { print("Waiting for host memory. Local capacity is not being advertised; hosted fallback remains available.") })
                }, release: memory.release, poll: client.poll, run: { offer, allocation, release in
                    print("Accepting local runner \(offer.runner) for \(offer.repository).")
                    try runner.run(offer, memory: allocation, releaseCapacity: release)
                }, wait: signals.wait, retrying: {
                    print("Coordinator request failed; retrying in five seconds. Outstanding cleanup must finish before new work.")
                })
            }
        } catch where isCancellation(error) {
            print("Stopped. Any unfinished connected assignment remains recorded for recovery.")
        }
    }
}
