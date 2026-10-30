#!/bin/bash
# Build the working tree and run it as SOURCR for quick UI iteration.
# Not a release: nothing is committed, pushed, packaged, or installed to /Applications.
# The dev bundle reuses the release bundle ID so watched repos and settings carry over.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/release-common.sh"

DEV_APP_PATH="$SCRIPT_DIR/build-dev.noindex/$APP_BUNDLE"

note "Building debug binary"
swift build --package-path "$SCRIPT_DIR" -c debug
BIN_PATH="$(swift build --package-path "$SCRIPT_DIR" -c debug --show-bin-path)/$APP_NAME"

note "Assembling $DEV_APP_PATH"
rm -rf "$DEV_APP_PATH"
mkdir -p "$DEV_APP_PATH/Contents/MacOS" "$DEV_APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$DEV_APP_PATH/Contents/MacOS/$APP_NAME"
cp "$SOURCE_PLIST" "$DEV_APP_PATH/Contents/Info.plist"
cp "$SCRIPT_DIR/AppIcon.icns" "$DEV_APP_PATH/Contents/Resources/AppIcon.icns"
# A stable local identity keeps the keychain's "Always Allow" valid across rebuilds;
# ad-hoc signatures change every build and re-prompt for the GitHub token.
DEV_SIGN_IDENTITY="${SOURCR_DEV_SIGN_IDENTITY:-SOURCR Local Signing}"
if security find-identity -p codesigning | grep -q "\"$DEV_SIGN_IDENTITY\""; then
    codesign --force --sign "$DEV_SIGN_IDENTITY" --entitlements "$APP_ENTITLEMENTS_PATH" "$DEV_APP_PATH"
else
    note "Signing identity '$DEV_SIGN_IDENTITY' not found; falling back to ad-hoc (keychain will re-prompt)"
    codesign --force --sign - --entitlements "$APP_ENTITLEMENTS_PATH" "$DEV_APP_PATH"
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    note "Stopping running $APP_NAME"
    pkill -x "$APP_NAME" || true
    for _ in {1..15}; do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

note "Launching dev build"
open "$DEV_APP_PATH"

# Opening a running SOURCR again triggers its reopen handler, which shows the panel.
for _ in {1..20}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && break
    sleep 0.25
done
sleep 1
note "Opening the SOURCR panel"
open "$DEV_APP_PATH"
