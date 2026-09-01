# yieldd

`yieldd` turns spare Mac resources into ephemeral GitHub Actions runners. The current package provides host diagnostics, Apple container machine management, integration tests, and a foreground worker that serves one repository with one ephemeral runner at a time.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer
- Swift 6.2 or newer
- Apple `container` with container machine support
- A running container system
- GitHub CLI authenticated to `github.com` with administration access to the test repository

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

Machines receive 8 virtual CPUs and a 12 GB memory ceiling. Runner processes and Docker-created workflow containers share a systemd slice that starts with 4 virtual CPUs and an 8 GB soft memory threshold. Before each runner is configured, `yieldd` reads macOS's current memory-pressure level. Normal pressure removes the soft threshold, allowing the workload to use the VM's available memory; warning, critical, or unknown pressure keeps the 8 GB threshold. The threshold is not a hard memory limit, and the decision is reevaluated for every ephemeral runner.

The guest also has an 8-vCPU full profile ready for the future host activity governor. Current commands always select the 4-vCPU constrained profile.

## Machine integration test

After building the guest image, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd machine-test
```

The command creates a uniquely named machine with no host home mount, runs `docker info`, runs `docker run --rm hello-world`, and destroys the machine. It attempts cleanup after every creation attempt, including failed ones.

## Ephemeral runner test

Only run self-hosted jobs from private repositories and contributors you trust. A workflow job executes repository-controlled commands on the runner machine.

The included workflow waits for the `yieldd` label. The temporary runner has no default `self-hosted`, OS, or architecture labels, so generic self-hosted jobs cannot claim it. Queue the workflow before starting the runner. On `main`, dispatch the `Runner test` workflow manually. On a pull request, add the `yieldd-runner-test` label after the workflow exists on the base branch. GitHub runs the base-branch workflow, which does not check out or execute pull-request code.

Then start one ephemeral runner for that repository:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd runner-test OWNER/REPOSITORY
```

The command requests a short-lived registration token through the authenticated `gh` CLI, sends it to the guest over stdin, registers an ephemeral runner, and waits up to 120 minutes for one job. Override that limit with `--timeout MINUTES`. GitHub removes the ephemeral registration after the job. The command also removes any exact-name registration left behind and destroys the machine, including when setup or the job fails, times out, or receives Ctrl+C or SIGTERM.

## Foreground runner service

To keep serving jobs until the process is stopped, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run yieldd serve OWNER/REPOSITORY
```

`serve` creates and registers one ephemeral runner, waits for one job, cleans up both the GitHub registration and machine, and then starts the next runner. It never runs two sessions concurrently. Setup and runner failures use exponential backoff capped at 30 seconds; a successful session resets the delay. A cleanup failure stops the service rather than risking another runner alongside a machine whose removal could not be confirmed.

This is a foreground command, not a daemon. Ctrl+C and SIGTERM interrupt the active command and run cleanup before `yieldd` exits. The service does not impose `runner-test`'s two-hour job timeout.
