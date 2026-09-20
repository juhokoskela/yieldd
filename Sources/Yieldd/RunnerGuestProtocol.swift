import Foundation

enum RunnerGuestProtocol {
    static func validate(backend: any RunnerBackend, id: RunnerID) throws {
        for helper in ["yieldd-configure-runner", "yieldd-runner-control"] {
            do {
                let result = try backend.exec([helper, "--protocol-version"], timeout: 5,
                    outputCapture: .tail(maxBytes: 1024), as: .runner, on: id)
                guard result.stdoutText == "1\n" else { throw RunnerGuestProtocolError.incompatible(helper) }
            } catch let error as ProcessExecutionError {
                if case .nonZeroExit = error { throw RunnerGuestProtocolError.incompatible(helper) }
                if case .timedOut = error {
                    throw RunnerGuestProtocolError.timedOut(helper: helper, detail: describeError(error))
                }
                throw error
            }
        }
    }
}

enum RunnerGuestProtocolError: Error, Equatable, LocalizedError {
    case incompatible(String)
    case timedOut(helper: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .incompatible(helper):
            "Guest helper \(helper) is missing or outdated. Update both guest scripts in the macOS template or rebuild the Linux guest image, then retry machine-test."
        case let .timedOut(helper, detail):
            "Checking guest helper \(helper) --protocol-version timed out: \(detail)"
        }
    }
}
