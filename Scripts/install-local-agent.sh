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
agent_configuration="${HOME:?}/Library/Application Support/yieldd/agent.json"
agent_label="dev.yieldd.agent"
user_domain="gui/$(id -u)"

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

wait_for_agent_exit() {
    remaining=70
    while launchctl print "$user_domain/$agent_label" >/dev/null 2>&1; do
        if [ "$remaining" -eq 0 ]; then
            echo "Timed out waiting for the existing local agent to stop." >&2
            return 1
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
}

ditto "$source_application" "$staged_application"
codesign --verify --strict "$staged_application"

legacy_installation=false
if [ -e "$installed_application" ]; then
    installed_executable="$installed_application/Contents/MacOS/yieldd"
    if [ ! -x "$installed_executable" ]; then
        echo "$installed_application does not contain an executable yieldd installation." >&2
        exit 1
    fi

    # The old leaf command also exits successfully for `agent uninstall --help`.
    agent_help=$("$installed_executable" agent --help 2>&1)
    case "$agent_help" in
    *"SUBCOMMANDS:"*"uninstall"*)
        "$installed_executable" agent uninstall --preserve-configuration
        ;;
    *)
        legacy_installation=true
        configuration_backup="$staging_directory/agent.json"
        if [ -f "$agent_configuration" ] && [ ! -L "$agent_configuration" ]; then
            cp -p "$agent_configuration" "$configuration_backup"
        fi

        "$installed_executable" service uninstall
        # Versions before `agent uninstall` treated SMAppService.notFound as absence.
        # Remove that legacy job explicitly if it is still loaded.
        if launchctl print "$user_domain/$agent_label" >/dev/null 2>&1; then
            if ! launchctl bootout "$user_domain/$agent_label" \
                && launchctl print "$user_domain/$agent_label" >/dev/null 2>&1; then
                echo "Could not stop the existing local agent." >&2
                exit 1
            fi
        fi
        wait_for_agent_exit
        if [ -f "$configuration_backup" ]; then
            cp -p "$configuration_backup" "$agent_configuration"
        fi
        ;;
    esac

    mv "$installed_application" "$previous_application"
fi

mv "$staged_application" "$installed_application"
replacement_complete=true

if [ "$legacy_installation" = true ]; then
    "$installed_application/Contents/MacOS/yieldd" agent uninstall --preserve-configuration
fi
"$installed_application/Contents/MacOS/yieldd" agent install "$@"

echo "Installed $installed_application"
