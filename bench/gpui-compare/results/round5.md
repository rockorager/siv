Round 5: a text node's bytes in a rope, edits shaping only what changed (D15). siv before is round 4 (`2e4e5bb`), siv after is this round (`7be42d8` plus the bench's chunked search). Measured 09:03–09:16 CDT with no other zig, test, or sway process running (checked every 15 s); an earlier attempt overlapped another thread's test runs and was discarded. Only the text and logs scenarios ran.

Median over 5 runs per cell, [min–max over runs].
| scenario | metric | siv before | siv after | gpui |
| --- | --- | --- | --- | --- |
| text | startup to first frame (ms) | 35.2 [33.9–56.8] | 35.0 [34.2–36.8] | 84.7 [78.9–119.6] |
| text | RSS (MiB) | 88.6 [86.6–89.8] | 88.3 [81.7–90.2] | 82.7 [82.3–82.9] |
| text | key to photon, median (ms) | 3.36 [2.92–3.43] | 2.79 [2.61–3.06] | 3.53 [3.21–3.73] |
| text | key to photon, max (ms) | 4.98 [4.89–5.70] | 4.22 [3.36–5.55] | 19.32 [18.97–20.44] |
| text | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| text | scroll: frame interval p99 (ms) | 17.24 [17.18–17.37] | 17.27 [17.19–17.40] | 17.25 [17.13–17.29] |
| text | scroll: CPU per frame (ms) | 1.34 [1.27–1.38] | 1.39 [1.18–1.52] | 2.72 [2.56–2.76] |
| text | scroll: GPU per frame (ms) | 0.98 [0.93–1.02] | 0.97 [0.95–1.01] | 0.60 [0.55–0.63] |
| text | wheel to photon, median (ms) | 1.90 [1.82–1.93] | 2.00 [1.74–2.06] | 3.86 [3.48–4.20] |
| text | jump to end, median (ms) | 4.36 [4.11–4.84] | 4.65 [3.89–4.73] | 7.72 [7.32–7.85] |
| text | jump to end, max (ms) | 10.01 [9.09–10.79] | 9.66 [9.11–10.45] | 22.41 [21.58–22.81] |
| text | jump to start, median (ms) | 3.62 [3.06–3.79] | 3.66 [3.09–4.14] | 6.67 [6.53–6.99] |
| text | search result jump, median (ms) | 5.59 [5.08–5.94] | 5.45 [5.34–6.00] | 8.49 [8.22–8.85] |
| text | search result jump, max (ms) | 12.48 [11.98–12.98] | 13.66 [12.69–14.25] | 8.67 [8.42–9.60] |
| logs | startup to first frame (ms) | 215.6 [215.3–216.1] | 216.0 [214.8–216.6] | 474.5 [464.3–486.9] |
| logs | RSS after start (MiB) | 283.8 [283.3–291.1] | 285.1 [284.7–285.6] | 434.0 [433.7–435.9] |
| logs | RSS at the end (MiB) | 291.8 [291.6–292.3] | 288.8 [288.0–290.3] | 434.1 [433.7–436.1] |
| logs | peak RSS (MiB) | 403.6 [403.3–404.4] | 405.5 [404.8–405.8] | 434.1 [433.7–436.1] |
| logs | key to photon, median (ms) | 26.94 [24.77–28.15] | 5.28 [5.11–5.41] | 3.50 [3.29–3.68] |
| logs | key to photon, max (ms) | 27.92 [27.40–29.40] | 7.25 [6.19–8.95] | 18.66 [18.31–19.33] |
| logs | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| logs | scroll: CPU per frame (ms) | 1.12 [1.11–1.20] | 1.17 [1.07–1.20] | 2.58 [2.52–2.65] |
| logs | scroll: GPU per frame (ms) | 0.76 [0.75–0.83] | 0.77 [0.71–0.78] | 0.52 [0.52–0.56] |
| logs | wheel to photon, median (ms) | 1.77 [1.63–1.81] | 1.75 [1.68–1.95] | 3.87 [3.74–4.00] |
| logs | jump to end, median (ms) | 4.15 [3.91–4.78] | 3.95 [3.65–4.01] | 6.86 [6.75–7.40] |
| logs | jump to end, max (ms) | 8.87 [8.60–9.46] | 9.43 [7.99–10.55] | 22.12 [21.45–22.54] |
| logs | jump to start, median (ms) | 2.91 [2.53–3.61] | 2.85 [2.67–3.53] | 5.77 [5.52–6.06] |
| logs | search result jump, median (ms) | 21.03 [19.57–21.56] | 18.98 [18.29–19.18] | 37.36 [37.02–38.55] |
| logs | search result jump, max (ms) | 26.92 [23.95–28.87] | 24.71 [24.51–25.44] | 38.37 [37.38–40.31] |
