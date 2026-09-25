#!/usr/bin/env python3
"""Landing-page changelog: releases.json → the 最近更新 / Recent updates block in index.html.

  python3 scripts/changelog.py <site chorus dir>                                    # re-render only
  python3 scripts/changelog.py <site chorus dir> <version> "<中文说明>" ["<English note>"]

A version with a note records that release in releases.json (newest first; an entry with the
same version is replaced). Either way the newest three entries are rendered into index.html
between the chorus:log sentinels, in both languages. An entry without an English note shows its
Chinese note on the English page too — pass one. release.sh calls this with its 2nd/3rd args.

Rendering at release time (rather than fetching releases.json in the browser) keeps the page a
single self-contained file — no runtime request that can fail and silently drop the section.
"""
import datetime
import html
import json
import os
import sys

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
START, END = "<!-- chorus:log:start", "<!-- chorus:log:end -->"


def row(e):
    esc = html.escape
    date = e.get("date") or ""
    try:
        day = datetime.date.fromisoformat(date)
        when = '<time datetime="%s"><span class="zh">%02d月%02d日</span><span class="en">%s %d</span></time>' % (
            date, day.month, day.day, MONTHS[day.month - 1], day.day)
    except ValueError:
        when = "<time></time>"
    zh, en = esc(e.get("note", "")), esc(e.get("note_en", ""))
    note = '<span class="zh">%s</span><span class="en">%s</span>' % (zh, en) if en else "<span>%s</span>" % zh
    return '<div class="log-row"><b>%s</b>%s%s</div>' % (esc(e.get("version", "")), when, note)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    site = argv[1]
    version, note, note_en = [(a or "").strip() for a in (argv[2:5] + ["", "", ""])[:3]]
    jpath, hpath = os.path.join(site, "releases.json"), os.path.join(site, "index.html")
    try:
        data = json.load(open(jpath, encoding="utf-8"))
    except (OSError, ValueError):
        data = []
    if version and note:
        entry = {"version": version, "date": datetime.date.today().isoformat(), "note": note}
        if note_en:
            entry["note_en"] = note_en
        data = [e for e in data if e.get("version") != version]
        data.insert(0, entry)
        with open(jpath, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("    changelog: added %s%s" % (version, "" if note_en else
              " — no English note, so the English page shows the Chinese one"))
    elif version:
        print("    changelog: no note given (pass one as arg 2) — list left as-is")

    if not os.path.exists(hpath) or not data:
        return 0
    doc = open(hpath, encoding="utf-8").read()
    if START not in doc or END not in doc:
        print("    changelog: sentinel markers missing — index.html left untouched")
        return 0
    rows = [row(e) for e in data[:3]]
    block = ('  <div class="sec log" id="log">\n'
             '    <h2><span class="zh">最近更新</span><span class="en">Recent updates</span></h2>\n'
             '    <div id="log-rows">\n' + "\n".join(rows) + '\n    </div>\n  </div>\n')
    i = doc.index("\n", doc.index(START)) + 1   # keep the marker line itself
    j = doc.index(END)
    new_doc = doc[:i] + block + doc[j:]
    if new_doc != doc:
        with open(hpath, "w", encoding="utf-8") as f:
            f.write(new_doc)
        print("    changelog: rendered %d rows into index.html" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
