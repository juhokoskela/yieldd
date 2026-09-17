# One connected Mac

This prototype adds one Linux ARM64 container slot to the coordinator. Application jobs still use `runs-on: yieldd`. An idle Mac creates no guest. A pending authenticated poll advertises one slot after local memory admission succeeds; accepted work uses the existing 4-vCPU, 12-GiB Linux machine configuration.

There is still only one active runner across local and hosted execution. This is not yet a multi-device scheduler, macOS guest client, or installed connected agent. Ubuntu's default hosted runner is x64, so workloads must support both architectures or select an ARM64 fallback.

## Setup

Use the same lowercase UUID in `YIELDD_DEVICE_ID` and the same random token in `YIELDD_CLIENT_TOKEN` in both terminals. Generate the UUID with `uuidgen | tr '[:upper:]' '[:lower:]'` and a token with `openssl rand -hex 32`. Supply the token through the environment, not a command argument or committed file. The coordinator binds this token to that one device; do not share it with another Mac. Enrollment and token rotation are manual in this prototype.

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

For a different coordinator host, replace the server with its HTTPS origin. `connect` needs Apple Container and the device token, but no GitHub token or `gh` executable. Broad GitHub credentials stay on the coordinator. Both sides must remain foreground processes for this slice.

After the client reports readiness, dispatch the existing test:

```sh
gh workflow run runner-test.yml --repo juhokoskela/yieldd --ref main
```

Expect `Local offer created`, `Local credentials issued`, and `Local runner cleaned up` on the coordinator, with no infrastructure bootstrap dispatch. The Mac reports listener progress and guest cleanup. Then stop the idle client, wait at least 30 seconds for its availability to expire, and dispatch again to exercise hosted fallback.

## Delivery and recovery

An offer contains the repository, coordinator identity, runner identity, and fixed Linux ARM64 shape. It contains no executable command. Offers expire after 30 seconds on the server. Unaccepted expired offers can become hosted attempts. The scheduler observes expiry on its next demand reconciliation, so expiry does not promise immediate fallback.

The Mac writes a private, durable journal before accepting. The coordinator persists acceptance before registration and possible credential delivery before returning the JIT payload. Credentials are issued at most once; a lost response never triggers a second execution attempt. The Mac validates the runner identity, ephemeral setting, and work directory, then delivers the payload through stdin into its guest. The guest passes it through the runner's JIT environment variable, not process arguments. The host journal does not contain the JIT payload.

The listener has a five-minute pickup timeout and a fifteen-minute execution timeout. Ctrl+C stops local execution and attempts guest destruction and server acknowledgement. Guest destruction must succeed before the client acknowledges completion. The coordinator then reconciles the registration, refusing to remove a busy runner. A failed job is not a failed listener: GitHub retains the workload's own conclusion.

Restart `connect` with the original server, device ID, and local state to recover. It destroys any recorded guest and retries acknowledgement before polling for new work. It never resumes the recorded listener. Failed destruction or acknowledgement keeps the journal. Standalone runner commands refuse to bypass that journal. Idle transport failures retry; active-assignment errors stop the client for operator attention.

Restart the coordinator with the same arguments and state directory after a server interruption. Once credentials may have reached a Mac, disconnection and elapsed time do not authorize hosted replacement. The server retains the reservation until the Mac confirms guest destruction and registration cleanup succeeds. `--recover` cannot bypass an issued local assignment. If the Mac or either journal is permanently lost, operator reconciliation is required; do not delete state to force failover.

## Validation boundary

Local tests cover authenticated HTTP, response bounds, redirect refusal, signal cancellation, offer expiry, duplicate acceptance, persisted recovery phases, credential handling, and cleanup failures. Backend and guest-script fixtures do not establish real Apple Container JIT pickup. Live local execution, remote HTTPS deployment, and disconnect/reboot recovery still require acceptance testing.
