# siv-webview: notes and measurements

siv-webview is the web view library in `webview/` (D33): `zig build`
builds it when pkg-config finds WPE WebKit (`-Dwebview=auto`, the
default; `true` requires it, `false` skips it), and
`zig build test-webview` runs its headless tests. These are its notes from the
four phases it was built in: the spike, the hooks it needed in siv, the
library, and the checks on real compositors. Paths are under `webview/`
unless they start with `examples/` or `docs/`.

## What applications need at run time

- WPE WebKit 2.50 or later with WPEPlatform (Arch: `wpewebkit`, which
  brings GStreamer, bubblewrap, and xdg-dbus-proxy).
- GStreamer's `autoaudiosink` element, from gst-plugins-good: Arch
  `gst-plugins-good` (wpewebkit lists it only as optional), Debian and
  Ubuntu `gstreamer1.0-plugins-good`, Fedora `gstreamer1-plugins-good`.
  Without it WPE WebKit's web process aborts (`GStreamer element
  autoaudiosink not found. Please install it`, then SIGABRT) as soon as a
  page gives a media element a source: `<audio src>`, `<video>`,
  `new Audio(url)`. Plain pages, and a bare `new AudioContext()`, are
  unaffected. So siv-webview asks GStreamer's registry when it starts its
  first web view, prints one line naming the element and the package
  when it is missing, and turns media off (D33): audio and video
  elements, Web Audio, and WebRTC; pages load without them instead of
  crashing. `SIV_WEBVIEW_KEEP_MEDIA` (Zig `.keep_media`, Lua
  `"keep_media"`) keeps media on regardless.
- Decoders for the media pages play: gst-plugins-bad and gst-libav on
  Arch (also optional dependencies of wpewebkit).

## Phase 1: the spike (2026-10-15)

`spike/spike.c` renders pages through WPE WebKit's platform API
(WPEPlatform) into a siv window, using only siv's public C ABI. It
implements `WPEDisplay`, `WPEView`, `WPEToplevel`, and `WPEScreen`
subclasses; WebKit hands each finished frame to `render_buffer` as a
dma-buf (or SHM buffer), the spike submits it to a siv frame slot
(`siv_external_submit`, with WebKit's rendering fence as the frame's
sync_file), and siv promotes it to a subsurface. Input comes from
`siv_on` handlers on the external node and goes to `wpe_view_event`.

### WPE WebKit on this machine

- Arch `wpewebkit` 2.52.6 (plus `libwpe` 1.16.3, `wpebackend-fdo`
  1.16.1, installed as its dependencies). The platform API is in
  `libWPEWebKit-2.0.so`; headers in
  `/usr/include/wpe-webkit-2.0/wpe-platform/wpe/`, pkg-config
  `wpe-platform-2.0`. It ships `WPEDisplay`/`WPEView`/`WPEToplevel`/
  `WPEScreen`/`WPEScreenSyncObserver` (derivable),
  `WPEBufferDMABuf`/`WPEBufferSHM`, rendering and release fences,
  `WPEKeymapXKB`, `WPEInputMethodContext`, `WPEClipboard`,
  `WPEGestureController`, and `WPEViewAccessible` (AT-SPI plug id).
- Runtime: `WPEWebProcess` and `WPENetworkProcess` (in
  `/usr/lib/wpe-webkit-2.0/`), each sandboxed with `bubblewrap` 0.12 and
  `xdg-dbus-proxy` 0.1.8; GStreamer 1.28 (`gst-plugins-base/bad-libs`,
  installed `gst-plugins-good`, `-bad`, `gst-libav` for media); libsoup3,
  Mesa EGL/GBM in the web process. No GPU process was started (2.52 has
  `WPEGPUProcess`; it stays off by default). The UI process needs an EGL
  display only to list importable formats (GBM on `renderD128`).

### Numbers (headless sway 1.12, Vulkan renderer, Radeon 760M, 1280x800@60, scale 1)

libsiv ReleaseFast, spike `-O2`, 3 runs (`bench/run.py`, raw data in
`bench/results/phase1-headless.json`). Latencies are from inject's flush
to sway to the presentation of the first commit after it (presshim);
sway's headless output composites at commit, so no vblank wait is
included (phase 4 measures on the panel).

| | local test page | en.wikipedia.org (Wayland article) |
| --- | --- | --- |
| first web frame on screen (fork to presentation) | 176 ms | 142 ms |
| key to photon, typing into a field (median / p90) | 12.6 / 23.8 ms | |
| wheel notch to photon (median / p90) | 14.1 / 19.9 ms | 19.0 / 25.2 ms |
| touchpad scrolling, 120 events/s for 3 s | 61.8 presents/s, 0 dropped | 61.2 presents/s, 0 dropped |
| memory, RSS / PSS / GPU (MiB) | | |
| UI process (siv + WebKit UI side) | 114 / 53 / 45 | 116 / 57 / 44 |
| WPEWebProcess | 196 / 107 / 148 | 287 / 228 / 170 |
| WPENetworkProcess | 58 / 30 / 0 | 75 / 43 / 0 |
| xdg-dbus-proxy (+ 5 bwrap stubs, ~1 MiB PSS) | 6 / 1 / 0 | 6 / 1 / 0 |
| total | 382 / 191 / 193 | 492 / 330 / 214 |

The first web frame shows 125–135 ms after process start for a local
page (WebKit launches its processes and lays out in that time); siv's
own first frame is at ~90 ms. A static page renders 2 frames in 6 s
while idle.

### What siv lacks, and how the spike bridged it

1. **Bug: a promoted subsurface that covers the whole window stalls the
   window.** wlroots sends frame callbacks only to surfaces that are
   visible; an opaque subsurface covering the window hides the parent, so
   its frame callbacks stop and siv's frame clock (which waits for them)
   never presents again. If it happens before the window's first frame
   reaches the screen, the window stays black. Any fullscreen video in a
   frame slot hits it too. Reproduced with `SPIKE_FULL=1`; bridged by the
   toolbar, which keeps part of the window visible.
   Plan: request frame callbacks (and use them for the frame clock) on
   promoted frame-slot subsurfaces as well as the window.
2. **No presentation event for slot frames.** `PRESENTED` window events
   follow UI commits only, so a producer cannot pace itself (WebKit's
   `wpe_view_buffer_rendered` is a frame callback). Bridged: call it on
   idle right after each submit; WebKit then paces with its own 60 Hz
   timer. Plan: a `presented` external event per shown frame (key and
   time), from the commit that showed it.
3. **No size or scale for frame slots.** `configure` exists only for
   surface slots. Bridged: poll `siv_node_get_rect` and
   `siv_window_get_scale` after every siv dispatch. Plan: send
   `configure` (logical size, buffer size, scale) to frame slots too.
4. **No way to run GLib's main context inside siv's loop.** WebKit needs
   the thread-default GMainContext dispatched. GLib does not wake its own
   poll for sources added on the owning thread, so watching its fds is not
   enough: it needs a `prepare` step before each wait. Bridged: GLib
   drives and siv is a GSource (D6 embedding). Plan: a loop hook that runs
   before siv waits and returns a timeout (GLib, GStreamer, PipeWire and
   libdbus integrations all need one).
5. **Key events have no hardware keycode.** `event.code` is
   "Unidentified" in the page. Bridged: keycode 0, keyval from the keysym.
   Plan: add the XKB keycode to `siv_event` (and expose the keymap).
6. **Scroll events are post-policy.** A handler gets siv's scaled
   distance (wheel detents scaled by extent^(2/3), touchpads ×4) with no
   axis source, no value120 steps, and no stop, so WebKit cannot do its
   own line steps or kinetic scrolling. Bridged: precise deltas of siv's
   distance (scrolling feels like siv's, not like a browser). Plan: add
   the source, steps, raw distance, and stop events.
7. **No raw touch.** Touch drives the pointer. Plan: touch events
   (id, phase, position) for nodes that handle them.
8. **No input method for custom nodes.** text-input-v3 serves siv's
   editors only. Plan: a node-level text-input state (enabled, cursor
   rectangle, surrounding text, content type) and preedit/commit/delete
   events.
9. **No way to put another process's AT-SPI tree under a node.** WebKit
   gives a plug id (`WPEViewAccessible.bind`). Plan: an embed setter that
   makes the remote root the node's accessible child and tells it its
   parent (`org.a11y.atspi.Socket.Embedded`).
10. **Bug: siv's Vulkan renderer imports single-plane XRGB8888 dma-bufs
    only.** WebKit's buffers on RADV are 2-plane (DCC) XRGB8888, so a
    clipped, rounded, transformed, or translucent webview draws nothing
    ("cannot import it (Unsupported)"). Plan: import every memory plane
    of a modifier, and ARGB8888.
11. Cursor images (`set_cursor_from_bytes`, CSS `cursor: url()`) have no
    siv call; named cursors map to `siv_set_cursor`. Left for later.

Other observations: siv's prebuilt `zig-out/bin` examples were stale against the
current libsiv (`siv_window_root`).

## Phase 2: the siv hooks (pushed to siv main)

| commit | hook |
| --- | --- |
| f0b153a | frame callbacks on covering subsurfaces (fixes the stall in 1) |
| 1f765a6 | frame slots get `configure` (size, buffer size, scale) and `presented` per shown frame (2, 3) |
| adbdec2 | `siv_app_add_prepare`: a hook before each wait, returning a timeout (4) |
| c6199a1 | `keycode`, raw scroll (`raw_dx/dy`, `steps_x/y` value120, `scroll_source`, stop), touch events (5, 6, 7) |
| a03e066 | `siv_set_text_input` and `text_input` events for custom nodes (8) |
| 0880928 | `siv_set_accessible_embed`: a remote AT-SPI root under a node (9) |
| db34105 | Vulkan import of multi-plane (DCC) dma-bufs (10) |
| fadec5c | Lua `siv.handle(h)` and `siv.wrap(type, n)`, so other libraries' Lua modules take and return siv userdata |
| 1d46df8 | a menu closed without a choice reports `close` (WebKit's `<select>` must hear it) |

Left for later: the XKB keymap text (WebKit builds its own from the
keycodes, so `event.code` and layouts work) and cursor images (11).

## Phase 3: the library

- `siv-webview.h` (installed as `include/siv-webview.h`): handles, descriptors, `siv_result`, and one
  event callback per web view, in siv's style (D2). `webview.c` is
  the siv side (frame slot, node, input handlers, cursor, text input,
  accessibility embed, drops); `swv.h` the engine table; `wpe.c`
  and `wpe_webkit.inc` the WPE engine; `glib_loop.c` runs GLib's
  default context inside siv's loop with `siv_app_add_prepare`.
- `siv_webview.zig`: the Zig module `siv_webview` (siv's types; slices,
  errors, methods), and `siv_webview-static`, the same linked against
  libsiv-webview.a and libsiv.a, beside `siv-static`. `lua.c`: `require("siv.webview")`, as
  `lib/lua/5.5/siv/webview.so` beside `siv.so`, and preloaded by the
  `siv-webview-lua` runner (siv-lua loads no C modules).
- Popups: `<select>` and the context menu are siv menus at the element
  or the click (context menu titles' GTK mnemonics become siv
  mnemonics); file inputs open siv's portal file chooser; notifications
  go to `siv_notification_send` unless the application shows them;
  permission requests are events the application answers.
- Drag and drop: WPE 2.52's platform API has none. Text and URLs dropped
  on the node become DOM `dragenter`/`dragover`/`drop` events (or are
  inserted into editable elements); files cannot be dropped in, and
  drags out of a page do not start.
- Dark mode: WebKit reads the appearance once per process from the
  primary WPE display, so the first display stays primary for the
  process's life and the last web view to set a color scheme decides.
- User scripts (`siv_webview_add_user_script`, `wv:addUserScript`,
  `wv:add_user_script`): WebKit user scripts in the web view's content
  manager, at document start or end, in the main frame or all frames,
  after siv's own `window.siv` script. They take effect from the next
  load (WebKit does not inject into the current document); each has an
  id for `siv_webview_remove_user_script`.
- `load_html` replaces the current history entry in WPE 2.52 rather
  than adding one; `load_uri` adds one.
- Tests (`zig build test-webview`, also part of `zig build test` when
  the web view is built): `tests/headless.c` (now 22 checks: load and
  title, scripts, messages both ways, user scripts (document start and
  end, frames, after a navigation, removal), `app://` schemes, navigation and
  new-window policy with real clicks, typing, frames in a capture, data
  directory vs ephemeral, cookies kept in the data directory's
  `cookies.sqlite` after the application exits (none from an ephemeral
  web view), zoom and dark mode, input devices, history, drops, Ctrl+C
  on page text (copied once, in a later application, without GLib
  criticals), Ctrl+V into a field after the page's own copy (in a later
  application), a wheel without value120, no scripts,
  a page playing audio with GStreamer's autoaudiosink hidden),
  `tests/zig.zig` (layout against the C header, a page through the Zig
  module), `tests/headless.lua`. All on siv's headless backend with the
  engine in software: no compositor, no GPU, about 3 s.

## Phase 4: on the panel, sway and Hyprland (2026-10-15)

The laptop's eDP panel (1280x800, 60.003 Hz) on the 760M, driven by sway
1.12 (`spike/sway-drm.sh`) and by Hyprland 0.56.2
(`spike/hyprland-drm.sh`), DRM backends on `/dev/dri/card1`, scale 1.
siv and the library ReleaseFast, the example browser, 3 runs each
(`bench/run.py`; raw data in `bench/results/phase4-*.json`). Latencies
include the wait for the panel's next vblank (up to 16.7 ms).

| | sway, test page | sway, Wikipedia | Hyprland, test page | Hyprland, Wikipedia |
| --- | --- | --- | --- | --- |
| first web frame (fork to presentation) | 200 ms | 179 ms | 187 ms | 180 ms |
| key to photon, median / p90 | 26.7 / 32.1 ms | | 20.7 / 29.9 ms | |
| wheel notch to photon, median / p90 | 25.3 / 29.9 ms | 29.2 / 38.5 ms | 26.1 / 30.6 ms | 28.4 / 41.9 ms |
| touchpad scrolling, 120 events/s for 3 s | 60.2 presents/s, 0 dropped | 59.8/s, 0 dropped | 60.2/s, 0 dropped | 59.8/s, 0 dropped |
| memory total, RSS / PSS / GPU (MiB) | 383 / 243 / 174 | 496 / 344 / 226 | 386 / 232 / 169 | 512 / 345 / 230 |

Per process (sway, test page): browser 114/63/44, WPEWebProcess
197/146/130, WPENetworkProcess 58/32/0, xdg-dbus-proxy and five bwrap
stubs about 2 MiB PSS.

Checked on both compositors, by screenshots, logs, and AT-SPI:

- Typing (real `KeyboardEvent.code`s), wheel and touchpad scrolling.
- Input method: `bench/ime` (an input-method-unstable-v2 client) composed
  "n~" as preedit and committed "ñandú" into a page field; it saw the
  field's surrounding text, content type, and an 18 px caret rectangle.
  (No CJK font is installed, so the demo uses Latin text.)
- `<select>` as a siv menu (choose, Escape, reopen), the context menu.
- File input through the portal: xdg-desktop-portal-gtk's chooser opened
  over the window; a chosen file reached the page.
- Video through GStreamer: VP9/Opus WebM over HTTP, 30 fps, 0 dropped
  frames. `file://` media fails: GStreamer's filesrc runs in the
  bubblewrap sandbox, which does not see the page's directory (pages
  should use `app://` or HTTP; an API for extra sandbox paths could
  follow).
- AT-SPI (`tools/atspi-dump.py`, accerciser is not packaged): the page's
  tree (document, heading, entry, button, combo box with its options,
  link) is under the siv node's "Web page" document frame
  (`bench/results/phase4-atspi-*.txt`).
- Fractional scale: Hyprland at 1.6 (it rounds 1.5 to a divisor of the
  mode): `devicePixelRatio` 1.6, `innerWidth` 800, and a canvas of
  1-device-pixel lines reached the panel with every edge sharp and no
  grey pixel.

Found and fixed on the way: Ctrl+L in the examples now selects the
address; a wheel without value120 (Hyprland's virtual pointer) counts 15
per detent. Bench artifacts: Hyprland gives a new window pointer focus
only on motion (`run.py` wiggles first) and reports the window's and
subsurface's presentations separately (counted once). A Wikipedia
fundraising banner swallows wheel events over it (page behavior; the
Hyprland Wikipedia row scrolls with the pointer over the article).

Video: `spike/demo.sh` records typing, composition, `<select>`, the
context menu, scrolling, and video on sway (wf-recorder).
