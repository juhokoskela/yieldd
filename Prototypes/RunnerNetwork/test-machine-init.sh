#!/bin/bash
set -euo pipefail

init_script="$1"
test_directory=$(mktemp -d)
trap 'rm -rf "$test_directory"' EXIT

# Keep the real init logic, with its hostname and final init confined to this fixture.
test_init=$(sed \
    -e 's|/etc/hostname|"$TEST_HOSTNAME"|' \
    -e 's|exec /sbin/init|exec /usr/bin/true|' \
    "$init_script")
run_init() {
    rm -f "$test_directory/hostname"
    if ! env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        CONTAINER_MACHINE_ID=yieldd-init-test \
        "CONTAINER_UID=$(id -u)" "CONTAINER_GID=$(id -g)" \
        "TEST_HOSTNAME=$test_directory/hostname" "$@" /bin/sh -c "$test_init"; then
        echo "Machine init failed with ${1:-SSH_AUTH_SOCK unset}." >&2
        return 1
    fi
    if [ "$(cat "$test_directory/hostname")" != yieldd-init-test ]; then
        echo "Machine init wrote the wrong hostname with ${1:-SSH_AUTH_SOCK unset}." >&2
        return 1
    fi
}
run_init
run_init SSH_AUTH_SOCK=
echo "Machine init passed with SSH_AUTH_SOCK unset and empty."
