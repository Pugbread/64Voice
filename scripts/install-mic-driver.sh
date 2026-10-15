#!/bin/bash
# Installs the 64Voice Mic driver into /Library/Audio/Plug-Ins/HAL, or removes it.
#
# Usage:
#   scripts/install-mic-driver.sh               # build, install, restart Core Audio
#   scripts/install-mic-driver.sh --uninstall   # remove, restart Core Audio
#
# Asks for your admin password. Restarting Core Audio cuts all sound for a second or two.

set -euo pipefail

cd "$(dirname "$0")/.."

DEST="/Library/Audio/Plug-Ins/HAL/64VoiceMic.driver"

if [ "${1:-}" = "--uninstall" ]; then
    sudo rm -rf "$DEST"
    echo "Removed $DEST"
else
    scripts/build-mic-driver.sh
    sudo rm -rf "$DEST"
    sudo cp -R build/64VoiceMic.driver "$DEST"
    sudo chown -R root:wheel "$DEST"
    echo "Installed $DEST"
fi

sudo killall coreaudiod
echo "Restarted Core Audio"
