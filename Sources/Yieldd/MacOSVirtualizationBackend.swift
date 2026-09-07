import Dispatch
import Foundation

final class MacOSVirtualizationBackend: RunnerBackend {
    let platform = RunnerPlatform.macOS
    private struct Guest {
        let machine: any MacOSVirtualMachineControlling
        let address: String?
    }

    private let templateURL: URL
    private let clones: MacOSRunnerCloneStore
    private let ssh: MacOSGuestSSH
    private let connection: MacOSGuestConnection
    private let requireEntitlement: () throws -> Void
    private let makeMachine: (URL, UInt64) throws -> any MacOSVirtualMachineControlling
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
        templateURL: URL,
        cloneRootURL: URL,
        executor: any ProcessExecuting,
        resolver: any MacOSGuestAddressResolving = MacOSGuestAddressResolver(),
        checkCancellation: @escaping () throws -> Void = {},
        wait: @escaping (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:),
        maximumExecutionDeadline: @escaping () -> DispatchTime? = { nil },
        bootTimeout: TimeInterval = MacOSVirtualMachineLifecycle.bootTimeout,
        stopTimeout: TimeInterval = MacOSVirtualMachineLifecycle.stopTimeout,
        requireEntitlement: @escaping () throws -> Void = VirtualizationEntitlement.requireCurrentProcess,
        makeMachine: @escaping (URL, UInt64) throws -> any MacOSVirtualMachineControlling =
            MacOSVirtualMachineLifecycle.makeMachine
    ) {
        self.templateURL = templateURL.resolvingSymlinksInPath()
        clones = MacOSRunnerCloneStore(rootURL: cloneRootURL.resolvingSymlinksInPath())
        let ssh = MacOSGuestSSH(templateURL: self.templateURL, executor: executor)
        self.ssh = ssh
        connection = MacOSGuestConnection(resolver: resolver, ssh: ssh)
        self.checkCancellation = checkCancellation
        self.wait = wait
        self.maximumExecutionDeadline = maximumExecutionDeadline
        self.bootTimeout = bootTimeout
        self.stopTimeout = stopTimeout
        self.requireEntitlement = requireEntitlement
        self.makeMachine = makeMachine
    }

    func create(id: RunnerID, memory: RunnerMemoryAllocation) throws {
        try lock.withLock {
            try requireEntitlement()
            try checkCancellation()
            try validateStorage(id)
            if let guest = guests[id], guest.address != nil,
               case .running = guest.machine.state {
                return
            }
            try destroyLocked(id)
            do {
                let clone = try MacOSVirtualizationProbeClone.create(
                    templateURL: templateURL,
                    cloneRootURL: clones.rootURL,
                    id: id
                )
                try checkCancellation()
                let machine = try makeMachine(
                    clone.url,
                    MacOSVirtualMachineLifecycle.memoryBytes(for: memory)
                )
                guests[id] = Guest(machine: machine, address: nil)
                let completion = VirtualMachineCompletion<Void>()
                machine.start(completion: completion.complete)
                try completion.wait(
                    operation: "starting the macOS virtual machine",
                    deadline: ProcessInfo.processInfo.systemUptime + bootTimeout,
                    checkCancellation: checkCancellation
                )
                let checkGuest = {
                    try self.checkCancellation()
                    try MacOSVirtualMachineLifecycle.requireRunning(machine)
                }
                let address = try connection.waitUntilReady(
                    macAddress: clone.macAddress,
                    checkCancellation: checkGuest,
                    wait: wait
                )
                try checkGuest()
                guests[id] = Guest(machine: machine, address: address)
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

    func exec(
        _ arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval?,
        outputCapture: ProcessOutputCapture,
        as user: RunnerGuestUser,
        on id: RunnerID
    ) throws {
        try checkCancellation()
        let address = try lock.withLock { () throws -> String in
            guard let guest = guests[id], let address = guest.address else {
                throw MacOSVirtualizationBackendError.notReady(id)
            }
            try MacOSVirtualMachineLifecycle.requireRunning(guest.machine)
            return address
        }
        let command: [String]
        if let executable = arguments.first,
           executable == "yieldd-configure-runner" || executable == "yieldd-runner-control" {
            command = ["/Users/runner/bin/\(executable)"] + arguments.dropFirst()
        } else {
            command = arguments
        }
        // Both shared session call sites execute as runner; macOS guests have no sudo.
        try ssh.execute(
            command, address: address, standardInput: standardInput,
            timeout: timeout, outputCapture: outputCapture
        )
    }

    func stopRunner(on id: RunnerID) throws {
        try lock.withLock {
            guard let guest = guests[id] else { return }
            switch guest.machine.state {
            case .stopped, .failed: return
            case .running, .stoppable, .transitioning: break
            }
            guard let address = guest.address else { return }
            try ssh.execute(
                ["/Users/runner/bin/yieldd-runner-control", "stop"],
                address: address,
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
            try requireSeparateTemplate()
            try destroyLocked(id)
        }
    }

    private func destroyLocked(_ id: RunnerID) throws {
        if let guest = guests[id] {
            try MacOSVirtualMachineLifecycle.forceStop(
                guest.machine,
                timeout: stopTimeout,
                checkDeadline: checkCleanupDeadline
            )
            guests.removeValue(forKey: id)
        }
        try clones.remove(id)
    }

    private func validateStorage(_ id: RunnerID) throws {
        _ = try clones.bundleURL(for: id)
        try requireSeparateTemplate()
        try MacOSVirtualizationProbeClone.validateTemplate(at: templateURL)
        try MacOSGuestSSH.validateTemplate(at: templateURL)
    }

    func requireSeparateTemplate() throws {
        let root = clones.rootURL.pathComponents
        guard !templateURL.pathComponents.starts(with: root) else {
            throw MacOSVirtualizationBackendError.templateInsideCloneRoot
        }
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
            "The macOS template must be outside the runner clone directory."
        }
    }
}
