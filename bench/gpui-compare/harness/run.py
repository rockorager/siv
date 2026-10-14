#!/usr/bin/env python3
"""Runs the comparison scenarios (siv, gpui, Qt, GTK) on headless sway with
GPU rendering.

    harness/run.py [--runs N] [--toolkits siv,gpui,qt,gtk] [--scenarios a,b] [--out DIR]
                   [--warmup]

Each run starts a fresh sway (headless backend, Vulkan renderer on the
render node, one 1280x800 output at 60 Hz, scale 1, no borders), the
toolkit's program for one scenario with presshim.so preloaded, and inject
for input. Every toolkit renders with Vulkan on the same GPU; run.py stops
if the render node's Vulkan device is not a GPU. Results go to
DIR/<toolkit>-<scenario>-<run>.json, the machine to DIR/machine.json;
report.py summarizes them.
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
RENDER_NODE = os.environ.get("GC_RENDER_NODE", "/dev/dri/renderD128")
PROGRAMS = {
    # GC_SIV_BENCH runs another build of the siv program (an older siv).
    "siv": [os.environ.get("GC_SIV_BENCH", os.path.join(OUT, "siv-bench"))],
    "gpui": [os.path.join(ROOT, "gpui", "target", "release", "gpui-compare")],
    "qt": [os.path.join(OUT, "qt-bench")],
    "gtk": [os.path.join(OUT, "gtk-bench")],
}
# Every toolkit on Vulkan, named rather than left to each toolkit's choice:
# Qt Quick's scene graph through QRhi, GTK's Vulkan renderer (its default
# on Wayland since 4.16). siv and gpui use Vulkan only. Qt's logging rules
# and GSK_DEBUG print the renderer and device each picked into the
# result's app_log, as siv does on its own.
TOOLKIT_ENV = {
    "qt": {"QT_QPA_PLATFORM": "wayland", "QSG_RHI_BACKEND": "vulkan",
           "QT_LOGGING_RULES": "qt.scenegraph.general=true;qt.rhi.general=true", "QT_FORCE_STDERR_LOGGING": "1"},
    "gtk": {"GSK_RENDERER": "vulkan", "GDK_BACKEND": "wayland", "GSK_DEBUG": "renderer"},
}
# Toolkits whose menus are xdg_popup surfaces; gpui draws its menus inside
# the window.
POPUP_MENUS = {"siv", "qt", "gtk"}
# Where the gallery's Default and Menu buttons are, in window coordinates:
# each toolkit's stock buttons have their own widths.
GALLERY_POINTS = {
    "siv": {"default": (60, 80), "menu": (314, 80)},
    "gpui": {"default": (60, 80), "menu": (314, 80)},
    "qt": {"default": (64, 81), "menu": (328, 81)},
    "gtk": {"default": (66, 81), "menu": (350, 81)},
}
SCENARIOS = ["idle", "gallery", "list", "text", "grid", "typing", "resize", "logs"]
# The Qt and GTK programs leave out the 100 MB log.
UNSUPPORTED = {"qt": {"logs"}, "gtk": {"logs"}}
# Touchpad scroll per event, so that every toolkit moves 30 logical px:
# gpui multiplies touchpad deltas by 3 (gpui_linux's Wayland client,
# `let modifier = 3.0`), siv by 4 since 37a1911 (D16; 1:1 before, when
# this was 30), GTK by 2.5. Qt's were measured: the list scrolled about
# 8 times the distance sent. With these, 600 events end every list on
# row 644 (Qt 643).
SCROLL_EVENT = {"siv": 7.5, "gpui": 10, "qt": 30, "gtk": 12}
# In the editors, as many paragraphs per second as siv's 30 px per event
# (measured: 360 events end siv and gpui on paragraph 223, Qt on 227, GTK
# on 222). QPlainTextEdit scrolls by lines, and line heights differ (20 px
# in siv and gpui, about 18 in Qt and GTK).
TEXT_SCROLL_EVENT = dict(SCROLL_EVENT, qt=29.7, gtk=10.6)


def now():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


# Sway ---------------------------------------------------------------------------


class Sway:
    def __init__(self):
        self.dir = f"/tmp/gpui-compare-{os.getpid()}-{now()}"
        os.makedirs(self.dir, mode=0o700)
        with open(os.path.join(self.dir, "config"), "w") as f:
            f.write("output * mode 1280x800@60Hz position 0 0 scale 1\n"
                    "default_border none\ndefault_floating_border none\n"
                    "focus_follows_mouse no\n")
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin"),
            "HOME": os.environ.get("HOME", "/root"),
            "XDG_RUNTIME_DIR": self.dir,
            "WAYLAND_DISPLAY": "wayland-1",
            "LC_ALL": "C.UTF-8",
        }
        senv = dict(self.env, WLR_BACKENDS="headless", WLR_RENDERER="vulkan", WLR_LIBINPUT_NO_DEVICES="1",
                    WLR_RENDER_DRM_DEVICE=RENDER_NODE)
        if os.environ.get("GC_KMS"):
            # A KMS output with real vblank timing: sway's DRM backend on
            # the KMS device named (vkms, say), rendering on the GPU.
            senv.update(WLR_BACKENDS="drm", WLR_DRM_DEVICES=os.environ["GC_KMS"], LIBSEAT_BACKEND="noop")
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


def task_stats(pid):
    """CPU time (ns) and context switches of each live thread, by tid."""
    tasks = {}
    for task in glob.glob(f"/proc/{pid}/task/*"):
        try:
            with open(task + "/schedstat") as f:
                cpu = int(f.read().split()[0])
            ctx = 0
            with open(task + "/status") as f:
                for line in f:
                    if line.startswith(("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")):
                        ctx += int(line.split()[1])
            tasks[os.path.basename(task)] = (cpu, ctx)
        except (FileNotFoundError, ProcessLookupError):
            pass
    return tasks


def proc_stats(pid):
    # Per thread: threads that exit (siv's pool retires idle workers)
    # take their counts with them, so sums over live threads can drop.
    st = {"tasks": task_stats(pid), "t": now()}
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
    gtt = {}
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
        if "drm-memory-gtt" in info:
            gtt[cid] = int(info["drm-memory-gtt"].split()[0])
    st["gpu_ns"] = sum(gpu.values())
    st["vram_kib"] = sum(vram.values())
    st["gtt_kib"] = sum(gtt.values())
    st["drm_clients"] = len(gpu)
    return st


def delta(a, b):
    """CPU, GPU, and context switches between two proc_stats: each
    thread's change, from zero for threads started in between; a thread
    that exited counts up to its last sample in b["tasks"] (see
    `Run.window`), else not at all."""
    dt = b["t"] - a["t"]
    cpu = ctx = 0
    for tid, (c1, x1) in b["tasks"].items():
        c0, x0 = a["tasks"].get(tid, (0, 0))
        cpu += c1 - c0
        ctx += x1 - x0
    return {
        "seconds": dt / 1e9,
        "cpu_ms": cpu / 1e6,
        "gpu_ms": (b["gpu_ns"] - a["gpu_ns"]) / 1e6,
        "ctx": ctx,
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
    def __init__(self, toolkit, scenario, screenshot, perf=None):
        self.toolkit = toolkit
        self.scenario = scenario
        self.result = {"toolkit": toolkit, "scenario": scenario}
        self.sway = Sway()
        self.inj = Injector(self.sway.env)
        self.log_path = os.path.join(self.sway.dir, "presshim.log")
        self.shim = Shim(self.log_path)
        self.screenshot = screenshot
        app_scenario = "gallery" if scenario == "resize" else scenario
        startup_limit = 60 if scenario == "logs" else 15
        env = dict(self.sway.env, LD_PRELOAD=os.path.join(OUT, "presshim.so"), PRESSHIM_LOG=self.log_path)
        env.update(TOOLKIT_ENV.get(toolkit, {}))
        # SIV_* variables reach the program (for experiments).
        env.update({k: v for k, v in os.environ.items() if k.startswith("SIV_")})
        self.app_log = open(os.path.join(self.sway.dir, "app.log"), "w")
        t0 = now()
        self.app = subprocess.Popen(PROGRAMS[toolkit] + [app_scenario], env=env, stdout=self.app_log, stderr=subprocess.STDOUT)
        self.pid = self.app.pid
        self.main = set()
        deadline = time.monotonic() + startup_limit
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
                            "vram_kib": st.get("vram_kib"), "gtt_kib": st.get("gtt_kib"), "threads": st.get("threads"),
                            "drm_clients": st.get("drm_clients"), "gpu_total_ms": st.get("gpu_ns", 0) / 1e6}

    def window(self, seconds):
        """Measures idle cost over `seconds`."""
        a = proc_stats(self.pid)
        t0 = now()
        # Threads seen during the window keep their last counts.
        seen = {}
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            seen.update(task_stats(self.pid))
            time.sleep(0.05)
        b = proc_stats(self.pid)
        b["tasks"] = {**seen, **b["tasks"]}
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
    r.memory("memory_idle")
    r.shot("idle")


def scenario_gallery(r):
    r.settle()
    r.memory("memory")
    r.result["idle"] = r.window(5)
    r.shot("gallery")
    # Key: the text field has focus at start.
    r.result["key_ms"] = r.latency(["key a"], count=15)
    # Click: press on Default, which shows it pressed; release.
    points = GALLERY_POINTS[r.toolkit]
    r.inj.send("move %d %d" % points["default"])
    time.sleep(0.3)
    r.settle(0.2)
    r.result["click_ms"] = r.latency(["press"], after=["release"], count=15)
    # Menu: a click on Menu until it shows (siv, Qt, GTK: its popup
    # surface; gpui draws menus in the window).
    r.inj.send("move %d %d" % points["menu"])
    time.sleep(0.3)
    r.settle(0.2)
    out = []
    for i in range(8):
        t = r.inj.send("press")[0]
        r.inj.send("release")
        if r.toolkit in POPUP_MENUS:
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


def jumps(r):
    """Ctrl+End and Ctrl+Home: the caret to the end or the start, shown;
    F3: the caret to the search result, shown (from the start each time)."""
    end, home, search = [], [], []
    for i in range(5):
        end += r.latency(["key ctrl+End"], count=1, gap=0.4)
        if i == 0:
            r.shot(r.scenario + "-end")
        home += r.latency(["key ctrl+Home"], count=1, gap=0.4)
    for i in range(5):
        search += r.latency(["key F3"], count=1, gap=0.4)
        if i == 0:
            r.shot(r.scenario + "-search")
        r.latency(["key ctrl+Home"], count=1, gap=0.4)
    r.result["jump_end_ms"] = end
    r.result["jump_home_ms"] = home
    r.result["search_ms"] = search


def scenario_text(r):
    r.settle()
    r.memory("memory")
    r.result["idle"] = r.window(3)
    r.shot(r.scenario)
    r.result["key_ms"] = r.latency(["key x"], count=15)
    r.inj.send("move 640 400")
    time.sleep(0.3)
    r.settle(0.2)
    r.result["scroll"] = r.frames(lambda: r.inj.send(f"scrollburst {TEXT_SCROLL_EVENT[r.toolkit]} 120 360", answers=360))
    r.settle(0.3)
    r.shot(r.scenario + "-scrolled")
    r.result["wheel_ms"] = r.latency(["wheel 1"], count=10)
    jumps(r)


def scenario_logs(r):
    # The same steps over 100 MB of log lines; background work may take a
    # while to go quiet.
    r.settle(0.5, limit=60)
    scenario_text(r)


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


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def machine():
    """The machine, GPU, driver, and toolkit versions; exits unless the
    Vulkan devices include a GPU (vulkaninfo, from vulkan-tools)."""
    gpus = []
    for block in sh("vulkaninfo --summary 2>/dev/null").split("\nGPU")[1:]:
        fields = dict(map(str.strip, line.split(" = ", 1)) for line in block.splitlines() if " = " in line)
        gpus.append({k: fields.get(k) for k in ("deviceName", "deviceType", "driverName", "driverInfo", "apiVersion")})
    if not any(g["deviceType"] in ("PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU", "PHYSICAL_DEVICE_TYPE_DISCRETE_GPU") for g in gpus):
        sys.exit(f"run.py: no Vulkan GPU (vulkaninfo found {gpus}); this bench measures GPU rendering only")
    if not os.path.exists(RENDER_NODE):
        sys.exit(f"run.py: no render node {RENDER_NODE} (GC_RENDER_NODE names another)")
    cpufreq = "/sys/devices/system/cpu/cpu0/cpufreq/"
    return {
        "vulkan_devices": gpus,
        "render_node": RENDER_NODE,
        "cpu": sh("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2"),
        "cpus": os.cpu_count(),
        "memory": sh("grep MemTotal /proc/meminfo"),
        "kernel": os.uname().release,
        "governor": sh(f"cat {cpufreq}scaling_governor {cpufreq}energy_performance_preference 2>/dev/null").replace("\n", " "),
        "sway": sh("sway --version"),
        "gtk": sh("pkg-config --modversion gtk4"),
        "qt": sh("pkg-config --modversion Qt6Quick"),
        "siv_commit": sh(f"git -C {ROOT} rev-parse HEAD"),
        "siv_dirty": bool(sh(f"git -C {ROOT} status --porcelain --untracked-files=no")),
        "zed_commit": sh(f"git -C {os.path.join(ROOT, 'gpui', 'zed')} rev-parse HEAD 2>/dev/null"),
        "date": time.strftime("%Y-%m-%d %H:%M %z"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--toolkits", default="siv,gpui,qt,gtk")
    ap.add_argument("--scenarios", default=",".join(SCENARIOS))
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "raw"))
    ap.add_argument("--screenshots", default=None, help="directory for screenshots of the first run")
    ap.add_argument("--perf", default=None, help="record each run with perf into PREFIX-<toolkit>-<scenario>.data (distorts the numbers)")
    ap.add_argument("--warmup", action="store_true", help="first run each program once per scenario, unrecorded (caches)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "machine.json"), "w") as f:
        json.dump(machine(), f, indent=1)
    if args.screenshots:
        os.makedirs(args.screenshots, exist_ok=True)
    for run in range(-1 if args.warmup else 0, args.runs):
        for scenario in args.scenarios.split(","):
            for toolkit in args.toolkits.split(","):
                if scenario in UNSUPPORTED.get(toolkit, ()):
                    continue
                r = Run(toolkit, scenario, args.screenshots if run == 0 else None, args.perf)
                try:
                    globals()["scenario_" + scenario](r)
                finally:
                    res = r.finish()
                # A program that never submitted work to the GPU drew on the
                # CPU (or on a CPU Vulkan driver): not what this bench measures.
                if not res["memory_end"]["gpu_total_ms"]:
                    sys.exit(f"run.py: {toolkit} {scenario} submitted no GPU work on {RENDER_NODE}; refusing a CPU-rendered result")
                if run < 0:
                    continue
                res["run"] = run
                res["loadavg"] = os.getloadavg()[0]
                with open(os.path.join(args.out, f"{toolkit}-{scenario}-{run}.json"), "w") as f:
                    json.dump(res, f, indent=1)
                print(f"{toolkit:5} {scenario:8} run {run}: startup {res.get('startup_ms', 0):.1f} ms", file=sys.stderr)


if __name__ == "__main__":
    main()
