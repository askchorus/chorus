#!/usr/bin/env python3
"""Rebuild the app's Chinese UI face: scripts/fonts/ChorusRound-{Medium,Bold}.ttf.

    python3 -m venv /tmp/fontenv && /tmp/fontenv/bin/pip install fonttools
    /tmp/fontenv/bin/python scripts/build-ui-font.py

Resource Han Rounded CN (SIL OFL 1.1, github.com/CyanoHao/Resource-Han-Rounded), cut down to the
CJK characters that appear in string literals under Sources/Chorus, renamed "Chorus Round" (the
OFL asks modified versions not to use the original's names). build-app.sh bundles the two faces
and warns when the app's strings use a character they lack — rerun this then; until you do, that
character falls back to PingFang. The same source font serves the landing page (个人网页/tools).
"""
import glob
import os
import re
import subprocess
import urllib.request

from fontTools import subset

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "scripts", "fonts")
CACHE = os.path.expanduser("~/.cache/chorus-site-fonts")
RHR_URL = "https://github.com/CyanoHao/Resource-Han-Rounded/releases/download/v0.990/RHR-CN-0.990.7z"
WEIGHTS = {"Medium": "ResourceHanRoundedCN-Medium.ttf", "Bold": "ResourceHanRoundedCN-Bold.ttf"}


def ui_chars():
    chars = set()
    for path in glob.glob(os.path.join(ROOT, "Sources", "Chorus", "*.swift")):
        text = open(path, encoding="utf-8").read()
        for lit in re.findall(r'"((?:[^"\\\n]|\\.)*)"', text):
            chars |= {c for c in lit if "　" <= c <= "鿿" or "＀" <= c <= "￯"}
    return "".join(sorted(chars))


def source(name):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        archive = os.path.join(CACHE, os.path.basename(RHR_URL))
        if not os.path.exists(archive):
            print("  fetching", RHR_URL)
            urllib.request.urlretrieve(RHR_URL, archive)
        subprocess.run(["bsdtar", "-xf", archive, "-C", CACHE, name], check=True)   # macOS bsdtar reads .7z
    return path


def cut(src, dst, text, weight):
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.hinting = False
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    font = subset.load_font(src, opts)
    sub = subset.Subsetter(opts)
    sub.populate(text=text)
    sub.subset(font)
    name = font["name"]
    name.names = [r for r in name.names if r.nameID not in (18, 20, 21, 22)]
    for rec in name.names:
        if rec.nameID in (1, 16):
            rec.string = "Chorus Round"
        elif rec.nameID in (2, 17):
            rec.string = weight
        elif rec.nameID == 4:
            rec.string = "Chorus Round " + weight
        elif rec.nameID == 6:
            rec.string = "ChorusRound-" + weight
        elif rec.nameID == 3:
            rec.string = "ChorusRound-" + weight + ";ui-subset"
    subset.save_font(font, dst, opts)
    return os.path.getsize(dst)


def main():
    os.makedirs(OUT, exist_ok=True)
    chars = ui_chars()
    for weight, file in WEIGHTS.items():
        n = cut(source(file), os.path.join(OUT, "ChorusRound-%s.ttf" % weight), chars, weight)
        print("ChorusRound-%s.ttf: %d characters, %d KB" % (weight, len(chars), n // 1024))
    with open(os.path.join(OUT, "ChorusRound.chars.txt"), "w", encoding="utf-8") as f:
        f.write(chars + "\n")


if __name__ == "__main__":
    main()
