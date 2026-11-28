import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// Observes macOS system sleep/wake transitions via `IORegisterForSystemPower`.
/// The `onWillSleep` callback must stay strictly bounded (<= 1.5s) because
/// `IOAllowPowerChange` is invoked immediately afterward.
final class SystemPowerMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.yieldd.agent.system-power")
    private let onWillSleep: @Sendable () -> Void
    private let onDidWake: @Sendable () -> Void
    private let lock = NSLock()
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var stopped = false

    init(onWillSleep: @escaping @Sendable () -> Void, onDidWake: @escaping @Sendable () -> Void) {
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
    }

    func start() -> Bool {
        lock.withLock {
            guard !stopped, rootPort == 0 else { return rootPort != 0 }
            var port: IONotificationPortRef?
            var object: io_object_t = 0
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let connect = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(messageType: messageType, argument: messageArgument)
            }, &object)
            guard connect != 0, let port else { return false }
            IONotificationPortSetDispatchQueue(port, queue)
            rootPort = connect
            notifyPort = port
            notifier = object
            return true
        }
    }

    func stop() {
        let state: (io_connect_t, IONotificationPortRef?, io_object_t) = lock.withLock {
            stopped = true
            let current = (rootPort, notifyPort, notifier)
            rootPort = 0
            notifyPort = nil
            notifier = 0
            return current
        }
        var object = state.2
        if object != 0 { IODeregisterForSystemPower(&object) }
        if state.0 != 0 { IOServiceClose(state.0) }
        if let port = state.1 { IONotificationPortDestroy(port) }
    }

    deinit { stop() }

    private func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        let port = lock.withLock { rootPort }
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case kIOMessageCanSystemSleep:
            if port != 0 { IOAllowPowerChange(port, notificationID) }
        case kIOMessageSystemWillSleep:
            onWillSleep()
            if port != 0 { IOAllowPowerChange(port, notificationID) }
        case kIOMessageSystemHasPoweredOn:
            onDidWake()
        default:
            break
        }
    }

    /// Reads whether the Mac is currently in a DarkWake (background maintenance wake
    /// while display/user session is asleep) from `IOPMrootDomain`.
    static func isDarkWake() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        if let capabilities = IORegistryEntryCreateCFProperty(
            rootDomain, "IOPMSystemPowerState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Int {
            // IOPMrootDomain state 2 is DarkWake; 3/4 is FullWake.
            return capabilities == 2
        }
        return false
    }
}

private let kIOMessageCanSystemSleep: natural_t = 0xE000_0270
private let kIOMessageSystemWillSleep: natural_t = 0xE000_0280
private let kIOMessageSystemHasPoweredOn: natural_t = 0xE000_0300
