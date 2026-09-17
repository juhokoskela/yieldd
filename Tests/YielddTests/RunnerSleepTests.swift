import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Yieldd

func runnerSleepAssertions(_ id: RunnerID) throws -> [[String: Any]] {
    var result: Unmanaged<CFDictionary>?
    try #require(IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess)
    let assertions = try #require(result).takeRetainedValue() as NSDictionary
    let own = assertions[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
    return own.filter { $0[kIOPMAssertionNameKey] as? String == "yieldd runner \(id.value)" }
}

func expectRunnerPreventsIdleSleep(_ id: RunnerID) throws {
    let assertions = try runnerSleepAssertions(id)
    let assertion = try #require(assertions.first)
    #expect(assertions.count == 1)
    #expect(assertion[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep)
    #expect(assertion[kIOPMAssertionLevelKey] as? Int == Int(kIOPMAssertionLevelOn))
}
