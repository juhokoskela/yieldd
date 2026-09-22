import Dispatch
import Foundation

final class MacOSVirtualizationBackend: RunnerBackend {
    let platform = RunnerPlatform.macOS
    private final class Guest {
        enum Phase {
            case relayOnly
            case booting(any MacOSVirtualMachineControlling)
            case ready(any MacOSVirtualMachineControlling)
        }
        let relay: any RunnerNetworkRelaying
        let ssh: MacOSGuestSSH
        var phase: Phase = .relayOnly

        init(relay: any RunnerNetworkRelaying, ssh: MacOSGuestSSH) {
            self.relay = relay
            self.ssh = ssh
        }

        var machine: (any MacOSVirtualMachineControlling)? {
            switch phase {
            case .relayOnly: nil
            case let .booting(machine), let .ready(machine): machine
            }
        }
    }

    private let templateURL: URL
    private let clones: MacOSRunnerCloneStore
    private let executor: any ProcessExecuting
    private let network: any MacOSRunnerNetworking
    private let requireEntitlement: () throws -> Void
    private let loadStorage: () throws -> RunnerStorage?
    private let makeMachine: (URL, UInt64, URL) throws -> any MacOSVirtualMachineControlling
    private let checkCancellation: () throws -> Void
    private let wait: (TimeInterval) throws -> Void
    private let maximumExecutionDeadline: () -> DispatchTime?
    private let bootTimeout: TimeInterval
    private let stopTimeout: TimeInterval
    // Provisioning and destruction are serialized. SSH job waits run outside this lock
    // so another caller can stop the runner or destroy its VM.
    private let lock = NSLock()
    private var guests: [RunnerID: Guest] = [:]

    init(
        stateDirectory: URL,
        templateURL: URL,
        cloneRootURL: URL,
        executor: any ProcessExecuting,
        network: (any MacOSRunnerNetworking)? = nil,
        checkCancellation: @escaping () throws -> Void = {},
        wait: @escaping (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:),
        maximumExecutionDeadline: @escaping () -> DispatchTime? = { nil },
        bootTimeout: TimeInterval = MacOSVirtualMachineLifecycle.bootTimeout,
        stopTimeout: TimeInterval = MacOSVirtualMachineLifecycle.stopTimeout,
        requireEntitlement: @escaping () throws -> Void = VirtualizationEntitlement.requireCurrentProcess,
        loadStorage: (() throws -> RunnerStorage?)? = nil,
        makeMachine: @escaping (URL, UInt64, URL) throws -> any MacOSVirtualMachineControlling =
            { try MacOSVirtualMachineLifecycle.makeMachine(bundleURL: $0, memoryBytes: $1, networkSocketURL: $2) }
    ) throws {
        self.templateURL = templateURL.resolvingSymlinksInPath()
        clones = MacOSRunnerCloneStore(rootURL: cloneRootURL.resolvingSymlinksInPath())
        try Self.validateTemplateLocation(self.templateURL, cloneRootURL: clones.rootURL)
        self.executor = executor
        self.network = try network ?? MacOSRunnerNetwork(stateDirectory: stateDirectory)
        self.checkCancellation = checkCancellation
        self.wait = wait
        self.maximumExecutionDeadline = maximumExecutionDeadline
        self.bootTimeout = bootTimeout
        self.stopTimeout = stopTimeout
        self.requireEntitlement = requireEntitlement
        self.loadStorage = loadStorage ?? { try RunnerStorage.validated(in: stateDirectory, executor: executor) }
        self.makeMachine = makeMachine
    }

    static func validateTemplateLocation(_ templateURL: URL, cloneRootURL: URL) throws {
        guard !templateURL.resolvingSymlinksInPath().pathComponents.starts(
            with: cloneRootURL.resolvingSymlinksInPath().pathComponents
        ) else {
            throw MacOSVirtualizationBackendError.templateInsideCloneRoot
        }
    }

    static func validateTemplate(at templateURL: URL) throws {
        try MacOSVirtualizationProbeClone.validateTemplate(at: templateURL)
        try MacOSGuestSSH.validateTemplate(at: templateURL)
    }

    func prepare() throws {
        try loadStorage()?.validateMacOS(template: templateURL, clones: clones.rootURL)
    }

    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws {
        try create(id: id, memory: memory, recordIntent: {})
    }

    func create(id: RunnerID, memory: RunnerMemoryAllocation, recordIntent: () throws -> Void) throws {
        try lock.withLock {
            try requireEntitlement()
            try checkCancellation()
            try prepare()
            try validateStorage(id)
            if let guest = guests[id], case let .ready(machine) = guest.phase,
               case .running = machine.state, guest.relay.isRunning {
                return
            }
            try recordIntent()
            try destroyLocked(id)
            do {
                let clone = try MacOSVirtualizationProbeClone.create(
                    templateURL: templateURL,
                    cloneRootURL: clones.rootURL,
                    id: id
                )
                try checkCancellation()
                let relay = try network.start(for: id, checkCancellation: checkCancellation)
                let ssh = MacOSGuestSSH(templateURL: templateURL, socketURL: relay.sshSocketURL, executor: executor)
                let guest = Guest(relay: relay, ssh: ssh)
                guests[id] = guest
                let machine = try makeMachine(
                    clone.url,
                    MacOSVirtualMachineLifecycle.memoryBytes(for: memory),
                    relay.socketURL
                )
                guest.phase = .booting(machine)
                let checkGuest = {
                    try self.checkCancellation()
                    try relay.check()
                }
                let completion = VirtualMachineCompletion<Void>()
                machine.start(completion: completion.complete)
                try completion.wait(
                    operation: "starting the macOS virtual machine",
                    deadline: ProcessInfo.processInfo.systemUptime + bootTimeout,
                    checkCancellation: checkGuest
                )
                let checkRunningGuest = {
                    try checkGuest()
                    try MacOSVirtualMachineLifecycle.requireRunning(machine)
                }
                try MacOSGuestConnection(ssh: ssh).waitUntilReady(
                    checkCancellation: checkRunningGuest,
                    wait: wait
                )
                try checkRunningGuest()
                guest.phase = .ready(machine)
            } catch {
                do {
                    try destroyLocked(id)
                } catch let cleanup {
                    throw MacOSVirtualizationProbeError.operationAndCleanupFailed(
                        operation: error, cleanup: cleanup
                    )
                }
                throw error
            }
        }
    }

    @discardableResult func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws -> ProcessResult {
        try checkCancellation()
        let ssh = try lock.withLock { () throws -> MacOSGuestSSH in
            guard let guest = guests[id], case let .ready(machine) = guest.phase else {
                throw MacOSVirtualizationBackendError.notReady(id)
            }
            try guest.relay.check()
            try MacOSVirtualMachineLifecycle.requireRunning(machine)
            return guest.ssh
        }
        let command: [String]
        if let executable = arguments.first,
           executable == "yieldd-configure-runner" || executable == "yieldd-runner-control" {
            command = ["/Users/runner/bin/\(executable)"] + arguments.dropFirst()
        } else {
            command = arguments
        }
        // macOS executes every command as runner, including callers' requests for root.
        return try ssh.execute(
            command, standardInput: standardInput,
            timeout: timeout, outputCapture: outputCapture
        )
    }

    func stopRunner(on id: RunnerID) throws {
        try lock.withLock {
            guard let guest = guests[id], let machine = guest.machine else { return }
            switch machine.state {
            case .stopped, .failed: return
            case .running, .stoppable, .transitioning: break
            }
            guard case .ready = guest.phase else { return }
            try guest.relay.check()
            try guest.ssh.execute(
                ["/Users/runner/bin/yieldd-runner-control", "stop"],
                timeout: try runnerStopTimeout(),
                outputCapture: .tail(maxBytes: MacOSGuestSSH.outputTailBytes),
                cancellable: false
            )
        }
    }

    func destroy(_ id: RunnerID) throws {
        try lock.withLock {
            // Validate paths even when no in-memory VM survived.
            _ = try clones.bundleURL(for: id)
            try destroyLocked(id)
        }
    }

    private func destroyLocked(_ id: RunnerID) throws {
        var failures: [RunnerSessionCleanupFailure] = []
        if let guest = guests[id] {
            var machineStopped = true
            // Revoke networking even when the VM cannot stop. Still attempt both
            // operations; retain ownership and capacity until both have succeeded.
            do { try guest.relay.stop(deadline: maximumExecutionDeadline()) }
            catch { failures.append(.init(step: .network, error: error)) }
            if let machine = guest.machine {
                do {
                    try MacOSVirtualMachineLifecycle.forceStop(
                        machine, timeout: stopTimeout, checkDeadline: checkCleanupDeadline
                    )
                } catch {
                    machineStopped = false
                    failures.append(.init(step: .machine, error: error))
                }
            }
            if !machineStopped || guest.relay.isRunning {
                if failures.count == 1 && failures[0].step == .machine { throw failures[0].error }
                throw RunnerSessionError.cleanupFailed(failures)
            }
            if failures.isEmpty { guests.removeValue(forKey: id) }
        }
        do {
            try loadStorage()?.validatePath(clones.rootURL)
            try clones.remove(id)
        } catch { failures.append(.init(step: .machine, error: error)) }
        if failures.count == 1 && failures[0].step == .machine { throw failures[0].error }
        if !failures.isEmpty { throw RunnerSessionError.cleanupFailed(failures) }
    }

    private func validateStorage(_ id: RunnerID) throws {
        _ = try clones.bundleURL(for: id)
        try Self.validateTemplate(at: templateURL)
    }

    private func checkCleanupDeadline() throws {
        if let deadline = maximumExecutionDeadline(), DispatchTime.now() >= deadline {
            throw MacOSVirtualizationProbeError.timedOut(operation: "cleaning up the macOS runner")
        }
    }

    private func runnerStopTimeout() throws -> TimeInterval {
        guard let deadline = maximumExecutionDeadline() else { return 20 }
        let now = DispatchTime.now()
        guard deadline > now else {
            throw MacOSVirtualizationProbeError.timedOut(operation: "cleaning up the macOS runner")
        }
        return min(20, Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000)
    }
}

enum MacOSVirtualizationBackendError: Error, LocalizedError {
    case notReady(RunnerID)
    case templateInsideCloneRoot

    var errorDescription: String? {
        switch self {
        case let .notReady(id):
            "macOS runner \(id.value) is not ready."
        case .templateInsideCloneRoot:
            "Move the macOS template outside the managed runner clone directory before retrying. Subsequent recovery commands may delete templates stored there."
        }
    }
}
