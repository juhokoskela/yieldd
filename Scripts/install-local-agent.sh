#!/bin/sh

set -eu

if [ "${1:-}" = --connected ]; then shift; fi
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 --server URL --device-id UUID [--platform linux|macos ...] [--macos-template PATH]" >&2
    exit 64
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(dirname -- "$script_directory")
source_application="$repository_directory/.build/yieldd.app"
applications_directory="${HOME:?}/Applications"
installed_application="$applications_directory/yieldd.app"

if [ -L "$installed_application" ]; then
    echo "Refusing to install over symbolic link $installed_application." >&2
    exit 1
fi

mkdir -p "$applications_directory"
lock="$applications_directory/.yieldd-installer"
if ! mkdir -m 700 "$lock"; then
    echo "An installation is running or was interrupted. Inspect $lock before retrying." >&2
    exit 1
fi
staged="$lock/yieldd.app"
previous="$lock/previous-yieldd.app"
installed="$installed_application/Contents/MacOS/yieldd"
guest_image=local/yieldd-guest:dev
candidate=local/yieldd-guest:installing-$$
backup=local/yieldd-guest:previous-$$
service="gui/$(id -u)/dev.yieldd.agent"
update=false
restore_bundle=false
restore_image=false
candidate_built=false
backup_tagged=false
builder=false
resume=false
restarting=false
committed=false
enrolling=false
old_instance=""

field() { plutil -extract "$1" raw -o - "$lock/status.json"; }
snapshot() { "$installed" agent status --json > "$lock/status.json"; }
still_drained() {
    snapshot && [ "$(field live.instanceID)" = "$old_instance" ] && [ "$(field live.paused)" = true ] &&
        [ "$(field live.activeAssignments)" = 0 ] && [ "$(field live.resumeGeneration)" = "$generation" ]
}
wait_ready() {
    attempts=0
    while [ "$attempts" -lt 60 ]; do
        if snapshot && [ "$(field live.ready)" = true ] && [ "$(field live.paused)" = true ] &&
            [ "$(field live.activeAssignments)" = 0 ] &&
            [ -n "$(field live.instanceID)" ] && [ "$(field live.instanceID)" != "$1" ] &&
            { [ -z "$2" ] || [ "$(field live.buildID)" = "$2" ]; }; then return 0; fi
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    restored=true
    if [ "$enrolling" = true ] && [ "$committed" = false ]; then
        # Registration may already have saved its credential or started a worker.
        restored=false
        echo "Enrollment was interrupted. Inspect agent status and retry install-connected from the installed app." >&2
    elif [ "$committed" = false ]; then
        if [ "$restarting" = true ] && snapshot && [ "$(field live.paused 2>/dev/null)" = false ]; then
            echo "Another caller resumed admissions. Leaving the current app and backup for recovery." >&2
            restored=false
        fi
        if [ "$restored" = true ] && [ "$restore_image" = true ]; then
            container image tag "$backup" "$guest_image" || restored=false
        fi
        if [ "$restored" = true ] && [ "$restore_bundle" = true ] && [ -d "$previous" ]; then
            if [ -e "$installed_application" ]; then mv "$installed_application" "$lock/failed.app" || restored=false; fi
            if [ "$restored" = true ]; then mv "$previous" "$installed_application" || restored=false; fi
        fi
        if [ "$restarting" = true ] && [ "$restored" = true ]; then
            # KeepAlive relaunches a stopped process using the restored bundle.
            current=""
            if snapshot; then current=$(field live.instanceID); fi
            launchctl kill SIGTERM "$service" 2>/dev/null || true
            wait_ready "$current" "" || restored=false
        fi
        if [ "$resume" = true ] && [ "$restored" = true ]; then "$installed" agent resume || restored=false; fi
    fi
    if [ "$builder" = true ]; then container builder stop || status=1; fi
    if [ "$candidate_built" = true ]; then container image delete --force "$candidate" || status=1; fi
    if [ "$restored" = true ]; then
        if [ "$backup_tagged" = true ]; then container image delete --force "$backup" || status=1; fi
        rm -rf "$lock"
    else
        echo "Installation recovery needs attention. Inspect $lock before resuming." >&2
        if [ "$backup_tagged" = true ]; then echo "Previous image: $backup" >&2; fi
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$script_directory/build-local-app.sh"
ditto "$source_application" "$staged"
codesign --verify --strict "$staged"
result=$("$staged/Contents/MacOS/yieldd" agent install-connected --preflight-only "$@")
case "$result" in
    update-linux|update-macos) update=true; platform=${result#update-} ;;
    linux|macos) platform="$result" ;;
    *) echo "Unexpected installation preflight: $result" >&2; exit 1 ;;
esac
if [ "$platform" = linux ]; then
    builder=true
    candidate_built=true
    container build -t "$candidate" "$repository_directory/Guest"
    container builder stop
    builder=false
fi

if [ "$update" = true ]; then
    snapshot
    old_instance=$(field live.instanceID)
    generation=$(field live.resumeGeneration)
    paused=$(field live.paused)
    case "$paused" in true) ;; false) resume=true ;; *) exit 1 ;; esac
    "$installed" agent drain
    still_drained || exit 1
    if [ "$platform" = linux ]; then
        container image tag "$guest_image" "$backup"
        backup_tagged=true
        restore_image=true
    fi
fi
if [ -e "$installed_application" ]; then
    restore_bundle=true
    mv "$installed_application" "$previous"
fi
mv "$staged" "$installed_application"
if [ "$platform" = linux ]; then container image tag "$candidate" "$guest_image"; fi

if [ "$update" = true ]; then
    build_id=$(plutil -extract YielddBuildID raw -o - "$installed_application/Contents/Info.plist")
    [ -n "$build_id" ]
    still_drained || exit 1
    restarting=true
    launchctl kill SIGTERM "$service"
    wait_ready "$old_instance" "$build_id"
    # Once admissions resume the new agent may immediately own guests.
    committed=true
    if [ "$resume" = true ]; then "$installed" agent resume; fi
else
    enrolling=true
    "$installed" agent install-connected "$@"
    committed=true
fi
echo "Installed $installed_application"
