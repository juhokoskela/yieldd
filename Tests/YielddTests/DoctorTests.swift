import Foundation
import Testing
@testable import Yieldd

@Test
func doctorReportsSuccessfulChecks() throws {
    let fixture = try ExecutableFixture(names: ["container", "gh"])
    defer { fixture.remove() }
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult()),
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
        .passed(fixture.executable(named: "container").path),
        .passed("reachable"),
        .passed("available"),
        .passed(fixture.executable(named: "gh").path),
        .passed("authenticated"),
    ])
    #expect(executor.requests.map(\.arguments) == [
        ["system", "status", "--format", "json"],
        ["machine", "list", "--quiet"],
        ["auth", "status", "--active", "--hostname", "github.com"],
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
    #expect(report.checks.count == 6)
    #expect(report.checks[2].status == .skipped("container executable is unavailable"))
    #expect(report.checks[3].status == .skipped("container executable is unavailable"))
    guard case .failed = report.checks[4].status else {
        Issue.record("Expected the gh executable check to fail")
        return
    }
    #expect(report.checks[5].status == .skipped("gh executable is unavailable"))
    #expect(executor.requests.isEmpty)
    #expect(throws: DoctorReportError.checksFailed) {
        try report.requireSuccess()
    }
}

@Test
func doctorAggregatesHostAndSystemFailures() throws {
    let fixture = try ExecutableFixture(names: ["container"])
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

@Test
func doctorChecksGitHubEvenWhenContainerIsMissing() throws {
    let fixture = try ExecutableFixture(names: ["gh"])
    defer { fixture.remove() }
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])

    let report = Doctor(
        executor: executor,
        executableLocator: ExecutableLocator(searchPath: fixture.directory.path),
        supportsAppleSilicon: { true }
    ).run()

    #expect(!report.succeeded)
    #expect(report.checks[4].status == .passed(fixture.executable(named: "gh").path))
    #expect(report.checks[5].status == .passed("authenticated"))
    #expect(executor.requests.map(\.arguments) == [
        ["auth", "status", "--active", "--hostname", "github.com"],
    ])
}

@Test
func macOSDoctorDoesNotRequireOrInvokeContainer() throws {
    let fixture = try ExecutableFixture(names: ["gh"])
    defer { fixture.remove() }
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let report = Doctor(
        executor: executor,
        executableLocator: ExecutableLocator(searchPath: fixture.directory.path),
        supportsAppleSilicon: { true }
    ).run(templateURL: fixture.directory.appendingPathComponent("missing.bundle"))

    #expect(!report.succeeded)
    #expect(!report.checks.contains { $0.name.hasPrefix("container") })
    let template = try #require(report.checks.first { $0.name == "macOS template" })
    guard case .failed = template.status else {
        Issue.record("Expected missing template validation to fail")
        return
    }
    #expect(executor.requests.map(\.arguments) == [["auth", "status", "--active", "--hostname", "github.com"]])
}

private struct ExecutableFixture {
    let directory: URL
    private let executables: [String: URL]

    init(names: [String]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yieldd-doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var created: [String: URL] = [:]
        for name in names {
            let executable = directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: executable.path, contents: Data()) else {
                throw TestFailure.unexpectedProcessRequest
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
            created[name] = executable
        }
        executables = created
    }

    func executable(named name: String) -> URL {
        guard let executable = executables[name] else {
            preconditionFailure("Fixture has no executable named \(name)")
        }
        return executable
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
