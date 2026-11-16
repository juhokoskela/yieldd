import Darwin
import Foundation

func readPrivateRunnerFile(_ file: URL, maximumBytes: Int) throws -> Data? {
    let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else {
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
        throw ConnectedAgentError.invalidConfiguration
    }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw ConnectedAgentError.invalidConfiguration }
    return data
}

func writePrivateRunnerFile(_ data: Data, to file: URL) throws {
    let directory = file.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".runner-state-\(UUID().uuidString).tmp")
    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { try? FileManager.default.removeItem(at: temporary) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    defer { try? handle.close() }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    guard Darwin.rename(temporary.path, file.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try synchronizeRunnerState(directory)
}
