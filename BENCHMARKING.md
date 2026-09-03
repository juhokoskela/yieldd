# Benchmarking

These are early end-to-end GitHub Actions results from real repositories. They are useful baselines, not controlled hardware benchmarks. Workflow setup, dependency handling, and provider infrastructure all affect the result.

## Results

| Workload | Blacksmith | yieldd | Relative time |
| --- | ---: | ---: | ---: |
| LibreChat TypeScript and JavaScript workflow | about 48 min | 17 min 26 s | about 2.8x faster |
| Go repository workflow | 15 min 51 s | 6 min 18 s | 2.52x faster |

The Go workflow saved 9 minutes 33 seconds, a 60.3% reduction in elapsed time.

## Runner sizing

The LibreChat workflow was also run with larger CPU allocations:

| vCPUs | Elapsed time | Reduction from 4 vCPUs |
| ---: | ---: | ---: |
| 4 | 17 min 26 s | baseline |
| 9 | 14 min 39 s | 16.0% |
| 13 | 12 min 11 s | 30.1% |

Moving from 4 to 9 vCPUs made 2.25x as many vCPUs available for a 16.0% shorter run. Moving to 13 vCPUs made 3.25x as many available for a 30.1% shorter run.

The two 4-vCPU yieldd workflows also ran concurrently on separate runners with no measurable performance regression compared with running them individually. These results support adding 4-vCPU runner slots on this host before making an individual runner larger.

## Configuration

- Host: Apple M5 Pro MacBook Pro
- yieldd guest: Ubuntu 24.04 ARM64 under Apple container machine
- yieldd runner: 4 vCPUs and 12 GB memory
- Comparison runner: `blacksmith-4vcpu-ubuntu-2404-arm`

Cache behavior materially affected earlier runs. GitHub cache downloads reached only about 3 to 4 MB/s on the self-hosted runner, making uncached dependency installation faster for these workloads. Future comparisons should use the same cache policy on both runners.

For a useful rerun, record the workflow commit and run URL, keep runner sizing and cache policy unchanged, and avoid unrelated host load.
