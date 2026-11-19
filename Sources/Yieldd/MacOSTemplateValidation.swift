import Foundation

enum MacOSTemplateValidation {
    static let timeout: TimeInterval = 10 * 60

    static let simulatorSelectionScript = #"""
    ObjC.import('Foundation');
    function run(argv) {
        var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
        if (text.isNil()) throw new Error('Could not read simulator runtime metadata. Check the CoreSimulator runtime listing.');
        var metadata;
        try {
            metadata = JSON.parse(ObjC.unwrap(text));
        } catch (error) {
            throw new Error('Malformed simulator runtime metadata: ' + error.message);
        }
        if (!metadata || !Array.isArray(metadata.runtimes)) throw new Error('Malformed simulator runtime metadata: expected a runtimes array.');
        var runtimes = metadata.runtimes;
        for (var i = 0; i < runtimes.length; i++) {
            var runtime = runtimes[i];
            if (!runtime || typeof runtime.identifier !== 'string' || typeof runtime.isAvailable !== 'boolean') {
                throw new Error('Malformed simulator runtime metadata: invalid runtime entry.');
            }
            if (!runtime.isAvailable || runtime.identifier.indexOf('com.apple.CoreSimulator.SimRuntime.iOS-') !== 0) continue;
            var types = runtime.supportedDeviceTypes;
            if (!Array.isArray(types)) throw new Error('Malformed simulator runtime metadata: expected supportedDeviceTypes.');
            for (var j = 0; j < types.length; j++) {
                if (!types[j] || typeof types[j].identifier !== 'string') {
                    throw new Error('Malformed simulator runtime metadata: invalid device type entry.');
                }
                if (types[j].identifier.indexOf('com.apple.CoreSimulator.SimDeviceType.iPhone-') === 0) {
                    return runtime.identifier + ' ' + types[j].identifier;
                }
            }
        }
        throw new Error('No available compatible iPhone simulator was found. Install an iOS Simulator runtime in Xcode Settings > Components in the template.');
    }
    """#

    static func run(backend: any RunnerBackend, id: RunnerID) throws {
        try backend.exec(
            ["/bin/bash", "-s"],
            standardInput: Data(script.utf8),
            timeout: timeout,
            outputCapture: .tail(maxBytes: MacOSGuestSSH.outputTailBytes),
            as: .runner,
            on: id
        )
    }

    // Sent over SSH to the disposable clone; no additional guest helper needs installing.
    static let script = #"""
    set -euo pipefail
    umask 077

    fail() {
        echo "$1" >&2
        exit 1
    }

    /usr/bin/xcodebuild -version || fail "Install full Xcode in the template and select it with xcode-select."
    /usr/bin/xcodebuild -checkFirstLaunchStatus || fail "Open Xcode in the template, accept its license, and finish installing its components."
    /usr/bin/xcrun swift --version || fail "The selected Xcode toolchain is incomplete; finish Xcode setup in the template."
    simctl="$(/usr/bin/xcrun --find simctl)" || fail "Select a full Xcode installation in the template; Command Line Tools alone do not include CoreSimulator."
    work_directory="$(/usr/bin/mktemp -d /tmp/yieldd-template-test.XXXXXX)"
    "$simctl" list runtimes --json > "$work_directory/runtimes.json" || fail "CoreSimulator cannot list runtimes; check Xcode setup and automatic login for runner in the template."

    selection="$(/usr/bin/osascript -l JavaScript - "$work_directory/runtimes.json" <<'JAVASCRIPT'
    \#(simulatorSelectionScript)
    JAVASCRIPT
    )"
    read -r runtime device_type <<< "$selection"
    device="$("$simctl" create yieldd-template-test "$device_type" "$runtime")" || fail "CoreSimulator could not create a device; repair the selected iOS runtime in the template."
    "$simctl" bootstatus "$device" -b || fail "Simulator boot or startup failed; check the iOS runtime, runner console login, and Xcode first-launch setup in the template."
    "$simctl" io "$device" screenshot "$work_directory/screenshot.png" || fail "Simulator screenshot failed; verify the template has a working GUI login session."
    [[ -s "$work_directory/screenshot.png" ]] || fail "CoreSimulator produced an empty screenshot."
    """#
}
