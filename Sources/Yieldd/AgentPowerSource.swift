import notify
import Foundation
import IOKit
import IOKit.ps
import os

enum HostPowerSource: String, Codable, Equatable, Sendable {
    case ac, battery, unknown
}

struct HostPowerStatus: Codable, Equatable, Sendable {
    let source: HostPowerSource
    let batteryPercent: Int?
    let lowPowerMode: Bool
    let drainingOnAC: Bool

    static let unknown = HostPowerStatus(source: .unknown, batteryPercent: nil, lowPowerMode: false, drainingOnAC: false)
}

final class AgentPowerSource: @unchecked Sendable {
    static let system = AgentPowerSource(
        notifications: [kIOPSNotifyPowerSource, kIOPSNotifyTimeRemaining],
        refreshTTL: 10,
        observeLowPowerMode: true,
        readStatus: readSystemPowerStatus
    )

    private struct CachedState {
        var status: HostPowerStatus
        var updatedAt: TimeInterval
    }

    private let state: OSAllocatedUnfairLock<CachedState>
    private let tokens: [Int32]
    private let refreshTTL: TimeInterval?
    private let observeLowPowerMode: Bool
    private let currentTime: @Sendable () -> TimeInterval
    private let readStatus: @Sendable () -> HostPowerStatus
    private var lowPowerObserver: (any NSObjectProtocol)?

    convenience init(notification: String, read: @escaping @Sendable () -> Bool) {
        self.init(
            notifications: [notification],
            refreshTTL: nil,
            observeLowPowerMode: false,
            readStatus: {
                HostPowerStatus(source: read() ? .battery : .ac, batteryPercent: nil, lowPowerMode: false, drainingOnAC: false)
            }
        )
    }

    init(notifications: [String],
         refreshTTL: TimeInterval? = 10,
         observeLowPowerMode: Bool = false,
         currentTime: @escaping @Sendable () -> TimeInterval = continuousMonotonicSeconds,
         readStatus: @escaping @Sendable () -> HostPowerStatus) {
        self.readStatus = readStatus
        self.refreshTTL = refreshTTL
        self.observeLowPowerMode = observeLowPowerMode
        self.currentTime = currentTime
        state = OSAllocatedUnfairLock(initialState: CachedState(status: .unknown, updatedAt: -.infinity))
        let queue = DispatchQueue(label: "dev.yieldd.agent.power")
        var registered: [Int32] = []
        for name in notifications {
            var registration: Int32 = 0
            let result = notify_register_dispatch(name, &registration, queue) { [state] _ in
                let current = readStatus()
                let now = currentTime()
                state.withLock { $0 = CachedState(status: current, updatedAt: now) }
            }
            if result == NOTIFY_STATUS_OK {
                registered.append(registration)
            }
        }
        tokens = registered
        queue.sync {
            let current = readStatus()
            let now = currentTime()
            state.withLock { $0 = CachedState(status: current, updatedAt: now) }
        }
        if observeLowPowerMode {
            lowPowerObserver = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: nil
            ) { [state] _ in
                let current = readStatus()
                let now = currentTime()
                state.withLock { $0 = CachedState(status: current, updatedAt: now) }
            }
        }
    }

    func status() -> HostPowerStatus {
        let now = currentTime()
        let base: HostPowerStatus
        if tokens.isEmpty {
            base = readStatus()
        } else if let refreshTTL {
            let cached = state.withLock { $0 }
            if now - cached.updatedAt >= refreshTTL {
                let refreshed = readStatus()
                state.withLock { $0 = CachedState(status: refreshed, updatedAt: now) }
                base = refreshed
            } else {
                base = cached.status
            }
        } else {
            base = state.withLock { $0.status }
        }
        guard observeLowPowerMode else { return base }
        let liveLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard liveLowPower != base.lowPowerMode else { return base }
        return HostPowerStatus(
            source: base.source,
            batteryPercent: base.batteryPercent,
            lowPowerMode: liveLowPower,
            drainingOnAC: base.drainingOnAC
        )
    }

    func onBattery() -> Bool {
        status().source == .battery
    }

    deinit {
        for token in tokens { notify_cancel(token) }
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
    }

    private static func readSystemPowerStatus() -> HostPowerStatus {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return HostPowerStatus(source: .unknown, batteryPercent: nil, lowPowerMode: lowPower, drainingOnAC: false)
        }
        let sourceType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let source: HostPowerSource
        if sourceType == kIOPSBatteryPowerValue {
            source = .battery
        } else if sourceType == kIOPSACPowerValue {
            source = .ac
        } else {
            source = .unknown
        }
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for item in list {
                guard let desc = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                      let current = desc[kIOPSCurrentCapacityKey] as? Int,
                      let maxCap = desc[kIOPSMaxCapacityKey] as? Int,
                      maxCap > 0 else { continue }
                percent = max(0, min(100, (current * 100) / maxCap))
                break
            }
        }
        let drainingOnAC = source == .ac && isSmartBatteryDraining()
        return HostPowerStatus(source: source, batteryPercent: percent, lowPowerMode: lowPower, drainingOnAC: drainingOnAC)
    }

    private static func isSmartBatteryDraining() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, "InstantAmperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
            return false
        }
        // Require > 100 mA discharge to avoid flapping near 0 mA when full on AC.
        return Int64(bitPattern: raw.uint64Value) < -100
    }
}
