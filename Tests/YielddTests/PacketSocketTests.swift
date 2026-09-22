@testable import Yieldd
import Darwin
import Foundation
import Testing
import Virtualization

struct PacketSocketTests {
    @Test func delayedDestructionPreservesReplacementEndpoint() throws {
        let fixture = try SocketFixture()
        try fixture.bindRelay()
        var previous: PacketSocket? = try PacketSocket(path: fixture.path)
        try #require(previous).handle.write(contentsOf: Data([1]))
        #expect(unlink(fixture.path + ".vm") == 0)
        let replacement = try PacketSocket(path: fixture.path)
        previous = nil
        withExtendedLifetime(replacement) {
            #expect(FileManager.default.fileExists(atPath: fixture.path + ".vm"))
        }
    }

    @Test func connectsAndRemovesOnlyItsOwnEndpoint() throws {
        let fixture = try SocketFixture()
        try fixture.bindRelay()
        do {
            let socket = try PacketSocket(path: fixture.path)
            #expect(fcntl(socket.handle.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.path + ".vm")
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let device = socket.device()
            #expect(device.macAddress.string == "02:00:00:00:00:02")
            #expect(device.attachment is VZFileHandleNetworkDeviceAttachment)
            try socket.handle.write(contentsOf: Data([1, 2, 3, 4]))
            #expect(try fixture.handle.read(upToCount: 4) == Data([1, 2, 3, 4]))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.path + ".vm"))
        #expect(FileManager.default.fileExists(atPath: fixture.path))
    }

    @Test func missingRelayRemovesPartiallyCreatedEndpoint() throws {
        let fixture = try SocketFixture()
        #expect(throws: POSIXError.self) { try PacketSocket(path: fixture.path) }
        #expect(!FileManager.default.fileExists(atPath: fixture.path + ".vm"))
    }

    @Test func existingEndpointIsNotRemovedOnFailure() throws {
        let fixture = try SocketFixture()
        let occupied = URL(fileURLWithPath: fixture.path + ".vm")
        let original = Data("owned by another attachment".utf8)
        try original.write(to: occupied)
        #expect(throws: POSIXError.self) { try PacketSocket(path: fixture.path) }
        #expect(try Data(contentsOf: occupied) == original)
    }

    @Test func sharedDirectoryIsRejected() throws {
        let fixture = try SocketFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        #expect(throws: POSIXError(.EACCES)) { try PacketSocket(path: fixture.path) }
        #expect(!FileManager.default.fileExists(atPath: fixture.path + ".vm"))
    }

    @Test func symlinkedDirectoryIsRejected() throws {
        let fixture = try SocketFixture()
        let link = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
        #expect(throws: POSIXError(.EACCES)) {
            try PacketSocket(path: link.appendingPathComponent("relay.sock").path)
        }
    }

    @Test(arguments: ["relative.sock", "/tmp/bad\0name"])
    func invalidPathsAreRejected(path: String) throws {
        #expect(throws: POSIXError(.EINVAL)) { try PacketSocket(path: path) }
    }

    @Test func oversizedPathIsRejectedBeforeBinding() throws {
        let fixture = try SocketFixture()
        let path = fixture.directory.appendingPathComponent(String(repeating: "x", count: 104)).path
        #expect(throws: POSIXError(.ENAMETOOLONG)) { try PacketSocket(path: path) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }
}

private final class SocketFixture {
    let directory: URL
    let handle: FileHandle
    var path: String { directory.appendingPathComponent("relay.sock").path }

    init() throws {
        var parent = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        // Keep room for the random directory suffix and both socket endpoints.
        if parent.utf8.count + "/yn-XXXXXX/relay.sock.vm".utf8.count >= 104 { parent = "/tmp" }
        var template = Array(URL(fileURLWithPath: parent).appendingPathComponent("yn-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        directory = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func bindRelay() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(handle.fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(handle.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
