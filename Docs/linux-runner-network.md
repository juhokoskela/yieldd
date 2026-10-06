# Linux runner networking

Linux runner commands now require yieldd's pinned Apple Container fork and the bundled packet relay. Stock Container does not expose this machine network path. There is no NAT fallback.

Each machine gets its own relay and private socket directory. yieldd creates the machine with `--no-boot`, then checks `machine inspect` for the exact runner ID, relay socket, and disabled home mount. Only a matching configuration can reach the first `machine run`, which boots the guest. This also rejects a patched CLI talking to an older machine service that discarded the socket setting. The runtime forbids combining the socket with vmnet attachments, published ports or sockets, or SSH-agent forwarding.

Relay health is checked before and during guest commands, including long listener waits. Owner death closes the relay's lifetime pipe. Cleanup attempts both relay shutdown and machine deletion; failed cleanup retains the journal and memory reservation. Recovery removes socket directories only after machine deletion and storage removal have been confirmed.

## Install the pinned Container build

Finish running jobs and cleanup, then stop yieldd before replacing Container. Its services and data root are shared with other Container users, not isolated to this project. Keep the quota volume and recovery journals intact. Do not install or restart services from inside a runner job.

From a checkout of this branch on the runner Mac:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-runner-container.sh
repo_root="$PWD"
prototype_dir="$repo_root/Prototypes/RunnerNetwork"
source "$prototype_dir/source-paths.sh"

container system stop
sudo installer -pkg "$container_source/bin/release/container-installer-unsigned.pkg" -target /
container system start --app-root /Volumes/YielddRunners/container
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd doctor
.build/yieldd.app/Contents/MacOS/yieldd machine-test
```

Use your configured volume path instead of `/Volumes/YielddRunners`. The build script creates an ad-hoc-signed development installer; it does not install or restart services. It verifies the pinned source revision and patch before compilation. Unexpected cache edits are rejected without being discarded.

The guest image and `connect` arguments are unchanged. Restart connected workers only after `machine-test` passes. Keep any failed cleanup records and resolve them before changing Container again.

## Validation boundary

Automated checks cover the create/inspect/boot ordering, rejection of missing or mismatched socket settings, relay failure during a running host process, bounded shutdown, and crash-directory cleanup. They build the actual patched CLI and services without installing them. They do not prove the installed machine CLI's first-boot user setup or GitHub-job execution.

Before deploying, repeat public DNS/HTTPS and controlled host/LAN denial checks through a real Linux machine, with positive controls showing that the host endpoint and public transport work. Also verify owner interruption, machine deletion, and recovery against the installed fork. Earlier Linux runtime probes bypassed the machine service and CLI, so they are not evidence for this integration.

The relay filters host and private destinations and drops IPv6. Public DNS and HTTPS remain possible data channels. Public-address hairpin routes and interface changes affecting existing connections remain limitations. Relay CPU, memory, and connection budgets are separate follow-up work. See [runner boundaries](runner-boundaries.md).
