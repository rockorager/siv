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
| list | A 100,000-row list filling the window, two text columns per row. 5 s of touchpad scrolling at 120 events/s and 30 px per event, then 15 wheel notches. |
| text | An editor over a 4,000-paragraph document (about 1.2 MB, 200,000 words) at 14.67 px with 20 px lines, wrapped to the window, focused at the start. 15 key presses, 3 s of scrolling, 10 wheel notches. |
| grid | 2,560 rounded 16 px squares (64×40), each fading between opacity 1 and 0.2 every second (CSS ease-in-out, alternating) with its own delay. 5 s of animation. |
| typing | The editor with a 6-paragraph document: 300 characters typed at one per 8 ms. |
| resize | The gallery as a floating window, resized 180 times at 60 Hz between 1280×800 and 800×500. |

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
