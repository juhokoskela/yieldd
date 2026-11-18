#!/bin/sh

set -eu

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
builder_active=false
cleanup() {
    result=$?
    trap - EXIT
    if "$builder_active"; then container builder stop || :; fi
    rm -rf "$lock"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -e "$installed_application" ]; then
    echo "Drain and uninstall the existing agent, then move $installed_application aside before installing." >&2
    exit 1
fi

"$script_directory/build-local-app.sh"
ditto "$source_application" "$staged"
codesign --verify --strict "$staged"
platform=$("$staged/Contents/MacOS/yieldd" agent install --preflight-only "$@")
case "$platform" in
    linux)
        builder_active=true
        container build -t local/yieldd-guest:dev "$repository_directory/Guest"
        container builder stop
        builder_active=false
        ;;
    macos) ;;
    *) echo "Unexpected installation preflight: $platform" >&2; exit 1 ;;
esac

if [ -e "$installed_application" ] || [ -L "$installed_application" ]; then
    echo "Install destination appeared during staging: $installed_application" >&2
    exit 1
fi
mv "$staged" "$installed_application"
# Registration may have saved credentials or started a worker even if it reports failure.
"$installed_application/Contents/MacOS/yieldd" agent install "$@"
echo "Installed $installed_application"
