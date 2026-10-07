import Foundation
import Testing
@testable import Yieldd

@Test
func containerSystemStartUsesNoninteractiveKernelPolicyAndTimeouts() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let storage = RunnerStorage(volumePath: fixture.directory.resolvingSymlinksInPath().path, volumeUUID: UUID().uuidString)
    let executor = RecordingProcessExecutor(outcomes: [.success(processResult())])
    let containerURL = URL(fileURLWithPath: "/usr/local/bin/container")

    try AppleContainerSystem(containerURL: containerURL, executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { storage }).start()

    #expect(executor.requests == [
        ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "system", "start",
                "--disable-kernel-install",
                "--timeout", "60",
                "--app-root", storage.containerURL.path,
            ],
            timeout: AppleContainerSystem.processTimeout,
            outputCapture: .tail(maxBytes: 1_024 * 1_024)
        ),
    ])
}

@Test
func containerSystemStartRequiresSuccessfulExit() throws {
    let fixture = try StorageFixture()
    defer { fixture.remove() }
    let storage = RunnerStorage(volumePath: fixture.directory.resolvingSymlinksInPath().path, volumeUUID: UUID().uuidString)
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stderr: "failed", status: 1)),
    ])

    #expect(throws: ProcessExecutionError.self) {
        try AppleContainerSystem(
            containerURL: URL(fileURLWithPath: "/usr/local/bin/container"),
            executor: executor, stateDirectory: unconfiguredContainerStateDirectory, loadStorage: { storage }
        ).start()
    }
}
