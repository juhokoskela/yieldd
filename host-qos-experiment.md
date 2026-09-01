# Host QoS experiment

Guest CPU limits are the primary resource control. Host QoS remains an experiment because Apple `container` runs VM work behind an XPC boundary, so applying `taskpolicy` to the short-lived CLI process may not affect the VM.

## Candidate policies

- Normal QoS is the baseline.
- `.utility` is the first candidate. On M5 Pro it may favor the twelve M-cores while leaving the faster super cores available for interactive work.
- `.background` is more aggressive and may throttle disk I/O enough to hurt CI workloads. Older Apple Silicon chips may also run background work mainly on much slower E-cores.

`taskpolicy -c utility PROGRAM` applies a QoS clamp when launching a process. `taskpolicy -b -p PID` and `taskpolicy -B -p PID` can toggle Darwin background priority on an existing process, but they are not equivalent to a utility clamp.

## Before implementing

1. Identify a stable per-machine virtualization process. Do not change a shared Apple container service.
2. Compare normal, utility, and background policies with the same guest CPU allocation.
3. Record workflow duration, per-core CPU use, disk and network throughput, GitHub heartbeat stability, and foreground responsiveness.
4. Keep host QoS disabled unless the result is useful across repeated runs. Treat chip families separately rather than assuming one policy fits every Apple Silicon generation.
