import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

@Test
func serviceOptionsPreserveMixedAndRepeatedSlots() throws {
    let command = try RunnerServiceCommand.parse([
        "owner/repo", "--macos", "owner/repo", "--macos", "owner/repo",
        "--macos-template", "/tmp/template with spaces.bundle",
    ])
    let configuration = try command.runners.serviceConfiguration()
    #expect(configuration.slots.map(\.platform) == [.linux, .macOS, .macOS])
    #expect(configuration.slots.map(\.repository.fullName) == Array(repeating: "owner/repo", count: 3))
    #expect(configuration.requiresLinux)
    #expect(configuration.macOSTemplateURL?.lastPathComponent == "template with spaces.bundle")
    let macOnly = try RunnerServiceCommand.parse([
        "--macos", "owner/repo", "--macos-template", "/tmp/template.bundle",
    ]).runners.serviceConfiguration()
    #expect(!macOnly.requiresLinux)
}

@Test(arguments: [
    ([], "At least one runner repository is required."),
    (["--macos", "owner/repo"], "--macos and --macos-template must be supplied together."),
    (["owner/repo", "--macos-template", "/tmp/template"], "--macos and --macos-template must be supplied together."),
    (["--macos", "owner/repo", "--macos-template", ""], "--macos-template must not be empty."),
    (["--macos", "owner/repo", "--macos", "owner/repo", "--macos", "owner/repo", "--macos-template", "/tmp/template"], "Supports at most 2 macOS runner slots."),
])
func serviceOptionsRejectInvalidSlotConfigurations(arguments: [String], message: String) throws {
    let error = try #require(#expect(throws: (any Error).self) { try RunnerServiceCommand.parse(arguments) })
    #expect(RunnerServiceCommand.message(for: error) == message)
}

@Test(arguments: [false, true])
func serviceRejectsManagedTemplateBeforeRecovery(symlink: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yieldd-service-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RunnerLeaseStore(directory: directory)
    let template = try MacOSRunnerCloneStore(stateDirectory: directory).bundleURL(for: RunnerID(value: "yieldd-template"))
    try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
    let disk = template.appendingPathComponent("Disk.img")
    try Data("must survive".utf8).write(to: disk)
    let alias = directory.appendingPathComponent("template-link")
    if symlink { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: template) }
    let configuration = try RunnerServiceConfiguration(
        repositories: [], macOSRepositories: [GitHubRepository("owner/repo")], macOSTemplateURL: symlink ? alias : template
    )
    let error = try #require(#expect(throws: MacOSVirtualizationBackendError.self) {
        try runRunnerService(
            configuration: configuration, leaseStore: store, containerURL: nil,
            ghURL: URL(fileURLWithPath: "/missing/gh"), stop: RunnerPoolStop(), output: .terminal
        )
    })
    guard case .templateInsideCloneRoot = error else {
        Issue.record("Expected template location rejection")
        return
    }
    #expect(try String(contentsOf: disk, encoding: .utf8) == "must survive")
}

@Test(arguments: [RunnerPlatform.linux, .macOS])
func serviceSessionSelectsBackendAndJobLabel(platform: RunnerPlatform) throws {
    let fixture = try ProbeBundleFixture()
    defer { fixture.remove() }
    let session = try makeRunnerSession(
        platform: platform, templateURL: platform == .macOS ? fixture.templateURL : nil,
        leaseStore: RunnerLeaseStore(directory: fixture.rootURL),
        containerURL: platform == .linux ? URL(fileURLWithPath: "/missing/container") : nil,
        ghURL: URL(fileURLWithPath: "/missing/gh"), stop: RunnerPoolStop(),
        memoryAdmission: RunnerMemoryAdmission(), stateChanged: { _ in }
    )
    #expect(session.backend.platform == platform)
    let messages = ServiceMessages()
    reportRunnerServiceState(
        .waitingForJob(RunnerID(value: "yieldd-test")), platform: platform,
        output: RunnerServiceOutput(info: messages.append, warning: messages.append, error: messages.append)
    )
    #expect(messages.values == ["Runner yieldd-test is waiting for one job labeled '\(platform.runnerLabel)'."])
}

private final class ServiceMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var values: [String] { lock.withLock { messages } }
    func append(_ value: String) { lock.withLock { messages.append(value) } }
}
