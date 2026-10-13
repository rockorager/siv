# siv-files

A file manager written against siv's public API only (the generated
`siv` Zig wrapper of the C ABI), to find where that API hurts. What it
found is in [FRICTION.md](FRICTION.md).

```sh
zig build files && ./zig-out/bin/siv-files [FOLDER] [--grid] [--hidden] [--dark|--light] [--rtl] [--no-thumbnails]
zig build test-files              # headless tests with golden images (in `zig build test`)
zig build test-integration-files  # headless sway, real input, AT-SPI (in `zig build test-integration`)
zig build bench-files -Doptimize=ReleaseFast   # startup, memory, idle, 100 000 entries
```

Places sidebar (home, XDG user folders, GTK bookmarks, trash, root);
breadcrumbs and a location field (Ctrl+L); search as you type; a
virtualized table with sortable, resizable columns, or a grid with image
thumbnails decoded off the UI thread; multiple selection by keyboard and
pointer; rename in place (F2); new folder (Ctrl+Shift+N); copy, cut, and
paste (Ctrl+C, Ctrl+X, Ctrl+V) and drag and drop with other applications
as text/uri-list; move to trash (Delete) and delete (Shift+Delete, after
asking); copies and moves on siv's worker pool with progress and
cancellation; open with the default application through the OpenURI
portal (Enter, double click) or choose one (Open With…); a context menu
(right click, Menu, Shift+F10); light and dark styles; right-to-left
layout; and a screen reader's view of all of it through AT-SPI.

Keys: Alt+Left/Right/Up and Backspace navigate, Alt+Home goes home,
Ctrl+H shows hidden files, Ctrl+1 and Ctrl+2 switch views, F5 reloads,
Escape clears the selection or the search, Ctrl+W closes.
