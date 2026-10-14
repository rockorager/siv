# siv

A high-performance GUI toolkit for Linux, written in Zig with a stable C ABI.
Wayland only.

The name comes from Coheed and Cambria's *Good Apollo, I'm Burning Star IV*.

**Status:** pre-1.0 (0.1.0), Linux and Wayland only. Until 1.0 a minor
release may change the API and ABI. See [DESIGN.md](DESIGN.md) for the
decisions so far.

- A retained node tree changed in transactions, with stock widgets (buttons,
  fields, editors, lists, tables, trees, menus, dialogs) that are keyboard
  navigable and accessible through AT-SPI.
- Scrolling and animation run on a compositor thread, so a busy
  application thread does not stall them; an idle application makes no
  wakeups.
- A Vulkan renderer, and a CPU renderer that draws when there is no GPU;
  the CPU renderer is the reference the Vulkan renderer's output is tested
  against.
- One schema generates the C header, the Zig API, the Lua binding, the
  reference, and a JSON description for other binding generators.

## Performance

Measured with the harness in [bench/gpui-compare](bench/gpui-compare):
the same applications (an idle window, a widget gallery, a 100,000-row
list, a 1.2 MB editable document, an animated grid, typing, resizing)
written with each toolkit's own widgets, run on headless sway, driven by
synthetic input through the compositor, and timed from the compositor's
presentation feedback. siv, gpui (Zed's GUI framework), Qt Quick 6.11,
and GTK 4.22 all render with Vulkan on the same GPU, a Radeon 760M (RADV,
Mesa 26.2.2) in a Ryzen 5 PRO 7640HS, measured 2026-10-14 at siv
`fcb487f`. Medians of five runs in one session, without thermal or
frequency pinning: directional numbers, good for where each toolkit
stands and by roughly how much. The bench's README has the method, the
programs' differences, and every metric with its range.

| | siv | gpui | Qt Quick | GTK 4 |
| --- | --- | --- | --- | --- |
| Startup to first frame, idle window | 25.8 ms | 75.2 ms | 69.4 ms | 60.0 ms |
| Startup to first frame, 1.2 MB document | 34.8 ms | 83.8 ms | 651 ms | 86.6 ms |
| RSS / PSS, idle window | 48.5 / 29.9 MiB | 77.1 / 53.9 MiB | 85.1 / 61.9 MiB | 65.1 / 40.9 MiB |
| GPU memory (VRAM + GTT), idle window | 38.5 MiB | 98.7 MiB | 123 MiB | 26.0 MiB |
| Threads after 10 s idle | 8 | 27 | 9 | 11 |
| Key / click to photon, gallery | 2.05 / 1.75 ms | 2.43 / 2.25 ms | 2.02 / 1.76 ms | 1.94 / 1.81 ms |
| Click to menu shown | 3.59 ms | 2.38 ms¹ | 18.2 ms | 19.6 ms |
| Wheel to photon, 100,000 rows | 1.66 ms | 3.21 ms | 23.7 ms | 2.78 ms |
| Key to photon in the 1.2 MB document, median / worst | 2.75 / 3.78 ms | 3.57 / 19.1 ms | 7.37 / 8.69 ms | 2.78 / 18.2 ms |
| Scrolling 100,000 rows: CPU / GPU per frame | 1.44 / 0.89 ms | 1.95 / 0.94 ms | 2.04 / 0.24 ms | 1.74 / 0.19 ms |
| Scrolling the document: CPU / GPU per frame | 1.31 / 0.92 ms | 2.66 / 0.58 ms | 2.85 / 0.36 ms | 1.99 / 0.36 ms |
| 2,560 animated cells: CPU / GPU per frame | 2.06 / 0.91 ms | 6.10 / 0.47 ms | 7.05 / 0.52 ms | 6.35 / 0.34 ms |
| Resizing: CPU per frame | 1.45 ms | 2.40 ms | 1.97 ms | 1.92 ms |
| Stripped size | 11.2 MiB (libsiv.so) | 21.3 MiB | shared Qt | shared GTK |

¹ gpui draws its menus inside the window; siv, Qt, and GTK show theirs in
popup surfaces, whose first frame waits for the popup's configure.

All four keep 60 Hz with no dropped frames while scrolling and
animating, and none wakes while idle. siv starts two to three times
sooner than gpui and GTK (and Qt Quick with a small window; Qt Quick
takes in the whole 1.2 MB document before its first frame), holds the
least memory apart from GTK's GPU memory, and spends the least CPU per
frame in every scenario with motion (a third of the others' on the grid,
which siv animates on its compositor thread). siv spends more GPU time
per frame than Qt and GTK (about 0.9 ms against 0.2 to 0.5), and more
than gpui except on the list: it renders into an FP16 working image in
linear light so that its Vulkan output matches its CPU renderer (D11).
Qt Quick shows a wheel notch a refresh after it, and Qt's and GTK's
menus show a refresh after the click.

Read these with their limits:

- One machine, one compositor (sway's headless output, which composites a
  frame as soon as a client commits), one integrated GPU. Nothing here
  measures X11, other compositors, a discrete GPU, HiDPI scales, or input
  methods.
- The programs match in content and sizes, not in features or looks.
  siv, Qt, and GTK use their stock widgets (with keyboard navigation and
  accessibility, which no program publishes here: there is no session
  bus); gpui has no stock widgets, so the gpui program draws simpler ones
  of its own. Qt is Qt Quick with Qt Quick Controls: Qt Widgets paints on
  the CPU even with a GPU, so it is not compared.
- GPU time is what each program submits to the GPU (amdgpu's fdinfo), not
  sway's composite; GPU memory is the program's VRAM and GTT buffers,
  outside RSS.

To reproduce, see [bench/gpui-compare/README.md](bench/gpui-compare/README.md#running).

## Building

Requires Zig 0.17.0 and the development packages for libwayland-client,
xkbcommon, Fontconfig, and the Vulkan headers (on Debian:
`libwayland-dev libxkbcommon-dev libfontconfig-dev libvulkan-dev`). Every
other dependency (HarfBuzz, the image decoders, Lua) is fetched and built
by `zig build`; `-fsys=<name>` links the system's copy instead.

```sh
zig build            # libsiv.so, libsiv.a, include/siv.h, siv.pc in zig-out/
zig build test -j16  # -j: Zig 0.17 runs about two steps at once by default
zig build examples   # C programs from examples/ in zig-out/bin/
zig build -Doptimize=ReleaseSafe --prefix /usr/local   # install
```

At run time siv needs a Wayland compositor, libwayland-client, xkbcommon,
and Fontconfig; it uses the Vulkan loader when one is installed and
xdg-desktop-portal when it is running.

## Using siv

The [guide](docs/guide/README.md) teaches siv from a first window to
lists, custom widgets, async work, printing, and testing, with samples in
C, Zig, and Lua; `zig build guide` builds, runs, and checks every one of
them. [apps/files](apps/files) is a larger example: a file manager
written against the public API only. The reference for every function and
type is generated into `zig-out/share/doc/siv/siv.md`.

### C

siv's ABI is C11: `siv.h`, `libsiv.so.0` (or `libsiv.a`), and pkg-config.

```sh
cc hello.c $(pkg-config --cflags --libs siv) -o hello
# from a checkout: PKG_CONFIG_PATH=zig-out/lib/pkgconfig to build, LD_LIBRARY_PATH=zig-out/lib to run
```

Builders append nodes in a transaction and the first failure makes the
rest do nothing, so a tree is built without checking every call:

```c
/* on_click and counter as in docs/guide/examples/hello.c */
siv_app app;
siv_window window;
siv_txn txn;
if (siv_app_create(NULL, &app) != SIV_OK) return 1;
siv_result r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Hello"), .width = 320, .height = 160), &window);
if (r == SIV_OK) r = siv_txn_begin(window, &txn);
if (r == SIV_OK) {
	siv_node root = siv_window_get_root(window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 12, .align_items = SIV_ALIGN_START));
	siv_text(txn, column, SIV_STR("Hello, siv"));
	siv_node button = siv_push_button(txn, column, SIV_DESC(siv_button_desc, .label = SIV_STR("Click me")));
	siv_on(txn, button, SIV_EVENT_TYPE_ACTIVATE, on_click, NULL, &counter);
	counter.label = siv_text(txn, column, SIV_STR("Not clicked yet"));
	r = siv_txn_commit(txn);
}
if (r == SIV_OK) r = siv_app_run(app);
siv_app_destroy(app);
```

[docs/guide/examples/hello.c](docs/guide/examples/hello.c) is complete,
and [Getting started](docs/guide/01-getting-started.md) walks through it.

### Zig

siv is a Zig package. `zig fetch --save git+https://github.com/rockorager/siv`,
then import its `siv` module: the Zig API, generated from the same schema
as siv.h, with Zig errors, slices, enums, and packed flags.

```zig
const siv = b.dependency("siv", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("siv", siv.module("siv"));   // linked against libsiv.so
b.installArtifact(siv.artifact("siv"));
```

```zig
const app = try siv.appCreate(null);
defer siv.appDestroy(app);
const window = try siv.windowCreate(app, .{ .title = "Hello", .width = 320, .height = 160 });
```

The `siv-static` module links libsiv.a instead, for a program that ships
as one file, and `siv-lua-static` adds the Lua binding for a program that
runs its users' Lua. [docs/guide/examples/zig-package](docs/guide/examples/zig-package)
is a complete package, and
[Getting started](docs/guide/01-getting-started.md#zig) has the full
`build.zig`, including the rpath and the NOTICES file to ship.

### Rust, through the C ABI

siv has no Rust crate. Rust uses the C library directly: bindgen
generates declarations from siv.h, and pkg-config finds libsiv.
[examples/rust](examples/rust) is the guide's first window in Rust:

```sh
zig build
PKG_CONFIG_PATH=$PWD/zig-out/lib/pkgconfig cargo run --manifest-path examples/rust/Cargo.toml
```

Its `build.rs` runs `pkg_config::probe("siv")` and bindgen over siv.h
(bindgen needs libclang: `libclang-dev` on Debian), and `main.rs` calls
siv as C does:

```rust
let mut window: siv_window = 0;
siv_window_create(app, desc!(siv_window_desc { title: title.as_ptr().cast(), title_len: title.len(), width: 320, height: 160 }), &mut window);
let button = siv_push_button(txn, column, desc!(siv_button_desc { label: label.as_ptr().cast(), label_len: label.len(), style: SIV_BUTTON_STYLE_PRIMARY }));
siv_on(txn, button, SIV_EVENT_TYPE_ACTIVATE, Some(on_click), None, (&raw mut counter).cast());
```

where `desc!` sets a descriptor's `size` field as `SIV_DESC` does. Calls
are `unsafe`; callbacks are `unsafe extern "C" fn`s and run on the thread
that called `siv_app_run`. A safe wrapper is left to the application. The
example was checked with Rust 1.98.1, bindgen 0.72, and libclang 21.

### Lua

siv's Lua binding is for Lua 5.5, three ways:

```sh
./zig-out/bin/siv-lua examples/todo.lua           # Lua built into libsiv-lua
./zig-out/bin/siv-lua --watch examples/todo.lua   # reload on save
LUA_CPATH='zig-out/lib/lua/5.5/?.so' lua5.5 -e 'require("siv")'   # your own Lua 5.5
```

and a C program links libsiv-lua (`pkg-config siv-lua`) and calls
`siv_lua_new` and `siv_lua_run` from `siv_lua.h` to embed it. Builders take
a table of properties and handlers:

```lua
local siv = require("siv")
local app = siv.app_create()
local win = app:window_create{ title = "Hello", width = 320, height = 160 }
win:update(function(txn, root)
	txn:set_visual(root, { background_token = "window_bg" })
	local column = txn:flex(root, { axis = "column", gap = 12, align_items = "start" }, { layout = { padding = 24 } })
	txn:push_button(column, { label = "Click me" }, { on = { activate = function() print("clicked") end } })
end)
app:run()
```

Annotations for lua-language-server are generated into
`zig-out/share/siv/lua/siv.lua`.

### Generated bindings

Every function, type, and constant is described once, in
[src/abi/api.zig](src/abi/api.zig), and generated from there (D3), so the
languages cannot drift apart:

| Output | Installed as |
| --- | --- |
| The C header | `include/siv.h` |
| The Zig API | `share/siv/siv.zig` (the `siv` module) |
| The Lua binding and its annotations | `lib/libsiv-lua.so`, `lib/lua/5.5/siv.so`, `share/siv/lua/siv.lua` |
| The reference | `share/doc/siv/siv.md` |
| The API as data, for other binding generators | `share/siv/siv.json` |

A C function maps to Zig and Lua by fixed rules (the table in
[Getting started](docs/guide/01-getting-started.md#one-api-three-languages));
a binding for another language can be generated from `siv.json` instead of
parsing the header. libsiv.so exports only `siv_*` symbols, checked by
`zig build test-abi`.

### Other integrations

- **Another event loop** (GLib, libuv, a game loop): poll
  `siv_app_get_fd` and call `siv_app_dispatch`
  ([Embedding](docs/guide/12-embedding.md), [examples/embed.c](examples/embed.c)).
- **Video and 3D content**: external nodes take frames in shared memory or
  dma-bufs, or give you a `wl_surface` for your own EGL, Vulkan, or
  GStreamer ([External surfaces](docs/guide/13-external-content.md)).
- **The desktop**: xdg-desktop-portal (file choosers, settings, opening
  URIs, printing), notifications, a tray item, D-Bus, and AT-SPI
  for screen readers ([Accessibility](docs/guide/11-accessibility.md),
  [Work off the UI thread](docs/guide/09-async.md)).
- **Printing and PDF** from the same drawing calls as a canvas
  ([Printing](docs/guide/14-printing.md)).
- **Packaging**: desktop files, D-Bus activation, and Flatpak
  ([Packaging](docs/guide/15-packaging.md)).
- **Tests without a display**: the headless backend and the test API
  drive an application and compare what it shows
  ([Testing](docs/guide/17-testing.md)).

siv does not run on X11, macOS, or Windows, and has no bindings other than
C, Zig, and Lua.

See [AGENTS.md](AGENTS.md) for the module layout and contribution rules.

## License

siv is released under the MIT license; see [LICENSE](LICENSE). The
licences of the libraries and data compiled into libsiv are installed with
it as `share/licenses/siv/NOTICES`.
