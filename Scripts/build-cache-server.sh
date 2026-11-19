#!/bin/bash
set -euo pipefail

case "$#:${1:-}" in
    0:|1:--test) ;;
    *) echo "Usage: $0 [--test]" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/Scripts/prepare-patched-source.sh"
revision=8786aa9a0b3d057aebad7d5932f36862d67c6299
patch="$repo_root/Cache/cache-server.patch"
source_dir=$(patched_source_directory "$repo_root/.build/cache-server" "$revision" "$patch")
mkdir -p "$repo_root/.build"
prepare_checkout https://github.com/falcondev-oss/github-actions-cache-server.git "$revision" "$source_dir" "$patch"
export YIELDD_CACHE_ADAPTER="$repo_root/Cache/host.rs"
export CARGO_TARGET_DIR="$repo_root/.build/cache-server-target"
cd "$source_dir"
# The shipped service only needs the compiler at build time.
rustup toolchain install 1.99 --profile minimal --no-self-update
export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
if [[ "${1:-}" == --test ]]; then
    exec cargo +1.99 test --release --locked --bin github-actions-cache-server
fi
cargo +1.99 build --release --locked --bin github-actions-cache-server
cp "$CARGO_TARGET_DIR/release/github-actions-cache-server" "$repo_root/.build/yieldd-cache-server"
cp LICENSE "$repo_root/.build/cache-server-LICENSE"
