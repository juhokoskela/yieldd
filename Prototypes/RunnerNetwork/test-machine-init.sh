#!/bin/bash
set -euo pipefail

init_script="$1"
test_directory=$(mktemp -d)
trap 'rm -rf "$test_directory"' EXIT

# Keep the real init logic, with its hostname and final init confined to this fixture.
test_init=$(sed \
    -e 's|/etc/hostname|"$TEST_HOSTNAME"|g' \
    -e 's|exec /sbin/init|exec /usr/bin/true|g' \
    "$init_script")
for socket_state in unset empty; do
    rm -f "$test_directory/hostname"
    test_environment=(
        env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin
        CONTAINER_MACHINE_ID=yieldd-init-test
        "CONTAINER_UID=$(id -u)" "CONTAINER_GID=$(id -g)"
        "TEST_HOSTNAME=$test_directory/hostname"
    )
    if [ "$socket_state" = empty ]; then test_environment+=(SSH_AUTH_SOCK=); fi
    "${test_environment[@]}" /bin/sh -c "$test_init"
    [ "$(cat "$test_directory/hostname")" = yieldd-init-test ]
done
echo "Machine init passed with SSH_AUTH_SOCK unset and empty."
