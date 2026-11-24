# Local job caches

Enable caching on the Mac once. Existing workflows that use Actions Cache API v2, including `actions/cache` and the cache in `actions/setup-go`, can then restore and save archives on that Mac. The actions still compress and extract their files. Workflow artifacts still go to GitHub.

## Enable caching

1. Drain the agent. Upgrade the signed application. Linux uses the existing yieldd Container build. Rebuild the Linux guest image and update the macOS template with the matching yieldd guest helpers and Actions runner. The Linux Dockerfile builds the worker. Follow [Prepare a macOS runner template](macos-template.md) for the macOS worker.
2. Create `~/Library/Application Support/yieldd/job-caches.json` with mode `0600`. Use the state directory passed to yieldd if it differs. The following policy keeps each repository separate.

   ```json
   {"trustedGroups": []}
   ```

3. With the agent stopped and the policy file in place, run `yieldd machine-test` for Linux and `yieldd machine-test --template /absolute/path/VM.bundle` for macOS. These commands boot disposable guests and check the cache-enabled helpers and worker.
4. Start the agent. It reads this file at startup. To disable caching, drain and stop the agent, remove the file and start it again. Jobs then use their usual GitHub cache endpoint.

The agent stores cache archives under `job-caches/` on the configured quota-limited runner volume. Archives use a separate sparse APFS image. Its capacity is at most 16 GiB, one eighth of the runner-volume quota and one quarter of the space available when the image is created, whichever is smallest. The filesystem bounds archive entries, unfinished uploads and SQLite together. Multipart restores stream the original parts directly. The image leaves room for database writes and filesystem overhead, then splits the remaining capacity evenly between published archives and staging the next upload. The published budget stays the same across restarts. Concurrent or unfinished uploads share the available staging space. An interrupted agent reuses the same image.

If saves fail because the archive image is full, retry after cleanup. Every five minutes the helper reclaims uploads that have been inactive for over a minute. After a runner quota reduction, an existing archive disk can exceed the new allowance. Restore the previous quota to keep those archives, or reset the store to create a smaller disk. To reset the archives, drain and stop the agent. Run `yieldd storage status` to find its guest volume and state directory (listed as “Recovery records”). Check `hdiutil info` for the exact image path. If it is still attached at `<state directory>/archive-volume`, detach that mount with `hdiutil detach "<state directory>/archive-volume"`. Once `hdiutil info` confirms the image is detached, remove only `<guest volume>/job-caches/archives/archives.sparseimage`. Restart the agent to create an empty archive store, then run `yieldd agent resume` for an installed agent.

## Share trusted branches

By default, the cache service uses the repository ID and branch or pull-request scopes from GitHub's signed job token. The workflow's effective `cache-mode` limits those grants. The job receives the read scopes and write permission GitHub granted it. A pull request can inherit a readable base cache and save a separate pull-request cache.

To share bytes across repositories, put their exact branch refs and numeric repository IDs in one group. Obtain an ID with `gh api repos/OWNER/REPO --jq .id`. For example:

```json
{
  "trustedGroups": [
    [
      {"repositoryID": "12345", "ref": "refs/heads/main"},
      {"repositoryID": "67890", "ref": "refs/heads/main"}
    ]
  ]
}
```

Both branches can then read and replace shared build state. A pull request that GitHub allows to read either base branch can also read that shared cache. For a `pull_request` run, writes stay in its repository’s merge-ref scope. A workflow that explicitly grants default-branch writes to another event, such as `pull_request_target`, can update shared state. See [GitHub's cache permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#cache-access-for-low-trust-workflow-triggers). Only group repositories whose workflows can be trusted with each other's cached files. Changing group membership starts a fresh shared namespace. Archive keys remain immutable within a scope.

## Upgrade from native job caches

Migrate workflows that call `actions/native-cache` to Actions archives before upgrading the agent. This includes workflows pinned to an older yieldd commit. Use `actions/setup-go` caching for Go, or `actions/cache` with the paths and keys needed for the build. Run the workflow twice on the same Mac and confirm the second run restores its archive.

Drain the old agent and finish any pending recovery before switching versions. Old native images remain under `job-caches/native` on the guest volume. After verifying the migration, an operator can reclaim those files. The local archive store is in the sibling `job-caches/archives` directory.

If you roll back to an agent that supports native job caches, restore its matching Linux guest image before resuming native-cache workflows. Both image versions report local-cache protocol 3. The archive-only image omits the native disk helper.
