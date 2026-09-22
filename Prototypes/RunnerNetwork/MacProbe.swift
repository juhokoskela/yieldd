import Darwin
import Foundation
import Virtualization

@main
@MainActor
enum MacProbe {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Prototype failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw NSError(domain: "Prototype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: mac-network-probe TEMPLATE CLONE_ROOT RELAY_EXECUTABLE"])
        }
        let template = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        let lockPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/yieldd/runner.lock").path
        let lock = open(lockPath, O_RDWR | O_EXLOCK | O_NONBLOCK)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        var templateStat = stat()
        var rootStat = stat()
        guard stat(template.path, &templateStat) == 0, stat(root.path, &rootStat) == 0,
            templateStat.st_dev == rootStat.st_dev, root.lastPathComponent == "macos-probes"
        else {
            throw POSIXError(.EXDEV)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[3])
        let relay = try await Task.detached { try RunnerNetworkRelay.start(executableURL: executable) }.value
        print("Packet relay SSH endpoint: 127.0.0.1:\(relay.sshPort)")
        do {
            try await runGuest(template: template, root: root, relay: relay)
        } catch {
            do { try await Task.detached { try relay.stop() }.value } catch {
                try? FileHandle.standardError.write(contentsOf: Data("Relay cleanup failed: \(error)\n".utf8))
            }
            throw error
        }
        try await Task.detached { try relay.stop() }.value
    }

    private static func runGuest(template: URL, root: URL, relay: RunnerNetworkRelay) async throws {
        let clone = root.appendingPathComponent("yieldd-net-\(UUID().uuidString.lowercased()).bundle")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var mayBeRunning = false
        defer {
            if !mayBeRunning { try? FileManager.default.removeItem(at: clone) } else { print("VM stop was not confirmed; retained prototype clone at \(clone.path)") }
        }
        for name in ["HardwareModel", "AuxiliaryStorage", "Disk.img"] {
            guard clonefile(template.appendingPathComponent(name).path, clone.appendingPathComponent(name).path, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard let hardware = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: clone.appendingPathComponent("HardwareModel"))), hardware.isSupported else {
            throw POSIXError(.ENOTSUP)
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardware
        platform.machineIdentifier = VZMacMachineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: clone.appendingPathComponent("AuxiliaryStorage"))
        let socket = try PacketSocket(path: relay.socketURL.path)
        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = 4
        config.memorySize = 8 * 1024 * 1024 * 1024
        config.networkDevices = [try socket.device()]
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: clone.appendingPathComponent("Disk.img"), readOnly: false))
        ]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 80)]
        config.graphicsDevices = [graphics]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration()]
        try config.validate()
        let vm = VZVirtualMachine(configuration: config)
        var interrupted = false
        let signals = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { interrupted = true }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        mayBeRunning = true
        do {
            try await vm.start()
            print("Disposable macOS guest started on packet relay only. Stopping in 120 seconds.")
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while !interrupted && ContinuousClock.now < deadline && vm.state == .running {
                try relay.check()
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch {
            if vm.canStop { try await vm.stop() }
            mayBeRunning = vm.state != .stopped && vm.state != .error
            throw error
        }
        if vm.canStop { try await vm.stop() }
        mayBeRunning = vm.state != .stopped && vm.state != .error
        withExtendedLifetime(socket) {}
        print("Prototype VM stopped.")
    }
}
