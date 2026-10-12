# siv

A high-performance GUI toolkit for Linux, written in Zig with a stable C ABI.
Wayland only.

The name comes from Coheed and Cambria's *Good Apollo, I'm Burning Star IV*.

siv is in the design stage. See [DESIGN.md](DESIGN.md) for the decisions so far.

## Building

Requires Zig 0.16.0 and the development packages for libwayland-client,
xkbcommon, and Fontconfig.

```sh
zig build        # libsiv.so, libsiv.a, include/siv.h, siv.pc in zig-out/
zig build test
```

See [AGENTS.md](AGENTS.md) for the module layout and contribution rules.

## License

MIT
