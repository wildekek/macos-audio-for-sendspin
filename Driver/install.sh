#!/bin/bash
# Install the Sendspin audio driver (or remove it with -u), then restart coreaudiod.
#
#   Driver/install.sh [path/to/MacOSAudioForSendspin.driver]
#   Driver/install.sh -u
#
# Restarting coreaudiod briefly interrupts all audio on this Mac.
set -euo pipefail

BUNDLE_NAME="MacOSAudioForSendspin.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

if [[ $EUID -ne 0 ]]; then
    if [[ -t 0 ]]; then
        exec sudo "$0" "$@"
    fi
    # No terminal to type a sudo password into: ask with the macOS admin dialog.
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    args=$(printf ' %q' "$script" "$@")
    exec osascript -e "do shell script \"${args//\"/\\\"}\" with prompt \"Install the Sendspin audio driver\" with administrator privileges"
fi

restart_coreaudiod() {
    echo "Restarting coreaudiod…"
    launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
}

if [[ "${1:-}" == "-u" ]]; then
    if [[ -d "$HAL_DIR/$BUNDLE_NAME" ]]; then
        rm -rf "${HAL_DIR:?}/$BUNDLE_NAME"
        echo "Removed $HAL_DIR/$BUNDLE_NAME"
        restart_coreaudiod
    else
        echo "Not installed"
    fi
    exit 0
fi

SOURCE="${1:-$(cd "$(dirname "$0")" && pwd)/build/$BUNDLE_NAME}"
if [[ ! -d "$SOURCE" ]]; then
    echo "Driver bundle not found: $SOURCE (build it first)" >&2
    exit 1
fi

rm -rf "${HAL_DIR:?}/$BUNDLE_NAME"
cp -R "$SOURCE" "$HAL_DIR/"
chown -R root:wheel "$HAL_DIR/$BUNDLE_NAME"
echo "Installed $HAL_DIR/$BUNDLE_NAME"
restart_coreaudiod
