import ArgumentParser
import Foundation

struct RecoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "Clean up abandoned runners without starting new machines."
    )

    mutating func run() throws {
        let stop = try RunnerPoolStop.monitoringSignals()
        let executor = ProcessExecutor(checkCancellation: stop.check)
        let locator = ExecutableLocator()
        try withRunnerOwnership { store in
            try recoverAbandonedRunners(
                leaseStore: store,
                makeGitHub: { GitHubRunnerClient(ghURL: try locator.locate("gh"), executor: executor) },
                makeLinuxBackend: {
                    AppleContainerBackend(containerURL: try locator.locate("container"), executor: executor)
                },
                checkCancellation: stop.check,
                wait: stop.wait
            )
        }
        print("Recovery complete. No new machines were started.")
    }
}

// The caller holds runner ownership throughout inspection and cleanup.
func recoverAbandonedRunners(
    leaseStore: RunnerLeaseStore,
    makeGitHub: () throws -> any GitHubRunnerManaging,
    makeLinuxBackend: @escaping () throws -> any RunnerBackend,
    checkCancellation: @escaping () throws -> Void,
    wait: @escaping (TimeInterval) throws -> Void,
    output: RunnerServiceOutput = .terminal
) throws {
    try checkCancellation()
    if try leaseStore.load().isEmpty {
        try MacOSRunnerCloneStore(stateDirectory: leaseStore.directory)
            .removeUnleased(keeping: [], checkCancellation: checkCancellation)
        return
    }
    let recovery = RunnerRecovery(
        linuxBackend: makeLinuxBackend, github: try makeGitHub(), leaseStore: leaseStore,
        recoveryWait: wait, checkCancellation: checkCancellation,
        stateChanged: { reportRunnerRecoveryState($0, output: output) }
    )
    for id in try recovery.run() {
        output.info("Cleaned up abandoned runner \(id.value).")
    }
}
