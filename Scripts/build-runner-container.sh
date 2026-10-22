#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
prototype_dir="$repo_root/Prototypes/RunnerNetwork"
source "$repo_root/Scripts/prepare-runner-container.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export RELEASE_VERSION="$container_version"
export GIT_COMMIT="$container_revision"
swift build --package-path "$container_source" -c release -j 6
# Upstream treats the staging directory as a completed target. An interrupted
# package build must not reuse it as evidence that staging finished.
case "$container_source" in
    "$repo_root"/.build/network-container-*) ;;
    *) echo "Unexpected Container build directory" >&2; exit 1 ;;
esac
rm -rf -- "$container_source/bin/release/staging"
make -C "$container_source" BUILD_CONFIGURATION=release installer-pkg
cp "$container_source/bin/release/container-installer-unsigned.pkg" "$repo_root/.build/yieldd-container-installer.pkg"
printf 'Built %s/.build/yieldd-container-installer.pkg. No services were installed or restarted.\n' "$repo_root"
