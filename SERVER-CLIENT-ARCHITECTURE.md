# Server-client architecture

This document records a possible connected mode for `yieldd`. It is not implemented. The foreground service and installable local agent remain standalone and do not require a server.

## Responsibilities

GitHub remains the source of truth for workflow jobs and their state. The server decides where eligible jobs should run, while each Mac owns its local runner machines and cleanup.

The server should:

- Receive queued and completed job events from GitHub.
- Enforce repository access rules.
- Track connected Macs and their available runner slots.
- Reserve capacity and assign jobs.
- Reassign expired offers and choose the configured hosted fallback.
- Request just-in-time runner configuration from GitHub.

The Mac client should:

- Report availability and capacity.
- Accept or reject short-lived assignments.
- Create the runner machine, execute one job, and clean it up.
- Preserve enough local state to recover after a crash or reboot.

The server sends declarative assignments, never arbitrary shell commands. An assignment identifies the repository, GitHub job, runner configuration, resource shape, and expiry. GitHub sends the actual workflow to the runner.

## Repository authorization

A GitHub App installation defines the outer boundary. The app may have access to selected repositories or every repository in an account or organization.

Within that boundary, the user chooses one of two policies:

- Selected repositories: only an explicit allowlist may use `yieldd`.
- All repositories: every repository currently accessible to that GitHub App installation may use `yieldd`.

"All repositories" never means every public repository on GitHub. If the GitHub App installation itself is restricted, it means all repositories within that restricted set.

Repository policy belongs on the server. Connected Macs should not carry the authoritative repository list or broad GitHub credentials. This lets the server manage one queue across several Macs and update repository access without reconfiguring every client.

## Client connection

The Mac initiates all network traffic. It holds an authenticated HTTPS long-poll request to a fixed server hostname over TCP port 443. The server answers that request when an assignment is available, and the client reconnects after a response or timeout.

This requires no inbound port, local firewall exception, port forwarding, or peer-to-peer connection. HTTPS long polling is the first choice because it works through more corporate proxies than WebSocket upgrades. A persistent WebSocket is unnecessary for the initial protocol.

The active request also acts as an availability signal. If the Mac sleeps, loses its network connection, or exits, its connection disappears and its server-side availability lease expires. The server must not assume that it can wake a Mac.

## Assignment flow

1. GitHub reports that an eligible workflow job is queued.
2. The server records the job and checks its repository policy.
3. The scheduler chooses an online Mac with an available slot and creates an expiring assignment.
4. The Mac accepts the assignment before its deadline. A rejected or expired assignment returns to the queue.
5. The server requests an encoded just-in-time runner configuration from GitHub and gives it to the assigned Mac.
6. The Mac creates the guest machine and starts the runner with that configuration.
7. The runner connects directly to GitHub, receives the workflow, and reports logs and job status to GitHub.
8. The Mac cleans up the runner and machine, then reports the slot available again.
9. GitHub events and periodic reconciliation confirm the final job state.

The server should hold the GitHub App credentials. The Mac receives only the assignment-specific runner configuration and never the app private key or a long-lived GitHub token.

GitHub documents both [just-in-time runner configuration](https://docs.github.com/en/rest/actions/self-hosted-runners) and an [HTTPS long-poll listener architecture](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller) for runner scale sets. The exact integration used by `yieldd` still needs a focused prototype.

## Queue semantics

The server stores a scheduling view of GitHub's queue, not workflow source code, logs, or command payloads. Records should be keyed by GitHub job identity and processed idempotently because webhook deliveries may be repeated.

At minimum, the scheduler must enforce:

- One active assignment for a job.
- One job for each available runner slot.
- Repository authorization before every assignment.
- Expiring offers and reservations.
- A bounded wait before hosted fallback.

Fairness, priorities, per-repository concurrency limits, and separate device pools can be added after the basic queue has real usage data.

## Hosted fallback

An unavailable Mac must not leave a job waiting for GitHub's self-hosted-runner timeout. The server should choose the hosted backend when no eligible Mac is online, all slots remain busy past the configured wait, or repeated assignments fail.

GitHub does not treat `runs-on: yieldd` as an automatic alternative to a hosted runner. The intended interface keeps that selector unchanged: yieldd supplies compute behind it instead of rewriting the queued job's target.

The proposed label-based fallback dispatches a separate bootstrap workflow on a user-configured runner target. That job starts an ephemeral yieldd listener on the provided machine, which can then receive the original queued workload. The [nested runner prototype](Docs/runner-bootstrap-prototype.md) tests this boundary using repository JIT configuration before adding scale sets or server-driven dispatch. The fallback label has no default and may target GitHub-hosted compute or another provider that permits this arrangement.

This is not yet a verified deployment model. The prototype must establish nested job context, credential handling, cancellation, and cleanup on disposable hosts. The server will also need bounded provisioning, durable bootstrap identities, and reconciliation between original jobs, registrations, and bootstrap runs. Missing pickup acknowledgement must never trigger duplicate workload execution.

## Standalone and connected modes

Standalone mode keeps the current model:

```sh
yieldd serve OWNER/REPOSITORY [OWNER/REPOSITORY ...]
```

The repository list is local, and each argument creates one slot.

The installed local agent persists this same repository list and runs the same pool through a per-user LaunchAgent. It is an unattended form of standalone mode, not the beginning of the server protocol.

Connected mode moves repository authorization and scheduling to the server. Local configuration should then contain device identity, capacity policy, and server connection details rather than an authoritative repository list.

Both modes should use the same local runner-session, cleanup, and recovery code. The standalone LaunchAgent's repository list is local-only and does not define the connected-client configuration.

## Open questions

- Which GitHub event or runner-scale-set interface should feed the queue?
- How should a workflow select between `yieldd` and its hosted fallback?
- How should device enrollment and credential rotation work?
- Which queue controls are necessary beyond a bounded FIFO policy?
- How much status and diagnostic data should Macs report to the server?

These questions belong in later prototypes. They do not block the installable standalone LaunchAgent milestone.
