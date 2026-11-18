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
        try withRunnerOwnership(recoveringMachineTest: true) { store in
            try store.recoverMachineTest {
                try AppleContainerBackend(containerURL: try locator.locate("container"), executor: executor, stateDirectory: store.directory)
            }
            try removeUnleasedRunnerFiles(in: store.directory, ownershipDescriptor: store.ownershipDescriptor, checkCancellation: stop.check)
        }
        print("Recovery complete. No new machines were started.")
    }
}
