#!/bin/bash
# Build the installer package: the app into /Applications, the driver into
# /Library/Audio/Plug-Ins/HAL. Output: build/release/macOS-Audio-for-Sendspin-<version>.pkg
#
#   Installer/build-pkg.sh
#
# Signing and notarization are switched on by environment variables:
#   DEVELOPER_ID_APP        "Developer ID Application: Name (TEAMID)", signs the app and driver
#   DEVELOPER_ID_INSTALLER  "Developer ID Installer: Name (TEAMID)", signs the package
#   NOTARY_PROFILE          keychain profile from `xcrun notarytool store-credentials`
# Without them the package is unsigned: fine for `sudo installer -pkg … -target /` on this Mac,
# not for distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
APP_NAME="macOS Audio for Sendspin"
DRIVER_BUNDLE="MacOSAudioForSendspin.driver"
PKG_ID="eu.vooijs.MacOSAudioForSendspin.pkg"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/App/project.yml")
DRIVER_VERSION=$(sed -n 's/^set(DRIVER_VERSION "\(.*\)")/\1/p' "$ROOT/Driver/CMakeLists.txt")
if [[ -z "$VERSION" || "$VERSION" != "$DRIVER_VERSION" ]]; then
    echo "Version mismatch: app '$VERSION' (App/project.yml), driver '$DRIVER_VERSION' (Driver/CMakeLists.txt)" >&2
    exit 1
fi
if [[ -n "${NOTARY_PROFILE:-}" && ( -z "${DEVELOPER_ID_APP:-}" || -z "${DEVELOPER_ID_INSTALLER:-}" ) ]]; then
    echo "Notarizing needs DEVELOPER_ID_APP and DEVELOPER_ID_INSTALLER" >&2
    exit 1
fi
SIGN_ID="${DEVELOPER_ID_APP:--}"

rm -rf "$OUT"
mkdir -p "$OUT/components"

echo "==> Driver ($VERSION)"
cmake -S "$ROOT/Driver" -B "$OUT/driver" -DCODESIGN_ID="$SIGN_ID" >/dev/null
cmake --build "$OUT/driver"

echo "==> App ($VERSION)"
(cd "$ROOT/App" && xcodegen generate --quiet)
# No injected get-task-allow entitlement: notarization rejects it.
sign_settings=(CODE_SIGN_IDENTITY="$SIGN_ID" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
    team=$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$DEVELOPER_ID_APP")
    sign_settings+=(DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp)
fi
xcodebuild -project "$ROOT/App/MacOSAudioForSendspin.xcodeproj" -scheme MacOSAudioForSendspin \
    -configuration Release -destination "generic/platform=macOS" -derivedDataPath "$OUT/app" \
    -quiet "${sign_settings[@]}" build

echo "==> Package"
mkdir -p "$OUT/stage/app/Applications" "$OUT/stage/driver/Library/Audio/Plug-Ins/HAL"
ditto "$OUT/app/Build/Products/Release/$APP_NAME.app" "$OUT/stage/app/Applications/$APP_NAME.app"
ditto "$OUT/driver/$DRIVER_BUNDLE" "$OUT/stage/driver/Library/Audio/Plug-Ins/HAL/$DRIVER_BUNDLE"
# Catch broken signatures here rather than after a notarization round trip.
codesign --verify --strict --deep "$OUT/stage/app/Applications/$APP_NAME.app"
codesign --verify --strict "$OUT/stage/driver/Library/Audio/Plug-Ins/HAL/$DRIVER_BUNDLE"

# component <name> <payload root> [pkgbuild args…]
component() {
    local name=$1 root=$2 plist="$OUT/components/$1.plist" i=0
    shift 2
    pkgbuild --analyze --root "$root" "$plist" >/dev/null
    # Install at the payload path even if a copy of the bundle exists elsewhere (e.g. a dev build).
    while plutil -type "$i" "$plist" >/dev/null 2>&1; do
        plutil -replace "$i.BundleIsRelocatable" -bool NO "$plist"
        i=$((i + 1))
    done
    pkgbuild --root "$root" --component-plist "$plist" --install-location / \
        --identifier "$PKG_ID.$name" --version "$VERSION" "$@" "$OUT/components/$name.pkg"
}
component app "$OUT/stage/app"
component driver "$OUT/stage/driver" --scripts "$ROOT/Installer/scripts"

PKG="$OUT/macOS-Audio-for-Sendspin-$VERSION.pkg"
product_args=(--distribution "$ROOT/Installer/distribution.xml" --package-path "$OUT/components")
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
    product_args+=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp)
fi
productbuild "${product_args[@]}" "$PKG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarize (takes a few minutes)"
    # notarytool exits 0 for a rejected submission too, so check the status.
    result=$(xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    status=$(plutil -extract status raw - <<<"$result")
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization status: $status" >&2
        xcrun notarytool log "$(plutil -extract id raw - <<<"$result")" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple "$PKG"
fi

echo "Built $PKG"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Not notarized: for testing on this Mac only, not for distribution."
fi
