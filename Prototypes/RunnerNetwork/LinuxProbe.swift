import ContainerResource
import ContainerRuntimeClient
import ContainerRuntimeLinuxServer
import ContainerXPC
import Containerization
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import NIO

// Uses the patched runtime over anonymous XPC, without registering a launchd service.
@main
enum LinuxProbe {
    static func main() async {
        do { try await run() } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Linux probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 8 else {
            throw failure("Usage: yieldd-linux-network-probe EMPTY_ROOT KERNEL INITFS ROOTFS RELAY SOCKET_DIR FIXTURE_URL")
        }
        let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw failure("The probe directory must exist and be empty.")
        }
        var rootStat = stat()
        var sourceStat = stat()
        guard stat(root.path, &rootStat) == 0, stat(args[4], &sourceStat) == 0,
            rootStat.st_dev == sourceStat.st_dev
        else { throw failure("The disposable disk must stay on the source disk's quota volume.") }
        let lockPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/yieldd/runner.lock").path
        let lock = open(lockPath, O_RDWR | O_EXLOCK | O_NONBLOCK)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        signal(SIGPIPE, SIG_IGN)

        let relay = try await Task.detached {
            try RunnerNetworkRelay.start(executableURL: URL(fileURLWithPath: args[5]), directory: URL(fileURLWithPath: args[6]))
        }.value
        // Bound boot/XPC failures too. Exiting releases the VM; leave its owned bundle for inspection.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 120)
        watchdog.setEventHandler {
            try? FileHandle.standardError.write(contentsOf: Data("Linux probe exceeded two minutes; retain its bundle for inspection.\n".utf8))
            _exit(124)
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        let signals = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                try? FileHandle.standardError.write(contentsOf: Data("Linux probe interrupted; retain its bundle for inspection.\n".utf8))
                _exit(128 + number)
            }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        do {
            try await runGuest(args: args, root: root, relay: relay)
        } catch {
            do { try await Task.detached { try relay.stop() }.value } catch {
                try? FileHandle.standardError.write(contentsOf: Data("Relay cleanup failed: \(error)\n".utf8))
            }
            throw error
        }
        try await Task.detached { try relay.stop() }.value
    }

    private static func runGuest(args: [String], root: URL, relay: RunnerNetworkRelay) async throws {
        try relay.check()

        let id = "yieldd-network-probe"
        let environment = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "container=container"]
        var config = ContainerConfiguration(
            id: id,
            image: ImageDescription(reference: "local/yieldd-guest:dev", descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + URL(fileURLWithPath: args[4]).deletingLastPathComponent().lastPathComponent,
                size: 0
            )),
            process: ProcessConfiguration(executable: "/sbin/init", arguments: [], environment: environment)
        )
        config.resources.cpus = 4
        config.resources.cpuOverhead = 0
        config.resources.memoryInBytes = 12 * 1024 * 1024 * 1024
        config.networkSocket = relay.socketURL.path
        config.dns = .init(nameservers: ["192.168.127.1"])
        config.capAdd = ["ALL"]
        config.maskedPaths = []
        config.readonlyPaths = []
        let bundle = try ContainerResource.Bundle.create(
            path: root.appendingPathComponent("guest"),
            initialFilesystem: .block(format: "ext4", source: args[3], destination: "/", options: ["ro"]),
            kernel: Kernel(path: URL(fileURLWithPath: args[2]), platform: .linuxArm),
            containerConfiguration: config,
            containerRootFilesystem: .block(format: "ext4", source: args[4], destination: "/", options: [])
        )
        let loops = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var log = Logger(label: "yieldd-linux-network-probe")
        log.logLevel = .warning
        nonisolated(unsafe) let connection = xpc_connection_create(nil, nil)
        let runtime = RuntimeService(root: bundle.path, interfaceStrategies: [:], eventLoopGroup: loops, connection: connection, log: log)
        let server = XPCServer(connection: connection, routes: [
            RuntimeRoutes.bootstrap.rawValue: XPCServer.route(runtime.bootstrap),
            RuntimeRoutes.start.rawValue: XPCServer.route(runtime.startProcess),
            RuntimeRoutes.createProcess.rawValue: XPCServer.route(runtime.createProcess),
            RuntimeRoutes.wait.rawValue: XPCServer.route(runtime.wait),
            RuntimeRoutes.stop.rawValue: XPCServer.route(runtime.stop),
        ], log: log)
        let listener = Task { try await server.listen() }
        let client = XPCClient(connection: xpc_connection_create_from_endpoint(xpc_endpoint_create(connection)), label: id)
        defer { client.close(); listener.cancel() }

        do {
            let bootstrap = XPCMessage(route: RuntimeRoutes.bootstrap.rawValue)
            bootstrap.set(key: RuntimeKeys.dynamicEnv.rawValue, value: try JSONEncoder().encode([String: String]()))
            bootstrap.set(key: RuntimeKeys.networkBootstrapInfos.rawValue, value: try JSONEncoder().encode([NetworkBootstrapInfo]()))
            try await client.send(bootstrap)
            try await start(id, client: client)
            print("Linux VM booted through the patched runtime with only the packet relay.")
            let script = #"""
            set -eu
            test "$(ls /sys/class/net | grep '^eth' | wc -l)" -eq 1
            cat /proc/net/route
            cat /etc/resolv.conf
            getent ahostsv4 github.com | awk 'NR == 1 { print $1 }' > /tmp/yieldd-probe-public-ip
            test -s /tmp/yieldd-probe-public-ip
            cat /tmp/yieldd-probe-public-ip
            curl --noproxy '*' --fail --silent --show-error --max-time 15 -o /dev/null -w 'public HTTPS before denial: %{http_code}\n' https://github.com/
            if curl --noproxy '*' --silent --show-error --connect-timeout 3 --max-time 4 "$1"; then
                echo 'ERROR: guest reached the host fixture' >&2
                exit 1
            fi
            echo 'host fixture denied'
            curl --noproxy '*' --fail --silent --show-error --max-time 15 -o /dev/null -w 'public HTTPS after denial: %{http_code}\n' https://github.com/
            """#
            guard try await execute(script, arguments: [args[7]], environment: environment, client: client) == 0 else {
                throw failure("Linux network checks failed.")
            }
            try await Task.detached { try relay.stop() }.value
            print("Relay stopped; checking fail-closed behavior from the still-running guest.")
            let closed = #"""
            if curl --noproxy '*' --silent --show-error --connect-timeout 3 --max-time 4 \
                --resolve "github.com:443:$(cat /tmp/yieldd-probe-public-ip)" https://github.com/ -o /dev/null; then
                echo 'ERROR: public HTTPS survived relay exit' >&2
                exit 1
            fi
            echo 'public HTTPS unavailable after relay exit'
            """#
            guard try await execute(closed, arguments: [], environment: environment, client: client) == 0 else {
                throw failure("Linux relay-loss check failed.")
            }
            try await stop(client)
            print("Linux runtime stopped its disposable guest.")
        } catch {
            do { try await stop(client) } catch { print("Guest stop failed; retain the probe directory for inspection: \(error)") }
            throw error
        }
        client.close()
        listener.cancel()
        _ = try? await listener.value
        try await loops.shutdownGracefully()
        // The caller removes the owned bundle after this process exits and VZ releases its disks.
        print("Linux live network checks passed. Disposable bundle: \(bundle.path.path)")
    }

    private static func start(_ id: String, client: XPCClient) async throws {
        let request = XPCMessage(route: RuntimeRoutes.start.rawValue)
        request.set(key: RuntimeKeys.id.rawValue, value: id)
        try await client.send(request)
    }

    private static func execute(_ script: String, arguments: [String], environment: [String], client: XPCClient) async throws -> Int64 {
        let id = UUID().uuidString
        let request = XPCMessage(route: RuntimeRoutes.createProcess.rawValue)
        request.set(key: RuntimeKeys.id.rawValue, value: id)
        request.set(key: RuntimeKeys.processConfig.rawValue, value: try JSONEncoder().encode(ProcessConfiguration(
            executable: "/bin/sh", arguments: ["-c", script, "probe"] + arguments, environment: environment,
            user: .raw(userString: "runner")
        )))
        // XPCMessage.set consumes the descriptor. Keep the harness's own output open.
        for (key, descriptor) in [(RuntimeKeys.stdout, STDOUT_FILENO), (.stderr, STDERR_FILENO)] {
            let copy = dup(descriptor)
            guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            request.set(key: key.rawValue, value: FileHandle(fileDescriptor: copy, closeOnDealloc: false))
        }
        try await client.send(request)
        try await start(id, client: client)
        let wait = XPCMessage(route: RuntimeRoutes.wait.rawValue)
        wait.set(key: RuntimeKeys.id.rawValue, value: id)
        return try await client.send(wait).int64(key: RuntimeKeys.exitCode.rawValue)
    }

    private static func stop(_ client: XPCClient) async throws {
        let request = XPCMessage(route: RuntimeRoutes.stop.rawValue)
        request.set(key: RuntimeKeys.stopOptions.rawValue, value: try JSONEncoder().encode(ContainerStopOptions(timeoutInSeconds: 3, signal: "SIGTERM")))
        try await client.send(request)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LinuxNetworkProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
