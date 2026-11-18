import Foundation

protocol NativeCacheBackend: RunnerBackend {
    func prepareNativeCache(exchangeDirectory: URL, on id: RunnerID) throws
    func attachNativeCache(image: URL, cold: Bool, on id: RunnerID) throws
    func detachNativeCache(on id: RunnerID) throws
}

extension NativeCacheBackend {
    func prepareNativeCache(exchangeDirectory: URL, on id: RunnerID) throws {}
}

// Confined to the slot worker. Its relay writes verified requests in the private network
// directory. The writable directory exported to a Linux guest is on a different volume.
final class NativeCacheSession {
    private struct Grants: Decodable, Equatable {
        let repository_id: String
        let repository: String?
        let read_scopes: [String]
        let write_scope: String?
    }
    private struct Request: Decodable {
        enum Operation: String, Decodable { case open, save }
        let id: String
        let operation: Operation
        let grants: Grants
    }
    private struct Response: Encodable {
        let id: String
        var path: String?
        var error: String?
    }

    private enum State {
        case fresh
        case attached(Grants)
        case saveRequested(Grants)
        case sealed
    }

    private let id: RunnerID
    private let repository: String
    private let directory: URL
    private let backend: any NativeCacheBackend
    private let store: NativeCacheStore
    private var state = State.fresh
    private var lastRequest: String?

    init(store: NativeCacheStore, backend: any NativeCacheBackend, id: RunnerID, repository: String, directory: URL) {
        self.store = store
        self.backend = backend
        self.id = id
        self.repository = repository
        self.directory = directory
    }

    convenience init(store: NativeCacheStore, backend: any RunnerBackend, offer: ConnectedOffer, stateDirectory: URL) throws {
        guard let backend = backend as? any NativeCacheBackend else { throw NativeCacheSessionError.unsupported }
        let id = RunnerID(value: offer.runner)
        let control = try RunnerNetworkDirectories(stateDirectory: stateDirectory).directory(for: id)
        self.init(store: store, backend: backend, id: id, repository: offer.repository, directory: control)
    }

    func prepare() throws {
        guard backend.platform == .linux else { return }
        let job = try store.jobDirectory(id)
        try backend.prepareNativeCache(exchangeDirectory: job.appendingPathComponent("exchange"), on: id)
    }

    func handleRequest() throws {
        guard let bytes = try readPrivateRunnerFile(directory.appendingPathComponent("native-request"), maximumBytes: 32 * 1024) else { return }
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        guard request.id != lastRequest else { return }
        var response = Response(id: request.id)
        do {
            guard !request.grants.repository_id.isEmpty,
                  request.grants.repository.map({ $0.caseInsensitiveCompare(repository) == .orderedSame }) ?? true
            else { throw NativeCacheSessionError.inconsistentGrant }
            switch request.operation {
            case .open:
                switch state {
                case .attached(let grants) where grants == request.grants:
                    break
                case .fresh:
                    // The store refuses a second image once it has recorded this checkout,
                    // including when attachment allocated a device and subsequently failed.
                    let disk = try store.open(id, readable: request.grants.read_scopes, writable: request.grants.write_scope)
                    try backend.attachNativeCache(image: disk.url, cold: disk.isCold, on: id)
                    state = .attached(request.grants)
                default:
                    throw NativeCacheSessionError.inconsistentGrant
                }
                response.path = backend.platform == .macOS ? "/Volumes/YielddCache" : "/mnt/yieldd-cache"
            case .save:
                switch state {
                case let .attached(grants), let .saveRequested(grants):
                    guard grants == request.grants else { throw NativeCacheSessionError.inconsistentGrant }
                    if grants.write_scope != nil { state = .saveRequested(grants) }
                default:
                    throw NativeCacheSessionError.inconsistentGrant
                }
            }
        } catch {
            writeToStandardError("Native cache \(request.operation.rawValue) for \(id.value) failed: \(describeError(error))\n")
            response.error = "The runner could not \(request.operation.rawValue) the native cache."
        }
        try writePrivateRunnerFile(JSONEncoder().encode(response), to: directory.appendingPathComponent("native-response"))
        lastRequest = request.id
    }

    var saveRequested: Bool {
        if case .saveRequested = state { return true }
        return false
    }

    // The post action only records intent. Disk flush runs after the GitHub listener exits.
    func detachForPublication() -> Bool {
        guard case .saveRequested = state else { return false }
        do {
            try backend.detachNativeCache(on: id)
            state = .sealed
            return true
        } catch {
            writeToStandardError("Discarding native cache for \(id.value): \(describeError(error))\n")
            return false
        }
    }

    func finishAfterDestruction(publish: Bool) throws {
        guard publish, case .sealed = state else {
            try store.finish(id, publish: false)
            return
        }
        do {
            try store.finish(id, publish: true)
        } catch {
            // A guest may invalidate its own pending disk. Confirm cleanup before
            // freeing the slot even when this generation cannot be published.
            writeToStandardError("Discarding native cache for \(id.value): \(describeError(error))\n")
            try store.finish(id, publish: false)
        }
    }
}

private enum NativeCacheSessionError: Error, LocalizedError {
    case unsupported, inconsistentGrant
    var errorDescription: String? {
        switch self {
        case .unsupported: "This runner backend cannot attach native cache disks."
        case .inconsistentGrant: "The cache permission does not match the open disk and repository."
        }
    }
}
