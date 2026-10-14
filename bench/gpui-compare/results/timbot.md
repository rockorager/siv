Measured 2026-10-14 18:03 -0500 on AMD Ryzen 5 PRO 7640HS w/ Radeon 760M Graphics (12 threads), AMD Radeon 760M Graphics (RADV PHOENIX), Mesa 26.2.2-arch1.1, Linux 7.2.2-arch1-1, sway version 1.12, GTK 4.22.4, Qt 6.11.2, governor powersave balance_performance; siv at d9906d7, zed (gpui) at 26363aa.

Median over 5 runs per cell, [min–max over runs]. Run 0 of gpui's and Qt's list scenario was measured again at 19:10 with the same programs (an interrupted later session wrote over it).

| scenario | metric | siv | gpui | qt | gtk |
| --- | --- | --- | --- | --- | --- |
| idle | startup to first frame (ms) | 25.8 [25.2–26.4] | 75.2 [67.7–78.9] | 69.4 [66.3–71.7] | 60.0 [57.3–61.1] |
| idle | idle CPU (%) | 0.00 [0.00–0.00] | 0.00 [0.00–0.00] | 0.00 [0.00–0.00] | 0.00 [0.00–0.00] |
| idle | idle wakeups (/s) | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 0.1 [0.1–0.1] |
| idle | RSS after start (MiB) | 48.5 [48.5–48.6] | 77.1 [76.7–77.3] | 85.1 [84.9–85.2] | 65.1 [64.9–65.2] |
| idle | PSS after start (MiB) | 29.9 [29.9–30.0] | 53.9 [53.5–54.1] | 61.9 [61.7–62.0] | 40.9 [40.7–41.0] |
| idle | GPU memory, VRAM (MiB) | 35.3 [35.3–35.3] | 81.5 [81.4–81.5] | 88.4 [88.4–88.4] | 22.7 [22.7–22.7] |
| idle | GPU memory, GTT (MiB) | 3.2 [3.2–3.2] | 17.2 [16.0–17.2] | 34.6 [34.6–34.6] | 3.3 [3.3–3.3] |
| idle | threads | 21 [21–21] | 27 [27–27] | 9 [9–9] | 11 [11–11] |
| idle | threads after 10 s idle | 8 [8–8] | 27 [27–27] | 9 [9–9] | 11 [11–11] |
| gallery | startup to first frame (ms) | 34.2 [32.8–34.7] | 71.7 [68.6–85.7] | 76.8 [74.7–77.6] | 69.7 [68.0–70.4] |
| gallery | idle wakeups (/s) | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] |
| gallery | RSS (MiB) | 54.2 [54.1–54.2] | 77.3 [77.0–77.9] | 93.9 [93.6–94.0] | 68.5 [68.2–68.5] |
| gallery | GPU memory, VRAM + GTT (MiB) | 39.6 [39.6–39.6] | 96.1 [96.1–98.7] | 222.1 [222.1–222.1] | 27.6 [27.6–27.6] |
| gallery | key to photon, median (ms) | 2.05 [1.87–2.20] | 2.43 [2.32–2.46] | 2.02 [1.90–2.11] | 1.94 [1.77–2.06] |
| gallery | key to photon, max (ms) | 2.76 [2.29–2.95] | 18.37 [17.83–18.58] | 3.92 [3.60–4.04] | 2.25 [2.13–2.40] |
| gallery | click to photon, median (ms) | 1.75 [1.50–1.81] | 2.25 [2.21–2.32] | 1.76 [1.58–1.94] | 1.81 [1.64–1.86] |
| gallery | click to menu shown, median (ms) | 3.59 [3.40–4.12] | 2.38 [2.24–2.66] | 18.19 [18.11–18.34] | 19.58 [19.16–19.74] |
| list | startup to first frame (ms) | 30.3 [27.7–31.8] | 74.4 [70.8–94.6] | 70.5 [69.4–71.7] | 76.7 [74.6–79.2] |
| list | RSS (MiB) | 51.1 [51.0–51.2] | 78.2 [78.0–78.5] | 90.5 [90.1–90.6] | 70.0 [69.5–70.0] |
| list | scroll: frames presented in 5 s | 302 [302–304] | 303 [303–304] | 305 [305–305] | 303 [302–303] |
| list | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| list | scroll: frame interval p50 (ms) | 16.42 [16.37–16.53] | 16.40 [16.37–16.48] | 16.32 [16.29–16.35] | 16.44 [16.41–16.54] |
| list | scroll: frame interval p99 (ms) | 17.27 [17.05–17.48] | 17.21 [17.09–17.24] | 16.90 [16.82–16.93] | 17.24 [17.21–17.27] |
| list | scroll: frame interval max (ms) | 17.45 [17.32–17.66] | 17.35 [17.28–17.53] | 17.13 [16.99–17.43] | 17.45 [17.34–17.68] |
| list | scroll: CPU per frame (ms) | 1.44 [1.32–1.48] | 1.93 [1.84–2.05] | 1.99 [1.94–2.12] | 1.74 [1.66–1.83] |
| list | scroll: GPU per frame (ms) | 0.89 [0.88–0.89] | 0.93 [0.92–0.97] | 0.24 [0.24–0.25] | 0.19 [0.18–0.20] |
| list | scroll: CPU (% of a core) | 8.7 [8.0–8.9] | 11.7 [11.2–12.4] | 12.1 [11.8–12.9] | 10.5 [10.0–11.0] |
| list | wheel to photon, median (ms) | 1.66 [1.62–1.70] | 3.21 [3.12–3.28] | 23.67 [21.54–24.52] | 2.78 [2.73–2.80] |
| text | startup to first frame (ms) | 34.8 [34.3–37.6] | 83.8 [78.1–93.4] | 650.7 [648.2–651.7] | 86.6 [80.6–89.0] |
| text | RSS (MiB) | 76.4 [73.2–78.7] | 83.1 [82.9–83.3] | 179.9 [178.7–181.7] | 71.8 [71.7–72.0] |
| text | GPU memory, VRAM + GTT (MiB) | 41.3 [41.3–41.3] | 96.2 [96.2–96.2] | 123.1 [123.1–123.1] | 26.1 [26.1–26.1] |
| text | key to photon, median (ms) | 2.75 [2.54–2.94] | 3.57 [3.21–3.71] | 7.37 [7.01–7.80] | 2.78 [2.48–2.92] |
| text | key to photon, max (ms) | 3.78 [3.40–4.46] | 19.12 [18.20–19.39] | 8.69 [8.06–9.49] | 18.17 [17.55–18.87] |
| text | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| text | scroll: frame interval p99 (ms) | 17.27 [17.06–17.39] | 17.18 [17.16–17.30] | 17.15 [16.91–17.27] | 17.33 [17.27–18.24] |
| text | scroll: CPU per frame (ms) | 1.31 [1.25–1.39] | 2.66 [2.63–2.76] | 2.85 [2.70–2.95] | 1.99 [1.96–2.15] |
| text | scroll: GPU per frame (ms) | 0.92 [0.91–0.97] | 0.58 [0.57–0.59] | 0.36 [0.35–0.37] | 0.36 [0.29–0.38] |
| text | wheel to photon, median (ms) | 1.96 [1.80–2.05] | 3.93 [3.68–4.13] | 22.39 [20.21–24.42] | 3.02 [3.01–3.48] |
| text | jump to end, median (ms) | 4.33 [4.12–4.39] | see below | 6.45 [6.19–6.60] | 7.48 [7.36–7.69] |
| text | jump to end, max (ms) | 9.53 [8.22–10.62] | see below | 22.79 [18.42–30.74] | 8.76 [7.87–9.01] |
| text | jump to start, median (ms) | 3.36 [3.17–3.79] | see below | 7.24 [6.75–7.62] | 7.38 [7.16–7.66] |
| text | search result jump, median (ms) | 5.35 [5.28–5.95] | see below | 10.24 [9.24–10.73] | 10.04 [8.90–10.16] |
| text | search result jump, max (ms) | 12.93 [11.96–13.28] | see below | 12.08 [10.90–12.38] | 10.37 [10.09–10.59] |
| grid | startup to first frame (ms) | 35.1 [33.6–35.7] | 91.0 [86.0–104.1] | 137.1 [132.5–141.4] | 90.8 [87.1–92.4] |
| grid | frames presented in 5 s | 301 [300–302] | 304 [303–304] | 305 [304–307] | 304 [302–305] |
| grid | dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| grid | frame interval p50 (ms) | 16.56 [16.53–16.69] | 16.41 [16.40–16.44] | 16.39 [16.22–16.41] | 16.39 [16.37–16.51] |
| grid | frame interval p99 (ms) | 17.19 [17.15–17.29] | 17.05 [16.83–17.26] | 16.77 [16.50–17.12] | 17.16 [16.98–17.23] |
| grid | frame interval max (ms) | 17.24 [17.22–17.70] | 17.24 [17.09–17.64] | 17.20 [16.59–17.59] | 17.32 [17.23–17.52] |
| grid | CPU per frame (ms) | 2.06 [1.97–2.10] | 6.10 [6.05–6.23] | 7.05 [6.95–7.37] | 6.35 [6.29–6.40] |
| grid | GPU per frame (ms) | 0.91 [0.87–0.95] | 0.47 [0.45–0.49] | 0.52 [0.51–0.55] | 0.34 [0.33–0.36] |
| grid | CPU (% of a core) | 12.4 [11.9–12.7] | 37.1 [36.6–37.9] | 43.2 [42.5–44.8] | 38.5 [38.1–39.0] |
| grid | RSS (MiB) | 64.6 [64.5–66.0] | 87.8 [86.7–88.0] | 125.2 [125.1–126.8] | 70.3 [70.1–70.4] |
| typing | key to photon, median (ms) | 24.03 [23.78–24.11] | 24.17 [24.03–24.30] | 23.93 [23.47–24.20] | 24.19 [23.84–24.38] |
| typing | key to photon, p99 (ms) | 32.33 [32.06–32.61] | 32.42 [32.25–32.50] | 32.34 [31.86–32.61] | 32.39 [32.31–32.62] |
| typing | key to photon, max (ms) | 32.93 [32.66–33.28] | 32.76 [32.60–33.13] | 32.91 [32.26–32.98] | 32.73 [32.57–33.03] |
| typing | frames presented | 146 [145–146] | 144 [144–145] | 146 [146–147] | 144 [144–145] |
| typing | CPU per frame (ms) | 1.82 [1.70–2.01] | 3.03 [2.69–3.14] | 2.71 [2.70–2.90] | 3.22 [2.90–3.35] |
| typing | CPU (% of a core) | 11.1 [10.3–12.2] | 18.2 [16.3–18.9] | 16.6 [16.5–17.7] | 19.4 [17.4–20.1] |
| resize | configures acknowledged | 360 [360–360] | 360 [360–360] | 360 [360–360] | 306 [300–312] |
| resize | frames presented | 172 [168–174] | 169 [166–172] | 175 [172–175] | 96 [92–97] |
| resize | resize to photon, median (ms) | 10.56 [10.36–11.32] | 10.87 [10.67–11.12] | 10.51 [10.25–10.56] | 22.82 [21.78–23.05] |
| resize | resize to photon, p99 (ms) | 50.25 [49.40–66.27] | 66.29 [50.67–83.13] | 49.90 [49.85–66.23] | 66.42 [49.49–66.73] |
| resize | resize to photon, max (ms) | 50.42 [50.08–66.33] | 66.72 [66.45–83.14] | 50.23 [50.12–66.27] | 66.60 [49.85–66.94] |
| resize | frame interval max (ms) | 64.72 [64.47–80.47] | 80.52 [80.40–96.55] | 64.58 [64.49–80.74] | 80.63 [64.57–80.74] |
| resize | CPU per frame (ms) | 1.45 [1.41–1.54] | 2.40 [2.29–2.47] | 1.97 [1.91–2.04] | 1.92 [1.85–1.98] |
| resize | CPU (% of a core) | 7.8 [7.7–8.2] | 12.5 [12.4–13.1] | 10.6 [10.5–11.2] | 5.7 [5.5–5.9] |
| logs | startup to first frame (ms) | 215.2 [214.4–217.3] | 452.2 [446.9–459.2] | – | – |
| logs | RSS after start (MiB) | 277.0 [276.6–277.9] | 434.6 [434.2–436.2] | – | – |
| logs | RSS at the end (MiB) | 280.4 [280.0–281.5] | 434.8 [434.2–436.3] | – | – |
| logs | peak RSS (MiB) | 398.2 [397.8–398.7] | 434.8 [434.2–436.3] | – | – |
| logs | key to photon, median (ms) | 5.55 [5.19–5.68] | 3.45 [3.28–3.82] | – | – |
| logs | key to photon, max (ms) | 7.51 [6.59–8.21] | 19.01 [18.36–19.58] | – | – |
| logs | scroll: dropped frames | 0 [0–0] | 0 [0–0] | – | – |
| logs | scroll: CPU per frame (ms) | 1.17 [1.13–1.26] | 2.55 [2.41–2.67] | – | – |
| logs | scroll: GPU per frame (ms) | 0.78 [0.76–0.81] | 0.55 [0.50–0.60] | – | – |
| logs | wheel to photon, median (ms) | 1.79 [1.69–1.85] | 3.84 [3.62–3.98] | – | – |
| logs | jump to end, median (ms) | 4.57 [3.86–4.99] | see below | – | – |
| logs | jump to end, max (ms) | 9.59 [9.38–10.52] | see below | – | – |
| logs | jump to start, median (ms) | 3.31 [3.09–3.58] | see below | – | – |
| logs | search result jump, median (ms) | 19.53 [19.27–19.71] | see below | – | – |
| logs | search result jump, max (ms) | 25.79 [24.47–26.01] | see below | – | – |
| all | stripped binary size (MiB) | 11.2 (libsiv.so 11.2 + program 23 KiB) | 21.3 | – | – |

## gpui jumps, measured again

gpui's Ctrl+End, Ctrl+Home, and F3 scrolled a few paragraphs and stopped in the runs above (ListState::scroll_to_reveal_item goes by the heights measured so far). After 710b51d they reach their target; the same build otherwise.

Measured 2026-10-14 19:10 -0500 on AMD Ryzen 5 PRO 7640HS w/ Radeon 760M Graphics (12 threads), AMD Radeon 760M Graphics (RADV PHOENIX), Mesa 26.2.2-arch1.1, Linux 7.2.2-arch1-1, sway version 1.12, GTK 4.22.4, Qt 6.11.2, governor powersave balance_performance; siv at 710b51d, zed (gpui) at 26363aa.
Median over 3 runs per cell, [min–max over runs].

| scenario | metric | gpui |
| --- | --- | --- |
| text | jump to end, median (ms) | 6.48 [6.37–6.54] |
| text | jump to end, max (ms) | 24.10 [23.85–24.54] |
| text | jump to start, median (ms) | 6.35 [5.81–6.36] |
| text | search result jump, median (ms) | 7.64 [7.58–8.23] |
| text | search result jump, max (ms) | 9.59 [8.66–9.73] |
| logs | jump to end, median (ms) | 6.22 [6.08–6.43] |
| logs | jump to end, max (ms) | 24.16 [23.63–24.18] |
| logs | jump to start, median (ms) | 6.13 [5.86–6.17] |
| logs | search result jump, median (ms) | 36.41 [36.03–36.57] |
| logs | search result jump, max (ms) | 37.54 [37.08–37.73] |
