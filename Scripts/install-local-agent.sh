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
if [ -e "$installed_application" ]; then
    installed_executable="$installed_application/Contents/MacOS/yieldd"
    if [ ! -x "$installed_executable" ]; then
        echo "$installed_application does not contain an executable yieldd installation." >&2
        exit 1
    fi
    exec "$installed_executable" service install "$@"
fi

"$script_directory/build-local-app.sh"
mkdir -p "$applications_directory"
ditto "$source_application" "$installed_application"

exec "$installed_application/Contents/MacOS/yieldd" service install "$@"
