#!/bin/bash
# Build a pretty Chorus.dmg: custom warm background, app icon on the left, an arrow, and the
# Applications folder on the right (drag-to-install). Outputs to ~/Desktop/Chorus.dmg.
# Run ./scripts/build-app.sh first (this uses build/Chorus.app).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VOL="Chorus"
APP="$ROOT/build/Chorus.app"
OUT="${1:-$HOME/Desktop/Chorus.dmg}"
BG="/tmp/chorus-dmg-bg.png"
RWDMG="/tmp/chorus-rw.dmg"

[ -d "$APP" ] || { echo "✗ $APP missing — run ./scripts/build-app.sh first"; exit 1; }

echo "==> Rendering background..."
swift "$ROOT/scripts/dmg-background.swift" "$BG"

echo "==> Staging..."
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/$VOL.app"
mkdir "$STAGE/.background"
cp "$BG" "$STAGE/.background/bg.png"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating read-write DMG..."
# Unmount any stale copy so it mounts at exactly /Volumes/Chorus.
hdiutil detach "/Volumes/$VOL" 2>/dev/null || true
rm -f "$RWDMG" "$OUT"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RWDMG" >/dev/null
rm -rf "$STAGE"

echo "==> Laying out window in Finder..."
hdiutil attach "$RWDMG" -readwrite -noverify -noautoopen >/dev/null
sleep 1
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 120, 940, 520}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 100
    set text size of theViewOptions to 12
    set background picture of theViewOptions to file ".background:bg.png"
    set position of item "$VOL.app" of container window to {165, 215}
    set position of item "Applications" of container window to {475, 215}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sync; sleep 1
hdiutil detach "/Volumes/$VOL" >/dev/null || hdiutil detach "/Volumes/$VOL" -force >/dev/null

echo "==> Compressing..."
hdiutil convert "$RWDMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RWDMG"

echo "✓ $OUT"
ls -lh "$OUT"
