#!/usr/bin/env python3
"""Runs the siv/gpui comparison scenarios on headless sway with GPU rendering.

    harness/run.py [--runs N] [--toolkits siv,gpui] [--scenarios a,b] [--out DIR]

Each run starts a fresh sway (headless backend, Vulkan renderer on the
render node, one 1280x800 output at 60 Hz, scale 1, no borders), the
toolkit's program for one scenario with presshim.so preloaded, and inject
for input. Results go to DIR/<toolkit>-<scenario>-<run>.json; report.py
summarizes them.
"""

import argparse
import glob
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "out")
REFRESH_NS = 1e9 / 60
PROGRAMS = {
    "siv": [os.path.join(OUT, "siv-bench")],
    "gpui": [os.path.join(ROOT, "gpui", "target", "release", "gpui-compare")],
}
SCENARIOS = ["idle", "gallery", "list", "text", "grid", "typing", "resize"]
# Touchpad scroll per event, so that both move 30 logical px: gpui
# multiplies touchpad deltas by 3 (gpui_linux's Wayland client,
# `let modifier = 3.0`), siv scrolls them as they come (D8).
SCROLL_EVENT = {"siv": 30, "gpui": 10}


def now():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


# Sway ---------------------------------------------------------------------------


class Sway:
    def __init__(self, renderer):
        self.dir = f"/tmp/gpui-compare-{os.getpid()}-{now()}"
        os.makedirs(self.dir, mode=0o700)
        with open(os.path.join(self.dir, "config"), "w") as f:
            f.write("output HEADLESS-1 mode 1280x800@60Hz position 0 0 scale 1\n"
                    "default_border none\ndefault_floating_border none\n"
                    "focus_follows_mouse no\n")
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin"),
            "HOME": os.environ.get("HOME", "/root"),
            "XDG_RUNTIME_DIR": self.dir,
            "WAYLAND_DISPLAY": "wayland-1",
            "LC_ALL": "C.UTF-8",
        }
        senv = dict(self.env, WLR_BACKENDS="headless", WLR_RENDERER=renderer, WLR_LIBINPUT_NO_DEVICES="1",
                    WLR_RENDER_DRM_DEVICE="/dev/dri/renderD128")
        del senv["WAYLAND_DISPLAY"]
        self.log = open(os.path.join(self.dir, "sway.log"), "w")
        self.proc = subprocess.Popen(["sway", "-c", os.path.join(self.dir, "config")], env=senv,
                                     stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(500):
            socks = glob.glob(os.path.join(self.dir, "sway-ipc.*.sock"))
            if socks and os.path.exists(os.path.join(self.dir, "wayland-1")):
                self.ipc_path = socks[0]
                try:
                    self.ipc("nop")
                    break
                except OSError:
                    pass
            time.sleep(0.01)
        else:
            raise RuntimeError("sway did not start")
        self.env["SWAYSOCK"] = self.ipc_path

    def ipc(self, cmd, kind=0):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.ipc_path)
        data = cmd.encode()
        s.sendall(b"i3-ipc" + struct.pack("<II", len(data), kind) + data)
        hdr = b""
        while len(hdr) < 14:
            hdr += s.recv(14 - len(hdr))
        n = struct.unpack("<I", hdr[6:10])[0]
        body = b""
        while len(body) < n:
            body += s.recv(n - len(body))
        s.close()
        return json.loads(body)

    def stop(self):
        try:
            os.killpg(self.proc.pid, 15)
            self.proc.wait(timeout=5)
        except Exception:
            os.killpg(self.proc.pid, 9)
        self.log.close()
        shutil.rmtree(self.dir, ignore_errors=True)


class Injector:
    def __init__(self, env):
        self.proc = subprocess.Popen([os.path.join(OUT, "inject")], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1)
        line = self.proc.stdout.readline()
        if line.strip() != "ready":
            raise RuntimeError("inject failed to start: " + line)

    def send(self, cmd, answers=1):
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()
        out = []
        for _ in range(answers):
            line = self.proc.stdout.readline().split()
            if line and line[0] == "t":
                out.append(int(line[1]))
        return out

    def stop(self):
        self.proc.stdin.close()
        self.proc.wait()


# Presentation log ------------------------------------------------------------------------


class Shim:
    """Incremental reader of presshim.so's log."""

    def __init__(self, path):
        self.path = path
        self.pos = 0
        self.commits = {}  # seq -> (surface, t)
        self.presented = {}  # seq -> t
        self.attach = []  # (surface, t)
        self.acks = []  # (xdg_surface, t)
        self.xdg = {}  # xdg_surface -> wl_surface
        self.toplevel_xdg = set()
        self.popup_xdg = set()

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
            k = p[0]
            if k == "C":
                self.commits[int(p[3])] = (int(p[1]), int(p[2]))
            elif k == "P":
                self.presented[int(p[1])] = int(p[2])
            elif k == "A":
                self.attach.append((int(p[1]), int(p[2])))
            elif k == "K":
                self.acks.append((int(p[1]), int(p[2])))
            elif k == "X":
                self.xdg[int(p[1])] = int(p[2])
            elif k == "T":
                self.toplevel_xdg.add(int(p[1]))
            elif k == "O":
                self.popup_xdg.add(int(p[1]))

    def surfaces(self, popups=False):
        ids = self.popup_xdg if popups else self.toplevel_xdg
        return {self.xdg[x] for x in ids if x in self.xdg}

    def presents(self, surfaces=None, t0=0, t1=1 << 63):
        """(commit time, present time) of presented commits, by present time."""
        out = []
        for seq, tp in self.presented.items():
            s, tc = self.commits.get(seq, (None, 0))
            if (surfaces is None or s in surfaces) and t0 <= tp <= t1:
                out.append((tc, tp))
        return sorted(out, key=lambda x: x[1])

    def first_present_after(self, t, surfaces=None, timeout=1.0):
        """The first presented commit made after t: input-to-photon."""
        deadline = time.monotonic() + timeout
        while True:
            self.poll()
            cands = [(tc, tp) for tc, tp in self.presents(surfaces) if tc >= t]
            if cands:
                return min(cands, key=lambda x: x[0])[1]
            if time.monotonic() > deadline:
                return None
            time.sleep(0.005)

    def commits_between(self, t0, t1, surfaces=None):
        return sum(1 for s, tc in self.commits.values() if t0 <= tc <= t1 and (surfaces is None or s in surfaces))


# Process statistics -------------------------------------------------------------------


def proc_stats(pid):
    cpu = 0
    ctx = 0
    for task in glob.glob(f"/proc/{pid}/task/*"):
        try:
            with open(task + "/schedstat") as f:
                cpu += int(f.read().split()[0])
            with open(task + "/status") as f:
                for line in f:
                    if line.startswith(("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")):
                        ctx += int(line.split()[1])
        except (FileNotFoundError, ProcessLookupError):
            pass
    st = {"cpu_ns": cpu, "ctx": ctx, "t": now()}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith(("VmRSS", "VmHWM")):
                st[line.split(":")[0]] = int(line.split()[1])
            if line.startswith("Threads"):
                st["threads"] = int(line.split()[1])
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            for line in f:
                if line.startswith("Pss:"):
                    st["Pss"] = int(line.split()[1])
    except FileNotFoundError:
        pass
    gpu = {}
    vram = {}
    for fd in glob.glob(f"/proc/{pid}/fdinfo/*"):
        try:
            with open(fd) as f:
                info = dict(line.split(":", 1) for line in f if ":" in line)
        except OSError:
            continue
        cid = info.get("drm-client-id")
        if cid is None:
            continue
        gpu[cid] = sum(int(v.split()[0]) for k, v in info.items() if k.startswith("drm-engine-"))
        if "drm-memory-vram" in info:
            vram[cid] = int(info["drm-memory-vram"].split()[0])
    st["gpu_ns"] = sum(gpu.values())
    st["vram_kib"] = sum(vram.values())
    return st


def delta(a, b):
    dt = b["t"] - a["t"]
    return {
        "seconds": dt / 1e9,
        "cpu_ms": (b["cpu_ns"] - a["cpu_ns"]) / 1e6,
        "gpu_ms": (b["gpu_ns"] - a["gpu_ns"]) / 1e6,
        "ctx": b["ctx"] - a["ctx"],
    }


def frame_stats(pres, cpu):
    """Frame-time distribution from presentation times; cpu: delta() over
    the same window."""
    times = [tp for _, tp in pres]
    iv = sorted((b - a) / 1e6 for a, b in zip(times, times[1:]))
    dropped = sum(max(0, round(d * 1e6 / REFRESH_NS) - 1) for d in iv)
    n = len(times)

    def pct(p):
        return iv[min(len(iv) - 1, int(p * len(iv)))] if iv else None

    return {
        "frames": n,
        "fps": n / cpu["seconds"] if cpu["seconds"] else 0,
        "interval_p50_ms": pct(0.5),
        "interval_p99_ms": pct(0.99),
        "interval_max_ms": iv[-1] if iv else None,
        "dropped": dropped,
        "cpu_ms_per_frame": cpu["cpu_ms"] / n if n else None,
        "gpu_ms_per_frame": cpu["gpu_ms"] / n if n else None,
        "cpu_percent": 100 * cpu["cpu_ms"] / 1000 / cpu["seconds"],
    }


# Scenarios ------------------------------------------------------------------------------


class Run:
    def __init__(self, toolkit, scenario, renderer, screenshot, perf=None):
        self.toolkit = toolkit
        self.scenario = scenario
        self.result = {"toolkit": toolkit, "scenario": scenario}
        self.sway = Sway(renderer)
        self.inj = Injector(self.sway.env)
        self.log_path = os.path.join(self.sway.dir, "presshim.log")
        self.shim = Shim(self.log_path)
        self.screenshot = screenshot
        app_scenario = "gallery" if scenario == "resize" else scenario
        env = dict(self.sway.env, LD_PRELOAD=os.path.join(OUT, "presshim.so"), PRESSHIM_LOG=self.log_path)
        self.app_log = open(os.path.join(self.sway.dir, "app.log"), "w")
        t0 = now()
        self.app = subprocess.Popen(PROGRAMS[toolkit] + [app_scenario], env=env, stdout=self.app_log, stderr=subprocess.STDOUT)
        self.pid = self.app.pid
        self.main = set()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            self.shim.poll()
            self.main = self.shim.surfaces()
            pres = self.shim.presents(self.main)
            if pres:
                self.result["startup_ms"] = (pres[0][1] - t0) / 1e6
                break
            if self.app.poll() is not None:
                raise RuntimeError(f"{toolkit} {scenario} exited at startup")
            time.sleep(0.002)
        else:
            raise RuntimeError("no first frame")
        self.perf = None
        if perf:
            self.perf = subprocess.Popen(["perf", "record", "-q", "-F", "1999", "--call-graph", "dwarf,32768", "-p", str(self.pid),
                                          "-o", f"{perf}-{toolkit}-{scenario}.data"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.5)

    def settle(self, quiet=0.5, limit=10.0):
        """Waits until the main surface has not committed for `quiet` s."""
        end = time.monotonic() + limit
        while time.monotonic() < end:
            self.shim.poll()
            last = max((tc for s, tc in self.shim.commits.values()), default=0)
            if now() - last > quiet * 1e9:
                return
            time.sleep(0.05)

    def memory(self, key):
        st = proc_stats(self.pid)
        self.result[key] = {"rss_kib": st.get("VmRSS"), "pss_kib": st.get("Pss"), "hwm_kib": st.get("VmHWM"),
                            "vram_kib": st.get("vram_kib"), "threads": st.get("threads")}

    def window(self, seconds):
        """Measures idle cost over `seconds`."""
        a = proc_stats(self.pid)
        t0 = now()
        time.sleep(seconds)
        b = proc_stats(self.pid)
        self.shim.poll()
        d = delta(a, b)
        return {"cpu_percent": 100 * d["cpu_ms"] / 1000 / d["seconds"], "wakeups_per_s": d["ctx"] / d["seconds"],
                "commits": self.shim.commits_between(t0, now()), "gpu_ms": d["gpu_ms"]}

    def latency(self, cmds, surfaces=None, count=10, gap=0.25, after=None):
        """Input-to-photon: for each probe, the first presented commit made
        after the event was flushed to the compositor."""
        out = []
        for _ in range(count):
            t = self.inj.send(cmds[0])
            for c in cmds[1:]:
                self.inj.send(c)
            tp = self.shim.first_present_after(t[0], surfaces if surfaces is not None else self.main)
            if tp is not None:
                out.append((tp - t[0]) / 1e6)
            time.sleep(gap)
            if after:
                for c in after:
                    self.inj.send(c)
                time.sleep(gap)
        return out

    def frames(self, action):
        """Runs `action` and returns frame statistics of the main surface
        over its duration."""
        a = proc_stats(self.pid)
        t0 = now()
        action()
        t1 = now()
        b = proc_stats(self.pid)
        time.sleep(0.1)
        self.shim.poll()
        return frame_stats(self.shim.presents(self.main, t0, t1), delta(a, b))

    def shot(self, name):
        if self.screenshot:
            path = os.path.join(self.screenshot, f"{self.toolkit}-{name}.png")
            subprocess.run(["grim", path], env=self.sway.env, check=False)

    def finish(self):
        self.memory("memory_end")
        if self.perf:
            self.perf.send_signal(2)
            self.perf.wait()
        self.app.terminate()
        try:
            self.app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.app.kill()
        self.inj.stop()
        self.app_log.close()
        with open(os.path.join(self.sway.dir, "app.log")) as f:
            self.result["app_log"] = f.read()[-2000:]
        self.sway.stop()
        return self.result


def scenario_idle(r):
    r.settle()
    r.memory("memory")
    r.result["idle"] = r.window(10)
    r.shot("idle")


def scenario_gallery(r):
    r.settle()
    r.memory("memory")
    r.result["idle"] = r.window(5)
    r.shot("gallery")
    # Key: the text field has focus at start.
    r.result["key_ms"] = r.latency(["key a"], count=15)
    # Click: press on Default, which shows it pressed; release.
    r.inj.send("move 60 80")
    time.sleep(0.3)
    r.settle(0.2)
    r.result["click_ms"] = r.latency(["press"], after=["release"], count=15)
    # Menu: a click on Menu until it shows (siv: its popup surface; gpui
    # draws menus in the window).
    r.inj.send("move 314 80")
    time.sleep(0.3)
    r.settle(0.2)
    menu_surfaces = None if r.toolkit == "gpui" else set()
    out = []
    for i in range(8):
        t = r.inj.send("press")[0]
        r.inj.send("release")
        if r.toolkit == "siv":
            deadline = time.monotonic() + 1
            tp = None
            while time.monotonic() < deadline and tp is None:
                r.shim.poll()
                pop = r.shim.surfaces(popups=True)
                c = [tp_ for tc, tp_ in r.shim.presents(pop) if tc >= t]
                tp = min(c) if c else None
                time.sleep(0.005)
        else:
            tp = r.shim.first_present_after(t, r.main)
        if tp:
            out.append((tp - t) / 1e6)
        time.sleep(0.3)
        if i == 0:
            r.shot("gallery-menu")
        r.inj.send("key Escape")
        time.sleep(0.3)
    r.result["menu_ms"] = out
    del menu_surfaces


def scenario_list(r):
    r.settle()
    r.memory("memory")
    r.inj.send("move 640 400")
    time.sleep(0.3)
    r.settle(0.2)
    r.result["scroll"] = r.frames(lambda: r.inj.send(f"scrollburst {SCROLL_EVENT[r.toolkit]} 120 600", answers=600))
    r.settle(0.3)
    r.shot("list-scrolled")
    r.result["wheel_ms"] = r.latency(["wheel 1"], count=15)


def scenario_text(r):
    r.settle()
    r.memory("memory")
    r.result["idle"] = r.window(3)
    r.shot("text")
    r.result["key_ms"] = r.latency(["key x"], count=15)
    r.inj.send("move 640 400")
    time.sleep(0.3)
    r.settle(0.2)
    r.result["scroll"] = r.frames(lambda: r.inj.send(f"scrollburst {SCROLL_EVENT[r.toolkit]} 120 360", answers=360))
    r.settle(0.3)
    r.result["wheel_ms"] = r.latency(["wheel 1"], count=10)


def scenario_typing(r):
    r.settle()
    r.memory("memory")
    text = ("the quick brown fox jumps over the lazy dog " * 8)[:300]
    holder = {}

    def burst():
        holder["t"] = r.inj.send("typeburst 8 " + text, answers=len(text))

    r.result["burst"] = r.frames(burst)
    time.sleep(0.3)
    r.shim.poll()
    pres = r.shim.presents(r.main)
    lat = []
    for t in holder["t"]:
        c = [tp for tc, tp in pres if tc >= t]
        if c:
            lat.append((min(c) - t) / 1e6)
    r.result["key_ms"] = lat
    r.shot("typing")


def scenario_grid(r):
    time.sleep(2.0)  # every cell's delay has passed
    r.memory("memory")
    r.result["animation"] = r.frames(lambda: time.sleep(5))
    r.shot("grid")


def scenario_resize(r):
    r.sway.ipc(f"[pid={r.pid}] floating enable, resize set 1280 800, move position 0 0")
    r.settle(0.5)
    r.memory("memory")
    sizes = []
    w, h, dw, dh = 1280, 800, -8, -5
    for _ in range(180):
        w += dw
        h += dh
        if w <= 800 or w >= 1280:
            dw, dh = -dw, -dh
        sizes.append((w, h))
    times = []

    def storm():
        t = time.monotonic()
        for i, (w, h) in enumerate(sizes):
            while time.monotonic() < t + i / 60:
                time.sleep(0.0005)
            times.append(now())
            r.sway.ipc(f"[pid={r.pid}] resize set {w} {h}")
        time.sleep(0.2)

    r.result["storm"] = r.frames(storm)
    r.shim.poll()
    acks = sorted(t for _, t in r.shim.acks)
    pres = r.shim.presents(r.main)
    lat = []
    for t in times:
        ack = next((a for a in acks if a >= t), None)
        if ack is None:
            continue
        c = [tp for tc, tp in pres if tc >= ack]
        if c:
            lat.append((min(c) - t) / 1e6)
    r.result["resize_ms"] = lat
    r.result["acks"] = sum(1 for a in acks if times and a >= times[0])
    r.shot("resize")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--toolkits", default="siv,gpui")
    ap.add_argument("--scenarios", default=",".join(SCENARIOS))
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "raw"))
    ap.add_argument("--renderer", default="vulkan")
    ap.add_argument("--screenshots", default=None, help="directory for screenshots of the first run")
    ap.add_argument("--perf", default=None, help="record each run with perf into PREFIX-<toolkit>-<scenario>.data (distorts the numbers)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    if args.screenshots:
        os.makedirs(args.screenshots, exist_ok=True)
    for run in range(args.runs):
        for scenario in args.scenarios.split(","):
            for toolkit in args.toolkits.split(","):
                r = Run(toolkit, scenario, args.renderer, args.screenshots if run == 0 else None, args.perf)
                try:
                    globals()["scenario_" + scenario](r)
                finally:
                    res = r.finish()
                res["run"] = run
                res["loadavg"] = os.getloadavg()[0]
                with open(os.path.join(args.out, f"{toolkit}-{scenario}-{run}.json"), "w") as f:
                    json.dump(res, f, indent=1)
                print(f"{toolkit:5} {scenario:8} run {run}: startup {res.get('startup_ms', 0):.1f} ms", file=sys.stderr)


if __name__ == "__main__":
    main()
