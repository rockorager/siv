Median over 5 runs per cell, [min–max over runs].

| scenario | metric | siv | gpui |
| --- | --- | --- | --- |
| idle | startup to first frame (ms) | 28.0 [27.6–28.6] | 67.9 [65.1–72.7] |
| idle | idle CPU (%) | 0.00 [0.00–0.00] | 0.00 [0.00–0.00] |
| idle | idle wakeups (/s) | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] |
| idle | RSS after start (MiB) | 60.5 [60.2–60.6] | 76.6 [76.2–76.7] |
| idle | PSS after start (MiB) | 37.8 [37.5–37.8] | 47.2 [46.9–47.2] |
| idle | GPU memory (MiB) | 43.3 [43.3–43.3] | 81.5 [81.5–81.5] |
| idle | threads | 20 [20–20] | 27 [27–27] |
| gallery | startup to first frame (ms) | 37.3 [35.1–38.0] | 71.3 [66.7–73.2] |
| gallery | idle wakeups (/s) | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] |
| gallery | RSS (MiB) | 76.3 [75.9–77.2] | 77.4 [76.7–77.6] |
| gallery | key to photon, median (ms) | 2.09 [2.07–2.23] | 2.40 [2.32–2.41] |
| gallery | key to photon, max (ms) | 4.02 [3.88–4.13] | 18.46 [17.79–18.97] |
| gallery | click to photon, median (ms) | 1.71 [1.48–1.79] | 2.29 [2.11–2.42] |
| gallery | click to menu shown, median (ms) | 19.79 [19.61–19.89] | 2.36 [2.28–2.83] |
| list | startup to first frame (ms) | 30.8 [29.3–32.3] | 70.7 [69.8–74.5] |
| list | RSS (MiB) | 77.8 [76.3–81.4] | 78.2 [77.8–78.8] |
| list | scroll: frames presented in 5 s | 304 [304–305] | 302 [301–303] |
| list | scroll: dropped frames | 0 [0–0] | 0 [0–0] |
| list | scroll: frame interval p50 (ms) | 16.37 [16.36–16.38] | 16.51 [16.48–16.54] |
| list | scroll: frame interval p99 (ms) | 17.15 [17.00–17.19] | 17.23 [17.19–17.26] |
| list | scroll: frame interval max (ms) | 17.38 [17.31–17.66] | 17.38 [17.31–17.66] |
| list | scroll: CPU per frame (ms) | 3.93 [3.80–3.97] | 2.24 [2.13–2.28] |
| list | scroll: GPU per frame (ms) | 1.73 [1.73–1.74] | 0.96 [0.95–0.99] |
| list | scroll: CPU (% of a core) | 23.9 [23.2–24.1] | 13.6 [12.9–13.8] |
| list | wheel to photon, median (ms) | 2.73 [2.49–2.94] | 3.30 [3.13–3.58] |
| text | startup to first frame (ms) | 102.5 [102.1–104.9] | 82.7 [78.9–87.3] |
| text | RSS (MiB) | 536.3 [531.1–560.1] | 82.6 [82.5–82.8] |
| text | key to photon, median (ms) | 606.49 [602.86–613.41] | 3.50 [3.29–3.97] |
| text | key to photon, max (ms) | 613.59 [608.03–618.03] | 19.85 [19.51–19.99] |
| text | scroll: dropped frames | 0 [0–0] | 0 [0–0] |
| text | scroll: frame interval p99 (ms) | 17.23 [17.15–17.28] | 17.17 [16.92–17.27] |
| text | scroll: CPU per frame (ms) | 1.76 [1.64–1.88] | 3.03 [2.82–3.14] |
| text | scroll: GPU per frame (ms) | 1.22 [1.18–1.23] | 0.57 [0.50–0.61] |
| text | wheel to photon, median (ms) | 2.55 [2.40–2.63] | 3.78 [3.52–4.08] |
| grid | startup to first frame (ms) | 36.5 [32.7–36.8] | 92.1 [87.0–93.7] |
| grid | frames presented in 5 s | 217 [216–218] | 303 [301–304] |
| grid | dropped frames | 0 [0–1] | 0 [0–0] |
| grid | frame interval p50 (ms) | 23.05 [22.98–23.12] | 16.43 [16.40–16.54] |
| grid | frame interval p99 (ms) | 23.75 [23.44–23.84] | 17.26 [17.23–17.35] |
| grid | frame interval max (ms) | 24.03 [23.93–25.82] | 17.51 [17.32–17.59] |
| grid | CPU per frame (ms) | 22.88 [22.68–22.92] | 6.23 [6.09–6.26] |
| grid | GPU per frame (ms) | 18.68 [18.52–18.74] | 0.48 [0.45–0.51] |
| grid | CPU (% of a core) | 99.0 [98.8–99.3] | 37.6 [37.0–38.0] |
| grid | RSS (MiB) | 79.6 [75.7–80.6] | 87.1 [85.9–87.5] |
| typing | key to photon, median (ms) | 23.92 [23.85–24.00] | 24.22 [23.98–24.31] |
| typing | key to photon, p99 (ms) | 32.46 [32.43–32.69] | 32.69 [32.45–32.72] |
| typing | key to photon, max (ms) | 32.90 [32.68–33.27] | 32.82 [32.69–33.12] |
| typing | frames presented | 145 [145–146] | 144 [143–144] |
| typing | CPU per frame (ms) | 3.42 [3.35–3.49] | 3.16 [2.81–3.18] |
| typing | CPU (% of a core) | 20.7 [20.3–21.2] | 18.8 [16.9–19.1] |
| resize | configures acknowledged | 360 [360–360] | 360 [360–360] |
| resize | frames presented | 171 [170–172] | 169 [167–172] |
| resize | resize to photon, median (ms) | 10.98 [10.88–11.12] | 10.86 [10.76–11.20] |
| resize | resize to photon, p99 (ms) | 66.38 [50.16–66.47] | 66.21 [50.59–66.52] |
| resize | resize to photon, max (ms) | 66.41 [66.09–82.75] | 66.69 [66.46–66.99] |
| resize | frame interval max (ms) | 80.60 [80.51–96.45] | 80.50 [80.41–80.61] |
| resize | CPU per frame (ms) | 1.86 [1.83–1.89] | 2.33 [2.24–2.36] |
| resize | CPU (% of a core) | 10.0 [9.8–10.1] | 12.3 [11.9–12.6] |
| all | stripped binary size (MiB) | 10.4 (libsiv.so 10.3 + program 22 KiB) | 21.3 |
