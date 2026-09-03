import Darwin
import Foundation
import Testing
@testable import Yieldd

@Test
func signalMonitorHandlesTimeoutFailedInstallAndCaughtSignal() throws {
    do {
        _ = try SignalMonitor(signals: [SIGUSR2, SIGKILL])
        Issue.record("Expected SIGKILL handler installation to fail")
    } catch let error as POSIXError {
        #expect(error.code == .EINVAL)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let delivery = RecordedSignal()
    let monitor = try SignalMonitor(
        signals: [SIGUSR2],
        signalReceived: delivery.record
    )
    try monitor.wait(for: 0)
    #expect(Darwin.kill(Darwin.getpid(), SIGUSR2) == 0)

    do {
        try monitor.wait(for: 1)
        Issue.record("Expected the wait to be interrupted")
    } catch let interruption as SignalInterruption {
        #expect(interruption.signal == SIGUSR2)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(delivery.value == SIGUSR2)

    do {
        try monitor.check()
        Issue.record("Expected the signal interruption to persist")
    } catch let interruption as SignalInterruption {
        #expect(interruption.signal == SIGUSR2)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private final class RecordedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signal: Int32?

    var value: Int32? {
        lock.withLock { signal }
    }

    func record(_ signal: Int32) {
        lock.withLock { self.signal = signal }
    }
}
