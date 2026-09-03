import Darwin
import Foundation

private let signalMonitorInstallation = SignalMonitorInstallation()

// Dispatch sources are immutable after initialization, and SignalMonitorState synchronizes delivery.
final class SignalMonitor: @unchecked Sendable {
    private let state: SignalMonitorState
    private let sources: [any DispatchSourceSignal]
    private let previousHandlers: [(signal: Int32, handler: sig_t?)]

    init(signals: [Int32] = [SIGINT, SIGTERM]) throws {
        guard signalMonitorInstallation.acquire() else {
            throw SignalMonitorError.alreadyInstalled
        }

        let state = SignalMonitorState()
        let queue = DispatchQueue(label: "dev.yieldd.signal-monitor")
        var sources: [any DispatchSourceSignal] = []
        var installedHandlers: [(signal: Int32, handler: sig_t?)] = []

        do {
            for signalNumber in signals {
                let previousHandler: sig_t? = signal(signalNumber, SIG_IGN)
                guard !Self.isSignalError(previousHandler) else {
                    throw Self.posixError()
                }
                installedHandlers.append((signalNumber, previousHandler))

                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber,
                    queue: queue
                )
                source.setEventHandler {
                    state.record(signal: signalNumber)
                }
                source.resume()
                sources.append(source)
            }
        } catch {
            for source in sources {
                source.cancel()
            }
            for previous in installedHandlers.reversed() {
                _ = signal(previous.signal, previous.handler)
            }
            signalMonitorInstallation.release()
            throw error
        }

        self.state = state
        self.sources = sources
        previousHandlers = installedHandlers
    }

    deinit {
        for source in sources {
            source.cancel()
        }
        for previous in previousHandlers.reversed() {
            _ = signal(previous.signal, previous.handler)
        }
        signalMonitorInstallation.release()
    }

    func check() throws {
        try state.check()
    }

    func wait(for interval: TimeInterval) throws {
        precondition(interval.isFinite && interval >= 0)
        try state.check()

        let deadline = DispatchTime.now() + .milliseconds(
            Int((interval * 1_000).rounded(.up))
        )
        _ = state.wait(timeout: deadline)
        try state.check()
    }

    private static func isSignalError(_ handler: sig_t?) -> Bool {
        guard let handler else {
            return false
        }
        return unsafeBitCast(handler, to: UInt.self) == unsafeBitCast(SIG_ERR, to: UInt.self)
    }

    private static func posixError() -> POSIXError {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return POSIXError(code)
    }
}

private final class SignalMonitorState: @unchecked Sendable {
    private let lock = NSLock()
    private let received = DispatchSemaphore(value: 0)
    private var interruption: SignalInterruption?

    func record(signal: Int32) {
        lock.withLock {
            if interruption == nil {
                interruption = SignalInterruption(signal: signal)
            }
        }
        received.signal()
    }

    func check() throws {
        let recordedInterruption = lock.withLock { self.interruption }

        if let recordedInterruption {
            throw recordedInterruption
        }
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        received.wait(timeout: timeout)
    }
}

private final class SignalMonitorInstallation: @unchecked Sendable {
    private let lock = NSLock()
    private var installed = false

    func acquire() -> Bool {
        lock.withLock {
            guard !installed else {
                return false
            }
            installed = true
            return true
        }
    }

    func release() {
        lock.withLock {
            installed = false
        }
    }
}

struct SignalInterruption: Error, Equatable, LocalizedError {
    let signal: Int32

    var errorDescription: String? {
        "Interrupted by signal \(signal)."
    }
}

enum SignalMonitorError: Error, Equatable, LocalizedError {
    case alreadyInstalled

    var errorDescription: String? {
        "A signal monitor is already active."
    }
}
