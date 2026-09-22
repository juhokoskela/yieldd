# Sourced by the relay and prototype build scripts.
prepare_checkout() (
    local repository="$1" revision="$2" destination="$3" patch="$4"
    shift 4
    local pathspecs=(.) path verification_directory
    # Callers may exclude only build output and exact files regenerated before use.
    for path in "$@"; do pathspecs+=(":(top,literal,exclude)$path"); done
    if [[ ! -d "$destination" ]]; then
        git clone --no-checkout "$repository" "$destination" || return
        git -C "$destination" checkout --detach "$revision" || return
    fi
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]] || {
        echo "Unexpected source revision in $destination; refusing to change it." >&2
        return 1
    }

    verification_directory=$(mktemp -d) || return
    trap 'rm -rf "$verification_directory"' EXIT
    # Compare against a fresh index, not the checkout's staged state or stat cache.
    export GIT_INDEX_FILE="$verification_directory/index"
    git -C "$destination" read-tree "$revision" || return
    git -C "$destination" apply --cached "$patch" || return

    matches_checkout() {
        local extra_files
        # Include ignored files: an ignored source file can still enter a build.
        extra_files=$(git -C "$destination" ls-files --others -- "${pathspecs[@]}") || return
        [[ -z "$extra_files" ]] &&
            git -C "$destination" -c core.fileMode=true -c core.fsmonitor=false \
                diff --quiet --no-ext-diff --no-textconv -- "${pathspecs[@]}"
    }

    if matches_checkout; then return 0; fi
    git -C "$destination" read-tree "$revision" || return
    if ! matches_checkout; then
        echo "Unexpected files or edits in $destination; refusing to build from it. Preserve your changes, move the checkout aside, and retry." >&2
        return 1
    fi
    git -C "$destination" apply "$patch" || return
    git -C "$destination" apply --cached "$patch" || return
    matches_checkout
)
