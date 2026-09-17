# Scale Set coordinator prototype

This foreground Go service provisions fallback compute for one application repository. Application jobs use only `runs-on: yieldd`; the coordinator dispatches a bootstrap in a separate infrastructure repository. The fallback target is required and has no default.

This prototype has capacity for one runner. An optional [connected Mac](../Docs/connected-mac-prototype.md) can supply that slot with an on-demand Linux ARM64 container. Otherwise, the coordinator provisions the configured fallback. An issued local assignment awaiting the Mac's cleanup acknowledgement holds the only slot, blocking hosted fallback too. An idle disconnected Mac does not hold the slot after availability expires. The installed Swift agent remains standalone; connected mode uses the foreground `yieldd connect` command.

The coordinator uses [actions/scaleset v0.4.0](https://github.com/actions/scaleset/tree/v0.4.0). It scales from GitHub's assigned-job count, not individual job notifications. GitHub chooses which queued job a runner receives.

## Setup

Use a Linux or macOS coordinator with Go 1.27.1 or newer. Run one coordinator for this repository and infrastructure workflow, with a dedicated private state directory. Do not run another scale-set controller or standalone `yieldd` runner against the same label during the experiment.

The infrastructure repository must contain the `runner-bootstrap.yml` workflow and the per-bootstrap credential selector on `main`. The coordinator generates names such as `yieldd-bootstrap-01234567-89ab-cdef-0123-456789abcdef`; the workflow reads the corresponding `YIELDD_JIT_0123456789ABCDEF0123456789ABCDEF` secret. The old shared `YIELDD_BOOTSTRAP_JIT` secret is not used.

Provide `GH_TOKEN` through the coordinator's environment. The token needs runner administration access to the application repository, plus workflow dispatch, cancellation, and repository-secret write access in the infrastructure repository. Keep it on the server. GitHub App enrollment and token rotation are not implemented in this prototype.

From `Server/`:

```sh
go run . \
  --repository juhokoskela/yieldd \
  --infrastructure juhokoskela/yieldd-infra \
  --fallback-runner '"ubuntu-24.04"' \
  --state-dir /absolute/private/yieldd-state
```

The fallback can also be a JSON label array, such as `'["self-hosted","linux","disposable"]'`. It must select a disposable Linux or macOS host with the workload's OS and architecture and support the infrastructure action's Node runtime. The provider must permit nested runners. A target containing `yieldd` is rejected to avoid routing back to this coordinator.

Use trusted workloads and private repositories. The outer bootstrap and nested job share an operating-system account; neither the private HOME nor the reduced environment is a security sandbox. Repository access to the infrastructure workflow and secrets must be restricted accordingly.

The state directory is created with mode `0700`; existing permissive directories are rejected. `state.json` is atomically replaced with mode `0600` and synced to disk. It temporarily contains JIT credentials until their encrypted upload succeeds. Keep the directory private, outside version control, on persistent local storage. One process holds its ownership lock. The lock does not coordinate separate hosts or different state directories.

## Container deployment on Linux

The [Dockerfile](Dockerfile) builds a static binary with Go 1.27.1. Its runtime image contains the coordinator and TLS root certificates, runs as UID/GID `65532`, and needs neither a Docker socket nor privileged mode. The Mac still runs `yieldd connect` natively to manage Apple Container guests.

The [Compose configuration](compose.yaml) targets Docker Engine on Linux. It uses [host networking](https://docs.docker.com/engine/network/drivers/host/) so the device API can keep its loopback-only binding at `127.0.0.1:8787`. Terminate HTTPS with a reverse proxy on that same Linux host. Do not expose port 8787 directly or assume this networking arrangement works unchanged on macOS.

Before moving from the Mac, let its active assignment finish and verify both client cleanup and coordinator cleanup. Stop the old coordinator before starting this one. Do not migrate with an outstanding lease or connected-client journal, and do not run two coordinators for the same scale set.

Create a private environment file outside the checkout, for example `/etc/yieldd/coordinator.env`, owned by the deploying account with mode `0600`:

```dotenv
GH_TOKEN=REPLACE_WITH_SERVER_GITHUB_TOKEN
YIELDD_CLIENT_TOKEN=REPLACE_WITH_SHARED_DEVICE_TOKEN
YIELDD_DEVICE_ID=REPLACE_WITH_EXISTING_LOWERCASE_DEVICE_UUID
YIELDD_REPOSITORY=juhokoskela/yieldd
YIELDD_INFRASTRUCTURE=juhokoskela/yieldd-infra
YIELDD_FALLBACK_RUNNER='"ubuntu-24.04"'
```

The fallback remains required and may instead be a JSON label array. Credentials are injected at runtime, never copied into the build context or image. Docker administrators can inspect container environment variables; restrict access to the daemon and the environment file. Avoid printing `docker compose config` with real credentials.

From `Server/` on the Linux host:

```sh
docker compose --env-file /etc/yieldd/coordinator.env up -d --build
docker compose --env-file /etc/yieldd/coordinator.env logs -f coordinator
```

Configure the host's HTTPS proxy to forward `/v1/` to `http://127.0.0.1:8787`, preserve the Authorization header, allow 20-second long polls and 60-second requests, and disable caching and credential/body logging. For example, a host-installed [Caddy reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) can serve a domain pointing at this server:

```caddyfile
yieldd.example.com {
    reverse_proxy /v1/* 127.0.0.1:8787
}
```

Use your actual domain with a publicly trusted certificate. Then start the Mac client with its existing device ID and shared token:

```sh
.build/yieldd.app/Contents/MacOS/yieldd connect \
  --server https://yieldd.example.com \
  --device-id "$YIELDD_DEVICE_ID"
```

Compose keeps state in the named volume `yieldd-coordinator-state`, with a private directory owned by UID `65532`. The root filesystem is read-only; only the state volume is writable. Recreating the container preserves the volume and coordinator identity. Back it up as sensitive data. Never use `docker compose down --volumes` or prune this volume while recovery obligations remain. Host networking is shared with other host processes, not an additional network isolation boundary.

Compose restarts the coordinator unless explicitly stopped and allows 90 seconds for shutdown. Repeated errors still require operator attention; restarting does not make an ambiguous dispatch safe to repeat. To stop without deleting state:

```sh
docker compose --env-file /etc/yieldd/coordinator.env stop coordinator
```

For explicit recovery, stop the service first, load the same configuration into your shell, then run a one-off container against the same volume:

```sh
set -a
. /etc/yieldd/coordinator.env
set +a
docker compose --env-file /etc/yieldd/coordinator.env run --rm coordinator \
  --repository "$YIELDD_REPOSITORY" \
  --infrastructure "$YIELDD_INFRASTRUCTURE" \
  --fallback-runner "$YIELDD_FALLBACK_RUNNER" \
  --device-id "$YIELDD_DEVICE_ID" \
  --state-dir /var/lib/yieldd \
  --recover
```

As with native execution, `--recover` cannot bypass an issued local assignment awaiting guest destruction. Start the Mac client to resolve that obligation.

Build and smoke-test the image without GitHub credentials or network access during the smoke test:

```sh
docker build -t local/yieldd-coordinator:dev .
bash test-image.sh
```

## Lifecycle and recovery

The service records intent before registration and dispatch. It uploads an encrypted, uniquely named GitHub secret, then clears the local JIT value and records dispatch intent in one write. Dispatch inputs contain only the runner name and fallback labels. The request enables [`return_run_details`](https://docs.github.com/en/rest/actions/workflows?apiVersion=2022-11-28#create-a-workflow-dispatch-event), and the service persists the returned run ID. Title-based discovery is reserved for lost responses or a crash before that ID was saved. It never redispatches an uncertain request.

SIGINT, SIGTERM, and SIGHUP stop the coordinator without canceling a running bootstrap. Restart with the same arguments and state directory to resume reconciliation. GitHub continues receiving the workload's logs and result independently of the coordinator.

If demand has fallen to zero on restart, a lease that has not reached dispatch intent enters cleanup instead of starting fallback compute. A dispatched or uncertain attempt still follows reconciliation; zero demand alone does not establish that its workload stopped.

The bootstrap listener has a five-minute pickup deadline, but yieldd imposes no execution deadline after its job-start hook has fired. Configure the workload's `timeout-minutes` as needed. The outer infrastructure workflow uses [GitHub's default six-hour job timeout](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idtimeout-minutes); provider limits still apply. The coordinator does not cancel queued or running bootstraps based on age. A stuck bootstrap retains its lease until GitHub ends it or an operator cancels it, including through `--recover`.

After an accepted or ambiguous dispatch, the coordinator waits for terminal workflow state before deleting credentials or an idle registration. A cancellation conflict triggers a fresh status read. Before any deletion, it persists cleanup intent and the known conclusion; every restart resumes cleanup, never provisioning, for that lease. Cleanup failures retain the lease. The infrastructure workflow supplies host disposal; the coordinator cannot verify a third-party provider's disposal guarantees.

An API or bootstrap failure generally stops this first version for operator attention. Local cleanup with durable intent retries recognized transient failures on subsequent reconciliation. It does not rerun the application workflow. A missing registration response requires explicit recovery. Confirmed dispatch rejections (HTTP 400, 401, 403, 404, 422, or 429) enter cleanup without searching for a nonexistent workflow. Timeouts, server errors, and malformed success responses remain ambiguous. If discovery finds no matching run, reconciliation stops with the intent retained; retry reconciliation later without redispatching. If GitHub never exposes a matching run, even recovery retains that obligation: investigate the dispatch before making any manual state change.

If a recorded workflow returns 404, the coordinator first verifies Actions access with a successful workflow-run listing, because 404 can also mask lost repository access. Cleanup also requires the registration API to independently confirm that its runner is absent. The coordinator retains an unknown conclusion rather than claiming success. If the runner still exists, restore workflow access or verify termination and remove that registration before retrying recovery. A missing workflow alone does not prove that execution stopped.

If dispatch fails before the HTTP transport consumes any payload bytes, the coordinator closes the body against late reads and persists cleanup intent. Once the transport has consumed any bytes, a cancellation or connection error remains ambiguous, even if delivery may have failed. It never treats a context error alone as evidence that dispatch did not happen.

A secret-deletion 404 does not clear the lease by itself. Cleanup verifies that the named secret is absent and that the Secrets API remains accessible. Lost access or inconsistent responses retain the cleanup obligation.

Likewise, a runner-status 404 requires a successful runner listing from the application repository before cleanup can treat the runner as absent. A failed access check cannot establish that the runner is idle.

To cancel and clean up a recorded bootstrap without provisioning another, stop the normal coordinator and repeat its arguments with `--recover`:

```sh
go run . \
  --repository juhokoskela/yieldd \
  --infrastructure juhokoskela/yieldd-infra \
  --fallback-runner '"ubuntu-24.04"' \
  --state-dir /absolute/private/yieldd-state \
  --recover
```

Recovery does not delete the scale set or cancel the original application workflow. It refuses to remove a busy or mismatched runner. Changing configuration requires recovering the old state with its original arguments and choosing a separate state directory. Never delete an active lease to force a retry.

This revision removes the prototype's `secret_stored` state field. Recover any outstanding lease with the previous binary before upgrading. Files containing the removed field are rejected rather than silently reinterpreted; a cleared state file remains compatible.

## Validation status

Local tests exercise the upstream listener callback integration, encrypted HTTP credential delivery, dispatch identity, interrupted provisioning, exclusive state ownership, and cleanup failures. CI runs the Go race detector and vet. These checks do not establish live provider behavior for new configurations.

Manual cross-repository pickup already succeeded with a repository JIT runner: [application run](https://github.com/juhokoskela/yieldd/actions/runs/34688921974) and [infrastructure run](https://github.com/juhokoskela/yieldd-infra/actions/runs/34688923785). That was not a coordinator or Scale Set test.

Live coordinator acceptance on September 17 confirmed automatic hosted pickup, restart reconciliation, and intentional workload failure followed by cleanup. The failure case preserved the application failure while the bootstrap succeeded. Cancellation and no-pickup cases remain separate checks. Connected local execution still needs live acceptance. Run only one trusted job at a time and inspect the run conclusions, exact registration, and cleanup state.
