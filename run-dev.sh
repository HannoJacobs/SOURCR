#!/bin/bash
# Build the working tree and install it as /Applications/SOURCR.app for quick UI iteration.
# Not a release: nothing is committed, pushed, or packaged. Installing over the single
# /Applications copy means Spotlight and Finder always open what was last built, with no
# second SOURCR lying around; the next full send replaces it with the Release build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/release-common.sh"

STAGING_APP_PATH="$SCRIPT_DIR/build-dev.noindex/$APP_BUNDLE"

note "Building debug binary"
swift build --package-path "$SCRIPT_DIR" -c debug
BIN_PATH="$(swift build --package-path "$SCRIPT_DIR" -c debug --show-bin-path)/$APP_NAME"

note "Assembling $STAGING_APP_PATH"
rm -rf "$STAGING_APP_PATH"
mkdir -p "$STAGING_APP_PATH/Contents/MacOS" "$STAGING_APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$STAGING_APP_PATH/Contents/MacOS/$APP_NAME"
cp "$SOURCE_PLIST" "$STAGING_APP_PATH/Contents/Info.plist"
cp "$SCRIPT_DIR/AppIcon.icns" "$STAGING_APP_PATH/Contents/Resources/AppIcon.icns"
# A stable local identity keeps the keychain's "Always Allow" valid across rebuilds;
# ad-hoc signatures change every build and re-prompt for the GitHub token.
DEV_SIGN_IDENTITY="${SOURCR_DEV_SIGN_IDENTITY:-SOURCR Local Signing}"
if security find-identity -p codesigning | grep -q "\"$DEV_SIGN_IDENTITY\""; then
    codesign --force --sign "$DEV_SIGN_IDENTITY" --entitlements "$APP_ENTITLEMENTS_PATH" "$STAGING_APP_PATH"
else
    note "Signing identity '$DEV_SIGN_IDENTITY' not found; falling back to ad-hoc (keychain will re-prompt)"
    codesign --force --sign - --entitlements "$APP_ENTITLEMENTS_PATH" "$STAGING_APP_PATH"
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    note "Stopping running $APP_NAME"
    pkill -x "$APP_NAME" || true
    for _ in {1..15}; do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

note "Installing dev build to $INSTALLED_APP_PATH"
rm -rf "$INSTALLED_APP_PATH"
ditto "$STAGING_APP_PATH" "$INSTALLED_APP_PATH"
rm -rf "$STAGING_APP_PATH"

note "Launching $INSTALLED_APP_PATH"
open "$INSTALLED_APP_PATH"

# Opening a running SOURCR again triggers its reopen handler, which shows the panel.
for _ in {1..20}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && break
    sleep 0.25
done
sleep 1
note "Opening the SOURCR panel"
open "$INSTALLED_APP_PATH"
