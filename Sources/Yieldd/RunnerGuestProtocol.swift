import Foundation

enum RunnerGuestProtocol {
    static func validate(backend: any RunnerBackend, id: RunnerID, localCache: Bool = false) throws {
        let probe = ["--protocol-version"] + (localCache ? ["--local-cache"] : [])
        let version = localCache ? "3\n" : "2\n"
        for helper in ["yieldd-configure-runner", "yieldd-runner-control"] {
            let incompatible: RunnerGuestProtocolError = localCache
                ? .incompatibleCache(helper, backend.platform) : .incompatible(helper)
            do {
                let result = try backend.exec([helper] + probe, timeout: 5,
                    outputCapture: .tail(maxBytes: 1024), as: .runner, on: id)
                guard result.stdoutText == version else { throw incompatible }
            } catch let error as ProcessExecutionError {
                if case let .nonZeroExit(_, result) = error,
                   [2, 126, 127].contains(result.terminationStatus),
                   result.stderrText.contains(helper) {
                    throw incompatible
                }
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
    case incompatibleCache(String, RunnerPlatform)
    case timedOut(helper: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .incompatible(helper):
            return "Guest helper \(helper) is missing or outdated. Update both guest scripts in the macOS template or rebuild the Linux guest image, then retry machine-test."
        case let .incompatibleCache(helper, platform):
            let repair = platform == .linux
                ? "Rebuild the Linux guest image."
                : "Update both yieldd guest helpers and the yieldd Actions worker in the macOS template."
            return "Guest helper \(helper) does not support local job caches. \(repair) Run machine-test to verify the guest."
        case let .timedOut(helper, detail):
            return "Checking guest helper \(helper) --protocol-version timed out: \(detail)"
        }
    }
}
