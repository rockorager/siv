# siv vs gpui, Qt, and GTK

Matching applications in siv, gpui (Zed's GUI framework), Qt Quick, and
GTK 4, measured the same way on sway, every one rendering with Vulkan on
the same GPU. Nothing here is part of siv's build or tests. The directory
is named for its first comparison, siv against gpui; Qt and GTK came
later.

```text
bench/gpui-compare/
  siv/bench.c        the siv program (C, against libsiv.so)
  gpui/src/main.rs   the gpui program; gpui/setup.sh fetches zed at a pinned commit
  qt/bench.cpp       the Qt Quick program; qt/bench.qml has its scenes
  gtk/bench.c        the GTK 4 program
  common/doc.h       shared constants and document text (gpui/src/spec.rs mirrors it)
  harness/presshim.c LD_PRELOAD library: presentation feedback for every commit
  harness/inject.c   virtual keyboard and pointer client
  harness/run.py     runs the scenarios, writes results/raw/*.json and machine.json
  harness/report.py  summarizes them as the tables in results/
```

## Running

On a machine with a GPU and its Mesa Vulkan driver, after a commit (run.py
records the commit and whether the tree had changes):

```sh
rustup toolchain install 1.98.1 --profile minimal   # zed's pinned toolchain
ZIG=~/.local/opt/zig-0.17.0/zig ./build.sh          # libsiv (ReleaseFast), the four programs, the tools
python3 harness/run.py --runs 5 --warmup            # about 40 minutes
python3 harness/report.py > results/latest.md
```

and for working on siv:

```sh
python3 harness/run.py --runs 1 --scenarios text --toolkits siv --perf /tmp/prof   # perf record
GC_SIV_BENCH=out/siv-bench-before python3 harness/run.py --toolkits siv --out results/raw-before   # another build of the siv program
python3 harness/report.py results/raw-before results/raw   # siv before, siv after, gpui
GC_KMS=/dev/dri/card0 python3 harness/run.py --scenarios gallery   # sway on a KMS device (vkms): real vblank
```

`--toolkits` and `--scenarios` pick subsets (default all four and every
scenario); `--screenshots DIR` saves what the first run showed. `--warmup`
runs each program once per scenario first and discards it, so that
Fontconfig's cache, the shader caches (Mesa's, Qt's pipeline cache), Qt's
QML cache, and the page cache are warm for every recorded run. `run.py`
passes `SIV_*` environment variables to the siv program, for experiments;
`GC_RENDER_NODE` names another render node than `/dev/dri/renderD128`.

Needs sway, wayland-scanner, wayland-protocols, libwayland-client,
xkbcommon, Fontconfig, the Adwaita Sans font, a Mesa Vulkan driver for the
GPU, `vulkaninfo` (vulkan-tools), Qt 6 with Qt Quick Controls (qtbase and
qtdeclarative 6.8 or later, for menus in their own popup surfaces), and
GTK 4 with their pkg-config files; `grim` for `--screenshots`. `build.sh`
skips gpui without cargo and Qt or GTK without their pkg-config files.

gpui is built from zed commit `26363aabdb31a0c016728634202e1ad5067033aa`
(2026-10-12) with zed's own release profile (thin LTO, one codegen unit)
and the `[patch]` entries of zed's workspace that gpui's dependencies
reach. Its Linux renderer is wgpu on Vulkan. libsiv is built ReleaseFast.
The Qt and GTK programs are built `-O2` against the system's Qt and GTK,
so all four programs share the C library and load the same Mesa Vulkan
driver.

## Method

Each run starts a fresh sway 1.12 on its headless backend with the Vulkan
renderer on the GPU's render node (`WLR_BACKENDS=headless
WLR_RENDERER=vulkan`), one output of 1280×800 at 60 Hz and scale 1, no
borders, so the one window is 1280×800. Then the scenario's program
starts, input comes from `inject`, and the program is stopped. Each
scenario runs five times per toolkit, interleaved, after an unrecorded
warm-up run; tables give the median over runs and the range.

Every toolkit renders with Vulkan on the GPU, named rather than left to
the toolkit's default:

- **siv** with its Vulkan renderer. It draws its first frames with its
  CPU renderer while its Vulkan device is created on a thread (D10), and
  switches after; startup measures that.
- **gpui** with wgpu on Vulkan, its only Linux renderer.
- **Qt Quick** with its scene graph on QRhi's Vulkan backend
  (`QSG_RHI_BACKEND=vulkan`). Qt Widgets is not compared: it paints with
  its raster engine on the CPU even when a GPU is present.
- **GTK 4** with its Vulkan renderer (`GSK_RENDERER=vulkan`, its default
  on Wayland since 4.16).

Each result's `app_log` keeps the line in which each toolkit names its
renderer and device (siv's own log, Qt's `qt.rhi.general` logging, GTK's
`GSK_DEBUG=renderer`). run.py exits unless `vulkaninfo` lists a GPU, and
stops if a program submitted no work to the GPU's render node during a
run (amdgpu's `drm-engine-*` counters below), so no CPU-rendered or
emulated (lavapipe) result can be recorded.

- **Frames** come from `presshim.so`, preloaded into every program. It
  wraps libwayland's request marshalling (including the entry points
  Rust's wayland-backend looks up with dlsym, and Mesa's WSI commits) and
  asks for `wp_presentation` feedback on every `wl_surface.commit`, so
  every toolkit is measured by the same code. Its dispatch thread sleeps
  while no feedback is outstanding, so it adds no idle wakeups.
- **Startup** is from `fork` to the presentation of the toplevel's first
  frame.
- **Input to photon** is from the moment `inject` flushed the event to sway
  to the presentation of the first commit the program made after it. The
  programs commit nothing while idle (every caret is steady, see below),
  so that commit is the response. sway's headless output composites a
  damaged frame as soon as a client commits, not at a vblank, so these
  numbers are the toolkit's own latency plus sway's composite (about
  0.5 ms), not a monitor's scan-out.
- **CPU time** is the sum over the program's threads of
  `/proc/PID/task/*/schedstat`, over the measured window, divided by
  presented frames for per-frame figures. Each thread counts its own
  change, from zero for a thread started during the window; a thread
  that exits takes its counts with it (siv's pool retires idle workers),
  so over idle windows threads are sampled every 50 ms and one that
  exits counts up to its last sample. **GPU time** is the program's
  `drm-engine-*` time from `/proc/PID/fdinfo` (amdgpu), which counts the
  GPU work the program submitted, not sway's composite.
- **Wakeups** are voluntary and involuntary context switches of all
  threads per second over an idle window.
- **Memory** is VmRSS and PSS (`smaps_rollup`) after startup, and the
  program's GPU buffers from fdinfo: `drm-memory-vram` (the GPU's carve-out
  on this APU) and `drm-memory-gtt` (system memory mapped for the GPU).
  RSS does not count GPU buffers; the GTT pages are system memory too.
- **Dropped frames** are refresh intervals during continuous motion with
  no new presentation: for each gap between presentations, its length in
  refresh periods minus one.
- **Binary size** is the stripped program, plus libsiv.so for siv. gpui
  links statically; the Qt and GTK programs link their toolkits' shared
  libraries and are not compared.
## Scenarios

| Scenario | What it does |
| --- | --- |
| idle | A window with one label. 10 s idle window. |
| gallery | A title, four buttons (default, primary, disabled, and a menu button with six items), a focused 320 px text field, a checkbox, a 320×320 list of 50 selectable items, and a status label. 15 key presses into the field, 15 clicks on a button, 8 menu openings. |
| list | A 100,000-row list filling the window, two text columns per row. 5 s of touchpad scrolling at 120 events/s of 30 px each (after each toolkit's own scaling), then 15 wheel notches. |
| text | An editor over a 4,000-paragraph document (about 1.2 MB, 200,000 words) at 14.67 px, wrapped to the window, focused at the start. 15 key presses, 3 s of scrolling, 10 wheel notches, then five jumps to the end and back (Ctrl+End, Ctrl+Home) and five search-result jumps (F3, then Ctrl+Home). |
| grid | 2,560 rounded 16 px squares (64×40), each fading between opacity 1 and 0.2 every second (CSS ease-in-out, alternating) with its own delay. 5 s of animation. |
| typing | The editor with a 6-paragraph document: 300 characters typed at one per 8 ms. |
| resize | The gallery as a floating window, resized 180 times at 60 Hz between 1280×800 and 800×500. |
| logs | The text scenario's editor and steps over 100 MB of log lines (1.05 M lines of about 100 bytes, `log_generate`), after waiting for the program to go quiet. siv and gpui only. |

Ctrl+End and Ctrl+Home move the caret to the end or the start and show
it. F3 searches the text for a word that occurs once, three quarters of
the way through (`DOC_NEEDLE`), puts the caret there, and shows it: siv
reads the editor's text in pieces of 1 MiB (`siv_node_get_text_range`)
and calls `siv_set_selection`, whose editor scrolls to its caret (D15);
gpui searches its paragraphs and scrolls the paragraph to the top with
`ListState::scroll_to` (Ctrl+End: `scroll_to_end`);
Qt searches `TextArea.text` with JavaScript's `indexOf` and selects the
match (TextArea has no search of its own); GTK uses
`gtk_text_iter_forward_search` and `gtk_text_view_scroll_mark_onscreen`.

Touchpad distances are scaled per toolkit so that each scrolls the same
3,600 px/s (`SCROLL_EVENT` in run.py): siv multiplies touchpad deltas by 4
(D16), gpui by 3 (`gpui_linux`'s Wayland client), GTK by 2.5, and Qt
Quick's Flickable takes them as they come. 600 events end every list
within four rows of row 644. In the editors the distance is set for the
same paragraphs per second (`TEXT_SCROLL_EVENT`), since line heights
differ (20 px in siv and gpui, 19 in Qt, about 18 in GTK); 360 events end
every editor within two paragraphs of paragraph 223.

Text is Adwaita Sans at siv's body size (11 pt, 14.67 px) in every
toolkit. siv's and gpui's programs use siv's light theme colors and widget
metrics (control height 32, radius 6, padding 12); Qt and GTK look like
themselves at the same sizes.

## Differences that remain

- **Stock widgets.** gpui has no stock widgets. The gallery's buttons,
  text field (trimmed from gpui's `examples/input.rs`), checkbox, list
  (`uniform_list`), and menu are written in the gpui program with gpui's
  elements, as a gpui application would. siv's, Qt's, and GTK's are their
  stock widgets, which do more: accessibility, focus rings, keyboard
  navigation.
- **Menus.** siv, Qt (`popupType: Popup.Window`), and GTK (a
  GtkPopoverMenu) show menus in `xdg_popup` surfaces that can extend past
  the window, and the menu latency is the popup's first presented frame;
  gpui draws them inside the window (`deferred` and `anchored`). That
  compares the ways of showing a menu users of each see.
- **The editors.** gpui has no stock editor outside Zed. The gpui
  program's editor is a `list` over paragraphs, each a wrapped
  `StyledText`, with a caret, typing through gpui's input handler,
  Backspace, Enter, and arrow keys: it shapes and lays out only the
  paragraphs in view. siv's is its stock editor (D15): selection, undo,
  input methods, accessibility. Qt's is TextArea in a Flickable that
  follows the caret (TextEdit's documented idiom), which lays out the
  whole document before its first frame; GTK's is GtkTextView, which lays
  out lazily.
- **Text rendering.** siv blends in linear light with its contrast
  correction (D11); gpui's text is lighter. gpui does not apply variable
  font weights, so the gallery's bold title is regular in gpui. Qt Quick
  draws text from distance fields (its default, `Text.QtRendering`).
- **Animation.** siv animates the grid on its compositor thread
  (`siv_set_animation`, one layer per cell, D8); Qt with an
  OpacityAnimator per cell, on its render thread; GTK with a CSS
  animation per cell (`animation: fade 1s cubic-bezier(0.42, 0, 0.58, 1)
  infinite alternate`), restyled and redrawn on the main thread each
  frame; gpui re-renders the window every frame
  (`request_animation_frame`), which is how gpui animates.
- **Same steady state.** No caret blinks: gpui's example editor has no
  blink, Qt's cursor flash time is 0, GTK's `gtk-cursor-blink` is off, and
  siv runs with reduced motion (`SIV_APP_REDUCED_MOTION`), which GTK
  matches with `gtk-enable-animations` off; in the grid scenario both are
  on. No program reaches a session bus, so none publishes accessibility
  or reads desktop settings (siv also runs with
  `SIV_APP_NO_DESKTOP_SETTINGS`; GTK warns that it cannot autolaunch
  D-Bus).
- **The programs** in detail: Qt's uses Qt Quick Controls' Fusion style
  with Button, Menu, TextField, CheckBox, a ListView of ItemDelegates in
  a Frame, a ListView over 100,000 rows of two Labels made on demand, and
  TextArea. GTK's uses GtkButton, a GtkMenuButton with a GMenu, GtkEntry,
  GtkCheckButton, GtkListView over list models (the 100,000 rows from a
  model that makes its items on demand), GtkTextView, and a GtkGrid of
  boxes for the grid, with GTK's built-in theme (no libadwaita).
- **Not ported:** the 100 MB log, to Qt and GTK.
## Results

These are directional numbers: one machine, one session of five runs per
cell after a warm-up, with no thermal or frequency pinning. They show
where each toolkit stands and by roughly how much, not differences of a
few percent. `results/timbot.md` has every metric with its range over the
runs (`report.py` writes it from the raw results). Measured
2026-10-14 on an AMD Ryzen 5 PRO 7640HS (6 cores, 12 threads, 32 GB of RAM) with
its integrated Radeon 760M, RADV from Mesa 26.2.2, Arch Linux with Linux
7.2.2, the `powersave` governor with `balance_performance`, sway 1.12,
Qt 6.11.2, and GTK 4.22.4; siv at `fcb487f` (the bench programs at
`d9906d7`), gpui at zed `26363aa`. gpui's jumps in the document and the
log were measured again, three runs, after `710b51d` made them reach
their target (its first runs scrolled a few paragraphs and stopped). The machine was otherwise idle (load average at most
0.63 at the end of any run). Every run's renderer line and GPU counters
show Vulkan on the Radeon.

| Scenario | Metric | siv | gpui | Qt Quick | GTK 4 |
| --- | --- | --- | --- | --- | --- |
| idle | startup to first frame | 25.8 ms | 75.2 ms | 69.4 ms | 60.0 ms |
| idle | RSS / PSS | 48.5 / 29.9 MiB | 77.1 / 53.9 MiB | 85.1 / 61.9 MiB | 65.1 / 40.9 MiB |
| idle | GPU memory, VRAM + GTT | 35.3 + 3.2 MiB | 81.5 + 17.2 MiB | 88.4 + 34.6 MiB | 22.7 + 3.3 MiB |
| idle | threads after 10 s idle; CPU and wakeups while idle | 8; 0, 0/s | 27; 0, 0/s | 9; 0, 0/s | 11; 0, 0.1/s |
| gallery | startup to first frame | 34.2 ms | 71.7 ms | 76.8 ms | 69.7 ms |
| gallery | key / click to photon (median) | 2.05 / 1.75 ms | 2.43 / 2.25 ms | 2.02 / 1.76 ms | 1.94 / 1.81 ms |
| gallery | key to photon, worst of 15 | 2.76 ms | 18.4 ms | 3.92 ms | 2.25 ms |
| gallery | click to menu shown | 3.59 ms | 2.38 ms* | 18.2 ms | 19.6 ms |
| list | scroll: CPU / GPU per frame | 1.44 / 0.89 ms | 1.95 / 0.94 ms | 2.04 / 0.24 ms | 1.74 / 0.19 ms |
| list | wheel to photon | 1.66 ms | 3.21 ms | 23.7 ms | 2.78 ms |
| text | startup to first frame | 34.8 ms | 83.8 ms | 651 ms | 86.6 ms |
| text | RSS / GPU memory at the end | 76.4 / 41.3 MiB | 83.1 / 96.2 MiB | 180 / 123 MiB | 71.8 / 26.1 MiB |
| text | key to photon (median / worst) | 2.75 / 3.78 ms | 3.57 / 19.1 ms | 7.37 / 8.69 ms | 2.78 / 18.2 ms |
| text | scroll: CPU / GPU per frame | 1.31 / 0.92 ms | 2.66 / 0.58 ms | 2.85 / 0.36 ms | 1.99 / 0.36 ms |
| text | wheel to photon | 1.96 ms | 3.93 ms | 22.4 ms | 3.02 ms |
| text | jump to end / search result (median) | 4.33 / 5.35 ms | 6.48 / 7.64 ms‡ | 6.45 / 10.2 ms | 7.48 / 10.0 ms |
| grid | CPU / GPU per frame | 2.06 / 0.91 ms | 6.10 / 0.47 ms | 7.05 / 0.52 ms | 6.35 / 0.34 ms |
| typing | key to photon (median), CPU per frame | 24.0 ms, 1.82 ms | 24.2 ms, 3.03 ms | 23.9 ms, 2.71 ms | 24.2 ms, 3.22 ms |
| resize | resize to photon (median); configures acknowledged | 10.6 ms; 360 | 10.9 ms; 360 | 10.5 ms; 360 | 22.8 ms; 306 |
| resize | CPU per frame | 1.45 ms | 2.40 ms | 1.97 ms | 1.92 ms |
| logs | startup; RSS at the end | 215 ms; 280 MiB | 452 ms; 435 MiB | – | – |
| logs | key to photon (median / worst) | 5.55 / 7.51 ms | 3.45 / 19.0 ms | – | – |
| logs | search result jump (median) | 19.5 ms | 36.4 ms‡ | – | – |
| all | stripped binary | 11.2 MiB (libsiv.so) | 21.3 MiB | – | – |

\* gpui draws its menu inside the window; the others show theirs in a
popup surface (Differences that remain).
‡ Three runs after `710b51d` (see above and `results/timbot.md`).

Every toolkit kept 60 Hz with no dropped frame in every run of the list,
the document, the grid, and the logs (p99 frame interval 16.5 to 18.2 ms),
and none woke while idle. In the typing burst, which types faster (125
keys/s) than any toolkit presents, all four show a key 24 ms after it,
about one and a half refreshes: that is frame pacing, the same for all.
Run-to-run spread is small: startup within 6 ms of the median except
gpui's (up to 18 ms above), per-frame CPU within 11%; the ranges are in
`results/timbot.md`.

### Where siv leads

- **Startup**: 26 ms to the first frame of a small window, against 60 to
  75 ms, and 35 ms for the 1.2 MB document, against 84 to 87 ms and Qt
  Quick's 651 ms (69 ms over the typing scenario's 6 paragraphs: Qt's
  TextArea takes in the whole text before its first frame; not profiled
  further). siv draws its first frame with its CPU renderer while the
  Vulkan device is made on a thread (D10), and shapes the blocks in view
  first (D13).
- **CPU per frame** in every scenario with motion: scrolling the list
  1.44 ms against 1.74 to 2.04, the document 1.31 against 1.99 to 2.85,
  typing 1.82 against 2.71 to 3.22, resizing 1.45 against 1.92 to 2.40.
  The grid costs 2.06 ms against 6.10 to 7.05: siv's compositor thread
  animates layer opacity (D8), where gpui rebuilds 2,560 elements every
  frame, GTK restyles and redraws 2,560 widgets, and Qt's render thread
  updates 2,560 animators and the scene graph.
- **Memory**: the lowest RSS and PSS at idle (48.5 / 29.9 MiB), 8
  threads after 10 s idle, and the second-lowest GPU memory (38.5 MiB,
  after GTK's 26.0); the 100 MB log holds 280 MiB against gpui's 435.
- **Wheel to photon**: 1.7 to 2.0 ms, against 2.8 to 3.9 for gpui and
  GTK. Qt Quick shows a wheel notch about a refresh later (22 to 24 ms)
  although it answers keys and clicks in 2 ms; this bench does not
  break that down.
- **Worst keystroke** in the document: 3.8 ms, where gpui's and GTK's
  wait a refresh (19.1 and 18.2 ms) and Qt's takes 8.7 (gpui's in the
  gallery too, 18.4).
- **Jumps** to the end of the document and to a search result: 4.3 and
  5.4 ms, against 6.5 to 10.2.

### Where siv trails, and why

- **GPU time per frame**: 0.89 ms scrolling the list against Qt's 0.24,
  GTK's 0.19, and gpui's 0.94; 0.92 for the document against 0.36 to
  0.58; 0.91 for the grid against 0.34 to 0.52. siv renders into an FP16
  working image in linear light and encodes it with its CPU renderer's
  dither (D11), and its draw shader evaluates the CPU renderer's
  coverage formulas (with a specialized variant for the common draws,
  D10), so that its Vulkan output matches its CPU renderer; gpui draws
  straight into an 8-bit image (History has the round that measured
  this). None of it costs a frame at 60 Hz, but it is GPU time a laptop
  pays for.
- **Menus** among the toolkits with popup menus siv is first (3.6 ms
  against Qt's 18.2 and GTK's 19.6), but gpui, which draws its menu inside
  the window, shows it in 2.4 ms: a popup's first buffer waits for its
  configure round trip and a frame of its own (D17).
- **Keys in the 100 MB log**: 5.6 ms against gpui's 3.5 (but a worst of
  7.5 ms against 19.0). Round 5 (History) traced what is left to
  bookkeeping per block of the editor's text (12,800 blocks) on every
  edit (D13, D15); gpui edits one paragraph string.
- **GTK** answers keys in the gallery marginally sooner (1.94 against
  2.05 ms, within each other's run-to-run range) and holds the least GPU
  memory; its resizing costs the least CPU per second because it presents
  fewer frames (96 against about 170) and acknowledges 306 of the 360
  configures.

## History: what the comparison found in siv

The first comparisons ran siv against gpui alone, on the same machine, on
2026-10-13, while the hot spots they showed were fixed. Each round's
numbers are from the commits named and were not measured again; the
Results above are current. gpui's jump and search times in rounds 4
and 5 measured a scroll that stopped short of its target (fixed in
`710b51d`, see Results). `results/final.md` has every metric with its
range over five runs, comparing the second round of fixes
(`results/round2.md`, main at `7fac27c`) with the third (main at
`63bc95e` plus `d34089c`); `results/round1.md` is the first round (main
at `01e17ce`) and `results/baseline.md` the first comparison, before any
fix (main at `e661fb4`).

| Scenario | Metric | siv baseline | siv round 2 | siv round 3 | gpui |
| --- | --- | --- | --- | --- | --- |
| idle | startup to first frame | 28.0 ms | 26.6 ms | 25.8 ms | 71.4 ms |
| idle | CPU, wakeups | 0, 0/s | 0, 0/s | 0, 0/s | 0, 0/s |
| idle | RSS / PSS / GPU memory | 60.5 / 37.8 / 43.3 MiB | 55.5 / 36.9 / 43.3 MiB | 56.0 / 37.4 / 43.3 MiB | 75.8 / 52.7 / 81.5 MiB |
| idle | threads at start, after 10 s idle | 20 | 28, 28 | 28, 8 | 27, 27 |
| gallery | key / click to photon (median) | 2.09 / 1.71 ms | 2.01 / 1.63 ms | 1.92 / 1.65 ms | 2.36 / 2.21 ms |
| gallery | click to menu shown | 19.8 ms | 5.6 ms | 3.3 ms | 2.5 ms |
| list | scroll: CPU / GPU per frame | 3.93 / 1.73 ms | 1.50 / 1.02 ms | 1.50 / 0.72 ms | 2.01 / 0.95 ms |
| list | scroll: dropped frames, p99 interval | 0, 17.2 ms | 0, 17.3 ms | 0, 17.3 ms | 0, 17.2 ms |
| list | wheel to photon | 2.73 ms | 1.70 ms | 1.69 ms | 3.07 ms |
| text | startup to first frame | 102.5 ms | 98.6 ms | 38.0 ms | 82.8 ms |
| text | key to photon (median / max) | 606 ms | 3.30 / 4.76 ms | 3.17 / 5.88 ms | 3.48 / 19.5 ms |
| text | RSS | 536 MiB | 163 MiB | 149 MiB | 82 MiB |
| text | scroll: CPU / GPU per frame | 1.76 / 1.22 ms | 1.31 / 1.25 ms | 1.33 / 0.97 ms | 2.64 / 0.57 ms |
| grid | frames in 5 s (dropped) | 217 (0) | 300 (0) | 301 (0) | 303 (0) |
| grid | CPU / GPU per frame | 22.9 / 18.7 ms | 2.17 / 0.99 ms | 2.14 / 0.89 ms | 6.16 / 0.50 ms |
| typing | key to photon (median / max) | 23.9 / 32.9 ms | 24.0 / 32.8 ms | 23.9 / 32.7 ms | 24.1 / 32.9 ms |
| typing | CPU per frame | 3.42 ms | 1.96 ms | 1.89 ms | 2.98 ms |
| resize | resize to photon (median) | 11.0 ms | 10.6 ms | 11.1 ms | 10.8 ms |
| resize | CPU per frame | 1.86 ms | 1.47 ms | 1.46 ms | 2.37 ms |
| all | stripped binary | 10.4 MiB | 10.7 MiB | 10.8 MiB | 21.3 MiB |

Run-to-run spread is small (startup within ±2 ms, per-frame CPU within
±5%), except where noted. The typing burst types faster (125 keys/s)
than either toolkit presents, so its latency is the frame pacing of
both, about one and a half refreshes. The resize latency is set by
sway's transactions; both toolkits acknowledge every configure. siv
starts 28 threads (20 at baseline, before its pool had a blocking lane
for icon and image loads); since round 3 the pool retires workers idle
for 5 s, so an idle siv window keeps 8 (gpui keeps 27).

### Profiling and fixes

Each fix was found with `perf record` on the siv program during the
scenario (`run.py --perf`), and measured with `run.py` before and after.

| Commit | Hot spot found | Before → after |
| --- | --- | --- |
| `217304d` image: build NASM with mempcpy from the C library | siv did not build on glibc 2.44 | — |
| `24b57cb` text: remember glyph ink extents per face | 54% of a keystroke in HarfBuzz computing glyph extents with gvar deltas (Adwaita Sans is variable) | text key 606 → 299 ms; list CPU/frame 3.93 → 2.42 ms |
| `2499974` scene: merge damage rectangles in one pass, collapsing early | 65% of the grid's CPU in cubic pairwise damage merging (5,120 rectangles a frame) | grid CPU/frame 22.9 → 9.4 ms |
| `dbc9509` render: composite a translucent layer of one draw as the draw | 2,560 offscreen FP16 passes a frame, one per faded cell | grid GPU/frame 17.9 → 0.93 ms, CPU 9.4 → 2.2 ms, 43 → 60 Hz |
| `6e10dbc` text: find a paragraph or style by binary search | linear paragraph lookup per line, quadratic in the document | 3.5% of a keystroke |
| `a011a85`, `b56a111` text, ui: reshape and lay out only the paragraphs an edit changed | every keystroke reshaped and re-broke all 1.4 MB | text key 299 → 28 ms, RSS 536 → 284 MiB, typing CPU/frame 3.42 → 1.91 ms |
| `10ac961` widgets: tell binds a row from the pool is recycled | rows reused from the pool were reported fresh; binds stacked a second set of children (duplicated, overlapping rows while scrolling) | correctness; list CPU/frame 2.42 → 2.39 ms |
| `a672139` text: measure each glyph run's ink when laying it out | 22% of a keystroke asking every glyph for its bounds when painting | text key 28 → 22 ms |
| `fa6892e`, `5fa8f7f`, `56d4f26` text, ui: blocks of whole paragraphs shared between edits; splice edits; paint the lines near view; exact-size arrays | an edit copied and shifted every glyph, caret, and line of the 1.4 MB document and painted all 1.4 M glyphs; the arena kept every outgrown buffer; `std.mem.eql` compiled to per-byte broadcasts with AVX-512 | text key 22.2 → 3.3 ms, RSS 284 → 163 MiB, scroll CPU/frame 1.77 → 1.31 ms |
| `65b003e` render: skip pixels a later opaque draw covers | the list shaded three full-window quads per frame (window background, view background, border) | list GPU/frame 1.68 → 1.05 ms (draw pass 1.38 → 0.74) |
| `03b1592` render: draw borders as bands; rasterize little path coverage inline | 45% of the list's CPU rasterizing the view's border as one window-sized mask, then a third waking twelve workers per frame | list CPU/frame 2.39 → 1.50 ms, wheel to photon 2.49 → 1.70 ms |
| `5ae92cb` compositor: show a popup and its parent's response in one refresh | the menu's first buffer came about 5 ms after the click, after the window's commit had been shown, so it waited a refresh | menu shown 19.7 → 5.6 ms (KMS output: 30.5 → 19.6 ms) |
| `9aa7c08` pool: retire workers idle for 5 s | an idle window kept every worker it had ever started | idle threads after 10 s 28 → 8 |
| `e2fe7b5` render: a specialized draw pipeline for the common draws | one exact shader of 23,560 instructions and 56 VGPRs drew every rect and glyph | draw pass (GPU timestamps) text 0.84 → 0.54 ms, grid 0.53 → 0.43, list 0.65 → 0.39; GPU/frame text 1.25 → 0.97, grid 0.99 → 0.89, list 1.02 → 0.72 |
| `63bc95e` text: shape long texts on the pool and keep glyphs only where painted | the 1.4 MB document was shaped and laid out whole before the first frame; positioned glyphs of every block were kept (30 MiB) though only painting reads them | text startup 98.6 → 38.0 ms, RSS 163 → 149 MiB |
| `d34089c` render: build the CPU renderer's transfer tables once per process | each small popup's CPU renderer computed three 65,536-entry tables with `pow` before its first frame | menu shown 7.4 → 3.3 ms (5.6 before the third table) |

### Round 4: bounded memory for long documents

`results/round4.md` (five runs each, siv before at `116a844`, after at
this round's commit) for the text scenario, now with jumps, and the new
100 MB log scenario:

| Scenario | Metric | siv before | siv after | gpui |
| --- | --- | --- | --- | --- |
| text | startup to first frame | 37.2 ms | 37.0 ms | 79.5 ms |
| text | RSS at the end | 151.5 MiB | 89.4 MiB | 82.4 MiB |
| text | key to photon (median / max) | 3.18 / 5.46 ms | 3.26 / 5.85 ms | 3.46 / 19.7 ms |
| text | scroll: CPU / GPU per frame | 1.35 / 1.03 ms | 1.39 / 0.96 ms | 2.67 / 0.58 ms |
| text | jump to end (median / max) | 3.48 / 3.91 ms* | 4.50 / 9.26 ms | 7.58 / 21.7 ms |
| text | search result jump (median / max) | –† | 5.75 / 12.9 ms | 8.14 / 9.25 ms |
| logs | startup to first frame | 215.6 ms | 215.6 ms | 469.3 ms |
| logs | RSS after start / at the end / peak | 1,028 / 6,607 / 7,439 MiB | 284 / 292 / 404 MiB | 434 / 434 / 434 MiB |
| logs | key to photon (median / max) | 30.4 / 571 ms | 27.1 / 28.3 ms | 3.57 / 19.1 ms |
| logs | scroll: CPU / GPU per frame | 1.16 / 0.82 ms | 1.14 / 0.79 ms | 2.63 / 0.54 ms |
| logs | jump to end (median / max) | 3.61 / 4.21 ms* | 3.84 / 9.10 ms | 7.13 / 22.1 ms |
| logs | search result jump (median / max) | –† | 21.0 / 24.5 ms | 37.6 / 38.8 ms |

\* Scrolled with `siv_scroll_to` over a document kept whole in memory.
† siv before could not show a caret's offset; its F3 only moved the
caret (2.7 ms for the document, 20.6 ms for the logs).

siv kept every block's shaping and lines: 65 times the text's bytes,
91 MiB for the document and 7 GiB for the logs, where the background
shaping of the rest also stalled keys pressed meanwhile (571 ms). Now a
residency keeps 16 MiB of blocks for all long texts and every block's
exact metrics, builds evicted blocks again when something needs them,
estimates the metrics of blocks not shaped yet, and keeps what a scroll
container shows in place while they are measured (D13); the editor
scrolls to show its caret (D15), which is what the jumps measure. The
document's memory is within 7 MiB of gpui's; the logs' is two thirds of
it. A jump costs one to four blocks shaped again (a millisecond each),
so the first jump to a place peaks at 9 ms, against gpui's 22.

Two costs remain linear in the document's size, and show at 100 MB:
a keystroke copies the editor's text, which is one buffer (D15), and
compares the old and new text block by block to find what changed
(D13); together 27 ms for the logs against gpui's 3.6, where gpui edits
one paragraph string. siv's search copies the text out
(`siv_node_get_text`), 100 MB per search; gpui searches its strings in
place and is still slower, scanning a million of them.

### Round 5: the editor's text in a rope

`results/round5.md` (five runs each; before is round 4, `2e4e5bb`):

| Scenario | Metric | siv before | siv after | gpui |
| --- | --- | --- | --- | --- |
| text | key to photon (median / max) | 3.36 / 4.98 ms | 2.79 / 4.22 ms | 3.53 / 19.3 ms |
| text | RSS at the end | 88.6 MiB | 88.3 MiB | 82.7 MiB |
| text | search result jump (median) | 5.59 ms | 5.45 ms | 8.49 ms |
| logs | key to photon (median / max) | 26.9 / 27.9 ms | 5.28 / 7.25 ms | 3.50 / 18.7 ms |
| logs | RSS after start / at the end | 284 / 292 MiB | 285 / 289 MiB | 434 / 434 MiB |
| logs | search result jump (median) | 21.0 ms | 19.0 ms | 37.4 ms |

A keystroke copied the editor's whole text and compared all of it with
the old blocks; now the text is a rope whose edits share all but the
leaves they touch, and shaping gets what changed from the ropes and
builds only the blocks it reaches (D15). What is left in 100 MB, 2.5 ms
over the document, is bookkeeping per block (12,800 of them): the new
text's arrays of block offsets, and stacking the blocks' heights; and
laying out the edited block. Search reads the text in pieces
(`siv_node_get_text_range`, D30) instead of copying all of it.

### siv bugs found by the bench, and their fixes

- Flex `grow` and `shrink` ignored `max_*` and `min_*` sizes, so the
  gallery's list needed a fixed frame. Fixed in `6becf70` (CSS flexbox's
  freezing of clamped items); the gallery now puts the list straight in
  its column.
- "A list view in a plain box collapses at the second layout" was a
  misreading: a list view in a plain box of `auto` height is zero high
  from the first layout on, and the frame that seemed to lose it was the
  flex-grow bug above. A fractional height against a box of definite
  height now resolves (`c32c25a`, from the file manager's work), and a
  views test keeps it so.
- After the compositor scrolled a list under a still pointer, the row
  that was hovered kept its highlight until the pointer moved. Fixed in
  `8366bb6`: the UI hit-tests the still pointer again after a scroll.
- "LLVM ERROR: inconsistency in registered CommandLine options" came from
  one libLLVM (pulled in by RADV), not two: the bench's error path
  returned from `main` while the device thread was still running
  libLLVM's static constructors, and `exit` ran their destructors under
  them. Fixed in `8dd0a3e`: `exit` waits for a starting device thread
  (DESIGN D10).
- `siv_test_settle` returned after three quiet 2 ms dispatches, before a
  frame the compositor owed for a wheel scroll when that frame waited for
  the next vblank; the transfer-table fix's timing made the test API's
  Lua test fail every time. Fixed in `e8be896`: settling waits on the
  loop until the compositor owes no frame (repeating animations aside),
  with a test that forces a 300 ms refresh (DESIGN D27).
