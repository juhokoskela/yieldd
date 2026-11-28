import Darwin
import Dispatch
import Foundation
import Security

#if arch(arm64)
import Virtualization
#endif

enum VirtualizationEntitlement {
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
    private static let requiredFiles = clonedFiles + ["MachineIdentifier"]

    let url: URL

    static func validateTemplate(at templateURL: URL) throws {
        let templateURL = templateURL.resolvingSymlinksInPath()
        let directoryDescriptor = try openDirectory(
            at: templateURL,
            operation: "Opening the macOS VM template"
        )
        defer { _ = Darwin.close(directoryDescriptor) }

        try validateRequiredFiles(
            in: directoryDescriptor,
            templateURL: templateURL
        )
    }

    static func create(
        templateURL: URL,
        cloneRootURL: URL,
        id: RunnerID = RunnerID(value: "yieldd-virtualization-probe-\(UUID().uuidString.lowercased())")
    ) throws -> Self {
        let store = MacOSRunnerCloneStore(rootURL: cloneRootURL)
        let creatingURL = try store.creatingURL(for: id)
        let publishedURL = try store.bundleURL(for: id)
        let fileManager = FileManager.default
        let machineIdentifier = try machineIdentifierData()
        let templateURL = templateURL.resolvingSymlinksInPath()
        let templateDescriptor = try openDirectory(
            at: templateURL,
            operation: "Opening the macOS VM template"
        )
        defer { _ = Darwin.close(templateDescriptor) }
        try validateRequiredFiles(
            in: templateDescriptor,
            templateURL: templateURL
        )

        try fileManager.createDirectory(
            at: cloneRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: cloneRootURL.path
        )

        let cloneRootURL = cloneRootURL.resolvingSymlinksInPath()
        let cloneURL = creatingURL
        guard Darwin.mkdir(cloneURL.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: cloneURL.path
            )
            let cloneDescriptor = try openDirectory(
                at: cloneURL,
                operation: "Opening the macOS VM clone"
            )
            defer { _ = Darwin.close(cloneDescriptor) }

            for filename in clonedFiles {
                try cloneFile(
                    named: filename,
                    from: templateDescriptor,
                    to: cloneDescriptor,
                    templateURL: templateURL,
                    cloneRootURL: cloneRootURL,
                    cloneURL: cloneURL
                )
            }
            try writePrivateFile(
                machineIdentifier,
                named: "MachineIdentifier",
                to: cloneURL
            )
            // moveItem refuses an existing destination; publish only a complete clone.
            try fileManager.moveItem(at: cloneURL, to: publishedURL)
            return Self(url: publishedURL)
        } catch {
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
        named filename: String,
        from sourceDirectory: Int32,
        to destinationDirectory: Int32,
        templateURL: URL,
        cloneRootURL: URL,
        cloneURL: URL
    ) throws {
        let sourceURL = templateURL.appendingPathComponent(filename)
        let destinationURL = cloneURL.appendingPathComponent(filename)
        let sourceDescriptor = try openRegularFile(
            named: filename,
            in: sourceDirectory,
            fileURL: sourceURL
        )
        defer { _ = Darwin.close(sourceDescriptor) }

        let (result, errorNumber) = filename.withCString { destinationName in
            let result = Darwin.fclonefileat(
                sourceDescriptor,
                destinationDirectory,
                destinationName,
                UInt32(CLONE_NOOWNERCOPY | CLONE_NOFOLLOW_ANY)
            )
            return (result, result == 0 ? 0 : errno)
        }
        guard result == 0 else {
            throw cloneError(
                errorNumber: errorNumber,
                templateURL: templateURL,
                cloneRootURL: cloneRootURL,
                destinationURL: destinationURL
            )
        }
        try setPermissions(
            0o600,
            named: filename,
            in: destinationDirectory,
            url: destinationURL
        )
    }

    static func cloneError(
        errorNumber: Int32,
        templateURL: URL,
        cloneRootURL: URL,
        destinationURL: URL
    ) -> MacOSVirtualizationProbeError {
        switch errorNumber {
        case EXDEV:
            .cloneRequiresSameVolume(
                templatePath: templateURL.path,
                cloneRootPath: cloneRootURL.path
            )
        case ENOTSUP:
            .cloneUnsupported(
                templatePath: templateURL.path,
                cloneRootPath: cloneRootURL.path
            )
        default:
            fileOperationError(
                operation: "Cloning the macOS VM template file",
                url: destinationURL,
                errorNumber: errorNumber
            )
        }
    }

    private static func validateRequiredFiles(
        in directoryDescriptor: Int32,
        templateURL: URL
    ) throws {
        for filename in requiredFiles {
            let descriptor = try openRegularFile(
                named: filename,
                in: directoryDescriptor,
                fileURL: templateURL.appendingPathComponent(filename)
            )
            _ = Darwin.close(descriptor)
        }
    }

    private static func openRegularFile(
        named filename: String,
        in directoryDescriptor: Int32,
        fileURL: URL
    ) throws -> Int32 {
        let (descriptor, errorNumber) = filename.withCString { name in
            let descriptor = Darwin.openat(
                directoryDescriptor,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            return (descriptor, descriptor >= 0 ? 0 : errno)
        }
        guard descriptor >= 0 else {
            throw fileOperationError(
                operation: "Opening the macOS VM template file",
                url: fileURL,
                errorNumber: errorNumber
            )
        }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            let errorNumber = errno
            _ = Darwin.close(descriptor)
            throw fileOperationError(
                operation: "Inspecting the macOS VM template file",
                url: fileURL,
                errorNumber: errorNumber
            )
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw MacOSVirtualizationProbeError.templateFileIsNotRegular(
                path: fileURL.path
            )
        }
        return descriptor
    }

    private static func openDirectory(
        at url: URL,
        operation: String
    ) throws -> Int32 {
        let (descriptor, errorNumber) = url.path.withCString { path in
            let descriptor = Darwin.open(
                path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            )
            return (descriptor, descriptor >= 0 ? 0 : errno)
        }
        guard descriptor >= 0 else {
            throw fileOperationError(
                operation: operation,
                url: url,
                errorNumber: errorNumber
            )
        }
        return descriptor
    }

    private static func setPermissions(
        _ permissions: mode_t,
        named filename: String,
        in directoryDescriptor: Int32,
        url: URL
    ) throws {
        let (result, errorNumber) = filename.withCString { name in
            let result = Darwin.fchmodat(
                directoryDescriptor,
                name,
                permissions,
                AT_SYMLINK_NOFOLLOW
            )
            return (result, result == 0 ? 0 : errno)
        }
        guard result == 0 else {
            throw fileOperationError(
                operation: "Setting private permissions",
                url: url,
                errorNumber: errorNumber
            )
        }
    }

    private static func writePrivateFile(
        _ data: Data,
        named filename: String,
        to directoryURL: URL
    ) throws {
        let fileURL = directoryURL.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func fileOperationError(
        operation: String,
        url: URL,
        errorNumber: Int32
    ) -> MacOSVirtualizationProbeError {
        .fileOperationFailed(
            operation: operation,
            path: url.path,
            code: POSIXErrorCode(rawValue: errorNumber) ?? .EIO
        )
    }

    private static func machineIdentifierData() throws -> Data {
#if arch(arm64)
        VZMacMachineIdentifier().dataRepresentation
#else
        throw MacOSVirtualizationProbeError.requiresAppleSilicon
#endif
    }

}

enum MacOSVirtualMachineState {
    case stopped
    case running
    case stoppable
    case transitioning
    case failed(any Error)
}

enum MacOSVirtualMachineStopOutcome: Sendable {
    case stopped
    case retry
}

protocol MacOSVirtualMachineControlling: Sendable {
    var state: MacOSVirtualMachineState { get }

    func start(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    )
    func forceStop(
        completion:
            @escaping @Sendable (
                Result<MacOSVirtualMachineStopOutcome, any Error>
            ) -> Void
    )
}

private let macOSVirtualMachineCheckInterval: TimeInterval = 0.1

enum MacOSVirtualMachineLifecycle {
    static let bootTimeout: TimeInterval = 60
    static let stopTimeout: TimeInterval = 15
    static let memoryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let constrainedMemoryBytes = memoryBytes * 3 / 4

    static func requireRunning(
        _ machine: any MacOSVirtualMachineControlling
    ) throws {
        switch machine.state {
        case .running:
            break
        case .failed(let error):
            throw MacOSVirtualizationProbeError.virtualMachineFailed(error)
        case .stopped, .stoppable, .transitioning:
            throw MacOSVirtualizationProbeError.stoppedUnexpectedly
        }
    }

    static func forceStop(
        _ machine: any MacOSVirtualMachineControlling,
        timeout: TimeInterval,
        checkDeadline: () throws -> Void = {}
    ) throws {
        let deadline = continuousMonotonicSeconds() + timeout

        while true {
            // A terminally failed VM cannot be stopped. Its owner must release it.
            if case .failed = machine.state { return }
            try checkDeadline()
            let completion = VirtualMachineCompletion<MacOSVirtualMachineStopOutcome>()
            machine.forceStop(completion: completion.complete)
            let outcome: MacOSVirtualMachineStopOutcome
            do {
                outcome = try completion.wait(
                    operation: "stopping the macOS virtual machine",
                    deadline: deadline,
                    checkCancellation: checkDeadline
                )
            } catch {
                if case .failed = machine.state { return }
                throw error
            }
            switch outcome {
            case .stopped:
                return
            case .retry:
                let remaining = deadline - continuousMonotonicSeconds()
                guard remaining > 0 else {
                    throw MacOSVirtualizationProbeError.timedOut(
                        operation: "stopping the macOS virtual machine"
                    )
                }
                Thread.sleep(
                    forTimeInterval: min(
                        remaining,
                        macOSVirtualMachineCheckInterval
                    ))
            }
        }
    }

    static func memoryBytes(for allocation: RunnerMemoryAllocation) -> UInt64 {
        switch allocation {
        case .constrained:
            constrainedMemoryBytes
        case .full:
            memoryBytes
        }
    }

    static func requireSupportedHost() throws {
#if arch(arm64)
        guard VZVirtualMachine.isSupported else {
            throw MacOSVirtualizationProbeError.virtualizationUnavailable
        }
#else
        throw MacOSVirtualizationProbeError.requiresAppleSilicon
#endif
    }

#if arch(arm64)
    static func makeAudioDevice() -> VZVirtioSoundDeviceConfiguration {
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        // A nil sink keeps guest playback silent without using the host's audio devices.
        let device = VZVirtioSoundDeviceConfiguration()
        device.streams = [output]
        return device
    }
#endif

    static func makeMachine(
        bundleURL: URL,
        memoryBytes: UInt64,
        networkSocketURL: URL
    ) throws -> any MacOSVirtualMachineControlling {
#if arch(arm64)
        try requireSupportedHost()
        return try VirtualizationFrameworkMachine(
            bundleURL: bundleURL, memoryBytes: memoryBytes,
            packetSocket: try PacketSocket(path: networkSocketURL.path)
        )
#else
        throw MacOSVirtualizationProbeError.requiresAppleSilicon
#endif
    }
}

#if arch(arm64)
private final class VirtualizationFrameworkMachine: NSObject, @unchecked Sendable,
    MacOSVirtualMachineControlling, VZVirtualMachineDelegate
{
    private static let virtualCPUs = 4

    private let queue: DispatchQueue
    private let machine: VZVirtualMachine
    private let packetSocket: PacketSocket
    private var failure: (any Error)?

    init(bundleURL: URL, memoryBytes: UInt64, packetSocket: PacketSocket) throws {
        self.packetSocket = packetSocket
        let configuration = try Self.configuration(
            bundleURL: bundleURL,
            memoryBytes: memoryBytes,
            packetSocket: packetSocket
        )
        try configuration.validate()

        let queue = DispatchQueue(label: "dev.yieldd.macos-vm-probe")
        self.queue = queue
        machine = VZVirtualMachine(configuration: configuration, queue: queue)
        super.init()
        queue.sync {
            machine.delegate = self
        }
    }

    var state: MacOSVirtualMachineState {
        queue.sync {
            switch machine.state {
            case .stopped:
                .stopped
            case .error:
                .failed(failure ?? MacOSVirtualizationProbeError.virtualMachineEnteredErrorState)
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
        completion:
            @escaping @Sendable (
                Result<MacOSVirtualMachineStopOutcome, any Error>
            ) -> Void
    ) {
        queue.async {
            switch self.machine.state {
            case .stopped:
                completion(.success(.stopped))
                return
            case .error:
                completion(
                    .failure(
                        self.failure
                            ?? MacOSVirtualizationProbeError.virtualMachineEnteredErrorState
                    ))
                return
            default:
                guard self.machine.canStop else {
                    completion(.success(.retry))
                    return
                }
            }

            self.machine.stop { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(.stopped))
                }
            }
        }
    }

    func virtualMachine(
        _: VZVirtualMachine,
        didStopWithError error: any Error
    ) {
        failure = error
    }

    private static func configuration(
        bundleURL: URL,
        memoryBytes: UInt64,
        packetSocket: PacketSocket
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

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.platform = platform
        configuration.cpuCount = virtualCPUs
        configuration.memorySize = memoryBytes
        configuration.storageDevices = [storage]
        configuration.graphicsDevices = [graphics]
        configuration.networkDevices = [packetSocket.device()]
        configuration.audioDevices = [MacOSVirtualMachineLifecycle.makeAudioDevice()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        return configuration
    }
}
#endif

final class VirtualMachineCompletion<Success: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Success, any Error>?

    func complete(_ result: Result<Success, any Error>) {
        condition.withLock {
            precondition(self.result == nil, "Virtual machine completion invoked more than once")
            self.result = result
            condition.broadcast()
        }
    }

    func wait(
        operation: String,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void = {}
    ) throws -> Success {
        while true {
            if let result = condition.withLock({ self.result }) {
                return try result.get()
            }
            try checkCancellation()

            let remaining = deadline - continuousMonotonicSeconds()
            guard remaining > 0 else {
                throw MacOSVirtualizationProbeError.timedOut(
                    operation: operation
                )
            }
            condition.withLock {
                guard self.result == nil else {
                    return
                }
                _ = condition.wait(
                    until: Date(
                        timeIntervalSinceNow: min(
                            remaining,
                            macOSVirtualMachineCheckInterval
                        )
                    ))
            }
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
    case templateFileIsNotRegular(path: String)
    case cloneRequiresSameVolume(templatePath: String, cloneRootPath: String)
    case cloneUnsupported(templatePath: String, cloneRootPath: String)
    case fileOperationFailed(operation: String, path: String, code: POSIXErrorCode)
    case timedOut(operation: String)
    case stoppedUnexpectedly
    case virtualMachineEnteredErrorState
    case virtualMachineFailed(any Error)
    case operationAndCleanupFailed(operation: any Error, cleanup: any Error)
}

extension MacOSVirtualizationProbeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingEntitlement:
            "This executable lacks the com.apple.security.virtualization entitlement. "
                + "Use the executable inside the packaged yieldd.app."
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
        case let .templateFileIsNotRegular(path):
            "The macOS VM template file is not a regular file: \(path)"
        case let .cloneRequiresSameVolume(templatePath, cloneRootPath):
            "The macOS VM template at \(templatePath) must be on the same volume as \(cloneRootPath)."
        case let .cloneUnsupported(templatePath, cloneRootPath):
            "The filesystem containing the macOS VM template at \(templatePath) "
                + "and clone root at \(cloneRootPath) does not support copy-on-write clones."
        case let .fileOperationFailed(operation, path, code):
            "\(operation) failed for \(path): \(POSIXError(code).localizedDescription)"
        case let .timedOut(operation):
            "Timed out while \(operation)."
        case .stoppedUnexpectedly:
            "The macOS virtual machine stopped before the probe completed."
        case .virtualMachineEnteredErrorState:
            "The macOS virtual machine entered an error state without reporting a reason."
        case let .virtualMachineFailed(error):
            "The macOS virtual machine failed: \(describeError(error))"
        case let .operationAndCleanupFailed(operation, cleanup):
            "macOS VM probe failed: \(describeError(operation)). "
                + "Cleanup also failed: \(describeError(cleanup))"
        }
    }
}
