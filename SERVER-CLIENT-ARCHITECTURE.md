# Server-client architecture

This document records the direction for connected mode. The [Go coordinator prototype](Server/README.md) implements one-repository Scale Set demand and hosted provisioning, pending live acceptance. Mac connections, local capacity reporting, and local-first routing are not implemented. The foreground service and installable local agent remain standalone and do not require a server.

## Responsibilities

GitHub remains the source of truth for workflow jobs and their state. The server decides where eligible jobs should run, while each Mac owns its local runner machines and cleanup.

The server should:

- Listen to GitHub Scale Set demand and job lifecycle events.
- Enforce repository access rules.
- Track connected Macs and their available runner slots.
- Reserve capacity and issue runner provisioning offers.
- Reassign expired offers and choose the configured hosted fallback.
- Request just-in-time runner configuration from GitHub.

The Mac client should:

- Report availability and capacity.
- Accept or reject short-lived assignments.
- Create the runner machine, execute one job, and clean it up.
- Preserve enough local state to recover after a crash or reboot.

The server sends declarative provisioning offers, never arbitrary shell commands. An offer identifies the repository, scale set, runner configuration, resource shape, and expiry. It does not bind the runner to an individual GitHub job. GitHub sends the actual workflow to an eligible idle runner.

## Repository authorization

The intended authorization boundary is a GitHub App installation. The first coordinator prototype instead uses a server-only `GH_TOKEN` and one explicitly configured repository. App enrollment remains future work. The app may eventually have access to selected repositories or every repository in an account or organization.

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

1. The Scale Set listener acquires available demand and reports the assigned-job count.
2. The server compares that demand with recorded provisioning and running capacity within its repository policy.
3. The scheduler chooses an online Mac with an available slot and creates an expiring provisioning offer.
4. The Mac accepts before the offer's deadline. A rejected or expired offer releases the reservation.
5. The server requests an encoded just-in-time runner configuration from GitHub and gives it to the assigned Mac.
6. The Mac creates the guest machine and starts the runner with that configuration.
7. The runner connects directly to GitHub, receives the workflow, and reports logs and job status to GitHub.
8. The Mac cleans up the runner and machine, then reports the slot available again.
9. GitHub events and periodic reconciliation confirm the final job state.

The server should hold the GitHub App credentials. The Mac receives only the assignment-specific runner configuration and never the app private key or a long-lived GitHub token.

The first server slice uses the official [Runner Scale Set Client](https://github.com/actions/scaleset/tree/v0.4.0) for long polling and scale-set JIT configuration. Until Mac clients exist, it provisions every accepted unit of demand on the configured fallback.

## Queue semantics

GitHub owns job assignment. The server persists provisioning identities and cleanup obligations, not a second queue of workflow commands. Job lifecycle events aid reconciliation; they are not a promise that a particular runner will receive a particular job.

At minimum, the scheduler must enforce:

- One active provisioning owner for each reserved unit of capacity.
- One job for each available runner slot.
- Repository authorization before every assignment.
- Expiring offers and reservations.
- A bounded wait before hosted fallback.

Fairness, priorities, per-repository concurrency limits, and separate device pools can be added after the basic queue has real usage data.

## Hosted fallback

An unavailable Mac must not leave a job waiting for GitHub's self-hosted-runner timeout. The server should choose the hosted backend when no eligible Mac is online, all slots remain busy past the configured wait, or repeated assignments fail.

GitHub does not treat `runs-on: yieldd` as an automatic alternative to a hosted runner. The intended interface keeps that selector unchanged: yieldd supplies compute behind it instead of rewriting the queued job's target.

The label-based fallback dispatches a bootstrap workflow in `yieldd-infra` on a user-configured runner target. That job starts an ephemeral yieldd listener on the provided machine, which can receive the original queued workload. Application repositories need no routing actions or bootstrap workflows. The fallback label has no default and may target GitHub-hosted compute or another provider that permits this arrangement.

Manual repository-JIT experiments established happy-path cross-repository execution on Ubuntu, plus same-repository failure, cancellation, and no-pickup behavior. The coordinator now records intent before side effects, uses per-bootstrap secrets, bounds provisioning, and reconciles registrations and bootstrap runs. Automatic Scale Set execution remains unverified. Missing pickup acknowledgement must never trigger replacement execution without reconciling the original attempt.

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

- How should device enrollment and credential rotation work?
- How should a lost Mac's provisioning and GitHub runner state be reconciled before fallback?
- Which fairness and admission controls are needed beyond one repository and one runner?
- How much status and diagnostic data should Macs report to the server?

The next slice adds Mac capacity and expiring provisioning offers without changing the application workflow interface.
