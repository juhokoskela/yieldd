#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
prototype_dir="$repo_root/Prototypes/RunnerNetwork"
source "$repo_root/Scripts/prepare-patched-source.sh"
mkdir -p "$repo_root/.build"
prepare_checkout https://github.com/containers/gvisor-tap-vsock.git \
    9cfc86f66679ef0feed0f20ba1df558fe2bef5c6 \
    "$repo_root/.build/network-gvproxy" "$prototype_dir/gvproxy.patch"
cd "$prototype_dir"
go build -trimpath -o "$repo_root/.build/yieldd-network-relay" .
