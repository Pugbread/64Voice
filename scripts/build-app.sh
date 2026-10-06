#!/bin/bash
# Builds 64Voice.app into ./build.
#
# Usage:
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh debug      # debug build
#   scripts/build-app.sh release --install   # also copy to /Applications and relaunch
#
# Signing: uses a stable identity so macOS keeps the Microphone / Accessibility /
# Screen Recording grants across rebuilds. Override with SFV_SIGN_IDENTITY.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
INSTALL="${2:-}"
APP_NAME="64Voice"
APP="build/${APP_NAME}.app"
IDENTITY="${SFV_SIGN_IDENTITY:-LiquidTUI Dev}"

swift build -c "$CONFIG" --product SixtyFourVoice
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_DIR/SixtyFourVoice" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# SwiftPM resource bundles (Bundle.module looks in Contents/Resources).
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Dynamic frameworks from binary targets.
for framework in "$BIN_DIR"/*.framework; do
    cp -R "$framework" "$APP/Contents/Frameworks/"
done
shopt -u nullglob

if [ -n "$(ls -A "$APP/Contents/Frameworks")" ]; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
else
    rmdir "$APP/Contents/Frameworks"
fi

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "warning: signing identity '$IDENTITY' not found, ad-hoc signing." >&2
    echo "         macOS will ask for permissions again after every rebuild." >&2
    codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"

if [ "$INSTALL" = "--install" ]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" "/Applications/"
    open "/Applications/${APP_NAME}.app"
    echo "Installed to /Applications and launched"
fi
