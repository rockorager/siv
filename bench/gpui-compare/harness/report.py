#!/usr/bin/env python3
"""Summarizes harness/run.py's results as Markdown tables.

    harness/report.py [RAW_DIR] > results.md

Every cell is the median over runs, with the range over runs in brackets.
Latencies are first reduced to each run's median (and p99/max where shown).
"""

import glob
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(raw):
    data = {}
    for path in glob.glob(os.path.join(raw, "*.json")):
        with open(path) as f:
            r = json.load(f)
        data.setdefault((r["toolkit"], r["scenario"]), []).append(r)
    return data


def get(r, path):
    for k in path.split("."):
        if r is None:
            return None
        r = r.get(k) if isinstance(r, dict) else None
    return r


def reduce(values, how):
    values = [v for v in values if v is not None]
    if not values:
        return None
    if how == "median":
        return statistics.median(values)
    if how == "p99":
        s = sorted(values)
        return s[min(len(s) - 1, int(0.99 * len(s)))]
    if how == "max":
        return max(values)
    raise ValueError(how)


def cell(runs, path, how=None, fmt="{:.1f}"):
    scale = 1 / 1024 if path.endswith("_kib") else 1
    vals = []
    for r in runs:
        v = get(r, path)
        if isinstance(v, list):
            v = reduce(v, how or "median")
        if v is not None:
            vals.append(v * scale)
    if not vals:
        return "–"
    med = statistics.median(vals)
    if len(vals) == 1:
        return fmt.format(med)
    return f"{fmt.format(med)} [{fmt.format(min(vals))}–{fmt.format(max(vals))}]"


METRICS = [
    # (scenario, label, path, reduce, format)
    ("idle", "startup to first frame (ms)", "startup_ms", None, "{:.1f}"),
    ("idle", "idle CPU (%)", "idle.cpu_percent", None, "{:.2f}"),
    ("idle", "idle wakeups (/s)", "idle.wakeups_per_s", None, "{:.1f}"),
    ("idle", "RSS after start (MiB)", "memory.rss_kib", None, "{:.1f}"),
    ("idle", "PSS after start (MiB)", "memory.pss_kib", None, "{:.1f}"),
    ("idle", "GPU memory (MiB)", "memory.vram_kib", None, "{:.1f}"),
    ("idle", "threads", "memory.threads", None, "{:.0f}"),
    ("gallery", "startup to first frame (ms)", "startup_ms", None, "{:.1f}"),
    ("gallery", "idle wakeups (/s)", "idle.wakeups_per_s", None, "{:.1f}"),
    ("gallery", "RSS (MiB)", "memory_end.rss_kib", None, "{:.1f}"),
    ("gallery", "key to photon, median (ms)", "key_ms", "median", "{:.2f}"),
    ("gallery", "key to photon, max (ms)", "key_ms", "max", "{:.2f}"),
    ("gallery", "click to photon, median (ms)", "click_ms", "median", "{:.2f}"),
    ("gallery", "click to menu shown, median (ms)", "menu_ms", "median", "{:.2f}"),
    ("list", "startup to first frame (ms)", "startup_ms", None, "{:.1f}"),
    ("list", "RSS (MiB)", "memory_end.rss_kib", None, "{:.1f}"),
    ("list", "scroll: frames presented in 5 s", "scroll.frames", None, "{:.0f}"),
    ("list", "scroll: dropped frames", "scroll.dropped", None, "{:.0f}"),
    ("list", "scroll: frame interval p50 (ms)", "scroll.interval_p50_ms", None, "{:.2f}"),
    ("list", "scroll: frame interval p99 (ms)", "scroll.interval_p99_ms", None, "{:.2f}"),
    ("list", "scroll: frame interval max (ms)", "scroll.interval_max_ms", None, "{:.2f}"),
    ("list", "scroll: CPU per frame (ms)", "scroll.cpu_ms_per_frame", None, "{:.2f}"),
    ("list", "scroll: GPU per frame (ms)", "scroll.gpu_ms_per_frame", None, "{:.2f}"),
    ("list", "scroll: CPU (% of a core)", "scroll.cpu_percent", None, "{:.1f}"),
    ("list", "wheel to photon, median (ms)", "wheel_ms", "median", "{:.2f}"),
    ("text", "startup to first frame (ms)", "startup_ms", None, "{:.1f}"),
    ("text", "RSS (MiB)", "memory_end.rss_kib", None, "{:.1f}"),
    ("text", "key to photon, median (ms)", "key_ms", "median", "{:.2f}"),
    ("text", "key to photon, max (ms)", "key_ms", "max", "{:.2f}"),
    ("text", "scroll: dropped frames", "scroll.dropped", None, "{:.0f}"),
    ("text", "scroll: frame interval p99 (ms)", "scroll.interval_p99_ms", None, "{:.2f}"),
    ("text", "scroll: CPU per frame (ms)", "scroll.cpu_ms_per_frame", None, "{:.2f}"),
    ("text", "scroll: GPU per frame (ms)", "scroll.gpu_ms_per_frame", None, "{:.2f}"),
    ("text", "wheel to photon, median (ms)", "wheel_ms", "median", "{:.2f}"),
    ("grid", "startup to first frame (ms)", "startup_ms", None, "{:.1f}"),
    ("grid", "frames presented in 5 s", "animation.frames", None, "{:.0f}"),
    ("grid", "dropped frames", "animation.dropped", None, "{:.0f}"),
    ("grid", "frame interval p50 (ms)", "animation.interval_p50_ms", None, "{:.2f}"),
    ("grid", "frame interval p99 (ms)", "animation.interval_p99_ms", None, "{:.2f}"),
    ("grid", "frame interval max (ms)", "animation.interval_max_ms", None, "{:.2f}"),
    ("grid", "CPU per frame (ms)", "animation.cpu_ms_per_frame", None, "{:.2f}"),
    ("grid", "GPU per frame (ms)", "animation.gpu_ms_per_frame", None, "{:.2f}"),
    ("grid", "CPU (% of a core)", "animation.cpu_percent", None, "{:.1f}"),
    ("grid", "RSS (MiB)", "memory_end.rss_kib", None, "{:.1f}"),
    ("typing", "key to photon, median (ms)", "key_ms", "median", "{:.2f}"),
    ("typing", "key to photon, p99 (ms)", "key_ms", "p99", "{:.2f}"),
    ("typing", "key to photon, max (ms)", "key_ms", "max", "{:.2f}"),
    ("typing", "frames presented", "burst.frames", None, "{:.0f}"),
    ("typing", "CPU per frame (ms)", "burst.cpu_ms_per_frame", None, "{:.2f}"),
    ("typing", "CPU (% of a core)", "burst.cpu_percent", None, "{:.1f}"),
    ("resize", "configures acknowledged", "acks", None, "{:.0f}"),
    ("resize", "frames presented", "storm.frames", None, "{:.0f}"),
    ("resize", "resize to photon, median (ms)", "resize_ms", "median", "{:.2f}"),
    ("resize", "resize to photon, p99 (ms)", "resize_ms", "p99", "{:.2f}"),
    ("resize", "resize to photon, max (ms)", "resize_ms", "max", "{:.2f}"),
    ("resize", "frame interval max (ms)", "storm.interval_max_ms", None, "{:.2f}"),
    ("resize", "CPU per frame (ms)", "storm.cpu_ms_per_frame", None, "{:.2f}"),
    ("resize", "CPU (% of a core)", "storm.cpu_percent", None, "{:.1f}"),
]

def stripped_size(path):
    out = "/tmp/gpui-compare-stripped"
    subprocess.run(["strip", "-o", out, path], check=True)
    n = os.path.getsize(out)
    os.unlink(out)
    return n


def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "results", "raw")
    data = load(raw)
    toolkits = ["siv", "gpui"]
    runs = max((len(v) for v in data.values()), default=0)
    print(f"Median over {runs} runs per cell, [min–max over runs].\n")
    print("| scenario | metric | siv | gpui |")
    print("| --- | --- | --- | --- |")
    for scenario, label, path, how, fmt in METRICS:
        cells = []
        for tk in toolkits:
            rs = data.get((tk, scenario), [])
            cells.append(cell(rs, path, how, fmt))
        print(f"| {scenario} | {label} | {cells[0]} | {cells[1]} |")
    siv_lib = os.path.realpath(os.path.join(ROOT, "..", "..", "zig-out", "lib", "libsiv.so"))
    sizes = {}
    for name, path in [("siv-bench", os.path.join(ROOT, "out", "siv-bench")), ("libsiv.so", siv_lib),
                       ("gpui-compare", os.path.join(ROOT, "gpui", "target", "release", "gpui-compare"))]:
        if os.path.exists(path):
            sizes[name] = stripped_size(path)
    if sizes:
        siv_total = sizes.get("siv-bench", 0) + sizes.get("libsiv.so", 0)
        print(f"| all | stripped binary size (MiB) | {siv_total / 2**20:.1f} (libsiv.so {sizes.get('libsiv.so', 0) / 2**20:.1f} "
              f"+ program {sizes.get('siv-bench', 0) / 2**10:.0f} KiB) | {sizes.get('gpui-compare', 0) / 2**20:.1f} |")


if __name__ == "__main__":
    main()
