import ArgumentParser
import Foundation

struct RunnerServiceOutput: Sendable {
    let info: @Sendable (String) -> Void
    let warning: @Sendable (String) -> Void
    let error: @Sendable (String) -> Void

    static let terminal = RunnerServiceOutput(
        info: { print($0) },
        warning: { writeToStandardError("Warning: \($0)\n") },
        error: { writeToStandardError("\($0)\n") }
    )
}

struct RunnerServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Continuously run ephemeral GitHub Actions runners."
    )

    @OptionGroup
    var runners: RunnerServiceOptions

    mutating func run() throws {
        let configuration = try runners.serviceConfiguration()
        let locator = ExecutableLocator()
        let containerURL = try configuration.requiresLinux ? locator.locate("container") : nil
        let ghURL = try locator.locate("gh")
        let stop = try RunnerPoolStop.monitoringSignals()
        defer { print("Stopping yieldd.") }
        print("Press Ctrl+C to stop.")
        try withRunnerOwnership { leaseStore in
            try runRunnerService(
                configuration: configuration,
                leaseStore: leaseStore,
                containerURL: containerURL,
                ghURL: ghURL,
                stop: stop,
                output: .terminal
            )
        }
    }
}

func runRunnerService(
    configuration: RunnerServiceConfiguration,
    leaseStore: RunnerLeaseStore,
    containerURL: URL?,
    ghURL: URL,
    stop: RunnerPoolStop,
    output: RunnerServiceOutput,
    memoryAdmission: RunnerMemoryAdmission = RunnerMemoryAdmission(),
    prepareContainer: (() throws -> URL)? = nil
) throws {
    try memoryAdmission.validateCapacity(reserving: configuration.memoryReservationBytes)
    if let templateURL = configuration.macOSTemplateURL {
        try validateRunnerServiceTemplate(
            templateURL, stateDirectory: leaseStore.directory
        )
        try VirtualizationEntitlement.requireCurrentProcess()
        try MacOSVirtualMachineLifecycle.requireSupportedHost()
    }

    let executor = ProcessExecutor(checkCancellation: stop.check, maximumExecutionDeadline: stop.executionDeadline)
    let resolveContainer = prepareContainer ?? { try containerURL ?? ExecutableLocator().locate("container") }
    do {
        let recovery = makeRunnerRecovery(
            leaseStore: leaseStore, resolveContainer: resolveContainer, ghURL: ghURL,
            stop: stop, executor: executor, stateChanged: { reportRunnerRecoveryState($0, output: output) }
        )
        for recoveredID in try recovery.run() {
            output.info("Cleaned up abandoned runner \(recoveredID.value).")
        }
    } catch {
        guard isCancellation(error) else {
            throw error
        }
        return
    }

    let preparedContainerURL = try configuration.requiresLinux ? resolveContainer() : nil
    let storage = try RunnerStorage.validated(in: leaseStore.directory)
    if let preparedContainerURL {
        try storage.validateContainer(containerExecutable: preparedContainerURL)
    }
    if let template = configuration.macOSTemplateURL {
        try storage.validateMacOS(template: template, clones: storage.clonesURL)
    }
    let slots = try configuration.slots.map { slot in
        let backend: RunnerSlotBackend
        switch slot.platform {
        case .linux:
            guard let containerURL = preparedContainerURL else { throw RunnerServiceConfigurationError.missingContainerExecutable }
            backend = .linux(containerURL: containerURL)
        case .macOS:
            guard let templateURL = configuration.macOSTemplateURL else {
                throw RunnerServiceConfigurationError.templatePairRequired
            }
            backend = .macOS(templateURL: templateURL)
        }
        return (repository: slot.repository, backend: backend)
    }
    output.info(runnerServiceBanner(configuration))

    try RunnerPool(stop: stop).run(slots: slots) { slot, stop in
        let repository = slot.repository
        let platform = slot.backend.platform
        let session = try makeRunnerSession(
            backend: slot.backend, leaseStore: leaseStore, ghURL: ghURL,
            stop: stop, memoryAdmission: memoryAdmission,
            stateChanged: { reportRunnerServiceState($0, platform: platform, output: output) }
        )
        try RunnerService(
            session: session,
            makeRunnerID: {
                platform.makeServiceRunnerID()
            },
            checkForStop: stop.check,
            waitUntilStopped: stop.wait,
            stateChanged: { state in
                switch state {
                case let .backingOff(failures, delay):
                    let unit = delay == 1 ? "second" : "seconds"
                    output.info("Runner slot for \(repository.fullName) failed \(failures) time(s); retrying in \(Int(delay)) \(unit).")
                case let .cleanupDeferred(id):
                    output.info("GitHub cleanup for \(id.value) is deferred until GitHub releases its active job.")
                }
            },
            sessionFailed: { error in
                if !isCancellation(error) {
                    output.error("Runner session for \(repository.fullName) failed: \(describeError(error))")
                }
            }
        ).run(repository: repository)
    }
}

func runnerServiceBanner(_ configuration: RunnerServiceConfiguration) -> String {
    let slotNoun = configuration.slots.count == 1 ? "slot" : "slots"
    let names = configuration.slots.map { "\($0.repository.fullName) (\($0.platform.rawValue.lowercased()))" }.joined(separator: ", ")
    return "Serving \(configuration.slots.count) ephemeral runner \(slotNoun) for \(names)."
}

enum RunnerSlotBackend: Sendable {
    case linux(containerURL: URL)
    case macOS(templateURL: URL)

    var platform: RunnerPlatform {
        switch self {
        case .linux: .linux
        case .macOS: .macOS
        }
    }
}

func makeRunnerSession(
    backend slotBackend: RunnerSlotBackend,
    leaseStore: RunnerLeaseStore,
    ghURL: URL,
    stop: RunnerPoolStop,
    memoryAdmission: RunnerMemoryAdmission,
    stateChanged: @escaping (RunnerSessionState) -> Void
) throws -> EphemeralRunnerSession {
    let executor = ProcessExecutor(
        checkCancellation: stop.check,
        maximumExecutionDeadline: stop.executionDeadline
    )
    let backend: any RunnerBackend
    switch slotBackend {
    case let .linux(containerURL):
        backend = AppleContainerBackend(
            containerURL: containerURL,
            executor: executor,
            stateDirectory: leaseStore.directory,
            dockerReadiness: DockerReadiness(
                wait: stop.wait,
                checkCancellation: stop.check
            )
        )
    case let .macOS(templateURL):
        backend = try MacOSVirtualizationBackend(stateDirectory: leaseStore.directory,
            templateURL: templateURL,
            cloneRootURL: RunnerStorage.cloneRoot(in: leaseStore.directory),
            executor: executor, checkCancellation: stop.check, wait: stop.wait,
            maximumExecutionDeadline: stop.executionDeadline
        )
    }
    return EphemeralRunnerSession(
        backend: backend,
        github: GitHubRunnerClient(
            ghURL: ghURL,
            executor: executor
        ),
        memoryAdmission: memoryAdmission,
        checkCancellation: stop.check,
        recoveryWait: stop.wait,
        stateChanged: stateChanged,
        leaseStore: leaseStore
    )
}

func makeRunnerRecovery(
    leaseStore: RunnerLeaseStore,
    resolveContainer: @escaping () throws -> URL,
    ghURL: URL,
    stop: RunnerPoolStop,
    executor: any ProcessExecuting,
    makeCloneStore: ((RunnerCloneKind) throws -> MacOSRunnerCloneStore)? = nil,
    stateChanged: @escaping (RunnerSessionState) -> Void
) -> RunnerRecovery {
    return RunnerRecovery(
        linuxBackend: {
            AppleContainerBackend(containerURL: try resolveContainer(), executor: executor, stateDirectory: leaseStore.directory)
        },
        github: GitHubRunnerClient(ghURL: ghURL, executor: executor),
        leaseStore: leaseStore,
        makeCloneStore: makeCloneStore,
        recoveryWait: stop.wait,
        checkCancellation: stop.check,
        stateChanged: stateChanged
    )
}

func validateRunnerServiceTemplate(_ templateURL: URL, stateDirectory: URL) throws {
    try RunnerStorage.required(in: stateDirectory).validateTemplateLocation(templateURL)
    try MacOSVirtualizationBackend.validateTemplate(at: templateURL)
}

func reportRunnerServiceState(_ state: RunnerSessionState, platform: RunnerPlatform, output: RunnerServiceOutput) {
    switch state {
    case let .listenerStarted(id):
        output.info("Runner listener \(id.value) started; waiting for job pickup.")
    case let .jobStarted(id):
        output.info("Runner \(id.value) reported job start.")
    case let .listenerExited(id, status):
        output.info("Runner listener \(id.value) exited with status \(status).")
    case let .executionStopped(id, reason):
        output.warning("Stopping runner \(id.value): \(reason)")
    case let .capacityReleased(id):
        output.info("Machine capacity released for \(id.value).")
    case let .cleanupCompleted(id):
        output.info("Runner cleanup completed for \(id.value).")
    case let .preparing(id):
        output.info("Preparing ephemeral runner \(id.value).")
    case let .waitingForMemory(id):
        output.info("Runner \(id.value) is waiting for available host memory.")
    case let .waitingForJob(id):
        output.info("Runner \(id.value) is waiting for one job labeled '\(platform.runnerLabel)'.")
    case .waitingForGitHubCleanup, .leaseCleanupFailed:
        reportRunnerRecoveryState(state, output: output)
    case let .cleaningUp(id):
        output.info("Cleaning up runner \(id.value).")
    }
}

func reportRunnerRecoveryState(_ state: RunnerSessionState, output: RunnerServiceOutput = .terminal) {
    switch state {
    case let .waitingForGitHubCleanup(id, retryDelay):
        output.info(githubCleanupRetryMessage(id: id, delay: retryDelay))
    case let .leaseCleanupFailed(id, reason):
        output.warning("Could not clear runner lease for \(id.value): \(reason)")
    case .waitingForMemory, .preparing, .waitingForJob, .cleaningUp,
         .listenerStarted, .jobStarted, .listenerExited, .executionStopped, .capacityReleased, .cleanupCompleted:
        break
    }
}

func githubCleanupRetryMessage(id: RunnerID, delay: TimeInterval) -> String {
    let unit = delay == 1 ? "second" : "seconds"
    return "GitHub still considers runner \(id.value) busy; retrying cleanup in \(Int(delay)) \(unit)."
}

func isCancellation(_ error: any Error) -> Bool {
    if error is SignalInterruption || error is CancellationError {
        return true
    }
    if let error = error as? ProcessExecutionError {
        switch error {
        case .cancelled, .executionDeadlineExceeded:
            return true
        default:
            break
        }
    }
    return false
}

func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}
