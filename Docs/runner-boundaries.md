# Runner boundaries

The VM boundary separates a local workflow from the Mac's processes and files. yieldd does not share host directories with either guest. This assumes the hypervisor, its devices, Apple Container's host service, and SSH work as designed. It does not assume that anything inside the guest remains trustworthy after a job starts.

Guest commands have bounded output capture, including Linux shutdown helpers. Diagnostic rendering escapes terminal control characters; captured bytes remain unchanged for protocol parsing. Connected execution needs renewable coordinator authorization: five minutes without a renewal causes host-side destruction, while a healthy job can keep renewing without a total duration limit. Capacity is released only after destruction succeeds. Guest status remains useful progress information, not execution authority. Standalone `serve` and `agent` do not use coordinator authorization; this change does not impose a new total duration limit on them.

JIT configuration accepts only `.runner`, `.credentials`, and optional `.credentials_rsaparams`, with base64 contents. It checks the expected runner name, ephemeral setting, and `_work` folder. These checks are not independent proof of repository membership. The coordinator is still trusted to choose the workload and supply genuine GitHub credentials. A local repository-name check alone would not protect against a compromised coordinator supplying forged metadata and another runner's credentials. Independent enrollment needs an authority separate from that coordinator.

Hosted fallback is not a nested sandbox. Its job runs as the provider's account and can affect anything that account can access. Select a provider that destroys the host after each bootstrap. Do not send hostile jobs to a persistent fallback machine.

## Unresolved host controls

NAT is not a host or LAN firewall. Runner guests can reach networks exposed by the Mac, including reachable host services. The installed Apple Container machine API does not expose a network selector. An [upstream report](https://github.com/apple/container/issues/1320) also describes vmnet traffic bypassing ordinary macOS firewall filtering. That report is not validation of a filter on this host. No firewall rule is installed or claimed to contain guests by this patch. Reliable filtering needs a host-enforced network path tested against both backends, including IPv6, host addresses, and private/link-local destinations.

Sparse guest disks and APFS clones do not impose a storage quota. This patch does not fix host disk exhaustion. A hard bound needs a quota-controlled filesystem for all writable runner disks. The macOS template and clones must stay on the same APFS volume for cloning. Apple Container machine storage belongs to its host service and may include non-yieldd machines, so moving it requires an explicit migration with the service stopped. Do not relocate only yieldd's journal and assume the guest disks moved. Keep recovery journals outside the guest storage quota so a full guest volume does not prevent durable cleanup records.

Host-measured free-space checks can provide early warning, but polling cannot prevent a fast writer from exhausting shared storage between checks. They are not a replacement for a filesystem-enforced quota. No disk migration or privileged host setup has been applied.

The coordinator container now uses bridge networking, publishes only a loopback port, and has CPU, memory, and process limits. This reduces its access to host-loopback services and resource use, but does not provide an outbound LAN deny policy. Its bearer token and GitHub credentials still require protection on both endpoints.
