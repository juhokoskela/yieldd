# macOS guest runner testing

Use this workflow to validate the guest scripts before connecting them to the
macOS virtualization backend. Always boot a disposable clone. Never run jobs in
the reusable template bundle.

## Prerequisites

- The disposable VM is running and its `runner` account is logged in at the
  console.
- SSH is enabled for `runner` and the template's private key and pinned host key
  are available on the host.
- Xcode, at least one required simulator runtime, and the GitHub Actions runner
  are installed in `/Users/runner/actions-runner`.
- A trusted workflow is queued with `runs-on: yieldd-macos`.

## Boot a disposable clone

Build the entitled application and run the hidden probe in hold mode:

```bash
template=/path/to/yieldd-macos-template.bundle
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd \
    agent virtualization-probe --hold "$template"
```

The probe creates a private clone and retries DHCP and SSH readiness until the
guest is ready or the command receives Ctrl+C. Keep this terminal open. The
probe force-stops the VM and deletes the clone when it exits.

After it prints the guest address, set the connection details in another host
terminal:

```bash
guest_address=192.168.65.5
guest="runner@$guest_address"
ssh_options=(
    -F /dev/null
    -i "$template/SSHPrivateKey"
    -o BatchMode=yes
    -o GlobalKnownHostsFile=/dev/null
    -o HostKeyAlias=yieldd-macos-template
    -o IdentitiesOnly=yes
    -o KbdInteractiveAuthentication=no
    -o PasswordAuthentication=no
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=\"$template/SSHKnownHosts\""
)
```

## Install and verify the entry points

```bash
scp "${ssh_options[@]}" \
    Guest/macOS/configure-runner \
    "$guest:/Users/runner/bin/yieldd-configure-runner"
scp "${ssh_options[@]}" \
    Guest/macOS/runner-control \
    "$guest:/Users/runner/bin/yieldd-runner-control"
ssh "${ssh_options[@]}" "$guest" \
    chmod 755 \
    /Users/runner/bin/yieldd-configure-runner \
    /Users/runner/bin/yieldd-runner-control
ssh "${ssh_options[@]}" "$guest" \
    /Users/runner/bin/yieldd-runner-control ready
```

The final command should return successfully without output. A console-login or
GUI-domain failure means the clone is not ready for Xcode and simulator jobs.

## Register and run

Use a repository whose workflows are trusted:

```bash
repository=OWNER/REPOSITORY
runner_name="yieldd-macos-test-$(uuidgen | tr '[:upper:]' '[:lower:]')"
registration_token="$(
    gh api --method POST \
        "repos/$repository/actions/runners/registration-token" \
        --jq .token
)"
printf '%s\n' "$registration_token" | \
    ssh "${ssh_options[@]}" "$guest" \
        /Users/runner/bin/yieldd-configure-runner \
        "$repository" "$runner_name"
unset registration_token

ssh "${ssh_options[@]}" "$guest" \
    /Users/runner/bin/yieldd-runner-control run
```

The last command waits for one job and returns the listener's exit status. The
runner is ephemeral and has only the `yieldd-macos` label.

## Verify SSH-loss independence

While the job is running, interrupt only the local `ssh ... runner-control run`
command with Ctrl+C. Do not invoke `runner-control stop`. Confirm in GitHub that
the same runner remains busy, then reconnect:

```bash
ssh "${ssh_options[@]}" "$guest" \
    /Users/runner/bin/yieldd-runner-control run
```

The second invocation must attach to the existing listener rather than register
or start another one. It should return after the job finishes and print the
listener output retained inside the guest.

## Cleanup

The stop operation is idempotent and signals the listener's complete process
group:

```bash
ssh "${ssh_options[@]}" "$guest" \
    /Users/runner/bin/yieldd-runner-control stop
```

If GitHub still lists the test runner, remove that exact registration:

```bash
runner_id="$(
    gh api "repos/$repository/actions/runners?name=$runner_name" \
        --jq ".runners[] | select(.name == \"$runner_name\") | .id" \
        | head -n 1
)"
if [[ -n "$runner_id" ]]; then
    gh api --method DELETE "repos/$repository/actions/runners/$runner_id"
fi
```

Finally, press Ctrl+C in the held probe's terminal. Confirm that it force-stops
the VM and deletes the disposable clone. A failed or interrupted test must
never be promoted back into the reusable template.
