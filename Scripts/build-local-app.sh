#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(dirname -- "$script_directory")
application="$repository_directory/.build/yieldd.app"
executable="$repository_directory/.build/release/yieldd"
entitlements="$repository_directory/Packaging/yieldd.entitlements"

cd "$repository_directory"
swift build -c release
bash Scripts/build-network-relay.sh
plutil -lint Packaging/Info.plist Packaging/dev.yieldd.agent.plist "$entitlements" >/dev/null

rm -rf "$application"
mkdir -p \
    "$application/Contents/MacOS" \
    "$application/Contents/Helpers" \
    "$application/Contents/Library/LaunchAgents"
cp Packaging/Info.plist "$application/Contents/Info.plist"
cp Packaging/dev.yieldd.agent.plist "$application/Contents/Library/LaunchAgents/"
cp "$executable" "$application/Contents/MacOS/yieldd"
cp .build/yieldd-network-relay "$application/Contents/Helpers/"
codesign --force --sign - --identifier dev.yieldd.network-relay \
    "$application/Contents/Helpers/yieldd-network-relay"

codesign --force --sign - --identifier dev.yieldd \
    --entitlements "$entitlements" \
    "$application"
codesign --verify --strict "$application"
codesign --verify --strict "$application/Contents/Helpers/yieldd-network-relay"
virtualization_entitlement=$(
    codesign --display --entitlements - --xml "$application" 2>/dev/null |
        plutil -extract 'com\.apple\.security\.virtualization' raw -
)
[ "$virtualization_entitlement" = true ]

echo "Built $application"
