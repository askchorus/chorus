#!/bin/bash
# Release pipeline — FREE (non-notarized) distribution.
#
#   ./scripts/release.sh 0.2.0
#
# Produces:
#   releases/Chorus-<version>.dmg   (universal, Sparkle embedded, ad-hoc signed)
#   releases/appcast.xml            (EdDSA-signed feed, regenerated from ALL DMGs in releases/)
# then stages both into the website repo (个人网页/public/chorus/) if it exists.
#
# Notes
# - No Apple notarization: first-time installers must pass Gatekeeper manually
#   (System Settings → Privacy & Security → Open Anyway). Sparkle-installed UPDATES
#   are not quarantined, so only the first install has friction.
# - EdDSA private key lives in the login Keychain ("Private key for signing Sparkle updates").
#   Keychain may prompt on first use — click Allow.
# - Keep old DMGs in releases/: generate_appcast rebuilds the feed from what's present
#   (and emits delta updates between consecutive versions it can see).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "Usage: $0 <version>   e.g. $0 0.2.0"; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: version must look like 0.2.0"; exit 1; }

PLIST="$ROOT/scripts/Info.plist"
RELEASES="$ROOT/releases"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
SITE_CHORUS_DIR="/Users/smiletalker/claudecode/个人网页/public/chorus"
DOWNLOAD_PREFIX="https://zhouyixiao.com/chorus/"

[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "ERROR: Sparkle tools missing — run 'swift package resolve' first"; exit 1; }

echo "==> Setting version $VERSION in Info.plist..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

echo "==> Building app bundle (universal)..."
"$ROOT/scripts/build-app.sh" > /dev/null
APP="$ROOT/build/Chorus.app"
[ -d "$APP" ] || { echo "ERROR: build failed"; exit 1; }

echo "==> Creating DMG..."
mkdir -p "$RELEASES"
DMG="$RELEASES/Chorus-$VERSION.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Chorus" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"
echo "    $(du -h "$DMG" | cut -f1 | tr -d ' ')  $DMG"

echo "==> Regenerating appcast (EdDSA signatures from login Keychain)..."
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" "$RELEASES" > /dev/null
echo "    $RELEASES/appcast.xml"

echo "==> Tagging v$VERSION..."
git tag -f "v$VERSION" >/dev/null 2>&1 || true

if [ -d "$(dirname "$SITE_CHORUS_DIR")" ]; then
    echo "==> Staging into website repo..."
    mkdir -p "$SITE_CHORUS_DIR"
    cp "$DMG" "$SITE_CHORUS_DIR/"
    cp "$RELEASES/appcast.xml" "$SITE_CHORUS_DIR/"
    # Ship deltas too when generate_appcast produced them.
    find "$RELEASES" -name "*.delta" -newer "$PLIST" -exec cp {} "$SITE_CHORUS_DIR/" \; 2>/dev/null || true
    # Keep the landing page's download link / version / size current.
    LANDING="$SITE_CHORUS_DIR/index.html"
    if [ -f "$LANDING" ]; then
        SIZE_H="$(du -h "$DMG" | cut -f1 | tr -d ' ' | sed 's/M$//')"
        sed -i '' -E \
          -e "s|Chorus-[0-9]+\.[0-9]+\.[0-9]+\.dmg|Chorus-$VERSION.dmg|g" \
          -e "s|(id=\"dl-version\">)[0-9]+\.[0-9]+\.[0-9]+|\1$VERSION|" \
          -e "s|· [0-9.]+ MB ·|· $SIZE_H MB ·|" \
          "$LANDING"
        echo "    landing page updated → $VERSION ($SIZE_H MB)"
    fi
    echo "    → $SITE_CHORUS_DIR (记得部署网站: cd 个人网页 && npx wrangler pages deploy public --project-name zhouyixiao)"
else
    echo "==> Website repo not found — upload these to $DOWNLOAD_PREFIX yourself:"
    echo "    $DMG"
    echo "    $RELEASES/appcast.xml"
fi

echo ""
echo "✓ Release $VERSION ready."
echo "  提交版本号变更: git add scripts/Info.plist releases/appcast.xml && git commit -m 'Release $VERSION'"
