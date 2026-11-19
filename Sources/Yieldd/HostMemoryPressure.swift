import Darwin
import Dispatch

enum HostMemoryPressure: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case unknown

    init(dispatchSourceRawValue: UInt32) {
        switch dispatchSourceRawValue {
        case UInt32(DispatchSource.MemoryPressureEvent.normal.rawValue):
            self = .normal
        case UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue):
            self = .warning
        case UInt32(DispatchSource.MemoryPressureEvent.critical.rawValue):
            self = .critical
        default:
            self = .unknown
        }
    }

    static func current() -> HostMemoryPressure {
        var rawValue: UInt32 = 0
        var size = MemoryLayout.size(ofValue: rawValue)

        // A dispatch memory-pressure source reports transitions but does not
        // guarantee an initial event. This read-only kernel value exposes the
        // current level using the same dispatch event bitmask.
        let status = sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &rawValue,
            &size,
            nil,
            0
        )
        guard status == 0, size == MemoryLayout.size(ofValue: rawValue) else {
            return .unknown
        }
        return HostMemoryPressure(dispatchSourceRawValue: rawValue)
    }
}
