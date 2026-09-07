import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

@Test
func runnerCommandsSelectMacOSTemplateWithoutChangingLinuxDefault() throws {
    let path = "/tmp/template with spaces.bundle"
    #expect(try MachineTestCommand.parse([]).machine.template == nil)
    #expect(try RunnerTestCommand.parse(["owner/repository"]).machine.template == nil)
    #expect(try MachineTestCommand.parse(["--template", path]).machine.template == path)
    let runner = try RunnerTestCommand.parse(["owner/repository", "--template", path, "--timeout", "10"])
    #expect(runner.machine.template == path)
    #expect(runner.timeout == 10)
}

@Test(arguments: ["", "template\0.bundle"])
func runnerCommandsRejectInvalidTemplatePaths(path: String) {
    #expect(throws: (any Error).self) { try MachineTestCommand.parse(["--template", path]) }
    #expect(throws: (any Error).self) { try RunnerTestCommand.parse(["owner/repository", "--template", path]) }
}

@Test
func platformSelectionUsesBackendMemoryCeilingsAndDistinctRunnerLabels() {
    #expect(RunnerPlatform.linux.memoryReservationBytes == AppleContainerBackend.memoryBytes)
    #expect(RunnerPlatform.macOS.memoryReservationBytes == MacOSVirtualMachineLifecycle.memoryBytes)
    #expect(RunnerPlatform.macOS.memoryReservationBytes == 8 * 1_024 * 1_024 * 1_024)
    #expect(RunnerPlatform.linux.runnerLabel == "yieldd")
    #expect(RunnerPlatform.macOS.runnerLabel == "yieldd-macos")
    let id = RunnerPlatform.macOS.makeTestRunnerID()
    #expect(id.isValid)
    #expect(id.value.hasPrefix("yieldd-macos-test-"))
    #expect(RunnerPlatform.linux.makeTestRunnerID().value.hasPrefix("yieldd-test-"))
}

@Test
func templateValidationScriptHasValidBashSyntax() throws {
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-n"],
        standardInput: Data(MacOSTemplateValidation.script.utf8),
        timeout: 5
    )
    try ProcessExecutor().execute(request).requireSuccess(for: request)
}

@Test(arguments: [false, true])
func templateValidationSelectsOnlyAvailableCompatibleIPhoneRuntime(available: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata = directory.appendingPathComponent("runtimes.json")
    let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
    let device = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
    try Data("""
        {"runtimes": [
            {"identifier": "\(runtime)", "isAvailable": \(available), "supportedDeviceTypes": [
                {"identifier": "\(device)"},
                {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"}
            ]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-0", "isAvailable": true},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "isAvailable": false}
        ]}
        """.utf8).write(to: metadata)
    let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
        arguments: ["-l", "JavaScript", "-", metadata.path],
        standardInput: Data(MacOSTemplateValidation.simulatorSelectionScript.utf8),
        timeout: 10
    )
    let result = try ProcessExecutor().execute(request)
    if available {
        try result.requireSuccess(for: request)
        #expect(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "\(runtime) \(device)")
    } else {
        #expect(result.terminationStatus != 0)
        #expect(result.stderrText.contains("Install an available iOS Simulator runtime"))
    }
}
