#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 [OWNER/REPOSITORY ...] [--macos OWNER/REPOSITORY ... --macos-template PATH]" >&2
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

"$script_directory/build-local-app.sh"
mkdir -p "$applications_directory"
staging_directory=$(mktemp -d "$applications_directory/.yieldd-install.XXXXXX")
staged_application="$staging_directory/yieldd.app"
previous_application="$staging_directory/previous-yieldd.app"
guest_image="local/yieldd-guest:dev"
staged_image="local/yieldd-guest:installing-$$"
replacement_complete=false
stop_builder=false
remove_staged_image=false

cleanup() {
    status=$?
    trap - 0
    if [ "$stop_builder" = true ] && ! container builder stop; then
        if [ "$status" -eq 0 ]; then
            status=1
        fi
    fi
    if [ "$remove_staged_image" = true ] \
        && ! container image delete --force "$staged_image"; then
        if [ "$status" -eq 0 ]; then
            status=1
        fi
    fi
    if [ "$replacement_complete" = false ] \
        && [ -d "$previous_application" ] \
        && [ ! -e "$installed_application" ]; then
        mv "$previous_application" "$installed_application"
    fi
    rm -rf "$staging_directory"
    exit "$status"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ditto "$source_application" "$staged_application"
codesign --verify --strict "$staged_application"
guest_platform=$("$staged_application/Contents/MacOS/yieldd" agent install \
    --preflight-only "$@")
case "$guest_platform" in
    linux|macos) ;;
    *) echo "Unexpected agent preflight result: $guest_platform" >&2; exit 1 ;;
esac
if [ "$guest_platform" = linux ]; then
    stop_builder=true
    remove_staged_image=true
    container build -t "$staged_image" "$repository_directory/Guest"
    container builder stop
    stop_builder=false
fi

if [ -e "$installed_application" ]; then
    installed_executable="$installed_application/Contents/MacOS/yieldd"
    if [ ! -x "$installed_executable" ]; then
        echo "$installed_application does not contain an executable yieldd installation." >&2
        exit 1
    fi

    "$installed_executable" agent uninstall
    mv "$installed_application" "$previous_application"
fi

if [ "$guest_platform" = linux ]; then
    container image delete --force "$guest_image"
    container image tag "$staged_image" "$guest_image"
    container image delete "$staged_image"
    remove_staged_image=false
fi

mv "$staged_application" "$installed_application"
replacement_complete=true

"$installed_application/Contents/MacOS/yieldd" agent install "$@"

echo "Installed $installed_application"
