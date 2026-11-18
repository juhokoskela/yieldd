import Foundation
import Testing
@testable import Yieldd

struct NativeCacheSessionTests {
    @Test func saveRecordsIntentAndPublicationWaitsForGuestAbsence() throws {
        let fixture = try NativeSessionFixture()
        defer { fixture.remove() }
        let opened = try fixture.request("open")
        #expect(opened["path"] == "/mnt/yieldd-cache")
        #expect(fixture.backend.attachments == 1)
        // A retried action receives the existing mount.
        _ = try fixture.request("open")
        #expect(fixture.backend.attachments == 1)
        #expect(!fixture.session.detachForPublication())
        _ = try fixture.request("save")
        #expect(fixture.backend.detachments == 0)
        #expect(fixture.session.detachForPublication())
        #expect(fixture.backend.detachments == 1)
        #expect(try fixture.checkCold("yieldd-before-destroy"))
        try fixture.session.finishAfterDestruction(publish: true)
        #expect(try !fixture.checkCold("yieldd-after-destroy"))
    }

    @Test func failedUnmountReadOnlyAndCanceledJobsKeepPreviousGeneration() throws {
        for mode in ["unmount-error", "read-only", "canceled"] {
            let fixture = try NativeSessionFixture()
            defer { fixture.remove() }
            let writable = mode == "read-only" ? nil : fixture.scope
            _ = try fixture.request("open", write: writable)
            _ = try fixture.request("save", write: writable)
            fixture.backend.failDetach = mode == "unmount-error"
            let detached = fixture.session.detachForPublication()
            #expect(detached == (mode == "canceled"))
            try fixture.session.finishAfterDestruction(publish: detached && mode != "canceled")
            #expect(try fixture.checkCold("yieldd-next"))
        }
    }

    @Test func partialAttachmentCannotReopenOrPublishTheDisk() throws {
        let fixture = try NativeSessionFixture()
        defer { fixture.remove() }
        fixture.backend.failAttach = true
        #expect(try fixture.request("open")["error"] != nil)
        fixture.backend.failAttach = false
        #expect(try fixture.request("open")["error"] != nil)
        #expect(fixture.backend.attachments == 1)
        #expect(try fixture.request("save")["error"] != nil)
        try fixture.session.finishAfterDestruction(publish: true)
        #expect(try fixture.checkCold("yieldd-next"))
    }

    @Test func mismatchedRepositoryOrChangedGrantCannotWrite() throws {
        let fixture = try NativeSessionFixture()
        defer { fixture.remove() }
        #expect(try fixture.request("open", repo: "other/project")["error"] != nil)
        #expect(fixture.backend.attachments == 0)
        _ = try fixture.request("open")
        #expect(try fixture.request("save", write: String(repeating: "b", count: 64))["error"] != nil)
        #expect(!fixture.session.detachForPublication())
        try fixture.session.finishAfterDestruction(publish: false)
    }
}

private final class NativeSessionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let id = RunnerID(value: "yieldd-owner")
    let scope = String(repeating: "a", count: 64)
    let backend = NativeSessionBackend()
    let store: NativeCacheStore
    let session: NativeCacheSession

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        store = NativeCacheStore(root: root.appendingPathComponent("store"), platform: .linux, diskBytes: 4096)
        session = NativeCacheSession(store: store, backend: backend, id: id, repository: "trusted/project", directory: root)
        try session.prepare()
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    func request(_ op: String, repo: String = "trusted/project") throws -> [String: String] {
        try request(op, repo: repo, write: scope)
    }

    func request(_ op: String, repo: String = "trusted/project", write: String?) throws -> [String: String] {
        var grants: [String: Any] = ["repository_id": "42", "repository": repo, "read_scopes": [scope]]
        grants["write_scope"] = write
        let requestID = UUID().uuidString
        let payload: [String: Any] = ["operation": op, "id": requestID, "grants": grants]
        try writePrivateRunnerFile(JSONSerialization.data(withJSONObject: payload), to: root.appendingPathComponent("native-request"))
        try session.handleRequest()
        let data = try #require(try readPrivateRunnerFile(root.appendingPathComponent("native-response"), maximumBytes: 1024))
        let result = try JSONDecoder().decode([String: String].self, from: data)
        #expect(result["id"] == requestID)
        return result
    }

    func checkCold(_ name: String) throws -> Bool {
        let id = RunnerID(value: name)
        let cold = try store.open(id, readable: [scope], writable: nil).isCold
        try store.finish(id, publish: false)
        return cold
    }
}

private final class NativeSessionBackend: NativeCacheBackend {
    let platform = RunnerPlatform.linux
    var attachments = 0
    var detachments = 0
    var failAttach = false
    var failDetach = false

    func attachNativeCache(image: URL, cold: Bool, on id: RunnerID) throws {
        attachments += 1
        if failAttach { throw TestFailure.machineCleanup }
    }
    func detachNativeCache(on id: RunnerID) throws {
        detachments += 1
        if failDetach { throw TestFailure.machineCleanup }
    }
    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws { throw TestFailure.unexpectedBackendCall }
    func destroy(_ id: RunnerID) throws { throw TestFailure.unexpectedBackendCall }
    func exec(_ arguments: [String], standardInput: Data?, timeout: TimeInterval?, outputCapture: ProcessOutputCapture,
              as user: RunnerGuestUser, on id: RunnerID) throws -> ProcessResult { throw TestFailure.unexpectedBackendCall }
}
