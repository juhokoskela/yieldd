# yieldd

`yieldd` turns spare Mac resources into ephemeral GitHub Actions runners. The current package provides host diagnostics, Apple container machine management, integration tests, and a foreground worker with one ephemeral runner slot per repository argument.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer
- Swift 6.2 or newer
- Apple `container` with container machine support
- A running container system for foreground commands
- GitHub CLI authenticated to `github.com` with administration access to the test repository

For safety, `yieldd` rejects empty `PATH` components instead of interpreting them as the working directory.

Start the container system outside `yieldd` if needed:

```sh
container system start
```

`yieldd doctor` never starts or changes the container system.

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

## Guest image

The local-agent installer builds the Ubuntu 24.04 guest image automatically. To build it manually for the foreground commands, run this from the repository root:

```sh
container build -t local/yieldd-guest:dev Guest
```

The image boots systemd as PID 1 and runs Docker from Ubuntu's `docker.io` package. It also contains the pinned Linux ARM64 GitHub Actions runner. Guest commands run as the unprivileged `runner` user, which belongs to the `docker` group.

Machines receive 4 virtual CPUs and a 12 GB memory ceiling. Runner processes and Docker-created workflow containers share a systemd slice with the same CPU allocation and an 8 GB soft memory threshold. `yieldd` reserves each live machine's 12 GB ceiling against 75% of host physical memory, so concurrent runner slots cannot independently overcommit the host. Normal memory pressure removes the soft threshold; warning or unknown pressure keeps it, and critical pressure pauses new machine creation. Reservations are released only after machine deletion succeeds.

## Machine integration test

After building the guest image, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd machine-test
```

The command creates a uniquely named machine with no host home mount, runs `docker info`, runs `docker run --rm hello-world`, and destroys the machine. It attempts cleanup after every creation attempt, including failed ones and commands interrupted with Ctrl+C or SIGTERM.

## Ephemeral runner test

Only run self-hosted jobs from private repositories and contributors you trust. A workflow job executes repository-controlled commands on the runner machine.

The included workflow waits for the `yieldd` label. The temporary runner has no default `self-hosted`, OS, or architecture labels, so generic self-hosted jobs cannot claim it. Queue the workflow before starting the runner. On `main`, dispatch the `Runner test` workflow manually. On a pull request, add the `yieldd-runner-test` label after the workflow exists on the base branch. GitHub runs the base-branch workflow, which does not check out or execute pull-request code.

Then start one ephemeral runner for that repository:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd runner-test OWNER/REPOSITORY
```

The command requests a short-lived registration token through the authenticated `gh` CLI, sends it to the guest over stdin, registers an ephemeral runner, and waits up to 120 minutes for one job. Override that limit with `--timeout MINUTES`, up to 1440 minutes. GitHub removes the ephemeral registration after the job. The command also removes any exact-name registration left behind and destroys the machine, including when setup or the job fails, times out, or receives Ctrl+C or SIGTERM.

`runner-test`, `serve`, and the local agent cannot run at the same time. They share one runner lock and record active runners in `~/Library/Application Support/yieldd/active-runner.json` without storing credentials. After a crash, forced termination, or reboot, the next runner command cleans up those exact runners before creating another one. If GitHub still considers an interrupted runner busy, `yieldd` keeps its lease and the next command waits with exponential backoff until GitHub releases it.

## Foreground runner service

To keep serving jobs until the process is stopped, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd serve OWNER/REPOSITORY [OWNER/REPOSITORY ...]
```

Each repository argument creates one independent runner slot, up to 16 slots per process. Repeat a repository to give it more than one slot. Every slot creates and registers an ephemeral runner, waits for one job, cleans up both the GitHub registration and machine, and then starts its next runner. Setup and runner failures use exponential backoff capped at 30 seconds; a successful session resets that slot's delay. A cleanup failure stops the pool and cleans up the other slots rather than admitting more work alongside a machine whose removal could not be confirmed.

This is a foreground command, not a daemon. Ctrl+C and SIGTERM interrupt every active slot and run cleanup before `yieldd` exits. The service does not impose `runner-test`'s two-hour job timeout.

## Local agent

The local agent runs the same runner pool at login without keeping a terminal open. Before installing it, run `yieldd doctor` and start the container system once so Apple Container can install any required kernel components.

Install one or more runner slots from the repository root:

```sh
Scripts/install-local-agent.sh OWNER/REPOSITORY [OWNER/REPOSITORY ...]
```

Before replacing any existing installation at `~/Applications/yieldd.app`, the script builds the guest image and an ad-hoc-signed application, then verifies the application. It waits for the previous agent to stop and recover active runners, installs the new application, stores the repository slots plus the resolved absolute paths to `container` and `gh`, and registers a per-user LaunchAgent through `SMAppService`. The agent starts Apple Container without interactive kernel installation, recovers abandoned runners, and then serves the configured repositories. The ad-hoc signature is intended for local builds only; distributable releases will need Developer ID signing and notarization.

launchd gives the agent 60 seconds to stop. `yieldd` uses a 50-second shutdown budget for its runner processes and cleanup commands so launchd does not kill it halfway through cleanup. Any lease that cannot be cleared within that budget remains available for recovery on the next launch.

Check the registration, configured slots, and active runner leases with:

```sh
~/Applications/yieldd.app/Contents/MacOS/yieldd agent status
```

If macOS reports that approval is required, enable `yieldd` under System Settings > General > Login Items & Extensions. Agent logs are available through unified logging:

```sh
log stream --style compact --predicate 'subsystem == "dev.yieldd" && category == "agent"'
```

Rerun `Scripts/install-local-agent.sh` to upgrade the application or change its repository slots. To remove the agent configuration and stop launching it at login:

```sh
~/Applications/yieldd.app/Contents/MacOS/yieldd agent uninstall
```

Uninstall waits for the agent to stop, recovers any remaining runner leases, and removes its configuration. After the command returns successfully, the application can be moved to the Trash.
