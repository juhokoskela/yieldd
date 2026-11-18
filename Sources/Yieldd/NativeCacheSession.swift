import Foundation

protocol NativeCacheBackend: RunnerBackend {
    func attachNativeCache(image: URL, cold: Bool, on id: RunnerID) throws
    func detachNativeCache(on id: RunnerID) throws
}

// The slot worker reads verified cache requests from its relay’s private directory.
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
        var writable: Bool?
        var error: String?
    }

    private enum State {
        case fresh
        case opening
        case attached(Grants, NativeCacheDisk)
        case saveRequested(Grants, NativeCacheDisk)
        case sealed(NativeCacheDisk)
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
                case .attached(let grants, _) where grants == request.grants:
                    break
                case .fresh:
                    // Either operation can allocate resources before throwing.
                    state = .opening
                    let disk = try store.open(id, readable: request.grants.read_scopes, writable: request.grants.write_scope)
                    try backend.attachNativeCache(image: disk.url, cold: disk.isCold, on: id)
                    state = .attached(request.grants, disk)
                default:
                    throw NativeCacheSessionError.inconsistentGrant
                }
                response.writable = request.grants.write_scope != nil
            case .save:
                switch state {
                case let .attached(grants, disk), let .saveRequested(grants, disk):
                    guard grants == request.grants else { throw NativeCacheSessionError.inconsistentGrant }
                    if grants.write_scope != nil { state = .saveRequested(grants, disk) }
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
    @discardableResult
    func detachForPublication() -> Bool {
        guard case let .saveRequested(_, disk) = state else { return false }
        do {
            try backend.detachNativeCache(on: id)
            state = .sealed(disk)
            return true
        } catch {
            writeToStandardError("Discarding native cache for \(id.value): \(describeError(error))\n")
            return false
        }
    }

    func finishAfterDestruction(publish: Bool) throws {
        if case .fresh = state { return }
        if publish, case let .sealed(disk) = state {
            do {
                try store.publish(disk)
            } catch {
                writeToStandardError("Discarding native cache for \(id.value): \(describeError(error))\n")
            }
        }
        try store.discard(id)
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
