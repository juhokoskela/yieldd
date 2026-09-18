#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

configuration="$(GH_TOKEN=configuration-test YIELDD_CLIENT_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
    YIELDD_REPOSITORY=example/application YIELDD_INFRASTRUCTURE=example/infrastructure \
    YIELDD_FALLBACK_RUNNER='"ubuntu-24.04"' YIELDD_MACOS_FALLBACK_RUNNER='' \
    YIELDD_DEVICE_ID=01234567-89ab-4def-8123-456789abcdef \
    docker compose --env-file /dev/null -f compose.yaml config --format json)"

jq -e '.services.coordinator |
    .network_mode == null and (.networks | has("default")) and
    (.ports | length) == 1 and .ports[0].host_ip == "127.0.0.1" and
    .ports[0].target == 8787 and .ports[0].published == "8787" and
    .cpus == 1 and (.mem_limit | tonumber) == 536870912 and .pids_limit == 128 and
    .read_only == true and .cap_drop == ["ALL"] and
    .security_opt == ["no-new-privileges:true"] and
    (.command | index("0.0.0.0:8787")) != null and
    (.command | index("--allow-non-loopback-client-listen")) != null' <<< "$configuration" >/dev/null

echo 'Compose limits and loopback-only port publication validated.'
