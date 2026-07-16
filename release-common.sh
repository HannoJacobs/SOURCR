#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="SOURCR"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.hannojacobs.SOURCR"
SCHEME_NAME="SOURCR"
WORKSPACE_PATH="$SCRIPT_DIR/.swiftpm/xcode/package.xcworkspace"
SOURCE_PLIST="$SCRIPT_DIR/Sources/SOURCR/Info.plist"
CHANGELOG_PATH="$SCRIPT_DIR/CHANGELOG.md"
APP_ENTITLEMENTS_PATH="$SCRIPT_DIR/SOURCR.entitlements"
BUILD_DIR="$SCRIPT_DIR/build-release"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
ARCHIVE_BINARY_PATH="$ARCHIVE_PATH/Products/usr/local/bin/$APP_NAME"
ARCHIVED_APP_PATH="$BUILD_DIR/$APP_BUNDLE"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="$SCRIPT_DIR/$DMG_NAME"
INSTALLED_APP_PATH="/Applications/$APP_BUNDLE"
LATEST_LOG_PATH="$HOME/Library/Application Support/SOURCR/Logs/latest.log"

RELEASE_CONFIG_FILE="${SOURCR_RELEASE_CONFIG:-$SCRIPT_DIR/release.env}"
if [ -f "$RELEASE_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$RELEASE_CONFIG_FILE"
fi

SOURCR_CODESIGN_IDENTITY="${SOURCR_CODESIGN_IDENTITY:-}"
SOURCR_CODESIGN_MODE="${SOURCR_CODESIGN_MODE:-adhoc}"
SOURCR_SPCTL_EXPECT="${SOURCR_SPCTL_EXPECT:-}"
VERBOSE_CHANGELOG_MIN_BULLETS=8
VERBOSE_CHANGELOG_MIN_CHARS=1200

fail() {
    echo "Error: $*" >&2
    exit 1
}

note() {
    echo "==> $*"
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
}

require_file() {
    local path="$1"
    [ -e "$path" ] || fail "Missing required path: $path"
}

changelog_entry_for_version() {
    local version="$1"
    awk -v version="$version" '
        $0 == "## " version { in_section=1; found=1; next }
        /^## / && in_section { exit }
        in_section { print }
        END {
            if (!found) {
                exit 2
            }
        }
    ' "$CHANGELOG_PATH"
}

verify_verbose_changelog_entry() {
    local version entry bullet_count char_count

    require_file "$CHANGELOG_PATH"
    version="$(app_version)"
    entry="$(changelog_entry_for_version "$version")" || fail "CHANGELOG.md is missing a section for version $version."

    bullet_count="$(grep -c '^- ' <<<"$entry" || true)"
    char_count="$(printf '%s' "$entry" | tr -d '\n' | wc -c | tr -d '[:space:]')"

    [ "$bullet_count" -ge "$VERBOSE_CHANGELOG_MIN_BULLETS" ] || \
        fail "CHANGELOG.md entry for version $version is not verbose enough: found $bullet_count bullet(s), expected at least $VERBOSE_CHANGELOG_MIN_BULLETS."

    [ "$char_count" -ge "$VERBOSE_CHANGELOG_MIN_CHARS" ] || \
        fail "CHANGELOG.md entry for version $version is not verbose enough: found $char_count characters, expected at least $VERBOSE_CHANGELOG_MIN_CHARS."

    note "CHANGELOG.md verbosity verified for version $version bullets=$bullet_count chars=$char_count"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

app_version() {
    plist_value "$SOURCE_PLIST" "CFBundleShortVersionString"
}

app_build() {
    plist_value "$SOURCE_PLIST" "CFBundleVersion"
}

assert_release_config() {
    case "$SOURCR_CODESIGN_MODE" in
        adhoc|developer_id)
            ;;
        *)
            fail "Unsupported SOURCR_CODESIGN_MODE value: $SOURCR_CODESIGN_MODE"
            ;;
    esac

    if [ -z "$SOURCR_SPCTL_EXPECT" ]; then
        if [ "$SOURCR_CODESIGN_MODE" = "adhoc" ]; then
            SOURCR_SPCTL_EXPECT="rejected"
        else
            SOURCR_SPCTL_EXPECT="accepted"
        fi
    fi

    case "$SOURCR_SPCTL_EXPECT" in
        accepted|rejected|skip)
            ;;
        *)
            fail "Unsupported SOURCR_SPCTL_EXPECT value: $SOURCR_SPCTL_EXPECT"
            ;;
    esac
}

codesign_identity_label() {
    if [ "$SOURCR_CODESIGN_MODE" = "developer_id" ]; then
        [ -n "$SOURCR_CODESIGN_IDENTITY" ] || fail "SOURCR_CODESIGN_IDENTITY is required for developer_id mode."
        printf '%s' "$SOURCR_CODESIGN_IDENTITY"
    else
        printf '%s' "-"
    fi
}

assert_bundle_metadata() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"

    require_file "$info_plist"
    [ "$(plist_value "$info_plist" "CFBundleIdentifier")" = "$BUNDLE_ID" ] || \
        fail "Bundle identifier mismatch in $info_plist"
    [ "$(plist_value "$info_plist" "CFBundleExecutable")" = "$APP_NAME" ] || \
        fail "Bundle executable mismatch in $info_plist"
    [ "$(plist_value "$info_plist" "LSUIElement")" = "true" ] || \
        fail "LSUIElement must be true for menu-bar app"
}

verify_signed_app() {
    local app_path="$1"
    local codesign_output
    local spctl_output
    local spctl_status=0

    assert_bundle_metadata "$app_path"

    codesign_output="$(codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
    echo "$codesign_output"

    codesign --verify --strict --deep --verbose=2 "$app_path"

    if [ "$SOURCR_CODESIGN_MODE" = "developer_id" ]; then
        echo "$codesign_output" | grep -q "flags=.*runtime" || \
            fail "Expected hardened runtime for developer_id mode."
    fi

    set +e
    spctl_output="$(spctl -a -t exec -vv "$app_path" 2>&1)"
    spctl_status=$?
    set -e
    echo "$spctl_output"

    case "$SOURCR_SPCTL_EXPECT" in
        accepted)
            [ "$spctl_status" -eq 0 ] || fail "spctl unexpectedly rejected $app_path"
            ;;
        rejected)
            [ "$spctl_status" -ne 0 ] || fail "spctl unexpectedly accepted ad-hoc $app_path"
            ;;
        skip)
            note "Skipping spctl expectation check"
            ;;
    esac
}

archive_build_products_dir() {
    local derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"
    local candidates

    candidates="$(find "$derived_data_root" -type d -path "*/ArchiveIntermediates/${SCHEME_NAME}/BuildProductsPath/Release" 2>/dev/null | head -n 5 || true)"
    if [ -z "$candidates" ]; then
        fail "Could not locate ArchiveIntermediates BuildProductsPath/Release for scheme $SCHEME_NAME"
    fi

    # Prefer the newest matching directory.
    printf '%s\n' "$candidates" | while IFS= read -r path; do
        printf '%s\t%s\n' "$(stat -f '%m' "$path")" "$path"
    done | sort -nr | head -n 1 | cut -f2-
}
