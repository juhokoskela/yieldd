# Runner network prototype

This directory contains the relay and experimental VM probes. Normal Linux and macOS runner commands use the same relay and socket adapter. Linux requires the [pinned Container fork](../../Docs/linux-runner-network.md); its [validation boundary](../../Docs/linux-runner-network.md#validation-boundary) tracks current acceptance coverage. Do not treat this as a finished sandbox.

Each guest gets one `VZFileHandleNetworkDeviceAttachment`, connected to its own host-side relay through a private Unix datagram socket. The relay uses gVisor's TCP/IP stack via `gvisor-tap-vsock`. A small upstream patch lets yieldd check the numeric destination immediately before opening a host TCP or UDP socket. There is no vmnet interface, host-address translation, or guest-accessible HTTP management service.

The policy denies private, loopback, link-local, shared-address, multicast, reserved, documentation, and current host-interface addresses. It rejects static forbidden ranges before inspecting interfaces. Public candidates require a fresh host-address lookup for every new outgoing connection; lookup failure denies the connection. A private address returned by DNS still fails the connection check. Host-to-guest SSH uses a private Unix socket and does not grant reverse access to host services. Other local users cannot reach that socket; processes running as the yieldd user remain trusted.

Guest DNS goes directly to Cloudflare's public resolver at `1.1.1.1:53` over TCP, through the same destination check. It never uses the Mac's resolver, hosts file, search domains, VPN DNS, or mDNS, and does not fall back to them on failure. The service forwards only Internet-class A queries. It returns no addresses for AAAA queries and refuses other record types, single-label names, `.local`, `.localhost`, and `home.arpa`. At most 16 upstream queries run concurrently. Public DNS and other permitted Internet traffic can still carry arbitrary data; this is not an exfiltration filter.

The relay attempts to write policy summaries to stderr every 30 seconds and on shutdown. Each reason gets a separate JSON line with the runner identity and platform, lifetime total, reporting interval, and interval counts. Lines stay within Darwin's 512-byte atomic pipe-write limit, so simultaneous relays cannot split each other's lines. DNS policy refusals, concurrency saturation, and upstream resolver failures are separate. A DNS dial refused by the destination policy is counted only under that destination reason. Frame reasons distinguish IPv6, unsupported protocols, and requests for other neighbors from malformed packets and incorrect guest identities. Destination reasons distinguish blocked address ranges, host addresses, invalid endpoints, and host-address lookup failures.

Each reason includes counts for the latest interval and bounded repeat tracking. Up to 256 distinct fingerprints are retained per reason per interval (at most 4,096 across the 16 reasons); additional untracked events are counted explicitly rather than called unique. Frame noise cannot consume DNS tracking capacity. DNS fingerprints ignore transaction IDs and name case, destination fingerprints identify the protocol and endpoint, and frame fingerprints identify exact packet bytes. Repeats show retry behavior, not hostile intent. No query names, endpoints, packets, or fingerprints are logged. Counter reporting is best effort: process exit never waits for it, so final totals may be lost even on normal shutdown. Fatal-error reporting gets at most 100 ms before exit. The private `0700` parent directory protects the socket during creation, before its own mode becomes `0600`.

Both probes use `Sources/Yieldd/RunnerNetworkRelay.swift` to own the relay process. Startup requires a version-2 JSON readiness response, bounded to 1 KiB, with the expected private Unix SSH socket path. The owner keeps a close-on-exec pipe open; EOF or any input revokes the relay's lifetime. This also stops the relay when the owner dies, without a fixed job-duration limit or a stored PID used for recovery. Explicit shutdown closes that pipe immediately, allows one second to exit, then sends TERM and finally KILL if needed. Each wait is capped by any remaining shutdown budget. The supervisor removes its socket directory only after confirming process exit. Normal macOS runners keep these directories under macOS's user-private temporary directory, not shared `/tmp`.

This first version supports IPv4 TCP and UDP. It drops IPv6, VLAN frames, IP options, fragmented packets, spoofed source identities, and oversized frames. IPv6 Internet access is not implemented.

## Build and check

Run from the yieldd checkout:

```sh
bash Prototypes/RunnerNetwork/check.sh
```

This macOS check builds and signs both probes, runs the relay tests with the race detector, runs `go vet`, builds the modified Container services, and runs the Swift configuration, socket, VM-lifecycle, and relay-supervisor tests. The supervisor tests include the real Go relay. The macOS lifecycle tests use a controlled clock and callbacks to cover stalled startup, interruption, late startup, and bounded cleanup without a VM. The check does not boot a VM or change installed services. Main CI runs the Swift suite on every push to main and pull request. Local checks and manual network workflow dispatches also run the focused Swift network suite.

Public-network and fuzz checks are separate:

```sh
(cd Prototypes/RunnerNetwork && YIELDD_NETWORK_LIVE=1 go test -modfile ../../.build/network-relay.mod -run TestPublicHTTPS -v -timeout 30s)
(cd Prototypes/RunnerNetwork && go test -modfile ../../.build/network-relay.mod -run '^$' -fuzz FuzzFrameBoundary -fuzztime 10s -parallel 2)
```

The preparation script creates pinned source checkouts under `.build/`, applies the two checked-in patches, builds the relay and both probes, and ad-hoc signs the probes with the existing virtualization entitlement. It refreshes generated copies of `LinuxProbe.swift`, `MacProbeLifecycle.swift`, and `MacProbeLifecycleTests.swift` from this directory, plus `PacketSocket.swift` and `RunnerNetworkRelay.swift` from `Sources/Yieldd/`. Edit those originals, not their `.build/` copies. It does not install, stop, or reconfigure Apple Container. Go dependencies belong to this separate module, not the coordinator. `Scripts/build-network-relay.sh` builds only the relay for the signed app, without building the Container fork or probes.

Cached dependency sources must match the pinned revision and checked-in patch. Unexpected edits or extra files, including ignored sources, stop the build without being discarded. Only declared build outputs (`.build` and Container's `bin/release` installer output) and generated source copies are excluded; source copies are refreshed before compilation. To replace a rejected cache, preserve your edits and move the checkout aside before rebuilding.

The socket-level tests use a second gVisor stack as the guest and exchange real Ethernet datagrams. They cover denied TCP/UDP traffic, host-to-guest connections, malformed frames, private socket directories, occupied socket paths, and cancellation both before connection and with a guest and SSH client connected. The TCP denial test uses a simulated public host address and a real loopback listener behind the checked dial boundary; it also checks a private destination. It does not require a LAN interface or skip when one is absent. Separate live VM evidence appears below. DNS tests exercise both guest transports against a controlled upstream and assert the public destination. Policy tests verify that new connections use updated host addresses. `Tests/YielddTests/PacketSocketTests.swift` exercises the actual socket adapter's datagram exchange, permissions, failure cleanup, and path rejection in normal Swift CI. The backend attachment test starts a real relay but uses a fake VM; it does not prove VM traffic flows. The opt-in live test resolves `github.com` through the guest DNS service and makes a certificate-verified HTTPS request through the relay.

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
  "$PWD/.build/yieldd-network-relay"
```

The probe holds yieldd's existing ownership lock, starts its relay, copies the template's disk and auxiliary storage using APFS clones, and starts an 8 GiB VM. It prints the Unix SSH socket path and uses only the relay interface. VM startup and runtime share a two-minute budget. SIGINT/SIGTERM/SIGHUP and relay exit are checked while startup is pending as well as during execution. Cleanup gets a separate 15 seconds, including time waiting for the VM to become stoppable. If shutdown cannot be confirmed, the probe reports the failure and retains the clone; it still shuts down the relay and exits. It removes the clone only after confirmed shutdown or terminal VM failure. These bounds are for the experiment, not proposed job execution limits. A crash or failed shutdown can leave a `.bundle` in `macos-probes`; normal yieldd recovery sweeps that directory.

In another terminal, connect using the printed socket path and the template's pinned key:

```sh
ssh -F /dev/null \
  -i /Volumes/YielddRunners/VM.bundle/SSHPrivateKey \
  -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes \
  -o GlobalKnownHostsFile=/dev/null \
  -o UserKnownHostsFile=/Volumes/YielddRunners/VM.bundle/SSHKnownHosts \
  -o HostKeyAlias=yieldd-macos-template -o StrictHostKeyChecking=yes \
  -o "ProxyCommand=/usr/bin/nc -U 'REPLACE_SOCKET_PATH'" runner@yieldd-macos-template \
  '/usr/bin/curl --noproxy "*" --max-time 10 --silent --show-error --output /dev/null --write-out "%{http_code}" https://github.com/'
```

`host-fixture.py` provides an optional two-minute fixed-response listener for a controlled negative test. It serves no files or commands. Reach `/yieldd-network-probe` from the host first, then attempt that same host address and port from the guest. Do not substitute existing service ports or scan the LAN.

## Apple Container fork

`container.patch` targets Apple Container 1.6.0 at `ca4884f8f3a13b62c90ea2fb3834f214d61fb91c`. It adds an experimental `network-socket` machine setting and a typed `ContainerConfiguration.networkSocket` field, replaces the built-in network with the socket attachment, and disables SSH-agent forwarding in that mode. Labels cannot select the attachment. It requires `home-mount=none`; the runtime refuses another network alongside the relay.

The shared `PacketSocket.swift` is copied into the fork during preparation. No Containerization dependency fork is needed. Dependency checkout paths include their pinned revision and patch digest. Changing a patch selects a new checkout without deleting old work; unexpected edits in a selected checkout still fail validation. The relay build uses a generated module file and disables VCS metadata.

After preparation, compile and run the configuration tests from the repository root without starting any service:

```sh
repo_root="$PWD"
prototype_dir="$repo_root/Prototypes/RunnerNetwork"
source "$prototype_dir/source-paths.sh"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path "$container_source" --target ContainerRuntimeLinuxServer -j 6
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path "$container_source" --target MachineAPIService -j 6
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path "$container_source" --filter MachineConfigTests -j 6
```

Do not run the fork's `system start` or `make install` on this host yet. The API server uses the same launchd service name as the installed Container service, even with a different data root. The Linux probe below runs the patched runtime over anonymous, in-process XPC instead.

`gvproxy.patch` targets `gvisor-tap-vsock` v0.8.9 at `9cfc86f66679ef0feed0f20ba1df558fe2bef5c6`. Its hook runs after address translation for both TCP and UDP. It also accepts a replacement DNS handler so the built-in host resolver is not started. The relay supplies both policies explicitly. Dependencies with known reachable advisory reports were updated in the prototype's module; the final vulnerability scan reported no reachable known vulnerabilities, with two advisories remaining in unused dependency packages/modules.

## Disposable Linux probe

The build produces `$container_source/.build/debug/yieldd-linux-network-probe` using the path selected above. It takes seven positional arguments:

```text
yieldd-linux-network-probe EMPTY_ROOT KERNEL INITFS ROOTFS RELAY SOCKET_DIR FIXTURE_URL
```

Use a fresh `mktemp -d` directory on the configured quota volume for `EMPTY_ROOT`, an existing Container kernel and read-only init filesystem, and the cached ARM64 `local/yieldd-guest:dev` root filesystem snapshot. The probe copies those inputs into its own bundle; it does not modify the sources. `SOCKET_DIR` must be a fresh, owned `0700` directory with a short path, such as one created by `mktemp -d /tmp/yieldd-pkt.XXXXXX`. The supervisor uses and removes that exact directory. `RELAY` is the absolute path to `.build/yieldd-network-relay`.

Run `host-fixture.py` separately and use its printed port with the Mac's LAN IPv4 address and `/yieldd-network-probe` path for `FIXTURE_URL`. Confirm the host can reach that URL immediately before and after the probe. Do not use existing service ports.

The probe holds yieldd's ownership lock, starts its own relay, and boots a 4-CPU, 12 GiB Linux VM through the fork's actual `RuntimeService`. No vmnet strategy, host share, published port, or SSH-agent forwarding is configured. Its checks run as the image's `runner` account: resolve GitHub, fetch public HTTPS, reject the host fixture, fetch public HTTPS again, stop the relay, then require a connection to GitHub's already-resolved address to fail. It stops the VM afterward. A two-minute watchdog bounds a stuck boot or XPC request by exiting the VM-owning process, which closes the relay's lifetime pipe. SIGINT, SIGTERM, and SIGHUP use the same exit path; disposable files can remain available for inspection.

After the probe process exits, remove only its two newly created directories. On failure, inspect the owned bundle's `vminitd.log` before removing it. These probe directories are not part of yieldd's automatic clone sweep. This harness does not exercise the machine CLI, machine service, or first-boot user setup.

## Evidence and remaining work

See the [validation boundary](../../Docs/linux-runner-network.md#validation-boundary) for current automated coverage, installed-fork evidence, and remaining acceptance checks. These probes do not establish complete host/LAN isolation or replace the VM security boundary.

An upstream contribution is separate follow-up work. The likely reusable piece is a general socket-backed attachment or plugin integration, rather than yieldd's fixed policy and probe harness. Discuss the scope with maintainers before treating this as a fix for [host-isolation issue #1320](https://github.com/apple/container/issues/1320).
