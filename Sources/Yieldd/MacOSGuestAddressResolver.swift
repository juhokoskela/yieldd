import Darwin
import Foundation

protocol MacOSGuestAddressResolving {
    func address(for macAddress: String) throws -> String?
}

struct MacOSGuestAddressResolver: MacOSGuestAddressResolving {
    static let defaultLeasesURL = URL(fileURLWithPath: "/var/db/dhcpd_leases")
    static let maximumLeaseBytes = 1_024 * 1_024

    private let leasesURL: URL
    private let currentUnixTime: @Sendable () -> UInt64

    init(
        leasesURL: URL = Self.defaultLeasesURL,
        currentUnixTime: @escaping @Sendable () -> UInt64 = {
            UInt64(max(0, Date().timeIntervalSince1970))
        }
    ) {
        self.leasesURL = leasesURL
        self.currentUnixTime = currentUnixTime
    }

    func address(for macAddress: String) throws -> String? {
        guard let targetAddress = Self.parseMACAddress(macAddress) else {
            throw MacOSGuestAddressResolverError.invalidMACAddress(macAddress)
        }
        let data = try Self.readLeases(at: leasesURL)
        return Self.address(
            in: String(decoding: data, as: UTF8.self),
            matching: targetAddress,
            currentUnixTime: currentUnixTime()
        )
    }

    static func address(
        in contents: String,
        matching targetAddress: [UInt8],
        currentUnixTime: UInt64
    ) -> String? {
        var record: [String: String] = [:]
        var recordIsValid = false
        var bestMatch: (address: String, expiration: UInt64)?

        for rawLine in contents.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            switch line {
            case "{":
                record = [:]
                recordIsValid = true
            case "}":
                if recordIsValid,
                   let match = matchingRecord(
                       record,
                       targetAddress: targetAddress,
                       currentUnixTime: currentUnixTime
                   ), match.expiration > (bestMatch?.expiration ?? 0) {
                    bestMatch = match
                }
                record = [:]
                recordIsValid = false
            default:
                guard recordIsValid else {
                    continue
                }
                let parts = line.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 2 else {
                    recordIsValid = false
                    continue
                }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, record.updateValue(value, forKey: key) == nil else {
                    recordIsValid = false
                    continue
                }
            }
        }

        return bestMatch?.address
    }

    static func parseMACAddress(_ value: String) -> [UInt8]? {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 6 else {
            return nil
        }
        var result: [UInt8] = []
        result.reserveCapacity(6)
        for component in components {
            guard (1...2).contains(component.count),
                  let byte = UInt8(component, radix: 16) else {
                return nil
            }
            result.append(byte)
        }
        return result
    }

    private static func matchingRecord(
        _ record: [String: String],
        targetAddress: [UInt8],
        currentUnixTime: UInt64
    ) -> (address: String, expiration: UInt64)? {
        guard let hardwareAddress = record["hw_address"],
              let comma = hardwareAddress.firstIndex(of: ","),
              hardwareAddress[..<comma] == "1",
              parseMACAddress(String(hardwareAddress[hardwareAddress.index(after: comma)...])) == targetAddress,
              let address = record["ip_address"], isIPv4Address(address),
              let rawLease = record["lease"],
              rawLease.lowercased().hasPrefix("0x"),
              let expiration = UInt64(rawLease.dropFirst(2), radix: 16),
              expiration > currentUnixTime else {
            return nil
        }
        return (address, expiration)
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    private static func readLeases(at url: URL) throws -> Data {
        let (descriptor, openError) = url.path.withCString { path in
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            return (descriptor, descriptor >= 0 ? 0 : errno)
        }
        if descriptor < 0, openError == ENOENT {
            return Data()
        }
        guard descriptor >= 0 else {
            throw fileError(operation: "Opening the DHCP lease file", url: url, errorNumber: openError)
        }
        defer { _ = Darwin.close(descriptor) }

        var fileStatus = stat()
        let inspectResult = Darwin.fstat(descriptor, &fileStatus)
        let inspectError = inspectResult == 0 ? 0 : errno
        guard inspectResult == 0 else {
            throw fileError(operation: "Inspecting the DHCP lease file", url: url, errorNumber: inspectError)
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            throw MacOSGuestAddressResolverError.leaseFileIsNotRegular(path: url.path)
        }
        guard fileStatus.st_size >= 0,
              fileStatus.st_size <= off_t(Self.maximumLeaseBytes) else {
            throw MacOSGuestAddressResolverError.leaseFileTooLarge(
                path: url.path,
                maximumBytes: Self.maximumLeaseBytes
            )
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= Self.maximumLeaseBytes {
            let remaining = Self.maximumLeaseBytes + 1 - data.count
            let (readCount, readError) = buffer.withUnsafeMutableBytes { bytes in
                let count = Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
                return (count, count >= 0 ? 0 : errno)
            }
            if readCount < 0, readError == EINTR {
                continue
            }
            guard readCount >= 0 else {
                throw fileError(operation: "Reading the DHCP lease file", url: url, errorNumber: readError)
            }
            guard readCount > 0 else {
                return data
            }
            data.append(contentsOf: buffer[..<readCount])
        }

        throw MacOSGuestAddressResolverError.leaseFileTooLarge(
            path: url.path,
            maximumBytes: Self.maximumLeaseBytes
        )
    }

    private static func fileError(
        operation: String,
        url: URL,
        errorNumber: Int32
    ) -> MacOSGuestAddressResolverError {
        .fileOperationFailed(
            operation: operation,
            path: url.path,
            code: POSIXErrorCode(rawValue: errorNumber) ?? .EIO
        )
    }
}

enum MacOSGuestAddressResolverError: Error, Equatable, LocalizedError {
    case invalidMACAddress(String)
    case leaseFileIsNotRegular(path: String)
    case leaseFileTooLarge(path: String, maximumBytes: Int)
    case fileOperationFailed(operation: String, path: String, code: POSIXErrorCode)

    var errorDescription: String? {
        switch self {
        case let .invalidMACAddress(address):
            "The macOS virtual machine reported an invalid MAC address: \(address)"
        case let .leaseFileIsNotRegular(path):
            "The DHCP lease file is not a regular file: \(path)"
        case let .leaseFileTooLarge(path, maximumBytes):
            "The DHCP lease file at \(path) exceeds \(maximumBytes) bytes."
        case let .fileOperationFailed(operation, path, code):
            "\(operation) failed for \(path): \(POSIXError(code).localizedDescription)"
        }
    }
}
