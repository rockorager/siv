#!/usr/bin/env python3
"""Imports the web-platform-tests CSS reftests that siv's document renderer
runs (D32): reftests without scripts, images, or other resources than the
Ahem font, from a WPT checkout. Writes the files under test/wpt/ with their
WPT paths, test/wpt/MANIFEST, one "suite test reference" line each, and
test/wpt/EXCLUDED, the tests left out of each suite counted by reason.

    git clone --depth 1 --filter=blob:none --sparse \\
        https://github.com/web-platform-tests/wpt /tmp/wpt
    git -C /tmp/wpt sparse-checkout set --skip-checks css fonts
    test/wpt/import.py /tmp/wpt [SUITE...]

With suites named, only those are imported again: the other suites keep
their manifest lines (and pass rates comparable across imports), and no
files are removed. Tests in the manifest that are out of scope for
documents are listed in test/wpt/SKIP with a reason; the runner leaves
them out of the pass rate.

WPT is BSD-3-Clause (test/wpt/LICENSE.md); Ahem is public domain.
"""

import collections
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
    "css-sizing": ["css/css-sizing"],
    "css-display": ["css/css-display"],
    "css-pseudo": ["css/css-pseudo"],
    "css-lists": ["css/css-lists", "css/CSS2/generated-content"],
    "css-text": ["css/css-text/white-space", "css/css-text/text-transform",
                 "css/css-text/letter-spacing", "css/css-text/word-break",
                 "css/css-text/overflow-wrap", "css/css-text/text-indent",
                 "css/css-text/text-align", "css/css-text/line-breaking"],
    "css-backgrounds": ["css/css-backgrounds", "css/css-borders"],
    "css-overflow": ["css/css-overflow"],
    "css-position": ["css/css-position"],
    "css-break": ["css/css-break"],
    "css-multicol": ["css/css-multicol"],
    "css-writing-modes": ["css/css-writing-modes"],
}
EXTS = (".html", ".htm", ".xht", ".xhtml")
MAX_BYTES = 12000
# Per suite, at most this many tests (the first by name), to keep the
# repository small.
MAX_TESTS = 400

# Reasons a test is left out, checked in order on the test and its
# reference. Writing modes are left out except from their own suite.
REASONS = [
    ("needs JavaScript", re.compile(r"<script|class=\"?reftest-wait", re.I)),
    ("embedded content (images, SVG, frames, canvas, video)",
     re.compile(r"<iframe|<object|<embed|<video|<canvas|<img|<image|<svg|<math", re.I)),
    ("form controls", re.compile(r"<input|<textarea|<select|<button", re.I)),
    ("writing modes and right-to-left", re.compile(
        r"writing-mode|direction:\s*rtl|vertical-lr|vertical-rl|text-orientation", re.I)),
    ("interactive state (:hover, :focus)", re.compile(r":hover|:focus", re.I)),
    ("vendor prefixes, @supports, zoom, contain", re.compile(r"@supports|-webkit-|zoom:|contain:", re.I)),
    ("ruby", re.compile(r"ruby", re.I)),
    ("mismatch reftest", re.compile(r"rel=\"?mismatch", re.I)),
]
WRITING_MODES = "writing modes and right-to-left"
URL = re.compile(r"url\(\s*['\"]?([^'\")]+)", re.I)
LINK = re.compile(r"<link[^>]*rel=['\"]?stylesheet['\"]?[^>]*>", re.I)
HREF = re.compile(r"href=['\"]?([^'\" >]+)", re.I)
MATCH = re.compile(r"<link[^>]*rel=['\"]?match['\"]?[^>]*>", re.I)


def reason_for(suite, text):
    for reason, pattern in REASONS:
        if reason == WRITING_MODES and suite == "css-writing-modes":
            continue
        if pattern.search(text):
            return reason
    return None


def resources(path, text, root):
    """The files a test needs besides itself, or None if unsupported."""
    out = []
    for m in LINK.finditer(text):
        h = HREF.search(m.group(0))
        if not h:
            return None
        out.append(h.group(1))
    for u in URL.findall(text):
        if not (u.lower().endswith(".css") or os.path.basename(u) == "Ahem.ttf"):
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
                if os.path.basename(u) != "Ahem.ttf":
                    return None
                f = os.path.normpath(os.path.join(root, u.lstrip("/")) if u.startswith("/") else os.path.join(os.path.dirname(full), u))
                if not os.path.isfile(f):
                    return None
                files.append(f)
        files.append(full)
    return files


def classify(suite, path, root):
    """(reference, files) for a test that runs, or (None, reason)."""
    if os.path.getsize(path) > MAX_BYTES:
        return None, "larger than 12 KB"
    text = open(path, encoding="utf-8", errors="replace").read()
    matches = MATCH.findall(text)
    if not matches:
        if re.search(r"rel=\"?mismatch", text, re.I):
            return None, "mismatch reftest"
        # testharness.js tests are scripts.
        return None, "needs JavaScript" if re.search(r"<script", text, re.I) else "not a reftest"

    if len(matches) != 1:
        return None, "several references"
    r = reason_for(suite, text)
    if r:
        return None, r
    href = HREF.search(matches[0])
    if not href:
        return None, "not a reftest"
    dirpath = os.path.dirname(path)
    ref = os.path.normpath(os.path.join(dirpath, href.group(1)) if not href.group(1).startswith("/") else os.path.join(root, href.group(1).lstrip("/")))
    if not os.path.isfile(ref):
        return None, "reference missing"
    if os.path.getsize(ref) > MAX_BYTES:
        return None, "larger than 12 KB"
    ref_text = open(ref, encoding="utf-8", errors="replace").read()
    if MATCH.search(ref_text):
        return None, "chained references"
    r = reason_for(suite, ref_text)
    if r:
        return None, r
    need = resources(path, text, root)
    need_ref = resources(ref, ref_text, root)
    if need is None or need_ref is None:
        return None, "resources other than style sheets and the Ahem font"
    return ref, [path, ref] + need + need_ref


def main():
    root = sys.argv[1]
    only = [a for a in sys.argv[2:] if not a.startswith("--")]
    # --excluded: count every suite's left-out tests again, without
    # importing anything.
    count_only = "--excluded" in sys.argv
    for s in only:
        if s not in SUITES:
            sys.exit(f"unknown suite {s}")
    here = os.path.dirname(os.path.abspath(__file__))
    kept = []
    excluded_kept = []
    if count_only:
        pass
    elif only:
        with open(os.path.join(here, "MANIFEST")) as f:
            kept = [line for line in f.read().splitlines() if line and line.split()[0] not in only]
        if os.path.isfile(os.path.join(here, "EXCLUDED")):
            with open(os.path.join(here, "EXCLUDED")) as f:
                excluded_kept = [line for line in f.read().splitlines()
                                 if line and not line.startswith("#") and line.split()[0] not in only]
    else:
        for d in os.listdir(here):
            if d in ("css", "fonts"):
                shutil.rmtree(os.path.join(here, d))
    manifest = []
    excluded = []
    copied = set()
    for suite, dirs in SUITES.items():
        if only and suite not in only and not count_only:
            continue
        count = 0
        reasons = collections.Counter()
        for d in dirs:
            # Each directory its share, so that no area crowds out the rest.
            cap = count + MAX_TESTS // len(dirs)
            base = os.path.join(root, d)
            for dirpath, _, names in sorted(os.walk(base)):
                if "/support" in dirpath or "/reference" in dirpath:
                    continue
                # A suite's own subdirectories are listed separately.
                if any(dirpath.startswith(os.path.join(root, o) + "/") or dirpath == os.path.join(root, o)
                       for o in dirs if o != d and o.startswith(d + "/")):
                    continue
                for name in sorted(names):
                    if not name.endswith(EXTS) or "-ref" in name or name.endswith("-notref.html"):
                        continue
                    path = os.path.join(dirpath, name)
                    ref, files = classify(suite, path, root)
                    if ref is None:
                        reasons[files] += 1
                        continue
                    if count >= cap:
                        reasons["beyond the per-suite cap of 400"] += 1
                        continue
                    for f in ([] if count_only else files):
                        rel = os.path.relpath(f, root)
                        if rel in copied:
                            continue
                        copied.add(rel)
                        dst = os.path.join(here, rel)
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        shutil.copyfile(f, dst)
                    manifest.append(f"{suite} {os.path.relpath(path, root)} {os.path.relpath(ref, root)}")
                    count += 1
        for reason, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
            excluded.append(f"{suite} {n} {reason}")
        print(f"{suite}: {count} imported, {sum(reasons.values())} left out")
    if not count_only:
        with open(os.path.join(here, "MANIFEST"), "w") as f:
            f.write("\n".join(kept + manifest) + "\n")
    with open(os.path.join(here, "EXCLUDED"), "w") as f:
        f.write("# Tests left out of each suite at import (test/wpt/import.py): suite, count, reason.\n")
        f.write("\n".join(excluded_kept + excluded) + "\n")
    if not count_only:
        shutil.copyfile(os.path.join(root, "LICENSE.md"), os.path.join(here, "LICENSE.md"))


if __name__ == "__main__":
    main()
