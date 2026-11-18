import ArgumentParser
import Foundation
import Testing
@testable import Yieldd

@Test
func serviceRecoveryReportsMissingContainerAndRetainsLinuxLease() throws {
    let fixture = try ProbeBundleFixture()
    try saveTestStorageBinding(in: fixture.rootURL)
    defer { fixture.remove() }
    let leases = try RunnerLeaseStore(directory: fixture.rootURL)
    let lease = RunnerLease(runnerID: RunnerID(value: "yieldd-abandoned"), repository: try GitHubRepository("owner/repo"))
    let executor = RecordingProcessExecutor(outcomes: [])
    let recovery = makeRunnerRecovery(
        leaseStore: leases, resolveContainer: { try ExecutableLocator(searchPath: fixture.rootURL.path).locate("container") },
        ghURL: URL(fileURLWithPath: "/missing/gh"), stop: RunnerPoolStop(), executor: executor, makeCloneStore: testCloneStores(in: fixture.rootURL), stateChanged: { _ in }
    )
    #expect(try recovery.run().isEmpty)
    try leases.save(lease)
    let error = try #require(#expect(throws: RunnerSessionError.self) { try recovery.run() })
    #expect(describeError(error).contains("Linux lease recovery could not prepare Apple Container"))
    #expect(describeError(error).contains("Could not find executable container"))
    #expect(try leases.load() == [lease])
    #expect(executor.requests.isEmpty)
}
