#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(dirname -- "$script_directory")
executable="$repository_directory/.build/release/yieldd"
entitlements="$repository_directory/Packaging/yieldd.entitlements"
signing_identity=${YIELDD_SIGNING_IDENTITY:--}

cd "$repository_directory"
if [ "$signing_identity" != "-" ] && ! security find-identity -v -p codesigning |
    awk '/"Apple Development:/ && $2 == toupper(ENVIRON["YIELDD_SIGNING_IDENTITY"]) { found = 1 } END { exit !found }'
then
    echo "No valid Apple Development identity matches YIELDD_SIGNING_IDENTITY. Check the fingerprint, private key, and WWDR G3 intermediate." >&2
    exit 1
fi
swift build -c release
bash Scripts/build-network-relay.sh
bash Scripts/build-cache-server.sh
plutil -lint Packaging/Info.plist Packaging/dev.yieldd.agent.plist "$entitlements" >/dev/null

staging=$(mktemp -d "$repository_directory/.build/.yieldd-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
application="$staging/yieldd.app"
mkdir -p \
    "$application/Contents/MacOS" \
    "$application/Contents/Helpers" \
    "$application/Contents/Library/LaunchAgents"
cp Packaging/Info.plist "$application/Contents/Info.plist"
cp Packaging/dev.yieldd.agent.plist "$application/Contents/Library/LaunchAgents/"
cp "$executable" "$application/Contents/MacOS/yieldd"
mkdir -p "$application/Contents/Resources"
cp .build/cache-server-LICENSE "$application/Contents/Resources/"
cp .build/yieldd-network-relay .build/yieldd-cache-server "$application/Contents/Helpers/"
codesign --force --sign "$signing_identity" --identifier dev.yieldd.cache-server \
    "$application/Contents/Helpers/yieldd-cache-server"
codesign --force --sign "$signing_identity" --identifier dev.yieldd.network-relay \
    "$application/Contents/Helpers/yieldd-network-relay"

codesign --force --sign "$signing_identity" --identifier dev.yieldd \
    --entitlements "$entitlements" \
    "$application"
codesign --verify --strict "$application"
codesign --verify --strict "$application/Contents/Helpers/yieldd-network-relay"
codesign --verify --strict "$application/Contents/Helpers/yieldd-cache-server"
virtualization_entitlement=$(
    codesign --display --entitlements - --xml "$application" 2>/dev/null |
        plutil -extract 'com\.apple\.security\.virtualization' raw -
)
[ "$virtualization_entitlement" = true ]

destination="$repository_directory/.build/yieldd.app"
swift - "$application" "$destination" <<'SWIFT'
import Foundation
let staged = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
do {
    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
} catch {
    fputs("Could not publish the verified yieldd.app: \(error.localizedDescription)\n", stderr)
    exit(1)
}
SWIFT
echo "Built $destination"
