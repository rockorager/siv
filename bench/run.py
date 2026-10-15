#!/usr/bin/env python3
"""Measures a siv-webview program on a running sway, from outside it, with
siv's bench methods (bench/gpui-compare, siv-columns' bench): presshim.so
for presentation feedback on every commit, inject for input through the
compositor's seat, /proc for memory of every process.

    python3 bench/run.py [--prog PATH] [--runs N] [--out FILE] [--url URL ...]

Needs XDG_RUNTIME_DIR, WAYLAND_DISPLAY, and SWAYSOCK of the sway to use;
spike/sway-headless.sh starts one. The window must be the only one, at
0,0 and 1280x800 (sway tiles it so).

Per run and URL: first frame (fork to the presentation of the first commit
after the program's first web frame), key to photon (a key into a focused
text field to the first presentation after it), wheel to photon (one notch
over the page), touchpad scrolling (dropped refresh intervals), and memory
(RSS, PSS, GPU) of the program and each WebKit process it started.
"""
import argparse, glob, json, os, re, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
ROOT = os.path.dirname(HERE)


def now():
    return time.monotonic_ns()


class Shim:
    def __init__(self, path):
        self.path, self.pos = path, 0
        self.commits, self.presented, self.xdg, self.toplevel = {}, {}, {}, set()

    def poll(self):
        try:
            with open(self.path) as f:
                f.seek(self.pos)
                data = f.read()
        except FileNotFoundError:
            return
        end = data.rfind("\n") + 1
        self.pos += end
        for line in data[:end].splitlines():
            p = line.split()
            if p[0] == "C":
                self.commits[int(p[3])] = (int(p[1]), int(p[2]))
            elif p[0] == "P":
                self.presented[int(p[1])] = int(p[2])
            elif p[0] == "X":
                self.xdg[int(p[1])] = int(p[2])
            elif p[0] == "T":
                self.toplevel.add(int(p[1]))

    def presents(self):
        # The toplevel's surfaces; every surface when presshim did not see
        # get_xdg_surface (synchronized subsurfaces present with it anyway).
        main = {self.xdg[x] for x in self.toplevel if x in self.xdg}
        return sorted((self.commits[s][1], tp) for s, tp in self.presented.items()
                      if s in self.commits and (not main or self.commits[s][0] in main))

    def first_present_after(self, t, timeout=2.0):
        deadline = time.monotonic() + timeout
        while True:
            self.poll()
            c = [tp for tc, tp in self.presents() if tc >= t]
            if c:
                return min(c)
            if time.monotonic() > deadline:
                return None
            time.sleep(0.002)


class Inject:
    def __init__(self):
        self.p = subprocess.Popen([os.path.join(OUT, "inject")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert self.p.stdout.readline().strip() == "ready"

    def cmd(self, c, answers=1):
        self.p.stdin.write(c + "\n")
        self.p.stdin.flush()
        out = [self.p.stdout.readline().strip() for _ in range(answers)]
        return [int(x.split()[1]) for x in out if x.startswith("t ")]

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def children(pid):
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        for t in glob.glob(f"/proc/{p}/task/*/children"):
            try:
                kids = [int(k) for k in open(t).read().split()]
            except OSError:
                continue
            out += kids
            todo += kids
    return out


def comm(pid):
    try:
        return open(f"/proc/{pid}/comm").read().strip()
    except OSError:
        return "?"


def memory(pid):
    try:
        rss = next(int(l.split()[1]) for l in open(f"/proc/{pid}/status") if l.startswith("VmRSS"))
        pss = next(int(l.split()[1]) for l in open(f"/proc/{pid}/smaps_rollup") if l.startswith("Pss:"))
    except (OSError, StopIteration):
        return None
    gpu = {}
    for fd in glob.glob(f"/proc/{pid}/fdinfo/*"):
        try:
            info = dict(l.split(":", 1) for l in open(fd) if ":" in l)
        except OSError:
            continue
        if "drm-client-id" in info:
            gpu[info["drm-client-id"].strip()] = sum(int(info[k].split()[0]) for k in ("drm-memory-vram", "drm-memory-gtt") if k in info)
    return {"rss_kib": rss, "pss_kib": pss, "gpu_kib": sum(gpu.values())}


def wait_log(path, pattern, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            m = re.search(pattern, open(path).read())
            if m:
                return m
        except FileNotFoundError:
            pass
        time.sleep(0.01)
    return None


def run_once(args, url, inj, tag):
    rt = os.environ["XDG_RUNTIME_DIR"]
    shim_log = os.path.join(rt, f"presshim-{now()}.log")
    app_log = os.path.join(rt, f"app-{now()}.log")
    env = dict(os.environ, LD_PRELOAD=os.path.join(OUT, "presshim.so"), PRESSHIM_LOG=shim_log)
    env.update(args.env)
    env["SIV_WEBVIEW_TRACE"] = "1"
    t0 = now()
    proc = subprocess.Popen([args.prog, url], env=env, stdout=open(app_log, "w"), stderr=subprocess.STDOUT)
    shim = Shim(shim_log)
    res = {"url": url, "tag": tag}
    # The spike logs program-relative ms; the library (SIV_WEBVIEW_TRACE)
    # CLOCK_MONOTONIC ns, the clock now() reads.
    m = wait_log(app_log, r"first render_buffer at ([0-9.]+) ms|first frame submitted at ([0-9]+) ns", 30)
    if not m:
        res["error"] = "no web frame"
    else:
        t_frame = int(m.group(2)) if m.group(2) else t0 + int(float(m.group(1)) * 1e6)
        tp = shim.first_present_after(t_frame, 5)
        res["first_frame_ms"] = (tp - t0) / 1e6 if tp else None
        wait_log(app_log, r"load finished", 30)
        time.sleep(args.settle)
        pids = [proc.pid] + children(proc.pid)
        res["memory"] = {f"{comm(p)}[{p}]": memory(p) for p in pids}
        res["memory_total"] = {k: sum((v or {}).get(k, 0) for v in res["memory"].values()) for k in ("rss_kib", "pss_kib", "gpu_kib")}
        if args.keys and "test.html" in url:
            inj.cmd("move 200 276")
            inj.cmd("press"), inj.cmd("release")
            time.sleep(0.3)
            lat = []
            for ch in "abcdefghijklmnopqrst":
                t = inj.cmd(f"key {ch}")[0]
                tp = shim.first_present_after(t, 1)
                if tp:
                    lat.append((tp - t) / 1e6)
                time.sleep(0.15)
            res["key_to_photon_ms"] = lat
        if args.wheel:
            # A step first: Hyprland gives a new window pointer focus only on
            # motion, and the pointer may already be there from the last run.
            inj.cmd("move %d %d" % (args.wheel_pos[0] + 5, args.wheel_pos[1]))
            inj.cmd("move %d %d" % tuple(args.wheel_pos))
            time.sleep(0.2)
            lat = []
            for i in range(15):
                t = inj.cmd(f"wheel {1 if i < 10 else -1}")[0]
                tp = shim.first_present_after(t, 1)
                if tp:
                    lat.append((tp - t) / 1e6)
                time.sleep(0.3)
            res["wheel_to_photon_ms"] = lat
            # Touchpad scrolling: 30 px events (7.5 before siv multiplies touchpad
            # distances by 4, D16) at 120/s for 3 s, then count
            # refresh intervals with no presentation while it ran.
            time.sleep(0.5)
            ts = inj.cmd("scrollburst 7.5 120 360", answers=360)
            time.sleep(0.3)
            shim.poll()
            # One per presentation time: Hyprland reports the window and its
            # synchronized subsurface separately.
            pres = sorted({tp for _, tp in shim.presents() if ts[0] <= tp <= ts[-1] + 20_000_000})
            period = 1e9 / 60
            dropped = sum(max(0, round((b - a) / period) - 1) for a, b in zip(pres, pres[1:]))
            res["scroll"] = {"presents": len(pres), "seconds": (ts[-1] - ts[0]) / 1e9, "dropped": dropped}
    proc.terminate()
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
    res["log_tail"] = open(app_log).read().splitlines()[-3:]
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prog", default=os.path.join(ROOT, "spike", "out", "spike"))
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--url", action="append")
    ap.add_argument("--out", default=None)
    ap.add_argument("--settle", type=float, default=2.0)
    ap.add_argument("--no-keys", dest="keys", action="store_false")
    ap.add_argument("--no-wheel", dest="wheel", action="store_false")
    ap.add_argument("--env", action="append", default=[], help="NAME=VALUE for the program")
    ap.add_argument("--wheel-pos", type=lambda v: [int(x) for x in v.split(",")], default=[640, 500], help="X,Y of the pointer for wheel and touchpad scrolling")
    args = ap.parse_args()
    args.env = dict(e.split("=", 1) for e in args.env)
    urls = args.url or ["file://" + os.path.join(ROOT, "spike", "pages", "test.html"), "https://en.wikipedia.org/wiki/Wayland_(protocol)"]
    inj = Inject()
    results = []
    for r in range(args.runs):
        for u in urls:
            res = run_once(args, u, inj, f"run{r}")
            results.append(res)
            print(json.dumps({k: v for k, v in res.items() if k != "memory"}), flush=True)
            time.sleep(1)
    inj.close()
    if args.out:
        json.dump({"results": results, "load": os.getloadavg(), "time": time.time()}, open(args.out, "w"), indent=1)
    for u in urls:
        rs = [x for x in results if x["url"] == u and "error" not in x]
        if not rs:
            continue
        med = lambda xs: statistics.median(xs) if xs else float("nan")
        print(f"\n{u}")
        print(f"  first frame ms: median {med([x['first_frame_ms'] for x in rs if x.get('first_frame_ms')]):.1f}")
        keys = [v for x in rs for v in x.get("key_to_photon_ms", [])]
        if keys:
            print(f"  key to photon ms: median {med(keys):.1f} p90 {sorted(keys)[int(len(keys) * .9)]:.1f} (n={len(keys)})")
        wheel = [v for x in rs for v in x.get("wheel_to_photon_ms", [])]
        if wheel:
            print(f"  wheel to photon ms: median {med(wheel):.1f} p90 {sorted(wheel)[int(len(wheel) * .9)]:.1f} (n={len(wheel)})")
        sc = [x["scroll"] for x in rs if "scroll" in x]
        if sc:
            print(f"  scrolling: presents/s {med([s['presents'] / s['seconds'] for s in sc]):.1f}, dropped {[s['dropped'] for s in sc]}")
        mem = rs[-1]["memory"]
        for k, v in mem.items():
            if v:
                print(f"  {k:28s} RSS {v['rss_kib'] / 1024:7.1f} MiB  PSS {v['pss_kib'] / 1024:7.1f} MiB  GPU {v['gpu_kib'] / 1024:7.1f} MiB")
        t = rs[-1]["memory_total"]
        print(f"  {'total':28s} RSS {t['rss_kib'] / 1024:7.1f} MiB  PSS {t['pss_kib'] / 1024:7.1f} MiB  GPU {t['gpu_kib'] / 1024:7.1f} MiB")


if __name__ == "__main__":
    main()
