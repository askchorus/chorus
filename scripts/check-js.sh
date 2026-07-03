#!/bin/bash
# Syntax-check every JS payload Broadcaster generates. Injection scripts fail at RUNTIME only
# (the Swift compiler can't see into the strings), so run this after touching WebPanel.swift's
# script builders. Parse = OK is signalled by a ReferenceError (no browser globals in JXA);
# a SyntaxError means the generated script is genuinely broken.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"

echo "import Foundation" > "$OUT/b.swift"
awk '/^enum Broadcaster \{/,0' "$ROOT/Sources/Chorus/WebPanel.swift" >> "$OUT/b.swift"
cat >> "$OUT/b.swift" <<EOF

let scripts: [(String, String)] = [
  ("lib", Broadcaster.libScript()),
  ("injection", Broadcaster.injectionScript(text: "hi \`edge\` \"quote\"\\nline2\\ttab", imagesBase64: ["QUJDREVG"], waitForGeminiUpload: false)),
  ("injection_wait", Broadcaster.injectionScript(text: "wait-upload variant", imagesBase64: [], waitForGeminiUpload: true)),
  ("watcher", Broadcaster.streamingWatcherScript()),
  ("uploadTrigger", Broadcaster.geminiUploadTriggerScript()),
  ("busy", Broadcaster.busyCheckScript()),
  ("extract", Broadcaster.extractAnswerScript()),
]
for (name, s) in scripts {
  try! s.write(toFile: "$OUT/\\(name).js", atomically: true, encoding: .utf8)
}
print("generated \\(scripts.count) scripts")
EOF

swift "$OUT/b.swift"

fail=0
for f in "$OUT"/*.js; do
  r=$(osascript -l JavaScript "$f" 2>&1 || true)
  if [[ "$r" == *SyntaxError* ]]; then
    echo "❌ $(basename "$f"): $r"
    fail=1
  else
    echo "✅ $(basename "$f") parses"
  fi
done
rm -rf "$OUT"
exit $fail
