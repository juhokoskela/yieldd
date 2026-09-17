# Prepare a macOS runner template

Template creation is manual. Use an Apple Virtualization.framework macOS VM bundle containing `Disk.img`, `AuxiliaryStorage`, `HardwareModel`, and `MachineIdentifier`. Keep it outside yieldd's `macos-runners` directory and on the same APFS volume. yieldd uses copy-on-write clones and does not fall back to copying the full disk across volumes.

## Configure the guest

1. Install macOS, complete Setup Assistant, and create the `runner` account with a password.
2. Enable Remote Login for `runner`. Install a dedicated SSH public key in its `~/.ssh/authorized_keys`.
3. Install full Xcode. Open it, accept its license, finish first-launch setup, and install an iOS Simulator runtime under Xcode Settings > Components. Select that Xcode installation with `xcode-select`.
4. Enable automatic login for `runner` in System Settings. After a cold boot, `/usr/bin/stat -f %Su /dev/console` must print `runner`, and `launchctl print "gui/$(id -u)"` from a runner SSH session must succeed. Do not rely on `sysadminctl` reporting success.
5. Install the macOS ARM64 GitHub Actions runner in `/Users/runner/actions-runner`, but leave it unregistered.
6. Copy this repository's `Guest/macOS/configure-runner` and `Guest/macOS/runner-control` to `/Users/runner/bin/yieldd-configure-runner` and `/Users/runner/bin/yieldd-runner-control`. Make both executable. Run `yieldd-runner-control ready` from that directory over SSH to check the login prerequisites.
7. Remove any previous runner registration and shut down the template cleanly. Do not run the template while yieldd is cloning it.

Automatic login weakens the guest's local security. Keep repository credentials, personal accounts, and other secrets out of the template. Do not install passwordless sudo. yieldd shares no host directories and sends the ephemeral registration token or connected runner's JIT payload over SSH stdin. It does not collect or store the guest password.

## Pin SSH credentials on the host

Place the dedicated private key in the template bundle as `SSHPrivateKey`, with mode `600` or stricter. Store the guest's verified SSH host public key in `SSHKnownHosts`, under the alias `yieldd-macos-template`:

```text
yieldd-macos-template ssh-ed25519 BASE64_PUBLIC_HOST_KEY
```

Obtain and verify that public host key through the template's console. Do not treat an unverified network key scan as authentication. `SSHKnownHosts` must not be group- or world-writable. These host-side files are used for SSH; yieldd does not copy them into the guest disk.

## Validate a cold clone

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd machine-test --template /absolute/path/VM.bundle
```

The command boots a disposable clone and checks SSH, console login, the GUI domain, Xcode, an available compatible iOS runtime and iPhone device type, simulator boot, and screenshot capture. It does not require the newest runtime or device, or test simulator teardown. Fix a reported prerequisite in the template, shut it down, and repeat validation. Cleanup is attempted even after a timeout; if destruction fails, the command reports it and leaves the clone for recovery. Validation does not download or update Xcode or simulator runtimes.

After validation passes, use `runner-test --template` with a trusted workflow labeled `yieldd-macos`. Jobs get fresh clones; they do not reuse the validation guest or change the template.
