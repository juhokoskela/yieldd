#!/bin/bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$prototype_dir/../.." && pwd)"
source "$prototype_dir/source-paths.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

bash "$repo_root/Scripts/test-prepare-patched-source.sh"
bash "$prototype_dir/prepare.sh"
bash "$prototype_dir/test-machine-init.sh" "$container_source/Sources/Plugins/MachineAPIServer/Resources/init"
cd "$prototype_dir"
go test -modfile "$relay_module" -race -timeout 90s ./...
go vet -modfile "$relay_module" ./...
case "${GITHUB_EVENT_NAME:-local}" in
    push|pull_request) ;; # The main CI workflow runs the full Swift suite.
    *)
        YIELDD_TEST_RELAY="$repo_root/.build/yieldd-network-relay" \
            swift test --package-path "$repo_root" --no-parallel \
            --filter 'RunnerNetworkRelayTests|RunnerNetworkTests|PacketSocketTests|macOSBackend|runnerNetwork|LinuxRunnerNetworkTests|monitoredProcess' -j 6
        ;;
esac
swift build --package-path "$container_source" --target MachineAPIService -j 6
swift build --package-path "$container_source" --product container -j 6
"$container_source/.build/debug/container" machine create --help | grep -q -- --network-socket
"$container_source/.build/debug/container" machine boot --help | grep -q 'without terminal input'
swift test --package-path "$container_source" \
    --filter 'MacProbeLifecycleTests|MachineConfigTests|ContainerConfigurationResourcesTests|ClientProcessSignalTests' -j 6
codesign --verify --strict "$repo_root/.build/mac-network-probe"
codesign --verify --strict "$container_source/.build/debug/yieldd-linux-network-probe"
echo "Prototype checks passed. No VMs or installed services were started."
