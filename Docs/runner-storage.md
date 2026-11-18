# Quota-limited runner storage

New Linux machines and macOS VMs require a dedicated APFS volume with a hard quota. Choose the quota for each Mac. The limit is shared by Apple Container data, macOS templates, and disposable clones; it is not a per-job allowance. A quota limits growth but does not reserve free space. Leave room on the host for other applications.

The layout is:

```text
/Volumes/YielddRunners/                 APFS volume, operator-chosen quota
  container/                           Apple Container service data, including guest logs
  VM.bundle/                           macOS template (optional)
  macos-runners/                       disposable runner clones
  macos-probes/                        disposable diagnostic clones
~/Library/Application Support/yieldd/  outside the guest volume
  storage.json                         pinned volume identity and mount point
  linux-machine-test, connected*runner*.json   cleanup records
  runner.lock
```

yieldd checks the mounted volume's UUID, quota, and storage paths before creating a guest. A missing mount, a different volume at the same path, an unlimited volume, or a template outside that volume prevents creation. Disk cleanup requires the original volume and `storage.json`; missing storage never counts as successful cleanup. Recovery still attempts independent work, including removing abandoned macOS registrations from GitHub, and retains each lease until all of its cleanup succeeds. Recovery sweeps both runner and diagnostic clone directories.

## Set up a Mac

Stop yieldd and finish any outstanding cleanup first. Use `recover` for interrupted machine tests, or reconnect with the original coordinator and device ID for connected leases. When upgrading from an unconfigured storage layout, finish that cleanup with the previous version before upgrading. This version does not search or migrate old Container roots or clone directories. Inspect those locations before retiring them, especially if other applications use Container. Configuration refuses pending leases. Do not delete journals to bypass these checks.

Create an encrypted APFS volume in Disk Utility with an explicit quota, or use the commands below. They add a volume, not a partition, and do not move existing files. Run them as your normal user. `sudo` requests administrator authorization, and `-passprompt` requests the new volume's encryption passphrase without putting it in shell history. Check the container identifier before adding the volume. Do not repeat this step if the volume already exists.

```sh
runner_quota_gib=256  # Choose for this Mac; 256 is an example, not a default.
runner_container="$(diskutil info -plist /System/Volumes/Data | plutil -extract APFSContainerReference raw -)"
diskutil apfs list "$runner_container"
sudo diskutil apfs addVolume "$runner_container" APFS YielddRunners \
  -quota "$((runner_quota_gib * 1024 * 1024 * 1024))" -passprompt
sudo chown "$(id -u):$(id -g)" /Volumes/YielddRunners
chmod 700 /Volumes/YielddRunners

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd storage configure --volume /Volumes/YielddRunners
.build/yieldd.app/Contents/MacOS/yieldd storage status
```

APFS quotas are volume settings, not a yieldd memory-budget flag. `storage configure` reads the actual quota instead of trusting a requested number. It saves the volume identity outside the quota and does not replace an existing binding. Keep `storage.json` with the recovery records. If an encrypted volume is used, unlock and mount it before starting yieldd after a reboot.

### Linux

Apple Container uses one service-wide data root. Switching it also changes which images, containers, and machines other `container` commands see. Stop any non-yieldd workloads first. This procedure starts with fresh Container data and preserves the old data in its original location. Do not copy an existing Container root into the new location: its metadata can contain absolute paths to disks outside the quota.

```sh
container system stop
container system start --app-root /Volumes/YielddRunners/container
container system status --format json
container build -t local/yieldd-guest:dev Guest
container builder stop
```

Confirm that `paths.appRoot` (or `appRoot` on older Container versions) points to `/Volumes/YielddRunners/container`. yieldd's service-start calls use this configured root, and Linux creation and cleanup check the running service's reported root. `yieldd recover` does not start Container: after a reboot, start it with this root before recovering a Linux machine test. Starting Container manually without `--app-root` can select its old data; yieldd refuses to create or clean up runners there. Keep the old root until you have checked that unrelated Container data is no longer needed.

The machine-bundle cleanup check uses `plugin-state/machine-apiserver/machines/`, which the pinned Container 1.6.0 build retains. Recheck that boundary when upgrading Container, especially if its machine storage layout changes.

### macOS

Shut down the template VM before copying it. Keep the original until the new location passes a machine test. Copying across APFS volumes needs real space even when the source disk was sparse or shared blocks with other clones.

```sh
ditto /Users/YOUR_USER/VM.bundle /Volumes/YielddRunners/VM.bundle
.build/yieldd.app/Contents/MacOS/yieldd machine-test \
  --template /Volumes/YielddRunners/VM.bundle
```

Use the new template path in `connect` or the agent configuration. The template must be outside both `macos-runners` and `macos-probes`, and on the same volume as the clones. No guest scripts need changing for storage quotas.

## If the volume fills

APFS rejects further guest writes at the quota. Jobs can fail, and Apple Container's own metadata writes can fail too. yieldd's recovery records remain writable on the host volume. Cleanup can remove macOS clones without free guest space. Linux cleanup keeps its obligation if the API fails or a machine's on-disk bundle remains despite disappearing from the API list.

If Container cannot start or delete a machine, stop yieldd and free space on the quota volume from data you have identified as disposable. Do not remove a live guest's disk or the host recovery records. Restart Container with the configured `--app-root`, then retry recovery. The quota protects host storage from guest-disk growth; it does not guarantee that every full-disk failure can be repaired automatically, or prevent unrelated host applications from filling the disk.

### An unlisted machine bundle remains

Container reloads valid machine bundles on service restart. A local stopped-machine experiment confirmed that restarting restored an unlisted bundle and made normal deletion work. The same experiment with missing machine metadata stayed unlisted after restart. yieldd cannot safely infer that an unlisted machine is stopped, so it does not delete these bundles automatically.

If restart does not help:

1. Stop yieldd, including any agent or connected client. Stop all Container workloads and run `container system stop`. Verify that Container is stopped and no backing guest process remains. Do not proceed if stopping fails or guest ownership is uncertain.
2. Inspect the exact bundle path printed by yieldd. It must belong to the retained runner ID under the configured volume's `container/plugin-state/machine-apiserver/machines/` directory. Do not remove the parent directory, templates, or other machines.
3. Remove only that stopped, disposable runner bundle. This permanently deletes its guest disk; preserve it elsewhere first if you need it for diagnosis. Keep `storage.json` and all cleanup journals.
4. Start Container with the configured `--app-root`, then rerun `yieldd recover` or reconnect with the original coordinator identity. yieldd can now verify disk removal, finish registration cleanup, and clear the journal.

## Verify the boundary without filling the real volume

```sh
YIELDD_STORAGE_INTEGRATION=1 \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --no-parallel --filter storageQuotaStopsWritesButNotRecoveryJournal
```

This opt-in test creates a disposable sparse disk image, adds a small quota volume, writes until APFS refuses more data, saves a recovery lease outside that volume, removes the test clone, and verifies that an unmounted volume cannot be mistaken for successful cleanup. The write loop has its own upper bound. It does not start Container or a VM, move existing data, or modify the host's APFS volumes.
