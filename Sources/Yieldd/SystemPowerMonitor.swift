import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// Observes macOS system sleep/wake transitions via `IORegisterForSystemPower`.
/// All IOKit callback handling and teardown are serialized on `queue` so `rootPort`
/// cannot be closed before `IOAllowPowerChange` and the callback context cannot
/// outlive its owner.
final class SystemPowerMonitor: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let queue: DispatchQueue
    private let onWillSleep: @Sendable () -> Void
    private let onDidWake: @Sendable () -> Void
    private let lock = NSLock()
    private var box: CallbackBox?
    private var stopped = false

    private final class CallbackBox: @unchecked Sendable {
        var rootPort: io_connect_t = 0
        var notifyPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        var active = true
        let onWillSleep: @Sendable () -> Void
        let onDidWake: @Sendable () -> Void

        init(onWillSleep: @escaping @Sendable () -> Void, onDidWake: @escaping @Sendable () -> Void) {
            self.onWillSleep = onWillSleep
            self.onDidWake = onDidWake
        }

        func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
            guard active, rootPort != 0 else { return }
            let notificationID = Int(bitPattern: argument)
            switch messageType {
            case kIOMessageCanSystemSleep:
                IOAllowPowerChange(rootPort, notificationID)
            case kIOMessageSystemWillSleep:
                onWillSleep()
                IOAllowPowerChange(rootPort, notificationID)
            case kIOMessageSystemHasPoweredOn:
                onDidWake()
            default:
                break
            }
        }

        func tearDownOnQueue() {
            guard active else { return }
            active = false
            if notifier != 0 {
                IODeregisterForSystemPower(&notifier)
                notifier = 0
            }
            if let port = notifyPort {
                IONotificationPortSetDispatchQueue(port, nil)
                IONotificationPortDestroy(port)
                notifyPort = nil
            }
            if rootPort != 0 {
                IOServiceClose(rootPort)
                rootPort = 0
            }
        }
    }

    init(onWillSleep: @escaping @Sendable () -> Void, onDidWake: @escaping @Sendable () -> Void) {
        let q = DispatchQueue(label: "dev.yieldd.agent.system-power")
        q.setSpecific(key: Self.queueKey, value: 1)
        self.queue = q
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
    }

    func start() -> Bool {
        lock.withLock {
            guard !stopped, box == nil else { return box != nil }
            let newBox = CallbackBox(onWillSleep: onWillSleep, onDidWake: onDidWake)
            let refcon = Unmanaged.passRetained(newBox).toOpaque()
            var port: IONotificationPortRef?
            var object: io_object_t = 0
            let connect = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(refcon).takeUnretainedValue()
                box.handle(messageType: messageType, argument: messageArgument)
            }, &object)
            guard connect != 0, let port else {
                Unmanaged<CallbackBox>.fromOpaque(refcon).release()
                return false
            }
            newBox.rootPort = connect
            newBox.notifyPort = port
            newBox.notifier = object
            IONotificationPortSetDispatchQueue(port, queue)
            box = newBox
            return true
        }
    }

    func stop() {
        let activeBox: CallbackBox? = lock.withLock {
            stopped = true
            let current = box
            box = nil
            return current
        }
        guard let activeBox else { return }
        let cleanup = {
            activeBox.tearDownOnQueue()
            // Balance the passRetained from start() only after the notification port
            // has been detached and destroyed on `queue`, so no callback can ever fire after.
            Unmanaged.passUnretained(activeBox).release()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            cleanup()
        } else {
            queue.sync(execute: cleanup)
        }
    }

    deinit { stop() }

    /// Decodes IOPMrootDomain "System Capabilities" bitmask:
    /// bit 0 (`0x1`) = CPU, bit 1 (`0x2`) = Graphics.
    /// DarkWake has CPU active without Graphics.
    static func isDarkWakeCapabilities(_ capabilities: UInt32?) -> Bool {
        guard let capabilities else { return false }
        let cpuBit: UInt32 = 0x1
        let graphicsBit: UInt32 = 0x2
        return (capabilities & cpuBit) != 0 && (capabilities & graphicsBit) == 0
    }

    /// Reads whether the Mac is currently in a DarkWake (background maintenance wake
    /// while display/user session is asleep) from `IOPMrootDomain`.
    static func isDarkWake() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        if let capabilities = IORegistryEntryCreateCFProperty(
            rootDomain, "System Capabilities" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber {
            return isDarkWakeCapabilities(capabilities.uint32Value)
        }
        return false
    }
}

private let kIOMessageCanSystemSleep: natural_t = 0xE000_0270
private let kIOMessageSystemWillSleep: natural_t = 0xE000_0280
private let kIOMessageSystemHasPoweredOn: natural_t = 0xE000_0300
