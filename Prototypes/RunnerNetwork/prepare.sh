#!/bin/bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$prototype_dir/../.." && pwd)"

source "$repo_root/Scripts/prepare-runner-container.sh"
bash "$repo_root/Scripts/build-network-relay.sh"

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
