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
# The rounded Chinese UI face (Resource Han Rounded, SIL OFL — licence alongside), cut down to the
# app's own strings. Warn when a string now uses a character the cut lacks: it would fall back to
# PingFang mid-word until scripts/build-ui-font.py is rerun.
cp "$ROOT/scripts/fonts/ChorusRound-Medium.ttf" "$ROOT/scripts/fonts/ChorusRound-Bold.ttf" \
   "$ROOT/scripts/fonts/OFL-ResourceHanRounded.txt" "$RESOURCES_DIR/"
python3 - "$ROOT" <<'PYEOF'
import glob, os, re, sys
root = sys.argv[1]
have = set(open(os.path.join(root, "scripts/fonts/ChorusRound.chars.txt"), encoding="utf-8").read().strip())
used = set()
for path in glob.glob(os.path.join(root, "Sources/Chorus/*.swift")):
    for lit in re.findall(r'"((?:[^"\\\n]|\\.)*)"', open(path, encoding="utf-8").read()):
        used |= {c for c in lit if "\u3000" <= c <= "\u9fff" or "\uff00" <= c <= "\uffef"}
missing = "".join(sorted(used - have))
if missing:
    print("⚠️  UI font lacks %d character(s): %s — run scripts/build-ui-font.py" % (len(missing), missing))
PYEOF

echo "==> Embedding Sparkle.framework..."
# SPM links the binary against @rpath/Sparkle.framework; the manually-assembled bundle must
# carry the framework and an rpath pointing at Contents/Frameworks.
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    # Artifact layout differs across Sparkle releases — locate it.
    SPARKLE_FW="$(find "$ROOT/.build/artifacts" -type d -name "Sparkle.framework" -path "*macos*" | head -1)"
fi
[ -d "$SPARKLE_FW" ] || { echo "ERROR: Sparkle.framework not found under .build/artifacts"; exit 1; }
cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME" 2>/dev/null || true

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
