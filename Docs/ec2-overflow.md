# EC2 overflow for Linux ARM64

Enable this route for one repository whose jobs can all read the same build cache. The Mac gets the first offer. When it has no available worker or declines the offer, the coordinator launches one `m9g.xlarge` for one GitHub job. The listener, Docker, containerd and their ordinary workloads share four vCPUs and a 12 GiB systemd slice. Workflows with root or Docker access can change guest settings, so the cgroup limit assumes a cooperative workload. GitHub assigns the queued job. An interrupted job requires a manual rerun.

## Prepare the runner image

Use a fresh Canonical Ubuntu 24.04 ARM64 EC2 builder with an encrypted root volume mapped at `/dev/sda1`. Copy the two files from `Guest/ec2/` to the builder and run:

```sh
sudo install -m 0755 job.sh /usr/local/sbin/yieldd-ec2-job
sudo bash bake.sh
sudo poweroff
```

Create a private AMI from the stopped builder's root disk and terminate the builder once the AMI is available. The recipe installs the checksum-pinned GitHub runner and Docker. It removes SSH host keys, authorized keys and cloud-init state before capture. Use a clean builder containing only the image inputs. Rebuild the AMI when updating the runner.

## Enable the route

Use the coordinator's existing private state directory, Mac connection and HTTPS reverse proxy. The subnet needs outbound access to GitHub, the proxy and the workload's dependencies. Use a security group with no inbound rules. Forward `POST /v1/ec2/{runner}/register` and `POST /v1/ec2/{runner}/quiesced` to the coordinator. Keep authorization headers and response bodies out of proxy logs.

Give the **coordinator** a renewable AWS workload identity. The AWS SDK reads its default credential chain and checks the account at startup. On EC2 use a dedicated coordinator instance profile. A coordinator in a bridged container needs a reachable credential provider, such as IMDSv2 with a response hop limit of two on that coordinator host. Workers launch without an instance profile. The [CloudFormation policy](../Server/ec2-policy.yaml) attaches the EC2 permissions to an existing coordinator role and scopes launches by repository, region, image, instance type, subnet and security group. The template assumes the account's standard EBS encryption key. Grant the coordinator read access to Actions runs, repository metadata and Git refs in the selected GitHub repository in addition to its existing runner permissions.

Set `YIELDD_EC2` to one JSON object in the coordinator environment. Supply the lowercase repository name from `--repositories`, the producer workflow path, and its exact GitHub job display name. Set `YIELDD_EC2_BOOTSTRAP_KEY` to a separate secret generated with `openssl rand -hex 32`. Keep it across restarts. Drain the queue before changing the key, route or AMI.

```json
{
  "repository": "example/application",
  "account": "111111111111",
  "region": "eu-central-1",
  "image": "ami-0123456789abcdef0",
  "subnet": "subnet-0123456789abcdef0",
  "security_group": "sg-0123456789abcdef0",
  "endpoint": "https://runner.example.org",
  "seed_workflow": ".github/workflows/ci.yml",
  "seed_job": "Build and test"
}
```

The EC2 queue has one hosted slot. Existing fallback flags still configure other queues. Omitting `YIELDD_EC2` leaves the original routes active. Each instance's user data contains a lease-scoped bootstrap token. The coordinator records issuance before returning the GitHub JIT credential and rejects a second registration request. Restrict AWS access to instance user data.

## Cache contents and publication

Each job gets an encrypted 12 GiB gp3 cache volume. It starts blank until a compatible snapshot completes. The layout contains Go's build and module directories, the Actions tool cache and `/mnt/yieldd/buildkit` for explicit BuildKit local exports. To use that directory with a compatible Buildx builder, import from a completed export with `--cache-from type=local,src=/mnt/yieldd/buildkit/current` and export to a separate directory with `--cache-to type=local,dest=/mnt/yieldd/buildkit/next,mode=max`. On a cold run omit the import. After a successful build replace `current` with `next`. Use `cache: false` with `actions/setup-go` when the workflow should rely solely on EBS for the Go cache. The workspace, runner credentials and live Docker daemon data stay on the disposable root disk.

Every job on the selected queue can read the entire seed, including its raw disk blocks. Choose a producer whose cache contains only data all those jobs may read. Keep credentials, secret build arguments and private inputs beyond that audience off the data disk, including temporary files.

The coordinator matches the completed job's runner ID, repository, display name and successful push event. It checks the run's workflow path, source repository and commit against the current default branch on GitHub. A tag with the same name as the branch makes the ref ambiguous and skips publication. After the guest unmounts the cache filesystem, the coordinator requests a snapshot and the guest can shut down while EBS finishes. A pending snapshot or a completed snapshot less than 24 hours old skips the save. A later launch chooses the newest completed snapshot matching the queue owner, repository, AMI, layout, producer workflow and job. Before publication, the coordinator prunes failed snapshots and completed generations older than the newest two. A retention error suspends publication. Jobs can still restore the existing cache. When retiring an AMI or queue, remove its old snapshots after draining.

## Recovery and rollout

The coordinator persists the lease before launch and uses its UUID as the EC2 client token. Restart with the same journal, region and bootstrap key. The coordinator matches the instance to the lease, waits through `shutting-down`, and checks both tagged disks after termination. It deletes detached disks left by that lease. Once EC2 confirms termination and every tagged disk is deleting or gone, the next job can launch while EBS finishes deletion. The guest powers off when the runner exits. Baked timers also power it off after ten minutes without job pickup or six hours from boot. If an observed instance ends before requesting registration, the coordinator retains its reservation across service restarts. Inspect the failed launch, then release the reservation with the exact `--recover` target printed in the error. The same command deliberately terminates a running assignment. Explicit recovery uses the journal and AWS identity and can run after loss of the bootstrap key.

For the first rollout, run one cold producer, wait for its snapshot to complete, then run the same revision on a fresh instance. Compare test results and output digests, check that the second launch log names the snapshot, and verify termination and disk deletion for both leases. A pull request and a failed producer should leave the seed unchanged. The instance timers, GitHub completion metadata and IAM policy need verification on the deployed image and role.
