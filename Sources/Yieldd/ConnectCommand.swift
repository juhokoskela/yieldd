import ArgumentParser
import Foundation

struct ConnectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "connect", abstract: "Offer one Linux ARM64 container slot to a coordinator.")

    @Option(name: .long, help: "Coordinator HTTPS origin. Loopback HTTP is allowed for local tests.")
    var server: String

    @Option(name: .long, help: "Lowercase device UUID configured on the coordinator.")
    var deviceID: String

    mutating func validate() throws {
        _ = try ConnectedHTTPClient.serverURL(server)
        guard UUID(uuidString: deviceID)?.uuidString.lowercased() == deviceID else {
            throw ValidationError("--device-id must be a lowercase UUID.")
        }
    }

    mutating func run() throws {
        let serverURL = try ConnectedHTTPClient.serverURL(server)
        let token = ProcessInfo.processInfo.environment["YIELDD_CLIENT_TOKEN"] ?? ""
        try ConnectedHTTPClient.validateToken(token)
        #if !arch(arm64)
        throw ValidationError("Connected Linux execution requires an Apple Silicon Mac.")
        #endif
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
            try memory.validateCapacity(reserving: RunnerPlatform.linux.memoryReservationBytes)
            let client = ConnectedHTTPClient(server: serverURL, deviceID: deviceID, token: token, checkCancellation: signals.check)
            let runner = ConnectedRunner(backend: backend, store: ConnectedRunnerStore(directory: leaseStore.directory),
                server: serverURL.absoluteString, deviceID: deviceID, accept: client.accept, complete: client.complete,
                checkCancellation: signals.check, wait: signals.wait,
                stateChanged: { reportRunnerServiceState($0, platform: .linux, output: .terminal) })
            try AppleContainerSystem(containerURL: container, executor: executor).start()
            try runner.recover()
            print("Connected Linux ARM64 slot ready. No guest is started until an offer is accepted.")
            while true {
                try signals.check()
                let reservation = try memory.acquire(reserving: RunnerPlatform.linux.memoryReservationBytes, checkCancellation: signals.check)
                let offer: ConnectedOffer?
                do {
                    offer = try client.poll()
                } catch let error as ConnectedRunnerError where error == .transport || error == .http(503) {
                    memory.release(reservation)
                    try signals.wait(for: 5)
                    continue
                }
                if let offer {
                    print("Accepting local runner \(offer.runner) for \(offer.repository).")
                    try runner.run(offer, memory: reservation.allocation)
                }
                memory.release(reservation)
            }
        }
    }
}
