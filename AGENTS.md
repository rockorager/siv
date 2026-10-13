# Working on siv

DESIGN.md is the source of truth. Read it before changing behavior, and
update it in the same change when a decision changes.

## Build and test

Requires Zig 0.17.0 and the development packages for libwayland-client,
xkbcommon, Fontconfig, and the Vulkan headers (`.agents/setup` installs
them on Debian, with lavapipe and the validation layer for the Vulkan
tests).

```sh
zig build                      # zig-out: libsiv.so, libsiv.a, include/siv.h, lib/pkgconfig/siv.pc
zig build test                 # every module's tests, headless tests, C ABI smoke test
zig build test-text            # one module: test-abi, test-text, test-raster, test-scene, test-image, test-svg, test-icon,
                               #   test-render-cpu, test-render-vulkan, test-pool, test-loop,
                               #   test-dbus, test-portal, test-pdf, test-tray, test-platform,
                               #   test-compositor, test-ui, test-a11y, test-app
zig build test-headless        # headless integration tests (test/headless.zig)
zig build test-integration     # Wayland backend against headless sway, D-Bus against
                               #   dbus-daemon (not in `test`; .agents/setup installs both)
zig build bench-pacing         # frame pacing on sway end to end (dropped frames,
                               #   wheel-to-photon, prediction error) against D12's
                               #   thresholds; not in any test step, needs a quiet machine
SIV_SWAY_RENDERER=vulkan zig build test-integration  # sway renders on the GPU: linux-dmabuf,
                               #   hardware Vulkan presentation, dma-buf frames (gles2 works
                               #   too; with vgem loaded, set WLR_RENDER_DRM_DEVICE as well)
zig build test-integration-dbus  # only the D-Bus part
zig build test-integration-a11y  # only AT-SPI against the real registry
zig build test-integration-portal  # only portals against xdg-desktop-portal
zig build test-integration-pdf  # only PDF output against qpdf and poppler
zig build test-integration-tray  # only the tray against dbus-daemon and gdbus
zig build test-integration-icons -Doptimize=ReleaseSafe  # installed Adwaita and Breeze drawn by siv
                               #   against rsvg-convert (SIV_ICON_DIFFS=DIR keeps the worst)
zig build test-dbus --fuzz -Doptimize=ReleaseSafe  # fuzz a module's parsers
zig build test-abi             # abi module, generators, Zig wrappers, exported symbols
zig build test-lua             # Lua binding against libsiv.so, siv.so from the stock lua,
                               #   annotations (also in `test`)
zig build test-integration-lua # only the Lua binding and siv-lua on sway
./zig-out/bin/siv-lua examples/todo.lua  # run a Lua example; --watch reloads it on edits
zig build test-notices         # NOTICES covers every shipped dependency (also in `test`)
zig build test-c               # C programs against the generated headers and shared libraries
zig build examples             # build and install the C programs in examples/
zig build test -Dtest-filter=bidi
zig build bench-text -Doptimize=ReleaseFast   # headless text engine benchmarks
zig build bench-render-cpu -Doptimize=ReleaseFast  # CPU renderer benchmarks
zig build bench-image -Doptimize=ReleaseFast -- FILE...  # image decoding benchmarks
zig build -fsys=harfbuzz -fsys=sheenbidi   # link system copies instead of vendored ones
zig build -fsys=glslang        # compile shaders with the system glslangValidator
zig build -fsys=lua            # link the system liblua5.5 into libsiv-lua
zig build -fsys=lcms2 -fsys=libwebp -fsys=libavif -fsys=dav1d -fsys=libjxl  # system image decoders
```

Fetched packages live in `zig-pkg/` (ignored). `zig build --fetch=all`
fetches everything, including lazy dependencies.

## Module ownership

Each directory under `src/` is a Zig module with its own tests. A workstream
owns its directories and does not edit another workstream's files.

| Module | Directory | Owner | May import |
| --- | --- | --- | --- |
| `abi` | `src/abi/` | ABI schema and code generation | every module below |
| `pool` | `src/pool/` | Rasterizer, display list, CPU renderer | none |
| `text` | `src/text/` | Text engine | `raster`, `harfbuzz`, `sheenbidi`, `fontconfig`, `uucode` |
| `raster` | `src/raster/` | Rasterizer, display list, CPU renderer | none |
| `scene` | `src/scene/` | Rasterizer, display list, CPU renderer | `raster` |
| `image` | `src/image/` | Image decoding | `scene`, `image_c` (wuffs, lcms2, libwebp, libavif, dav1d, libjxl) |
| `svg` | `src/svg/` | Icons and SVG | `scene`, `raster` |
| `icon` | `src/icon/` | Icons and SVG | none |
| `render_cpu` | `src/render/cpu/` | Rasterizer, display list, CPU renderer | `scene`, `raster`, `text`, `harfbuzz`, `pool`, `image` |
| `render_vulkan` | `src/render/vulkan/` | Vulkan renderer | `scene`, `raster`, `render_cpu`, `pool`, `vulkan`, `shaders` |
| `loop` | `src/loop/` | Event loop and Wayland platform | `pool` |
| `dbus` | `src/dbus/` | D-Bus and desktop settings | `loop` |
| `portal` | `src/portal/` | Desktop integration | `dbus`, `loop` |
| `tray` | `src/tray/` | Desktop integration | `dbus`, `loop` |
| `pdf` | `src/pdf/` | Desktop integration | `scene`, `raster`, `render_cpu`, `text`, `harfbuzz_subset` |
| `platform` | `src/platform/` | Event loop and Wayland platform | `loop`, `wayland`, `xkbcommon` |
| `compositor` | `src/compositor/` | Compositor thread | `scene`, `raster`, `render_cpu`, `render_vulkan`, `pool`, `loop`, `platform` |
| `ui` | `src/ui/` | UI core | `scene`, `svg`, `icon`, `raster`, `text`, `image`, `loop`, `platform`, `compositor` |
| `a11y` | `src/a11y/` | D-Bus and desktop settings (AT-SPI) | `dbus`, `ui`, `loop`, `raster`, `text` |
| `app` | `src/app/` | Public C API | `text`, `loop`, `platform`, `compositor`, `ui`, `dbus`, `a11y`, `portal` |
| `widgets` | `src/widgets/` | Theming and stock widgets | `siv` (the generated C API wrapper) only (D22) |
| `lua` | `src/lua/` | Lua binding | `siv` (the generated C API wrapper), `siv_schema` (`src/abi/api.zig` as data), `lua_c` (D23) |

The theming workstream also owns `src/ui/theme.zig` (D29). The icons
workstream owns `src/ui/icons.zig` and the test themes in
`test/icons/` (D19). Stock widgets
use only the public C API; when one needs more, add a public primitive.

Shared files have no single owner: `build.zig`, `build.zig.zon`,
`src/siv.zig`, `test/`, `.agents/`, and this file. Change them only when your
work cannot be done otherwise, keep the change minimal, and say so in the
commit message. In particular:

- **New import between modules:** add the edge in `build.zig` and the table
  above. Keep the graph acyclic and the direction low level to high level.
- **New dependency:** pin it in `build.zig.zon` with an exact URL and hash
  (`zig fetch <url>`). Only MIT, BSD, or Apache-2.0 code (D25). A C library
  gets a `-fsys=<name>` option to link the system copy, and is fetched lazily
  so that `-fsys` builds do not download it. Give it a licence entry in
  `src/notices/build_steps.zig` (D25); `zig build test` fails without one.
- **Owner-controlled build inputs** that need no `build.zig` edit:
  - `src/platform/protocols.zig`: Wayland protocol XML and global versions.
  - `src/text/uucode_config.zig`: Unicode properties compiled into tables.
  - `src/abi/gen.zig`: everything it writes to its install directory is
    installed under the prefix.
  - `src/abi/build_steps.zig`: the ABI part of the build graph (generated
    outputs, libsiv.so link setup, ABI tests).
  - `src/render/vulkan/build_steps.zig`: the Vulkan headers module, the
    glslang shader compiler, and the shader list (`shaders/*.glsl`).
  - `src/image/build_steps.zig`: the image decoders' C sources, generated
    headers, `-fsys` options, and NASM (built from source for dav1d).
  - `src/lua/build_steps.zig`: Lua's sources and allowlist of standard
    libraries, libsiv-lua, the siv-lua runner, the generated annotations,
    and the Lua tests (D23).

## Conventions

- Each module root ends with `test { std.testing.refAllDecls(@This()); }`.
  Tests in other files run only if the root references the file.
- Internal code uses plain indices; generation-checked handles exist only in
  `src/abi/` (D20).
- C headers are translated by the build (`addTranslateC`), not `@cImport`.
  The C modules are `harfbuzz`, `sheenbidi`, `fontconfig`, `xkbcommon`,
  `image_c` (the image decoders), and `vulkan` (headers only; libvulkan
  is loaded at run time).
- Unicode data files for tests are embedded by name:
  `@embedFile("LineBreakTest.txt")`. The list is in `build.zig`.
- Vendored C code is compiled with `-fvisibility=hidden`; libsiv.so exports
  only the `siv_` ABI. A generated version script enforces this, so
  libsiv.so links with LLVM and LLD (Zig's self-hosted ELF linker ignores
  version scripts); `test-abi` fails if any other symbol is exported.
- **Adding a C function:** describe it in `src/abi/api.zig` (conventions in
  `src/abi/schema.zig` and D2), then export it from `src/abi/` with the
  generated wrapper's types (`@import("siv")`), going through
  `src/abi/runtime.zig` for descriptors, strings, handles, and errors. The
  build fails if an export is missing or its signature differs from the
  schema. Subsystems expose plain Zig APIs with internal indices; only
  `src/abi/` knows about handles.
- Headless tests (test/headless.zig) may import every internal module; they
  run the real loop on the headless backend and compare CPU golden images
  (D24). Golden images go under `test/golden/<area>/`. The Vulkan renderer
  is diffed against the same images on any Vulkan 1.3 device (lavapipe in
  orbs) and skipped without one; validation errors fail the tests.
