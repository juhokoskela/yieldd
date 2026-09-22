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

owners=()
for attempt in 1 2; do
    instance="$(docker create --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges --mount "type=volume,src=$volume,dst=/var/lib/yieldd" \
        --env GH_TOKEN=offline-test "$image" \
        --repositories example/glasseq,example/yieldd,example/infrastructure,example/glasseqserver \
        --local-only-repositories example/infrastructure --infrastructure example/infrastructure \
        --device-id 01234567-89ab-4def-8123-456789abcdef \
        --fallback-runner '"ubuntu-24.04"' --macos-fallback-runner '"macos-26"' \
        --state-dir /var/lib/yieldd --recover)"
    containers+=("$instance")
    docker start --attach "$instance"
    [[ "$(docker inspect --format '{{.State.ExitCode}}' "$instance")" == 0 ]]
    index=0
    for repository in glasseq yieldd infrastructure glasseqserver; do
        for platform in linux macos; do
            state="$(docker cp "$instance:/var/lib/yieldd/queues/example/$repository/$platform/state.json" - | tar -xOf -)"
            current_owner="$(jq -er '.owner' <<< "$state")"
            jq -e --arg repository "example/$repository" --arg platform "$platform" \
                '.lease == null and .config.repository == $repository and
                (.config.platform // "linux") == $platform and
                (.config.local_only // false) == ($repository == "example/infrastructure")' <<< "$state" >/dev/null
            if [[ "$attempt" == 1 ]]; then
                if (( ${#owners[@]} )); then
                    for owner in "${owners[@]}"; do [[ "$owner" != "$current_owner" ]]; done
                fi
                owners+=("$current_owner")
            else
                [[ "$current_owner" == "${owners[$index]}" ]]
            fi
            index=$((index + 1))
        done
    done
done

echo 'Image runs without root or network access and preserves eight independent queue identities across containers.'
