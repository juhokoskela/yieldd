# yieldd

`yieldd` turns spare Mac resources into ephemeral GitHub Actions runners. The Go coordinator routes queued jobs to a connected Mac or a hosted fallback. Run the Mac client in a terminal or as a login agent.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer
- Swift 6.2 or newer
- Go matching `Prototypes/RunnerNetwork/go.mod` to build the bundled network relay
- For Linux runners: the [pinned Container fork](Docs/linux-runner-network.md) with relay-aware machine support and a running container system
- A configured [quota-limited APFS volume](Docs/runner-storage.md) for guest storage, separate from recovery records
- For macOS runners: a user-prepared template bundle on that guest-storage volume
- For one-job diagnostics and legacy registration recovery: GitHub CLI authenticated to `github.com` with administration access to the repository

For safety, `yieldd` rejects empty `PATH` components instead of interpreting them as the working directory.

Configure [runner storage](Docs/runner-storage.md) first. Start the container system outside `yieldd` if needed, using the configured guest volume:

```sh
container system start --app-root /Volumes/YielddRunners/container
```

`yieldd doctor` never starts or changes the container system.

For macOS-only checks, use the signed application with `doctor --template /absolute/path/VM.bundle`. This checks virtualization support, signing entitlement, the bundled network relay, template files and location, and memory capacity without requiring Apple Container. It does not boot a guest; use `machine-test` for SSH, GUI, and simulator validation.

Linux and macOS runner commands use a separate network relay per guest, with no NAT fallback. macOS uses pinned SSH through a user-private Unix socket; Linux control stays on Container's host control channel. Build the signed app with `Scripts/build-local-app.sh`; a bare `swift build` does not package the helper. Linux also requires the [pinned Container build](Docs/linux-runner-network.md). The relay permits public IPv4 TCP/UDP, filters host and private destinations, and uses a fixed public DNS resolver. IPv6, LAN/VPN DNS, and local service access are unavailable. See the [validation boundary](Docs/linux-runner-network.md#validation-boundary) for current acceptance coverage. See [runner boundaries](Docs/runner-boundaries.md) for limitations.

For the one-job diagnostic, authenticate the GitHub CLI:

```sh
gh auth login --hostname github.com
```

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

Machines receive 4 virtual CPUs and a 12 GiB memory ceiling. At boot, `/dev/shm` is resized from Container's 64 MiB default to half of guest memory, so browsers have room for shared memory. Runner processes and Docker-created workflow containers share a systemd slice with the same CPU allocation and an 8 GiB soft memory threshold. `yieldd` reserves each live machine's full ceiling against 75% of host physical memory, so the current configuration requires roughly 16 GiB of physical memory and concurrent runner slots cannot independently overcommit the host. Normal memory pressure removes the soft threshold; warning or unknown pressure keeps it. A slot waits before requesting its registration token when the memory budget is already reserved or host memory pressure is critical. Capacity waits end when another machine is deleted, while critical pressure is periodically rechecked. Reservations are released only after machine deletion succeeds.

## Machine integration test

After building the guest image, run:

```sh
.build/yieldd.app/Contents/MacOS/yieldd machine-test
```

The command shares the runner ownership lock and memory-admission policy with `runner-test`, foreground `connect`, and the login agent. It creates a uniquely named machine with no host home mount, runs `docker info`, checks both guest helpers' protocol version, runs `docker run --rm hello-world`, and destroys the machine. It attempts cleanup after every creation attempt, including failed ones and commands interrupted with Ctrl+C or SIGTERM.

### macOS template validation

Prepare a template using the [macOS template setup guide](Docs/macos-template.md). Build the signed local application, then validate a cold clone:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd machine-test --template /absolute/path/VM.bundle
```

Use the packaged executable for macOS commands. A plain `swift run` executable lacks the virtualization entitlement. Building the application does not install or start the agent.

Validation checks SSH, both guest helpers' protocol version, automatic console login, the GUI launchd domain, Xcode setup, an available compatible iOS runtime and iPhone device type, simulator boot, and a nonempty screenshot. Selection does not guarantee the newest runtime or device. Simulator validation has a ten-minute limit. The command attempts to destroy the clone after success, failure, or interruption; if destruction fails, it reports the failure and leaves the clone for recovery. The template is not modified. macOS clones reserve 8 GiB against the host budget and boot with 8 GiB under normal pressure or 6 GiB under warning or unknown pressure. No host directories are shared.

This command needs neither `container` nor `gh` when no abandoned leases exist. If leases exist, it recovers them first; Linux leases still require `container`. It also sweeps abandoned, unleased macOS clones.

macOS guests expose one virtual audio output for Core Audio workloads. Playback is discarded instead of sent to the host speakers, and no microphone input is exposed. The device is configured at VM creation, so updating yieldd requires restarting the service to use it in new guests; the template needs no audio-driver installation.

## Ephemeral runner test

Only run self-hosted jobs from private repositories and contributors you trust. A workflow job executes repository-controlled commands on the runner machine.

The included workflow waits for the `yieldd` label. The temporary runner has no default `self-hosted`, OS, or architecture labels, so generic self-hosted jobs cannot claim it. Queue the workflow before starting the runner. On `main`, dispatch the `Runner test` workflow manually. On a pull request, add the `yieldd-runner-test` label after the workflow exists on the base branch. GitHub runs the base-branch workflow, which does not check out or execute pull-request code.

Then start one ephemeral runner for that repository:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd runner-test OWNER/REPOSITORY
```

The command requests a short-lived registration token through the authenticated `gh` CLI, sends it to the guest over stdin, registers an ephemeral runner, and waits up to 120 minutes for one job. Override that limit with `--timeout MINUTES`, up to 1440 minutes. GitHub removes the ephemeral registration after the job. The command also attempts to remove any exact-name registration left behind and destroy the machine, including when setup or the job fails, times out, or receives Ctrl+C or SIGTERM. Cleanup failures are reported, and the lease remains available for recovery if the machine cannot be destroyed.

After macOS template validation passes, queue a trusted workflow with `runs-on: yieldd-macos`, then run:

```sh
.build/yieldd.app/Contents/MacOS/yieldd runner-test OWNER/REPOSITORY --template /absolute/path/VM.bundle
```

macOS runners have the `yieldd-macos` label and no default labels. Their names start with `yieldd-macos-test-`. Each job uses a fresh clone, and closing the controlling terminal also triggers cleanup through SIGHUP. The opt-in `macOS runner test` workflow can be dispatched manually once it is on the default branch; it is never queued automatically for pull requests.

`machine-test`, `runner-test`, foreground `connect`, and the login agent cannot run at the same time. They share one runner lock. GitHub runner sessions record active runners in `~/Library/Application Support/yieldd/active-runner.json` without storing credentials. After an interruption, use `yieldd recover` for one-job registrations and the exact Linux machine recorded by `machine-test`. Linux machine-test also recovers its previous machine before creating another. Connected assignments need their original coordinator and device ID. If GitHub still considers an interrupted runner busy, recovery keeps its lease and waits with exponential backoff until GitHub releases it.

Recovery requires an explicit platform in every runner lease. For macOS leases, recovery removes the GitHub registration and disposable clone without loading a template or attempting SSH. Before new runner slots start, it also removes unleased clones from the configured volume's `macos-runners/` and `macos-probes/`, leaving unrelated files and symbolic links untouched.

Leases without `platform` and agent configurations without `macOSRepositories` are no longer accepted. Before upgrading from those formats, use the previous version to recover outstanding runners and uninstall the old agent, then reinstall the agent after upgrading. Never delete unresolved leases to bypass recovery.

Before upgrading from an unconfigured storage layout, finish outstanding cleanup with the previous version. This version requires `storage.json` for disk cleanup and does not search or migrate legacy Container roots or clone directories. See the [storage setup instructions](Docs/runner-storage.md#set-up-a-mac).

## Standalone recovery

Run `yieldd recover` to clean up abandoned registrations and disposable macOS clones without starting new runner machines or uninstalling an agent. Stop any active yieldd service first: recovery takes the same exclusive ownership lock as runner commands. It needs no template or slot configuration. With no leases, it sweeps unleased clones without requiring `gh` or `container`; otherwise `gh` is required, and Linux leases also need a working Container system. A Linux failure does not prevent independent macOS cleanup. Failed cleanup records remain for a later retry.

## Reserved single-job tests

The [Scale Set coordinator prototype](Server/README.md) supports up to 16 repositories and 16 assignments per repository/platform queue. Repositories share memory-bounded worker pools on [one connected Mac](Docs/connected-mac-prototype.md), with up to two macOS guests and sixteen Linux guests. Same-platform jobs can run concurrently. `runs-on: yieldd` selects Linux; `yieldd-linux` is an alias when retained by GitHub. Linux sets can continue with `yieldd` alone and an explicit startup warning. `yieldd-macos` selects the independently enabled macOS queue. Queues without local capacity use their platform's user-selected fallback through a separate infrastructure repository, unless marked local-only. `--max-fallback-runners` limits active hosted bootstraps per repository/platform queue, defaulting to one. Idle local slots reserve no RAM. Earlier live testing confirmed both platforms and capacity-triggered fallback; the new same-platform concurrency still needs live validation. Connected execution requires renewable authorization with a five-minute offline grace; healthy jobs have no total duration limit. See [runner boundaries](Docs/runner-boundaries.md) before accepting hostile workloads.

To exercise job-specific routing before connecting a coordinator, queue a trusted job whose `runs-on` matches a unique label, then run:

```sh
.build/yieldd.app/Contents/MacOS/yieldd runner-test OWNER/REPOSITORY \
  --template /absolute/path/VM.bundle \
  --routing-label yieldd-request-unique-id \
  --pickup-timeout 5 --timeout 120
```

Replace `unique-id` with a fresh lowercase identifier. Labels must start with `yieldd-request-`, contain only lowercase letters, digits, and hyphens, and be at most 63 characters. The runner registers only this label, not its generic platform label. Omit `--template` for Linux. Rebuild the Linux guest image and update both macOS guest entry-point scripts before using reserved tests. These standalone tests do not use coordinator routing or hosted fallback.

The manual `macOS runner test` workflow accepts an optional `routing-label` input. Leaving it empty keeps the default `yieldd-macos` target. After pushing the branch containing this workflow change, generate one label and use it for both dispatch and the local runner:

```sh
routing_label="yieldd-request-$(uuidgen | tr '[:upper:]' '[:lower:]')"
gh workflow run macos-runner-test.yml --repo OWNER/REPOSITORY \
  --ref "$(git branch --show-current)" -f "routing-label=$routing_label" &&
.build/yieldd.app/Contents/MacOS/yieldd runner-test OWNER/REPOSITORY \
  --template /absolute/path/VM.bundle \
  --routing-label "$routing_label" --pickup-timeout 5 --timeout 15
```

Expect job-start and listener-exit events, followed by capacity release and cleanup completion. Check the workflow run in GitHub for its actual conclusion.

Startup has a ten-minute budget after memory admission, with existing shorter per-operation limits. Job pickup has its own five-minute default. With `--routing-label`, `--timeout` starts when yieldd observes the job-start hook; without it, the existing combined listener timeout is unchanged. Listener startup is not proof of an online GitHub connection. Status reports listener launch, observed job start, listener exit, machine-capacity release, and cleanup completion separately. Listener exit status is not the GitHub job conclusion.

A pickup timeout or lost connection does not prove that the job never started and must not automatically authorize duplicate execution on a hosted runner. Guest status is diagnostic data from the runner account, not a security boundary. Cleanup still attempts to remove the runner and machine; capacity is released only after confirmed machine removal. The completion hook is not used to destroy machines.

## Running at login

Use the connected installer with the same server, device ID, and platforms as foreground `connect`. The Mac needs its device token for initial enrollment. The coordinator owns repository selection and GitHub credentials. The installation guide covers Keychain access, upgrades, drain, status, and recovery. [Connected agent at login](Docs/connected-mac-prototype.md#connected-agent-at-login)

To migrate from unattended standalone operation, finish current jobs, stop the old foreground service or uninstall the old login agent with its original executable, and resolve all outstanding registrations and guests with the original GitHub identity. Keep the old app and its configuration until cleanup succeeds. Then install the connected agent. The new binary still reads old configuration for status and uninstall. One-job `runner-test` remains available for checking a particular Mac before enrollment.
