import Foundation

struct AppleContainerSystem {
    static let commandTimeout: TimeInterval = 60
    static let processTimeout: TimeInterval = commandTimeout + 15

    let containerURL: URL
    let executor: any ProcessExecuting
    let stateDirectory: URL
    var loadStorage: (() throws -> RunnerStorage)?

    func start() throws {
        let storage = try (loadStorage ?? { try RunnerStorage.validated(in: stateDirectory, executor: executor) })()
        try storage.validatePath(storage.containerURL)
        try AppleContainerBackend.requireNetworkSupport(containerURL: containerURL, executor: executor)
        let request = ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "system", "start",
                "--disable-kernel-install",
                "--timeout", String(Int(Self.commandTimeout)),
                "--app-root", storage.containerURL.path,
            ],
            timeout: Self.processTimeout,
            outputCapture: .tail(maxBytes: 1_024 * 1_024)
        )
        try executor.execute(request).requireSuccess(for: request)
    }
}
