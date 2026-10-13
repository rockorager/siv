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

Measured 2026-10-13 on the machine above. `results/final.md` has every
metric with its range over five runs, comparing the first round of fixes
(`results/round1.md`, main at `01e17ce`) with the second (main at
`5ae92cb`); `results/baseline.md` is the first comparison, before any
fix (main at `e661fb4`).

| Scenario | Metric | siv baseline | siv round 1 | siv now | gpui |
| --- | --- | --- | --- | --- | --- |
| idle | startup to first frame | 28.0 ms | 28.0 ms | 26.6 ms | 70.3 ms |
| idle | CPU, wakeups | 0, 0/s | 0, 0/s | 0, 0/s | 0, 0/s |
| idle | RSS / PSS / GPU memory | 60.5 / 37.8 / 43.3 MiB | 60.9 / 38.1 / 43.3 MiB | 55.5 / 36.9 / 43.3 MiB | 76.1 / 53.0 / 81.5 MiB |
| gallery | key / click to photon (median) | 2.09 / 1.71 ms | 1.97 / 1.53 ms | 2.01 / 1.63 ms | 2.36 / 2.16 ms |
| gallery | click to menu shown | 19.8 ms | 19.7 ms | 5.6 ms | 2.4 ms |
| list | scroll: CPU / GPU per frame | 3.93 / 1.73 ms | 2.39 / 1.68 ms | 1.50 / 1.02 ms | 2.12 / 0.96 ms |
| list | scroll: dropped frames, p99 interval | 0, 17.2 ms | 0, 17.2 ms | 0, 17.3 ms | 0, 17.2 ms |
| list | wheel to photon | 2.73 ms | 2.49 ms | 1.70 ms | 3.27 ms |
| text | startup to first frame | 102.5 ms | 99.4 ms | 98.6 ms | 86.6 ms |
| text | key to photon (median / max) | 606 ms | 22.2 / 24.8 ms | 3.30 / 4.76 ms | 3.55 / 20.1 ms |
| text | RSS | 536 MiB | 284 MiB | 163 MiB | 82 MiB |
| text | scroll: CPU / GPU per frame | 1.76 / 1.22 ms | 1.77 / 1.22 ms | 1.31 / 1.25 ms | 2.68 / 0.59 ms |
| grid | frames in 5 s (dropped) | 217 (0) | 301 (0) | 300 (0) | 303 (0) |
| grid | CPU / GPU per frame | 22.9 / 18.7 ms | 2.09 / 0.96 ms | 2.17 / 0.99 ms | 6.21 / 0.46 ms |
| typing | key to photon (median / max) | 23.9 / 32.9 ms | 24.2 / 33.0 ms | 24.0 / 32.8 ms | 24.0 / 32.7 ms |
| typing | CPU per frame | 3.42 ms | 1.93 ms | 1.96 ms | 3.14 ms |
| resize | resize to photon (median) | 11.0 ms | 10.9 ms | 10.6 ms | 10.9 ms |
| resize | CPU per frame | 1.86 ms | 1.78 ms | 1.47 ms | 2.33 ms |
| all | stripped binary | 10.4 MiB | 10.4 MiB | 10.7 MiB | 21.3 MiB |

Run-to-run spread is small (startup within ±2 ms, per-frame CPU within
±5%), except where noted. The typing burst types faster (125 keys/s)
than either toolkit presents, so its latency is the frame pacing of
both, about one and a half refreshes. The resize latency is set by
sway's transactions; both toolkits acknowledge every configure. siv now
runs 28 threads (20 before): other work added a blocking lane to its
worker pool for icon and image loads.

### Where siv wins

- Startup: 27 ms from `fork` to the first presented frame against 70 ms,
  in every scenario but the large document.
- Memory: 56 MiB RSS and 43 MiB of GPU memory at idle against 76 and 82;
  half the binary size (libsiv.so 10.7 MiB with every image decoder,
  against a 21.3 MiB gpui program).
- Animation: the grid costs 2.2 ms of CPU per frame against 6.2 ms,
  because siv's compositor thread animates layer opacity (D8) while gpui
  rebuilds and re-lays out 2,560 elements every frame.
- Input latency: keys and clicks in the gallery 0.3–0.5 ms lower, wheels
  1.6–1.8 ms lower; a key in the 1.4 MB document 3.3 ms against 3.6 ms,
  with a worst key of 4.8 ms against 20.1 ms.
- CPU per frame: list scrolling 1.5 ms against 2.1, document scrolling
  1.3 against 2.7, typing 2.0 against 3.1, resizing 1.5 against 2.3.

### Where siv loses, and why

- **GPU time per frame** is about the same for the list (1.02 against
  0.96 ms) but twice gpui's for the document (1.25 against 0.59) and the
  grid (0.99 against 0.46). siv's one fragment shader evaluates the CPU
  renderer's formulas exactly (coverage, clips, paints) into an FP16
  image and encodes it with the CPU's dither (D10, D11); gpui's
  specialized shaders draw straight into an 8-bit image. Skipping
  covered pixels fixed the list's overdraw; an sRGB working image and
  encoding by swapchain image age were measured and gave nothing (D10).
  The frame rate is unaffected at 60 Hz.
- **Menus** show 5.6 ms after the click against 2.4 ms. siv's menu is an
  `xdg_popup`: its first buffer has to wait for the popup's configure
  round trip and a layout and frame of its own. The window's response
  now waits for it, so both show in one refresh (D17), on a KMS output
  with real vblank too; gpui draws its menu inside the window.
- **The large document** still holds 163 MiB against 82 and starts in
  99 ms against 87: siv shapes and lays out all of it at startup (in
  blocks, D13), while gpui's editor here shapes only the paragraphs in
  view. Editing it is now as fast as gpui's.

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
