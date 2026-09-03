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

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
