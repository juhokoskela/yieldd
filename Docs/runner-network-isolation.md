# Guest network isolation: feasibility

This records the baseline investigation and the subsequent [socket-relay prototype](../Prototypes/RunnerNetwork/README.md). Both runner backends now use that relay; Linux requires a [pinned Container fork](linux-runner-network.md), with current acceptance coverage in its [validation boundary](linux-runner-network.md#validation-boundary). The stock Linux runner-machine path can reach the Mac's services. Enforcing an Internet-only policy needs a packet path yieldd can control outside the guest.

## What was checked

The 2026-09-20 check used macOS 27.0 (26A428), Apple Container 1.3.1 (`a9a62e28f6beb88940122a3d7b286f2d5ae8053a`), and yieldd after PR #34. Results are specific to that environment.

The host fixture accepted bounded HTTP requests on temporary IPv4 and IPv6 ports and returned a fixed marker. It served no files, credentials, or commands. Linux used `local/yieldd-guest:dev` through `container machine create` with the production CPU, memory, and `--home-mount none` settings, followed by `machine run --user runner`. No GitHub runner was registered. The ownership lock was held during the experiment.

| Check | Result |
| --- | --- |
| Linux guest to the Mac's LAN IPv4 address | Reached the fixture; the host recorded the request. |
| Linux guest to its IPv4 gateway | Reached the same fixture; the host recorded the request. |
| Linux guest to the Mac's LAN IPv6 ULA | Connection failed. The guest had no usable IPv6 default route. This does not establish IPv6 isolation. |
| Linux guest to public HTTPS | DNS resolution timed out. Internet connectivity was not established by this check. |
| macOS disposable clone | Booted and acquired DHCP. Pinned SSH failed with `No route to host`, despite a route and matching ARP entry. No guest-originated probe ran. |

The Linux positive results used the actual runner-machine path, not an ordinary `container run` substitute. Initial non-TTY invocations failed during Container's first-boot user setup; the successful probe ran with a host terminal. Probe commands must account for `machine run` invoking a guest shell: avoid unquoted wildcards and literal newlines in arguments.

No existing service ports were scanned. No second LAN host, metadata endpoint, firewall rule, sysctl, or network configuration was changed or tested. All disposable machines, machine bundles, and the macOS probe clone were removed, and the HTTP listener was stopped. Container remained on its configured quota-backed root. The template was not changed.

## Available enforcement points

### Linux

The installed `container machine create` and `machine set` options do not expose a network selector. The pinned [machine service](https://github.com/apple/container/blob/a9a62e28f6beb88940122a3d7b286f2d5ae8053a/Sources/Services/MachineAPIService/Server/MachinesService.swift#L687-L695) explicitly attaches the built-in network.

A custom network plugin alone is insufficient. The [runtime registers two fixed vmnet interface strategies](https://github.com/apple/container/blob/a9a62e28f6beb88940122a3d7b286f2d5ae8053a/Sources/Plugins/RuntimeLinux/RuntimeLinuxHelper%2BStart.swift#L66-L72), and [rejects an attachment without a matching strategy](https://github.com/apple/container/blob/a9a62e28f6beb88940122a3d7b286f2d5ae8053a/Sources/Services/RuntimeLinux/Server/RuntimeService.swift#L210-L219). A socket-based filtering path therefore needs a Container runtime extension or a different Linux backend, not just another CLI argument.

### macOS

macOS runners use [VZFileHandleNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment), which exchanges Ethernet frames through a connected datagram socket. It connects to a gVisor-based relay for DHCP, DNS, forwarding, destination checks, and host-to-guest SSH. The manual `agent vm-probe` still uses `VZNATNetworkDeviceAttachment`.

The SDK describes `vmnet_enable_isolation_key` as isolation between VM interfaces. It does not promise to block host or LAN destinations. Container's `--internal` option describes a host-only network, not an Internet-only network. Neither satisfies this requirement on its own.

The [upstream firewall-bypass report](https://github.com/apple/container/issues/1320) remains a report, not proof about a proposed rule set on this host. This experiment did not install or evaluate `pf` rules.

## Prototype and acceptance boundary

The prototype now lives under `Prototypes/RunnerNetwork/`. Disposable macOS and Linux guests successfully used DNS and public HTTPS through the relay while controlled host-LAN connections were denied. macOS also used pinned SSH. The Linux probe exercised the patched Container runtime over anonymous XPC, without installing a service; it did not exercise the machine CLI or first-boot setup. After relay shutdown, a connection from the still-running Linux guest to GitHub's already-resolved IP failed. Neither installed backend was changed. See the prototype's evidence and limitations before extending it.

Those VM runs used the host resolver, which was a separate path around the destination policy. The prototype now forwards only A lookups to a fixed public resolver through the checked dial, returns AAAA NODATA, and refuses local names and other record types. Controlled packet tests and a public DNS/HTTPS check cover this correction; the VM probes have not been repeated with it. Public DNS remains an Internet data channel, not a way to prevent exfiltration.

The shared Swift relay supervisor is used by both probes and both runner backends. The signed app bundles the helper, and macOS runner SSH uses a user-private Unix socket rather than host DHCP discovery. See [runner boundaries](runner-boundaries.md) for the current trust model and the [Linux integration runbook](linux-runner-network.md) for installation, lifecycle behavior, and validation still required before deployment.

A working prototype must demonstrate all of the following before yieldd advertises network isolation:

- Every guest interface goes through the relay. Guest root, route changes, and raw packets cannot select a second NAT path.
- Destination checks block host addresses, other guests, private, link-local, loopback, multicast, and metadata destinations across both IP families. Host addresses need checking even when they are publicly routable.
- DNS uses a narrow, controlled service, not a blanket exception for the host gateway. DNS answers and alternate address representations cannot bypass destination checks.
- Public DNS and HTTPS work from both guests. The host can still manage macOS through pinned SSH without granting guests general host access.
- Relay startup failure prevents provisioning; relay failure during execution leaves no unfiltered path. Restart, cancellation, and cleanup preserve existing lease and memory guarantees.
- Negative connectivity tests have positive controls proving that the endpoint and guest transport were working. A timeout or missing route alone is not evidence of enforcement.

Both guests now have DNS and HTTPS positive controls on the new socket path, with SSH also checked on macOS. This does not establish the cause of the earlier NAT-path failures or prove every isolation requirement above. A separate runner VLAN can reduce LAN exposure, but it does not by itself remove access to services on the runner Mac.
