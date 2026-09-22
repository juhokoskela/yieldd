#!/bin/bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$prototype_dir/../.." && pwd)"

prepare_checkout() {
    local repository="$1" revision="$2" destination="$3" patch="$4"
    if [[ ! -d "$destination" ]]; then
        git clone --no-checkout "$repository" "$destination"
        git -C "$destination" checkout --detach "$revision"
    fi
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]] || {
        echo "Unexpected source revision in $destination; refusing to change it." >&2
        exit 1
    }
    if git -C "$destination" apply --check "$patch" 2>/dev/null; then
        git -C "$destination" apply "$patch"
    else
        git -C "$destination" apply --reverse --check "$patch"
    fi
}

prepare_checkout https://github.com/containers/gvisor-tap-vsock.git \
    9cfc86f66679ef0feed0f20ba1df558fe2bef5c6 \
    "$repo_root/.build/network-gvproxy" "$prototype_dir/gvproxy.patch"
prepare_checkout https://github.com/apple/container.git \
    a9a62e28f6beb88940122a3d7b286f2d5ae8053a \
    "$repo_root/.build/network-container" "$prototype_dir/container.patch"

copy_source() {
    local source="$1" destination="$2"
    mkdir -p "$(dirname "$destination")"
    # These paths are generated copies. Edit the source files, not these copies.
    if ! cmp -s "$source" "$destination"; then
        cp "$source" "$destination"
    fi
}

# The fork and macOS probe compile the same socket implementation.
copy_source "$prototype_dir/PacketSocket.swift" \
    "$repo_root/.build/network-container/Sources/Services/RuntimeLinux/Server/PacketSocket.swift"
copy_source "$prototype_dir/LinuxProbe.swift" \
    "$repo_root/.build/network-container/Sources/YielddNetworkProbe/LinuxProbe.swift"
copy_source "$repo_root/Sources/Yieldd/RunnerNetworkRelay.swift" \
    "$repo_root/.build/network-container/Sources/YielddNetworkProbe/RunnerNetworkRelay.swift"
copy_source "$prototype_dir/PacketSocketTests.swift" \
    "$repo_root/.build/network-container/Tests/YielddNetworkPrototypeTests/PacketSocketTests.swift"

cd "$prototype_dir"
go build -o "$repo_root/.build/network-prototype" .
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -parse-as-library PacketSocket.swift MacProbe.swift \
    "$repo_root/Sources/Yieldd/RunnerNetworkRelay.swift" \
    -o "$repo_root/.build/mac-network-probe"
codesign --force --sign - --entitlements "$repo_root/Packaging/yieldd.entitlements" \
    "$repo_root/.build/mac-network-probe"
swift build --package-path "$repo_root/.build/network-container" --product yieldd-linux-network-probe -j 6
codesign --force --sign - --entitlements "$repo_root/Packaging/yieldd.entitlements" \
    "$repo_root/.build/network-container/.build/debug/yieldd-linux-network-probe"
echo "Built prototype relay and both probes. No services were installed or restarted."
