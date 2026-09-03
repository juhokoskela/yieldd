#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(dirname -- "$script_directory")
application="$repository_directory/.build/yieldd.app"
executable="$repository_directory/.build/release/yieldd"

cd "$repository_directory"
swift build -c release
plutil -lint Packaging/Info.plist Packaging/dev.yieldd.agent.plist >/dev/null

rm -rf "$application"
mkdir -p \
    "$application/Contents/MacOS" \
    "$application/Contents/Resources" \
    "$application/Contents/Library/LaunchAgents"
cp Packaging/Info.plist "$application/Contents/Info.plist"
cp Packaging/dev.yieldd.agent.plist "$application/Contents/Library/LaunchAgents/"
cp "$executable" "$application/Contents/MacOS/yieldd"
cp "$executable" "$application/Contents/Resources/yieldd-agent"

codesign --force --sign - --identifier dev.yieldd.agent \
    "$application/Contents/Resources/yieldd-agent"
codesign --force --sign - --identifier dev.yieldd "$application"
codesign --verify --deep --strict "$application"

echo "Built $application"
