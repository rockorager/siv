Median over 5 runs per cell, [min–max over runs].

| scenario | metric | siv before | siv after | gpui |
| --- | --- | --- | --- | --- |
| idle | startup to first frame (ms) | 28.0 [27.3–28.3] | 26.6 [25.3–35.5] | 70.3 [67.6–128.2] |
| idle | idle CPU (%) | 0.00 [0.00–0.00] | 0.00 [0.00–0.00] | 0.00 [0.00–0.00] |
| idle | idle wakeups (/s) | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] |
| idle | RSS after start (MiB) | 60.9 [60.8–61.0] | 55.5 [55.3–55.6] | 76.1 [75.4–76.2] |
| idle | PSS after start (MiB) | 38.1 [38.1–38.2] | 36.9 [36.8–37.0] | 53.0 [52.4–53.1] |
| idle | GPU memory (MiB) | 43.3 [43.3–43.3] | 43.3 [43.3–43.3] | 81.5 [81.4–81.5] |
| idle | threads | 20 [20–20] | 28 [28–28] | 27 [27–27] |
| gallery | startup to first frame (ms) | 37.8 [37.0–40.3] | 34.6 [33.4–35.7] | 72.8 [67.6–106.9] |
| gallery | idle wakeups (/s) | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] |
| gallery | RSS (MiB) | 77.1 [76.6–77.4] | 70.0 [69.6–70.7] | 76.8 [75.8–77.2] |
| gallery | key to photon, median (ms) | 1.97 [1.85–2.06] | 2.01 [1.77–2.45] | 2.36 [2.14–2.74] |
| gallery | key to photon, max (ms) | 3.24 [2.48–4.05] | 2.84 [2.33–3.21] | 18.39 [18.08–18.68] |
| gallery | click to photon, median (ms) | 1.53 [1.47–1.61] | 1.63 [1.51–1.76] | 2.16 [1.96–2.20] |
| gallery | click to menu shown, median (ms) | 19.65 [19.58–19.79] | 5.64 [5.42–5.92] | 2.44 [2.33–2.97] |
| list | startup to first frame (ms) | 29.2 [28.3–30.2] | 26.8 [26.1–32.2] | 74.0 [71.9–78.5] |
| list | RSS (MiB) | 77.6 [75.0–79.8] | 60.5 [58.3–60.7] | 77.4 [76.9–77.8] |
| list | scroll: frames presented in 5 s | 304 [303–305] | 301 [300–302] | 302 [301–303] |
| list | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| list | scroll: frame interval p50 (ms) | 16.38 [16.36–16.38] | 16.60 [16.53–16.62] | 16.51 [16.46–16.54] |
| list | scroll: frame interval p99 (ms) | 17.16 [17.10–17.19] | 17.31 [17.25–17.34] | 17.21 [17.08–17.36] |
| list | scroll: frame interval max (ms) | 17.35 [17.26–17.64] | 17.63 [17.37–17.68] | 17.35 [17.27–17.68] |
| list | scroll: CPU per frame (ms) | 2.39 [2.34–2.48] | 1.50 [1.43–1.51] | 2.12 [1.93–2.13] |
| list | scroll: GPU per frame (ms) | 1.68 [1.67–1.70] | 1.02 [1.02–1.09] | 0.96 [0.94–0.99] |
| list | scroll: CPU (% of a core) | 14.6 [14.2–15.1] | 9.1 [8.6–9.1] | 12.8 [11.7–12.9] |
| list | wheel to photon, median (ms) | 2.49 [2.43–2.74] | 1.70 [1.60–1.85] | 3.27 [3.11–3.53] |
| text | startup to first frame (ms) | 99.4 [97.9–100.5] | 98.6 [97.6–101.6] | 86.6 [82.6–89.3] |
| text | RSS (MiB) | 283.5 [281.9–287.7] | 162.7 [161.5–164.7] | 81.9 [81.8–82.4] |
| text | key to photon, median (ms) | 22.19 [21.00–56.36] | 3.30 [2.97–3.32] | 3.55 [3.41–3.92] |
| text | key to photon, max (ms) | 24.83 [23.04–59.27] | 4.76 [4.13–6.17] | 20.05 [19.52–20.28] |
| text | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| text | scroll: frame interval p99 (ms) | 17.28 [17.10–17.32] | 17.23 [17.21–17.28] | 17.20 [17.07–17.25] |
| text | scroll: CPU per frame (ms) | 1.77 [1.63–1.92] | 1.31 [1.24–1.40] | 2.68 [2.65–2.87] |
| text | scroll: GPU per frame (ms) | 1.22 [1.16–1.24] | 1.25 [1.20–1.29] | 0.59 [0.56–0.61] |
| text | wheel to photon, median (ms) | 2.50 [2.45–2.88] | 2.04 [1.63–2.17] | 3.87 [3.83–4.03] |
| grid | startup to first frame (ms) | 35.3 [34.0–37.1] | 33.2 [32.8–35.0] | 94.3 [92.8–100.4] |
| grid | frames presented in 5 s | 301 [300–301] | 300 [299–302] | 303 [301–304] |
| grid | dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| grid | frame interval p50 (ms) | 16.57 [16.55–16.72] | 16.61 [16.56–16.72] | 16.42 [16.40–16.47] |
| grid | frame interval p99 (ms) | 17.24 [17.23–17.26] | 17.29 [17.18–17.30] | 17.22 [17.18–17.57] |
| grid | frame interval max (ms) | 17.35 [17.29–17.56] | 17.64 [17.30–17.72] | 17.45 [17.39–17.75] |
| grid | CPU per frame (ms) | 2.09 [2.06–2.19] | 2.17 [1.94–2.36] | 6.21 [6.06–6.35] |
| grid | GPU per frame (ms) | 0.96 [0.93–1.00] | 0.99 [0.95–1.03] | 0.46 [0.45–0.50] |
| grid | CPU (% of a core) | 12.6 [12.4–13.2] | 13.0 [11.7–14.1] | 37.7 [36.6–38.5] |
| grid | RSS (MiB) | 68.1 [66.7–69.9] | 63.2 [61.3–64.3] | 86.3 [85.3–86.9] |
| typing | key to photon, median (ms) | 24.17 [24.04–24.27] | 24.02 [23.80–24.05] | 23.98 [23.76–24.33] |
| typing | key to photon, p99 (ms) | 32.65 [32.56–32.89] | 32.38 [32.30–32.65] | 32.39 [32.24–32.47] |
| typing | key to photon, max (ms) | 33.02 [32.79–33.10] | 32.83 [32.53–33.16] | 32.72 [32.61–33.03] |
| typing | frames presented | 145 [144–145] | 145 [145–145] | 144 [144–145] |
| typing | CPU per frame (ms) | 1.93 [1.83–1.99] | 1.96 [1.91–2.00] | 3.14 [2.80–3.20] |
| typing | CPU (% of a core) | 11.7 [11.1–12.1] | 11.9 [11.6–12.1] | 18.9 [17.0–19.2] |
| resize | configures acknowledged | 360 [360–360] | 360 [360–360] | 360 [360–360] |
| resize | frames presented | 172 [170–174] | 173 [170–174] | 169 [165–172] |
| resize | resize to photon, median (ms) | 10.89 [10.52–11.17] | 10.63 [10.40–11.07] | 10.94 [10.69–11.29] |
| resize | resize to photon, p99 (ms) | 50.14 [49.75–66.43] | 50.13 [49.58–50.15] | 66.54 [50.21–66.90] |
| resize | resize to photon, max (ms) | 50.58 [49.82–67.11] | 50.31 [49.94–66.76] | 66.77 [50.32–82.94] |
| resize | frame interval max (ms) | 64.51 [64.48–80.74] | 64.55 [64.49–80.60] | 80.48 [64.50–96.48] |
| resize | CPU per frame (ms) | 1.78 [1.72–1.86] | 1.47 [1.37–1.59] | 2.33 [2.27–2.48] |
| resize | CPU (% of a core) | 9.6 [9.4–9.9] | 8.0 [7.4–8.5] | 12.4 [12.2–12.8] |
| all | stripped binary size (MiB) | 10.7 (libsiv.so 10.7 + program 22 KiB) | 10.7 (libsiv.so 10.7 + program 22 KiB) | 21.3 |
