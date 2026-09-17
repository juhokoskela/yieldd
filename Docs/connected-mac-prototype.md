# One connected Mac

This prototype adds one Linux ARM64 container slot to the coordinator. Application jobs still use `runs-on: yieldd`. An idle Mac creates no guest. A pending authenticated poll advertises one slot after local memory admission succeeds; accepted work uses the existing 4-vCPU, 12-GiB Linux machine configuration.

There is still only one active runner across local and hosted execution. This is not yet a multi-device scheduler, macOS guest client, or installed connected agent. Ubuntu's default hosted runner is x64, so workloads must support both architectures or select an ARM64 fallback.

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

The HTTP listener binds only to a loopback IP. For a remote Mac, expose it through a trusted HTTPS reverse proxy on the coordinator host. Forward `/v1/` and the Authorization header, allow 20-second long polls and 60-second operations, and disable response caching and credential/body logging. The Mac validates normal system TLS trust and refuses redirects. Direct loopback HTTP is permitted only for same-host testing.

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

For a different coordinator host, replace the server with its HTTPS origin. `connect` needs Apple Container and the device token, but no GitHub token or `gh` executable. Broad GitHub credentials stay on the coordinator. The Mac client remains a foreground process; the coordinator can run in the foreground or through the Linux Compose deployment.

While accepting and executing an assignment, and during its cleanup attempt, `connect` prevents automatic idle system sleep. It releases that assertion when the attempt returns, including on failure or cancellation. Recovery acquires it again while cleaning up a recorded assignment. Idle polling and retry backoff do not keep the Mac awake. The display can sleep; closing the lid, explicitly choosing Sleep, and critical-battery shutdown are not prevented.

Once the client has completed any outstanding recovery and is polling, dispatch the existing test:

```sh
gh workflow run runner-test.yml --repo juhokoskela/yieldd --ref main
```

Expect `Local offer created`, `Local credentials issued`, and `Local runner cleaned up` on the coordinator, with no infrastructure bootstrap dispatch. The Mac reports listener progress and guest cleanup. Then stop the idle client, wait at least 30 seconds for its availability to expire, and dispatch again to exercise hosted fallback.

## Delivery and recovery

An offer contains the repository, coordinator identity, runner identity, and fixed Linux ARM64 shape. It contains no executable command. Offers expire after 30 seconds on the server. Unaccepted expired offers can become hosted attempts. Acceptance starts a fresh 30-second window: if credential delivery never reaches the issued phase, expiry or zero demand triggers registration cleanup before another allocation. The scheduler observes expiry on its next demand reconciliation, so expiry does not promise immediate fallback.

The Mac writes a private, durable journal before accepting. The coordinator persists acceptance before registration and possible credential delivery before returning the JIT payload. Credentials are issued at most once; a lost response never triggers a second execution attempt. The Mac validates the runner identity, ephemeral setting, and work directory, then delivers the payload through stdin into its guest. The guest passes it through the runner's JIT environment variable, not process arguments. The pinned runner consumes and removes that variable before starting jobs. This is not isolation from a trusted workload running under the same guest account. The host journal does not contain the JIT payload.

The listener has a five-minute pickup timeout and a fifteen-minute execution timeout. Ctrl+C stops local execution and attempts guest destruction and server acknowledgement. Guest destruction must succeed before the client acknowledges completion. The coordinator then reconciles the registration, refusing to remove a busy runner. A failed job is not a failed listener: GitHub retains the workload's own conclusion.

Transport failures and retryable HTTP responses trigger a five-second retry delay. Before accepting more work, the client destroys any recorded guest and retries acknowledgement. It never retries acceptance or resumes the recorded listener. Restarting `connect` uses the same recovery path. Failed destruction, permanent HTTP errors, and invalid responses stop the client with unresolved recovery state retained. Standalone runner commands refuse to bypass that journal. Empty polls have a one-second client-side delay, and memory admission reports when it cannot advertise capacity.

Restart the coordinator with the same arguments and state directory after a server interruption. Once credentials may have reached a Mac, disconnection and elapsed time do not authorize hosted replacement. An issued assignment without a cleanup acknowledgement blocks all new provisioning, including hosted fallback, until the Mac returns. The coordinator reports this hold. Once cleanup intent is durable, normal reconciliation can finish registration cleanup without another acknowledgement; transient local-cleanup failures retain the lease and retry on subsequent reconciliation. `--recover` cannot bypass an issued local assignment. A stopped idle client does not block hosted fallback after its advertised availability expires.

If the coordinator's original state is permanently lost, restoring it is preferable to abandoning recovery. Otherwise, first stop the old coordinator and manually remove the exact runner registration from the application repository's GitHub settings. Then, on the Mac, use the original server and device ID and the runner name printed in the recovery error:

```sh
.build/yieldd.app/Contents/MacOS/yieldd connect \
  --server http://127.0.0.1:8787 \
  --device-id "$YIELDD_DEVICE_ID" \
  --confirm-registration-removed yieldd-bootstrap-REPLACE-WITH-EXACT-RUNNER-UUID
```

This is an explicit operator assertion that GitHub registration cleanup is complete. It does not remove the registration for you or contact the coordinator. It requires an exact match to the local journal, destroys the guest, clears the journal only after successful destruction, and exits without polling. It needs no device token. Never use it merely to force fallback while the original assignment may still be active elsewhere. If the Mac or its journal is lost, verify guest termination and registration removal separately before repairing server state.

## Validation boundary

Local tests cover authenticated HTTP, response bounds, redirect refusal, signal cancellation, offer expiry, duplicate acceptance, persisted recovery phases, credential handling, and cleanup failures. Backend and guest-script fixtures do not establish real Apple Container JIT pickup. Live local execution, remote HTTPS deployment, and disconnect/reboot recovery still require acceptance testing.
