# Scale Set coordinator prototype

This Go service routes jobs for up to 16 application repositories through one coordinator and one Mac connection. Each repository has its own Linux and optional macOS scale sets. `runs-on: yieldd` targets Linux; `runs-on: yieldd-linux` targets the same scale set when GitHub retains that alias. `runs-on: yieldd-macos` targets macOS. Each platform uses its user-configured fallback target, dispatched through the infrastructure repository, unless that application repository is local-only.

Each repository/platform queue can hold up to 16 assignments. A [connected Mac](../Docs/connected-mac-prototype.md) offers several Linux ARM64 or macOS ARM64 workers, shared across repositories and bounded by its memory budget. macOS is capped at two guests. Paid fallback capacity is configured separately for each queue. Additional demand waits when both local and configured hosted capacity are occupied. An issued local assignment retains only its own worker slot until cleanup is acknowledged. Other slots can keep working, including on the same repository. Idle workers create no guests and reserve no RAM. The Mac connects to the coordinator through its installed login agent or foreground `yieldd connect`.

The coordinator uses [actions/scaleset v0.4.0](https://github.com/actions/scaleset/tree/v0.4.0). It scales from GitHub's assigned-job count, not individual job notifications. GitHub chooses which queued job a runner receives.

## Setup

Use a Linux or macOS coordinator with Go 1.27.4 or newer. Run one coordinator for the configured repositories and infrastructure workflow, with a dedicated private state directory. Do not run another scale-set controller or legacy standalone `yieldd` service against the same repository's label during the experiment.

Before upgrading a coordinator that could save JIT credentials, stop new demand and drain the Macs. Keep the old coordinator serving until issued guests finish, the Macs confirm destruction, and hosted workflows finish. Stop it and use its original binary, configuration, token and journals to recover any remaining assignments. Verify every queue’s lease map is empty before starting the new binary against the same state directory. A journal containing a legacy `jit` field is rejected. If you encounter one, finish recovery with the old binary and preserve the original journals and credentials throughout.

When upgrading from the single-repository version, finish its jobs and recovery with the previous binary and original configuration first. Stop it, keep its state intact, and choose a fresh `--state-dir` for this version. Old `state.json` and `macos/state.json` layouts are rejected, not migrated. Existing GitHub scale sets are discovered by name.

When upgrading from the one-runner-per-queue version, finish all jobs and recovery with the previous coordinator and Mac client first. Stop both before updating them together. Empty multi-repository journals can be reused without changing queue or scale-set identities; active single-assignment journals are rejected rather than migrated. Do not delete unresolved state. The `connect` command and coordinator environment variables are unchanged.

Each selected infrastructure repository must contain the `runner-bootstrap.yml` workflow and the per-bootstrap credential selector on `main`. The coordinator generates names such as `yieldd-bootstrap-01234567-89ab-cdef-0123-456789abcdef`; the workflow reads the corresponding `YIELDD_JIT_0123456789ABCDEF0123456789ABCDEF` secret. The old shared `YIELDD_BOOTSTRAP_JIT` secret is not used.

Provide `GH_TOKEN` through the coordinator's environment. The token needs runner administration access to every application repository, plus workflow dispatch, cancellation, and repository-secret write access in every selected infrastructure repository. Keep it on the server. GitHub App enrollment and token rotation are not implemented in this prototype.

From `Server/`:

```sh
go run . \
  --repositories juhokoskela/GlassEQ,juhokoskela/yieldd,juhokoskela/yieldd-infra,juhokoskela/GlassEQServer \
  --local-only-repositories juhokoskela/yieldd-infra \
  --infrastructure juhokoskela/yieldd-infra \
  --fallback-runner '"ubuntu-24.04"' \
  --device-id "$YIELDD_DEVICE_ID" \
  --client-listen 127.0.0.1:8787 \
  --state-dir /absolute/private/yieldd-state
```

Add `--macos-fallback-runner '"macos-26"'` to enable macOS queues for all repositories. Neither platform has a default fallback provider. Startup requests the `yieldd-linux` alias for each Linux set. If GitHub retains only `yieldd`, startup preserves that identity and warns that workflows must use `runs-on: yieldd`. This applies to saved, discovered, and newly created sets. Missing base labels, unexpected labels, and changed identities are rejected.

Set `--max-fallback-runners 3` to allow up to three active hosted bootstraps in each repository/platform queue. The range is 1–16 and the default is 1. Local capacity remains preferred, and local-only queues never use fallback. Startup logs show the configured `fallback_capacity`. Changing this limit needs no state migration; lowering it blocks new hosted assignments without canceling existing ones. Uncertain dispatches and pending cleanup still occupy capacity.

The limit applies to each queue, not the whole deployment, so raising it can increase hosted costs across repositories and platforms. Dispatched bootstraps are not retired just because demand falls. Canceling queued workloads can leave several bootstraps waiting without a job until their pickup deadlines expire. Their failure conclusions require operator attention after cleanup; the coordinator does not retry those workloads automatically.

Repositories listed in `--local-only-repositories` must also appear in `--repositories` and require a connected device. They wait for local capacity, without registering a runner or uploading credentials while waiting. An expired unaccepted offer returns to the local queue instead of dispatching fallback. Waiting local-only queues receive capacity in arrival order. The infrastructure repository may run its own CI this way, but cannot use itself for fallback. Keep its `runner-bootstrap.yml` on an external disposable provider; ordinary CI jobs may use `yieldd` or `yieldd-macos`.

The fallback can also be a JSON label array, such as `'["self-hosted","linux","disposable"]'`. It must select a disposable host with that platform's OS and a workload-compatible architecture and support the infrastructure action's Node runtime. The provider must permit nested runners. Arbitrary provider labels cannot establish compatibility; the operator owns that choice. A target containing `yieldd`, `yieldd-linux`, or `yieldd-macos` is rejected to avoid routing back to this coordinator.

Use `--repository-routes` to override the infrastructure repository and Linux fallback for selected application repositories. It accepts a JSON array; each entry requires `repository`, `infrastructure`, and `fallback`. The fallback is a label string or array. Repository names are case-insensitive, and each routed repository must appear in `--repositories` and cannot be local-only. Other repositories keep the default flags. The infrastructure override applies to both platforms; macOS keeps the target from `--macos-fallback-runner`. Enable each provider for the infrastructure repository where its bootstrap workflow runs, not just the application repository.

For example, include `SPLCompanyOy/LibreChat` in `--repositories` and add:

```sh
--repository-routes '[{"repository":"SPLCompanyOy/LibreChat","infrastructure":"SPLCompanyOy/yieldd-infra","fallback":"blacksmith-4vcpu-ubuntu-2404-arm"}]'
```

Use trusted workloads and private repositories. The outer bootstrap and nested job share an operating-system account; neither the private HOME nor the reduced environment is a security sandbox. Repository access to the infrastructure workflow and secrets must be restricted accordingly.

The state directory is created with mode `0700`; existing permissive directories are rejected. Each queue stores its identity and runner-keyed assignment map at `queues/owner/repository/linux/state.json` or `queues/owner/repository/macos/state.json`, using lowercase repository names. Reordering the repository list does not change those identities. Files are atomically replaced with mode `0600` and synced to disk. The coordinator keeps JIT credentials in memory for hosted secret upload or local delivery. For local issuance it records the runner ID and possible delivery before replying to the Mac. Keep the directory private, outside version control, on persistent local storage. A deployment-wide ownership lock excludes another process using that root; queue locks also protect individual journals. The locks do not coordinate separate hosts or different state directories.

Startup refuses to omit any saved queue. Before removing a repository or platform, finish its work, stop the Mac and coordinator, run recovery with the original configuration, then archive that queue's directory. An empty queue can adopt a new route in place. With any outstanding lease, keep its original configuration until cleanup is complete.

## Container deployment on Linux

The [Dockerfile](Dockerfile) builds a static binary with Go 1.27.4. Its runtime image contains the coordinator and TLS root certificates, runs as UID/GID `65532`, and needs neither a Docker socket nor privileged mode. The Mac still runs `yieldd connect` natively to manage its containers and VMs.

The [Compose configuration](compose.yaml) targets Docker Engine on Linux. The coordinator uses a bridge network and listens on `0.0.0.0:8787` inside its container. Docker publishes that port only on host `127.0.0.1:8787`. Terminate HTTPS with a reverse proxy on that same Linux host. Do not publish port 8787 on a public interface. For a bare binary, keep `--client-listen 127.0.0.1:8787`. Wildcard binding requires `--allow-non-loopback-client-listen`, supplied by Compose. This explicit opt-in does not detect whether the process is containerized or verify the published port.

Use Docker Engine 28 or newer with the default NAT bridge settings. [Older releases can expose localhost-published ports to the same layer-2 network](https://docs.docker.com/engine/network/port-publishing/). Keep port 8787 closed in the EC2 security group or host ingress firewall too. Do not enable direct routing to the coordinator's bridge.

Before moving from the Mac, let its active assignment finish and verify both client cleanup and coordinator cleanup. Stop the old coordinator before starting this one. Do not migrate with an outstanding lease or connected-client journal, and do not run two coordinators for the same scale set.

Create a private environment file outside the checkout, for example `/etc/yieldd/coordinator.env`, owned by the deploying account with mode `0600`:

```dotenv
GH_TOKEN=REPLACE_WITH_SERVER_GITHUB_TOKEN
YIELDD_CLIENT_TOKEN=REPLACE_WITH_SHARED_DEVICE_TOKEN
YIELDD_DEVICE_ID=REPLACE_WITH_EXISTING_LOWERCASE_DEVICE_UUID
YIELDD_REPOSITORIES=juhokoskela/GlassEQ,juhokoskela/yieldd,juhokoskela/yieldd-infra,juhokoskela/GlassEQServer
YIELDD_LOCAL_ONLY_REPOSITORIES=juhokoskela/yieldd-infra
YIELDD_INFRASTRUCTURE=juhokoskela/yieldd-infra
YIELDD_STATE_VOLUME=yieldd-coordinator-multi-repository-state
YIELDD_FALLBACK_RUNNER='"ubuntu-24.04"'
# Hosted bootstrap limit per repository/platform queue (1–16).
YIELDD_MAX_FALLBACK_RUNNERS=1
# Optional: enable macOS with a user-selected fallback.
YIELDD_MACOS_FALLBACK_RUNNER='"macos-26"'
```

The fallback remains required for the application queues and may instead be a JSON label array. `yieldd-infra` is local-only in this example; the other three repositories retain fallback. Credentials are injected at runtime, never copied into the build context or image. Docker administrators can inspect container environment variables; restrict access to the daemon and the environment file. Avoid printing `docker compose config` with real credentials.

For personal repositories on Avrea and LibreChat on the organization's Blacksmith bootstrap, use these routing values after recovering affected queues with their old configuration:

```dotenv
YIELDD_REPOSITORIES=juhokoskela/GlassEQ,juhokoskela/yieldd,juhokoskela/yieldd-infra,juhokoskela/GlassEQServer,SPLCompanyOy/LibreChat
YIELDD_LOCAL_ONLY_REPOSITORIES=juhokoskela/yieldd-infra
YIELDD_INFRASTRUCTURE=juhokoskela/yieldd-infra
YIELDD_FALLBACK_RUNNER='"avrea-ubuntu-latest-arm-2-vcpu"'
YIELDD_MACOS_FALLBACK_RUNNER='"avrea-macos-26-8-vcpu"'
YIELDD_REPOSITORY_ROUTES='[{"repository":"SPLCompanyOy/LibreChat","infrastructure":"SPLCompanyOy/yieldd-infra","fallback":"blacksmith-4vcpu-ubuntu-2404-arm"}]'
```

Leave `YIELDD_REPOSITORY_ROUTES` unset to use only the default routes. Keep the existing device ID, shared token, local-only list, and state volume. Changing the global Linux fallback affects every non-local-only Linux queue without an override; changing LibreChat's infrastructure affects both of its platform queues. Archive only recovered queue directories, with their backups intact, before starting their new configuration. The Mac's `connect` arguments and binary are unchanged.

This release replaces `--repository` / `YIELDD_REPOSITORY` and the single-repository state layout. Before upgrading an existing deployment, finish local jobs and their cleanup acknowledgements, stop the Mac client, and recover the old coordinator with its original binary, configuration, and volume. Stop the old coordinator before launching the new one. Keep its volume intact and explicitly select a fresh `YIELDD_STATE_VOLUME`, as above. The new version refuses old `state.json` or `macos/state.json` layouts; it does not migrate unresolved leases. Existing GitHub scale sets are discovered by name. Reconnect the Mac to the same HTTPS origin after startup; its arguments and token are unchanged.

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

Compose keeps state in `YIELDD_STATE_VOLUME` (default `yieldd-coordinator-state`), with a private directory owned by UID `65532`. The root filesystem is read-only; only the state volume is writable. It limits the service to one CPU, 512 MiB RAM, and 128 processes/threads. Recreating the container preserves the volume and queue identities. Back it up as sensitive data. Never use `docker compose down --volumes` or prune this volume while recovery obligations remain. Bridge networking removes direct access to the host's loopback namespace; it is not an outbound LAN firewall. Existing host-proxy configurations can keep forwarding to `127.0.0.1:8787` after recreation.

Compose restarts the coordinator unless explicitly stopped and allows 90 seconds for shutdown. Shutdown cancels worker requests, including the upstream listener's message acknowledgements and job acquisition, and cancels device long polls. Device HTTP then drains for up to ten seconds, followed by concurrent session closure within one shared 15-second budget. These network deadlines do not bound stalled filesystem operations. Repeated errors still require operator attention; restarting does not make an ambiguous dispatch safe to repeat. To stop without deleting state:

```sh
docker compose --env-file /etc/yieldd/coordinator.env stop coordinator
```

For explicit recovery, record the exact repository (owner/name), platform (linux or macos), and runner name from the journal. Drain local assignments before stopping the service if their renewals need to continue. Stop the service, load the same configuration into your shell, then run a one-off container against the same volume:

```sh
set -a
. /etc/yieldd/coordinator.env
set +a
docker compose --env-file /etc/yieldd/coordinator.env run --rm coordinator \
  --repositories "$YIELDD_REPOSITORIES" \
  --local-only-repositories "${YIELDD_LOCAL_ONLY_REPOSITORIES:-}" \
  --infrastructure "$YIELDD_INFRASTRUCTURE" \
  --fallback-runner "$YIELDD_FALLBACK_RUNNER" \
  --macos-fallback-runner "${YIELDD_MACOS_FALLBACK_RUNNER:-}" \
  --repository-routes "${YIELDD_REPOSITORY_ROUTES:-}" \
  --device-id "$YIELDD_DEVICE_ID" \
  --state-dir /var/lib/yieldd \
  --recover "$repository/$platform/$runner"
```

As with native execution, `--recover` cannot bypass an issued local assignment awaiting guest destruction. Include both fallback arguments when both platforms are enabled. Start the Mac client to resolve local obligations.

Build and smoke-test the image without GitHub credentials or network access during the smoke test:

```sh
docker build -t local/yieldd-coordinator:dev .
bash test-image.sh
```

## Lifecycle and recovery

For hosted provisioning, the coordinator saves a unique runner name before registration. It uploads the JIT credential to the matching encrypted GitHub secret, then saves the registration ID and dispatch intent together before sending the workflow request. Dispatch inputs contain only the runner name and fallback labels. The request enables [`return_run_details`](https://docs.github.com/en/rest/actions/workflows?apiVersion=2022-11-28#create-a-workflow-dispatch-event), and the service persists the returned run ID. Title-based discovery is reserved for lost responses or a crash before that ID was saved. It never redispatches an uncertain request.

SIGINT, SIGTERM, and SIGHUP stop the coordinator without canceling a running bootstrap. Restart with the same arguments and state directory to resume reconciliation. GitHub continues receiving the workload's logs and result independently of the coordinator.

When demand falls, including to a smaller positive count, the coordinator retires surplus offers and undispatched assignments instead of starting fallback compute for them. Started jobs and dispatched or uncertain bootstraps take priority over idle workers; aggregate demand alone does not establish that their workloads stopped. Issued idle workers take priority over unused offers.

After cleaning up a registered assignment, the coordinator refreshes GitHub's scale-set statistics before acting on a positive listener count. This avoids allocating another runner from a cached count for the job that just finished. GitHub statistics can still lag; they are not a job-specific reservation. Surplus issued idle runners lose startup authorization, but retain their leases and Mac slots until destruction is acknowledged and registration cleanup succeeds. A runner GitHub reports as busy can still renew. Repeated scale-down checks do not retire additional workers just because earlier retirements still await cleanup.

The bootstrap listener has a five-minute pickup deadline, but yieldd imposes no execution deadline after its job-start hook has fired. Configure the workload's `timeout-minutes` as needed. The outer infrastructure workflow uses [GitHub's default six-hour job timeout](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idtimeout-minutes); provider limits still apply. The coordinator does not cancel queued or running bootstraps based on age. A stuck bootstrap retains its lease until GitHub ends it or an operator cancels it, including through `--recover`.

After an accepted or ambiguous dispatch, the coordinator waits for terminal workflow state before deleting credentials or an idle registration. A cancellation conflict triggers a fresh status read. Before any deletion, it persists cleanup intent and the known conclusion; every restart resumes cleanup, never provisioning, for that lease. Cleanup failures retain the lease. The infrastructure workflow supplies host disposal; the coordinator cannot verify a third-party provider's disposal guarantees.

Demand-listener failures reconnect with backoff from five seconds up to one minute. Retries continue until shutdown, including authentication, permissions, and unavailable scale-set failures. Persistent warnings require an operator to check GitHub access and configuration; the coordinator does not replace a saved scale-set identity. While listening is interrupted, the queue rejects unissued acceptance and suspends new offers and hosted provisioning until fresh session statistics arrive. Unissued assignments can be cleaned up; issued runners retain their slots and can still renew and complete. Reconnection keeps the same queue identity and does not replay registration or dispatch requests. SDK response bodies stay out of logs.

Provisioning or bootstrap failures pause new work in the affected repository/platform queue for operator attention. If that queue has already issued local runners, their renewal and completion requests continue until they finish; unused offers are cleaned up. Afterward the queue stops. Journal-write failures stop the queue immediately because its persisted state may be uncertain. Other repository/platform queues keep serving. Unresolved assignments retain their journals and worker slots. Restart with the same configuration to reconcile, or use explicit recovery when required. Startup configuration, journal-validation, and session-creation failures still abort startup. Local cleanup with durable intent retries recognized transient failures after five seconds without needing another demand message or Mac request. It does not rerun the application workflow. On restart, a hosted lease without dispatch intent enters cleanup. The coordinator looks up the exact runner name, verifies its scale set and idle status if present, and removes the registration and the assignment’s secret. It checks fresh demand before creating a replacement with a new name. Confirmed dispatch rejections (HTTP 400, 401, 403, 404, 422, or 429) enter cleanup without searching for a nonexistent workflow. Timeouts, server errors, and malformed success responses remain ambiguous. If discovery finds no matching run, that queue stops with the intent retained; retry reconciliation later without redispatching. If GitHub never exposes a matching run, even recovery retains that obligation: investigate the dispatch before making any manual state change.

A saved workflow ID identifies its bootstrap within the configured infrastructure repository. The coordinator saves that ID from the dispatch response or after verifying a discovered run's generated title and positive ID. Saved-run lookups also require the `runner-bootstrap.yml` workflow path. Once the ID is saved, reconciliation and recovery use that exact ID even if GitHub has not rendered the title. This allows terminal `startup_failure` runs with generic titles to enter normal cleanup and retain their failure conclusions. If no ID was saved and GitHub returns a generic title, discovery cannot identify the run; the dispatch remains unconfirmed and its intent is retained for operator investigation.

A mismatched bootstrap identity or a transient failure reading workflow status pauses provisioning. The coordinator retries verification after five seconds and doubles the delay up to one minute, even after local siblings finish. Device requests continue between attempts. Warnings identify affected runners when the set changes and repeat once a minute for persistent failures. The coordinator never cancels, cleans up, or redispatches an unverified bootstrap. The pause clears when all affected runs can be verified against their leases; journal-write failures and other permanent failures still require operator attention. Diagnostics include the expected and observed run IDs, status, and a generated bootstrap title when present. Missing or unexpected titles and statuses are reported as categories, not arbitrary response text. Explicit `--recover` still fails on an unverified identity rather than claiming recovery succeeded. The queue's single state owner persists lease transitions, rejecting changes to runner identities, known registration and workflow IDs, persisted intent, or recorded job progress.

Known hosted workflow statuses are read concurrently so slow lookups do not accumulate per-assignment delays. The queue owner waits for those reads before validating identities or changing leases. Registration, dispatch, cleanup, and journal writes remain serialized. Normal reconciliation attempts at most one hosted cleanup per pass. Deferred cleanups retain their verified conclusions and durable intent, and resume with a fresh request budget before further status reads or provisioning. Pending cleanup rotates between leases. When an issued local runner keeps a failed queue active, the coordinator waits five seconds before retrying the same hosted cleanup. Other pending cleanups and expired local offers can proceed during that interval. Local renewal and completion requests can run between passes.

If a recorded workflow returns 404, the coordinator first verifies Actions access with a successful workflow-run listing, because 404 can also mask lost repository access. Cleanup also requires the registration API to independently confirm that its runner is absent. The coordinator retains an unknown conclusion rather than claiming success. If the runner still exists, restore workflow access or verify termination and remove that registration before retrying recovery. A missing workflow alone does not prove that execution stopped.

If dispatch fails before the HTTP transport consumes any payload bytes, the coordinator closes the body against late reads and persists cleanup intent. Once the transport has consumed any bytes, a cancellation or connection error remains ambiguous, even if delivery may have failed. It never treats a context error alone as evidence that dispatch did not happen.

Startup errors name the repository and platform. Scale Set API errors state a category but never include SDK response bodies. The SDK does not expose every HTTP failure as a distinct category. An empty HTTP 200 for a saved scale set does not prove the set is gone; the coordinator stops rather than replace a saved identity.

A secret-deletion 404 does not clear the lease by itself. Cleanup verifies that the named secret is absent and that the Secrets API remains accessible. Lost access or inconsistent responses retain the cleanup obligation.

Likewise, a runner-status 404 requires a successful runner listing from the application repository before cleanup can treat the runner as absent. A failed access check cannot establish that the runner is idle.

To cancel and clean up a recorded bootstrap without provisioning another, stop the normal coordinator and repeat its arguments with the exact `--recover "$repository/$platform/$runner"` target:

```sh
go run . \
  --repositories juhokoskela/GlassEQ,juhokoskela/yieldd,juhokoskela/yieldd-infra,juhokoskela/GlassEQServer \
  --local-only-repositories juhokoskela/yieldd-infra \
  --infrastructure juhokoskela/yieldd-infra \
  --fallback-runner '"ubuntu-24.04"' \
  --device-id "$YIELDD_DEVICE_ID" \
  --state-dir /absolute/private/yieldd-state \
  --recover "$repository/$platform/$runner"
```

If setup included `--macos-fallback-runner '"macos-26"'` or `--repository-routes`, include the same values in this recovery command too. Keep the complete repository list, local-only policy, device ID, fallback targets, and state directory unchanged. `--client-listen` is not needed during recovery.

Targeted recovery validates the full deployment inventory and reconciles only the named lease. Set `repository`, `platform`, and `runner` to the recorded values in both examples above. Use `--recover-all` only when intentionally cancelling and cleaning every queue. It does not delete scale sets or cancel original application workflows, and refuses to remove a busy or mismatched runner. An empty queue can adopt new infrastructure, fallback, and local-only routing under its original identity. Finish outstanding leases using their recorded route first. JSON whitespace and equivalent escapes in fallback labels can change while a lease is active. Never delete an active lease to force a retry.

The manual fixed-secret bootstrap experiment has been retired. For old manual runs, finish both workflows, reconcile the exact runner registration and then remove its `YIELDD_BOOTSTRAP_JIT` secret. Managed fallback continues to use the infrastructure repository workflow and a separate secret per assignment.

## Validation status

Local tests exercise the upstream listener callback integration, encrypted HTTP credential delivery, dispatch identity, interrupted provisioning, exclusive state ownership, and cleanup failures. CI runs the Go race detector and vet. These checks do not establish live provider behavior for new configurations.

Multi-repository tests cover shared local admission, independent fallback and runtime failures, queue-specific acceptance and cleanup, autonomous cleanup retries, cached-demand refresh, local-only waiting, restart identities, and rejected state omissions. Listener tests cover shutdown during detached acknowledgement and acquisition calls. The device protocol binds every offer, acceptance, decline, renewal, and completion to a worker slot as well as its queue and runner. Concurrency tests cover independent long polls, multiple local assignments, restart restoration, sibling-safe cleanup, stale-demand refresh, bounded paid fallback, and a provisioning pause while issued runners finish. They also check that failed assignments cannot starve later cleanup, paused queues reject acceptance, and slow fallback reconciliation gives other queues access to idle workers. CI exercises the Swift client against the Go HTTP router without GitHub or VMs. Same-platform VM overlap and demand-statistics freshness on EC2 still require live acceptance.

Manual cross-repository pickup already succeeded with a repository JIT runner: [application run](https://github.com/juhokoskela/yieldd/actions/runs/34688921974) and [infrastructure run](https://github.com/juhokoskela/yieldd-infra/actions/runs/34688923785). That was not a coordinator or Scale Set test.

Live single-repository acceptance on September 17 confirmed automatic hosted pickup, restart reconciliation, and intentional workload failure followed by cleanup. The failure case preserved the application failure while the bootstrap succeeded. Earlier testing also exercised Linux and macOS connected execution and capacity-triggered fallback. Validate each new multi-repository queue with a trusted job and inspect the run conclusion, exact registration, and cleanup state before increasing concurrency.
