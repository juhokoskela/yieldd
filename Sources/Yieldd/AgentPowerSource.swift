import notify
import Foundation
import IOKit.ps
import os

final class AgentPowerSource: Sendable {
    static let system = AgentPowerSource(notification: kIOPSNotifyPowerSource) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
    }

    private let state: OSAllocatedUnfairLock<Bool>
    private let token: Int32?
    private let read: @Sendable () -> Bool

    init(notification: String, read: @escaping @Sendable () -> Bool) {
        self.read = read
        state = OSAllocatedUnfairLock(initialState: false)
        let queue = DispatchQueue(label: "dev.yieldd.agent.power")
        var registration: Int32 = 0
        let result = notify_register_dispatch(notification, &registration, queue) { [state] _ in
            let onBattery = read()
            state.withLock { $0 = onBattery }
        }
        token = result == NOTIFY_STATUS_OK ? registration : nil
        queue.sync {
            let onBattery = read()
            state.withLock { $0 = onBattery }
        }
    }

    func onBattery() -> Bool {
        token == nil ? read() : state.withLock { $0 }
    }

    deinit {
        if let token { notify_cancel(token) }
    }
}
