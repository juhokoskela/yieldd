import Darwin
import Foundation
import Virtualization

// One host-owned endpoint per guest, without a vmnet attachment.
final class PacketSocket: Sendable {
    let handle: FileHandle
    private let localPath: String
    private let deviceID: dev_t
    private let inode: ino_t

    init(path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var info = stat()
        guard lstat(directory, &info) == 0,
            info.st_mode & S_IFMT == S_IFDIR,
            info.st_mode & 0o777 == 0o700,
            info.st_uid == getuid()
        else { throw POSIXError(.EACCES) }
        localPath = path + ".vm"
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var bound = false
        do {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var sendBuffer: Int32 = 1 << 20
            var receiveBuffer: Int32 = 4 << 20
            guard setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0,
                setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try Self.address(localPath) { address, length in
                guard Darwin.bind(descriptor, address, length) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            bound = true
            guard lstat(localPath, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            deviceID = info.st_dev
            inode = info.st_ino
            guard chmod(localPath, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try Self.address(path) { address, length in
                guard Darwin.connect(descriptor, address, length) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        } catch {
            try? handle.close()
            if bound { unlink(localPath) }
            throw error
        }
        self.handle = handle
    }

    deinit {
        var info = stat()
        if lstat(localPath, &info) == 0, info.st_dev == deviceID, info.st_ino == inode {
            unlink(localPath)
        }
    }

    func device() -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.macAddress = VZMACAddress(string: "02:00:00:00:00:02")!
        device.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        return device
    }

    private static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
