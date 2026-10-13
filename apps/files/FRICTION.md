# Friction log: building a file manager on siv's public API

`apps/files` is written in Zig against the generated `siv` wrapper only,
so it meets exactly what C and other bindings meet. This log records every
place where the API was awkward, missing, slow, or surprising, in the
order found. Each entry says what happened, what the app does about it,
and its status:

- **Fixed** — siv changed in a labeled commit, with DESIGN.md updated.
- **Open** — a larger API question left for a decision; the app works
  around it.
- **Noted** — minor, or a gap DESIGN.md already lists.

Measurements are in [Numbers](#numbers) at the end.

## Fixed in siv

1. **No way to run blocking work on siv's worker pool.** Reading a folder
   of 100 000 entries (getdents and a statx per entry, then a natural
   sort: 200–250 ms) and copying files must not run on the UI thread, but
   the pool (D6) was internal: only image decoding used it. An application
   would start threads of its own and oversubscribe the CPU against siv's
   decoders and tile rendering. *Fixed:* `siv_job_start(app, work, done,
   destroy, user_data)` (commit "abi: run application jobs on the worker
   pool", D6).

2. **A list in a split pane could not fill the pane.** Split panes are
   boxes; a box offered its children no height, so `height = fraction 1`
   resolved to auto and the file view shrank to its header (the sidebar
   to 12 px). Nothing in the public API could make it fill: the pane's
   height is unknown to the application. *Fixed:* fraction heights
   resolve against a box's height when it is definite (commit "ui:
   resolve fraction heights against a box's definite height", D26).

3. **An editor inside a list row lost its keys to the row.** Renaming in
   place puts a text field in the item's row. Keys bubble from the focused
   node to the root *before* the editor's own handling, and the row's key
   handler took Space, arrows, Home, End, and Ctrl+A, so typing "my list"
   gave "my" and moved the selection. A handler cannot help: returning
   true both stops bubbling and cancels the editor's default handling,
   and a handler could not tell which node the key was aimed at. Releasing
   a press in the editor also activated the row (selecting it and
   stealing focus). *Fixed:* `siv_event.target` names the node an event
   was delivered to first; rows handle only keys aimed at themselves and
   ignore presses in an editor; a press in an editor activates no ancestor
   (commit "abi, widgets: leave keys and presses in a row's editor to the
   editor", D16, D22).

4. **Table rows had no accessible name.** A focused row of the file table
   was announced as nothing: rows were not named from their content, only
   cells and list items were. *Fixed:* rows are named from their content
   as ARIA 1.2 does (commit "ui: name table rows from their content",
   D18). The app gives its cells role `cell` with their column index, so
   AT-SPI clients see four cells per row with `colindex`, and the header
   cells' `sort`.

5. **Only editors could reach the clipboard.** Copy and cut of files need
   text/uri-list and x-special/gnome-copied-files (which says whether a
   paste moves), and paste needs to read those types from other
   applications. There was no clipboard call at all; while this work was
   under way, `siv_clipboard_write` and `siv_clipboard_read` landed for
   text (with the Lua binding). *Fixed:* `siv_clipboard_write_data(window,
   selection, desc)` offers MIME types and data split by lengths (like
   `siv_drag_start`); `siv_clipboard_read_data(window, selection, mimes,
   callback, ...)` reads the first type offered as raw bytes (commit "abi:
   offer and read the clipboard in any MIME type", D19).

6. **Selecting many items was quadratic.** A view's selection could be
   read and set only one item per call, and every `siv_view_set_selected`
   restyled every row. Ctrl+A over 100 000 entries took 0.8 s; keeping the
   selection across a new sort order (read every bit, re-sort, clear, set
   the new positions) took 1.5 s. *Fixed:* `siv_view_get_selection` and
   `siv_view_set_selection` copy and replace the bitset the view keeps;
   setting one item restyles only its row (commit "widgets: read and
   replace a view's selection as a bitset", D22). Now 1.8 ms and 60 ms.

7. **Context menus could open only below a node.** A context menu
   belongs at the click, but `siv_menu_open` and popups anchored to a
   node's whole box. The app kept a 1×1 anchor node in a stack, moved it
   to the pointer with insets, and opened the menu from a zero-delay
   timer after the next layout, since a popup takes its anchor's place
   from the last layout. *Fixed:* `siv_popup_desc.anchor_rect` with
   `SIV_POPUP_AT_RECT`, and `siv_menu_open_at(menu, node, x, y)` (commit
   "abi, widgets: open popups and menus at a point of a node", D17).

8. **Every thread of the host process carried 256 KiB of libsiv's
   thread-local storage.** The file manager's inotify thread, started with
   a 512 KiB stack, failed with EINVAL in the real binary (linked to
   libsiv.so) though not in the tests (linked statically). libsiv.so had a
   256 KiB TLS segment: Zig's per-thread alternative signal stack, which a
   library with no crash handler never uses, and which glibc reserves in
   every thread of the process, including the host's. *Fixed:* libsiv sets
   `std_options.signal_stack_size = null`, and the export check fails the
   build above 4 KiB of TLS (commit "abi: keep libsiv's thread-local
   storage small", D2). Programs built with Zig still carry Zig's own
   256 KiB unless they do the same (the app does not need to).

9. **One return value means both "stop bubbling" and "skip the default
   action".** The DOM separates `stopPropagation` from `preventDefault`;
   siv's `bool` return conflates them. The app's window-wide shortcut
   handler (on the root) sees every key typed into the search field, the
   location field, and the rename field; Backspace there must stay the
   editor's, not "go up". With `target` (item 3) a handler can tell, but
   only if it knows which nodes are editors: the app tracks focus on each
   of its editors (`editing`). Should handlers be able to stop bubbling
   without cancelling the default action? Should siv expose the focused
   node (`siv_window_get_focus`) and whether a node is an editor?
   *Fixed:* handlers return `siv_event_result`: `stop`, `prevent`,
   `handled` (both), or `pass`, and `siv_window_get_focus` names the
   focused node (commit "abi, ui: separate stopping bubbling from
   preventing the default", D16). The app asks for the focus instead of
   tracking it on each editor, and the rename field returns `stop` for the
   keys it leaves to the editor, so neither the row nor the window's
   shortcuts see them while the editor still types them.

10. **A press on a selected item collapses a multiple selection at once.**
   File managers keep the selection on press so that a drag carries all
   of it, and collapse it on release without a drag. The stock view
   selects on press; the app intercepts presses on already selected items
   (returning true, which also skips focusing) and selects on release
   itself. Should views defer the collapse to the release when the item
   is selected?
   *Fixed:* views keep the selection on such a press and collapse it on
   release unless a drag started (commit "widgets: keep a selection on
   press, say what changed, expose the cursor", D22). The app's
   interception is gone; a test drags two selected files out and gets both
   URIs.

17. **Selection changes do not say what changed.** `select` reports the
    cursor and the count; the status line needs the selected items' total
    size, so the app reads the whole bitset on every change (cheap now,
    item 6).
   *Fixed:* `select` names a range of rows that holds every changed item
   (`changed_index`, `changed_count`; same commit). The app keeps a copy
   of the bitset with the count and total size, and on each event reads
   the bitset only up to the range's end and adjusts the totals for the
   bits that differ.

18. **Views expose neither their rows nor a way to focus the cursor.**
    Opening the context menu with the keyboard (Menu, Shift+F10) at the
    cursor's row means walking the view's subtree for the row whose node
    data the app set; focusing the view means a depth-first search for its
    one focusable row, since `siv_node_focus` on the view itself fails.
   *Fixed:* `siv_view_get_cursor`, `siv_view_set_cursor`,
   `siv_view_focus`, and `siv_view_get_row` (same commit). The subtree
   walk and the depth-first focus search are gone.

19. **Keysyms are not in siv.h.** Every program writes out XKB keysym
    numbers (`apps/files/src/keys.zig`; src/widgets has its own table).
   *Fixed:* `siv_key` names them in the schema: `SIV_KEY_ESCAPE` in C,
   `.escape` in Zig, `"escape"` in Lua (commit "abi: name keysyms in the
   schema as siv_key", D16). `src/keys.zig` is gone.

11. **No way to watch a file descriptor.** inotify for the shown folder
    needs a descriptor in the event loop, but the public loop takes none:
    `siv_app_fd` embeds siv in another loop, not the reverse. The app runs
    a thread blocked in poll(2) that `siv_post`s changes
    (`src/Watcher.zig`). A `siv_app_watch_fd(app, fd, events, callback)`
    would remove the thread and the cross-thread lifetime handling.
    *Fixed:* `siv_app_watch_fd` watches it in siv's loop and calls back at
    a safe point; `siv_watch_destroy` stops (commit "abi: watch
    application file descriptors in the loop", D6). `src/Watcher.zig` lost
    its thread, eventfd, atomics, and post lifetime handling (119 to 70
    lines). Writing the test for it found a bug of the app's own: re-
    adding the watch after every reload reported IN_IGNORED, which
    reloaded again; it now keeps the watch of an unchanged folder and
    ignores IN_IGNORED.

12. **Long jobs share the pool with decoding and rendering.** A copy of a
    large tree occupies a worker for its whole length; several copies at
    once leave thumbnails queued behind them, and fork-join rendering
    falls back to the compositor thread alone. Blocking I/O may want a
    lane of its own, or a cap on how many workers jobs take.
    *Fixed:* the pool has a blocking lane of its own (up to 8 threads that
    never take compute work), and fork-join helpers jump the compute
    queue; `siv_job_start` takes `siv_job_flags`, blocking by default,
    `SIV_JOB_COMPUTE` for CPU work (commit "pool, abi: a blocking lane,
    and prioritized, cancellable image loads", D6). The app's folder
    listings and file operations are blocking jobs.

13. **Image loads cannot be cancelled or prioritised.** The grid asks for
    thumbnails of the cells it binds; scrolling quickly past thousands of
    images would decode all of them. The app keeps its own queue (newest
    first, three in flight, older requests dropped) and reads the
    freedesktop thumbnail cache first (`src/Thumbs.zig`). Each decode
    reads and decodes the whole file at full size before scaling (D19
    notes JPEG DCT scaling is not done yet), so a 12-megapixel photo
    costs ~50 MB and tens of ms per thumbnail.
    *Fixed:* `siv_image_load` returns a `siv_image_request` and takes a
    priority; `siv_image_request_cancel` and
    `siv_image_request_set_priority` (same commit, D19). `src/Thumbs.zig`
    dropped its own stack and in-flight cap: every request goes to siv at
    once with a growing priority, asking again raises it, and past 256
    waiting the oldest is cancelled. A test asks for 300 and sees 256
    decoded. Decoding at full size before scaling remains (D19 lists JPEG
    DCT scaling as not done).

14. **No frame-presented event.** Measuring startup to first frame, or
    knowing that a change reached the screen, is impossible from the
    public API: windows report close, resize, scale, and states only. The
    benchmark and tests read siv's internals (`presented_seq`).
    *Fixed:* `SIV_WINDOW_EVENT_PRESENTED` with the commit count shown, the
    predicted presentation time, and the commit time (commit "abi, app:
    report presented frames to applications", D12). The app records its
    first frame and its first frame with rows from it, and the benchmark
    reads those instead of `presented_seq`.

15. **No text truncation.** Long file names need an ellipsis (one line in
    the table, two in the grid). Text nodes wrap or not, nothing else; the
    app clips the cell, which cuts names mid-glyph with no indication.
    `siv_text_flags` could grow `ellipsize` and a line limit.
    *Fixed:* `SIV_TEXT_ELLIPSIZE` and `siv_text_style_desc.max_lines`
    (commit "ui, abi: ellipses, line clamps, and a text direction of its
    own", D13). Table cells and one-line labels end in "…", grid names
    take two lines at most; the accessible names stay whole. The goldens
    show a long name in the list and in the grid.

16. **Formatted numbers in right-to-left layouts need marks.** A date
    "2026-10-13 14:05" in an RTL table shows its two runs of digits
    swapped, because a paragraph's base direction comes from its first
    strong character and digits have none (D21). The app prefixes U+200E;
    that mark then appears in accessible names (AT-SPI clients see
    "\u200e2026-10-13"). A per-text base direction separate from the
    layout direction (which also flips alignment) would be cleaner.
    *Fixed:* `siv_text_style_desc.direction` sets a text's base direction
    apart from its layout direction (same commit, D21). The Modified
    column is left to right of its own; the mark is gone from the text and
    from what AT-SPI reads (the sway test checks row names without it).

## Open API questions

## Noted

20. **Icons.** DESIGN.md (D19) says icons follow the freedesktop icon
    theme specification and render through siv's SVG parser, but neither
    exists yet: there is no way to load a themed icon by name. The app
    draws its icons on canvases with paths in theme colors
    (`src/icons.zig`), which keeps them sharp and themed but means every
    application redraws the folder icon.

21. **Push buttons take a label only.** Back, Forward, Up, and the view
    toggle are text buttons; an icon button would need a custom canvas
    widget with its own focus, press, and activate handling.

22. **Menu items are reached by walking the menu's children.** Setting a
    check mark or disabling an item needs its node; the builder returns
    it, but an application that builds menus from tables keeps an index
    and walks `siv_node_get_related` to find it again.

23. **Fields must precede declarations in a Zig struct** (Zig 0.17), so an
    application's state struct cannot keep a field next to the functions
    that use it. Not siv's, but every Zig program meets it.

## Numbers

`zig build bench-files -Doptimize=ReleaseFast` on this orb (x86-64,
headless backend, CPU renderer), October 2026:

| What | Result |
| --- | --- |
| Startup, 40 entries: first frame | 12 ms |
| Startup, 40 entries: first frame with the rows | 53 ms (UI thread CPU 5.4 ms) |
| Resident memory with the window open | 25 MiB |
| Idle for 2 s | 2 context switches across 7 threads, one of them the bench's own timeout |
| 100 000 entries: read and sorted on the pool | 205–250 ms |
| 100 000 entries: rows shown | 223–273 ms |
| Memory for 100 000 entries listed | +25 MiB |
| Scrolling 300 wheel steps of 450 px | 0.6 ms UI thread CPU per step on average, 2.7 ms worst (8.3 ms is a 120 Hz frame) |
| End, then Home | 0.9 ms |
| Ctrl+A over 100 000 entries | 1.8 ms (was 805 ms) |
| Sort by size keeping the selection | 60 ms (was 1563 ms) |
| Search as you type ("file-99") | 9.5 ms |
