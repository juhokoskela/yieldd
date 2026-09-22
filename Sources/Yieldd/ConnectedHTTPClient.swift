import Foundation

final class ConnectedHTTPClient {
    let server: URL
    let deviceID: String
    let token: String
    let checkCancellation: () throws -> Void
    let platform: RunnerPlatform
    let slot: Int
    private let session: URLSession

    init(server: URL, deviceID: String, token: String, platform: RunnerPlatform = .linux, slot: Int = 0, checkCancellation: @escaping () throws -> Void) {
        self.server = server
        self.deviceID = deviceID
        self.token = token
        self.platform = platform
        self.slot = slot
        self.checkCancellation = checkCancellation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 65
        configuration.timeoutIntervalForResource = 70
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    static func serverURL(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value) else { throw ConnectedRunnerError.invalidServer }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.port == (components.scheme == "https" ? 443 : 80) { components.port = nil }
        guard let url = components.url, let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw ConnectedRunnerError.invalidServer
        }
        return url.appendingPathComponent("")
    }

    static func validateToken(_ token: String) throws {
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ConnectedRunnerError.invalidToken
        }
    }

    func poll() throws -> ConnectedOffer? {
        let (status, data) = try request("poll", offer: nil, checkCancellation: checkCancellation)
        if status == 204 { return nil }
        let offer = try JSONDecoder().decode(ConnectedOffer.self, from: data)
        guard offer.runnerPlatform == platform, offer.slot == slot else { throw ConnectedRunnerError.invalidOffer }
        return offer
    }

    func accept(_ offer: ConnectedOffer) throws -> String {
        struct Credential: Decodable { let jit: String }
        let (_, data) = try request("accept", offer: offer, checkCancellation: checkCancellation)
        return try JSONDecoder().decode(Credential.self, from: data).jit
    }

    func complete(_ offer: ConnectedOffer) throws {
        _ = try request("complete", offer: offer, checkCancellation: {})
    }

    func decline(_ offer: ConnectedOffer) throws {
        _ = try request("decline", offer: offer, checkCancellation: checkCancellation)
    }

    func renew(_ offer: ConnectedOffer, checkDeadline: () throws -> Void) throws -> Bool {
        struct Authorization: Decodable { let `continue`: Bool }
        let (_, data) = try request("renew", offer: offer, checkCancellation: {
            try self.checkCancellation()
            try checkDeadline()
        })
        return try JSONDecoder().decode(Authorization.self, from: data).continue
    }

    private func request(_ action: String, offer: ConnectedOffer?, checkCancellation check: () throws -> Void) throws -> (Int, Data) {
        try check()
        if let offer, offer.runnerPlatform != platform || offer.slot != slot { throw ConnectedRunnerError.invalidOffer }
        struct Body: Encodable {
            let deviceID: String
            let slot: Int
            let owner: String?
            let runner: String?

            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case slot, owner, runner
            }
        }
        let body = Body(deviceID: deviceID, slot: slot, owner: offer?.owner, runner: offer?.runner)
        let path = platform == .linux ? "v1/\(action)" : "v1/macos/\(action)"
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = ConnectedHTTPResponse()
        let task = session.dataTask(with: request)
        task.delegate = response
        defer { task.cancel() }
        task.resume()
        while response.completed.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            try check()
        }
        try check()
        let (status, data) = try response.result()
        guard status == 200 || (action == "poll" && status == 204) else {
            throw ConnectedRunnerError.http(status)
        }
        return (status, data)
    }
}

// URLSession callbacks and the synchronous command share only lock-protected response state.
private final class ConnectedHTTPResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    private var status = 0
    private var failure: ConnectedRunnerError?
    private static let maximumBytes = 2 * 1_024 * 1_024

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allowed = lock.withLock {
            guard let http = response as? HTTPURLResponse else { failure = .transport; return false }
            status = http.statusCode
            guard response.expectedContentLength <= Self.maximumBytes else { failure = .responseTooLarge; return false }
            return true
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        let allowed = lock.withLock {
            guard data.count + bytes.count <= Self.maximumBytes else { failure = .responseTooLarge; return false }
            data.append(bytes)
            return true
        }
        if !allowed { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.withLock { if error != nil, failure == nil { failure = .transport } }
        completed.signal()
    }

    func result() throws -> (Int, Data) {
        try lock.withLock {
            if let failure { throw failure }
            return (status, data)
        }
    }
}
