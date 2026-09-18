# One connected Mac

This prototype offers one Linux ARM64 container slot, one macOS ARM64 VM slot, or both from one Mac. Application jobs use `runs-on: yieldd` (Linux), `yieldd-linux`, or `yieldd-macos`. If the coordinator warns that GitHub did not retain the `yieldd-linux` alias, use `yieldd` for Linux; macOS remains separate. An idle slot creates no guest and reserves no RAM. Polling advertises a snapshot of available memory; an offer must acquire an atomic reservation before acceptance.

There is at most one active runner per platform across local and fallback execution. Both local slots share one host-memory budget: Linux reserves 12 GiB and macOS reserves 8 GiB while provisioning or executing. A 24-GiB host's 18-GiB budget cannot run both simultaneously, but neither idle slot can starve the other. A platform without local capacity uses its configured fallback. This is not yet a multi-device scheduler or installed connected agent. Workloads must support the chosen fallback architecture as well as local ARM64.

## Setup

Use the same lowercase UUID in `YIELDD_DEVICE_ID` and the same random token in `YIELDD_CLIENT_TOKEN` in both terminals. Generate the UUID with `uuidgen | tr '[:upper:]' '[:lower:]'` and a token with `openssl rand -hex 32`. Supply the token through the environment, not a command argument or committed file. The listener authenticates the bearer token and separately checks the request's device ID against its single configured device. Anyone holding both can act as that device; do not share them with another Mac. Enrollment and token rotation are manual in this prototype.

Stop the previous coordinator after its lease has been cleaned up. Adding a device changes the persisted configuration, so use a new private state directory. Do not run the old and new coordinators against the same scale set concurrently.

From `Server/`, start the coordinator:

```sh
GH_TOKEN="$(gh auth token)" go run . \
  --repository juhokoskela/yieldd \
  --infrastructure juhokoskela/yieldd-infra \
  --fallback-runner '"ubuntu-24.04"' \
  --device-id "$YIELDD_DEVICE_ID" \
  --client-listen 127.0.0.1:8787 \
  --state-dir /Users/juhokoskela/.local/state/yieldd-connected-coordinator
```

Bind the native HTTP listener to loopback. The Compose container binds internally to all interfaces but publishes only a host-loopback port. For a remote Mac, expose it through a trusted HTTPS reverse proxy on the coordinator host. Forward `/v1/` and the Authorization header, allow 20-second long polls and 60-second operations, and disable response caching and credential/body logging. The Mac validates normal system TLS trust and refuses redirects. Direct loopback HTTP is permitted only for same-host testing.

For a separate Linux host, the [coordinator container setup](../Server/README.md#container-deployment-on-linux) provides a non-root image, persistent state, and a Compose service behind the host's HTTPS proxy. Only the coordinator moves into that container; `yieldd connect` remains a native macOS process.

On the Mac, rebuild the guest image with JIT support and the CLI, from the repository root:

```sh
container system start
container build -t local/yieldd-guest:dev Guest
container builder stop
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
```

Stop any standalone runner command or installed local agent first. `connect` uses the same ownership lock. Recover outstanding standalone leases with `yieldd recover` before connecting. For a same-host test:

```sh
.build/yieldd.app/Contents/MacOS/yieldd connect \
  --server http://127.0.0.1:8787 \
  --device-id "$YIELDD_DEVICE_ID"
```

For a different coordinator host, replace the server with its HTTPS origin. `connect` needs the device token, but no GitHub token or `gh` executable. Apple Container is required for Linux execution or recovery, not a macOS-only client. Broad GitHub credentials stay on the coordinator. The Mac client remains a foreground process; the coordinator can run in the foreground or through the Linux Compose deployment.

While accepting and executing an assignment, and during its cleanup attempt, `connect` prevents automatic idle system sleep. It releases that assertion when the attempt returns, including on failure or cancellation. Recovery acquires it again while cleaning up a recorded assignment. Idle polling and retry backoff do not keep the Mac awake. The display can sleep; closing the lid, explicitly choosing Sleep, and critical-battery shutdown are not prevented.

Once the client has completed any outstanding recovery and is polling, dispatch the existing test:

```sh
gh workflow run runner-test.yml --repo juhokoskela/yieldd --ref main
```

Expect `Local offer created`, `Local credentials issued`, and `Local runner cleaned up` on the coordinator, with no infrastructure bootstrap dispatch. The Mac reports listener progress and guest cleanup. Then stop the idle client, wait at least 30 seconds for its availability to expire, and dispatch again to exercise hosted fallback.

## Enable macOS

Add `--macos-fallback-runner '"macos-26"'` on the coordinator, or set `YIELDD_MACOS_FALLBACK_RUNNER='"macos-26"'` in its Compose environment file. This is an example target, not a built-in default.

Update both template guest scripts using the [macOS template setup](macos-template.md) before cloning it, then shut down the template VM. Both helpers must answer `--protocol-version` with `1`. `machine-test` checks this after boot; `connect` checks before sending credentials into the guest. Rebuild the Linux image too. These checks detect stale tooling, not a malicious guest.

On the Mac, offer both platforms through one process:

```sh
.build/yieldd.app/Contents/MacOS/yieldd connect \
  --server https://yieldd.example.com \
  --device-id "$YIELDD_DEVICE_ID" \
  --platform linux --platform macos \
  --macos-template /Users/juhokoskela/VM.bundle
```

For macOS only, omit `--platform linux`. With no platform flags, the existing command remains Linux-only. The macOS template path must be absolute and outside the managed clone directory. Both slots poll independently without reserving memory; when simultaneous offers exceed the budget, only the slot that acquires its reservation can accept. The other offer expires into its own fallback. On a host with enough memory, the two platforms can execute concurrently.

The proxy must forward all of `/v1/`, including `/v1/macos/`. Workflows need only `runs-on: yieldd-macos`; no workflow-side routing action is needed.

## Delivery and recovery

An offer contains the repository, coordinator identity, runner identity, and the queue's Linux or macOS ARM64 platform. It contains no executable command. The Mac has five seconds to accept an offer; guest startup is not part of that deadline. A coordinator timer starts hosted fallback when an unaccepted offer expires, without waiting for another GitHub demand message. On restart, the coordinator first confirms current demand with GitHub so it can retract an obsolete offer. Acceptance and expiry share the same event loop, so they cannot both win. An in-progress coordinator operation can delay timer handling. Logs report acceptance latency and expired offers.

Availability remains valid for 30 seconds after a poll. Acceptance starts a separate 30-second registration window: if credential delivery never reaches the issued phase, the next demand reconciliation after expiry, or zero demand, triggers registration cleanup before another allocation. Issued credentials never expire into hosted fallback.

The Mac writes a private, durable journal per platform before accepting. Linux retains `connected-runner.json`; macOS uses `connected-macos-runner.json`. Startup recovers both journals, including disabled platforms, before polling. macOS crash recovery does not require the template: the prior process's VM is gone, so it removes the recorded clone and acknowledges cleanup. The coordinator persists acceptance before registration and possible credential delivery before returning the JIT payload. Credentials are issued at most once; a lost response never triggers a second execution attempt. The Mac validates the runner identity, ephemeral setting, and work directory, then delivers the payload through stdin into its guest. The guest passes it through the runner's JIT environment variable, not process arguments. The pinned runner consumes and removes that variable before starting jobs. This is not isolation from a trusted workload running under the same guest account. The host journal does not contain the JIT payload.

The listener has a five-minute pickup timeout. Healthy jobs have no fixed total execution deadline, but the host requires renewed coordinator authorization every five minutes. It requests renewal every 30 seconds and retries transient failures after five seconds. The coordinator allows ten minutes for startup and pickup after issuing credentials; after that, GitHub must report the runner busy. A matching GitHub completion event durably revokes authorization. Guest status cannot extend it. Missing renewal for five minutes or explicit revocation stops the guest through the host backend, even if the guest claims it is still running. A stuck host backend or failed destruction remains a cleanup error, not proof of termination.

Upgrade the coordinator before the Mac client: the new client requires `/v1/renew` and `/v1/macos/renew`. Old clients do not enforce this authorization policy. Ctrl+C also stops local execution and attempts guest destruction and server acknowledgement. Destruction must succeed before the client acknowledges completion. The coordinator then reconciles the registration, refusing to remove a busy runner. A failed job is not a failed listener: GitHub retains the workload's own conclusion.

Transport failures and retryable HTTP responses trigger a five-second retry delay. During execution, renewal failures use the remaining offline grace. Before accepting more work after an interrupted assignment, the client destroys any recorded guest and retries acknowledgement. It never retries acceptance or resumes the recorded listener. Restarting `connect` uses the same recovery path. Failed destruction, permanent HTTP errors, and invalid responses stop the client with unresolved recovery state retained. Standalone runner commands refuse to bypass that journal. Empty polls have a one-second client-side delay, and memory admission reports when it cannot advertise capacity.

Restart the coordinator with the same arguments and state directory after a server interruption. Once credentials may have reached a Mac, disconnection and elapsed time do not authorize hosted replacement. An issued assignment without a cleanup acknowledgement blocks new provisioning for its platform, including hosted fallback, until the Mac returns. The coordinator reports this hold. Once cleanup intent is durable, normal reconciliation can finish registration cleanup without another acknowledgement; transient local-cleanup failures retain the lease and retry on subsequent reconciliation. `--recover` cannot bypass an issued local assignment. A stopped idle client does not block hosted fallback after its advertised availability expires.

If the coordinator's original state is permanently lost, restoring it is preferable to abandoning recovery. Otherwise, first stop the old coordinator and manually remove the exact runner registration from the application repository's GitHub settings. Then, on the Mac, use the original server and device ID and the runner name printed in the recovery error:

```sh
.build/yieldd.app/Contents/MacOS/yieldd connect \
  --server http://127.0.0.1:8787 \
  --device-id "$YIELDD_DEVICE_ID" \
  --confirm-registration-removed yieldd-bootstrap-REPLACE-WITH-EXACT-RUNNER-UUID
```

This is an explicit operator assertion that GitHub registration cleanup is complete. It does not remove the registration for you or contact the coordinator. It requires an exact match to the local journal, destroys the guest, clears the journal only after successful destruction, and exits without polling. It needs no device token. Never use it merely to force fallback while the original assignment may still be active elsewhere. If the Mac or its journal is lost, verify guest termination and registration removal separately before repairing server state.

## Validation boundary

Local tests cover authenticated HTTP, response bounds, redirect refusal, signal cancellation, offer expiry, duplicate acceptance, persisted recovery phases, credential handling, cleanup failures, and renewable execution authorization. Earlier live testing confirmed Linux and macOS execution, simultaneous slots, and capacity-triggered fallback. The authorization protocol and bridge-network deployment changes still require live acceptance; the fixtures do not establish those provider and host boundaries.

See [runner boundaries](runner-boundaries.md) for the controls implemented here and the host network, storage, and coordinator-trust risks that remain.
