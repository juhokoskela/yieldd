import Foundation
import Testing

@Test
func localAgentPlistRunsTheMainExecutableWithBoundedShutdown() throws {
    let plistURL = repositoryRoot
        .appendingPathComponent("Packaging/dev.yieldd.agent.plist", isDirectory: false)
    let data = try Data(contentsOf: plistURL)
    let plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    )

    #expect(plist["BundleProgram"] as? String == "Contents/MacOS/yieldd")
    #expect(plist["ProgramArguments"] as? [String] == ["yieldd", "agent", "run"])
    #expect(plist["ExitTimeOut"] as? Int == 60)
    #expect(plist["ThrottleInterval"] as? Int == 30)
    #expect(plist["KeepAlive"] as? Bool == true)
    #expect(plist["AssociatedBundleIdentifiers"] == nil)
}

@Test
func localAgentEntitlementsEnableVirtualization() throws {
    let entitlementsURL = repositoryRoot
        .appendingPathComponent("Packaging/yieldd.entitlements", isDirectory: false)
    let data = try Data(contentsOf: entitlementsURL)
    let entitlements = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    )
    #expect(entitlements["com.apple.security.virtualization"] as? Bool == true)
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
