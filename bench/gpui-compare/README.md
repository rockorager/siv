# siv vs gpui

Matching applications in siv and gpui (Zed's GUI framework), measured the
same way on sway with GPU rendering. Nothing here is part of siv's build or
tests; the gpui side builds only where cargo is installed.

```text
bench/gpui-compare/
  siv/bench.c        the siv program (C, against libsiv.so)
  gpui/src/main.rs   the gpui program; gpui/setup.sh fetches zed at a pinned commit
  common/doc.h       shared constants and document text (gpui/src/spec.rs mirrors it)
  harness/presshim.c LD_PRELOAD library: presentation feedback for every commit
  harness/inject.c   virtual keyboard and pointer client
  harness/run.py     runs the scenarios, writes results/raw/*.json
  harness/report.py  summarizes them as the tables in results/
```

## Running

```sh
rustup toolchain install 1.98.1 --profile minimal   # zed's pinned toolchain
ZIG=~/.local/opt/zig-0.17.0/zig ./build.sh          # libsiv (ReleaseFast), both programs, the tools
python3 harness/run.py --runs 5                     # about 25 minutes
python3 harness/report.py > results/latest.md
python3 harness/run.py --runs 1 --scenarios text --toolkits siv --perf /tmp/prof   # perf record
GC_SIV_BENCH=out/siv-bench-before python3 harness/run.py --toolkits siv --out results/raw-before   # another build of the siv program
GC_KMS=/dev/dri/card0 python3 harness/run.py --scenarios gallery   # sway on a KMS device (vkms): real vblank
```

`run.py` passes `SIV_*` environment variables to the siv program, for
experiments.

Needs sway, wayland-scanner, libwayland-client, xkbcommon, Fontconfig, the
Adwaita Sans font, and a Vulkan driver; `grim` for `--screenshots`.

gpui is built from zed commit `26363aabdb31a0c016728634202e1ad5067033aa`
(2026-10-12) with zed's own release profile (thin LTO, one codegen unit)
and the `[patch]` entries of zed's workspace that gpui's dependencies
reach. Its Linux renderer is wgpu on Vulkan. libsiv is built ReleaseFast.

## Method

Each run starts a fresh sway 1.12 on its headless backend with the Vulkan
renderer on the GPU's render node (`WLR_BACKENDS=headless
WLR_RENDERER=vulkan`), one output of 1280×800 at 60 Hz and scale 1, no
borders, so the one window is 1280×800. Both toolkits render with Vulkan
on the same GPU (RADV). Then the scenario's program starts, input comes
from `inject`, and the program is stopped. Each scenario runs five times
per toolkit, interleaved; tables give the median over runs and the range.

- **Frames** come from `presshim.so`, preloaded into both programs. It
  wraps libwayland's request marshalling (including the entry points
  Rust's wayland-backend looks up with dlsym, and Mesa's WSI commits) and
  asks for `wp_presentation` feedback on every `wl_surface.commit`, so
  both toolkits are measured by the same code, whether they present
  through Vulkan or shared memory. Its dispatch thread sleeps while no
  feedback is outstanding, so it adds no idle wakeups.
- **Startup** is from `fork` to the presentation of the toplevel's first
  frame.
- **Input to photon** is from the moment `inject` flushed the event to sway
  to the presentation of the first commit the program made after it. The
  programs commit nothing while idle (both carets are steady, see below),
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
  exits counts up to its last sample. (Until round 3 the harness
  subtracted sums over the live threads, which went negative when a
  thread exited.) **GPU time** is the program's
  `drm-engine-*` time from `/proc/PID/fdinfo` (amdgpu), which counts the
  GPU work the program submitted, not sway's composite.
- **Wakeups** are voluntary and involuntary context switches of all
  threads per second over an idle window.
- **Memory** is VmRSS and PSS (`smaps_rollup`) after startup, and
  `drm-memory-vram` for GPU memory.
- **Dropped frames** are refresh intervals during continuous motion with
  no new presentation: for each gap between presentations, its length in
  refresh periods minus one.
- **Binary size** is the stripped program, plus libsiv.so for siv. gpui
  links statically.

The machine: AMD Ryzen 5 PRO 7640HS with a Radeon 760M (RADV, Mesa 26.2.2),
Linux 7.2, `powersave` governor with `balance_performance`, sway 1.12.
Other work on the machine was light during runs; `run.py` records the
load average in every result.

## Scenarios

| Scenario | What it does |
| --- | --- |
| idle | A window with one label. 10 s idle window. |
| gallery | A title, four buttons (default, primary, disabled, and a menu button with six items), a focused 320 px text field, a checkbox, a 320×320 list of 50 selectable items, and a status label. 15 key presses into the field, 15 clicks on a button, 8 menu openings. |
| list | A 100,000-row list filling the window, two text columns per row. 5 s of touchpad scrolling at 120 events/s of 30 px each, then 15 wheel notches. |
| text | An editor over a 4,000-paragraph document (about 1.2 MB, 200,000 words) at 14.67 px with 20 px lines, wrapped to the window, focused at the start. 15 key presses, 3 s of scrolling, 10 wheel notches, then five jumps to the end and back (Ctrl+End, Ctrl+Home) and five search-result jumps (F3, then Ctrl+Home). |
| grid | 2,560 rounded 16 px squares (64×40), each fading between opacity 1 and 0.2 every second (CSS ease-in-out, alternating) with its own delay. 5 s of animation. |
| typing | The editor with a 6-paragraph document: 300 characters typed at one per 8 ms. |
| resize | The gallery as a floating window, resized 180 times at 60 Hz between 1280×800 and 800×500. |
| logs | The text scenario's editor and steps over 100 MB of log lines (1.05 M lines of about 100 bytes, `log_generate`), after waiting for the program to go quiet. |

Ctrl+End and Ctrl+Home move the caret to the end or the start and show
it. F3 searches the text for a word that occurs once, three quarters of
the way through (`DOC_NEEDLE`), puts the caret there, and shows it: siv
copies the editor's text (`siv_node_get_text`, freed after) and calls
`siv_set_selection`, whose editor scrolls to its caret (D15); gpui
searches its paragraphs and calls `ListState::scroll_to_reveal_item`.
siv before round 4 could not show a caret's offset: its build
(`-DBENCH_SCROLL_JUMP`) also scrolls to the end or the start with
`siv_scroll_to` on Ctrl+End and Ctrl+Home, and its search jump moves
only the caret.

gpui multiplies touchpad deltas by 3 (`gpui_linux`'s Wayland client), so
`run.py` sends it 10 px per event where siv gets 30: both scroll the same
3,600 px/s and end on the same row.

Text is Adwaita Sans at siv's body size (11 pt, 14.67 px) in both, in
siv's light theme colors and widget metrics (control height 32, radius 6,
padding 12).

## Differences that remain

- **Stock widgets.** gpui has no stock widgets. The gallery's buttons,
  text field (trimmed from gpui's `examples/input.rs`), checkbox, list
  (`uniform_list`), and menu are written in the gpui program with gpui's
  elements, as a gpui application would. siv's are its stock widgets,
  which do more: accessibility (AT-SPI), focus rings, keyboard navigation,
  mnemonics, transitions.
- **Menus.** siv shows menus in `xdg_popup` surfaces that can extend
  past the window; gpui draws them inside the window (`deferred` and
  `anchored`). The menu latency compares the two ways of showing a menu,
  which is what users of each see.
- **The editor.** gpui has no stock editor outside Zed. The gpui program's
  editor is a `list` over paragraphs, each a wrapped `StyledText`, with a
  caret, typing through gpui's input handler, Backspace, Enter, and arrow
  keys: it shapes and lays out only the paragraphs in view. siv's is its
  stock editor (D15): selection, undo, input methods, accessibility.
- **Carets do not blink in either.** gpui's example editor has no blink;
  siv runs with reduced motion (`SIV_APP_REDUCED_MOTION`) except in the
  grid scenario, which also turns off siv's 150 ms control transitions.
- **Animation.** siv animates the grid on its compositor thread
  (`siv_set_animation`, one layer per cell, D8); gpui re-renders the
  window every frame (`request_animation_frame`), which is how gpui
  animates.
- **Text rendering.** siv blends in linear light with its contrast
  correction (D11); gpui's text is lighter. gpui does not apply variable
  font weights, so the gallery's bold title is regular in gpui.
- **No session bus.** Neither program can reach D-Bus, so neither
  publishes accessibility or reads desktop settings (siv also runs with
  `SIV_APP_NO_DESKTOP_SETTINGS`).
- **First frames.** siv draws its first frames with the CPU renderer
  while its Vulkan device is created on a thread (D10), and switches
  after; startup measures that.

## Results

Measured 2026-10-13 on the machine above. `results/final.md` has every
metric with its range over five runs, comparing the second round of
fixes (`results/round2.md`, main at `7fac27c`) with the third (main at
`63bc95e` plus `d34089c`; a run after rebasing onto other work
matched); `results/round1.md` is the first round (main at `01e17ce`)
and `results/baseline.md` the first comparison, before any fix (main at
`e661fb4`).

| Scenario | Metric | siv baseline | siv round 2 | siv now | gpui |
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

### Where siv wins

- Startup: 26 ms from `fork` to the first presented frame against 71 ms,
  and now in every scenario: the 1.4 MB document's first frame comes in
  38 ms against 83, since siv shapes the blocks in view first and the
  rest on its worker pool (D13).
- Memory: 56 MiB RSS and 43 MiB of GPU memory at idle against 76 and 82;
  8 threads after 10 s idle against 27; half the binary size (libsiv.so
  10.8 MiB with every image decoder, against a 21.3 MiB gpui program).
- Animation: the grid costs 2.1 ms of CPU per frame against 6.2 ms,
  because siv's compositor thread animates layer opacity (D8) while gpui
  rebuilds and re-lays out 2,560 elements every frame.
- Input latency: keys and clicks in the gallery 0.4–0.6 ms lower, wheels
  1.4–1.8 ms lower; a key in the 1.4 MB document 3.2 ms against 3.5 ms,
  with a worst key of 5.9 ms against 19.5 ms.
- CPU per frame: list scrolling 1.5 ms against 2.0, document scrolling
  1.3 against 2.6, typing 1.9 against 3.0, resizing 1.5 against 2.4.
- GPU time per frame for the list: 0.72 ms against 0.95.

### Where siv loses, and why

- **GPU time per frame** for the document (0.97 against 0.57 ms) and the
  grid (0.89 against 0.50). Round 3 split the draw pass between the
  exact shader, which evaluates the CPU renderer's formulas for every
  paint, clip, and coverage (23,560 instructions, 56 VGPRs under RADV's
  shader statistics), and a variant specialized by a constant for solid
  rects, rounded rects, and glyphs with at most two analytic clips (943
  instructions, 24 VGPRs; D10). The draw pass went from 0.84 to 0.54 ms
  for the document, 0.53 to 0.43 for the grid, and 0.65 to 0.39 for the
  list, by GPU timestamps; goldens are unchanged. What remains is the
  FP16 working image and its encode pass with the CPU's dither (about
  0.2 ms, D11), and the draw pass's pixel work: gpui draws straight into
  an 8-bit image. The frame rate is unaffected at 60 Hz.
- **Menus** show 3.3 ms after the click against 2.5 ms. siv's menu is an
  `xdg_popup`, which may extend outside the window: its first buffer
  waits for the popup's configure round trip and a layout and frame of
  its own, and the window's response waits for it so both show in one
  refresh (D17); gpui draws its menu inside the window. Round 3 found
  that each small popup's CPU renderer built three 65,536-entry transfer
  tables before its first frame (7.4 ms after the third was added for
  sRGB layers); built once per process, the menu shows in 3.3 ms. Its
  change in timing exposed a race in `siv_test_settle`, which could
  return before the frame the compositor owed for a wheel scroll; it
  now waits for every frame the compositor owes (D27).
- **The large document** held 149 MiB against 82. siv kept the whole
  document shaped (glyphs, carets, and line breaks of 1.4 M characters),
  so that every height, caret, and hit test is exact; gpui's editor
  shapes only the lines in view. Round 3 dropped positioned glyphs from
  blocks that are not painted (30 MiB less), and part of that went to
  the heaps of the workers that shape in the background. Round 4 bounds
  it (89 MiB at the end of the scenario, below).
- **Keystrokes in 100 MB** cost 27 ms against 3.6 (round 4, below).

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
