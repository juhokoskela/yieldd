# Sourced by the relay and prototype build scripts.
prepare_checkout() {
    local repository="$1" revision="$2" destination="$3" patch="$4"
    if [[ ! -d "$destination" ]]; then
        git clone --no-checkout "$repository" "$destination"
        git -C "$destination" checkout --detach "$revision"
    fi
    [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]] || {
        echo "Unexpected source revision in $destination; refusing to change it." >&2
        exit 1
    }
    if git -C "$destination" apply --check "$patch" 2>/dev/null; then
        git -C "$destination" apply "$patch"
    else
        git -C "$destination" apply --reverse --check "$patch"
    fi
}
