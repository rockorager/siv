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
   resolved to auto and the file view shrank to its header (the sidebar to
   12 px). Nothing in the public API could make it fill: the pane's height
   is unknown to the application. *Fixed:* fraction heights resolve
   against a box's height when it is definite (commit "ui: resolve
   fraction heights against a box's definite height", D26).

3. **An editor inside a list row lost its keys to the row.** Renaming in
   place puts a text field in the item's row. Keys bubble from the focused
   node to the root *before* the editor's own handling, and the row's key
   handler took Space, arrows, Home, End, and Ctrl+A, so typing "my list"
   gave "my" and moved the selection. A handler cannot help: returning
   true both stops bubbling and cancels the editor's default handling, and
   a handler could not tell which node the key was aimed at. Releasing a
   press in the editor also activated the row (selecting it and stealing
   focus). *Fixed:* `siv_event.target` names the node an event was
   delivered to first; rows handle only keys aimed at themselves and
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

7. **Context menus could open only below a node.** A context menu belongs
   at the click, but `siv_menu_open` and popups anchored to a node's whole
   box. The app kept a 1×1 anchor node in a stack, moved it to the pointer
   with insets, and opened the menu from a zero-delay timer after the next
   layout, since a popup takes its anchor's place from the last layout.
   *Fixed:* `siv_popup_desc.anchor_rect` with `SIV_POPUP_AT_RECT`, and
   `siv_menu_open_at(menu, node, x, y)` (commit "abi, widgets: open popups
   and menus at a point of a node", D17).

8. **Every thread of the host process carried 256 KiB of libsiv's
   thread-local storage.** The file manager's inotify thread, started with
   a 512 KiB stack, failed with EINVAL in the real binary (linked to
   libsiv.so) though not in the tests (linked statically). libsiv.so had a
   256 KiB TLS segment: Zig's per-thread alternative signal stack, which a
   library with no crash handler never uses, and which glibc reserves in
   every thread of the process, including the host's. *Fixed:* libsiv sets
   `std_options.signal_stack_size = null`, and the export check fails the
   build above 4 KiB of TLS (commit "abi: keep libsiv's thread-local
   storage small", D2). Programs built with Zig still carry Zig's own 256
   KiB unless they do the same (the app does not need to).

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
    interception is gone; a test drags two selected files out and gets
    both URIs.

11. **No way to watch a file descriptor.** inotify for the shown folder
    needs a descriptor in the event loop, but the public loop takes none:
    `siv_app_fd` embeds siv in another loop, not the reverse. The app runs
    a thread blocked in poll(2) that `siv_post`s changes
    (`src/Watcher.zig`). A `siv_app_watch_fd(app, fd, events, callback)`
    would remove the thread and the cross-thread lifetime handling.
    *Fixed:* `siv_app_watch_fd` watches it in siv's loop and calls back at
    a safe point; `siv_watch_destroy` stops (commit "abi: watch
    application file descriptors in the loop", D6). `src/Watcher.zig` lost
    its thread, eventfd, atomics, and post lifetime handling (119 to 72
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
    notes JPEG DCT scaling is not done yet), so a 12-megapixel photo costs
    ~50 MB and tens of ms per thumbnail.
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
    *Fixed:* `SIV_WINDOW_EVENT_TYPE_PRESENTED` with the commit count shown, the
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

22. **Menu items are reached by walking the menu's children.** Setting a
    check mark or disabling an item needs its node; the builder returns
    it, but an application that builds menus from tables keeps an index
    and walks `siv_node_get_related` to find it again (`menuItem` in
    `src/Files.zig`). A `siv_menu_get_item(menu, index)`, like
    `siv_view_get_row`, would do.
    *Fixed:* `siv_menu_get_item(menu, index, item)`, by the position
    `select` reports (commit "widgets: find a menu item by its position",
    D22). The app's child walk is a one-line call.

20. **Icons.** DESIGN.md (D19) said icons follow the freedesktop icon
    theme specification and render through siv's SVG parser, but neither
    existed: the app drew its icons on canvases with paths in theme
    colors, so every application would redraw the folder icon. *Fixed:*
    image nodes show a themed icon by name (`siv_image_view_desc.icon`),
    looked up in the desktop's icon theme and loaded on the worker pool
    (commits "svg, icon: ...", "ui: vector images, and themed icons in
    image nodes", "abi: icons through the C API", D19). Rows, grid cells,
    and places name their icons (`src/icons.zig`: `folder`,
    `text-x-generic`, `user-home`, with fallbacks); the app's own SVGs in
    `apps/files/icons` (its former canvas drawings, recolored by the
    theme through KDE's color scheme classes) fill in names a theme
    lacks and are all the tests see.

21. **Push buttons took a label only.** Back, Forward, Up, and the view
    toggle were text buttons; an icon button would have needed a custom
    canvas widget. *Fixed:* buttons take an icon, alone with the label as
    the accessible name (`SIV_WIDGET_ICON_ONLY`), and
    `siv_widget_set_icon` changes it with the view toggle's label
    (commit "widgets: icons in push, toggle, and menu buttons and menu
    items", D22).

24. **A descriptor cannot end in one 4-byte field.** Descriptors have no
    padding (D2), so appending a single `uint32_t` or enum to one whose
    size is a multiple of 8 fails the build ("trailing padding; append a
    field"). The image load priority became an `int64_t` for that reason;
    `siv_text_style_desc` took `max_lines` and `direction` together.
    Should the rule allow trailing padding that must be zero, or should
    descriptors reserve a field when they end 4 bytes short?
    *Fixed:* the no-padding rule stays (C does not zero an automatic
    struct's padding); schema fields can be reserved instead: zero,
    rejected as unsupported otherwise, so a later version can use them
    (commit "abi: reserved descriptor fields, and open or closed enums",
    D2). The image priority is an `int32_t` again, followed by
    `reserved0`; Lua tables leave reserved fields out.

25. **`siv_key` is the first open enum.** D2 says unknown enum values are
    `SIV_ERROR_UNSUPPORTED`; keysyms are an open set, so `siv_key` names
    the common keys and every other value passes through (Lua gets a name
    or a number). Nothing checks keysyms today, but the schema has no way
    to say an enum is open, and a generator for another language might map
    it to a closed type. Should the schema mark open enums?
    *Fixed:* the schema marks enums open or closed (same commit, D2).
    Closed enums reject unknown values; `siv_key` is open and passes them.
    The header, Zig wrapper, JSON, reference, Lua binding (closed enums
    take only named integers), and Lua annotations follow the mark.

31. **Nowhere to keep the window's size or the view mode.** Every run
    opened at 1000×640 in list view with hidden files hidden, whatever
    the user chose last time: siv had no settings or state storage, and
    session restore (D17) depends on the compositor (sway has none).
    The app would have had to write and watch a file of its own.
    *Fixed:* settings and state stores (commit "abi: settings and state
    stores", D36). The app opens `state.toml` in
    `$XDG_STATE_HOME/org.siv.Files/`, gives the window
    `siv_window_desc.settings` (its size and maximized and fullscreen
    states), and saves `view.mode` and `view.show-hidden` when they
    change; `--grid` and `--hidden` win for one run.

32. **A narrow window had no room for the places.** On a tiling
    compositor the window is often a third of the screen; the sidebar
    kept its 190 px, and the search field pushed the menu button off the
    toolbar. A resize handler that rebuilt the tree would have shown one
    frame at the old arrangement and thrown away the views' state.
    *Fixed:* variants (commit "abi: add variants that change a node by
    the space it gets", D39). Below 600 px the split pane's start pane
    and divider are hidden and the search field is 140 px wide, in the
    frame of the resize; `tests/golden/narrow.png`.

## Open API questions

33. **A split pane names no divider part.** Hiding the start pane
    leaves its divider, so the app reaches the divider with
    `siv_node_get_related(start, next)`, which depends on how the stock
    widget builds itself. A `divider` part, or a pane that collapses its
    divider with it, belongs to the navigation widgets (D40), which give
    sidebars a collapsed state of their own; the app moves to that.

34. **Delete could not be undone, and the trash was the app's own.**
    Delete moved files to `$XDG_DATA_HOME/Trash` with code of the app's
    (only the home trash, so a file on another disk crossed file systems
    by copying), and nothing took it back: siv had an undo stack (D35)
    and toasts with an action button, but no way to restore a trashed
    file, so the app used neither. Inside Flatpak only the Trash portal
    can trash, and it cannot restore either.
    *Fixed:* the trash (commit "abi: the trash and system signals",
    D42). Delete and dropping on Trash call `siv_trash_file` per file;
    when every result is in, the files trashed become one step on the
    window's undo stack (`siv_undo_create`, attached to the root with
    `siv_set_undo`, so Ctrl+Z and Ctrl+Shift+Z work), whose undo calls
    `siv_trash_restore` with each id and whose redo trashes them again.
    The toast says what moved and its Undo button undoes the step while
    it is the newest; restored files are selected. A file the trash
    cannot take says why (`unsupported` suggests Shift+Delete). The
    app's trash code is gone. Deleting inside the trash folder still
    deletes files for good with the app's own code, which leaves their
    information files behind; `siv_trash_delete` would not.

## Noted

23. **Fields must precede declarations in a Zig struct** (Zig 0.17), so an
    application's state struct cannot keep a field next to the functions
    that use it. Not siv's, but every Zig program meets it.

27. **Changing a callback's return type moves every handler.** Splitting
    the handler result (item 9) touched about 150 handlers in the stock
    widgets, the tests, the C examples, and the app. In C it stays a
    one-line change per handler, and `return true` still means handled,
    which is why the result is an enum and not two flag bits.

28. **The cut copy of ellipsized text is what AT-SPI measures.** The
    accessible name and text are whole, but character extents come from
    the layout on screen, so characters past the ellipsis have none.
    Screen readers read the name; a magnifier following the caret has no
    caret in a label. Fine for labels; revisit if editors ever ellipsize.

29. **`siv_view_set_cursor` overlaps the widget value.** A view's value
    (`siv_widget_set_value`) was already its cursor; the named calls are
    clearer and also move the Shift anchor, but there are two ways now.
    *Fixed:* views have no widget value, and `siv_node_focus` on a view
    focuses its cursor row, so `siv_view_focus` is gone too (commit
    "widgets: one way to move a view's cursor, focus it, and size its
    columns", D22, D30). The app calls `siv_node_focus`.

30. **Asynchronous Lua calls with out values.** The Lua mapping rejected
    asynchronous functions with out parameters; `siv_image_load` now has
    one (its request). The rule is relaxed: given a callback the call
    returns its out values, and waiting in a coroutine drops them.

31. **Shortcuts, menu labels, and check marks were kept in step by hand.**
    The app menu listed "Ctrl+H" beside Show Hidden Files, the window's key
    handler bound Ctrl+H separately, and every state change walked the
    menu to set check marks. *Fixed:* window actions (D34): New Folder,
    Show Hidden Files (a toggle), the view and the style (choices), and
    Close carry their keys; the menu items bound to them take labels,
    shortcuts, and check marks from them, and the app sets an action's
    value when its state changes. Those keys now also work in the search
    and location fields, which do not use them. The context menu stays as
    it was: its keys act on the selection and must stay the editors' in
    the rename field, which a focused editor's first refusal (D34) only
    gives for keys the editor handles.

## Numbers

`zig build bench-files -Doptimize=ReleaseFast` on this orb (x86-64,
headless backend, CPU renderer), October 2026. Frame times come from the
app's `SIV_WINDOW_EVENT_TYPE_PRESENTED` events (commit time of the first
presented frame, and of the first presented after the listing arrived);
the first round read siv's internals and waited for the window to settle.

| What | Result | First round |
| --- | --- | --- |
| Startup, 40 entries: first frame | 12.6 ms | 12 ms |
| Startup, 40 entries: first frame with the rows | 12.6 ms (the listing beats the first frame; UI thread CPU 3.4 ms) | 53 ms to settled (5.4 ms CPU) |
| Resident memory with the window open | 25.1 MiB | 25 MiB |
| Idle for 2 s | 2 context switches across 7 threads, one of them the bench's own timeout | same |
| 100 000 entries: first frame | 12.8 ms | — |
| 100 000 entries: read and sorted on the blocking lane | 221 ms | 205–250 ms |
| 100 000 entries: rows shown | 227 ms | 223–273 ms |
| Memory for 100 000 entries listed | +23.8 MiB | +25 MiB |
| Scrolling 300 wheel steps of 450 px | 0.69 ms UI thread CPU per step on average, 3.6 ms worst (8.3 ms is a 120 Hz frame) | 0.6 ms, 2.7 ms worst |
| End, then Home | 0.21 ms | 0.9 ms |
| Ctrl+A over 100 000 entries | 1.4 ms | 1.8 ms (805 ms before the bitset calls) |
| Sort by size keeping the selection | 60 ms | 60 ms |
| Search as you type ("file-99") | 7.1 ms | 9.5 ms |
