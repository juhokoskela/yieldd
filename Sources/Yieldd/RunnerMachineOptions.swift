import ArgumentParser
import Foundation

struct RunnerMachineOptions: ParsableArguments {
    @Option(name: .long, help: "Use a prepared macOS template bundle instead of a Linux machine.")
    var template: String?

    mutating func validate() throws {
        if let template, template.isEmpty {
            throw ValidationError("--template must not be empty.")
        }
    }

    func makeBackend(
        leaseStore: RunnerLeaseStore,
        executor: any ProcessExecuting,
        checkCancellation: @escaping () throws -> Void,
        wait: @escaping (TimeInterval) throws -> Void
    ) throws -> any RunnerBackend {
        if let template {
            try VirtualizationEntitlement.requireCurrentProcess()
            return try MacOSVirtualizationBackend(stateDirectory: leaseStore.directory,
                templateURL: URL(fileURLWithPath: template),
                cloneRootURL: RunnerStorage.cloneRoot(in: leaseStore.directory),
                executor: executor,
                checkCancellation: checkCancellation,
                wait: wait
            )
        }
        return AppleContainerBackend(
            containerURL: try ExecutableLocator().locate("container"),
            executor: executor,
            stateDirectory: leaseStore.directory,
            checkCancellation: checkCancellation,
            dockerReadiness: DockerReadiness(
                wait: wait,
                checkCancellation: checkCancellation
            )
        )
    }
}
