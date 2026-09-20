import Foundation

struct AppleContainerSystem {
    static let commandTimeout: TimeInterval = 60
    static let processTimeout: TimeInterval = commandTimeout + 15

    let containerURL: URL
    let executor: any ProcessExecuting
    var stateDirectory: URL? = nil

    func start() throws {
        let directory = try stateDirectory ?? yielddApplicationSupportDirectory()
        let storage = try RunnerStorage.load(in: directory)
        if let storage {
            try storage.validate(stateDirectory: directory, executor: executor)
            try storage.validatePath(storage.containerURL)
        }
        let request = ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "system", "start",
                "--disable-kernel-install",
                "--timeout", String(Int(Self.commandTimeout)),
            ] + (storage.map { ["--app-root", $0.containerURL.path] } ?? []),
            timeout: Self.processTimeout,
            outputCapture: .tail(maxBytes: 1_024 * 1_024)
        )
        try executor.execute(request).requireSuccess(for: request)
    }
}
