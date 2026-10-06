#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/prepare-runner-container.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build --package-path "$container_source" -c release -j 6
make -C "$container_source" BUILD_CONFIGURATION=release installer-pkg
printf 'Built %s/bin/release/container-installer-unsigned.pkg. No services were installed or restarted.\n' "$container_source"
