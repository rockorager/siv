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
```

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
  presented frames for per-frame figures. **GPU time** is the program's
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
| text | An editor over a 4,000-paragraph document (about 1.2 MB, 200,000 words) at 14.67 px with 20 px lines, wrapped to the window, focused at the start. 15 key presses, 3 s of scrolling, 10 wheel notches. |
| grid | 2,560 rounded 16 px squares (64×40), each fading between opacity 1 and 0.2 every second (CSS ease-in-out, alternating) with its own delay. 5 s of animation. |
| typing | The editor with a 6-paragraph document: 300 characters typed at one per 8 ms. |
| resize | The gallery as a floating window, resized 180 times at 60 Hz between 1280×800 and 800×500. |

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

Measured 2026-10-13 on the machine above; `results/final.md` has every
metric with its range over five runs, `results/baseline.md` the first
comparison, before any fix. The "siv before" column is the baseline
(main at `e661fb4`), "siv after" includes the fixes below.

| Scenario | Metric | siv before | siv after | gpui |
| --- | --- | --- | --- | --- |
| idle | startup to first frame | 28.0 ms | 28.0 ms | 71.5 ms |
| idle | CPU, wakeups | 0, 0/s | 0, 0/s | 0, 0/s |
| idle | RSS / PSS / GPU memory | 60.5 / 37.8 / 43.3 MiB | 60.9 / 38.1 / 43.3 MiB | 76.6 / 47.1 / 81.5 MiB |
| gallery | key / click to photon (median) | 2.09 / 1.71 ms | 1.97 / 1.53 ms | 2.31 / 2.19 ms |
| gallery | click to menu shown | 19.8 ms | 19.7 ms | 2.6 ms |
| list | scroll: CPU / GPU per frame | 3.93 / 1.73 ms | 2.39 / 1.68 ms | 2.04 / 0.96 ms |
| list | scroll: dropped frames, p99 interval | 0, 17.2 ms | 0, 17.2 ms | 0, 17.3 ms |
| list | wheel to photon | 2.73 ms | 2.49 ms | 3.18 ms |
| text | startup to first frame | 102.5 ms | 99.4 ms | 80.4 ms |
| text | key to photon (median, range of run medians) | 606 ms | 22.2 ms (21.0–56.4) | 3.6 ms |
| text | RSS | 536 MiB | 284 MiB | 82 MiB |
| text | scroll: CPU / GPU per frame | 1.76 / 1.22 ms | 1.77 / 1.22 ms | 2.79 / 0.62 ms |
| grid | frames in 5 s (dropped) | 217 (0) | 301 (0) | 302 (0) |
| grid | CPU / GPU per frame | 22.9 / 18.7 ms | 2.09 / 0.96 ms | 6.18 / 0.50 ms |
| typing | key to photon (median / max) | 23.9 / 32.9 ms | 24.2 / 33.0 ms | 24.0 / 32.6 ms |
| typing | CPU per frame | 3.42 ms | 1.93 ms | 3.07 ms |
| resize | resize to photon (median) | 11.0 ms | 10.9 ms | 10.9 ms |
| resize | CPU per frame | 1.86 ms | 1.78 ms | 2.35 ms |
| all | stripped binary | 10.4 MiB | 10.4 MiB | 21.3 MiB |

Run-to-run spread is small (startup within ±2 ms, per-frame CPU within
±5%), except where noted. The typing burst types faster (125 keys/s)
than either toolkit presents, so its latency is the frame pacing of
both, about one and a half refreshes. The resize latency is set by
sway's transactions; both toolkits acknowledge every configure.

### Where siv wins

- Startup: 28 ms from `fork` to the first presented frame against 72 ms,
  in every scenario but the large document. That is wall time to a
  presented frame, not D25's first-frame CPU budget.
- Memory: 61 MiB RSS and 43 MiB of GPU memory at idle against 77 and 82;
  20 threads against 27; half the binary size (libsiv.so 10.4 MiB with
  every image decoder, against a 21.3 MiB gpui program).
- Animation: the grid costs 2.1 ms of CPU per frame against 6.2 ms,
  because siv's compositor thread animates layer opacity (D8) while gpui
  rebuilds and re-lays out 2,560 elements every frame.
- Input latency: 0.3–0.7 ms lower for keys and clicks in the gallery,
  0.7–1.4 ms for wheels.
- Typing in a short text costs 1.9 ms of CPU per frame against 3.1,
  scrolling the large document 1.8 ms against 2.8.

### Where siv loses, and why

- **GPU time per frame is about twice gpui's** (list 1.68 against 0.96
  ms, text 1.22 against 0.62, grid 0.96 against 0.50). siv renders into a
  persistent FP16 linear-light image and encodes all of it into the
  swapchain image every frame (D10, D11); gpui draws straight into an
  8-bit swapchain image. The frame rate is unaffected at 60 Hz.
- **Editing the 1.4 MB document** costs 22 ms per key against 3.6 ms, and
  284 MiB against 82. After the fixes, shaping and line breaking redo
  only the paragraphs around the edit, but siv still keeps the whole
  document shaped and laid out in flat arrays, copies them (shifted) on
  every edit, and paints every glyph into the editor's layer, so the
  cost stays linear in the text: about 16 µs per KB. In one run of five
  most keys took 56 ms instead; perf of such a run puts 14% of samples in
  the kernel zeroing fresh pages for the copies, but the slow mode is not
  fully explained. gpui's editor in this benchmark shapes only the
  paragraphs in view (`list`). Startup is 99 ms against 80 for the same
  reason.
- **Menus** show 19.7 ms after the click against 2.6 ms. siv's menu is an
  `xdg_popup` whose first buffer is committed about 5 ms after the click
  (the popup's configure round trip, its swapchain, and a frame of its
  own), after the window's commit that shows the button pressed. Headless
  sway composites the first commit at once and the second at its next
  16.7 ms tick; on a display both commits wait for the same vblank most
  of the time. gpui draws its menu inside the window, in the same frame.
- **List scrolling** costs 2.39 ms of CPU per frame against 2.04: binding
  rows that come into view on the UI thread, then composing and encoding
  on the compositor thread.

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

### siv bugs found and not fixed here

- Flex `grow` ignores `max_height` (and `max_width`): a grown item is not
  clamped (`src/ui/layout.zig`), so the gallery's list needed a fixed
  frame.
- A list view in a plain box is sized at the first layout and collapses
  to nothing at the next one, so incremental layout disagrees with a full
  one; in a flex column it keeps its size.
- After the compositor scrolls a list under a still pointer, the row
  that was hovered keeps its highlight until the pointer moves.
- Once, at startup, siv aborted with "LLVM ERROR: inconsistency in
  registered CommandLine options" (two LLVM copies in one process, from
  Mesa); it did not happen again in about 300 runs.
