import Foundation
import Network
import Synchronization
import Testing
@testable import Yieldd

@Test(arguments: [0, 2, 15])
func connectedHTTPUsesBearerAuthenticationAndWireIdentity(slot: Int) throws {
    let body = """
        {"slot":\(slot),"owner":"01234567-89ab-4def-8123-456789abcdef","runner":"yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef","repository":"owner/repo","platform":"linux","architecture":"arm64"}
        """
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let original = server.client
    let client = ConnectedHTTPClient(server: original.server, deviceID: original.deviceID, token: original.token,
                                     slot: slot, checkCancellation: {})
    let offer = try #require(try client.poll())
    #expect(offer.repository == "owner/repo")
    #expect(offer.slot == slot)
    let request = server.request
    #expect(request.lowercased().contains("authorization: bearer " + server.token))
    #expect(request.contains("POST /v1/poll HTTP/1.1"))
    #expect(request.contains(#""device_id":"01234567-89ab-4def-8123-456789abcdef""#))
    #expect(request.contains("\"slot\":\(slot)"))
}

@Test
func connectedHTTPRejectsAnotherWorkersOfferBeforeSendingCredentialsOrCleanup() throws {
    let body = #"{"slot":1,"owner":"01234567-89ab-4def-8123-456789abcdef","runner":"yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef","repository":"owner/repo","platform":"linux","architecture":"arm64"}"#
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let client = server.client
    #expect(throws: ConnectedRunnerError.invalidOffer) { try client.poll() }
    let offer = try JSONDecoder().decode(ConnectedOffer.self, from: Data(body.utf8))
    for action in ["accept", "renew", "complete"] {
        #expect(throws: ConnectedRunnerError.invalidOffer) {
            switch action {
            case "accept": _ = try client.accept(offer)
            case "renew": _ = try client.renew(offer, checkDeadline: {})
            default: try client.complete(offer)
            }
        }
        #expect(server.request.contains("POST /v1/poll HTTP/1.1"))
    }
}

@Test(arguments: [false, true])
func connectedHTTPRoutesMacOSAndRejectsLinuxOffers(wrongPlatform: Bool) throws {
    let platform = wrongPlatform ? "linux" : "macos"
    let body = """
        {"slot":0,"owner":"01234567-89ab-4def-8123-456789abcdef","runner":"yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef","repository":"owner/repo","platform":"\(platform)","architecture":"arm64"}
        """
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let original = server.client
    let client = ConnectedHTTPClient(server: original.server, deviceID: original.deviceID,
        token: original.token, platform: .macOS, checkCancellation: {})
    if wrongPlatform {
        #expect(throws: ConnectedRunnerError.invalidOffer) { try client.poll() }
    } else {
        #expect(try client.poll()?.runnerPlatform == .macOS)
    }
    #expect(server.request.contains("POST /v1/macos/poll HTTP/1.1"))
}

@Test(arguments: [302, 401, 503])
func connectedHTTPRejectsRedirectsAndErrorsWithoutLeakingBodies(_ status: Int) throws {
    let body = "private-jit secret-token"
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 \(status) Error\r\nLocation: http://127.0.0.1:1/stolen\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    do {
        _ = try server.client.poll()
        Issue.record("Expected HTTP rejection")
    } catch {
        #expect(error as? ConnectedRunnerError == .http(status, request: "POST /v1/poll (linux ARM64 slot 0)"))
        #expect(isTransientConnectedFailure(error) == (status == 503))
        #expect(!describeError(error).contains("private-jit"))
        #expect(!describeError(error).contains("secret-token"))
    }
}

@Test(arguments: [
    "",
    #"{"jit":"private-jit","token":"secret-token"}"#,
    "<html>proxy error: private-jit secret-token</html>",
    "one poll per worker slot\nprivate-jit secret-token",
    "one poll per worker slot\u{1b}[2J",
    String(repeating: " ", count: 512) + "one poll per worker slot",
])
func connectedHTTPOmitsUnexpectedResponseBodies(_ body: String) throws {
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 409 Conflict\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    #expect(throws: ConnectedRunnerError.http(409, request: "POST /v1/poll (linux ARM64 slot 0)")) {
        try server.client.poll()
    }
}

@Test(arguments: [RunnerPlatform.linux, .macOS], ["poll", "accept", "decline", "complete", "renew"])
func connectedHTTPErrorsIdentifyTheRequestAndCoordinatorReason(_ platform: RunnerPlatform, action: String) throws {
    let reason = action == "poll" ? "one poll per worker slot" : "coordinator queue identity does not match; retain local recovery state"
    let body = "\(reason)\n"
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 409 Conflict\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let original = server.client
    let client = ConnectedHTTPClient(server: original.server, deviceID: original.deviceID,
        token: original.token, platform: platform, slot: 2, checkCancellation: {})
    let offer = try ConnectedOffer(owner: client.deviceID,
        runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo",
        platform: platform == .linux ? "linux" : "macos", architecture: "arm64", slot: 2)
    do {
        switch action {
        case "poll": _ = try client.poll()
        case "accept": _ = try client.accept(offer)
        case "decline": try client.decline(offer)
        case "complete": try client.complete(offer)
        default: _ = try client.renew(offer, checkDeadline: {})
        }
        Issue.record("Expected HTTP rejection")
    } catch {
        let prefix = platform == .linux ? "/v1/" : "/v1/macos/"
        #expect(describeError(error) == "The coordinator returned HTTP 409 for POST \(prefix)\(action) (\(platform.rawValue) ARM64 slot 2): \(reason). Any unacknowledged cleanup remains in the local journal.")
        #expect(isTransientConnectedFailure(error) == (action == "poll"))
        #expect(!describeError(error).contains(server.token))
    }
}

@Test
func connectedHTTPReusesTheClientForIndependentResponses() throws {
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
    defer { server.close() }
    let client = server.client
    #expect(try client.poll() == nil)
    #expect(try client.poll() == nil)
}

@Test
func connectedHTTPBoundsResponsesWithoutTrustingContentLength() throws {
    let body = String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    #expect(throws: ConnectedRunnerError.responseTooLarge) { try server.client.poll() }
}

@Test
func connectedHTTPStopsLongPollOnCancellation() throws {
    let server = try ConnectedHTTPFixture(response: nil)
    defer { server.close() }
    var client = server.client
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    client = ConnectedHTTPClient(server: client.server, deviceID: client.deviceID, token: client.token, checkCancellation: {
        if !server.request.isEmpty { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw TestFailure.runnerJob }
    })
    #expect(throws: CancellationError.self) { try client.poll() }
}

@Test(arguments: [true, false])
func connectedRenewalRequiresExplicitFinalSuccess(_ success: Bool) throws {
    let body = success ? #"{"continue":false,"job_succeeded":true}"# : #"{"continue":false}"#
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let offer = try ConnectedOffer(owner: UUID().uuidString.lowercased(), runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())",
        repository: "owner/repo", platform: "linux", architecture: "arm64")
    #expect(try server.client.renew(offer, checkDeadline: {}) == (success ? .jobSucceeded : .revoked))
}

@Test(arguments: [FinalJobResult.pending, .succeeded, .unavailable])
func connectedFinalResultUsesDedicatedEndpoint(_ result: FinalJobResult) throws {
    let body = #"{"result":"\#(result.rawValue)"}"#
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let offer = try ConnectedOffer(owner: UUID().uuidString.lowercased(), runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())",
        repository: "owner/repo", platform: "linux", architecture: "arm64")
    #expect(try server.client.jobResult(offer, checkDeadline: {}) == result)
    #expect(server.request.contains("POST /v1/job-result HTTP/1.1"))
}

@Test(arguments: [RunnerPlatform.linux, .macOS], [0, 2, 15])
func connectedHTTPPreservesEachRepositoryQueueIdentity(_ platform: RunnerPlatform, slot: Int) throws {
    let body = #"{"jit":"fixture","continue":true}"#
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let original = server.client
    let client = ConnectedHTTPClient(server: original.server, deviceID: original.deviceID,
        token: original.token, platform: platform, slot: slot, checkCancellation: {})
    for repository in ["owner/first", "owner/second"] {
        let offer = try ConnectedOffer(owner: UUID().uuidString.lowercased(),
            runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())", repository: repository,
            platform: platform == .linux ? "linux" : "macos", architecture: "arm64", slot: slot)
        for action in ["accept", "renew", "complete", "decline"] {
            switch action {
            case "accept": #expect(try client.accept(offer) == "fixture")
            case "renew": #expect(try client.renew(offer, checkDeadline: {}) == .active)
            case "decline": try client.decline(offer)
            default: try client.complete(offer)
            }
            let request = server.request
            let separator = try #require(request.range(of: "\r\n\r\n"))
            let identity = try #require(JSONSerialization.jsonObject(with: Data(request[separator.upperBound...].utf8)) as? [String: Any])
            #expect(Set(identity.keys) == ["device_id", "slot", "owner", "runner"])
            #expect(identity["device_id"] as? String == client.deviceID)
            #expect(identity["owner"] as? String == offer.owner)
            #expect(identity["runner"] as? String == offer.runner)
            #expect(identity["slot"] as? Int == client.slot)
            let prefix = platform == .linux ? "/v1/" : "/v1/macos/"
            #expect(request.contains("POST \(prefix)\(action) HTTP/1.1"))
        }
    }
}

@Test(arguments: [RunnerPlatform.linux, .macOS])
func connectedHTTPAuthorizationUsesIdentityAndDeadline(_ platform: RunnerPlatform) throws {
    let body = #"{"continue":true}"#
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let client = ConnectedHTTPClient(server: server.client.server, deviceID: server.client.deviceID,
        token: server.token, platform: platform, checkCancellation: {})
    let offer = try ConnectedOffer(owner: client.deviceID, runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef",
        repository: "owner/repo", platform: platform == .linux ? "linux" : "macos", architecture: "arm64")
    #expect(try client.renew(offer, checkDeadline: {}) == .active)
    #expect(server.request.contains(platform == .linux ? "POST /v1/renew " : "POST /v1/macos/renew "))
    #expect(server.request.contains(offer.runner))
    #expect(server.request.contains(offer.owner))
    #expect(throws: ConnectedExecutionError.expired) {
        try client.renew(offer, checkDeadline: { throw ConnectedExecutionError.expired })
    }
}

// The serial network queue owns connections. A lock protects snapshots read by synchronous tests.
private final class ConnectedHTTPFixture: @unchecked Sendable {
    let token = String(repeating: "x", count: 32)
    private let queue = DispatchQueue(label: "yieldd.connected-http-test")
    private let listener: NWListener
    private let lock = NSLock()
    private var received = ""
    private var connections: [NWConnection] = []
    var request: String { lock.withLock { received } }
    var client: ConnectedHTTPClient {
        ConnectedHTTPClient(server: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!,
            deviceID: "01234567-89ab-4def-8123-456789abcdef", token: token, checkCancellation: {})
    }

    convenience init(response: String?) throws {
        try self.init(respond: { _ in response })
    }

    init(respond: @escaping @Sendable (String) -> String?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data(), respond: respond)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw TestFailure.create
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data, respond: @escaping @Sendable (String) -> String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self, error == nil else { connection.cancel(); return }
            let combined = accumulated + (data ?? Data())
            guard combined.count <= 16384 else { connection.cancel(); return }
            let text = String(decoding: combined, as: UTF8.self)
            guard let separator = text.range(of: "\r\n\r\n") else {
                if !ended { self.receive(connection, accumulated: combined, respond: respond) }
                return
            }
            let headers = String(text[..<separator.lowerBound])
            let length = headers.components(separatedBy: "\r\n").compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            if text[separator.upperBound...].utf8.count < length, !ended {
                self.receive(connection, accumulated: combined, respond: respond)
                return
            }
            self.lock.withLock { self.received = text }
            if let response = respond(text) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func close() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.cancel() }
        }
    }
}

@Test(arguments: [false, true])
func connectedCleanupHonorsShutdownDeadlineWithoutCancellingEarlyCleanup(expired: Bool) throws {
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    defer { server.close() }
    let original = server.client
    let client = ConnectedHTTPClient(server: original.server, deviceID: original.deviceID, token: original.token,
        checkCancellation: { throw CancellationError() },
        maximumExecutionDeadline: { expired ? .now() - .seconds(1) : nil })
    let offer = try ConnectedOffer(owner: client.deviceID,
        runner: "yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef", repository: "owner/repo", platform: "linux", architecture: "arm64")
    if expired {
        #expect(throws: CancellationError.self) { try client.complete(offer) }
    } else {
        try client.complete(offer)
        #expect(server.request.contains("POST /v1/complete HTTP/1.1"))
    }
}

@Test(arguments: [204, 503, 401, 410])
func connectedHTTPReportsLastContactAndFailureWithoutResponseBodies(status: Int) throws {
    let body = status == 204 ? "" : "private-token private-jit"
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 \(status) Response\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let original = server.client
    var states: [AgentConnectionState] = []
    var failures: [String] = []
    let client = ConnectedHTTPClient(server: original.server, deviceID: original.deviceID, token: original.token,
        checkCancellation: {}, connectionChanged: { state, error in
            states.append(state)
            if let error { failures.append(error) }
        })
    if status == 204 { _ = try client.poll() }
    else { #expect(throws: ConnectedRunnerError.self) { try client.poll() } }
    #expect(states == [status == 204 || status == 410 ? .connected : status == 503 ? .retrying : .failed])
    #expect(!failures.joined().contains("private-token"))
    #expect(!failures.joined().contains("private-jit"))
}

@Test(arguments: [0, 1])
func startupRecoveryReportsCompletedWorkersAndTheRemainingRetry(failedSlot: Int) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-status-\(UUID().uuidString)")
    _ = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = ConnectedAgentControl(directory: directory)
    let stop = RunnerPoolStop()
    let server = try ConnectedHTTPFixture(respond: { request in
        let status = request.contains("\"slot\":\(failedSlot)") ? 503 : 200
        return "HTTP/1.1 \(status) Response\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    })
    defer { server.close() }
    let client = server.client
    let clones = testCloneStores(in: directory)(.runners)
    var bundles: [URL] = []
    for slot in 0..<2 {
        let offer = try ConnectedOffer(owner: client.deviceID,
            runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())", repository: "owner/repo", platform: "macos", architecture: "arm64", slot: slot)
        let bundle = try clones.bundleURL(for: RunnerID(value: offer.runner))
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        bundles.append(bundle)
        try ConnectedRunnerStore(directory: directory, platform: .macOS, slot: slot)
            .save(ConnectedLease(server: client.server.absoluteString, deviceID: client.deviceID, offer: offer))
    }
    let recordedBundles = bundles
    let output = RunnerServiceOutput(info: { _ in
        #expect(recordedBundles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let snapshot = control.snapshot
        #expect(snapshot.phase == .recovering && !snapshot.ready)
        #expect(snapshot.activeAssignments == 2 - failedSlot)
        if failedSlot == 1 {
            #expect(snapshot.workers.first { $0.slot == 0 }?.runner == nil)
            #expect(snapshot.workers.first { $0.slot == 0 }?.lastContactAt != nil)
        }
        #expect(snapshot.workers.first { $0.slot == failedSlot }?.connection == .retrying)
        #expect(snapshot.lastError?.message.contains("503") == true)
        stop.request()
    }, warning: { _ in }, error: { _ in })
    #expect(throws: CancellationError.self) {
        try recoverConnectedPlatforms(directory: directory, server: client.server, deviceID: client.deviceID, token: client.token,
            confirmation: nil, stop: stop, makeCloneStore: testCloneStores(in: directory), output: output, control: control)
    }
    #expect(try (ConnectedRunnerStore(directory: directory, platform: .macOS, slot: 0).load() == nil) == (failedSlot == 1))
    #expect(try ConnectedRunnerStore(directory: directory, platform: .macOS, slot: 1).load() != nil)
}

@Test
func startupRecoveryRetriesHealthySlotDespiteIndependentFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    _ = try RunnerLeaseStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let attempts = Mutex(0)
    let server = try ConnectedHTTPFixture(respond: { _ in
        let status = attempts.withLock { $0 += 1; return $0 == 1 ? 503 : 200 }
        return "HTTP/1.1 \(status) Response\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    })
    defer { server.close() }
    let client = server.client
    for slot in 0..<2 {
        let offer = try ConnectedOffer(owner: client.deviceID,
            runner: "yieldd-bootstrap-\(UUID().uuidString.lowercased())", repository: "owner/repo", platform: "macos", architecture: "arm64", slot: slot)
        try ConnectedRunnerStore(directory: directory, platform: .macOS, slot: slot)
            .save(ConnectedLease(server: slot == 0 ? "https://old.example/" : client.server.absoluteString, deviceID: client.deviceID, offer: offer))
    }
    #expect(throws: ConnectedRunnerError.self) {
        try recoverConnectedPlatforms(directory: directory, server: client.server, deviceID: client.deviceID, token: client.token,
            confirmation: nil, stop: RunnerPoolStop(), makeCloneStore: testCloneStores(in: directory))
    }
    #expect(attempts.withLock { $0 } == 2)
    #expect(try ConnectedRunnerStore(directory: directory, platform: .macOS, slot: 0).load() != nil)
    #expect(try ConnectedRunnerStore(directory: directory, platform: .macOS, slot: 1).load() == nil)
}
