#!/bin/bash
# Tests that need the installed Sendspin driver and coreaudiod, so they run on a Mac, not in CI:
# the loopback, capture timing, sample-rate switches, who gets the audio, and format switches
# against aiosendspin's player. Quit the app (and its dev build) first: these switch the
# device's rate and latency. They put both back, and play nothing out loud.
#
#   Tests/device-tests.sh
#
# The driver only hands its audio to clients signed like it. For a driver signed by a team
# (an app build), sendspin-bridge is signed with SIGN_IDENTITY, or else the identity in
# App/Local.xcconfig.
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -f "/Sendspin( \(Dev\))?\.app/Contents/MacOS/" >/dev/null; then
    echo "Quit Sendspin (and its dev build) first" >&2
    exit 1
fi
driver=/Library/Audio/Plug-Ins/HAL/Sendspin.driver
[[ -d $driver ]] || { echo "The Sendspin driver isn't installed (Driver/install.sh)" >&2; exit 1; }

swift build -c release --product sendspin-bridge --package-path Packages/SendspinServerKit >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bridge=$work/sendspin-bridge
cp Packages/SendspinServerKit/.build/release/sendspin-bridge "$bridge"

team=$(codesign -dv "$driver" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ -n $team && $team != "not set" ]]; then
    identity=${SIGN_IDENTITY:-$(sed -n 's/^CODE_SIGN_IDENTITY *= *//p' App/Local.xcconfig 2>/dev/null || true)}
    if [[ -z $identity ]]; then
        echo "The driver is signed by team $team: set SIGN_IDENTITY to sign sendspin-bridge like it" >&2
        exit 1
    fi
    codesign -f -s "$identity" -i sendspin-bridge -o runtime "$bridge" 2>/dev/null
fi

# Any other program is refused the audio.
refuses_others() {
    cp "$bridge" "$work/other"
    codesign -f -s - -i com.sendspin-audio.not-allowed "$work/other" 2>/dev/null
    local output
    output=$("$work/other" --check-loopback 2>&1 || true)
    grep -q "refused" <<<"$output"
}

failed=()
run() {
    local name=$1
    shift
    echo "== $name"
    if ! "$@"; then failed+=("$name"); fi
}
run "The audio comes back sample-exact" "$bridge" --check-loopback
run "Capture times are the output times" "$bridge" --measure-latency
run "A rate switch restarts the timeline once" "$bridge" --check-rate-switch
run "Other programs are refused" refuses_others
run "One stream/start per format switch (aiosendspin player)" \
    uv run --quiet Tests/interop/test_player.py rate-switch --bridge "$bridge"

echo
if ((${#failed[@]})); then
    printf 'FAILED: %s\n' "${failed[@]}"
    exit 1
fi
echo "All device tests passed"
