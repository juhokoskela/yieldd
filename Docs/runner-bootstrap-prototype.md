# Nested runner bootstrap prototype

This experiment keeps the workload on `runs-on: yieldd`. A separate, manually dispatched bootstrap workflow obtains a disposable machine using your chosen fallback label, then runs one ephemeral Actions listener on it. The original workflow retains its job logs and conclusion. A successful bootstrap does not mean the workload succeeded.

The prototype uses repository-scoped JIT configuration, not a scale set. It tests whether a runner inside another workflow job can execute the original job correctly. The always-on server, capacity-based dispatch, scale-set registration, and reconciliation come afterward if this boundary passes live testing. No automatic fallback or retry is implemented.

## Safety and prerequisites

- Use a private test repository with trusted workflows and contributors. Stop other `yieldd` runners and ensure no unrelated job targets `yieldd` during this experiment. A generic label cannot reserve a specific job.
- Use a disposable Linux or macOS fallback runner on x64 or ARM64, with Bash, curl, tar, and the Actions runner's native dependencies. There is no default provider. Do not choose `yieldd` as the fallback target, which would make the bootstrap wait for itself.
- The fallback must allow running a nested listener. Check the provider's restrictions and billing. This experiment has not established support from GitHub or another provider.
- Bootstrap and workload run under the same operating-system account. A fresh HOME and minimal environment prevent accidental inheritance, not access to the outer runner's filesystem, processes, credentials, or network. This is not a sandbox for untrusted workloads.
- A 15-minute supervisor deadline covers download and listener execution; the bootstrap job has a 20-minute limit. Cancellation signals the owned process group, then escalates after five seconds to leave time for cleanup before GitHub's outer cancellation deadline. Processes that deliberately leave that group and force-killed bootstrap processes rely on host disposal for cleanup.
- The supervisor deletes its private runner files but cannot deregister an abandoned runner: it has no GitHub admin credential. Inspect and remove any surviving registration after interruption or failed startup.

The bootstrap downloads runner 2.337.0 and verifies its pinned platform-specific SHA-256. It passes the JIT configuration through `ACTIONS_RUNNER_INPUT_JITCONFIG`, which that runner version consumes and removes before job execution. Listener exit status 2 triggers a retry after five seconds within the original 15-minute deadline. Other nonzero statuses stop the bootstrap. No broad GitHub credential is sent to the bootstrap. Do not publish encoded JIT credentials as workflow inputs, artifacts, command arguments, or logs.

## Prepare and dispatch

After both workflows are on the default branch, build a fresh configuration locally with an authenticated `gh` CLI. This creates a runner registration and stores its single-use configuration as a repository secret. Choose a real fallback target available to the repository; it may be a JSON label string or label array.

```sh
set -o pipefail
repository=juhokoskela/yieldd
runner_name="yieldd-bootstrap-$(uuidgen | tr '[:upper:]' '[:lower:]')"
fallback_runner='"YOUR_DISPOSABLE_FALLBACK_LABEL"'

gh api --method POST "repos/$repository/actions/runners/generate-jitconfig" \
  -f "name=$runner_name" -F runner_group_id=1 \
  -f 'labels[]=yieldd' -f work_folder=_work \
  --jq .encoded_jit_config | \
gh secret set YIELDD_BOOTSTRAP_JIT --repo "$repository"
```

Runner group 1 is the default group; select your applicable group if it differs. Only prepare one experiment at a time. Do not overwrite the secret while another bootstrap is queued or running. The expected runner name rejects accidental reuse of a different configuration; workflow reruns are rejected because JIT credentials are single-use.

After credential creation succeeds, dispatch the original workload and then its bootstrap:

```sh
gh workflow run runner-bootstrap-test.yml --repo "$repository" --ref main \
  -f "runner-name=$runner_name" -f outcome=success && \
gh workflow run runner-bootstrap.yml --repo "$repository" --ref main \
  -f "runner-name=$runner_name" -f "fallback-runner=$fallback_runner"
```

Record both run URLs. If bootstrap dispatch fails, cancel the queued workload explicitly. Never dispatch replacement execution based only on a timeout.

## Acceptance checks

1. Success: the workload reports the expected nested runner name and its own workflow/run identity. Checkout succeeds, and writing to `GITHUB_ENV` affects the next original-job step. The original job summary belongs to the workload, not the bootstrap. No JIT input or bootstrap token is inherited by job steps. Both workflows finish, and the ephemeral registration disappears.
2. Job failure: create a new configuration and dispatch with `outcome=failure`. The original workload must fail; the bootstrap may succeed because its listener completed normally. No second workload is launched.
3. Workload cancellation: use a new configuration with `outcome=cancellation`. Cancel the original workload after its sleep message. Confirm listener exit, bootstrap cleanup, and runner deregistration.
4. Bootstrap cancellation: cancel a fresh bootstrap while the workload is running. Confirm that it stops its listener and descendants. Inspect the original job separately; cancel it if necessary and remove any abandoned registration.
5. No pickup: start a fresh bootstrap without a workload. It must fail at its deadline and clean up local files. Inspect the registration rather than assuming timeout proves deregistration.

After each experiment, delete the consumed secret and inspect registrations:

```sh
gh secret delete YIELDD_BOOTSTRAP_JIT --repo "$repository"
gh api --paginate "repos/$repository/actions/runners" \
  --jq '.runners[] | {id, name, status, busy}'
```

If the exact generated runner remains, first confirm the bootstrap has stopped and the workload is no longer running. Remove only its numeric ID with `gh api --method DELETE "repos/$repository/actions/runners/RUNNER_ID"`. Also cancel any queued smoke run left behind.

Local checks: `node --test .github/actions/bootstrap-runner/index.test.cjs`. These cover configuration validation, the child environment, checksum verification, process failures, and cancellation escalation. They do not prove nested GitHub execution, host disposal, billing, or scale-set compatibility.

References: [repository JIT configuration](https://docs.github.com/en/rest/actions/self-hosted-runners#create-configuration-for-a-just-in-time-runner-for-a-repository), [runner environment argument consumption](https://github.com/actions/runner/blob/v2.337.0/src/Runner.Listener/CommandSettings.cs), and [Scale Set Client](https://github.com/actions/scaleset).
