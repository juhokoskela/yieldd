import Darwin
import Foundation
import Testing
@testable import Yieldd

@Test
func guestAddressResolverSelectsTheNewestCurrentExactMACLease() throws {
    let target = try #require(MacOSGuestAddressResolver.parseMACAddress("02:00:00:00:00:0f"))
    let leases = """
        {
            ip_address=192.168.65.2
            hw_address=1,2:0:0:0:0:f
            lease=0x63
        }
        {
            ip_address=192.168.65.3
            hw_address=1,2:0:0:0:0:e
            lease=0x200
        }
        {
            ip_address=invalid
            hw_address=1,2:0:0:0:0:f
            lease=0x300
        }
        {
            ip_address=192.168.65.4
            hw_address=1,02:00:00:00:00:0F
            lease=0x101
        }
        {
            ip_address=192.168.65.5
            hw_address=1,2:0:0:0:0:f
            lease=0x201
        }
        """

    #expect(MacOSGuestAddressResolver.address(
        in: leases,
        matching: target,
        currentUnixTime: 0x100
    ) == "192.168.65.5")
}

@Test
func guestAddressResolverIgnoresMalformedAndExpiredRecords() throws {
    let target = try #require(MacOSGuestAddressResolver.parseMACAddress("02:00:00:00:00:0f"))
    let leases = """
        {
            ip_address=192.168.65.2
            ip_address=192.168.65.3
            hw_address=1,2:0:0:0:0:f
            lease=0x200
        }
        {
            ip_address=192.168.65.4
            malformed
            hw_address=1,2:0:0:0:0:f
            lease=0x200
        }
        {
            ip_address=192.168.65.5
            hw_address=1,2:0:0:0:0:f
            lease=0x100
        }
        """

    #expect(MacOSGuestAddressResolver.address(
        in: leases,
        matching: target,
        currentUnixTime: 0x100
    ) == nil)
}

@Test(arguments: [
    "",
    "02:00:00:00:00",
    "02:00:00:00:00:000",
    "02:00:00:00:00:gg",
])
func guestAddressResolverRejectsInvalidTargetMAC(_ macAddress: String) throws {
    let resolver = MacOSGuestAddressResolver(
        leasesURL: URL(fileURLWithPath: "/file-that-must-not-be-read")
    )

    #expect(throws: MacOSGuestAddressResolverError.invalidMACAddress(macAddress)) {
        try resolver.address(for: macAddress)
    }
}

@Test
func guestAddressResolverTreatsAMissingLeaseFileAsNoAddress() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "missing-dhcp-leases-\(UUID().uuidString)"
    )
    let resolver = MacOSGuestAddressResolver(leasesURL: url)

    #expect(try resolver.address(for: "02:00:00:00:00:0f") == nil)
}

@Test
func guestAddressResolverRejectsOversizedLeaseFiles() throws {
    let url = uniqueLeaseFileURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 0, count: MacOSGuestAddressResolver.maximumLeaseBytes + 1).write(to: url)
    let resolver = MacOSGuestAddressResolver(leasesURL: url)

    #expect(throws: MacOSGuestAddressResolverError.leaseFileTooLarge(
        path: url.path,
        maximumBytes: MacOSGuestAddressResolver.maximumLeaseBytes
    )) {
        try resolver.address(for: "02:00:00:00:00:0f")
    }
}

@Test
func guestAddressResolverRejectsNonRegularLeaseFilesWithoutBlocking() throws {
    let url = uniqueLeaseFileURL()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(Darwin.mkfifo(url.path, 0o600) == 0)
    let resolver = MacOSGuestAddressResolver(leasesURL: url)

    #expect(throws: MacOSGuestAddressResolverError.leaseFileIsNotRegular(path: url.path)) {
        try resolver.address(for: "02:00:00:00:00:0f")
    }
}

private func uniqueLeaseFileURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "yieldd-dhcp-leases-\(UUID().uuidString)"
    )
}
