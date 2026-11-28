import Darwin
import Foundation
import IOKit

/// Monotonic time in seconds that advances across macOS system sleep.
/// Unlike `ProcessInfo.processInfo.systemUptime` (`CLOCK_UPTIME_RAW`),
/// `CLOCK_MONOTONIC_RAW` keeps counting while the Mac is asleep so
/// execution-authorization grace periods and timeouts expire during lid close.
func continuousMonotonicSeconds() -> TimeInterval {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
}

enum HostThermalState: String, Codable, Equatable, Sendable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var isElevated: Bool { self != .nominal }
    var isSevere: Bool { self == .serious || self == .critical }
}

struct HostHardwareProfile: Equatable, Sendable {
    let modelIdentifier: String
    let logicalCPUs: Int

    /// Conservative quiet-mode Linux vCPU default based on chassis class.
    /// 16" MacBook Pros and desktops (Studio/Mini/Pro) default to 4 vCPUs;
    /// 14" MacBook Pros and fanless MacBook Airs default to 2 vCPUs.
    var defaultMeetingModeCPUs: Int {
        let model = modelIdentifier.lowercased()
        // Known 14" MacBook Pro and MacBook Air identifiers have tighter quiet thermal budgets.
        if model.contains("macbookair") || model.hasPrefix("mac14,2") || model.hasPrefix("mac14,15")
            || model.hasPrefix("mac15,12") || model.hasPrefix("mac15,13")
            || model.hasPrefix("mac16,12") || model.hasPrefix("mac16,13") {
            return 2
        }
        // 14" MacBook Pro families (MacBookPro18,3/4, Mac14,5/9, Mac15,3/6/8/10, Mac16,1/6/8, Mac17,x 14")
        let compactProPrefixes = [
            "macbookpro18,3", "macbookpro18,4",
            "mac14,5", "mac14,9",
            "mac15,3", "mac15,6", "mac15,8", "mac15,10",
            "mac16,1", "mac16,6", "mac16,8",
            "mac17,2", "mac17,6", "mac17,8",
        ]
        if compactProPrefixes.contains(where: { model == $0 }) {
            return 2
        }
        if logicalCPUs <= 10 {
            return 2
        }
        return 4
    }

    static var current: HostHardwareProfile {
        HostHardwareProfile(
            modelIdentifier: sysctlString("hw.model") ?? "unknown",
            logicalCPUs: ProcessInfo.processInfo.processorCount
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) }
        }
    }
}
