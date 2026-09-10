# yieldd

`yieldd` turns spare Mac resources into ephemeral GitHub Actions runners. The current package provides host diagnostics, Apple container machine management, integration tests, and a foreground worker with one ephemeral runner slot per repository argument.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer
- Swift 6.2 or newer
- For Linux runners: Apple `container` with container machine support and a running container system
- For macOS runners: a user-prepared template bundle on the same APFS volume as yieldd's Application Support directory
- For GitHub jobs or abandoned-runner recovery: GitHub CLI authenticated to `github.com` with administration access to the repository

For safety, `yieldd` rejects empty `PATH` components instead of interpreting them as the working directory.

Start the container system outside `yieldd` if needed:

```sh
container system start
```

`yieldd doctor` never starts or changes the container system.

For macOS-only checks, use the signed application with `doctor --template /absolute/path/VM.bundle`. This checks virtualization support, signing entitlement, template files and location, memory capacity, and GitHub authentication without requiring Apple Container. It does not boot a guest; use `machine-test` for SSH, GUI, and simulator validation.

Authenticate the GitHub CLI if needed:

```sh
gh auth login --hostname github.com
```

## Build and test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd doctor
```

The `CI` workflow builds and tests yieldd and verifies the signed app on GitHub-hosted `macos-26` runners for pushes to `main` and pull requests. Tests run serially while parallel lifecycle-test timing failures remain unresolved. To exercise the same job on a trusted yieldd macOS guest, manually dispatch `ci.yml` with the `runner` input set to `yieldd-macos`. Automatic CI never selects a self-hosted runner.

## Guest image

The local-agent installer builds the Ubuntu 24.04 guest image automatically when Linux slots are configured. To build it manually for the foreground commands, run this from the repository root:

```sh
container build -t local/yieldd-guest:dev Guest
```

The image boots systemd as PID 1 and runs Docker from Ubuntu's `docker.io` package. It also contains the pinned Linux ARM64 GitHub Actions runner. Guest commands run as the unprivileged `runner` user, which belongs to the `docker` group.

Machines receive 4 virtual CPUs and a 12 GiB memory ceiling. Runner processes and Docker-created workflow containers share a systemd slice with the same CPU allocation and an 8 GiB soft memory threshold. `yieldd` reserves each live machine's full ceiling against 75% of host physical memory, so the current configuration requires roughly 16 GiB of physical memory and concurrent runner slots cannot independently overcommit the host. Normal memory pressure removes the soft threshold; warning or unknown pressure keeps it. A slot waits before requesting its registration token when the memory budget is already reserved or host memory pressure is critical. Capacity waits end when another machine is deleted, while critical pressure is periodically rechecked. Reservations are released only after machine deletion succeeds.

## Machine integration test

After building the guest image, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd machine-test
```

The command shares the runner ownership lock and memory-admission policy with `runner-test`, `serve`, and the local agent. It creates a uniquely named machine with no host home mount, runs `docker info`, runs `docker run --rm hello-world`, and destroys the machine. It attempts cleanup after every creation attempt, including failed ones and commands interrupted with Ctrl+C or SIGTERM.

### macOS template validation

Prepare a template using the [macOS template setup guide](Docs/macos-template.md). Build the signed local application, then validate a cold clone:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd machine-test --template /absolute/path/VM.bundle
```

Use the packaged executable for macOS commands. A plain `swift run` executable lacks the virtualization entitlement. Building the application does not install or start the agent.

Validation checks SSH, automatic console login, the GUI launchd domain, Xcode setup, an available compatible iOS runtime and iPhone device type, simulator boot, and a nonempty screenshot. Selection does not guarantee the newest runtime or device. Simulator validation has a ten-minute limit. The command attempts to destroy the clone after success, failure, or interruption; if destruction fails, it reports the failure and leaves the clone for recovery. The template is not modified. macOS clones reserve 8 GiB against the host budget and boot with 8 GiB under normal pressure or 6 GiB under warning or unknown pressure. No host directories are shared.

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

`machine-test`, `runner-test`, `serve`, and the local agent cannot run at the same time. They share one runner lock. GitHub runner sessions record active runners in `~/Library/Application Support/yieldd/active-runner.json` without storing credentials. After a crash, forced termination, or reboot, `runner-test`, `serve`, the local agent, and macOS `machine-test` recover those exact runners before creating another machine. Linux `machine-test` does not perform recovery. If GitHub still considers an interrupted runner busy, recovery keeps its lease and waits with exponential backoff until GitHub releases it.

Recovery records the platform of each runner; older leases without a platform are treated as Linux. For macOS leases, recovery removes the GitHub registration and disposable clone without loading a template or attempting SSH. Before new runner slots start, it also removes unleased runner directories from `~/Library/Application Support/yieldd/macos-runners/`, leaving unrelated files and symbolic links untouched.

## Standalone recovery

Run `yieldd recover` to clean up abandoned registrations and disposable macOS clones without starting new runner machines or uninstalling an agent. Stop any active yieldd service first: recovery takes the same exclusive ownership lock as runner commands. It needs no template or slot configuration. With no leases, it sweeps unleased clones without requiring `gh` or `container`; otherwise `gh` is required, and Linux leases also need a working Container system. A Linux failure does not prevent independent macOS cleanup. Failed cleanup records remain for a later retry.

## Reserved single-job tests

The [nested runner bootstrap prototype](Docs/runner-bootstrap-prototype.md) explores fallback compute while leaving the original workload on `runs-on: yieldd`. It is manual and restricted to trusted jobs on disposable hosts; it does not yet implement a coordinator or scale sets.

To exercise job-specific routing before connecting a coordinator, queue a trusted job whose `runs-on` matches a unique label, then run:

```sh
.build/yieldd.app/Contents/MacOS/yieldd runner-test OWNER/REPOSITORY \
  --template /absolute/path/VM.bundle \
  --routing-label yieldd-request-unique-id \
  --pickup-timeout 5 --timeout 120
```

Replace `unique-id` with a fresh lowercase identifier. Labels must start with `yieldd-request-`, contain only lowercase letters, digits, and hyphens, and be at most 63 characters. The runner registers only this label, not its generic platform label. Omit `--template` for Linux. Rebuild the Linux guest image and update both macOS guest entry-point scripts before using reserved tests. No coordinator or hosted fallback is implemented yet.

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

## Foreground runner service

To keep serving jobs until the process is stopped, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd serve OWNER/REPOSITORY [OWNER/REPOSITORY ...]
```

Each repository argument creates one independent runner slot, up to 16 slots per process. Repeat a repository to give it more than one slot. Every slot creates and registers an ephemeral runner, waits for one job, cleans up both the GitHub registration and machine, and then starts its next runner. Setup and runner failures use exponential backoff capped at 30 seconds; a successful session resets that slot's delay. A cleanup failure stops the pool and cleans up the other slots rather than admitting more work alongside a machine whose removal could not be confirmed.

Add macOS slots with repeatable `--macos OWNER/REPOSITORY` options and one `--macos-template PATH`. Positional repositories remain Linux slots. Use the signed application for macOS slots:

```sh
.build/yieldd.app/Contents/MacOS/yieldd serve OWNER/LINUX-REPO \
  --macos OWNER/MACOS-REPO --macos-template /absolute/path/VM.bundle
```

Omit positional repositories for a macOS-only service, which does not require `container` unless abandoned Linux leases need recovery. The template path must be absolute. The service permits at most two macOS slots and sixteen total slots, provided their combined reservations fit within 75% of host physical memory. Linux reserves 12 GiB per live machine and macOS reserves 8 GiB. Two macOS slots fit within the 18 GiB budget of a 24 GiB host; a Linux and macOS slot together require 20 GiB, so that configuration is rejected before recovery or runner startup. Idle runners retain their reservations while waiting for jobs; slots do not rotate to make room for another platform. Each reservation is released only after its machine is confirmed absent.

Capacity rejection leaves abandoned leases and clones untouched. Restart with a configuration that fits the budget to recover them, or use `agent uninstall` for an installed agent. Supplying `--macos-template` more than once is an error.

This is a foreground command, not a daemon. Ctrl+C, SIGTERM, and closing the terminal (SIGHUP) interrupt every active slot and attempt cleanup before `yieldd` exits. The same signals stop `agent run`. The service does not impose `runner-test`'s two-hour job timeout.

## Local agent

The local agent runs the same runner pool at login without keeping a terminal open. For Linux slots, run `yieldd doctor` and start the container system once before installation so Apple Container can install any required kernel components. For macOS slots, validate the template with `machine-test` first.

Install one or more runner slots from the repository root:

```sh
Scripts/install-local-agent.sh OWNER/REPOSITORY [OWNER/REPOSITORY ...]
```

The installer accepts the same slots as `serve`, including up to two macOS slots and sixteen total slots. Their combined reservations must fit the host-memory budget; preflight rejects oversized configurations before replacing the existing application. For a macOS-only agent:

```sh
Scripts/install-local-agent.sh --macos OWNER/REPOSITORY --macos OWNER/REPOSITORY \
  --macos-template /absolute/path/VM.bundle
```

Add positional repositories to include Linux slots.

Before replacing any existing installation at `~/Applications/yieldd.app`, the script builds and verifies an ad-hoc-signed application and validates its configuration and template files. It builds the Linux guest image only when Linux slots are configured. It then waits for the previous agent to stop and recover active runners, installs the new application, and registers a per-user LaunchAgent through `SMAppService`. The ad-hoc signature is intended for local builds only; distributable releases will need Developer ID signing and notarization.

The saved configuration includes each platform's repository slots, the resolved absolute template path, and the absolute paths to `gh` and, when available, `container`. Linux slots require `container` at installation; macOS-only installations record it when found so later Linux lease recovery does not depend on launchd's PATH. Existing Linux-only configuration files remain supported. Status lists each slot's platform and the template path.

At startup, the shared service path validates capacity, template files, and the virtualization entitlement before Container startup or recovery. Recovery prepares Apple Container only for actual Linux leases, without interactive kernel installation. A Linux preparation failure retains those leases but does not prevent independent macOS cleanup. After recovery, configured Linux slots also require Container to start. An unused, stale Container path does not block a macOS-only agent.

A missing or unmounted template deliberately prevents new service startup, including startup recovery. Use `agent uninstall` to disable the agent and recover leases without that template. Uninstall ignores configured slots when deciding whether Container is needed. If an older macOS-only configuration has no saved Container path and Linux leases remain, uninstall disables the agent but retains the failed leases and configuration. Run `agent install` with the same slots and `container` on your shell's PATH to record its absolute path, then retry cleanup.

The installer invokes the previously installed binary's uninstall command. When migrating from an older Linux agent to macOS-only slots, keep `container` at its previously configured path until that uninstall succeeds; fixes in the new binary cannot change the old binary's cleanup behavior.

launchd gives the agent 60 seconds to stop. `yieldd` uses a 50-second shutdown budget for its runner processes and cleanup commands so launchd does not kill it halfway through cleanup. Any lease that cannot be cleared within that budget remains available for recovery on the next launch.

Check the registration, configured slots, and active runner leases with:

```sh
~/Applications/yieldd.app/Contents/MacOS/yieldd agent status
```

The status command reads persisted configuration and cleanup leases. It does not query live guest health, determine whether a job is running, or establish available capacity.

If macOS reports that approval is required, enable `yieldd` under System Settings > General > Login Items & Extensions. Agent logs are available through unified logging:

```sh
log stream --style compact --predicate 'subsystem == "dev.yieldd" && category == "agent"'
```

Rerun `Scripts/install-local-agent.sh` to upgrade the application or change its repository slots. To remove the agent configuration and stop launching it at login:

```sh
~/Applications/yieldd.app/Contents/MacOS/yieldd agent uninstall
```

Uninstall waits for the agent to stop, recovers any remaining runner leases, and removes its configuration. After the command returns successfully, the application can be moved to the Trash.
