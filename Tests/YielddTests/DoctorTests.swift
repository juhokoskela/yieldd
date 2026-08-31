import Foundation
import Testing
@testable import Yieldd

@Test
func doctorReportsSuccessfulChecks() throws {
    let fixture = try ExecutableFixture(name: "container")
    defer { fixture.remove() }
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
        .success(processResult()),
    ])

    let report = Doctor(
        executor: executor,
        executableLocator: ExecutableLocator(searchPath: fixture.directory.path),
        supportsAppleSilicon: { true }
    ).run()

    #expect(report.succeeded)
    #expect(report.checks.map(\.status) == [
        .passed("supported"),
        .passed(fixture.executable.path),
        .passed("reachable"),
        .passed("available"),
    ])
    #expect(executor.requests.map(\.arguments) == [
        ["system", "status", "--format", "json"],
        ["machine", "list", "--quiet"],
    ])
    try report.requireSuccess()
}

@Test
func doctorSkipsDependentChecksWhenContainerIsMissing() {
    let directory = "/tmp/yieldd-empty-path-\(UUID().uuidString)"
    let executor = RecordingProcessExecutor(outcomes: [])

    let report = Doctor(
        executor: executor,
        executableLocator: ExecutableLocator(searchPath: directory),
        supportsAppleSilicon: { true }
    ).run()

    #expect(!report.succeeded)
    #expect(report.checks.count == 4)
    #expect(report.checks[2].status == .skipped("container executable is unavailable"))
    #expect(report.checks[3].status == .skipped("container executable is unavailable"))
    #expect(executor.requests.isEmpty)
    #expect(throws: DoctorReportError.checksFailed) {
        try report.requireSuccess()
    }
}

@Test
func doctorAggregatesHostAndSystemFailures() throws {
    let fixture = try ExecutableFixture(name: "container")
    defer { fixture.remove() }
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stderr: "not running", status: 1)),
    ])

    let report = Doctor(
        executor: executor,
        executableLocator: ExecutableLocator(searchPath: fixture.directory.path),
        supportsAppleSilicon: { false }
    ).run()

    #expect(report.checks[0].status == .failed("this host does not report Apple Silicon support"))
    guard case .failed = report.checks[2].status else {
        Issue.record("Expected the container system check to fail")
        return
    }
    #expect(report.checks[3].status == .skipped("container system is unreachable"))
    #expect(executor.requests.map(\.arguments) == [
        ["system", "status", "--format", "json"],
    ])
}

private struct ExecutableFixture {
    let directory: URL
    let executable: URL

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yieldd-doctor-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: executable.path, contents: Data()) else {
            throw TestFailure.unexpectedProcessRequest
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
