#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
prototype_dir="$repo_root/Prototypes/RunnerNetwork"
source "$prototype_dir/source-paths.sh"
mkdir -p "$repo_root/.build"
prepare_checkout https://github.com/containers/gvisor-tap-vsock.git \
    "$gvproxy_revision" "$gvproxy_source" "$prototype_dir/gvproxy.patch"
cd "$prototype_dir"
cp go.mod "$relay_module"
cp go.sum "${relay_module%.mod}.sum"
go mod edit -modfile "$relay_module" -replace "github.com/containers/gvisor-tap-vsock=$gvproxy_source"
go build -modfile "$relay_module" -buildvcs=false -trimpath -o "$repo_root/.build/yieldd-network-relay" .
