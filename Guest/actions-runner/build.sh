#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo "usage: build.sh linux-arm64|osx-arm64 NEW_RUNNER_DIRECTORY" >&2
    exit 2
fi
version=2.338.2
revision=d1eb12d4b115c301201de27d667284e1a80f2ab5
source_sha=a0fa836ec067173a6de1d5afc1ae7c9f5e23cd576884385d6d020c7a529c6e5e
sdk_version=8.0.427
case "$1" in
    linux-arm64) os=OS_LINUX; release_sha=670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945 ;;
    osx-arm64) os=OS_OSX; release_sha=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388 ;;
    *) echo "unsupported runner platform: $1" >&2; exit 2 ;;
esac
platform=$1
directory=$(cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")
if [[ -e "$directory" || -L "$directory" ]]; then
    echo "Runner destination already exists: $directory" >&2
    exit 1
fi
patch_directory=$(cd -- "$(dirname -- "$0")" && pwd)
sdk_parent=$(dotnet --list-sdks | sed -n 's/^8\.0\.427 \[\(.*\)\]$/\1/p')
compiler="$sdk_parent/$sdk_version/Roslyn/bincore/csc.dll"
if [[ ! -f "$compiler" ]]; then
    echo "Install the .NET $sdk_version SDK to build the yieldd Actions worker." >&2
    exit 1
fi
scratch=$(mktemp -d "$directory.build.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
cd "$scratch"
mkdir source release
if command -v sha256sum >/dev/null; then digest=(sha256sum); else digest=(shasum -a 256); fi
curl --fail --location --silent --show-error --retry 3 \
    "https://codeload.github.com/actions/runner/tar.gz/$revision" -o source.tar.gz
curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/actions/runner/releases/download/v$version/actions-runner-$platform-$version.tar.gz" -o release.tar.gz
printf '%s  %s\n' "$source_sha" source.tar.gz "$release_sha" release.tar.gz | "${digest[@]}" -c -
tar -xzf source.tar.gz --strip-components=1 -C source
tar -xzf release.tar.gz -C release
GIT_CEILING_DIRECTORIES="$scratch" git -C source apply "$patch_directory/local-cache.patch"

# Compile one managed assembly against the exact binaries the guest will load.
# The listener, SDK dependencies, bundled runtime and Node executables stay at the release pin.
cd source/src/Runner.Worker
refs=()
for dll in "$scratch"/release/bin/*.dll; do
    [[ ${dll##*/} == Runner.Worker.dll ]] || refs+=("-reference:$dll")
done
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find . -type f -name '*.cs' | LC_ALL=C sort)
printf '[assembly: System.Reflection.AssemblyVersion("%s.0")]\n' "$version" > "$scratch/Version.cs"
dotnet "$compiler" -nologo -noconfig -nostdlib+ -target:exe -optimize+ -deterministic+ \
    "-define:$os;ARM64;TRACE" "-pathmap:$scratch=/_/runner" \
    -resource:action_yaml.json,GitHub.Runner.Worker.action_yaml.json \
    "-out:$scratch/release/bin/Runner.Worker.dll" "${refs[@]}" "${sources[@]}" "$scratch/Version.cs"
cd "$scratch/release"
"${digest[@]}" bin/Runner.Worker.dll > bin/yieldd-cache-worker.sha256
mv "$scratch/release" "$directory"
