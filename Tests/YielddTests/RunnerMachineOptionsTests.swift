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

@Test
func runnerCommandsRejectEmptyTemplatePaths() {
    if let error = #expect(throws: (any Error).self, performing: {
        try MachineTestCommand.parse(["--template", ""])
    }) {
        #expect(MachineTestCommand.message(for: error) == "--template must not be empty.")
    }
    if let error = #expect(throws: (any Error).self, performing: {
        try RunnerTestCommand.parse(["owner/repository", "--template", ""])
    }) {
        #expect(RunnerTestCommand.message(for: error) == "--template must not be empty.")
    }
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
