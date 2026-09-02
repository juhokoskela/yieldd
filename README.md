# yieldd

`yieldd` turns spare Mac resources into ephemeral GitHub Actions runners. The current package provides host diagnostics, Apple container machine management, integration tests, and a foreground worker with one ephemeral runner slot per repository argument.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer
- Swift 6.2 or newer
- Apple `container` with container machine support
- A running container system
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

Build the Ubuntu 24.04 guest image from the repository root:

```sh
container build -t local/yieldd-guest:dev Guest
```

The image boots systemd as PID 1 and runs Docker from Ubuntu's `docker.io` package. It also contains the pinned Linux ARM64 GitHub Actions runner. Guest commands run as the unprivileged `runner` user, which belongs to the `docker` group.

Machines receive 4 virtual CPUs and a 12 GB memory ceiling. Runner processes and Docker-created workflow containers share a systemd slice with the same CPU allocation and an 8 GB soft memory threshold. Before each runner is configured, `yieldd` reads macOS's current memory-pressure level. Normal pressure removes the soft threshold, allowing the workload to use the VM's available memory; warning, critical, or unknown pressure keeps the 8 GB threshold. The threshold is not a hard memory limit, and the decision is reevaluated for every ephemeral runner.

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

`runner-test` and `serve` cannot run at the same time. They record active runners in `~/Library/Application Support/yieldd/active-runner.json` without storing credentials. After a crash, forced termination, or reboot, the next command cleans up those exact runners before creating another one. If GitHub still considers an interrupted runner busy, `yieldd` keeps its lease and the next command waits with exponential backoff until GitHub releases it.

## Foreground runner service

To keep serving jobs until the process is stopped, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd serve OWNER/REPOSITORY [OWNER/REPOSITORY ...]
```

Each repository argument creates one independent runner slot, up to 16 slots per process. Repeat a repository to give it more than one slot. Every slot creates and registers an ephemeral runner, waits for one job, cleans up both the GitHub registration and machine, and then starts its next runner. Setup and runner failures use exponential backoff capped at 30 seconds; a successful session resets that slot's delay. A cleanup failure stops the pool and cleans up the other slots rather than admitting more work alongside a machine whose removal could not be confirmed.

This is a foreground command, not a daemon. Ctrl+C and SIGTERM interrupt every active slot and run cleanup before `yieldd` exits. The service does not impose `runner-test`'s two-hour job timeout.
