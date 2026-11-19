import Darwin
import Foundation
import Synchronization
import Testing
@testable import Yieldd

@Test(.enabled(if: ProcessInfo.processInfo.environment["YIELDD_TEST_COORDINATOR"] != nil))
func connectedSwiftClientUsesGoRouterAcrossPlatformsAndWorkers() throws {
    let executable = try #require(ProcessInfo.processInfo.environment["YIELDD_TEST_COORDINATOR"])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-test.run", "^TestSwiftClientProtocolFixture$", "-test.timeout", "30s"]
    process.environment = ["YIELDD_SWIFT_PROTOCOL_FIXTURE": "1"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + 5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            #expect(exited.wait(timeout: .now() + 5) == .success)
            Issue.record("Coordinator fixture failed to stop after ownership EOF")
        }
        #expect(process.terminationStatus == 0)
    }
    let endpoint = Mutex<Data?>(nil)
    let ready = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        endpoint.withLock { $0 = output.fileHandleForReading.readDataToEndOfFile() }
        ready.signal()
    }
    try #require(ready.wait(timeout: .now() + 5) == .success)
    let data = try #require(endpoint.withLock { $0 })
    let origin = try #require(String(data: data, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
    let server = try ConnectedHTTPClient.serverURL(origin)
    var active: [(ConnectedHTTPClient, ConnectedOffer)] = []
    for platform in [RunnerPlatform.linux, .macOS] {
        for slot in 0..<2 {
            let client = ConnectedHTTPClient(server: server, deviceID: "01234567-89ab-4def-8123-456789abcdef",
                token: String(repeating: "x", count: 32), platform: platform, slot: slot, checkCancellation: {})
            let offer = try #require(try client.poll())
            #expect(offer.runnerPlatform == platform && offer.slot == slot)
            #expect(!active.contains { $0.1.owner == offer.owner || $0.1.runner == offer.runner })
            #expect(try client.accept(offer) == "private-jit")
            active.append((client, offer))
        }
    }
    #expect(active.count == 4)
    for (client, offer) in active {
        #expect(try client.renew(offer, checkDeadline: {}) == true)
    }
    try active[0].0.complete(active[0].1)
    #expect(try active[0].0.renew(active[0].1, checkDeadline: {}) == false)
    for (client, offer) in active.dropFirst() {
        #expect(try client.renew(offer, checkDeadline: {}) == true)
        try client.complete(offer)
    }
    try active[0].0.complete(active[0].1)
    let declined = try #require(try active[0].0.poll())
    try active[0].0.decline(declined)
    #expect(throws: ConnectedRunnerError.http(410, request: "POST /v1/accept (linux ARM64 slot 0)",
        reason: "offer is no longer available; clean up without starting a runner")) { try active[0].0.accept(declined) }
}
