Round 4: bounded layout memory for long documents (D13). siv before is `116a844`, built with `-DBENCH_SCROLL_JUMP` (it could not show a caret's offset: its jumps to the end and the start scroll with `siv_scroll_to`, and its search jump only moves the caret); siv after is this round. Only the text and logs scenarios ran; the others are unchanged by it.

Median over 5 runs per cell, [min–max over runs].
| scenario | metric | siv before | siv after | gpui |
| --- | --- | --- | --- | --- |
| text | startup to first frame (ms) | 37.2 [35.5–38.3] | 37.0 [36.0–44.8] | 79.5 [76.9–93.7] |
| text | RSS (MiB) | 151.5 [149.5–152.3] | 89.4 [81.9–90.7] | 82.4 [82.3–82.7] |
| text | key to photon, median (ms) | 3.18 [3.03–3.42] | 3.26 [2.96–3.62] | 3.46 [3.31–3.97] |
| text | key to photon, max (ms) | 5.46 [4.95–6.14] | 5.85 [5.22–6.59] | 19.74 [18.26–20.89] |
| text | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| text | scroll: frame interval p99 (ms) | 17.22 [17.20–17.36] | 17.31 [17.26–17.42] | 17.23 [17.13–17.56] |
| text | scroll: CPU per frame (ms) | 1.35 [1.29–1.41] | 1.39 [1.29–1.47] | 2.67 [2.66–2.82] |
| text | scroll: GPU per frame (ms) | 1.03 [0.94–1.07] | 0.96 [0.94–0.99] | 0.58 [0.55–0.64] |
| text | wheel to photon, median (ms) | 1.98 [1.93–2.33] | 2.01 [1.92–2.12] | 4.09 [3.77–4.17] |
| text | jump to end, median (ms) | 3.48 [2.75–3.70] | 4.50 [4.19–4.94] | 7.58 [7.08–8.21] |
| text | jump to end, max (ms) | 3.91 [3.41–4.19] | 9.26 [8.96–10.03] | 21.68 [18.84–22.94] |
| text | jump to start, median (ms) | 3.00 [2.92–3.61] | 3.58 [3.28–3.86] | 6.76 [6.43–6.81] |
| text | search result jump, median (ms) | 2.74 [2.43–3.16] | 5.75 [5.39–6.29] | 8.14 [8.06–8.99] |
| text | search result jump, max (ms) | 3.94 [2.54–4.31] | 12.92 [12.21–13.22] | 9.25 [8.76–9.42] |
| logs | startup to first frame (ms) | 215.6 [214.8–216.8] | 215.6 [214.7–218.1] | 469.3 [466.6–491.3] |
| logs | RSS after start (MiB) | 1027.9 [1015.9–1048.3] | 283.5 [283.3–283.7] | 433.6 [418.7–433.9] |
| logs | RSS at the end (MiB) | 6606.6 [6481.1–6800.7] | 291.9 [291.6–293.7] | 433.8 [418.7–434.0] |
| logs | peak RSS (MiB) | 7438.6 [7423.7–9065.2] | 404.0 [403.7–404.9] | 433.8 [418.7–434.0] |
| logs | key to photon, median (ms) | 30.44 [28.19–527.38] | 27.06 [26.09–27.25] | 3.57 [3.43–3.84] |
| logs | key to photon, max (ms) | 571.36 [398.88–844.87] | 28.26 [27.47–28.84] | 19.09 [18.67–20.14] |
| logs | scroll: dropped frames | 0 [0–0] | 0 [0–0] | 0 [0–0] |
| logs | scroll: CPU per frame (ms) | 1.16 [1.13–1.30] | 1.14 [1.03–1.25] | 2.63 [2.46–2.75] |
| logs | scroll: GPU per frame (ms) | 0.82 [0.79–0.90] | 0.79 [0.76–0.85] | 0.54 [0.51–0.56] |
| logs | wheel to photon, median (ms) | 1.73 [1.60–2.04] | 1.80 [1.70–1.94] | 3.83 [3.67–4.30] |
| logs | jump to end, median (ms) | 3.61 [3.21–3.93] | 3.84 [3.75–4.15] | 7.13 [6.84–7.30] |
| logs | jump to end, max (ms) | 4.21 [3.56–4.51] | 9.10 [8.25–10.05] | 22.09 [20.99–22.87] |
| logs | jump to start, median (ms) | 3.16 [2.73–3.77] | 3.06 [2.69–3.35] | 5.94 [5.53–6.28] |
| logs | search result jump, median (ms) | 20.62 [17.58–20.81] | 21.00 [19.15–21.35] | 37.55 [37.07–37.74] |
| logs | search result jump, max (ms) | 20.95 [20.33–21.44] | 24.54 [23.42–27.42] | 38.81 [37.41–40.37] |
