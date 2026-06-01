#!/bin/bash
# Build a release Chorus.app bundle.
# Usage: ./scripts/build-app.sh        — produces build/Chorus.app
#        ./scripts/build-app.sh -i     — also moves it to /Applications (overwrites existing)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Chorus"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Compiling universal release binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Preparing icon (if missing)..."
if [ ! -f "$ROOT/scripts/AppIcon.icns" ]; then
    pushd "$ROOT/scripts" > /dev/null
    rm -rf Chorus.iconset
    swift process-icon.swift icon-source.png Chorus.iconset   # rebuild from the source art
    iconutil -c icns Chorus.iconset -o AppIcon.icns
    rm -rf Chorus.iconset
    popd > /dev/null
fi

echo "==> Assembling .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/scripts/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/scripts/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "✓ Built: $APP_DIR"

if [ "${1:-}" = "-i" ] || [ "${1:-}" = "-r" ]; then
    echo "==> Stopping running Chorus instances..."
    pkill -x "Chorus" 2>/dev/null || true
    sleep 1

    echo "==> Installing to /Applications..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
    echo "✓ Installed: /Applications/$APP_NAME.app"

    # rm+cp gives the bundle a fresh inode each time, so LaunchServices keeps serving the
    # OLD cached icon for this path. Re-register + touch + restart the Dock so the new
    # AppIcon shows immediately instead of "reverting" to the previous one.
    echo "==> Refreshing icon cache..."
    LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREG" -f "/Applications/$APP_NAME.app" 2>/dev/null || true
    touch "/Applications/$APP_NAME.app" 2>/dev/null || true
    rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices.store" 2>/dev/null || true
    killall Dock 2>/dev/null || true

    if [ "${1:-}" = "-r" ]; then
        echo "==> Relaunching..."
        open "/Applications/$APP_NAME.app"
    else
        echo ""
        echo "First launch: right-click → Open (Gatekeeper bypass for ad-hoc signed)"
    fi
else
    echo ""
    echo "  -i  install to /Applications"
    echo "  -r  install + relaunch (use after first install)"
    echo ""
    echo "Or drag $APP_DIR to /Applications manually."
fi
