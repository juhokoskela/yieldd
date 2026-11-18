# Local job caches

Enable caching on the Mac once. Existing workflows that use Actions Cache API v2, including `actions/cache` and the cache in `actions/setup-go`, can then restore and save archives on that Mac. The actions still compress and extract their files. Workflow artifacts still go to GitHub.

For a build directory that is expensive to archive, a workflow can request a private writable disk instead. Each job gets its own copy, including concurrent jobs for the same repository. macOS guests use APFS and Linux guests use ext4. The Mac creates both copies with APFS copy-on-write cloning.

## Enable caching

1. Drain the agent. Upgrade the signed application and the patched Container installation for Linux. Rebuild the Linux guest image and update the macOS template with the matching yieldd guest helpers and Actions runner. The Linux Dockerfile builds the worker. Follow [Prepare a macOS runner template](macos-template.md) for the macOS worker.
2. Create `~/Library/Application Support/yieldd/job-caches.json` with mode `0600`. Use the state directory passed to yieldd if it differs. The following policy keeps each repository separate.

   ```json
   {"trustedGroups": []}
   ```

3. Start the agent. It reads this file at startup. To disable caching, drain and stop the agent, remove the file and start it again. Jobs then use their usual GitHub cache endpoint.

The agent stores disposable job disks and published caches under `job-caches/` on the configured quota-limited runner volume. Archive cleanup targets 10 GiB. For each guest platform, yieldd retains up to 16 native generations across scopes, with a combined budget of 16 GiB counted by allocated blocks. Each writable native disk has an 8 GiB virtual capacity. Active jobs and unfinished uploads need additional space on the volume.

## Use a native disk

Add the action after checkout and point your build tool at the directory it exports. Pin the action to a reviewed commit available to the workflow. For example, a Swift package can use:

```yaml
- uses: juhokoskela/yieldd/actions/native-cache@<commit>
- run: swift test --scratch-path "$YIELDD_CACHE_PATH/swift-build"
```

Run this action directly in the VM so the build can access its mount point. If yieldd is in a private repository, grant the consuming repository access to the action in GitHub. The action also supplies a `path` step output. It gives each job a temporary directory on hosted fallback runners and when the workflow sets `cache-mode: none`. Use a separate subdirectory for each tool or incompatible build configuration. Enabling a native cache for the same paths already covered by an archive makes the workflow pay for both.

A successful action post-step requests publication. After the listener exits, yieldd unmounts the disk, destroys the guest and publishes the new generation. The agent holds the slot until it proves the guest is gone. A failed unmount, canceled job or interrupted cleanup leaves the prior generation available. When two jobs start from the same generation, the first successful publication wins. A read-only job can modify its private copy.

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

Both branches can then read and replace shared build state. A pull request that GitHub allows to read either base branch can also read that shared cache. For a `pull_request` run, writes stay in its repository’s merge-ref scope. A workflow that explicitly grants default-branch writes to another event, such as `pull_request_target`, can update shared state. See [GitHub's cache permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#cache-access-for-low-trust-workflow-triggers). Only group repositories whose workflows can be trusted with each other's cached files. Changing group membership starts a fresh shared namespace. Archive keys remain immutable within a scope, and archives and native disks use separate storage.
