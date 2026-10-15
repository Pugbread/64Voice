#!/bin/bash
# Builds the 64Voice Mic virtual audio driver into ./build/64VoiceMic.driver.
# Install it with scripts/install-mic-driver.sh.
#
# The driver is BlackHole (Driver/BlackHole.c, GPL-3.0) configured by Driver/VirtualMicConfig.h.

set -euo pipefail

cd "$(dirname "$0")/.."

DRIVER="build/64VoiceMic.driver"
IDENTITY="${SFV_SIGN_IDENTITY:-LiquidTUI Dev}"

rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"

clang -bundle -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
    -include Driver/VirtualMicConfig.h -Wno-format-extra-args \
    -framework CoreAudio -framework CoreFoundation -framework Accelerate \
    -o "$DRIVER/Contents/MacOS/64VoiceMic" Driver/BlackHole.c

cp Driver/Info.plist "$DRIVER/Contents/Info.plist"
cp Driver/64VoiceMic.icns "$DRIVER/Contents/Resources/"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$DRIVER"
else
    echo "warning: signing identity '$IDENTITY' not found, ad-hoc signing." >&2
    codesign --force --sign - "$DRIVER"
fi

echo "Built $DRIVER"
