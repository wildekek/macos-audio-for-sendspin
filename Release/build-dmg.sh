#!/bin/bash
# Build the disk image: the app, with the audio driver inside (it installs the driver itself
# on first launch), next to an Applications shortcut to drag it to.
# Output: build/release/Sendspin-<version>.dmg
#
#   Release/build-dmg.sh
#
# Signing and notarization are switched on by environment variables:
#   DEVELOPER_ID_APP   "Developer ID Application: Name (TEAMID)": signs the app, driver and disk image
#   NOTARY_PROFILE     keychain profile from `xcrun notarytool store-credentials`
# Without them the app is signed ad hoc: fine for testing on this Mac, not for distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
APP_NAME="Sendspin"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/App/project.yml")
DRIVER_VERSION=$(sed -n 's/^set(DRIVER_VERSION "\(.*\)")/\1/p' "$ROOT/Driver/CMakeLists.txt")
# The driver has its own version, changed only when the driver changes: the app offers to
# update an installed driver whose version differs, which asks for a password.
if [[ -z "$VERSION" || -z "$DRIVER_VERSION" ]]; then
    echo "No version: app '$VERSION' (App/project.yml), driver '$DRIVER_VERSION' (Driver/CMakeLists.txt)" >&2
    exit 1
fi
if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID_APP:-}" ]]; then
    echo "Notarizing needs DEVELOPER_ID_APP" >&2
    exit 1
fi
SIGN_ID="${DEVELOPER_ID_APP:--}"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> App $VERSION, driver $DRIVER_VERSION"
(cd "$ROOT/App" && xcodegen generate --quiet)
# No injected get-task-allow entitlement: notarization rejects it.
sign_settings=(CODE_SIGN_IDENTITY="$SIGN_ID" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
    team=$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$DEVELOPER_ID_APP")
    sign_settings+=(DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp)
fi
xcodebuild -project "$ROOT/App/Sendspin.xcodeproj" -scheme Sendspin \
    -configuration Release -destination "generic/platform=macOS" -derivedDataPath "$OUT/app" \
    -quiet "${sign_settings[@]}" build

APP="$OUT/app/Build/Products/Release/$APP_NAME.app"
DRIVER="$APP/Contents/Library/Audio/Plug-Ins/HAL/Sendspin.driver"
# Catch broken signatures here rather than after a notarization round trip.
codesign --verify --strict --deep "$APP"
codesign --verify --strict "$DRIVER"

echo "==> Disk image"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/$APP_NAME.app"
DMG="$OUT/Sendspin-$VERSION.dmg"
create-dmg --volname "$APP_NAME" --window-size 540 340 --icon-size 128 \
    --icon "$APP_NAME.app" 140 150 --hide-extension "$APP_NAME.app" --app-drop-link 400 150 \
    --no-internet-enable "$DMG" "$OUT/dmg" >/dev/null
if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
    codesign --sign "$DEVELOPER_ID_APP" --timestamp "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarize (takes a few minutes)"
    # notarytool exits 0 for a rejected submission too, so check the status.
    result=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    status=$(plutil -extract status raw - <<<"$result")
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization status: $status" >&2
        xcrun notarytool log "$(plutil -extract id raw - <<<"$result")" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple "$DMG"
fi

echo "Built $DMG"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Not notarized: for testing on this Mac only, not for distribution."
fi
