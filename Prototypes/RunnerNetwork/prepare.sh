#!/bin/bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$prototype_dir/../.." && pwd)"

source "$prototype_dir/source-paths.sh"
bash "$repo_root/Scripts/build-network-relay.sh"
prepare_checkout https://github.com/apple/container.git \
    "$container_revision" "$container_source" "$prototype_dir/container.patch" \
    .build \
    Sources/Services/RuntimeLinux/Server/PacketSocket.swift \
    Sources/YielddNetworkProbe/LinuxProbe.swift \
    Sources/YielddNetworkProbe/RunnerNetworkRelay.swift \
    Tests/YielddNetworkPrototypeTests/MacProbeLifecycle.swift \
    Tests/YielddNetworkPrototypeTests/MacProbeLifecycleTests.swift

copy_source() {
    local source="$1" destination="$2"
    mkdir -p "$(dirname "$destination")"
    # These paths are generated copies. Edit the source files, not these copies.
    if ! cmp -s "$source" "$destination"; then
        cp "$source" "$destination"
    fi
}

# The fork and macOS probe compile the same socket implementation.
copy_source "$repo_root/Sources/Yieldd/PacketSocket.swift" \
    "$container_source/Sources/Services/RuntimeLinux/Server/PacketSocket.swift"
copy_source "$prototype_dir/LinuxProbe.swift" \
    "$container_source/Sources/YielddNetworkProbe/LinuxProbe.swift"
copy_source "$repo_root/Sources/Yieldd/RunnerNetworkRelay.swift" \
    "$container_source/Sources/YielddNetworkProbe/RunnerNetworkRelay.swift"
copy_source "$prototype_dir/MacProbeLifecycle.swift" \
    "$container_source/Tests/YielddNetworkPrototypeTests/MacProbeLifecycle.swift"
copy_source "$prototype_dir/MacProbeLifecycleTests.swift" \
    "$container_source/Tests/YielddNetworkPrototypeTests/MacProbeLifecycleTests.swift"

cd "$prototype_dir"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -parse-as-library "$repo_root/Sources/Yieldd/PacketSocket.swift" MacProbe.swift MacProbeLifecycle.swift \
    "$repo_root/Sources/Yieldd/RunnerNetworkRelay.swift" \
    -o "$repo_root/.build/mac-network-probe"
codesign --force --sign - --entitlements "$repo_root/Packaging/yieldd.entitlements" \
    "$repo_root/.build/mac-network-probe"
swift build --package-path "$container_source" --product yieldd-linux-network-probe -j 6
codesign --force --sign - --entitlements "$repo_root/Packaging/yieldd.entitlements" \
    "$container_source/.build/debug/yieldd-linux-network-probe"
echo "Built prototype relay and both probes. No services were installed or restarted."
