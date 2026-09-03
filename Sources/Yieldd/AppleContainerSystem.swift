import Foundation

struct AppleContainerSystem {
    static let commandTimeout: TimeInterval = 60
    static let processTimeout: TimeInterval = commandTimeout + 15

    let containerURL: URL
    let executor: any ProcessExecuting

    func start() throws {
        let request = ProcessRequest(
            executableURL: containerURL,
            arguments: [
                "system", "start",
                "--disable-kernel-install",
                "--timeout", String(Int(Self.commandTimeout)),
            ],
            timeout: Self.processTimeout,
            outputCapture: .tail(maxBytes: 1_024 * 1_024)
        )
        try executor.execute(request).requireSuccess(for: request)
    }
}
