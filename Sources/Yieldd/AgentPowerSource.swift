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

final class AgentPowerSource: Sendable {
    static let system = AgentPowerSource(notification: kIOPSNotifyPowerSource, readStatus: readSystemPowerStatus)

    private let state: OSAllocatedUnfairLock<HostPowerStatus>
    private let token: Int32?
    private let readStatus: @Sendable () -> HostPowerStatus

    init(notification: String, read: @escaping @Sendable () -> Bool) {
        self.readStatus = {
            HostPowerStatus(source: read() ? .battery : .ac, batteryPercent: nil, lowPowerMode: false, drainingOnAC: false)
        }
        state = OSAllocatedUnfairLock(initialState: .unknown)
        let queue = DispatchQueue(label: "dev.yieldd.agent.power")
        var registration: Int32 = 0
        let readFn = self.readStatus
        let result = notify_register_dispatch(notification, &registration, queue) { [state] _ in
            let current = readFn()
            state.withLock { $0 = current }
        }
        token = result == NOTIFY_STATUS_OK ? registration : nil
        queue.sync {
            let current = readFn()
            state.withLock { $0 = current }
        }
    }

    init(notification: String, readStatus: @escaping @Sendable () -> HostPowerStatus) {
        self.readStatus = readStatus
        state = OSAllocatedUnfairLock(initialState: .unknown)
        let queue = DispatchQueue(label: "dev.yieldd.agent.power")
        var registration: Int32 = 0
        let result = notify_register_dispatch(notification, &registration, queue) { [state] _ in
            let current = readStatus()
            state.withLock { $0 = current }
        }
        token = result == NOTIFY_STATUS_OK ? registration : nil
        queue.sync {
            let current = readStatus()
            state.withLock { $0 = current }
        }
    }

    func status() -> HostPowerStatus {
        token == nil ? readStatus() : state.withLock { $0 }
    }

    func onBattery() -> Bool {
        status().source == .battery
    }

    deinit {
        if let token { notify_cancel(token) }
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
        // InstantAmperage is reported as 64-bit signed milliamps (negative means battery discharging).
        return Int64(bitPattern: raw.uint64Value) < 0
    }
}
