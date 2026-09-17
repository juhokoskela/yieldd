#!/usr/bin/env bash
set -euo pipefail

image="${1:-local/yieldd-coordinator:dev}"
volume="$(docker volume create)"
containers=()
cleanup() {
    if (( ${#containers[@]} )); then docker rm -f "${containers[@]}" >/dev/null; fi
    docker volume rm "$volume" >/dev/null
}
trap cleanup EXIT

[[ "$(docker image inspect --format '{{.Config.User}}' "$image")" == '65532:65532' ]]
docker run --rm --network none --read-only "$image" --help

owner=''
for attempt in 1 2; do
    instance="$(docker create --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges --mount "type=volume,src=$volume,dst=/var/lib/yieldd" \
        --env GH_TOKEN=offline-test "$image" \
        --repository example/application --infrastructure example/infrastructure \
        --fallback-runner '"ubuntu-24.04"' --state-dir /var/lib/yieldd --recover)"
    containers+=("$instance")
    docker start --attach "$instance"
    [[ "$(docker inspect --format '{{.State.ExitCode}}' "$instance")" == 0 ]]
    state="$(docker cp "$instance:/var/lib/yieldd/state.json" - | tar -xOf -)"
    current_owner="$(jq -er '.owner' <<< "$state")"
    jq -e '.lease == null' <<< "$state" >/dev/null
    if [[ "$attempt" == 1 ]]; then
        owner="$current_owner"
    else
        [[ "$current_owner" == "$owner" ]]
    fi
done

echo 'Image runs without root or network access and preserves recovery state across containers.'
