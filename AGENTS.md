# Working on siv

DESIGN.md is the source of truth. Read it before changing behavior, and
update it in the same change when a decision changes.

## Build and test

Requires Zig 0.17.0 and the development packages for libwayland-client,
xkbcommon, and Fontconfig (`.agents/setup` installs them on Debian).

```sh
zig build                      # zig-out: libsiv.so, libsiv.a, include/siv.h, lib/pkgconfig/siv.pc
zig build test                 # every module's tests, headless tests, C ABI smoke test
zig build test-text            # one module: test-abi, test-text, test-raster, test-scene,
                               #   test-render-cpu, test-pool, test-loop, test-platform
zig build test-headless        # headless integration tests (test/headless.zig)
zig build test-abi             # abi module, generators, Zig wrappers, exported symbols
zig build test-c               # C programs against the generated headers and shared libraries
zig build test -Dtest-filter=bidi
zig build bench-text -Doptimize=ReleaseFast   # headless text engine benchmarks
zig build bench-render-cpu -Doptimize=ReleaseFast  # CPU renderer benchmarks
zig build -fsys=harfbuzz -fsys=sheenbidi   # link system copies instead of vendored ones
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
| `render_cpu` | `src/render/cpu/` | Rasterizer, display list, CPU renderer | `scene`, `raster`, `text`, `harfbuzz`, `pool` |
| `loop` | `src/loop/` | Event loop and Wayland platform | `pool` |
| `platform` | `src/platform/` | Event loop and Wayland platform | `loop`, `wayland`, `xkbcommon` |

Shared files have no single owner: `build.zig`, `build.zig.zon`,
`src/siv.zig`, `test/`, `.agents/`, and this file. Change them only when your
work cannot be done otherwise, keep the change minimal, and say so in the
commit message. In particular:

- **New import between modules:** add the edge in `build.zig` and the table
  above. Keep the graph acyclic and the direction low level to high level.
- **New dependency:** pin it in `build.zig.zon` with an exact URL and hash
  (`zig fetch <url>`). Only MIT, BSD, or Apache-2.0 code (D25). A C library
  gets a `-fsys=<name>` option to link the system copy, and is fetched lazily
  so that `-fsys` builds do not download it.
- **Owner-controlled build inputs** that need no `build.zig` edit:
  - `src/platform/protocols.zig`: Wayland protocol XML and global versions.
  - `src/text/uucode_config.zig`: Unicode properties compiled into tables.
  - `src/abi/gen.zig`: everything it writes to its install directory is
    installed under the prefix.
  - `src/abi/build_steps.zig`: the ABI part of the build graph (generated
    outputs, libsiv.so link setup, ABI tests).

## Conventions

- Each module root ends with `test { std.testing.refAllDecls(@This()); }`.
  Tests in other files run only if the root references the file.
- Internal code uses plain indices; generation-checked handles exist only in
  `src/abi/` (D20).
- C headers are translated by the build (`addTranslateC`), not `@cImport`.
  The C modules are `harfbuzz`, `sheenbidi`, `fontconfig`, and `xkbcommon`.
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
  (D24). Golden images go under `test/golden/<area>/`.
