# Scale Set coordinator prototype

This foreground Go service provisions fallback compute for one application repository. Application jobs use only `runs-on: yieldd`; the coordinator dispatches a bootstrap in a separate infrastructure repository. The fallback target is required and has no default.

This first slice has capacity for one runner. It does not connect to Macs, report local capacity, or choose between local and hosted compute yet. The existing Swift agent remains standalone.

The coordinator uses [actions/scaleset v0.4.0](https://github.com/actions/scaleset/tree/v0.4.0). It scales from GitHub's assigned-job count, not individual job notifications. GitHub chooses which queued job a runner receives.

## Setup

Use a Linux or macOS coordinator with Go 1.26.3 or newer. Run one coordinator for this repository and infrastructure workflow, with a dedicated private state directory. Do not run another scale-set controller or standalone `yieldd` runner against the same label during the experiment.

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

## Lifecycle and recovery

The service records intent before registration and dispatch. It uploads an encrypted, uniquely named GitHub secret, then clears the local JIT value and records dispatch intent in one write. Dispatch inputs contain only the runner name and fallback labels. The request enables [`return_run_details`](https://docs.github.com/en/rest/actions/workflows?apiVersion=2022-11-28#create-a-workflow-dispatch-event), and the service persists the returned run ID. Title-based discovery is reserved for lost responses or a crash before that ID was saved. It never redispatches an uncertain request.

SIGINT, SIGTERM, and SIGHUP stop the coordinator without canceling a running bootstrap. Restart with the same arguments and state directory to resume reconciliation. GitHub continues receiving the workload's logs and result independently of the coordinator.

The bootstrap supervisor has a 15-minute execution limit. The coordinator requests cancellation after 25 minutes from workflow creation, including time spent queued for fallback capacity. It compares GitHub's `created_at` with the response's `Date` header, so host clock changes do not alter the deadline. Missing or inconsistent timestamps stop normal reconciliation; `--recover` can still request cancellation. After an accepted or ambiguous dispatch, it waits for terminal workflow state before deleting credentials or an idle registration. A cancellation conflict triggers a fresh status read. Before any deletion, it persists cleanup intent and the known conclusion; every restart resumes cleanup, never provisioning, for that lease. Cleanup failures retain the lease. The infrastructure workflow supplies host disposal; the coordinator cannot verify a third-party provider's disposal guarantees.

An API or bootstrap failure stops this first version for operator attention. It does not rerun the application workflow. A missing registration response requires explicit recovery. Confirmed dispatch rejections (HTTP 400, 401, 403, 404, 422, or 429) enter cleanup without searching for a nonexistent workflow. Timeouts, server errors, and malformed success responses remain ambiguous. If discovery finds no matching run, reconciliation stops with the intent retained; retry reconciliation later without redispatching. If GitHub never exposes a matching run, even recovery retains that obligation: investigate the dispatch before making any manual state change.

If a recorded workflow returns 404, cleanup requires the registration API to independently confirm that its runner is absent. The coordinator retains an unknown conclusion rather than claiming success. If the runner still exists, restore workflow access or verify termination and remove that registration before retrying recovery. A missing workflow alone does not prove that execution stopped.

If dispatch fails before the HTTP transport consumes any payload bytes, the coordinator closes the body against late reads and persists cleanup intent. Once the transport has consumed any bytes, a cancellation or connection error remains ambiguous, even if delivery may have failed. It never treats a context error alone as evidence that dispatch did not happen.

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

Local tests exercise the upstream listener callback integration, encrypted HTTP credential delivery, dispatch identity, interrupted provisioning, exclusive state ownership, and cleanup failures. CI runs the Go race detector and vet. These checks do not establish live Scale Set pickup or GitHub permission compatibility.

Manual cross-repository pickup already succeeded with a repository JIT runner: [application run](https://github.com/juhokoskela/yieldd/actions/runs/34688921974) and [infrastructure run](https://github.com/juhokoskela/yieldd-infra/actions/runs/34688923785). That was not a coordinator or Scale Set test.

After deploying the paired infrastructure workflow, the next acceptance check is one ordinary `runs-on: yieldd` job automatically provisioned by this service, followed by restart, failure, cancellation, and no-pickup cases. Run only one trusted job at a time and inspect both run conclusions, the exact registration, and the per-bootstrap secret after cleanup.
