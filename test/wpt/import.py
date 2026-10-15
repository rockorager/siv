#!/usr/bin/env python3
"""Imports the web-platform-tests CSS reftests that siv's document renderer
runs (D32): reftests without scripts, images, or other resources than the
Ahem font, from a WPT checkout. Writes the files under test/wpt/ with their
WPT paths, and test/wpt/MANIFEST, one "suite test reference" line each.

    git clone --depth 1 --filter=blob:none --sparse \\
        https://github.com/web-platform-tests/wpt /tmp/wpt
    git -C /tmp/wpt sparse-checkout set --skip-checks css fonts
    test/wpt/import.py /tmp/wpt

WPT is BSD-3-Clause (test/wpt/LICENSE.md); Ahem is public domain.
"""

import os
import re
import shutil
import sys

SUITES = {
    "css2": ["css/CSS2/normal-flow", "css/CSS2/box", "css/CSS2/margin-padding-clear",
             "css/CSS2/colors", "css/CSS2/borders", "css/CSS2/positioning",
             "css/CSS2/linebox", "css/CSS2/lists"],
    "css-flexbox": ["css/css-flexbox"],
    "css-grid": ["css/css-grid/grid-definition", "css/css-grid/alignment",
                 "css/css-grid/grid-items", "css/css-grid/placement"],
    "css-values": ["css/css-values"],
    "css-variables": ["css/css-variables"],
    "css-tables": ["css/CSS2/tables", "css/css-tables"],
    "floats": ["css/CSS2/floats", "css/CSS2/floats-clear"],
}
EXTS = (".html", ".htm", ".xht", ".xhtml")
MAX_BYTES = 12000
# Per suite, at most this many tests (the first by name), to keep the
# repository small.
MAX_TESTS = 400

BAD = re.compile(r"<script|<iframe|<object|<embed|<video|<canvas|<img|<image|<input|<svg|"
                 r"writing-mode|direction:\s*rtl|@supports|-webkit-|:hover|:focus|"
                 r"vertical-lr|vertical-rl|text-orientation|zoom:|contain:|"
                 r"rel=\"?mismatch|class=\"?reftest-wait|ruby|<math", re.I)
URL = re.compile(r"url\(\s*['\"]?([^'\")]+)", re.I)
LINK = re.compile(r"<link[^>]*rel=['\"]?stylesheet['\"]?[^>]*>", re.I)
HREF = re.compile(r"href=['\"]?([^'\" >]+)", re.I)
MATCH = re.compile(r"<link[^>]*rel=['\"]?match['\"]?[^>]*>", re.I)


def resources(path, text, root):
    """The files a test needs besides itself, or None if unsupported."""
    out = []
    for m in LINK.finditer(text):
        h = HREF.search(m.group(0))
        if not h:
            return None
        out.append(h.group(1))
    for u in URL.findall(text):
        if not u.lower().endswith((".ttf", ".css")):
            return None
        out.append(u)
    files = []
    for ref in out:
        if ref.startswith(("http:", "https:", "data:")):
            return None
        full = os.path.normpath(os.path.join(root, ref.lstrip("/")) if ref.startswith("/") else os.path.join(os.path.dirname(path), ref))
        if not os.path.isfile(full):
            return None
        if full.endswith(".css"):
            css = open(full, encoding="utf-8", errors="replace").read()
            for u in URL.findall(css):
                if not u.lower().endswith(".ttf"):
                    return None
                f = os.path.normpath(os.path.join(root, u.lstrip("/")) if u.startswith("/") else os.path.join(os.path.dirname(full), u))
                if not os.path.isfile(f):
                    return None
                files.append(f)
        files.append(full)
    return files


def main():
    root = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    for d in os.listdir(here):
        if d in ("css", "fonts"):
            shutil.rmtree(os.path.join(here, d))
    manifest = []
    copied = set()
    for suite, dirs in SUITES.items():
        count = 0
        for d in dirs:
            # Each directory its share, so that no area crowds out the rest.
            cap = count + MAX_TESTS // len(dirs)
            base = os.path.join(root, d)
            for dirpath, _, names in sorted(os.walk(base)):
                if "/support" in dirpath or "/reference" in dirpath:
                    continue
                for name in sorted(names):
                    if count >= cap or not name.endswith(EXTS) or "-ref" in name:
                        continue
                    path = os.path.join(dirpath, name)
                    if os.path.getsize(path) > MAX_BYTES:
                        continue
                    text = open(path, encoding="utf-8", errors="replace").read()
                    matches = MATCH.findall(text)
                    if len(matches) != 1 or BAD.search(text):
                        continue
                    href = HREF.search(matches[0])
                    if not href:
                        continue
                    ref = os.path.normpath(os.path.join(dirpath, href.group(1)) if not href.group(1).startswith("/") else os.path.join(root, href.group(1).lstrip("/")))
                    if not os.path.isfile(ref) or os.path.getsize(ref) > MAX_BYTES:
                        continue
                    ref_text = open(ref, encoding="utf-8", errors="replace").read()
                    if BAD.search(ref_text) or MATCH.search(ref_text):
                        continue
                    need = resources(path, text, root)
                    need_ref = resources(ref, ref_text, root)
                    if need is None or need_ref is None:
                        continue
                    for f in [path, ref] + need + need_ref:
                        rel = os.path.relpath(f, root)
                        if rel in copied:
                            continue
                        copied.add(rel)
                        dst = os.path.join(here, rel)
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        shutil.copyfile(f, dst)
                    manifest.append(f"{suite} {os.path.relpath(path, root)} {os.path.relpath(ref, root)}")
                    count += 1
        print(f"{suite}: {count}")
    with open(os.path.join(here, "MANIFEST"), "w") as f:
        f.write("\n".join(manifest) + "\n")
    shutil.copyfile(os.path.join(root, "LICENSE.md"), os.path.join(here, "LICENSE.md"))


if __name__ == "__main__":
    main()
