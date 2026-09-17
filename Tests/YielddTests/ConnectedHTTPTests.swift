import Foundation
import Network
import Testing
@testable import Yieldd

@Test
func connectedHTTPUsesBearerAuthenticationAndWireIdentity() throws {
    let body = #"{"owner":"01234567-89ab-4def-8123-456789abcdef","runner":"yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef","repository":"owner/repo","platform":"linux","architecture":"arm64"}"#
    let server = try ConnectedHTTPFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    defer { server.close() }
    let offer = try #require(try server.client.poll())
    #expect(offer.repository == "owner/repo")
    let request = server.request
    #expect(request.lowercased().contains("authorization: bearer " + server.token))
    #expect(request.contains("POST /v1/poll HTTP/1.1"))
    #expect(request.contains(#""device_id":"01234567-89ab-4def-8123-456789abcdef""#))
}

@Test(arguments: [false, true])
func connectedHTTPRoutesMacOSAndRejectsLinuxOffers(wrongPlatform: Bool) throws {
    let platform = wrongPlatform ? "linux" : "macos"
    let body = """
        {"owner":"01234567-89ab-4def-8123-456789abcdef","runner":"yieldd-bootstrap-01234567-89ab-4def-8123-456789abcdef","repository":"owner/repo","platform":"\(platform)","architecture":"arm64"}
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
        #expect(error as? ConnectedRunnerError == .http(status))
        #expect(!describeError(error).contains("private-jit"))
        #expect(!describeError(error).contains("secret-token"))
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

    init(response: String?) throws {
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
            self.receive(connection, accumulated: Data(), response: response)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw TestFailure.create
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data, response: String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self, error == nil else { connection.cancel(); return }
            let combined = accumulated + (data ?? Data())
            guard combined.count <= 16384 else { connection.cancel(); return }
            let text = String(decoding: combined, as: UTF8.self)
            guard let separator = text.range(of: "\r\n\r\n") else {
                if !ended { self.receive(connection, accumulated: combined, response: response) }
                return
            }
            let headers = String(text[..<separator.lowerBound])
            let length = headers.components(separatedBy: "\r\n").compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            if text[separator.upperBound...].utf8.count < length, !ended {
                self.receive(connection, accumulated: combined, response: response)
                return
            }
            self.lock.withLock { self.received = text }
            if let response {
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
