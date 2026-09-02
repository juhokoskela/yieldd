import Foundation
import Testing
@testable import Yieldd

@Test
func findsExecutableInSearchPath() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yieldd-locator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("tool")
    #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
    )

    let located = try ExecutableLocator(searchPath: directory.path).locate("tool")

    #expect(located == executable)
}

@Test
func reportsSearchedDirectoriesWhenExecutableIsMissing() {
    let searchPath = "/first:/second"

    do {
        _ = try ExecutableLocator(searchPath: searchPath).locate("missing")
        Issue.record("Expected lookup to fail")
    } catch let error as ExecutableLocatorError {
        #expect(error == .notFound(name: "missing", searchedDirectories: ["/first", "/second"]))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test(arguments: [
    "",
    ":/usr/bin",
    "/usr/bin:",
    "/usr/bin::/bin",
])
func rejectsEmptySearchPathComponents(_ searchPath: String) {
    #expect(throws: ExecutableLocatorError.emptySearchPathComponent) {
        try ExecutableLocator(searchPath: searchPath).locate("tool")
    }
}

@Test
func rejectsNamesContainingAPathSeparator() {
    #expect(throws: ExecutableLocatorError.invalidName("bin/tool")) {
        try ExecutableLocator(searchPath: "/usr/bin").locate("bin/tool")
    }
}
