# Linux runner networking

Linux runner commands now require yieldd's pinned Apple Container fork and the bundled packet relay. Stock Container does not expose this machine network path. There is no NAT fallback.

The fork uses Container 1.6.0 (`ca4884f8f3a13b62c90ea2fb3834f214d61fb91c`), including its image-digest verification and build-context symlink fixes. The packet relay, headless `machine boot` command, and signal-forwarding fix remain local patches. Relay machines retain the image's accounts and skip host-user provisioning. yieldd runs commands as explicit guest users, so host names such as `runner` or `ubuntu` do not collide with guest accounts. The init script also skips SSH socket ownership changes when forwarding is disabled.

Each machine gets its own relay and private socket directory. yieldd creates the machine with `--no-boot`, then checks `machine inspect` for the exact runner ID, relay socket, and disabled home mount. Only a matching configuration can reach the fork's non-interactive `machine boot` command. Boot has the five-minute creation budget, before the shorter Docker readiness probes. Later commands and status polls do not run user setup or rewrite sudoers. This also rejects a patched CLI talking to an older machine service that discarded the socket setting. The runtime forbids combining the socket with vmnet attachments, published ports or sockets, host Unix-socket mounts, or SSH-agent forwarding. This guard covers network paths; the machine configuration separately requires `home-mount=none`. Socket paths are per-machine settings and cannot be system defaults. An empty `network-socket` value clears the setting.

Relay health is checked before and during guest commands, including long listener waits. Relay loss interrupts the host command and is reported as a network failure, not a successful user stop. Owner death closes the relay's lifetime pipe. Cleanup attempts both relay shutdown and machine deletion; failed cleanup retains the journal and memory reservation. Recovery never boots abandoned guests or invokes their listener helpers; it deletes machines through Container's host control plane. It does not require the fork just to delete a machine. Socket directories are removed only after machine deletion and storage removal have been confirmed.

## Install the pinned Container build

Finish running jobs and cleanup, then stop yieldd before replacing Container. Its services and data root are shared with other Container users, not isolated to this project. Keep the quota volume and recovery journals intact. Do not install or restart services from inside a runner job.

From a checkout of this branch on the runner Mac:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-runner-container.sh
container system stop
sudo installer -pkg .build/yieldd-container-installer.pkg -target /
container system start --app-root /Volumes/YielddRunners/container
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd doctor
.build/yieldd.app/Contents/MacOS/yieldd machine-test
```

Use your configured volume path instead of `/Volumes/YielddRunners`. The build script creates an ad-hoc-signed development installer; it does not install or restart services. It verifies the pinned source revision and patch before compilation. The installer binaries report `1.6.0+yieldd.2` and the pinned base commit; no Git tag is required. Unexpected cache edits are rejected without being discarded.

The fork also fixes process-signal forwarding: the Container CLI sends the host-platform signal name, which the API server forwards to the host-side `container-runtime-linux` helper for Linux signal parsing. A numeric Darwin signal would misidentify signals such as SIGUSR1 and SIGUSR2 on Linux. The original integer encoding could instead report `missing signal in xpc message` when interrupting a timed-out guest command. Updating yieldd alone does not replace the installed Container CLI; rebuild and install the package above after jobs and cleanup finish.

The guest image and `connect` arguments are unchanged. Restart connected workers only after `machine-test` passes. Keep any failed cleanup records and resolve them before changing Container again.

## Validation boundary

Automated checks cover the create/inspect/boot ordering, rejection of missing or mismatched socket settings, relay failure during a running host process, bounded shutdown, crash-directory cleanup, and both Container status formats. Fork configuration tests cover socket clearing, invalid shared defaults, and configuration persistence. A local XPC test checks process-signal encoding without starting a guest. The real init script runs in a host fixture with `SSH_AUTH_SOCK` unset and empty. CI builds the patched CLI, services, and installer without installing them.

The initial installed 1.6.0 package passed `doctor` and Linux `machine-test`, including CLI boot, guest helpers, Docker `hello-world`, and confirmed machine cleanup. The corrected CLI also passed a disposable guest check with a `runner:501` host mapping: the image account was retained, and eight repeated commands preserved modified passwd and sudoers files. The old CLI reproduced the account collision and stopped the VM. This check used the previously installed services, so it does not validate the new runtime guards or hostname mapping in installed services, or establish GitHub-job acceptance.

Before deploying the corrected package, repeat the guest account checks and verify hostname resolution and rejected host Unix-socket mounts through the installed machine CLI. Also check controlled host/LAN denial with positive host and public DNS/HTTPS controls, owner interruption, deletion after interruption, recovery, and a real GitHub job. Normal machine deletion and public transport already passed the initial smoke test; the remaining checks exercise isolation and failure recovery. The normal macOS backend still needs live VM and job acceptance. Earlier runtime-only probes bypassed the machine service and CLI.

The relay filters host and private destinations and drops IPv6. Public DNS and HTTPS remain possible data channels. Public-address hairpin routes and interface changes affecting existing connections remain limitations. Relay CPU, memory, and connection budgets are separate follow-up work. See [runner boundaries](runner-boundaries.md).
