#!/bin/bash
# Sourced by the pinned Container build and the prototype checks.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prototype_dir="$repo_root/Prototypes/RunnerNetwork"
source "$prototype_dir/source-paths.sh"
prepare_checkout https://github.com/apple/container.git \
    "$container_revision" "$container_source" "$prototype_dir/container.patch" \
    .build bin/release \
    Sources/Services/RuntimeLinux/Server/PacketSocket.swift \
    Sources/YielddNetworkProbe/LinuxProbe.swift \
    Sources/YielddNetworkProbe/RunnerNetworkRelay.swift \
    Tests/YielddNetworkPrototypeTests/MacProbeLifecycle.swift \
    Tests/YielddNetworkPrototypeTests/MacProbeLifecycleTests.swift

copy_source() {
    local source="$1" destination="$2"
    mkdir -p "$(dirname "$destination")"
    if ! cmp -s "$source" "$destination"; then cp "$source" "$destination"; fi
}
copy_source "$repo_root/Sources/Yieldd/PacketSocket.swift" \
    "$container_source/Sources/Services/RuntimeLinux/Server/PacketSocket.swift"
copy_source "$prototype_dir/LinuxProbe.swift" "$container_source/Sources/YielddNetworkProbe/LinuxProbe.swift"
copy_source "$repo_root/Sources/Yieldd/RunnerNetworkRelay.swift" "$container_source/Sources/YielddNetworkProbe/RunnerNetworkRelay.swift"
copy_source "$prototype_dir/MacProbeLifecycle.swift" "$container_source/Tests/YielddNetworkPrototypeTests/MacProbeLifecycle.swift"
copy_source "$prototype_dir/MacProbeLifecycleTests.swift" "$container_source/Tests/YielddNetworkPrototypeTests/MacProbeLifecycleTests.swift"
