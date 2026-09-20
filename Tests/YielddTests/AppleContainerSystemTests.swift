import Foundation
import Testing
@testable import Yieldd

@Test
func containerSystemStartUsesNoninteractiveKernelPolicyAndTimeouts() throws {
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let containerURL = URL(fileURLWithPath: "/usr/local/bin/container")

    try AppleContainerSystem(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory).start()

    #expect(executor.requests == [
        ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "system", "start",
                "--disable-kernel-install",
                "--timeout", "60",
            ],
            timeout: AppleContainerSystem.processTimeout,
            outputCapture: .tail(maxBytes: 1_024 * 1_024)
        ),
    ])
}

@Test
func containerSystemStartRequiresSuccessfulExit() {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stderr: "failed", status: 1)),
    ])

    #expect(throws: ProcessExecutionError.self) {
        try AppleContainerSystem(
            containerURL: URL(fileURLWithPath: "/usr/local/bin/container"),
            executor: executor, stateDirectory: unconfiguredContainerStateDirectory
        ).start()
    }
}
