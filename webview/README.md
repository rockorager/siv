# siv-webview

A web view for [siv](https://github.com/rockorager/siv), the way WebKitGTK
sits beside GTK: a separate library built only on siv's public C ABI,
with its own C header, Zig module, and Lua module. The engine is WPE
WebKit through its platform API (WPEPlatform, 2.50 or later): WebKit
renders in its own processes and hands finished frames to siv as
dma-bufs, which siv puts on a subsurface without a copy.

```c
siv_webview wv;
siv_webview_create(window, SIV_DESC(siv_webview_desc, .on_event = on_event), &wv);
siv_txn txn;
siv_txn_begin(window, &txn);
siv_node page = siv_webview_view(txn, root, wv);
siv_set_layout(txn, page, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .grow = 1));
siv_txn_commit(txn);
siv_webview_load_uri(wv, SIV_STR("https://example.com"));
```

```lua
local webview = require("siv.webview")
local wv = webview.create(win, { on = { title = function(_, ev) win:set_title(ev.text) end } })
win:update(function(txn, root) wv:view(txn, root) end)
wv:load_uri("https://example.com")
```

It covers loading URLs and HTML, history, title/URL/progress/load
events, JavaScript with results, messages both ways (`window.siv`),
custom URI schemes (`app://`), navigation and new-window policy,
per-application data directories and ephemeral views, the remote
inspector, zoom, dark mode, `<select>` and context menus as siv
popups, file inputs through the portal, clipboard, text and URL drops,
downloads, permissions, notifications, input methods, accessibility,
and fractional scale.

## Building

Needs an installed siv (`zig build` in siv makes `zig-out`), WPE WebKit
2.50+ with WPEPlatform, GBM, EGL, and GLib (Arch: `wpewebkit`; media
needs the GStreamer plugins).

```sh
zig build -Dsiv=/path/to/siv/zig-out    # or siv from pkg-config
zig build test -Dsiv=...                 # headless: no compositor or GPU
./zig-out/bin/siv-webview-browser https://example.com
./zig-out/bin/siv-webview-lua examples/browser.lua
```

`NOTES.md` has the design notes and measurements; `spike/` and `bench/`
the phase-1 spike and the latency harness.
