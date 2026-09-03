import Darwin
import Dispatch
import Foundation
import Security

#if arch(arm64)
import Virtualization
#endif

private enum VirtualizationEntitlement {
    static let name = "com.apple.security.virtualization"

    static func requireCurrentProcess() throws {
        guard let task = SecTaskCreateFromSelf(nil) else {
            throw MacOSVirtualizationProbeError.entitlementLookupFailed
        }

        var unmanagedError: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(
            task,
            name as CFString,
            &unmanagedError
        )
        let lookupError = unmanagedError?.takeRetainedValue()
        guard (value as? NSNumber)?.boolValue == true else {
            if lookupError != nil {
                throw MacOSVirtualizationProbeError.entitlementLookupFailed
            }
            throw MacOSVirtualizationProbeError.missingEntitlement
        }
    }
}

struct MacOSVirtualizationProbeClone {
    private static let clonedFiles = [
        "HardwareModel",
        "AuxiliaryStorage",
        "Disk.img",
    ]

    let url: URL

    static func create(templateURL: URL, cloneRootURL: URL) throws -> Self {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: cloneRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let templateURL = templateURL.resolvingSymlinksInPath()
        let cloneRootURL = cloneRootURL.resolvingSymlinksInPath()
        let cloneURL = cloneRootURL.appendingPathComponent(
            "yieldd-virtualization-probe-\(UUID().uuidString.lowercased()).bundle",
            isDirectory: true
        )
        var created = false

        do {
            try fileManager.createDirectory(
                at: cloneURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            created = true
            for filename in clonedFiles {
                try cloneFile(
                    from: templateURL.appendingPathComponent(filename),
                    to: cloneURL.appendingPathComponent(filename),
                    templateURL: templateURL,
                    cloneRootURL: cloneRootURL
                )
            }
            try machineIdentifierData().write(
                to: cloneURL.appendingPathComponent("MachineIdentifier"),
                options: .atomic
            )
            return Self(url: cloneURL)
        } catch {
            guard created else {
                throw error
            }
            do {
                try fileManager.removeItem(at: cloneURL)
            } catch let cleanupError {
                throw MacOSVirtualizationProbeError.operationAndCleanupFailed(
                    operation: error,
                    cleanup: cleanupError
                )
            }
            throw error
        }
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }

    private static func cloneFile(
        from sourceURL: URL,
        to destinationURL: URL,
        templateURL: URL,
        cloneRootURL: URL
    ) throws {
        let sourceDescriptor = sourceURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(sourceDescriptor) }

        let result = destinationURL.path.withCString { destinationPath in
            Darwin.fclonefileat(
                sourceDescriptor,
                AT_FDCWD,
                destinationPath,
                UInt32(CLONE_NOOWNERCOPY)
            )
        }
        guard result == 0 else {
            let errorNumber = errno
            if errorNumber == EXDEV {
                throw MacOSVirtualizationProbeError.cloneRequiresSameVolume(
                    templatePath: templateURL.path,
                    cloneRootPath: cloneRootURL.path
                )
            }
            throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
        }
    }

    private static func machineIdentifierData() throws -> Data {
#if arch(arm64)
        VZMacMachineIdentifier().dataRepresentation
#else
        throw MacOSVirtualizationProbeError.requiresAppleSilicon
#endif
    }
}

enum MacOSVirtualMachineState: Equatable {
    case stopped
    case running
    case stoppable
    case transitioning
}

protocol MacOSVirtualMachineControlling: Sendable {
    var state: MacOSVirtualMachineState { get }

    func start(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    )
    func forceStop(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    )
}

struct MacOSVirtualizationProbe {
    static let bootTimeout: TimeInterval = 60
    static let stopTimeout: TimeInterval = 15
    static let runDuration: TimeInterval = 5
    static let memoryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    private static let checkInterval: TimeInterval = 0.1

    private let requireEntitlement: () throws -> Void
    private let makeMachine: (URL) throws -> any MacOSVirtualMachineControlling

    init(
        requireEntitlement: @escaping () throws -> Void =
            VirtualizationEntitlement.requireCurrentProcess,
        makeMachine: @escaping (URL) throws -> any MacOSVirtualMachineControlling =
            MacOSVirtualizationProbe.makeMachine
    ) {
        self.requireEntitlement = requireEntitlement
        self.makeMachine = makeMachine
    }

    func run(
        templateURL: URL,
        cloneRootURL: URL,
        checkCancellation: () throws -> Void = {},
        wait: (TimeInterval) throws -> Void = Thread.sleep(forTimeInterval:),
        started: () -> Void = {}
    ) throws {
        try requireEntitlement()
        try checkCancellation()
        let clone = try MacOSVirtualizationProbeClone.create(
            templateURL: templateURL,
            cloneRootURL: cloneRootURL
        )
        var machine: (any MacOSVirtualMachineControlling)?
        let operation = Result<Void, any Error> {
            try checkCancellation()
            let createdMachine = try makeMachine(clone.url)
            machine = createdMachine
            let completion = VirtualMachineCompletion()
            createdMachine.start(completion: completion.complete)
            try completion.wait(
                operation: "starting the macOS virtual machine",
                timeout: Self.bootTimeout,
                checkCancellation: checkCancellation
            )
            started()
            try wait(Self.runDuration)
            try checkCancellation()
            guard createdMachine.state == .running else {
                throw MacOSVirtualizationProbeError.stoppedUnexpectedly
            }
        }
        let cleanup = Result<Void, any Error> {
            if let machine {
                try forceStop(machine, timeout: Self.stopTimeout)
            }
            try clone.remove()
        }

        switch (operation, cleanup) {
        case (.success, .success):
            try checkCancellation()
        case let (.failure(operationError), .success):
            throw operationError
        case let (.success, .failure(stopError)):
            throw stopError
        case let (.failure(operationError), .failure(stopError)):
            throw MacOSVirtualizationProbeError.operationAndCleanupFailed(
                operation: operationError,
                cleanup: stopError
            )
        }
    }

    private func forceStop(
        _ machine: any MacOSVirtualMachineControlling,
        timeout: TimeInterval
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout

        while true {
            switch machine.state {
            case .stopped:
                return
            case .running, .stoppable:
                let completion = VirtualMachineCompletion()
                machine.forceStop(completion: completion.complete)
                do {
                    try completion.wait(
                        operation: "stopping the macOS virtual machine",
                        deadline: deadline
                    )
                } catch {
                    guard machine.state == .stopped else {
                        throw error
                    }
                }
                return
            case .transitioning:
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw MacOSVirtualizationProbeError.timedOut(
                        operation: "stopping the macOS virtual machine"
                    )
                }
                Thread.sleep(forTimeInterval: Self.checkInterval)
            }
        }
    }

    private static func makeMachine(
        bundleURL: URL
    ) throws -> any MacOSVirtualMachineControlling {
#if arch(arm64)
        guard VZVirtualMachine.isSupported else {
            throw MacOSVirtualizationProbeError.virtualizationUnavailable
        }
        return try VirtualizationFrameworkMachine(bundleURL: bundleURL)
#else
        throw MacOSVirtualizationProbeError.requiresAppleSilicon
#endif
    }
}

#if arch(arm64)
private final class VirtualizationFrameworkMachine: @unchecked Sendable,
    MacOSVirtualMachineControlling
{
    private static let virtualCPUs = 4

    private let queue: DispatchQueue
    private let machine: VZVirtualMachine

    init(bundleURL: URL) throws {
        let configuration = try Self.configuration(bundleURL: bundleURL)
        try configuration.validate()

        let queue = DispatchQueue(label: "dev.yieldd.macos-vm-probe")
        self.queue = queue
        machine = VZVirtualMachine(configuration: configuration, queue: queue)
    }

    var state: MacOSVirtualMachineState {
        queue.sync {
            switch machine.state {
            case .stopped, .error:
                .stopped
            case .running:
                .running
            default:
                machine.canStop ? .stoppable : .transitioning
            }
        }
    }

    func start(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        queue.async {
            self.machine.start(completionHandler: completion)
        }
    }

    func forceStop(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        queue.async {
            self.machine.stop { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    private static func configuration(
        bundleURL: URL
    ) throws -> VZVirtualMachineConfiguration {
        let hardwareModelURL = bundleURL.appendingPathComponent("HardwareModel")
        let machineIdentifierURL = bundleURL.appendingPathComponent("MachineIdentifier")
        let auxiliaryStorageURL = bundleURL.appendingPathComponent("AuxiliaryStorage")
        let diskURL = bundleURL.appendingPathComponent("Disk.img")

        guard let hardwareModel = VZMacHardwareModel(
            dataRepresentation: try Data(contentsOf: hardwareModelURL)
        ) else {
            throw MacOSVirtualizationProbeError.invalidHardwareModel(
                path: hardwareModelURL.path
            )
        }
        guard hardwareModel.isSupported else {
            throw MacOSVirtualizationProbeError.unsupportedHardwareModel
        }
        guard let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: try Data(contentsOf: machineIdentifierURL)
        ) else {
            throw MacOSVirtualizationProbeError.invalidMachineIdentifier(
                path: machineIdentifierURL.path
            )
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorageURL)

        let storageAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        let storage = VZVirtioBlockDeviceConfiguration(
            attachment: storageAttachment
        )

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: 1_920,
            heightInPixels: 1_080,
            pixelsPerInch: 80
        )]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = VZMACAddress.randomLocallyAdministered()

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.platform = platform
        configuration.cpuCount = virtualCPUs
        configuration.memorySize = MacOSVirtualizationProbe.memoryBytes
        configuration.storageDevices = [storage]
        configuration.graphicsDevices = [graphics]
        configuration.networkDevices = [network]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        return configuration
    }
}
#endif

private final class VirtualMachineCompletion: @unchecked Sendable {
    private static let checkInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var result: Result<Void, any Error>?

    func complete(_ result: Result<Void, any Error>) {
        lock.withLock {
            precondition(self.result == nil, "Virtual machine completion invoked more than once")
            self.result = result
        }
        signal.signal()
    }

    func wait(
        operation: String,
        timeout: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws {
        try wait(
            operation: operation,
            deadline: ProcessInfo.processInfo.systemUptime + timeout,
            checkCancellation: checkCancellation
        )
    }

    func wait(
        operation: String,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void = {}
    ) throws {
        while true {
            if let result = lock.withLock({ self.result }) {
                return try result.get()
            }
            try checkCancellation()

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw MacOSVirtualizationProbeError.timedOut(
                    operation: operation
                )
            }
            _ = signal.wait(timeout: .now() + .milliseconds(
                max(1, Int((min(remaining, Self.checkInterval) * 1_000).rounded(.up)))
            ))
        }
    }
}

enum MacOSVirtualizationProbeError: Error {
    case missingEntitlement
    case entitlementLookupFailed
    case virtualizationUnavailable
    case requiresAppleSilicon
    case invalidHardwareModel(path: String)
    case unsupportedHardwareModel
    case invalidMachineIdentifier(path: String)
    case cloneRequiresSameVolume(templatePath: String, cloneRootPath: String)
    case timedOut(operation: String)
    case stoppedUnexpectedly
    case operationAndCleanupFailed(operation: any Error, cleanup: any Error)
}

extension MacOSVirtualizationProbeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingEntitlement:
            "This executable lacks the com.apple.security.virtualization entitlement. "
                + "Run the probe from the packaged yieldd.app."
        case .entitlementLookupFailed:
            "Could not read the current process's virtualization entitlement."
        case .virtualizationUnavailable:
            "Virtualization.framework is unavailable on this host."
        case .requiresAppleSilicon:
            "macOS runners require Apple silicon."
        case let .invalidHardwareModel(path):
            "The macOS VM hardware model is invalid: \(path)"
        case .unsupportedHardwareModel:
            "The macOS VM hardware model is not supported on this host."
        case let .invalidMachineIdentifier(path):
            "The macOS VM machine identifier is invalid: \(path)"
        case let .cloneRequiresSameVolume(templatePath, cloneRootPath):
            "The macOS VM template at \(templatePath) must be on the same volume as \(cloneRootPath)."
        case let .timedOut(operation):
            "Timed out while \(operation)."
        case .stoppedUnexpectedly:
            "The macOS virtual machine stopped before the probe completed."
        case let .operationAndCleanupFailed(operation, cleanup):
            "macOS VM probe failed: \(describeError(operation)). "
                + "Cleanup also failed: \(describeError(cleanup))"
        }
    }
}
