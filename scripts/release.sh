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
NOTE="${2:-}"   # optional one-line Chinese summary shown in the landing page's 最近更新 list
[ -n "$VERSION" ] || { echo "Usage: $0 <version> [\"一句话更新说明\"]   e.g. $0 0.2.4 \"修复 Gemini 偶发发送失败\""; exit 1; }
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
    # Changelog (最近更新 on the landing page): record this release in releases.json, then
    # RENDER it straight into index.html. Rendering at release time (rather than fetching
    # releases.json in the browser) keeps the page a single self-contained file — no runtime
    # request that can fail and silently drop the section.
    VERSION="$VERSION" NOTE="$NOTE" SITE="$SITE_CHORUS_DIR" python3 - <<'PYEOF'
import json, os, datetime, re, html
site = os.environ["SITE"]
jpath, hpath = os.path.join(site, "releases.json"), os.path.join(site, "index.html")
try:
    data = json.load(open(jpath, encoding="utf-8"))
except Exception:
    data = []
note = os.environ.get("NOTE", "").strip()
if note:
    v = os.environ["VERSION"]
    data = [e for e in data if e.get("version") != v]
    data.insert(0, {"version": v, "date": datetime.date.today().isoformat(), "note": note})
    json.dump(data, open(jpath, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("    changelog: added %s" % v)
else:
    print("    changelog: no note given (pass one as arg 2) — list left as-is")

if not os.path.exists(hpath) or not data:
    raise SystemExit(0)
rows = []
for e in data[:3]:
    mm_dd = (e.get("date") or "")[5:]
    when = mm_dd.replace("-", "月") + "日" if mm_dd else ""
    rows.append('<div class="log-row"><b>%s</b><time>%s</time><span>%s</span></div>'
                % (html.escape(e.get("version", "")), when, html.escape(e.get("note", ""))))
doc = open(hpath, encoding="utf-8").read()
# Replace ONLY what sits between the sentinel comments. The previous version ran from the
# log div to the gatekeeper card, so ANY section added between them would be deleted on the
# next release — the privacy block was already sitting in that blast radius.
block = ('  <div class="sec log" id="log">\n'
         '    <h2><span class="zh">最近更新</span><span class="en">Recent updates</span></h2>\n'
         '    <div id="log-rows">\n' + "\n".join(rows) + '\n    </div>\n  </div>\n')
start_marker, end_marker = '<!-- chorus:log:start', '<!-- chorus:log:end -->'
if start_marker in doc and end_marker in doc:
    i = doc.index('\n', doc.index(start_marker)) + 1   # keep the marker line itself
    j = doc.index(end_marker)
    new_doc = doc[:i] + block + doc[j:]
else:
    new_doc = doc
    print("    changelog: sentinel markers missing — index.html left untouched")
if new_doc != doc:
    open(hpath, "w", encoding="utf-8").write(new_doc)
    print("    changelog: rendered %d rows into index.html" % len(rows))
PYEOF

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
