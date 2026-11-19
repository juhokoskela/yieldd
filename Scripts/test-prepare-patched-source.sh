#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
source "$script_directory/prepare-patched-source.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
repository="$fixture/upstream"
patch="$fixture/change.patch"
git init -q "$repository"
git -C "$repository" config user.email test@example.invalid
git -C "$repository" config user.name 'Patch fixture'
printf 'original\n' > "$repository/source"
printf 'unrelated\n' > "$repository/other"
printf 'ignored.go\n' > "$repository/.gitignore"
git -C "$repository" add .
git -C "$repository" -c commit.gpgsign=false commit -qm initial
revision=$(git -C "$repository" rev-parse HEAD)
printf 'patched\n' > "$repository/source"
printf 'added\n' > "$repository/added"
git -C "$repository" add source added
git -C "$repository" diff --cached --binary > "$patch"

new_checkout() {
    checkout="$fixture/$1"
    git clone -q "$repository" "$checkout"
}

expect_rejection() {
    local output="$fixture/rejection"
    if prepare_checkout "$repository" "$revision" "$checkout" "$patch" "$@" > "$output" 2>&1; then
        echo "Accepted unexpected checkout changes: $checkout" >&2
        exit 1
    fi
    grep -q 'refusing to' "$output"
}

# Fresh clones and pristine cached checkouts receive exactly the patch. Reuse
# must preserve the real index, including when a caller stages the patched files.
checkout="$fixture/fresh clone"
prepare_checkout "$repository" "$revision" "$checkout" "$patch"
[[ "$(<"$checkout/source")" == patched && "$(<"$checkout/added")" == added ]]
git -C "$checkout" diff --cached --quiet
prepare_checkout "$repository" "$revision" "$checkout" "$patch"
git -C "$checkout" add source added
staged_tree=$(git -C "$checkout" write-tree)
prepare_checkout "$repository" "$revision" "$checkout" "$patch"
[[ "$(git -C "$checkout" write-tree)" == "$staged_tree" ]]

new_checkout clean-cache
prepare_checkout "$repository" "$revision" "$checkout" "$patch"
[[ "$(<"$checkout/source")" == patched ]]

for state in pristine patched staged; do
    new_checkout "$state-extra-edit"
    if [[ "$state" == patched ]]; then
        prepare_checkout "$repository" "$revision" "$checkout" "$patch"
    fi
    printf 'experimental\n' > "$checkout/other"
    if [[ "$state" == staged ]]; then git -C "$checkout" add other; fi
    before=$(git -C "$checkout" write-tree)
    if [[ "$state" == patched ]]; then
        git -C "$checkout" apply --reverse --check "$patch"
    fi
    expect_rejection
    [[ "$(<"$checkout/other")" == experimental ]]
    [[ "$(git -C "$checkout" write-tree)" == "$before" ]]
    if [[ "$state" != patched ]]; then [[ "$(<"$checkout/source")" == original ]]; fi
done

new_checkout patched-file-edit
prepare_checkout "$repository" "$revision" "$checkout" "$patch"
printf 'extra line\n' >> "$checkout/source"
expect_rejection
[[ "$(tail -1 "$checkout/source")" == 'extra line' ]]

for extra in untracked.go ignored.go; do
    new_checkout "$extra"
    prepare_checkout "$repository" "$revision" "$checkout" "$patch"
    printf 'unexpected source\n' > "$checkout/$extra"
    expect_rejection
    [[ -f "$checkout/$extra" ]]
done

new_checkout deleted-file
prepare_checkout "$repository" "$revision" "$checkout" "$patch"
mv "$checkout/other" "$fixture/deleted-other"
expect_rejection
[[ ! -e "$checkout/other" ]]

new_checkout executable-change
prepare_checkout "$repository" "$revision" "$checkout" "$patch"
git -C "$checkout" config core.fileMode false
chmod +x "$checkout/other"
expect_rejection
[[ -x "$checkout/other" ]]

for flag in assume-unchanged skip-worktree; do
    new_checkout "$flag"
    prepare_checkout "$repository" "$revision" "$checkout" "$patch"
    git -C "$checkout" update-index "--$flag" other
    printf 'hidden edit\n' > "$checkout/other"
    expect_rejection
    [[ "$(<"$checkout/other")" == 'hidden edit' ]]
done

new_checkout wrong-revision
git -C "$checkout" -c user.name=Test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -qm different --allow-empty
expect_rejection

new_checkout declared-generated-files
mkdir -p "$checkout/generated" "$checkout/.build"
printf 'generated\n' > "$checkout/generated/helper.swift"
printf 'build output\n' > "$checkout/.build/output"
prepare_checkout "$repository" "$revision" "$checkout" "$patch" .build generated/helper.swift
prepare_checkout "$repository" "$revision" "$checkout" "$patch" .build generated/helper.swift
printf 'unexpected sibling\n' > "$checkout/generated/other.swift"
expect_rejection .build generated/helper.swift
[[ -f "$checkout/generated/other.swift" ]]

first=$(patched_source_directory "$fixture/cache" "$revision" "$patch")
prepare_checkout "$repository" "$revision" "$first" "$patch"
printf 'another patch\n' > "$repository/source"
git -C "$repository" add source
git -C "$repository" diff --cached --binary > "$fixture/next.patch"
second=$(patched_source_directory "$fixture/cache" "$revision" "$fixture/next.patch")
[[ "$first" != "$second" ]]
prepare_checkout "$repository" "$revision" "$second" "$fixture/next.patch"
[[ "$(<"$first/source")" == patched && "$(<"$second/source")" == 'another patch' ]]
[[ "$(patched_source_directory "$fixture/cache" "$revision" "$patch")" == "$first" ]]
[[ "$(patched_source_directory "$fixture/cache" different-revision "$patch")" != "$first" ]]
prepare_checkout "$repository" "$revision" "$first" "$patch"
checkout="$first"
printf 'unexpected edit\n' > "$checkout/other"
expect_rejection

echo 'Patched-source checks passed; unexpected changes were rejected without discarding them.'
