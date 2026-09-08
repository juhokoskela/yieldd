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
        signalMonitor: SignalMonitor,
        executor: any ProcessExecuting
    ) throws -> any RunnerBackend {
        if let template {
            try VirtualizationEntitlement.requireCurrentProcess()
            return try MacOSVirtualizationBackend(
                templateURL: URL(fileURLWithPath: template),
                cloneRootURL: MacOSRunnerCloneStore(stateDirectory: leaseStore.directory).rootURL,
                executor: executor,
                checkCancellation: signalMonitor.check,
                wait: signalMonitor.wait
            )
        }
        return AppleContainerBackend(
            containerURL: try ExecutableLocator().locate("container"),
            executor: executor,
            dockerReadiness: DockerReadiness(
                wait: signalMonitor.wait,
                checkCancellation: signalMonitor.check
            )
        )
    }
}
