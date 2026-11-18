# One connected Mac

This prototype offers Linux ARM64 containers, macOS ARM64 VMs, or both from one Mac, with several jobs able to run at once. Application jobs use `runs-on: yieldd` (Linux), `yieldd-linux`, or `yieldd-macos`. If the coordinator warns that GitHub did not retain the `yieldd-linux` alias, use `yieldd` for Linux; macOS remains separate. An idle slot creates no guest and reserves no RAM. Polling advertises a snapshot of available memory; an offer must acquire an atomic reservation before acceptance.

`connect` sizes its worker pool from 75% of physical memory. Linux reserves 12 GiB per guest and macOS reserves 8 GiB. A 48-GiB Mac therefore offers three Linux workers and two macOS workers; they share a 36-GiB budget, so not all five can run simultaneously. A 24-GiB Mac can run two macOS guests or one Linux guest, but not both platforms together. Critical memory pressure prevents new reservations. Idle workers consume none of this budget.

macOS workers are capped at two, in line with [Apple's standard macOS virtualization allowance](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf). Shut down the template and other macOS VMs before running two guests. Linux workers are capped at 16. These are worker limits, not guarantees of available host CPU, disk, or memory.

All repositories share these local workers. Each repository/platform queue can hold up to 16 assignments. The coordinator's `--max-fallback-runners` setting limits active hosted bootstraps per queue, defaulting to one; Compose exposes it as `YIELDD_MAX_FALLBACK_RUNNERS`. Additional demand waits when neither local capacity nor another fallback slot is available. Local-only repositories never dispatch fallback. This is not yet a multi-device scheduler. Workloads using fallback must support its architecture as well as local ARM64.

## Setup

Before upgrading from the single-worker protocol, finish jobs and recovery with the previous coordinator and client, then stop both and update them together. Do not carry an active old journal into this version. Empty multi-repository coordinator state can be reused; command arguments and environment variables are unchanged.

Use the same lowercase UUID in `YIELDD_DEVICE_ID` and the same random token in `YIELDD_CLIENT_TOKEN` in both terminals. Generate the UUID with `uuidgen | tr '[:upper:]' '[:lower:]'` and a token with `openssl rand -hex 32`. Supply the token through the environment, not a command argument or committed file. The listener authenticates the bearer token and separately checks the request's device ID against its single configured device. Anyone holding both can act as that device; do not share them with another Mac. Enrollment and token rotation are manual in this prototype.

Stop the previous coordinator after its lease has been cleaned up. Adding a device changes the persisted configuration, so use a new private state directory. Do not run the old and new coordinators against the same scale set concurrently.

From `Server/`, start the coordinator:

```sh
GH_TOKEN="$(gh auth token)" go run . \
  --repositories juhokoskela/yieldd \
  --infrastructure juhokoskela/yieldd-infra \
  --fallback-runner '"ubuntu-24.04"' \
  --device-id "$YIELDD_DEVICE_ID" \
  --client-listen 127.0.0.1:8787 \
  --state-dir /Users/juhokoskela/.local/state/yieldd-connected-coordinator
```

Bind the native HTTP listener to loopback. The Compose container explicitly opts into wildcard binding with `--allow-non-loopback-client-listen` and publishes only a host-loopback port. Without that flag, wildcard binding is rejected. For a remote Mac, expose it through a trusted HTTPS reverse proxy on the coordinator host. Forward `/v1/` and the Authorization header, allow 20-second long polls and 60-second operations, and disable response caching and credential/body logging. The Mac validates normal system TLS trust and refuses redirects. Direct loopback HTTP is permitted only for same-host testing.

For a separate Linux host, the [coordinator container setup](../Server/README.md#container-deployment-on-linux) provides a non-root image, persistent state, and a Compose service behind the host's HTTPS proxy. Only the coordinator moves into that container; `yieldd connect` remains a native macOS process.

Add repositories to the coordinator's comma-separated `--repositories` list, not to the Mac command. Use `--local-only-repositories` for repositories that must wait rather than use fallback. The infrastructure repository's own CI must be local-only, while its fallback bootstrap workflow continues to target an external provider. The [server setup](../Server/README.md#setup) describes queue state and the required migration from single-repository deployments.

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

For a different coordinator host, replace the server with its HTTPS origin. `connect` needs the device token, but no GitHub token or `gh` executable. The [pinned Container build](linux-runner-network.md) is required for Linux execution or recovery, not a macOS-only client. Broad GitHub credentials stay on the coordinator. The Mac client can run in the foreground or as the installed connected agent below; the coordinator can run in the foreground or through the Linux Compose deployment.

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

For macOS only, omit `--platform linux`. With no platform flags, the existing command remains Linux-only. The macOS template path must be absolute and outside the managed clone directory. Workers poll independently without reserving memory. When simultaneous offers exceed the budget, only workers that acquire reservations can accept. A worker that loses admission immediately declines its offer, so the coordinator can reconcile without waiting five seconds. Declined or expired offers use fallback if the queue is below its configured hosted limit; otherwise they return to waiting. Local-only offers always return to waiting. A host with enough memory can execute several jobs from the same platform and repository, or mix platforms and repositories.

The proxy must forward all of `/v1/`, including `/v1/macos/`. Workflows need only `runs-on: yieldd-macos`; no workflow-side routing action is needed.

## Connected agent at login

After validating foreground execution, install the connected agent from the repository root:

```sh
Scripts/install-local-agent.sh \
  --server https://yieldd.example.com --device-id "$YIELDD_DEVICE_ID" \
  --platform linux --platform macos --macos-template /absolute/path/VM.bundle
```

Supply `YIELDD_CLIENT_TOKEN` in the installer's environment for first enrollment. Installation saves it as a non-synchronizing generic password in the login Keychain, separate from the private `connected-agent.json` configuration. The agent reads the token without prompting; a locked or inaccessible keychain stops startup and retains recovery records. macOS may require Keychain access approval during setup. No GitHub CLI or GitHub token is needed on the Mac. Device enrollment and token rotation remain manual on the coordinator.

For a routine upgrade, rerun the installer with the saved configuration. It validates the staged build and checks access to the existing Keychain credential, then builds the Linux image when needed. If macOS prompts for the new ad-hoc signature, grant that build ongoing access to the existing entry. Preflight repeats the read with prompts disabled before draining the old agent. It drains the running agent, replaces the app at the registered path, and waits for a new, paused, ready instance reporting the staged build ID. Keep admission controls with the operator running the update until it finishes. An accepting agent resumes. An already-paused agent stays paused. Keep the previous executable available when migrating a legacy installation that lacks drain support.

If replacement fails before the new instance is ready, the installer restores the previous bundle and Linux image tag. If rollback fails or power is lost, keep `~/Applications/.yieldd-installer`, the `local/yieldd-guest:previous-*` tag and the recovery journals. Inspect the installed bundle and saved backup before resuming admissions. If initial enrollment failed after writing configuration, keep the installed app and rerun its `agent install-connected` command with the original arguments. Verify registration, credentials and readiness before clearing the installer directory. To change identity or credentials, drain and explicitly uninstall under the original identity first. If no agent is reachable, resolve its login-item registration or existing foreground owner before retrying.

Use `yieldd agent status` from the installed app to inspect registration and configuration, and `yieldd agent uninstall` to disable it and recover outstanding assignments. Configuration and the Keychain token remain if recovery fails. The agent uses unified logging under subsystem `dev.yieldd`, category `agent`, and has a 50-second shutdown budget. Foreground `connect` remains available for diagnostics.

### Pause and drain

Run these commands from the installed app:

```sh
yieldd agent pause
yieldd agent drain
yieldd agent resume
```

`pause` stops new connected admissions and lets active assignments finish. A poll already in flight may still return an offer; the worker declines it before accepting credentials. Paused clients stop advertising capacity, and the coordinator's existing availability lease expires normally. Hosted fallback remains governed by coordinator policy.

`drain` pauses and waits for all accepted work and cleanup to finish. It does not stop guests, revoke execution authorization, or unregister the agent. Cleanup retries keep the assignment active until they succeed. Cancelling the waiting command leaves the agent paused; an unavailable service, an agent restart, or another caller's resume fails the wait. Run it before replacing or uninstalling the agent when existing jobs should finish first. Uninstall itself still stops the process and performs recovery.

Pause persists across process restarts and app replacement. Resume explicitly when maintenance is complete. These controls apply to the installed connected agent; foreground diagnostic commands keep their own process lifetime. Control requests use a versioned local XPC interface restricted to the agent's effective user. It opens no network listener.

### Live status

`yieldd agent status` queries the running connected agent over XPC. Add `--json` for a versioned report suitable for a menu bar client or local tooling. The XPC response and JSON report contain no device token or JIT credential payload.

Live status includes service readiness, pause/drain state, active assignment and cleanup counts, worker phases, runner/repository identities, memory reservations and pressure, the latest coordinator request result and successful contact time, and the last error with its timestamp. Reservations are the runner budget, not measured guest RSS or host free memory. A successful coordinator request is a recent observation, not a guarantee of current reachability; paused and memory-blocked workers may make no requests. Listener exit does not establish the GitHub job conclusion.

When XPC is unavailable, the report has no live snapshot. It shows the connection error and any last recorded fatal startup/runtime failure, clearly labeled as history. This small private diagnostic record is separate from recovery journals; damage or failure to save it never changes cleanup or execution authority. Standalone `agent status` retains its existing configuration/lease report.

### End-to-end acceptance

Use the installer from this checkout and a trusted repository to validate the installed service:

1. Install connected mode with the existing coordinator identity and token. Approve the login item and any setup-time Keychain access, then verify startup after login. Check a locked/missing Keychain token and a rebuilt app against an existing Keychain item; background startup should fail visibly rather than prompt.
2. Observe `agent status --json` while real Linux and macOS jobs move through provisioning, pickup, execution, capacity release, and cleanup. Exercise concurrent same-platform guests and memory contention. Confirm the reported runner identities against coordinator and GitHub records.
3. Pause during a long poll and while jobs are active. Confirm existing jobs finish, new offers are declined, idle capacity stops being advertised, and configured hosted fallback runs new demand. Restart while paused and verify pause persists.
4. Drain during execution and cleanup retries. Confirm it waits until cleanup is complete, and that Ctrl+C only stops the wait. Resume/re-pause from another terminal and restart the service during separate drain attempts; each wait must fail rather than silently attach to a new admission period.
5. Interrupt networking and restart the coordinator/client with their original state. Confirm status reports retry/recovery accurately, no duplicate execution starts, and unresolved cleanup remains recorded. Check the unavailable-service report after a startup failure.
6. Drain before replacing or uninstalling the installed app. Verify recovery, retained pause, explicit resume, and normal subsequent local execution and fallback.

The installed service, real guests, network-isolation checks, and fallback placement are live acceptance boundaries. Unit tests and the anonymous XPC fixture do not establish them.

## Delivery and recovery

An offer contains the repository, queue identity, runner identity, worker slot, and the queue's Linux or macOS ARM64 platform. It contains no executable command. Acceptance, renewal, and cleanup use the persisted queue, runner, and slot identities, not the currently waiting repository. Only one long poll is allowed per platform/worker slot; different workers poll independently. The Mac has five seconds to accept an offer; guest startup is not part of that deadline. A coordinator timer starts hosted fallback when an unaccepted offer expires, without waiting for another GitHub demand message. Local-only offers instead release their claim and wait again. On restart, the coordinator first confirms current demand with GitHub so it can retract an obsolete offer. Acceptance and expiry share the queue's event loop, so they cannot both win. Each queue offers one worker at a time until its credentials are issued, then immediately offers the next worker for outstanding demand. Guest boot and execution overlap; serial registration keeps slow GitHub calls from consuming another offer's acceptance window. An in-progress operation can delay that queue's timer, but not another queue's polling. Logs report acceptance latency and expired offers.

Availability remains valid for 30 seconds after a poll. Acceptance starts a separate 30-second registration window: if credential delivery never reaches the issued phase, the next demand reconciliation after expiry, or zero demand, triggers registration cleanup before another allocation. Issued credentials never expire into hosted fallback.

The Mac writes a private, durable journal per platform and worker before accepting. Slot zero uses `connected-runner.json` or `connected-macos-runner.json`; higher slots add their index, such as `connected-runner-1.json`. Startup inspects every supported slot, including disabled platforms and workers no longer enabled by the current memory budget, and finishes recovery before polling. macOS crash recovery does not require the template: the prior process's VM is gone, so it removes the recorded clone and acknowledges cleanup. The coordinator persists acceptance before registration and possible credential delivery before returning the JIT payload. Credentials are issued at most once; a lost response never triggers a second execution attempt. The Mac validates the runner identity, ephemeral setting, and work directory, then delivers the payload through stdin into its guest. The guest passes it through the runner's JIT environment variable, not process arguments. The pinned runner consumes and removes that variable before starting jobs. This is not isolation from a trusted workload running under the same guest account. The host journal does not contain the JIT payload.

The listener has a five-minute pickup timeout. Healthy jobs have no fixed total execution deadline, but the host requires renewed coordinator authorization every five minutes. It requests renewal every 30 seconds and retries transient failures after five seconds. The coordinator allows ten minutes for startup and pickup after issuing credentials, ending that allowance earlier if GitHub reports zero demand. An active job can still renew when GitHub reports its runner busy. A matching GitHub completion event durably revokes authorization. Guest status cannot extend it. Missing renewal for five minutes or explicit revocation stops the guest through the host backend, even if the guest claims it is still running. A stuck host backend or failed destruction remains a cleanup error, not proof of termination.

Ctrl+C also stops local execution and attempts guest destruction and server acknowledgement. Destruction must succeed before the client acknowledges completion. The coordinator then reconciles the registration, refusing to remove a busy runner. A failed job is not a failed listener: GitHub retains the workload's own conclusion.

Transport failures and retryable HTTP responses trigger a five-second retry delay. During execution, renewal failures use the remaining offline grace. Before accepting more work after an interrupted assignment, the client destroys any recorded guest and retries acknowledgement. It never retries acceptance or resumes the recorded listener. Restarting `connect` uses the same recovery path. Failed destruction, permanent coordinator HTTP errors, and invalid coordinator responses stop the client with unresolved recovery state retained. Standalone runner commands refuse to bypass that journal. Empty polls have a one-second client-side delay, and memory admission reports when it cannot advertise capacity.

After yieldd observes job start, a command timeout, nonzero exit, signal termination, invalid listener status, or loss of the VM or network relay stops that assignment without cancelling healthy sibling workers. A CLI or SSH failure does not establish whether the guest or host transport failed; containment applies to either after job start. The worker polls again only after guest destruction, coordinator acknowledgement, and journal removal all succeed. This does not retry the failed job.

Failures before an observed job start, including listener startup failure, pickup timeout, and an exit without a job, stop the client instead of repeatedly accepting local demand. Host process-launch or I/O failures, permanent coordinator errors, and cancellation also remain fatal. Failed cleanup is never treated as a completed assignment.

Restart the coordinator with the same configuration and state directory after a server interruption. Once credentials may have reached a Mac, disconnection and elapsed time do not authorize hosted replacement. An issued assignment without a cleanup acknowledgement retains its own worker slot and counts against its queue's capacity until the Mac returns. It does not occupy other workers. Other demand can still use free local workers or available hosted capacity within the queue's configured fallback limit. The coordinator reports this hold. On restart the Mac attempts local destruction for independent slots before retrying remote acknowledgements. Once cleanup intent is durable, normal reconciliation can finish registration cleanup without another acknowledgement; transient local-cleanup failures retain the lease and retry after five seconds, even without another demand message. `--recover` cannot bypass an issued local assignment. A stopped idle client does not block hosted fallback after its advertised availability expires.

If the coordinator's original state is permanently lost, restoring it is preferable to abandoning recovery. Otherwise, first stop the old coordinator and manually remove the exact runner registration from the application repository's GitHub settings. Then, on the Mac, use the original server and device ID and the runner name printed in the recovery error:

```sh
.build/yieldd.app/Contents/MacOS/yieldd connect \
  --server http://127.0.0.1:8787 \
  --device-id "$YIELDD_DEVICE_ID" \
  --confirm-registration-removed yieldd-bootstrap-REPLACE-WITH-EXACT-RUNNER-UUID
```

This is an explicit operator assertion that GitHub registration cleanup is complete. It does not remove the registration for you or contact the coordinator. It requires an exact match to the local journal, destroys the guest, clears the journal only after successful destruction, and exits without polling. It needs no device token. Never use it merely to force fallback while the original assignment may still be active elsewhere. If the Mac or its journal is lost, verify guest termination and registration removal separately before repairing server state.

## Validation boundary

Local tests cover authenticated HTTP, response bounds, redirect refusal, signal cancellation, offer expiry and decline, duplicate acceptance, persisted recovery phases, credential handling, cleanup failures, and renewable execution authorization. Tests also exercise overlapping simulated guests, mixed-platform memory contention, independent worker journals, and recovery of slots no longer enabled. CI runs the Swift HTTP client against the Go router with fake GitHub responses across two platforms, repositories, and worker slots. Earlier live testing confirmed Linux and macOS execution, one simultaneous slot per platform, and capacity-triggered fallback. The new same-platform concurrency still needs live acceptance with actual guests; these fixtures do not establish that boundary.

See [runner boundaries](runner-boundaries.md) for the controls implemented here and the host network, storage, and coordinator-trust risks that remain.
