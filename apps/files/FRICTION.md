# Friction log: building a file manager on siv's public API

`apps/files` is written in Zig against the generated `siv` wrapper only,
so it meets exactly what C and other bindings meet. This log records every
place where the API was awkward, missing, slow, or surprising, in the
order found. Each entry says what happened, what the app does about it,
and its status:

- **Fixed** — siv changed in a labeled commit, with DESIGN.md updated.
- **Open** — a larger API question left for a decision; the app works
  around it.
- **Noted** — minor, or a known gap already listed in DESIGN.md.

## Fixed in siv

1. **No way to run blocking work on siv's worker pool.** Reading a folder
   of 100 000 entries (getdents and a statx per entry, then a natural
   sort) and copying files must not run on the UI thread, but the pool
   (D6) was internal: only image decoding used it. An application would
   start threads of its own and oversubscribe the CPU against siv's
   decoders and tile rendering. *Fixed:* `siv_job_start(app, work, done,
   destroy, user_data)` (commit "abi: run application jobs on the worker
   pool", D6).

2. **A list in a split pane could not fill the pane.** Split panes are
   boxes; a box offered its children no height, so `height = fraction 1`
   resolved to auto and the file view shrank to its header (the sidebar
   to 12 px). Nothing in the public API could make it fill: the pane's
   height is unknown to the application. *Fixed:* fraction heights resolve
   against a box's height when it is definite (commit "ui: resolve
   fraction heights against a box's definite height", D26).

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
   D18). The app also gives its cells role `cell` with their column index.

## Open API questions

5. **One return value means both "stop bubbling" and "skip the default
   action".** The DOM separates `stopPropagation` from `preventDefault`;
   siv's `bool` return conflates them. The app's window-wide shortcut
   handler (on the root) sees every key typed into the search field, the
   location field, and the rename field; Backspace there must stay the
   editor's, not "go up". With `target` (item 3) a handler can tell, but
   only if it knows which nodes are editors: the app tracks focus on each
   of its editors (`editing`). Questions: should handlers be able to stop
   bubbling without cancelling the default action? Should siv expose the
   focused node (`siv_window_get_focus`) and its kind?

## Noted

6. **Keysyms are not in siv.h.** Every program writes out XKB keysym
   numbers (`apps/files/src/keys.zig`; src/widgets has its own table).

7. **Icons.** DESIGN.md (D19) says icons follow the freedesktop icon theme
   specification and render through siv's SVG parser, but neither exists
   yet: there is no way to load a themed icon by name. The app draws its
   icons on canvases with paths in theme colors (`src/icons.zig`), which
   keeps them sharp and themed but means every application redraws the
   folder icon.

8. **Push buttons take a label only.** Back, Forward, Up, and the view
   toggle are text buttons; an icon button would need a custom canvas
   widget with its own focus, press, and activate handling.
