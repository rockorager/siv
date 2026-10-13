# siv

A high-performance GUI toolkit for Linux, written in Zig with a stable C ABI.
Wayland only.

The name comes from Coheed and Cambria's *Good Apollo, I'm Burning Star IV*.

siv is in the design stage. See [DESIGN.md](DESIGN.md) for the decisions so far.

## Building

Requires Zig 0.17.0 and the development packages for libwayland-client,
xkbcommon, and Fontconfig.

```sh
zig build          # libsiv.so, libsiv.a, include/siv.h, siv.pc in zig-out/
zig build test
zig build examples # C programs from examples/ in zig-out/bin/
./zig-out/bin/siv-lua examples/todo.lua  # Lua 5.5 through libsiv-lua
LUA_CPATH='zig-out/lib/lua/5.5/?.so' lua5.5 -e 'require("siv")'  # or your own Lua 5.5
```

To write an application with siv, start with the [guide](docs/guide/README.md),
in C, Zig, and Lua; `zig build guide` builds and checks its samples.

The C API reference is generated into `zig-out/share/doc/siv/siv.md`, and
annotations of the Lua API for lua-language-server into
`zig-out/share/siv/lua/siv.lua`.

See [AGENTS.md](AGENTS.md) for the module layout and contribution rules.

## License

MIT
