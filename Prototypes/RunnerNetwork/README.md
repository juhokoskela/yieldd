# Runner network prototype

Experimental only. Normal yieldd commands still use their existing networking. Do not run hostile workloads through this prototype or treat it as a finished sandbox.

Each guest gets one `VZFileHandleNetworkDeviceAttachment`, connected to its own host-side relay through a private Unix datagram socket. The relay uses gVisor's TCP/IP stack via `gvisor-tap-vsock`. A small upstream patch lets yieldd check the numeric destination immediately before opening a host TCP or UDP socket. There is no vmnet interface, host-address translation, or guest-accessible HTTP management service.

The policy denies private, loopback, link-local, shared-address, multicast, reserved, documentation, and current host-interface addresses. It rejects static forbidden ranges before inspecting interfaces. Public candidates require a fresh host-address lookup for every new outgoing connection; lookup failure denies the connection. A private address returned by DNS still fails the connection check. Host-to-guest SSH uses a loopback-only ephemeral port and does not grant reverse access to host services.

Guest DNS goes directly to Cloudflare's public resolver at `1.1.1.1:53` over TCP, through the same destination check. It never uses the Mac's resolver, hosts file, search domains, VPN DNS, or mDNS, and does not fall back to them on failure. The service forwards only Internet-class A queries. It returns no addresses for AAAA queries and refuses other record types, single-label names, `.local`, `.localhost`, and `home.arpa`. At most 16 upstream queries run concurrently. Public DNS and other permitted Internet traffic can still carry arbitrary data; this is not an exfiltration filter.

The relay attempts to write cumulative counts of denied destinations, dropped frames, and rejected DNS queries to stderr every 30 seconds and on shutdown. Counter reporting is best effort: process exit never waits for it, so final totals may be lost even on normal shutdown. Fatal-error reporting gets at most 100 ms before exit. It does not log queried names, destinations, or individual packets. The private `0700` parent directory protects the socket during creation, before its own mode becomes `0600`.

Both probes use `Sources/Yieldd/RunnerNetworkRelay.swift` to own the relay process. Startup requires a version-1 JSON readiness response, bounded to 1 KiB, with a loopback SSH port. The owner keeps a close-on-exec pipe open; EOF or any input revokes the relay's lifetime. This also stops the relay when the owner dies, without a fixed job-duration limit or a stored PID used for recovery. Explicit shutdown closes that pipe, allows one second to exit, then sends TERM and finally KILL if needed. The supervisor removes its private socket directory only after confirming that the process exited.

This first version supports IPv4 TCP and UDP. It drops IPv6, VLAN frames, IP options, fragmented packets, spoofed source identities, and oversized frames. IPv6 Internet access is not implemented.

## Build and check

Run from the yieldd checkout:

```sh
bash Prototypes/RunnerNetwork/check.sh
```

This macOS check builds and signs both probes, runs the relay tests with the race detector, runs `go vet`, builds the modified Container services, and runs the Swift configuration, socket, VM-lifecycle, and relay-supervisor tests. The supervisor tests include the real Go relay. The macOS lifecycle tests use a controlled clock and callbacks to cover stalled startup, interruption, late startup, and bounded cleanup without a VM. The check does not boot a VM or change installed services. The prototype-only GitHub workflow runs the same command when the prototype or shared supervisor changes.

Public-network and fuzz checks are separate:

```sh
(cd Prototypes/RunnerNetwork && YIELDD_NETWORK_LIVE=1 go test -run TestPublicHTTPS -v -timeout 30s)
(cd Prototypes/RunnerNetwork && go test -run '^$' -fuzz FuzzFrameBoundary -fuzztime 10s -parallel 2)
```

The preparation script creates pinned source checkouts under `.build/`, applies the two checked-in patches, builds the relay and both probes, and ad-hoc signs the probes with the existing virtualization entitlement. It refreshes generated copies of `PacketSocket.swift`, `LinuxProbe.swift`, `PacketSocketTests.swift`, `MacProbeLifecycle.swift`, and `MacProbeLifecycleTests.swift` from this directory, plus `RunnerNetworkRelay.swift` from `Sources/Yieldd/`. Edit those originals, not their `.build/` copies. It does not install, stop, or reconfigure Apple Container. Go dependencies belong to this separate prototype module, not the coordinator.

The socket-level tests use a second gVisor stack as the guest and exchange real Ethernet datagrams. They cover denied TCP/UDP traffic, host-to-guest connections, malformed frames, private socket directories, occupied socket paths, and cancellation both before connection and with a guest and SSH client connected. The TCP denial test uses a simulated public host address and a real loopback listener behind the checked dial boundary; it also checks a private destination. It does not require a LAN interface or skip when one is absent. Separate live VM evidence appears below. DNS tests exercise both guest transports against a controlled upstream and assert the public destination. Policy tests verify that new connections use updated host addresses. Swift tests exercise the actual socket adapter's datagram exchange, permissions, failure cleanup, and path rejection without a VM. The opt-in live test resolves `github.com` through the guest DNS service and makes a certificate-verified HTTPS request through the relay.

Socket tests honor a short, writable `TMPDIR`. If its path would exceed Darwin's 104-byte Unix socket limit, they use `/tmp`. Set a shorter `TMPDIR` when `/tmp` is unavailable.

Tests that create an upstream network run in separate child processes, matching the relay's ownership model. Upstream DHCP, DNS, and stack workers live until process exit; repeatedly creating networks in one test process accumulates them. Cancellation tests still require the relay to return, close SSH clients, and remove its socket before the child exits.

Process tests cover readiness validation, startup failure and cancellation, unexpected relay exit, idempotent cleanup, and a child that ignores EOF and TERM. Separate Go process tests revoke the lifetime pipe through EOF, input, and abrupt owner death, and check shutdown on SIGTERM while the owner remains connected. They require the relay process, socket, and SSH connection to close within bounded deadlines. EOF, owner death, and startup failure are also tested with a full stderr pipe that is never drained.

## Disposable macOS probe

First confirm that configured runner storage is mounted and no job is active:

```sh
.build/yieldd.app/Contents/MacOS/yieldd storage status
.build/mac-network-probe \
  /Volumes/YielddRunners/VM.bundle \
  /Volumes/YielddRunners/macos-probes \
  "$PWD/.build/network-prototype"
```

The probe holds yieldd's existing ownership lock, starts its relay, copies the template's disk and auxiliary storage using APFS clones, and starts an 8 GiB VM. It prints the loopback SSH port and uses only the relay interface. VM startup and runtime share a two-minute budget. SIGINT/SIGTERM/SIGHUP and relay exit are checked while startup is pending as well as during execution. Cleanup gets a separate 15 seconds, including time waiting for the VM to become stoppable. If shutdown cannot be confirmed, the probe reports the failure and retains the clone; it still shuts down the relay and exits. It removes the clone only after confirmed shutdown or terminal VM failure. These bounds are for the experiment, not proposed job execution limits. A crash or failed shutdown can leave a `.bundle` in `macos-probes`; normal yieldd recovery sweeps that directory.

In another terminal, connect using the printed port and the template's pinned key:

```sh
ssh -F /dev/null \
  -i /Volumes/YielddRunners/VM.bundle/SSHPrivateKey \
  -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes \
  -o GlobalKnownHostsFile=/dev/null \
  -o UserKnownHostsFile=/Volumes/YielddRunners/VM.bundle/SSHKnownHosts \
  -o HostKeyAlias=yieldd-macos-template -o StrictHostKeyChecking=yes \
  -p REPLACE_PORT runner@127.0.0.1 \
  '/usr/bin/curl --noproxy "*" --max-time 10 --silent --show-error --output /dev/null --write-out "%{http_code}" https://github.com/'
```

`host-fixture.py` provides an optional two-minute fixed-response listener for a controlled negative test. It serves no files or commands. Reach `/yieldd-network-probe` from the host first, then attempt that same host address and port from the guest. Do not substitute existing service ports or scan the LAN.

## Apple Container fork

`container.patch` targets Apple Container 1.3.1 at `a9a62e28f6beb88940122a3d7b286f2d5ae8053a`. It adds an experimental `network-socket` machine setting and a typed `ContainerConfiguration.networkSocket` field, replaces the built-in network with the socket attachment, and disables SSH-agent forwarding in that mode. Labels cannot select the attachment. It requires `home-mount=none`; the runtime refuses another network alongside the relay.

The shared `PacketSocket.swift` is copied into the fork during preparation. No Containerization dependency fork is needed. Compile and run the configuration tests without starting any service:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path .build/network-container --target ContainerRuntimeLinuxServer -j 6
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path .build/network-container --target MachineAPIService -j 6
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path .build/network-container --filter MachineConfigTests -j 6
```

Do not run the fork's `system start` or `make install` on this host yet. The API server uses the same launchd service name as the installed Container service, even with a different data root. The Linux probe below runs the patched runtime over anonymous, in-process XPC instead.

`gvproxy.patch` targets `gvisor-tap-vsock` v0.8.9 at `9cfc86f66679ef0feed0f20ba1df558fe2bef5c6`. Its hook runs after address translation for both TCP and UDP. It also accepts a replacement DNS handler so the built-in host resolver is not started. The relay supplies both policies explicitly. Dependencies with known reachable advisory reports were updated in the prototype's module; the final vulnerability scan reported no reachable known vulnerabilities, with two advisories remaining in unused dependency packages/modules.

## Disposable Linux probe

The build produces `.build/network-container/.build/debug/yieldd-linux-network-probe`. It takes seven positional arguments:

```text
yieldd-linux-network-probe EMPTY_ROOT KERNEL INITFS ROOTFS RELAY SOCKET_DIR FIXTURE_URL
```

Use a fresh `mktemp -d` directory on the configured quota volume for `EMPTY_ROOT`, an existing Container kernel and read-only init filesystem, and the cached ARM64 `local/yieldd-guest:dev` root filesystem snapshot. The probe copies those inputs into its own bundle; it does not modify the sources. `SOCKET_DIR` must be a fresh, owned `0700` directory with a short path, such as one created by `mktemp -d /tmp/yieldd-pkt.XXXXXX`. The supervisor creates its own private subdirectory inside it. `RELAY` is the absolute path to `.build/network-prototype`.

Run `host-fixture.py` separately and use its printed port with the Mac's LAN IPv4 address and `/yieldd-network-probe` path for `FIXTURE_URL`. Confirm the host can reach that URL immediately before and after the probe. Do not use existing service ports.

The probe holds yieldd's ownership lock, starts its own relay, and boots a 4-CPU, 12 GiB Linux VM through the fork's actual `RuntimeService`. No vmnet strategy, host share, published port, or SSH-agent forwarding is configured. Its checks run as the image's `runner` account: resolve GitHub, fetch public HTTPS, reject the host fixture, fetch public HTTPS again, stop the relay, then require a connection to GitHub's already-resolved address to fail. It stops the VM afterward. A two-minute watchdog bounds a stuck boot or XPC request by exiting the VM-owning process, which closes the relay's lifetime pipe. SIGINT, SIGTERM, and SIGHUP use the same exit path; disposable files can remain available for inspection.

After the probe process exits, remove only its two newly created directories. On failure, inspect the owned bundle's `vminitd.log` before removing it. These probe directories are not part of yieldd's automatic clone sweep. This harness does not exercise the machine CLI, machine service, or first-boot user setup.

## Evidence and remaining work

On 2026-09-20, macOS 27.0, the disposable macOS VM reached public HTTPS (HTTP 200), used pinned SSH through the relay, and could not connect to a controlled listener on the Mac's LAN IPv4 address. The host reached that listener, and the guest reached public HTTPS again immediately after the denial. Stopping the relay removed its SSH endpoint. Starting the probe with a missing relay failed before VM startup and left no clone.

The same day's Linux probe booted the yieldd Ubuntu image through the patched runtime with one Ethernet interface and the relay as its default gateway and DNS server. DNS resolved GitHub; HTTPS returned 200 before and after the host-fixture denial. The host reached that fixture before and after the test. After relay shutdown, a new HTTPS connection to GitHub's already-resolved IP timed out while guest execution remained available over the runtime control channel. The runtime then stopped the VM. A deliberately failing relay executable prevented bundle creation. All test processes and disposable disk/socket directories were removed.

Preparing the live test exposed a runtime assumption that a network interface always has a vmnet allocation. The fork now starts vmnet port forwarders only when an allocation exists and rejects published ports or sockets in relay mode. The successful VM boot exercises the previously crashing path.

The Go race-enabled tests, packet fuzzing (302,237 inputs in the recorded ten-second run), opt-in DNS/HTTPS test, both modified Swift targets, and all 11 `MachineConfigTests` passed. No GitHub job ran. The installed Container service stayed on its original version and quota-backed root.

Final branch checks also passed all seven `PacketSocketTests` (one with two inputs), the expanded Go race-enabled tests, and `go vet`. The dependency scan found no reachable known vulnerabilities; two advisories remain in unused dependency modules. A controlled relay that ignored SIGTERM was forcibly stopped after an intentional pre-boot failure, without waiting for its 30-second lifetime. No VM was needed for that cleanup check. The new CI workflow has been checked locally, not run on GitHub.

Those VM runs predated the DNS fix: their DNS queries still used the Mac's resolver, so the host-fixture denial did not prove DNS isolation. The replacement public DNS path subsequently passed controlled UDP/TCP guest tests and the live packet-level DNS/HTTPS check. The VM probes have not been rerun with the DNS fix and typed attachment field.

After these corrections, the full check also passed with an alternate `TMPDIR`: Go race tests and vet, both probe builds, the machine service build, signatures, and 21 Swift tests covering sockets and configuration. Generated copies refreshed without manual deletion. Focused DNS, TCP-denial, counters, and cancellation checks passed three repeated race-enabled runs.

On 2026-09-22, the shared supervisor passed nine Swift tests, including a handshake and shutdown with the real relay. The four Go ownership scenarios passed three race-enabled repetitions. The combined prototype check passed, as did the core Swift suite (393 tests). No VM or GitHub job ran for this lifecycle change, and no installed service was changed.

Still unverified or deliberately incomplete:

- The full modified Linux machine CLI/service path, including first-boot setup and persisted machine cleanup. The live harness bypasses those layers, not the runtime itself.
- Normal backend integration, continuous relay health monitoring during Linux operations, durable cleanup, memory/CPU/connection budgets, and performance under load. The shared process supervisor is used by the probes only. Upstream network services live for the helper process; this design uses one helper per guest.
- An owner crash closes the relay but can leave its temporary directory or guest-side socket path. There is no durable relay-directory sweep yet. Process-level lifecycle checks do not establish VM or runner recovery.
- Denial totals are process-local and best effort, including during normal shutdown. There is no durable metric collection or alerting yet.
- Public DNS and permitted Internet endpoints remain possible data channels. Rejecting unneeded record types in the built-in service does not restrict jobs from using another public DNS or HTTPS service.
- IPv6 Internet support and a complete review of the third-party packet stack.
- Public-address hairpinning through a router or VPN, and interface changes affecting an already-established connection. The current address check covers local interface addresses at connection creation, not every possible public route back into a private network.
- Full-volume, host restart, and crash-recovery testing with the relay enabled.

The experiment shows that this packet path is usable. It does not establish complete host/LAN isolation or replace the VM security boundary.

An upstream contribution is separate follow-up work. The likely reusable piece is a general socket-backed attachment or plugin integration, rather than yieldd's fixed policy and probe harness. Discuss the scope with maintainers before treating this as a fix for [host-isolation issue #1320](https://github.com/apple/container/issues/1320).
