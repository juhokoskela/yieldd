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

    let monitor = try SignalMonitor(signals: [SIGUSR2])
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

    do {
        try monitor.check()
        Issue.record("Expected the signal interruption to persist")
    } catch let interruption as SignalInterruption {
        #expect(interruption.signal == SIGUSR2)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
