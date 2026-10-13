Median over 5 runs per cell, [min–max over runs].

| scenario | metric | siv before | siv after | gpui |
| --- | --- | --- | --- | --- |
| idle | startup to first frame (ms) | 26.6 [25.3–35.5] | 25.8 [25.6–27.4] | 71.4 [71.3–81.7] |
| idle | idle CPU (%) | 0.00 [0.00–0.00] | 0.00 [0.00–0.00] | 0.00 [0.00–0.00] |
| idle | idle wakeups (/s) | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] |
| idle | RSS after start (MiB) | 55.5 [55.3–55.6] | 56.0 [55.9–56.0] | 75.8 [75.3–76.2] |
| idle | PSS after start (MiB) | 36.9 [36.8–37.0] | 37.4 [37.3–37.4] | 52.7 [52.2–53.2] |
| idle | GPU memory (MiB) | 43.3 [43.3–43.3] | 43.3 [43.3–43.3] | 81.5 [81.4–81.5] |
| idle | threads | 28 [28–28] | 28 [28–28] | 27 [27–27] |
| idle | threads after 10 s idle | – | 8 [8–8] | 27 [27–27] |
| gallery | startup to first frame (ms) | 34.6 [33.4–35.7] | 35.9 [34.2–37.2] | 71.7 [70.1–79.6] |
| gallery | idle wakeups (/s) | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] |
| gallery | RSS (MiB) | 70.0 [69.6–70.7] | 70.2 [69.7–70.5] | 76.9 [75.9–77.3] |
| gallery | key to photon, median (ms) | 2.01 [1.77–2.45] | 1.92 [1.80–2.14] | 2.36 [2.30–2.39] |
| gallery | key to photon, max (ms) | 2.84 [2.33–3.21] | 2.87 [2.50–2.95] | 17.81 [17.69–18.57] |
| gallery | click to photon, median (ms) | 1.63 [1.51–1.76] | 1.65 [1.54–1.88] | 2.21 [2.17–2.27] |
| gallery | click to menu shown, median (ms) | 5.64 [5.42–5.92] | 3.27 [3.00–3.71] | 2.45 [2.25–2.72] |
| list | startup to first frame (ms) | 26.8 [26.1–32.2] | 28.9 [27.5–29.8] | 72.6 [71.3–82.2] |
| list | RSS (MiB) | 60.5 [58.3–60.7] | 58.7 [58.6–60.7] | 77.6 [77.3–77.8] |
| list | scroll: frames presented in 5 s | 301 [300–302] | 301 [300–302] | 303 [302–303] |
| list | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| list | scroll: frame interval p50 (ms) | 16.60 [16.53–16.62] | 16.55 [16.53–16.65] | 16.48 [16.39–16.52] |
| list | scroll: frame interval p99 (ms) | 17.31 [17.25–17.34] | 17.31 [17.27–17.38] | 17.16 [17.13–17.21] |
| list | scroll: frame interval max (ms) | 17.63 [17.37–17.68] | 17.66 [17.33–17.74] | 17.49 [17.29–17.64] |
| list | scroll: CPU per frame (ms) | 1.50 [1.43–1.51] | 1.50 [1.48–1.62] | 2.01 [1.88–2.08] |
| list | scroll: GPU per frame (ms) | 1.02 [1.02–1.09] | 0.72 [0.71–0.73] | 0.95 [0.94–0.98] |
| list | scroll: CPU (% of a core) | 9.1 [8.6–9.1] | 9.1 [8.9–9.7] | 12.2 [11.4–12.6] |
| list | wheel to photon, median (ms) | 1.70 [1.60–1.85] | 1.69 [1.54–1.82] | 3.07 [3.02–3.45] |
| text | startup to first frame (ms) | 98.6 [97.6–101.6] | 38.0 [34.4–39.0] | 82.8 [77.1–85.8] |
| text | RSS (MiB) | 162.7 [161.5–164.7] | 149.0 [146.5–150.8] | 82.0 [81.8–82.2] |
| text | key to photon, median (ms) | 3.30 [2.97–3.32] | 3.17 [2.99–3.47] | 3.48 [3.09–3.57] |
| text | key to photon, max (ms) | 4.76 [4.13–6.17] | 5.88 [4.28–6.77] | 19.53 [19.31–19.88] |
| text | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| text | scroll: frame interval p99 (ms) | 17.23 [17.21–17.28] | 17.26 [17.19–17.35] | 17.21 [17.12–17.25] |
| text | scroll: CPU per frame (ms) | 1.31 [1.24–1.40] | 1.33 [1.28–1.49] | 2.64 [2.56–2.82] |
| text | scroll: GPU per frame (ms) | 1.25 [1.20–1.29] | 0.97 [0.95–0.99] | 0.57 [0.55–0.60] |
| text | wheel to photon, median (ms) | 2.04 [1.63–2.17] | 2.03 [1.94–2.26] | 3.85 [3.65–4.03] |
| grid | startup to first frame (ms) | 33.2 [32.8–35.0] | 36.2 [32.7–36.9] | 90.6 [90.2–101.2] |
| grid | frames presented in 5 s | 300 [299–302] | 301 [300–301] | 303 [301–303] |
| grid | dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| grid | frame interval p50 (ms) | 16.61 [16.56–16.72] | 16.58 [16.57–16.62] | 16.46 [16.42–16.54] |
| grid | frame interval p99 (ms) | 17.29 [17.18–17.30] | 17.28 [17.23–17.41] | 17.22 [17.16–17.50] |
| grid | frame interval max (ms) | 17.64 [17.30–17.72] | 17.38 [17.26–17.62] | 17.38 [17.24–17.63] |
| grid | CPU per frame (ms) | 2.17 [1.94–2.36] | 2.14 [2.09–2.16] | 6.16 [6.06–6.25] |
| grid | GPU per frame (ms) | 0.99 [0.95–1.03] | 0.89 [0.87–0.96] | 0.50 [0.46–0.52] |
| grid | CPU (% of a core) | 13.0 [11.7–14.1] | 12.9 [12.6–13.0] | 37.3 [36.7–37.9] |
| grid | RSS (MiB) | 63.2 [61.3–64.3] | 64.2 [62.6–64.5] | 86.8 [86.5–86.9] |
| typing | key to photon, median (ms) | 24.02 [23.80–24.05] | 23.92 [23.85–24.37] | 24.14 [24.09–24.25] |
| typing | key to photon, p99 (ms) | 32.38 [32.30–32.65] | 32.46 [32.29–32.72] | 32.55 [32.41–32.76] |
| typing | key to photon, max (ms) | 32.83 [32.53–33.16] | 32.71 [32.61–33.02] | 32.92 [32.79–33.09] |
| typing | frames presented | 145 [145–145] | 145 [145–146] | 144 [144–145] |
| typing | CPU per frame (ms) | 1.96 [1.91–2.00] | 1.89 [1.87–1.97] | 2.98 [2.95–3.14] |
| typing | CPU (% of a core) | 11.9 [11.6–12.1] | 11.5 [11.3–11.9] | 18.0 [17.7–18.9] |
| resize | configures acknowledged | 360 [360–360] | 360 [360–360] | 360 [360–360] |
| resize | frames presented | 173 [170–174] | 173 [172–173] | 169 [167–170] |
| resize | resize to photon, median (ms) | 10.63 [10.40–11.07] | 11.08 [10.75–11.10] | 10.84 [10.81–10.94] |
| resize | resize to photon, p99 (ms) | 50.13 [49.58–50.15] | 50.00 [49.90–50.83] | 66.26 [50.46–66.32] |
| resize | resize to photon, max (ms) | 50.31 [49.94–66.76] | 50.49 [50.15–66.66] | 66.62 [66.49–66.63] |
| resize | frame interval max (ms) | 64.55 [64.49–80.60] | 64.61 [64.50–80.74] | 80.49 [80.42–80.63] |
| resize | CPU per frame (ms) | 1.47 [1.37–1.59] | 1.46 [1.38–1.49] | 2.37 [2.34–2.41] |
| resize | CPU (% of a core) | 8.0 [7.4–8.5] | 7.9 [7.5–8.0] | 12.5 [12.5–12.6] |
| all | stripped binary size (MiB) | 10.8 (libsiv.so 10.8 + program 22 KiB) | 10.8 (libsiv.so 10.8 + program 22 KiB) | 21.3 |
