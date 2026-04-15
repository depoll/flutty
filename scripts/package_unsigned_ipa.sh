#!/bin/bash
# Packages a Flutter iOS device build into an unsigned IPA.

set -euo pipefail

BUILD_DIR=${1:-build/ios/iphoneos}
OUTPUT_PATH=${2:-build/ios/ipa/Runner-unsigned.ipa}
OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
STAGING_DIR="$(dirname "$OUTPUT_DIR")/unsigned"

APP_PATH=$(find "$BUILD_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)
if [ -z "$APP_PATH" ]; then
    echo "Expected a built .app bundle under $BUILD_DIR, but none was found."
    ls -la "$BUILD_DIR" || true
    exit 1
fi
APP_BUNDLE_NAME=$(basename "$APP_PATH")

bundle_executable_path() {
    local bundle_path="$1"
    local info_plist="$bundle_path/Info.plist"
    if [ ! -f "$info_plist" ]; then
        echo "Expected Info.plist at $info_plist" >&2
        return 1
    fi

    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist"
}

add_swift_scan_args() {
    local bundle_path="$1"
    local executable_name
    executable_name=$(bundle_executable_path "$bundle_path")
    SWIFT_SCAN_ARGS+=("--scan-executable" "$bundle_path/$executable_name")

    if [ -d "$bundle_path/Frameworks" ]; then
        SWIFT_SCAN_ARGS+=("--scan-folder" "$bundle_path/Frameworks")
    fi
}

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Payload" "$OUTPUT_DIR"
OUTPUT_PATH="$(cd "$OUTPUT_DIR" && pwd)/$(basename "$OUTPUT_PATH")"
ditto "$APP_PATH" "$STAGING_DIR/Payload/$APP_BUNDLE_NAME"

SWIFT_SUPPORT_DIR="$STAGING_DIR/SwiftSupport/iphoneos"
mkdir -p "$SWIFT_SUPPORT_DIR"
declare -a SWIFT_SCAN_ARGS=()
add_swift_scan_args "$STAGING_DIR/Payload/$APP_BUNDLE_NAME"
if [ -d "$STAGING_DIR/Payload/$APP_BUNDLE_NAME/PlugIns" ]; then
    while IFS= read -r -d '' appex_path; do
        add_swift_scan_args "$appex_path"
    done < <(find "$STAGING_DIR/Payload/$APP_BUNDLE_NAME/PlugIns" -mindepth 1 -maxdepth 1 -name '*.appex' -type d -print0)
fi
xcrun swift-stdlib-tool --copy --platform iphoneos --destination "$SWIFT_SUPPORT_DIR" "${SWIFT_SCAN_ARGS[@]}"
if ! find "$SWIFT_SUPPORT_DIR" -type f | grep -q .; then
    rm -rf "$STAGING_DIR/SwiftSupport"
fi

(
    cd "$STAGING_DIR"
    zip_inputs=(Payload)
    if [ -d SwiftSupport ]; then
        zip_inputs+=(SwiftSupport)
    fi
    zip -qry "$OUTPUT_PATH" "${zip_inputs[@]}"
)
