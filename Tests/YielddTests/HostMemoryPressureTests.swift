import Dispatch
import Testing
@testable import Yieldd

@Test
func decodesDispatchMemoryPressureValues() {
    #expect(HostMemoryPressure(
        dispatchSourceRawValue: UInt32(DispatchSource.MemoryPressureEvent.normal.rawValue)
    ) == .normal)
    #expect(HostMemoryPressure(
        dispatchSourceRawValue: UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue)
    ) == .warning)
    #expect(HostMemoryPressure(
        dispatchSourceRawValue: UInt32(DispatchSource.MemoryPressureEvent.critical.rawValue)
    ) == .critical)
    #expect(HostMemoryPressure(dispatchSourceRawValue: 0) == .unknown)
}
