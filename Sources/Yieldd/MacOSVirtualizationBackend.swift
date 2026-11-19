import Dispatch
import Foundation

final class MacOSVirtualizationBackend: NativeCacheBackend {
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
        var cacheVolumeID: UUID?

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
    private let network: any RunnerNetworking
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
        network: (any RunnerNetworking)? = nil,
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
        self.network = try network ?? RunnerNetwork(stateDirectory: stateDirectory, platform: .macOS)
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

    private func readyGuest(_ id: RunnerID) throws -> (machine: any MacOSVirtualMachineControlling, guest: Guest) {
        try lock.withLock {
            guard let guest = guests[id], case let .ready(machine) = guest.phase else {
                throw MacOSVirtualizationBackendError.notReady(id)
            }
            try guest.relay.check()
            try MacOSVirtualMachineLifecycle.requireRunning(machine)
            return (machine, guest)
        }
    }

    func attachNativeCache(image: URL, cold _: Bool, on id: RunnerID) throws {
        try checkCancellation()
        try loadStorage()?.validatePath(image)
        let (machine, guest) = try readyGuest(id)
        let requireVacantMount = """
        if [[ -e /Volumes/YielddCache || -L /Volumes/YielddCache ]]; then
            echo 'The cache mount point /Volumes/YielddCache is already in use.' >&2
            exit 1
        fi
        """
        try guest.ssh.execute(["/bin/bash", "-c", requireVacantMount], timeout: 10, outputCapture: .tail(maxBytes: 4096))
        let completion = VirtualMachineCompletion<Void>()
        machine.attachNativeDisk(image, completion: completion.complete)
        try completion.wait(operation: "attaching the cache disk", deadline: ProcessInfo.processInfo.systemUptime + 30,
                            checkCancellation: checkCancellation)
        // Disk Arbitration mounts removable APFS media asynchronously in the logged-in guest.
        // A directory left on the guest's root filesystem must never count as a mounted cache.
        let waitForMount = """
        set -euo pipefail
        volume=/Volumes/YielddCache
        system_device=$(/usr/bin/stat -f %d /Volumes)
        for ((i=0; i<120; ++i)); do
            if [[ -d "$volume" && ! -L "$volume" && -w "$volume" ]] &&
               cache_device=$(/usr/bin/stat -f %d "$volume") && [[ "$cache_device" != "$system_device" ]]; then
                /usr/sbin/diskutil info -plist "$volume" | /usr/bin/plutil -extract VolumeUUID raw -
                exit 0
            fi
            /bin/sleep .25
        done
        echo 'The cache disk did not mount at /Volumes/YielddCache.' >&2
        exit 1
        """
        let result = try guest.ssh.execute(["/bin/bash", "-c", waitForMount], timeout: 40, outputCapture: .tail(maxBytes: 4096))
        guard let volumeID = UUID(uuidString: result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MacOSVirtualizationBackendError.cacheVolumeUnknown
        }
        lock.withLock { guest.cacheVolumeID = volumeID }
    }

    func detachNativeCache(on id: RunnerID) throws {
        let (machine, guest) = try readyGuest(id)
        guard let volumeID = lock.withLock({ guest.cacheVolumeID }) else {
            throw MacOSVirtualizationBackendError.cacheVolumeUnknown
        }
        struct VolumeInfo: Decodable { let VolumeUUID: UUID; let MountPoint: String; let VolumeName: String }
        let result = try guest.ssh.execute(["/usr/sbin/diskutil", "info", "-plist", "/Volumes/YielddCache"],
                                           timeout: 10, outputCapture: .tail(maxBytes: 64 * 1024))
        let mounted = try PropertyListDecoder().decode(VolumeInfo.self, from: result.stdout)
        guard mounted.VolumeUUID == volumeID, mounted.MountPoint == "/Volumes/YielddCache", mounted.VolumeName == "YielddCache" else {
            throw MacOSVirtualizationBackendError.cacheVolumeChanged
        }
        try guest.ssh.execute(["/usr/sbin/diskutil", "unmount", volumeID.uuidString], timeout: 60, outputCapture: .tail(maxBytes: 4096))
        let completion = VirtualMachineCompletion<Void>()
        machine.detachNativeDisk(completion: completion.complete)
        try completion.wait(operation: "detaching the cache disk", deadline: ProcessInfo.processInfo.systemUptime + 30,
                            checkCancellation: checkCleanupDeadline)
        lock.withLock { guest.cacheVolumeID = nil }
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
        let ssh = try readyGuest(id).guest.ssh
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


}

enum MacOSVirtualizationBackendError: Error, LocalizedError {
    case notReady(RunnerID)
    case cacheVolumeUnknown, cacheVolumeChanged
    case templateInsideCloneRoot

    var errorDescription: String? {
        switch self {
        case let .notReady(id):
            "macOS runner \(id.value) is not ready."
        case .cacheVolumeUnknown:
            "The guest could not identify the mounted APFS cache volume."
        case .cacheVolumeChanged:
            "The APFS cache disk changed its name, mount point, or volume identity during the job."
        case .templateInsideCloneRoot:
            "Move the macOS template outside the managed runner clone directory before retrying. Subsequent recovery commands may delete templates stored there."
        }
    }
}
