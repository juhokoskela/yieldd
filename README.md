# yieldd

`yieldd` turns spare Mac resources into ephemeral GitHub Actions runners. The Go coordinator routes queued jobs to a connected Mac or a hosted fallback. Run the Mac client in a terminal or as a login agent.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer
- Swift 6.2 or newer
- Go matching `Prototypes/RunnerNetwork/go.mod` to build the bundled network relay
- For Linux runners: the [pinned Container fork](Docs/linux-runner-network.md) with relay-aware machine support and a running container system
- A configured [quota-limited APFS volume](Docs/runner-storage.md) for guest storage, separate from recovery records
- For macOS runners: a user-prepared template bundle on that guest-storage volume

For safety, `yieldd` rejects empty `PATH` components instead of interpreting them as the working directory.

Configure [runner storage](Docs/runner-storage.md) first. Start the container system outside `yieldd` if needed, using the configured guest volume:

```sh
container system start --app-root /Volumes/YielddRunners/container
```

`yieldd doctor` never starts or changes the container system.

For macOS-only checks, use the signed application with `doctor --template /absolute/path/VM.bundle`. This checks virtualization support, signing entitlement, the bundled network relay, template files and location, and memory capacity without requiring Apple Container. It does not boot a guest; use `machine-test` for SSH, GUI, and simulator validation.

Linux and macOS runner commands use a separate network relay per guest, with no NAT fallback. macOS uses pinned SSH through a user-private Unix socket; Linux control stays on Container's host control channel. Build the signed app with `Scripts/build-local-app.sh`; a bare `swift build` does not package the helper. Linux also requires the [pinned Container build](Docs/linux-runner-network.md). The relay permits public IPv4 TCP/UDP, filters host and private destinations, and uses a fixed public DNS resolver. IPv6, LAN/VPN DNS, and local service access are unavailable. See the [validation boundary](Docs/linux-runner-network.md#validation-boundary) for current acceptance coverage. See [runner boundaries](Docs/runner-boundaries.md) for limitations.

## Build and test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd doctor
```

While the yieldd coordinator is unavailable, the `CI` workflow uses GitHub-hosted runners for pushes to `main`, pull requests, and manual dispatches. Swift builds, tests, and signed-app checks run on `macos-26`; bootstrap and coordinator checks run on `ubuntu-24.04-arm`. The `Network prototype` workflow also uses `macos-26`. CI does not depend on the yieldd coordinator. These checks do not start nested runner VMs or replace a running yieldd installation. Swift tests run serially while parallel lifecycle-test timing failures remain unresolved.

The opt-in runner acceptance workflows target yieldd runners. They require a working coordinator or a manually started local runner; a GitHub-hosted run would not validate yieldd execution. Hosted fallback bootstrap workflows must target their explicitly supplied external runner, never a yieldd queue.

## Guest image

The local-agent installer builds the Ubuntu 24.04 guest image automatically when Linux slots are configured. To build it manually for the foreground commands, run this from the repository root:

```sh
container build -t local/yieldd-guest:dev Guest
```

The image boots systemd as PID 1 and runs Docker from Ubuntu's `docker.io` package. It also contains the pinned Linux ARM64 GitHub Actions runner and GitHub CLI, plus `zstd` so `actions/cache` compresses entries the same way as GitHub-hosted and fallback runners and can restore the caches they save. Guest commands run as the unprivileged `runner` user, which belongs to the `docker` group.

Machines receive 4 virtual CPUs and a 12 GiB memory ceiling. At boot, `/dev/shm` is resized from Container's 64 MiB default to half of guest memory, so browsers have room for shared memory. Runner processes and Docker-created workflow containers share a systemd slice with the same CPU allocation and an 8 GiB soft memory threshold. `yieldd` reserves each live machine's full ceiling against 75% of host physical memory, so the current configuration requires roughly 16 GiB of physical memory and concurrent runner slots cannot independently overcommit the host. Normal memory pressure removes the soft threshold; warning or unknown pressure keeps it. A worker can accept an offer only after reserving memory. Capacity waits end when another machine is deleted, while critical pressure is periodically rechecked. Reservations are released only after machine deletion succeeds.

## Machine integration test

After building the guest image, run:

```sh
.build/yieldd.app/Contents/MacOS/yieldd machine-test
```

The command shares the runner ownership lock and memory-admission policy with foreground `connect`, and the login agent. It creates a uniquely named machine with no host home mount, runs `docker info`, checks both guest helpers' protocol version, runs `docker run --rm hello-world`, and destroys the machine. It attempts cleanup after every creation attempt, including failed ones and commands interrupted with Ctrl+C or SIGTERM.

### Local job caching

Enable the [local cache](Docs/job-caches.md) to keep Actions cache archives on the Mac or give a workflow a private writable build disk.

### macOS template validation

Prepare a template using the [macOS template setup guide](Docs/macos-template.md). Build the signed local application, then validate a cold clone:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd machine-test --template /absolute/path/VM.bundle
```

Use the packaged executable for macOS commands. A plain `swift run` executable lacks the virtualization entitlement. Building the application does not install or start the agent.

Validation checks SSH, both guest helpers' protocol version, automatic console login, the GUI launchd domain, Xcode setup, an available compatible iOS runtime and iPhone device type, simulator boot, and a nonempty screenshot. Selection does not guarantee the newest runtime or device. Simulator validation has a ten-minute limit. The command attempts to destroy the clone after success, failure, or interruption; if destruction fails, it reports the failure and leaves the clone for recovery. The template is not modified. macOS clones reserve 8 GiB against the host budget and boot with 8 GiB under normal pressure or 6 GiB under warning or unknown pressure. The macOS guest receives virtual disks.

A pending Linux machine test requires `container` for cleanup. The macOS test also removes abandoned clones. Outstanding coordinator assignments must be recovered through the original connection first.

macOS guests expose one virtual audio output for Core Audio workloads. Playback is discarded instead of sent to the host speakers, and no microphone input is exposed. The device is configured at VM creation, so updating yieldd requires restarting the service to use it in new guests; the template needs no audio-driver installation.

## Verify an enrolled Mac

Enroll the Mac and check that `yieldd agent status` reports a ready worker for the platform. Dispatch the repository’s trusted `Runner test` workflow for Linux or `macOS runner test` for macOS. Both use the coordinator’s normal platform labels.

In the GitHub job details, find the assigned runner name. Match that exact name to the coordinator’s local credential issuance for your device ID and to its cleanup acknowledgement. A green job on hosted fallback does not verify the Mac. If other demand took the local slot, repeat the check when the Mac is idle.

Use `yieldd recover` for an interrupted machine test. For an interrupted workflow assignment, reconnect the Mac with its original coordinator and device ID so it can remove the guest and acknowledge cleanup.

## Running at login

Use the connected installer with the same server, device ID, and platforms as foreground `connect`. The Mac needs its device token for initial enrollment. The coordinator owns repository selection and GitHub credentials. The installation guide covers Keychain access, upgrades, drain, status, and recovery. [Connected agent at login](Docs/connected-mac-prototype.md#connected-agent-at-login)

Before upgrading, drain and uninstall with the original binary. For a release without `agent drain`, stop submitting jobs, let active work finish, and use its original binary and GitHub identity to stop the service and recover outstanding registrations. Keep both sides’ journals, credentials, and old binaries until all guests and registrations have been reconciled. Then move the uninstalled app aside, update both guest helpers, and enroll again. See the [installation and recovery procedure](Docs/connected-mac-prototype.md#connected-agent-at-login).
