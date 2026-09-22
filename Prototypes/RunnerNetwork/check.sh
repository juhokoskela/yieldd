#!/bin/bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$prototype_dir/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

bash "$repo_root/Scripts/test-prepare-patched-source.sh"
bash "$prototype_dir/prepare.sh"
cd "$prototype_dir"
go test -race -timeout 90s ./...
go vet ./...
YIELDD_TEST_RELAY="$repo_root/.build/yieldd-network-relay" \
    swift test --package-path "$repo_root" --no-parallel \
    --filter 'RunnerNetworkRelayTests|MacOSRunnerNetworkTests|PacketSocketTests|macOSBackend|runnerNetwork' -j 6
swift build --package-path "$repo_root/.build/network-container" --target MachineAPIService -j 6
swift test --package-path "$repo_root/.build/network-container" \
    --filter 'MacProbeLifecycleTests|MachineConfigTests|ContainerConfigurationResourcesTests' -j 6
codesign --verify --strict "$repo_root/.build/mac-network-probe"
codesign --verify --strict "$repo_root/.build/network-container/.build/debug/yieldd-linux-network-probe"
echo "Prototype checks passed. No VMs or installed services were started."
