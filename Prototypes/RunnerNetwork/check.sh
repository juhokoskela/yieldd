#!/bin/bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$prototype_dir/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

bash "$prototype_dir/prepare.sh"
cd "$prototype_dir"
go test -race -timeout 90s ./...
go vet ./...
YIELDD_TEST_RELAY="$repo_root/.build/network-prototype" \
    swift test --package-path "$repo_root" --filter RunnerNetworkRelayTests -j 6
swift build --package-path "$repo_root/.build/network-container" --target MachineAPIService -j 6
swift test --package-path "$repo_root/.build/network-container" \
    --filter 'PacketSocketTests|MachineConfigTests|ContainerConfigurationResourcesTests' -j 6
codesign --verify --strict "$repo_root/.build/mac-network-probe"
codesign --verify --strict "$repo_root/.build/network-container/.build/debug/yieldd-linux-network-probe"
echo "Prototype checks passed. No VMs or installed services were started."
