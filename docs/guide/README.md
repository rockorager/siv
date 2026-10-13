# The siv guide

siv is a GUI toolkit for Linux and Wayland, written in Zig, with a stable
C ABI. This guide teaches you to build applications with it, in C, Zig, or
Lua. It assumes you know your language and have written a GUI before; it
does not assume you know siv.

The reference documentation lists every function and type: after `zig
build`, it is in `zig-out/share/doc/siv/siv.md`, and the Lua annotations
for your editor are in `zig-out/share/siv/lua/siv.lua`. This guide explains
how the pieces fit together and what to reach for. [DESIGN.md](../../DESIGN.md)
records why siv is built the way it is; the guide points to its decisions
(D1 to D29) where the reasons matter.

1. [Getting started](01-getting-started.md): installing siv, building
   against it from C, Zig, and Lua, and a first window.
2. [How siv works](02-model.md): the application, windows, the retained
   tree, transactions, callbacks at safe points, and the compositor thread.
3. [Layout and text](03-layout-and-text.md)
4. [Stock widgets and theming](04-widgets-and-theming.md)
5. [Events and focus](05-events-and-focus.md)
6. [Custom widgets](06-custom-widgets.md): from primitives and on a canvas.
7. [Images and icons](07-images-and-icons.md)
8. [Lists, tables, and trees](08-lists-and-tables.md)
9. [Work off the UI thread](09-async.md): jobs, image loads, portals, and
   coroutines in Lua.
10. [Clipboard and drag and drop](10-clipboard-and-dnd.md)
11. [Accessibility](11-accessibility.md)
12. [Embedding siv in another event loop](12-embedding.md)
13. [External surfaces and video](13-external-content.md)
14. [Printing and PDF](14-printing.md)
15. [Packaging](15-packaging.md): desktop files, D-Bus activation, and
    Flatpak.
16. [Performance](16-performance.md)

## The samples

Every program in this guide is a file in [examples/](examples/), and every
code block is quoted from one of them. `zig build guide` builds them all as
programs (installed as `zig-out/bin/guide-*`), then runs each one on siv's
headless backend, drives it like a user, and compares its window with the
screenshot the guide shows. `zig build test` does the same, so the samples
and screenshots cannot drift from the library. Lua samples run with the
`siv-lua` runner:

```sh
zig build guide
./zig-out/bin/guide-hello
./zig-out/bin/siv-lua docs/guide/examples/hello.lua
```

Run them from the repository root: some read files under
`docs/guide/examples/data`. The screenshots use the test fonts (Droid Sans)
and test icons, so they look plainer than your desktop will.

The C samples are the most complete, since C is the ABI. The Zig and Lua
bindings are generated from the same schema, so everything in C carries
over by a fixed rule ([Getting started](01-getting-started.md#one-api-three-languages)
gives it); the guide shows Zig and Lua where they differ in more than
spelling.
