#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 OWNER/REPOSITORY [OWNER/REPOSITORY ...]" >&2
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
replacement_complete=false

cleanup() {
    status=$?
    trap - 0
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
"$staged_application/Contents/MacOS/yieldd" agent install \
    --preflight-only "$@"

if [ -e "$installed_application" ]; then
    installed_executable="$installed_application/Contents/MacOS/yieldd"
    if [ ! -x "$installed_executable" ]; then
        echo "$installed_application does not contain an executable yieldd installation." >&2
        exit 1
    fi

    "$installed_executable" agent uninstall
    mv "$installed_application" "$previous_application"
fi

mv "$staged_application" "$installed_application"
replacement_complete=true

"$installed_application/Contents/MacOS/yieldd" agent install "$@"

echo "Installed $installed_application"
