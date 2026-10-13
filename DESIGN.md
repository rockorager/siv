# siv design

siv (from Coheed and Cambria's *Good Apollo, I'm Burning Star IV*) is a
high-performance GUI toolkit for Linux. It is written in Zig, exports a stable C
ABI, and targets Wayland only.

This document records decisions, not aspirations. Each decision names the
requirement it serves, the alternatives considered, and the evidence that would
reverse it. "Another toolkit does it this way" is evidence, never a reason.

## Principles

1. **Design from first principles.** Every decision states the requirement it
   serves. Prior art (GTK, Qt, Chromium, Flutter, ourokit) informs; it does not
   decide.
2. **Performance is a requirement.** Budgets are measured in CI. An idle
   application costs nothing.
3. **No development shortcuts.** The first implementation of a subsystem is the
   real one: accessibility, input methods, color management, and failure paths
   are designed in, not added later.
4. **The C ABI is the product.** Every capability is reachable from C. Stock
   widgets use only public primitives.
5. **Small core, complete scope.** The core is a UI toolkit. Anything else is an
   optional module or out of scope.

## Architecture

```text
┌──────────────┐ ┌─────────┐ ┌────────────────────┐
│ Lua 5.5      │ │ Zig API │ │ C / Rust / Go / …  │
│ (libsiv-lua) │ │         │ │ (generated)        │
└──────┬───────┘ └────┬────┘ └─────────┬──────────┘
       └──────────────┼────────────────┘
                      ▼
       ┌──────────────────────────────┐
       │ C ABI: handles, transactions │
       └──────────────┬───────────────┘
                      ▼
┌───────────────────────────────────────────────────┐
│ UI thread                                         │
│ event loop (epoll) · input routing · focus        │
│ retained tree · layout · text · semantics (a11y)  │
│ stock widgets · D-Bus · portals                   │
└──────┬───────────────────▲──────────┬─────────────┘
       │ layer updates     │ events   │ worker pool:
       ▼                   │          │ decode, file I/O,
┌──────────────────────────┴───┐      │ raster tiles
│ Compositor thread            │      │
│ libwayland · layer tree      │◀─────┘
│ scroll and transform/opacity │
│ animation                    │
│ CPU renderer │ Vulkan        │
│ wl_shm       │ swapchain     │
└──────────────────────────────┘
```

## Decisions

### D1. Library with a stable C ABI

- **Requirement:** applications in any language can use siv, and the toolkit can
  be embedded in existing programs.
- **Decision:** siv is a shared library (`libsiv.so.N`) with a C ABI. Zig, Lua,
  and other bindings are generated from one API schema.
- **Alternatives:** an application host with a scripting language as the primary
  interface (ourokit); a Zig-only library.
- **Reverse if:** never; this is the product definition.

### D2. ABI conventions

- **Requirement:** foreign callers must be able to use the ABI safely and
  bindings must stay correct across versions.
- **Decision:**
  - Objects are generation-checked `uint64_t` handles, never pointers. A stale
    handle is a detectable error. Layout: type tag (8 bits, never 0, so a
    mistyped handle fails), root slot (10), generation (22), index (24).
    Objects belong to a root (the application); destroying the root
    invalidates every handle it issued.
  - Every descriptor struct begins with `size_t size`. Zero means default, so
    callers use designated initializers (`SIV_DESC(type, .field = v)` sets the
    size). Descriptors are passed by pointer (NULL means all defaults), are
    never embedded by value, only grow by appending fields, and have no
    padding. A smaller size (older headers) gets defaults for the missing
    fields; a larger size (newer headers) is accepted only if the unknown
    bytes are zero, otherwise `SIV_ERROR_UNSUPPORTED`; a size that ends inside
    a field is invalid. Value structs (points, colors) are frozen forever.
  - Strings are pointer and length; embedded NUL is allowed. siv copies what
    it keeps. Static strings siv returns are also NUL-terminated.
  - Callbacks take `void *user_data` as their first parameter; a callback
    parameter is followed by its `user_data`.
  - Fallible functions return `siv_result` (0 is success, errors negative),
    write outputs through trailing pointers only on success, and have no
    effect when they fail. Unknown enum values and flag bits are
    `SIV_ERROR_UNSUPPORTED`.
  - No global state; multiple applications per process are allowed. The one
    process-wide structure is a fixed, lock-free table of 1024 root slots
    that lets any handle be validated without its root. It holds no
    configuration and needs no initialization.
  - Allocation failure is an error result at every call, never an abort.
    Applications may supply allocator hooks (`siv_allocator`: alloc and free
    with size and alignment, plus user data) per root; every allocation for
    that root, including the root itself, goes through them. The hooks must
    be thread-safe: `siv_post` allocates on the calling thread (D5).
  - SONAME versioning, symbol versioning, and semantic versioning. The SONAME
    is `libsiv.so.<major>`. A generated version script exports exactly the
    schema's functions and hides everything else (including sanitizer
    runtimes). Before 1.0 every symbol carries the node of the current minor
    release (`SIV_0.1`), so a program linked against 0.1 fails to load
    against 0.2 instead of misbehaving; from 1.0 a symbol keeps the node of
    the release that added it. A build check compares the exported symbols,
    versions, and SONAME against the schema. Deprecation rules are written
    down before 1.0.
  - Every function except `siv_post` (and `siv_version`,
    `siv_result_name`) is called on the thread that created the root.
  - `siv_post` racing root destruction: each registry slot has a pin
    count. `siv_post` pins the root (increment, then recheck the
    generation, both sequentially consistent), queues its closure, and
    unpins. `siv_app_destroy` first retires the handle (bumps the
    generation, so new pins and lookups fail) and waits for the pin count
    to reach zero, then tears down. So a post either fails with
    `SIV_ERROR_INVALID_HANDLE` and nothing runs, or its closure is queued
    before teardown and its destroy-notify runs exactly once. The wait
    is bounded by one allocation and a lock-free push on the posting
    thread.
  - A destroy-notify runs exactly once, when siv drops the user data, and
    never while a siv callback is running: releases triggered from a
    callback (a handler replacing itself, a window destroyed from its own
    handler) are queued until the outermost callback returns. A call that
    takes a destroy-notify and fails runs it at once, since ownership
    passed with the call.
  - Arrays are a const pointer and `<name>_count`; functions that fill
    caller memory take `char *` and `<name>_cap`, write at most that much,
    and report the full length, so callers can size a second call.
  - Callbacks receive event details as size-prefixed structs by pointer
    (`siv_event`, `siv_window_event`), so events grow like descriptors.
- **Alternatives:** GObject-style reference-counted objects with
  inheritance; raw pointers; a per-thread "last error" (global state, and
  lost across language boundaries); `libsiv.so.0.<minor>` SONAMEs before 1.0
  (lets 0.x releases coexist, but Zig's build names files by major only).
  For `siv_post`: reference-counted roots (every call would pay an atomic
  pair, not only posts); hazard pointers (the same guarantee with more
  machinery than one counter per slot); a lock per slot (posters would
  block each other).
- **Reverse if:** generation checks show up in profiles on hot paths. Then
  check only at the ABI boundary in release builds (internal code already uses
  plain indices; see D20). Use per-minor SONAMEs if distributions need 0.x
  releases installed side by side.

### D3. One API schema generates every binding

- **Requirement:** the C header, Zig wrapper, Lua binding, documentation, and
  third-party bindings must never drift.
- **Decision:** a Zig schema (`src/abi/api.zig`, format in
  `src/abi/schema.zig`) describes every type and function. Build steps
  generate `siv.h`, the Zig wrapper, reference documentation, a published
  JSON description for external generators, and the linker version
  script; the Lua binding is generated from the schema at compile time
  (D23). libsiv's own exports use the generated Zig wrapper's types
  and are checked at compile time against the schema signatures, so the
  implementation cannot drift either. A test-only library built from a second
  schema exercises every construct through the same pipeline.
- **Alternatives:** hand-written header with bindings derived from it; GObject
  Introspection.
- **Reverse if:** the schema cannot express a needed ABI construct without
  special cases.

### D4. Retained tree mutated through transactions

- **Requirement:** accessibility, input methods, focus, and animation need stable
  identity across frames. Each frame must show a consistent state. Crossing the
  FFI boundary has a per-call cost.
- **Decision:** a retained tree of a small closed set of primitives (box, flex,
  grid, stack, text, editor, scroll/viewport, image, canvas, external surface).
  Mutations are batched in a transaction and applied atomically on commit.
  Declarative diffing, if wanted, is a helper above the tree, not a layer every
  update passes through.

  ```c
  siv_txn *t = siv_txn_begin(win);
  siv_node row = siv_flex(t, root, &(siv_flex_desc){ .axis = SIV_ROW, .gap = 8 });
  siv_text(t, row, "Hello", 5);
  siv_on(t, button, SIV_ACTIVATE, on_click, user);
  siv_txn_commit(t);
  ```
  - The tree lives in `src/ui` (`Window`), one per window. Operations apply
    to the tree at once, so later operations and queries in the same
    transaction see them; frames do not run while a transaction is open.
    The first change to a node in a transaction copies its committed
    state, and `abort` restores the copies. Each operation allocates
    before it changes anything, so a failed operation has no effect and
    `commit` cannot fail. One transaction per window is open at a time.
  - Nodes are always created under a parent (no orphans to leak), and
    removing a node destroys its subtree at commit. Removed slots are
    recycled only after the next frame, so a node index held while events
    are dispatched never names a different node.
  - Derived state (dirty flags, layout caches, layer assignment) is kept
    outside the copies; an abort can leave extra dirty flags, never
    missing ones.
  - External surfaces are in the closed set but not built yet; creating
    one fails with `Unsupported`.
  - At the C ABI (`src/abi/tree.zig`), builders (`siv_flex`, `siv_text`,
    ...) return the new node's handle directly, as in the example above,
    and errors are sticky: the first operation that fails records its
    error in the transaction; every later operation does nothing and
    returns it (builders return 0), and `siv_txn_commit` discards the
    whole transaction and returns that error. `siv_txn_status` reads it
    early. A C program builds a subtree without checking each call and
    still never commits half of it. Setters return the status too, with
    warnings for ignored results off.
  - Node handles are made when a node is created and removed when a
    committed transaction destroys it, the transaction that created it
    aborts, or the window goes. Handlers set with `siv_on` are part of the
    transaction: an abort restores the previous handler and releases the
    new one; a commit releases the replaced one.
- **Alternatives:** immediate mode (no stable identity without hashing call
  sites); builders that return `siv_result` with the node through an out
  parameter (every line of tree-building code becomes a checked call, the
  usual C idiom drops errors anyway, and a failure midway still leaves
  the caller to abort); applying the successful operations of a failed
  transaction (commits a half-built subtree); a log of operations applied at commit (no reads of pending
  state, and cycles and kinds can only be checked at commit, where failure
  is too late); descriptions lowered through several intermediate representations
  (ourokit: description → descriptor → instance → render object).
- **Reverse if:** binding authors cannot express common UIs without a diffing
  layer; then ship the diffing helper, not a second tree.

### D5. Callbacks run only at safe points on the UI thread

- **Requirement:** no re-entrancy between I/O completion, layout, and application
  code.
- **Decision:** I/O and platform events only update state and mark work
  runnable. Application callbacks run at a defined phase of the loop.
  `siv_post` is the only call that is safe from any thread.
  - Each loop iteration runs, in order: poll; io (fd handlers, which only
    read, update state, and schedule tasks); timers; dispatch (closures from
    `siv_post`, worker-pool completions, then dispatch tasks); frame (layout,
    paint, present); prepare hooks before sleeping (Wayland flushes here).
    Work scheduled for a phase that already ran waits for the next iteration.
  - `siv_post` takes a callback, a destroy-notify, and user data. Posting
    allocates a node, so the loop's allocator must be thread-safe. The
    destroy-notify runs after the callback, or alone if the application
    is destroyed first, so it is the one place to free the user data.
  - Worker jobs run on the application's one worker pool (`src/pool`, see
    D6); the loop's wrapper posts each completion to the loop, so `done` runs
    in the dispatch phase.
  - Destroying the application never runs pending posted closures or worker
    completions, since teardown has begun; it calls their destroy-notify (or
    a job's cancel function) so they can release what they own.
- **Alternatives:** callbacks from arbitrary threads (forces locking on every
  caller); running pending closures at teardown (runs application code
  against a half-destroyed application).
- **Reverse if:** never.

### D6. Embeddable event loop: epoll

- **Requirement:** hosts with their own loop (GLib, libuv, Qt, game loops) must
  be able to drive siv. siv must run inside sandboxes.
- **Decision:** one epoll loop per application with eventfd wakeups and timerfd
  deadlines from a userspace timer heap. `siv_app_fd()` and
  `siv_app_dispatch(timeout)` embed it; `siv_run()` owns it. File I/O runs on the
  worker pool.
  - The loop fd stays readable while any work is pending (the eventfd is
    written when work is scheduled for a phase that already ran), so an
    embedder only needs to poll it and call `siv_app_dispatch(0)`. An idle
    loop with no armed timers blocks indefinitely.
  - Worker threads start on demand up to a limit and block when idle.
  - One worker pool per application, shared by file I/O, decode, and raster
    tiles, so the loop and the renderer never oversubscribe the CPU. It has
    two modes on the same threads and queue: async jobs (completions
    delivered by the loop, D5) and blocking fork-join, in which the calling
    thread also runs the job and helpers that have not started when it
    finishes are dropped, so fork-join never waits behind queued I/O.
- **Alternatives:** io_uring. Rejected: a GUI client issues tens of syscalls per
  frame, so batching gains are negligible; Docker's default seccomp profile
  blocks io_uring, Android and ChromeOS disable it, and seccomp sandboxes cannot
  filter it.
- **Reverse if:** a measured workload shows syscall overhead in a frame budget,
  and io_uring is available in the target sandboxes.

### D7. libwayland, Wayland only

- **Requirement:** embedders need standard `wl_display*`/`wl_surface*` objects
  for Vulkan surfaces, GStreamer, libmpv, and EGL. No X11 users are targeted.
- **Decision:** libwayland-client, with zig-wayland generated bindings. No X11
  backend.
- **Alternatives:** Wayring (no ABI-compatible display objects, so no standard
  Vulkan swapchain and no third-party embedding).
- **Reverse if:** zig-wayland cannot track the Zig version siv requires; then
  generate bindings with siv's own scanner over the libwayland C API.

### D8. Compositor thread with a layer tree

- **Requirement:** scrolling and animation stay smooth while the UI thread is
  busy (application code, Lua, large layouts).
- **Decision:** one compositor thread per process owns a layer tree and all
  presentation. It runs scrolling and transform/opacity animations
  independently. The UI thread sends layer updates, not whole frames.
  The compositor thread renders CPU tiles through the application pool's
  fork-join mode and works on tiles itself, so it never blocks on the loop.
  - Layer updates (`src/compositor/update.zig`): each window has a tree of
    layers with UI-chosen ids (plain indices, D20). The UI commits batches
    of ops (create, destroy, insert, detach, set content, transform,
    opacity, clip, scroll container, scroll to, fling, animate,
    background), applied atomically between frames. Content is a display
    list whose builder moves to the compositor and comes back in a
    `released` event once no frame reads it.
    `ui.Window.buildersHome` reports when all of a window's builders have
    come back, so its owner knows when the window can be freed.
  - Transforms are components (translate, scale, rotation about an
    origin), not matrices, so that animations interpolate them; skew
    belongs inside content.
  - Scroll offsets belong to the compositor: it scrolls containers on
    pointer input and flings by itself and reports `scrolled` events with
    the last applied commit's sequence number, so the UI can ignore
    reports older than its own `scroll_to`.
  - The platform (the Wayland connection, or the headless backend) runs
    on the compositor thread's own loop, and the compositor forwards
    input, configure, and output events to the UI loop. Presenting while
    the UI thread is stalled needs frame callbacks, buffer releases, and
    presentation feedback dispatched off the UI thread, and scrolling on
    input needs the input too. The alternative, a second event queue for
    presentation objects with the configure and frame clock state shared
    under a lock, keeps input on a stalled thread. The cost is one thread
    hop (an eventfd write) per input event.
  - Pointer scroll goes to the UI first when ctrl, alt, or super is held
    (zoom and similar bindings), and over wheel regions the UI marks on
    layers (`set_wheel_region`) for its own scroll and wheel handlers.
    Otherwise the compositor hit-tests its tree and walks from the
    topmost hit layer to the root: the first wheel region containing the
    point sends the event to the UI, the first input-enabled scroll
    container that can still move in that direction scrolls it. A
    touchpad gesture keeps its first target until the scroll stops. UI
    handlers that decline an event pass it on with `scroll_by`, which is
    relative and so cannot race the compositor's own scrolling. Touch
    drags go to the UI, which starts flings with `fling`.
  - Configure acks follow content: configures reach the UI as events
    with serials, and a commit names the serial its layout answers
    (`ack_configure`). A configure that changes the logical size is
    acknowledged with the first frame that includes such a commit, or
    after 100 ms with the old layout at the new size, so a stalled UI
    cannot freeze the window. Scale and state changes present at once:
    vector content needs no new layout to render at a new scale. The
    platform's `deferConfigure` (D12) holds the ack and enforces the
    timeout.
  - Every Wayland request the UI owns logically (text-input-v3 state,
    clipboard and drag-and-drop sources and offers, cursors, popups,
    window management) is a platform call made on the compositor thread.
    The UI issues it with `Compositor.post`, which runs a closure there in
    order with layer commits, so a text-input cursor rectangle or a popup
    lands in the same frame as the content it belongs to; or with
    `Compositor.call` when it needs a result (creating a window or popup,
    reading output info). The UI never touches the display. Replies come
    back as forwarded platform events. Bulk data (clipboard and
    drag-and-drop transfers) moves through pipes that the UI reads and
    writes on its own loop or the worker pool; only the requests that
    hand over the fds go through the compositor.
  - A frame presents only when it has damage or an animation is running
    (whose frame callbacks pace it, even when a step shows nothing new).
    A UI frame request or a commit that changes nothing visible costs no
    buffer; a pending configure ack goes out as a bare commit (D12).
  - Lowering (`src/ui/paint.zig`): layers are the root, every node with
    opacity below 1, a transform, or a layer hint, every clipping node
    with layers below it (so its clip, a layer property, applies to them),
    and every scroll node. A scroll node's layer is the scroll container,
    with its decoration as the container's own (unscrolled) content and
    one child layer for the scrolled content. Content painted after a
    child layer in the same parent goes into a "chunk" layer after it, so
    paint order survives without node knowledge in the compositor. Layer
    ids are layer indices plus one.
  - Each layer's content is a display list in the coordinates of the node
    that roots it. Only layers whose nodes changed are repainted, and their
    `SetContent.damage` is the old and new painted bounds of the nodes that
    changed. Moving, fading, or transforming a layer root, and scrolling,
    send properties only.
  - Scroll offsets are logical in the tree (in RTL, offset 0 shows the
    right end of the content) and physical in layer ops. When the content
    of an RTL scroll node changes width, the UI sends `scroll_to` so the
    start edge stays in view.
  - A node with a scroll handler roots its own layer with a wheel region
    over its box, so scroll input over it reaches the UI first. Scroll
    input the UI gets (wheel regions, modifiers held, nothing to scroll in
    the compositor) bubbles through scroll handlers from the node under
    the pointer; if none takes it, and no ctrl, alt, or super is held, it
    goes on to the nearest scroll node with room as `scroll_by`. Keyboard
    scrolling (arrows, page keys) is `scroll_by` too. Only offsets the
    application sets in a transaction are `scroll_to`.
  - A frame composes the window's tree into one display list: each layer
    is a scene layer with its own id, so `scene.damage.Tracker` diffs
    frames (D9); ids inside content are cleared, and content damage comes
    from `set_content`. A scroll container wraps its children in a second
    scene layer (id with bit 31 set, so layer ids stay below 2^31) that
    clips to the viewport and carries the offset. A reorder damages only
    the moved layer's old and new bounds. Replaced content is released
    after the next frame, whose damage tracking still reads the old list.
  - The presentation boundary is `surface.Surface`: it takes the composed
    list, device damage, root transform, and background. The CPU backend
    keeps one renderer per window (so glyph caches are per window too),
    renders into the platform's wl_shm buffers, re-encodes a reused
    buffer's age damage from the persistent framebuffer, and reports this
    frame's damage in buffer pixels. The Vulkan backend (D10) is the
    second variant, with its own swapchain on the same wl_surface; the
    tree, animation, and damage tracking above it do not change.
  - A frame presents when something is damaged, an animation runs, or the
    UI asked for a frame (an empty-damage present keeps frame callbacks
    pacing). `Event.frame` answers `requestFrame` with the time of the
    frame after the current one, which is when a commit made in response
    is shown. `presented` reports the first frame with a commit; a commit
    that changes nothing visible counts as presented at once.
  - Wheel deltas apply immediately, unsmoothed. Flings start only when a
    touchpad gesture stops faster than 100 px/s, from the last 100 ms of
    deltas, and decay with a 325 ms time constant (a first guess). A
    scroll container is hit anywhere in its viewport, drawn or not.
  - Measured (`zig build test-headless` with `SIV_MEASURE=1`, and `zig
    build bench-pacing`, 60 Hz): on headless, key-to-photon with the
    compositor thread has a median of 7 ms against 7.6 ms rendering on the
    UI thread (both within one frame). On sway, using presentation
    feedback while the UI thread sleeps, wheel-to-photon has a median of
    2.4 ms (ReleaseFast) or 9 ms (Debug). A 500 ms animation while the UI
    thread spins drops no frames on either backend, at 1280×720 on sway;
    rendering on the UI thread (headless) misses 23 of the stall's 24
    vblanks. The headless test asserts only that the compositor thread
    finishes the animation while the UI thread does not dispatch, and
    prints the missed vblanks: with the rest of `zig build test` and busy
    loops beside it, the compositor thread sometimes runs a vblank late
    and misses one, which measures the machine, not siv (`zig build
    bench-pacing` counts drops on sway, D12). Input waits behind a frame
    being rendered on the compositor thread, so a slow frame delays input
    by up to its render time.
- **Alternatives:** render on the UI thread (lowest latency when idle, but any
  UI-thread stall drops frames); a plain render thread (adds a handoff without
  independent animation).
- **Reverse if:** measured input-to-photon latency regresses beyond one frame
  versus UI-thread rendering for idle applications.

### D9. Vector display list

- **Requirement:** one scene description must drive the CPU renderer, Vulkan,
  and PDF output for printing and export.
- **Decision:** immutable display lists of paths, gradients, images, text runs,
  clips, layers with opacity, 2D affine transforms, and backdrop blur. Steady-
  state frames allocate nothing. Paint-only changes skip layout. Damage is
  tracked per layer.
  - A list is a flat command sequence: `push`/`pop` open and close a layer
    (transform, clip, opacity, blend mode, forced isolation); fills (rect,
    rounded rect, or path with nonzero or even-odd), strokes, glyph runs,
    images, box shadows, and backdrop blurs draw into the innermost layer.
    The stack form maps to PDF's q/Q, clipping paths, and transparency
    groups.
  - A box shadow (`scene.Shadow`) is CSS box-shadow for a rounded
    rectangle: offset, Gaussian sigma (half the CSS blur radius), spread,
    color, outset or inset. Outset shadows are not drawn under their
    rectangle, inset ones only inside it, so a translucent card does not
    show its own shadow. Cards, menus, and popups need one each; as a layer
    with a fill and a backdrop blur every shadow costs an offscreen pass,
    and a damaged blur redraws all of it (a 40-card dashboard: 198 ms per
    CPU frame and 194 ms for a hover, against 72 ms and 4 ms analytic).
    Corner radii grow or shrink with the spread (zero stays sharp). PDF:
    a soft mask image of the blur, clipped to the shape (D19, Printing).
  - Colors are linear light, sRGB primaries, straight alpha. Paints are solid
    colors and linear, two-point conical, and sweep gradients; gradients
    interpolate premultiplied in linear light, and repeat/reflect use the
    stop range as the period (CSS, COLRv1).
  - Image formats include opaque `bgrx8_srgb`, the XRGB8888 layout
    external video frames arrive in (D17).
  - Layer blend modes are the COLRv1 set (Porter-Duff and the W3C blend
    modes), because color glyphs lower into display lists. Modes that touch
    the destination where the source is transparent affect the layer's whole
    clip.
  - A backdrop blur blurs everything drawn before it in the nearest isolated
    layer, like CSS backdrop-filter.
  - Builders copy paths, stops, and glyphs into an arena that is reset per
    frame slot. Image pixels and fonts are referenced; their keys change when
    content changes and key backend caches.
  - In the UI, image pixels belong to siv (D2): `ui.Image.create` copies
    them into immutable storage, reference counted from any thread. An
    image node holds a reference (taken and dropped with its transaction:
    abort drops the new one, commit the old), and each display list that
    draws the image holds one in its builder until the compositor
    releases the list. So the creator may release its reference at once,
    and the pixels are freed when the last list that can still be shown
    is released. Keys come from a process-wide counter with the top bit
    set, apart from the keys producers choose for external frames (D17).
    Decoded images (D19) are `rgba8_srgb`, or `rgba16_linear_premul`
    when scaled, color managed, or deeper than 8 bits; an animation's
    frames share one `ui.Image` with a key per frame.
  - Synthetic bold and oblique (D13) need nothing in the list: they live
    in the face's HarfBuzz font, which `scene.Font` names, and its key
    differs from the plain face's.
  - Glyph runs may carry their text (`scene.GlyphText`: the bytes and
    each glyph's cluster offset into them) for output that keeps text,
    such as PDF's ToUnicode maps; the renderers ignore it.
  - Damage: layers with a nonzero id are matched across lists. A layer's
    version covers everything except its transform and opacity, including
    the order of its child layers. `scene.damage.Tracker` returns device
    rectangles (merged; more than 16 collapse to their bounds). Merging
    is one pass that collapses to the bounds as soon as more than 64 stay
    disjoint: 2,560 animated layers damage 5,120 rectangles a frame, and
    pairwise merging took 65% of the process's time.
  - PDF output composites in sRGB, not linear light. PDF blends in a
    transparency group's color space, so declaring a linear-light space
    (an ICCBased profile with sRGB primaries and identity curves, or
    CalRGB with gamma 1) on the page and group XObjects, with colors given
    in it, would make printed translucency match the screen. Measured
    with 50% blue over white (linear blending gives sRGB 187, sRGB
    blending 127): Ghostscript 10.0 honors it (187), and with it the
    cups-filters paths that render with Ghostscript (gstoraster, and
    pdftops, whose default renderer is Ghostscript's ps2write); Poppler
    22.12 (Splash and Cairo, so pdftoppm, pdftoraster, Evince, Okular),
    MuPDF 1.21, and pdf.js 4.10 ignore it (127). Device colors drawn in
    such a group are converted by Ghostscript too. So viewers and
    previews would disagree with Ghostscript prints of the same file;
    siv keeps DeviceRGB and sRGB compositing everywhere, so every reader
    shows the same thing. Revisit when Poppler and pdf.js blend in the
    group's space.
- **Alternatives:** pixel-only scene (cannot produce PDF).
- **Reverse if:** a construct cannot be lowered to all three backends. PDF
  has no sweep-gradient shading; sweeps lower to Coons patch meshes, and
  box shadows to soft masks (D19, Printing). Backdrop blur has no PDF
  equivalent and is left out of printed pages.

### D10. CPU renderer and Vulkan renderer

- **Requirement:** headless tests, golden images, machines without suitable
  Vulkan, and high performance where the GPU is available.
- **Decision:**
  - CPU: tiled across the worker pool, presented through `wl_shm`. It is the
    golden-image oracle. Presented buffers are premultiplied ARGB8888, which
    every compositor supports; the 16-bit working space (D11) is converted
    when writing them.
  - CPU frames: one prepare pass on the calling thread (device transforms,
    premultiplied paints, glyph placement), path and stroke flattening on
    the workers, a parallel pass that rasterizes paths up to 512×512 px once
    into masks (larger paths rasterize per tile from row-binned lines), then
    damaged 64×64 tiles run on workers into a persistent 16-bit linear
    framebuffer and are encoded into the output buffer. Keeping the
    framebuffer makes damage-only frames exact and lets a reused buffer's age
    damage be re-encoded without redrawing.
  - The renderer takes a fork-join `Executor` (run one job on N workers and
    wait). The application pool provides it (D6); `Executor.serial` renders
    inline, e.g. for color glyph bitmaps.
  - Which worker gets which work changes from frame to frame, so after the
    geometry pass every worker's buffers grow to what any one worker
    would need: its line list to all the lines the frame made, its path
    and stroke scratch to the largest any worker has used (exactly, since
    rounding up would ratchet). A frame like an earlier one then allocates
    nothing even if one worker that never ran does all of it, which a
    test forces with an executor that runs every job on one chosen worker.
  - Coverage contract shared with Vulkan: exact box coverage for
    rectangles; rounded corners clamp(0.5 − d, 0, 1) at pixel centers,
    limited by box coverage; paths exact-area coverage after flattening to
    1/40 px, quantized to 8 bits.
  - Backdrop blur: render the backdrop region with the preceding commands on
    the same tile grid, blur it separably (an exact Gaussian up to σ = 2,
    three box passes above), clamp at the surface edge, and widen damage
    where changed pixels reach the backdrop.
  - Output: ARGB/XRGB/ABGR/XBGR 8888, 2101010, and 16161616, sRGB-encoded
    and premultiplied in encoded space. 8- and 10-bit outputs get an 8×8
    ordered dither anchored to device coordinates.
  - Golden images live in test/golden/render and are compared with a small
    tolerance (every channel within 3/255, at most 0.5% of pixels off by more
    than 1) to absorb cross-CPU rounding.
  - Vulkan 1.3 (dynamic rendering, synchronization2): instanced quads, analytic
    rounded rectangles and shadows, glyph and image atlases. Presentation uses
    the standard Vulkan Wayland swapchain.
  - Vulkan frames (`src/render/vulkan`) mirror CPU frames: the same prepare
    walk (transforms, clip bounds, culling) produces one instance per draw
    in a storage buffer, drawn as instanced quads by one fragment shader
    that evaluates the CPU renderer's formulas at pixel centers (coverage,
    gradients, the CPU's 8-bit bilinear image filter, blend modes, text
    contrast tables). Rectangles and rounded rectangles under axis-aligned
    transforms are analytic; every other shape (paths, strokes, clip paths,
    rotated rectangles, transformed glyph runs) is rasterized on the worker
    pool by the shared rasterizer into R8 mask pages (layers of one array
    image), only where damage needs it, so paths match the coverage
    contract exactly. Glyphs come from the CPU glyph cache (D14) through an
    R8 and an RGBA16 atlas. Isolated layers render into per-depth FP16
    images and composite back with fixed-function source-over, or for other
    blend modes against a copy of their backdrop. A backdrop blur copies its
    backdrop and runs the CPU's separable passes in FP32.
  - Both renderers skip the group buffer of a layer that is isolated only
    for its opacity and holds one fill or stroke with a solid paint, one
    image, or one box shadow (`scene.foldedOpacity`): that draw with its
    alpha multiplied by the opacity composites exactly as the group does,
    up to the group buffer's rounding. A layer per faded or animated box
    (D8 gives every animated node one) then costs a draw instead of an
    offscreen pass: 2,560 cells fading on the compositor took 18.7 ms of
    GPU time per frame on RADV, and 0.9 ms after.
  - The working image is a persistent FP16 image, so damage-only frames are
    exact as on the CPU. Damage is widened like the CPU's where a blur's
    backdrop changed, then each damage region grows until it holds the
    backdrop of every blur it meets, so blurs read only pixels drawn in the
    same pass (pixels outside the damage redraw identically). Every frame
    encodes the whole working image into the target with the CPU's transfer
    tables and dither, so swapchain images need no buffer age.
  - Descriptors: storage buffers and the atlases in one set per frame, and a
    second set of two textures per draw that needs one (images, layers,
    backdrops); image draws batch per image. No descriptor indexing:
    lavapipe (Mesa 22.3, the test device) has none.
  - libvulkan is loaded with dlopen, so libsiv has no link dependency on it
    and starts on machines without a loader.
  - Shaders are GLSL compiled to SPIR-V 1.6 on every build by glslang 16.6
    built from the source pinned in build.zig.zon (`-fsys=glslang` runs the
    system glslangValidator), so the SPIR-V always derives from the tree and
    from one compiler on every host. Alternatives: checked-in SPIR-V
    (drifts from its source without a regeneration step and a check that
    needs the compiler anyway); shaderc, DXC, Slang, or Tint (larger C++
    builds wrapping the same work); Zig's SPIR-V backend (experimental, with
    no image fetch or descriptor helpers in std). glslang's generated parser
    is GPL-3.0 with the Bison exception; it runs only at build time and
    nothing of it ships. Cost: about 80 s on a cold build (glslang is built
    in Debug; optimized builds exceeded 7 GiB with four jobs). Reverse if
    Zig's SPIR-V backend compiles these shaders into SPIR-V that drivers
    accept.
  - Verified (`zig build test-headless`, lavapipe): every CPU golden image
    in test/golden/render matches within the golden tolerance, including
    every blend mode, blur, COLRv1, and bitmap glyphs; in fact every
    channel is within 1/255 of the CPU's except one pixel at 2/255.
    Damage-only frames match full CPU frames, and the validation layer
    reports nothing. On RADV (Mesa 26.2.2, Radeon 760M, validation layer
    1.4.357) every channel of all ten images is within 1/255, with no
    validation messages.
  - Runtime fallback to CPU on `VK_ERROR_DEVICE_LOST` or GPU removal, and
    back to Vulkan once a device can be created again. Device selection on
    multi-GPU systems follows dma-buf feedback.
  - Device selection: Vulkan 1.3 with dynamic rendering, synchronization2,
    Wayland presentation, and the FP16 and FP32 render formats. The
    compositor's main device from linux-dmabuf default feedback (the
    platform binds `zwp_linux_dmabuf_v1` version 4 only for it) wins,
    matched through VK_EXT_physical_device_drm, so buffers never cross
    GPUs; then discrete, integrated, and virtual GPUs. CPU implementations
    (lavapipe) are never chosen by default: the CPU renderer is faster
    there and is the oracle. `Compositor.Options.renderer` forces the CPU
    renderer or accepts CPU implementations (tests). Verified on sway with
    a GPU renderer and lavapipe installed beside RADV: feedback names
    226:128 (renderD128), which RADV matches (score 19 against
    lavapipe's 1); on pixman sway RADV cannot present and lavapipe,
    accepted in tests, is chosen. Not tried on a machine with two GPUs.
  - The device is one per process and is created on a thread of its own
    when the first Wayland window opens (10 ms to find none, 116 ms on
    lavapipe with pipelines, longer than the first-frame budget of D25);
    windows present with the CPU renderer until it is ready and then
    switch once. First frames stay on the CPU even with the pipeline cache
    below: instance and device creation alone took 15 to 45 ms on lavapipe.
  - Pipeline cache: a VkPipelineCache persists in
    `$XDG_CACHE_HOME/siv/vulkan` (else `~/.cache/siv/vulkan`), one file
    named by the driver's pipelineCacheUUID and a hash of the SPIR-V, so a
    driver or shader update starts a new file instead of feeding a driver
    stale data. It is loaded before the pipelines are created, saved after
    (only when it changed, written to a temporary file and renamed so a
    crash or a concurrent process never leaves a torn file), and then
    dropped. `Device.Options.pipeline_cache` names another directory or
    none (tests). Measured device creation (instance, device, five
    pipelines) without a cache, cold, and warm: lavapipe 22.3 (Debian) 128,
    127, 128 ms; lavapipe 26.2 (Nix) 738, 724, 733 ms. Lavapipe's cache
    holds only its header (32 and 20 bytes): it compiles with LLVM at
    pipeline creation and serializes nothing, so the saving cannot be
    measured in this environment; RADV, ANV, NVK, and NVIDIA serialize
    compiled pipelines, and Mesa drivers also keep their own shader disk
    cache. RADV (Mesa 26.2.2, Radeon 760M) writes 117 KB. With Mesa's
    disk cache disabled: 545 to 605 ms without a cache and cold, 32 to
    36 ms warm. With Mesa's disk cache warm (any earlier run of these
    shaders): 35 to 90 ms with or without siv's file, so siv's cache
    pays off only where Mesa's is evicted or disabled (571 to 594 ms
    down to 36 to 90 ms); a driver update makes both cold. RADV's data
    differs by a few bytes after each load, so the file is rewritten at
    each device creation, harmlessly, on the device's thread. None of
    this touches the D25 first-frame budget, which the CPU renderer
    meets while the device is created on its thread; the cache
    shortens when windows switch to Vulkan. Verified: a second device
    loads the first one's file (`render/vulkan/tests.zig`).
  - Presentation (`surface.Vulkan`): the platform hands the window's commits
    to the swapchain (`setExternalPresenter`); each frame it sets up the
    configure ack, scale, frame callback, and presentation feedback, then
    vkQueuePresentKHR commits them with the image, so the frame clock (D12)
    works as with wl_shm. Damage goes out through VK_KHR_incremental_present.
    The present mode is MAILBOX (Mesa always offers it), FIFO otherwise;
    see D12 for why. A window presented through Vulkan has no wp_fifo_v1 of
    siv's: Mesa (since 25.0) creates one for every swapchain in every
    present mode, and a second is a protocol error. The same will apply to
    wp_color_management_surface_v1 when siv drives HDR (D11) on a Vulkan
    window: the swapchain's color space must say it, not siv.
  - Fallback: on any swapchain failure, the window's swapchain is destroyed
    and that same frame presents with the CPU renderer. On device loss the
    window that sees it falls back that frame and, at the next frame of
    any window, every window moves to the CPU renderer and the device is
    destroyed. The compositor then re-creates it (on its thread, as at
    start) after 1 s, doubling the wait after each failed attempt up to
    60 s, and keeps trying: a removed GPU may come back (an eGPU replugged,
    a driver reloaded), and an attempt a minute is no idle cost worth
    saving. Once one succeeds, every window switches back at its next
    frame. A window whose swapchain failed for another reason stays on
    the CPU until a device is re-created. Verified on sway by marking the
    device lost mid-run: the window keeps presenting on the CPU, returns
    to Vulkan after the backoff, and a window opened afterwards starts on
    Vulkan.
  - Box shadow contract (`render/cpu/shadow.zig`, mirrored by the Vulkan
    shader): each pixel center maps into the layer's coordinates; the
    shadow shape's Gaussian blur is integrated exactly along x (each row of
    a rounded rectangle is one span, whose blur is an erf difference) and
    along y exactly over the straight rows and with a substituted midpoint
    rule over the corner bands; sigma includes the pixel's own box
    footprint (variance 1/12), so sharp shadows are antialiased; the
    casting rectangle's coverage is 0.5 minus its signed distance. erf is
    Abramowitz and Stegun 7.1.27 (no exponential, error below 5e-4)
    saturated beyond ±4; the shape's blur keeps its area within 0.25%.
    The CPU evaluates rows of axis-aligned shadows with the y samples and
    the straight span's x term shared, and skips pixels under the casting
    rectangle and where every erf saturates. Vulkan output is within 1/255
    of the CPU golden image.
  - Composited external dma-bufs (D17) are imported, never sampled in
    place: each new frame is copied into a texture by a submission of its
    own that is waited for (`render/vulkan/dmabuf.zig`), so the producer's
    memory is free once the copy returns and no frame in flight holds an
    import. With VK_EXT_image_drm_format_modifier the dma-buf becomes an
    image with its explicit modifier and plane layout (any modifier the
    driver lists for transfer and dma-buf import); without it, only linear
    dma-bufs are imported, as a buffer copied at the frame's stride. A
    linear dma-buf the driver rejects as an image (RADV wants stride and
    offset aligned to 256 bytes; decoders and other GPUs pad less) is
    copied as a buffer too. Both acquire the memory from the foreign
    queue family and treat foreign images as GENERAL, like wlroots.
    Opaque XRGB8888 only for now (as for shared memory); YUV needs a
    sampler Y'CbCr conversion and goes to a subsurface instead. The copy
    costs one GPU blit per video frame, the price of not tracking which
    frames in flight sample which import. Verified on lavapipe 26.2 (Nix;
    Debian's 22.3 lacks the extensions), with a memfd standing in for a
    linear dma-buf, and on RADV (Mesa 26.2.2, Radeon 760M) with a real
    dma-buf from udmabuf: an aligned frame through the explicit-modifier
    image, an odd stride and offset through the buffer copy; and a tiled
    image the same GPU exported (GFX11 64 KiB R_X swizzle, modifier
    0x0200000010401b04) through its explicit modifier and plane layout.
    Each imported frame matches the uploaded one exactly, with no
    validation errors.
  - Textures: beyond images unused for 120 frames, the least recently used
    ones not drawn this frame go once all of them pass 256 MiB, since
    every external video frame is a new texture.
  - Alternatives for shadows: a layer with a backdrop blur (above); a
    closed form for rounded corners (none exists; known ones such as Evan
    Wallace's approximate the corner and do not keep the area); a nine-
    slice texture of a precomputed blur (cheap, but a contract tied to
    texture resolution and inexact for elliptical or mixed radii).
  - No OpenGL.
- **Alternatives:** compute-based vector rendering (higher latency and
  complexity than UI needs); Sokol (X11-only window glue, no exportable images);
  own dma-buf presenter (required only without libwayland).
- **Reverse if:** the standard swapchain blocks a measured requirement
  (resize synchronization, frame timing); then build the dma-buf presenter.

### D11. Color

- **Requirement:** correct compositing, HDR and wide-gamut output.
- **Decision:** linear-light working space (FP16 on Vulkan, 16-bit on CPU) and
  `wp_color_management_v1` for HDR and wide gamut. Text coverage gets a
  perceptual correction, because users compare text with gamma-space Linux text.
  - The text correction maps coverage so that linear blending reproduces
    gamma-space blending against a contrasting background (white behind
    dark text; #181818, a dark theme's background, behind light text),
    from a table per foreground luminance (16 levels). Color glyphs are
    not corrected.
  - Light text first assumed black behind it. On real dark backgrounds
    that thinned it by about a tenth at half coverage. Measured against a
    GTK 4.22 app at 11–13 px (D14), GTK's light and dark text carry the
    same ink (it blends in sRGB), but siv's light text carried 7% less
    than its dark text and looked dim. With #181818 the two match, and
    dark text is unchanged.
- **Alternatives:** gamma-space blending everywhere (incorrect gradients and
  alpha); pure linear text (looks thin).
- **Reverse if:** user testing prefers uncorrected linear text.

### D12. Frame clock

- **Requirement:** animations land on the presented frame; no wasted frames.
- **Decision:** one frame clock per surface driven by frame callbacks and
  presentation feedback, sampling animations at the predicted presentation time.
  Use `fifo-v1` where available; tearing control is opt-in. Suspended or occluded surfaces produce no frames.
  - A frame runs when the application wants one and no frame callback is
    outstanding. A configure always forces a frame, even while suspended or
    waiting on a callback; if the application presents nothing, siv still
    acknowledges the configure and commits, unless the frame defers it
    (`deferConfigure`): then the next present acknowledges it, or, after
    100 ms, a forced frame that cannot defer again. Both backends behave
    the same; the compositor defers size changes until the UI's layout for
    them arrives (D8).
  - The predicted time is the first refresh after the last presentation that
    is still in the future (now plus one refresh before any feedback; the
    refresh comes from the output mode until feedback arrives). Presentation
    timestamps on another clock (weston uses `CLOCK_MONOTONIC_RAW`) are
    converted to `CLOCK_MONOTONIC`, the loop's clock.
  - With `fifo-v1`, each animation frame waits for the previous commit's
    barrier so that no frame replaces one that was never shown; answers to
    configures do not wait.
  - `commit-timing-v1` is not used. Frames target the next refresh, which a
    timestamp cannot improve, and mutter 50 stalls timed commits: when its
    last presentation lacks the vsync flag (headless outputs, or before it
    has an update-time estimate) it schedules the wakeup at about target +
    now, so a window never maps or freezes mid-animation.
- **Alternatives:** fixed-rate timers; `commit-timing-v1` on every commit.
  - Vulkan windows (D10) keep this clock: the platform requests the frame
    callback and presentation feedback before vkQueuePresentKHR, so they
    land in the swapchain's commit. Measured on sway 1.12 headless with
    lavapipe (Mesa 22.3), a 500 ms animation with the UI thread spinning:
    30 presentations, none dropped, one frame rendered per refresh, and
    predictions within 0.6 ms of feedback, in MAILBOX and in FIFO alike.
    The same on RADV (Radeon 760M) with sway's Vulkan renderer, seven runs
    per mode: 31 presentations, none dropped, 32 frames rendered, each
    handed off at most 1.1 to 2.0 ms after it became due, and predictions
    within 0.6 ms of feedback.
  - Measuring pacing: the frame clock records every presentation from
    feedback and, per frame, when it became due (its frame callback, or
    its start) and when its commit started (siv's hand-off). The tests
    count drops from that record, not by sampling the last presentation
    (a sampling thread that oversleeps a refresh under load reports drops
    that never happened), and assert that siv hands every frame off within
    a refresh of it becoming due: 0.5 to 1.3 ms for Vulkan here. With four
    busy CPU loops beside the test, frames still drop while hand-offs stay
    under 0.7 ms: the time goes to lavapipe rasterizing on the contended
    CPUs, which Mesa's software WSI waits for in vkQueuePresentKHR (25 to
    37 ms), and to sway's pixman repaint. That is inherent to a software
    GPU, so `zig build test-integration` asserts only what siv controls:
    every frame handed off within a refresh of becoming due (in Debug,
    only for Vulkan and the small card; the CPU renderer's full-window
    redraw takes most of a refresh unoptimized), no more than one frame
    per refresh (at most 500 ms / refresh + 4 frames for a 500 ms
    animation), presentation feedback reaching the frame clock, device
    loss falling back to the CPU renderer and recovering, and hidden FIFO
    windows never blocking. `zig build bench-pacing`, outside every test
    step and meant for a quiet machine or real hardware, prints the end
    to end numbers and fails above these thresholds: for a 500 ms
    animation with the UI thread spinning, at least 500 ms / refresh - 3
    presentations and none dropped (the full-window scroll only in
    optimized builds), the last prediction within a refresh of its
    feedback (Vulkan), and a wheel-to-photon median within two refreshes
    plus 2 ms.
  - Mesa's FIFO without `fifo-v1` (every release before 25.0) waits for the
    previous commit's frame callback inside vkQueuePresentKHR, with no
    timeout. A configure forces a frame even while a callback is
    outstanding, so a hidden window that gets two configures blocked the
    compositor thread for as long as it stayed hidden (3 s in the test,
    `zig build test-integration`). Vulkan windows therefore present in
    MAILBOX, which never blocks, and in FIFO skip a present while their own
    frame callback for the previous commit is pending: the compositor sends
    both callbacks of a commit together, and the platform still
    acknowledges the configure with a bare commit.
- **Reverse if:** never. Use `commit-timing-v1` for frames scheduled beyond the
  next refresh (media with timestamps) once mutter fixes the stall.

### D13. Text engine

- **Requirement:** correct complex-script text, async font loading, control over
  caching, and fixes without waiting on another project.
- **Decision:** siv's own paragraph engine:
  - Fontconfig for discovery and fallback candidates.
  - HarfBuzz (built in, without FreeType, GLib, or ICU integration) for shaping.
  - SheenBidi for UAX #9; uucode plus siv's UAX #14 and UAX #29 scanners, gated
    on the official conformance suites.
  - Font fallback chosen by actual `.notdef` output at grapheme boundaries.
  - Each run shaped with full paragraph context; L1–L2 reordering per line after
    break selection.
  - A text node owns a width-independent `ShapedParagraph`; a width change
    reruns only break selection and positioning into a `Layout`. The only cache
    is the font cache. Intermediates live in one arena per layout pass.
  - An edit reshapes only the paragraphs it touched, and one on each side
    (`ShapedParagraph.initReusing`): the others keep their bidi levels,
    segmentation, shaping, and break opportunities, copied to their new
    offsets, and `Layout.initReusing` keeps their lines, moved by the
    change in height. Paragraphs are independent (bidi, line, grapheme,
    and word boundaries all break after a separator; shaping stops
    there), so the result is the full rebuild's, which randomized tests
    compare field by field. Measured on a 1.4 MB, 4,000-paragraph editor
    (bench/gpui-compare, RADV): key to photon 299 ms before, 28 ms after.
    What remains is linear in the text: the arrays are copied, not
    shared, and the whole layout is painted; per-paragraph storage would
    remove that.
  - Unsafe-to-break line edges are reshaped inline.
  - Hyphenation from Liang patterns (each pattern file's licence checked);
    an optional Knuth–Plass breaker for document views.
  - Horizontal text only; vertical CJK is a non-goal.
  - The font cache never reads files. Fonts enter with caller-supplied bytes or
    as pending Fontconfig sources; shaping skips pending fonts and lists the
    ones it wanted, and the text node loads them on the worker pool and
    rebuilds its `ShapedParagraph`. A style's fallback chain is Fontconfig's
    coverage-trimmed sort for the query.
  - Fallback probes only fonts whose cmap (or Fontconfig charset, when
    pending) has the grapheme's first code point. A stretch of unrenderable
    graphemes goes to the first font that renders all of it, else grapheme by
    grapheme. Emoji presentation (UTS #51) prefers color or text faces.
  - SheenBidi resolves levels once per text; L1 and L2 run in siv on the stored
    levels and bidi classes, so no SheenBidi object outlives the analysis.
  - Line_Break, Word_Break, Script, and Script_Extensions are uucode extension
    fields built from the pinned UCD. Grapheme clusters keep uucode's one
    tailoring: an emoji modifier not after a modifier base is its own cluster.
  - One `hb_font_t` per face at font-unit scale, scaled per run, so sizes cost
    nothing. `ptem`-dependent shaping (`trak`) is not applied.
  - The cluster map is two caret stops per grapheme in visual order; ligatures
    split at GDEF caret positions, else evenly.
  - Paragraph styles (`text.layout.ParagraphStyle`, per bidi paragraph:
    the text up to a paragraph separator) are layout options, since none
    changes shaping: start and end indents and a first-line indent
    (negative hangs), alignment, line spacing as a multiple of the line's
    natural height (CSS line-height: the extra space split above and
    below, so the baseline moves down by half of it) or an exact line
    height, and space before and after. Paragraph spacing applies between
    paragraphs only, the two sums adding (as in LibreOffice; CSS margins
    collapse to the larger, Word adds both); space before the first
    paragraph or after the last would only duplicate the node's padding.
    Lines record their indents and alignment; the layout's widest line
    counts its indents, so the reuse rule above still holds. Indents
    follow the direction the lines are aligned by, like alignment (D21):
    a text node's or a canvas's, not each paragraph's.
  - Tabs advance to tab stops at layout time, from the start margin
    rather than the indent, so columns line up across paragraphs with
    different indents: explicit stops (per node, since a value struct
    cannot hold an array), then multiples of the paragraph's tab width,
    by default the shaped tab's advance (four spaces). A segment holding
    a tab is measured where it falls, glyph by glyph in logical order,
    which is exact for lines of one direction; a line mixing directions
    measures its tabs in logical order too. Stops are start-aligned only.
  - Breaking inside an overlong word is opt-in (`break_words`, CSS
    overflow-wrap: anywhere): a first segment that does not fit on a line
    of its own breaks at the last grapheme boundary that fits, taking at
    least one grapheme, and both edges are reshaped as at an unsafe
    opportunity. Max-content widths are unchanged.
  - Justified alignment widens a line's word separators (U+0020, U+00A0,
    U+3000) equally until its content fills the width, on every line but
    a paragraph's last, which goes at the start (CSS text-align-last:
    auto); glyphs and caret stops after each separator move with it. A
    text node whose lines are justified or chosen by total fit lays out
    again for every width instead of reusing a layout built for another.
  - Tab stops align start, center, end, or decimal (a character,
    '.' by default, at the stop; without one the text ends there). Text
    after a center, end, or decimal stop is measured to the next tab or
    the end of its paragraph: word processors measure to the end of the
    line, which is not known while lines are being chosen.
  - Hyphenation: Liang's algorithm over hyph-utf8's patterns, kept only
    where the pattern file's licence is MIT, BSD, or as permissive
    (`src/text/hyphenation/README.md`: English US and British, German
    1996, French, Spanish, Dutch, Portuguese, Polish, Ukrainian, Slovak;
    American English is under the FSF all-permissive notice, which
    permits copying and modification with the notice kept, like MIT).
    The patterns are embedded and parsed per language the first time
    text in it is hyphenated (`text.hyphen.Hyphenation`, one per
    application in `ui.Fonts`), with the hyphenmins their headers give.
    A text's language finds them by its tag, its language and region,
    British English for British-spelling regions, else its language's
    first patterns. Applications add patterns for other languages, which
    also replace built-in ones (`siv_app_add_hyphenation`). Words are runs
    of letters, marks, and apostrophes; points fall on grapheme
    boundaries. A line broken at one ends with U+2010 (else a hyphen-
    minus) from the face before the break, after the line's last caret
    stop and in the cluster of the grapheme before it, so it is shown,
    never text: PDF copies the word whole. Only left-to-right runs
    hyphenate. The greedy breaker takes a point in the word that did not
    fit as the last opportunity that fits, as CSS hyphens: auto does.
  - Total-fit breaking (`optimal_breaks`, for document views) is Knuth
    and Plass's, by dynamic programming over every opportunity between
    forced breaks, quadratic in the opportunities of a paragraph with an
    early exit once lines overflow. Interword spaces stretch by half
    their width and never shrink (justification only widens them, and
    ragged lines must fit); a line's adjustment ratio is its room over
    its stretch plus 3% of the width, so lines without spaces are worse
    the looser they are instead of all tied at TeX's capped badness (a
    first line of one hyphenated syllable tied with a loose line of
    words); badness 100 |r|³, demerits (10 + badness)² plus 50² for a
    hyphen and 3000 for consecutive hyphens; a paragraph's last line is
    free. A word no break makes fit gets a line of its own. Breaks are
    chosen with tabs at their shaped advance and placed at their stops;
    `break_words` applies to greedy breaking only. No fitness classes.
  - Not yet built: hyphenation in right-to-left text and Knuth–Plass's
    fitness classes and looseness.
  - Text nodes (`src/ui`) reuse a `Layout` built for another width when its
    lines would break the same way (its widest line fits and it was built
    at least as wide), and align lines in the node themselves, so a node
    that shrinks to its text needs one layout. A node's style can be
    overridden over ranges by spans (D22's styled text); each run of
    equal span style is a style run of the paragraph.
  - Besides the font cache, `ui.Fonts` remembers the fallback chain per
    query (family, weight, slant, width, language), since sorting fonts
    on every reshape costs milliseconds, and per size for chains with an
    opsz axis. It holds font ids, not fonts; the chains are dropped when
    a family changes, and the sized ones when a font finishes loading
    (it may turn out to have an opsz axis).
  - Families of fonts the application adds (`siv_app_add_font`,
    `text.family`): every face of the data (each face of a collection)
    joins the named family, or the family its name table gives
    (typographic family, else font family) when the name is empty. Each
    face describes itself from its data (`text.font.Description`):
    weight (OS/2 usWeightClass), width (usWidthClass), italic (fsSelection
    or macStyle), slant (post italicAngle), and for variable fonts the
    wght, wdth, ital, slnt, and opsz axis ranges. A query ranks a
    family's faces by CSS Fonts 4 font matching (width, then slant, then
    weight, a variable face covering its whole range; ties keep the
    order faces were added in, so faces of one style added for different
    scripts form a fallback chain) and instances each for the style:
    axes set to the requested values (clamped; an italic or oblique
    request uses ital=1, else slnt at -14 degrees, CSS's oblique angle),
    synthetic bold when the request is semibold or bolder and the face
    stays lighter than semibold (as browsers do), and a synthetic oblique
    when the face cannot slant at all. The whole family stays in the
    chain, best first, so a grapheme the chosen face lacks still finds a
    face of the family.
  - Instances are faces of their own in the font cache
    (`FontCache.instance`): the base's bytes, other axis values, or
    synthetic styles, created once and found again by value, with their
    own content key for glyph caches. Synthetic styles are baked into the
    instance's HarfBuzz font (`hb_font_set_synthetic_bold`, not in place,
    and `hb_font_set_synthetic_slant`), so shaping advances, outlines,
    extents, and color paint all carry them, and every consumer that
    draws from the font (the CPU glyph cache, which the Vulkan renderer
    uploads from, outlines drawn as paths, PDF, D19) shows the same
    glyphs. Bold adds 1/24 em of stroke horizontally and vertically and
    widens advances by as much: FreeType's FT_GlyphSlot_Embolden
    strength, which Cairo and Pango use. The oblique shear is tan 14°,
    CSS's default oblique angle. Fontconfig fonts keep Fontconfig's own
    matching; its synthetic-style rules (FC_EMBOLDEN and the FC_MATRIX
    shear from 90-synthetic.conf) become the same instance styles.
  - Optical size: every ready face with an opsz axis (added or from
    Fontconfig) is instanced at the run's size in logical pixels after
    text scaling, as CSS's font-optical-sizing does with CSS pixels,
    rather than in points (OpenType's nominal unit; 1 pt = 4/3 px, D29)
    or device pixels: the design's size should follow the size the
    reader is asked to read, which the output scale does not change, and
    browsers set it the same way, so fonts tuned for the web look as
    their designers tested them. Sizes are rounded to 1/64 px, clamped to
    the axis, and the axis default needs no instance.
  - Weights in text styles are the named steps (thin to black) or any
    CSS weight from 1 to 1000 (`weight_value`), which a variable face's
    wght axis takes as it is; spans keep the named steps.
- **Alternatives:** Pango (GLib dependency, blocking font load, single-threaded
  layout objects); libraqm (no wrapping or fallback); Parley (Rust toolchain);
  kb_text_shape (no cluster mapping, so no editing).
- **Reverse if:** the engine cannot reach Pango-level correctness on the
  shaping and bidi test corpora.

### D14. Glyph rasterization without FreeType

- **Requirement:** identical CPU and Vulkan output, color glyphs, variable fonts.
- **Decision:** glyph outlines and COLRv1 paint go through HarfBuzz's draw and
  paint APIs into siv's coverage rasterizer, shared with paths. CBDT/sbix emoji
  decode through the image module (D19). Glyphs are cached by face, glyph, pixel size, and 1/4-
  pixel horizontal phase; Vulkan uploads CPU-rasterized coverage. Without
  hinting, baselines (and ideally x-heights) snap to pixels, small sizes get
  slight stem darkening, and text coverage gets a contrast correction. No LCD
  subpixel antialiasing.
  - The glyph cache belongs to the renderer and keys on the text engine's
    face content hash, so it never needs invalidation when faces are
    recreated. Color glyphs also key on the foreground color.
  - COLRv0/v1 paint lowers into a display list that the CPU renderer draws
    into a 16-bit bitmap; Vulkan uploads the same bitmaps. CBDT/sbix PNGs
    arrive through the same paint callbacks and decode through the D19
    image module (`render_cpu` imports `image`), straight to their device
    size, box-filtered in linear light; one wuffs serves both.
  - At 32 px and below the x-height is scaled vertically to a whole pixel,
    rounding up from a fraction of 0.375 as FreeType's autohinter does
    (−8% to +12%). Stem darkening adds 0.25 px of stroke at 10 px and below,
    falling to none at 18 px.
  - Evaluation, October 2026: Inter 4.1 and Noto Sans at 11–13 px on a 1×
    output, against FreeType (the font's hinting and the light
    autohinter) and a GTK 4.22 app on headless sway with GTK's default
    rendering (hintslight, grayscale, subpixel positions). siv kept even
    spacing and sharp one-pixel stems where FreeType's hinted spacing is
    uneven; its dark text carried 1.06–1.28× GTK's ink (visible coverage
    summed over a strip) and looked good. Light text looked dim and soft
    at 11–12 px, most in Noto Sans: the
    D11 table assumed black behind it, and Noto Sans at 12 px rounded its
    x-height from 6.43 down to 6 px where GTK rounds it up to 7. The
    table now assumes #181818 and the x-height rounds up from 0.375
    (it used to round to nearest, within ±8%), which lifts light text to
    1.16–1.27× GTK's ink, the same as dark text, and gives Noto Sans at
    12 px GTK's x-height in both schemes (its dark text goes from 1.06×
    to 1.23×, in line with the other sizes). Stem darkening stays: it
    applies to every foreground, and more of it would make dark text
    heavier. Advances and line widths are unchanged.
  - Runs under rotation, skew, non-uniform scale, or above 256 px draw their
    outlines as paths; color glyphs lose their colors there.
  - Synthetic bold and oblique (D13) arrive in the face's HarfBuzz font,
    so the glyph cache draws them like any face, keyed by the instance's
    own key, with stem darkening and x-height snapping on top. The
    Vulkan renderer uploads the same bitmaps, so both renderers match
    (`test/golden/render/families.png`, including a rotated run drawn as
    outlines).
- **Alternatives:** FreeType with hinting.
- **Reverse if:** a side-by-side comparison with FreeType-hinted text (Inter and
  Noto at 11–13 px on 1× displays) shows unacceptable softness that the
  mitigations cannot fix.

### D15. Editor

- **Requirement:** caret, selection, IME composition, and grapheme/word movement
  without duplicate text state.
- **Decision:** the editor builds on the text `Layout`: cluster map, break data,
  and bidi levels. IME uses `text-input-v3`; xkbcommon compose sequences work
  without an IME. Masked fields keep values in locked, dump-excluded memory with
  no undo or IME.
  - The editor node (`src/ui/editor.zig`) stores only its text, caret,
    anchor, and caret affinity; movement, hit testing, and selection
    rectangles come from the `Layout`. Arrows move visually, Ctrl+arrows
    by words, Home and End to the line's edges in reading order, Up and
    Down keep a preferred x. A single-line editor scrolls its text to
    keep the caret in view and drops line breaks from typed text.
  - User edits commit through their own transaction and then send the
    editor a `change` event. User input is never lost: input that arrives
    while the application holds a transaction open, and input queued
    behind it, waits and is replayed in order at the start of the next
    frame, before layout.
  - Undo and redo (Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y) keep up to 100 steps
    per editor. Typing merges into one step per word, and runs of
    Backspace or Delete merge; undo restores the selection the edit
    replaced. The history belongs to the text it was recorded on: each
    text change bumps the editor's revision, and text the application
    sets makes the history stale, so it is dropped.
  - Masked editors keep their text in their own mmap'd pages, locked
    (`mlock`), excluded from core dumps (`MADV_DONTDUMP`), wiped in forked
    children, and zeroed before unmapping; edits assemble the new text in
    such pages, and queued key events are zeroed after replay. They show
    one bullet per code point, so offsets index the bullets. No undo, no
    word-wise movement or deletion (it would reveal word breaks), and the
    semantics tree exposes neither the value nor caret offsets. A memlock
    limit too small for the text is an allocation failure.
  - The focused editor roots a layer whose child layer holds the caret,
    so moving the caret is a transform. Each caret change shows it solid
    and starts a compositor opacity animation that blinks for the
    desktop's blink timeout and ends visible, so an idle window makes no
    wakeups (D25). The cycle and timeout come from the desktop settings
    (D19, GTK's 1.2 s for 10 s by default); with reduced motion, or
    blinking turned off, the caret does not blink.
  - Input methods (`src/ui/ime.zig`, `src/platform/TextInput.zig`): when
    a seat's text input enters the window and a non-masked editor has
    focus, the window enables it and, after each frame, sends what changed
    (surrounding text of up to 1000 bytes each side of the selection,
    caret and anchor, multiline hint, caret rectangle in surface
    coordinates) through `Host.text_input`, which the application runs on
    the compositor thread with `Compositor.post`, in order with layer
    commits (D8). The platform collects preedit, commit, and deletion until
    `done` and queues them as one event, splitting commits longer than 128
    bytes at character boundaries (a preedit that long is cut, since it
    is only shown). Commits and deletions edit the editor and join its
    undo history like typing; the preedit is shaped inline at the caret,
    underlined, and is never part of the text. Editing keys that still
    arrive while the input method composes are ignored; a click resets
    the preedit. Masked editors keep the input method disabled.
  - A double click selects the word (UAX #29 segment) under the pointer,
    a triple click its paragraph, and dragging after either extends by
    whole words or paragraphs. Presses count as one multi-click within
    the desktop's double-click time (D19, 400 ms by default) and 4 px; no
    portal backend exposes a distance, so that stays a toolkit default.
    Pointer events report the count to handlers. Masked
    editors select everything on a double click.

### D16. Input

- **Requirement:** every Linux input device behaves correctly.
- **Decision:** the core event model covers high-resolution scrolling with axis
  source, touch, tablet tools and pads (`tablet-v2`), pinch/swipe/hold gestures,
  xkbcommon with compose, `text-input-v3`, pointer constraints and relative
  motion on request, and keyboard-shortcut inhibition on request. Kinetic
  scrolling is implemented in the toolkit using the scroll-stop event.
  - Wheel events that carry only high-resolution steps (`v120`) scroll
    15 logical pixels per detent, wl_pointer's legacy axis value, in the
    compositor and the UI alike (`platform.Scroll.delta`).
  - Key text omits C0 control characters and DEL; the keysym identifies those
    keys. A key that continues or cancels a compose sequence is delivered
    with `composing` set and no text, so shortcuts still see it.
  - Routing (`src/ui/input.zig`): pointer events go to the topmost
    hit-testable node (or the node a button press went to, until release)
    and bubble to the root until a handler returns true; keyboard events
    start at the focused node. Unhandled events get default actions: a
    primary press focuses the nearest focusable ancestor, a release over
    the pressed node activates it, Tab and Shift+Tab move focus in tree
    order (logical, so the same in RTL), Enter and Space activate the
    focused node, and arrow and page keys scroll the nearest scroll node.
    Touch drives the primary pointer until gestures exist.
  - Focus moved by the keyboard shows a ring drawn by the core (2 px,
    outside the node), so keyboard-only use works without widget code;
    focus from a pointer press shows none. Its color is the theme's
    `focus_ring` (D29).
  - Modal nodes (`SIV_SEMANTICS_MODAL`, dialogs) contain focus: the
    active one is the shown modal node made modal last; while it exists
    the pointer reaches only its subtree, Tab cycles inside it, nodes
    outside cannot take focus (`siv_node_focus` refuses them), and keys
    with nothing focused go to it. A modal node that appears without
    focus inside takes it (its first focusable node) after the commit.
    When focus enters a modal node from outside, the node that had it is
    remembered on a stack, and when the modal node goes (removed, hidden,
    or no longer modal) focus returns to it, with the ring it had, if it
    can still take focus. Nested dialogs unwind in order. The stack lives
    in the core, not the dialog widget, so it works however the dialog
    is closed.
  - Pointer cursors: each node may set a cursor shape (the CSS names, as
    cursor-shape-v1 numbers them, and hidden), inherited by descendants
    that set none; enabled editors show the text cursor. The cursor is
    that of the node the pointer is captured by (a press keeps a split
    handle's resize cursor while the pointer leaves it) or over. A
    window-wide override wins over every node, for busy states. The UI
    resolves it after pointer input, commits, and frames (the tree can
    change under a still pointer) and sends the platform a change only.
  - The platform keeps a cursor per window and shows it on every
    pointer enter: through cursor-shape-v1 when the compositor offers it
    (version 2's shapes fall back to copy and move on version 1),
    otherwise from the XCursor theme (`src/platform/xcursor.zig`, a parser
    with a fuzz target, and the theme search path with `Inherits`) at the
    desktop's theme and size (D19) times the window's scale: the closest
    nominal size, shown at the theme's logical size through a viewport
    (an integer buffer scale without viewporter), animated with the
    file's delays. Shapes a theme lacks show its arrow. Themed cursors
    load on first use per shape and pixel size, on the compositor thread:
    measured (Debug) 60–150 µs for Adwaita's arrow, text, and 60-frame
    wait cursor through the `default` theme's inheritance, so it does
    not go to the worker pool unless a theme proves slower.
  - Client-side decorations resize from edge nodes that set a resize
    cursor and call `siv_window_begin_resize` (or `begin_move`) from a
    pointer down handler, with that press's serial.

### D17. Windows, popups, decorations, external content

- **Requirement:** native window behavior on every major compositor, and
  embedding of video and app-rendered GPU content.
- **Decision:**
  - Server-side decorations when `xdg-decoration` offers them; fully featured
    client-side decorations otherwise (shadows, resize edges, input regions,
    window menu). Applications may opt into client-side for header-bar layouts.
  - Every menu, tooltip, and combobox is an `xdg_popup` with positioner
    constraints and grabs.
    - A popup is a window of its own (`Platform.createPopup`,
      `Compositor.createPopup`) with its own layer tree and its own
      `ui.Window`; its configure reports where the compositor placed it.
      A grab, taken for the press or key that opened it, gives it the
      keyboard; when the compositor dismisses it (`popup_done`), it gets
      `close_requested`, and the dismissing press goes nowhere else.
    - Compositors differ in two ways the coordinator (`src/app`) evens
      out. xdg_popup gives the topmost grabbing popup keyboard focus, but
      sway (1.12) keeps sending keys to the toplevel during the grab, so
      keys and modifiers for a window go to its topmost grabbing popup,
      which gets a keyboard enter if it never had one (GTK does the
      same). And a compositor dismisses a grab only for presses on other
      clients' surfaces, so a press on the application's own toplevel,
      newer than the press the grab was taken for, dismisses its
      grabbing popups topmost first and goes nowhere else, nor does its
      release; a press on a popup of the chain (a hover-opened submenu)
      is delivered.
    - `ui.Window.popupPositioner` anchors a popup to a node with logical
      placements: `below` (menus: start edge, flip up, slide sideways,
      shrink), `beside` (submenus: end edge, flip to the start side), and
      `tooltip` (centered below). In RTL they mirror.
    - In the C API (D22), `siv_popup_create` makes a popup window with its
      tree and `siv_popup_show` maps it, sized to its content unless a
      size was given; its `close_requested` arrives at the popup's
      `on_event`.
    - The headless backend places popups with the same rules
      (`platform.positioner.place`: flip, then slide, then resize, per
      axis) against its output and simulates grab dismissal; the sway
      integration tests check real placement, and a menu test there opens
      a menu with a real click, drives it and a submenu (opened by keys
      and, without a grab, by hover) with a virtual keyboard, and
      dismisses it with a click on the toplevel.
    - A popup whose anchor moves (a completion list following the caret,
      a menu whose button scrolled) is moved with a new positioner
      (`Compositor.repositionPopup`, `xdg_popup.reposition`, in order with
      commits); the new placement arrives as a configure. A positioner
      can be `reactive`, so the compositor places the popup again when the
      parent moves or resizes. Both need `xdg_wm_base` 3; on older
      compositors a popup keeps its first placement, so the caller closes
      and reopens it if the move matters.
  - External GPU content is a scene node. When the node is axis-aligned,
    rectangularly clipped, and opaque or topmost, it is promoted to a subsurface
    (zero-copy, `wp_viewporter`, compositor color management). Otherwise its
    dma-buf is imported as a texture. Embedders can receive a `wl_surface*` for
    their own Vulkan, EGL, GStreamer, or libmpv rendering.
    - Built so far, for CPU frames: a producer creates an external slot in
      a window (`Compositor.createExternal`) and submits opaque XRGB8888
      frames in shared memory (`setExternalFrame`, from any thread; the
      compositor duplicates the fd and maps it). The UI's `external` node
      roots a layer and places the slot in its content box
      (`Op.set_external`), fitted to the content's aspect ratio.
    - Each frame the compositor finds every placement's surface rectangle
      and promotes it when the layer's transform is axis-aligned with
      positive scale, its opacity is 1, and its clips are rectangles.
      Promoted frames go to a synchronized `wl_subsurface` as a wl_shm
      buffer from the producer's own memory (no copy), scaled with
      `wp_viewport` and cropped to the clips through its source rectangle.
      If nothing painted later overlaps it, the subsurface is above the
      window. If something does (video controls), it goes below the window
      and composition punches a hole: the window is cleared to transparent
      over the visible part (a `src`-blend layer), so the opaque frame
      shows through and the later content composites over it there.
      Rounded or rotated clips, other transforms, and opacity composite the
      frame as an image (`bgrx8_srgb`). Changing modes redraws the layer.
      A new frame that changes only a subsurface costs a bare commit, not a
      present. Replaced frames are released (`Event.external_released`)
      after the next frame.
    - Embedders that render themselves (EGL, Vulkan WSI, GStreamer, an
      application drawing libmpv's GL output) get a `wl_surface*` of their
      own and the `wl_display*` (`Compositor.createExternalSurface`), on a
      synchronized `wl_subsurface` placed like any external. siv owns its
      position, stacking, and `wp_viewport`; the embedder owns its buffers.
      - Size: `Event.external_configure` gives the placement's logical size
        and the buffer size to render (times the window's scale); the
        embedder renders a frame of that size soon after, even if nothing
        else changed, because the viewport scales whatever it attaches.
      - Frames: after committing one, the embedder calls
        `externalSurfaceCommitted` with its buffer size, from any thread;
        the window's next frame commits (a bare commit if nothing else
        changed), and only then does the synchronized frame show and its
        frame callback fire, so a swap interval of 1 paces itself to it.
        Synchronized rather than desynchronized so that moves, crops, and
        resizes apply in the same commit as the UI around them.
      - When the viewport's source or destination changes, siv commits the
        embedder's surface itself (the state is cached until the window's
        commit). That commit can fall between the embedder's attach and
        commit on its thread; it only ever completes a finished frame
        early, provided embedders attach finished frames of the size they
        were told.
      - Nothing shows outside the window or its clips. The window's
        bounds clip every external placement (shm frames too), and clips
        crop through the viewport's source rectangle, snapped inward to
        wl_fixed's 1/256 grid. That needs a frame of the configured size:
        a source outside the embedder's buffer is a protocol error. A
        placement that needs cropping stays unmapped until the embedder
        reports such a frame, including after each new size; an uncropped
        one shows at once, scaled to whatever frame it has. Rotated and
        translucent placements are cropped on their bounding box and go
        below the window with a hole at full opacity. It is shown in one
        place only.
      - Hidden placements destroy the `wl_subsurface` role, which unmaps
        the surface without touching its buffer; showing it again creates
        the role anew.
      - Threads: the display is the compositor thread's connection, which
        reads with `wl_display_prepare_read`, so other threads may use it
        through an event queue of their own (`wl_display_create_queue`, a
        proxy wrapper of the display, `wl_display_dispatch_queue`), as
        Mesa's EGL and Vulkan do. Embedders must never dispatch or
        round-trip the default queue, and must not set a listener, a
        viewport, or a buffer scale on the surface.
    - dma-buf frames: a producer submits a dma-buf instead of shared
      memory (`ExternalFrame.dmabuf`; in C, `siv_external_frame_desc`'s
      `memory`, `modifier`, `drm_format`, and `planes`): a DRM fourcc and
      modifier and one to four planes, whose fds the compositor
      duplicates.
      - Readiness: a frame becomes current only once its implicit fences
        signal. The compositor thread watches the dma-buf in its loop
        (a dma-buf polls readable when its writes are done) and keeps
        showing the previous frame meanwhile, so neither it nor a renderer
        waits on the producer's GPU and nothing needs a sync_file. A newer
        frame replaces one still pending, which is then released unshown.
      - Promotion: as for shared memory, plus the Wayland compositor must
        take the format and modifier: the platform reads linux-dmabuf
        default feedback's format table and tranches
        (`Platform.supportsDmabuf`) and creates the wl_buffer with
        `create_immed` (a buffer the compositor advertised but still
        cannot import is a protocol error, as with Mesa's WSI). Any format
        the compositor takes is promoted, YUV included.
      - Release: a promoted frame is in use until the compositor lets go,
        which can be after siv replaces it (scan-out, or a repaint still
        reading it), so it is released only when every wl_buffer made from
        it has had `wl_buffer.release` (`Event.subsurface_released`,
        `Platform.dmabufBusy`). Each wl_buffer is attached once: showing a
        frame again after hiding it makes a new one, so a release always
        ends one attachment (re-attaching a buffer whose release may be in
        flight would make the release ambiguous).
      - Composited (not promotable, or a format the compositor does not
        take): the Vulkan renderer imports it (D10). Without Vulkan, the
        CPU renderer reads it through a mapping only when it is linear,
        single-plane XRGB8888 (bracketed by `DMA_BUF_IOCTL_SYNC`). Any
        other dma-buf (tiled, YUV, or another RGB format) is not drawn
        there, is still released as usual, and is logged once. Rejection
        rather than readback: reading tiled or YUV layouts on the CPU
        means detiling each vendor's modifiers and converting color, and
        mappings of device memory read at a fraction of RAM speed; the
        windows that hit it are the rare ones without Vulkan whose
        compositor will not take the buffer either.
      - Verified on the headless backend (`compositor/tests.zig`): a
        linear dma-buf is read like shared memory, a tiled one is not drawn
        but released, a format the compositor takes is promoted, a frame
        with pending writes waits for them (a pipe stands in for its
        fences), and promoted frames are released after the compositor's
        release. Verified on sway 1.12 headless with its Vulkan and GLES2
        renderers on a Radeon 760M (`SIV_SWAY_RENDERER=vulkan zig build
        test-integration`; pixman sway offers no `zwp_linux_dmabuf_v1`),
        with udmabuf frames: linear XRGB8888 from the format table is
        promoted through `create_immed` without protocol errors; a frame
        gated by a vgem fence imported as its write fence
        (`DMA_BUF_IOCTL_IMPORT_SYNC_FILE`, as Mesa's WSI does) stays off
        screen until the fence signals (200 ms in the test) and shows
        within a millisecond after; and with sway stopped (SIGSTOP), a
        replaced frame stays in use until sway runs again and releases
        it. A translucent placement composites through the Vulkan
        renderer's explicit-modifier import there too.
    - Not yet: external nodes in the C API.
  - Fractional scale, preferred buffer scale, output hotplug, `xdg-activation`,
    idle inhibit, `xdg-dialog`, toplevel icons, and session restore.
    - Built: xdg-foreign-v2 exports of toplevels (portal dialog parents,
      D19) and xdg-activation-v1 tokens and activation. Sway marks an
      activated window urgent unless `focus_on_window_activation focus`;
      the integration test sets it.

### D18. Accessibility

- **Requirement:** screen readers (Orca), magnifiers, and keyboard-only use work
  in every application.
- **Decision:** a semantics tree is mandatory: every widget declares a role.
  siv implements AT-SPI itself over its D-Bus implementation, including text,
  value, action, and selection interfaces, live-region announcements, and caret
  tracking. Tests query the semantics tree.
  - Primitives default to a role (containers `generic`, text `label`,
    scroll `scroll_area`, image `image`). Role `none`, and `generic` nodes
    that are neither labelled nor focusable, are left out of the semantics
    tree with their children promoted. Buttons, links, checkboxes, list
    items, and similar roles without a label take their name from their
    descendants' text.
  - Focusability and disabled state are semantic properties, so a node
    cannot take focus without the information a screen reader needs.
  - The tree is rebuilt in full after frames that changed structure,
    layout, semantics, text, or focus; AT-SPI change events will diff it.
    `semantics.Tree.generation` counts rebuilds, so an unchanged tree is
    skipped without diffing. Headings (and tree items) carry a `level`.
  - Text and editing for the Text and EditableText interfaces
    (`ui.access`): character rectangles, the offset at a point, and visual
    line ranges, in window coordinates with byte offsets into the node's
    text (an editor's preedit is shown but not counted, and its scrolling
    applies); and replace, select, copy or cut, and paste-at for editors.
    The edits take the user's path, so they are undo steps with change
    events, and they queue behind an open application transaction like
    input (D15). Masked editors have neither. Copies carry the serial of
    the window's last input, which a compositor may refuse when the
    window has had none. Text attributes (GetAttributes,
    GetAttributeRun) report the style run at an offset with GTK's names
    (family-name, weight, style, stretch, size in points, underline,
    strikethrough, fg-color), only what the run changes from the node's
    style, and what the paragraph style changes from the node's
    paragraph defaults (justification, left-margin, right-margin, indent,
    pixels-above-lines, pixels-below-lines, with start and end resolved
    by the node's direction); a run ends where either changes. Line
    spacing and tab stops are not reported. Default attributes stay
    empty.
  - The bridge (`src/a11y`, `a11y.Bridge`) follows org.a11y.Bus on the
    session bus and connects to the accessibility bus only while
    org.a11y.Status IsEnabled or ScreenReaderEnabled is set, so an
    application nobody inspects pays nothing ($AT_SPI_BUS_ADDRESS
    overrides discovery). It embeds itself in the registry with
    Socket.Embed and drops everything when accessibility turns off.
  - All objects are one D-Bus subtree registration (D19). The application
    is `/org/a11y/atspi/accessible/root`; a node is
    `.../<window>_<node>_<generation>`, resolved from the path on each
    call. A node's generation changes when it leaves the tree, so a
    recycled node index never answers for an old object. The application
    also exports org.a11y.atspi.Cache, so libatspi reads the whole tree
    with one call.
  - The application coordinator (`src/app`) starts the bridge on its
    session bus connection (D19) at creation, adds each window with its
    title, calls `update` after each of its frames, forwards title
    changes and activation from configures, and removes the window when
    it is destroyed. The headless backend never publishes, so tests stay
    independent of the desktop; `zig build test-integration` checks the
    wiring end to end against the real registry and libatspi.
  - Each window keeps a snapshot of what it last published. The
    application calls `update` after each frame of the window; when the
    tree's generation changed, the bridge builds a new snapshot, diffs it
    (children, names, descriptions, roles, states, values, text, caret,
    selection, live regions), emits the events, and swaps. Calls are
    answered from the snapshot, so answers and events agree. Removals
    are reported before additions; a reorder without a change of children
    sends nothing.
  - Interfaces per node: Accessible and Component always; Action for
    nodes with an activate handler (one action, named like GTK's for the
    role: click, toggle, jump, activate); Text for text nodes, editors,
    and text roles; EditableText for unmasked enabled editors; Value for
    nodes with a range, whose MinimumIncrement is the semantics' step and
    whose CurrentValue is writable: setting it sends the node a
    `set_value` event (`ui.input.setValue`), which a widget applies
    clamped and stepped (D22) or refuses, and the change reaches the
    client through the next update like any other; Selection for lists,
    trees, tab lists, menus, tables, and combo boxes, where selecting a
    child activates it. Modal nodes have the modal state.
  - Roles follow ARIA's AT-SPI mapping where siv's roles are ARIA's;
    switches are toggle buttons, since the switch role (at-spi2-core 2.56)
    is newer than current registries and screen readers. Text offsets are
    characters, converted from siv's UTF-8 byte offsets.
  - Events: ChildrenChanged, PropertyChange (name, description, role,
    value), StateChanged (focus gained after every loss), TextChanged,
    TextCaretMoved, TextSelectionChanged, TextAttributesChanged (a
    snapshot keeps a hash of each text node's spans and paragraph styles;
    a new hash over the same text sends it, while styles that move with
    an edit are part of its TextChanged), and Announcement for a live
    region whose text changes or that gains content, with live and
    container-live attributes on the region. Window Activate and
    Deactivate come from the application (`setActive`, from the
    toplevel's activated state), as do titles (`setTitle`) for windows
    whose root has no label.
  - Coordinates: a Wayland client does not know where it is on the
    screen, so screen coordinates are window coordinates, as in GTK 4.
    Magnifiers that follow the caret get its rectangle in the window
    from Text.GetCharacterExtents.
  - Verified (`zig build test-integration-a11y`) against at-spi2-core
    2.46's bus launcher and registry with libatspi (pyatspi) as the
    client: discovery through IsEnabled, the tree with roles, names,
    states, and interfaces, actions, focus, text and extents, editing,
    values, and checked, focused, text, caret, and announcement events.
    Orca 43 on headless sway turns accessibility on, the bridge joins by
    itself, and Orca speaks "Orca test frame.", "OK push button.", and
    "Remember check box not checked." for activation and focus changes
    (read from its debug log; a stub stands in for X's xkbcomp, which
    Orca 43 calls at startup).
- **Alternatives:** AccessKit's Linux adapter (adds a Rust toolchain).
- **Reverse if:** AccessKit offers a C build without Rust and covers every
  interface listed above.

### D19. Desktop integration

- **Requirement:** applications behave correctly under Flatpak and follow
  desktop settings.
- **Decision:**
  - D-Bus is implemented natively on the event loop.
    - `src/dbus` imports only `loop`. A connection is a loop source whose
      io handler only reads bytes and fds; the dispatch task (a safe
      point, D5) validates messages in place and runs reply callbacks,
      signal subscriptions, and method handlers. Writes are queued and
      sent with one sendmsg per batch from the prepare hook (a send
      outside an iteration wakes the loop), and up to 32 of their buffers
      are reused, so steady traffic allocates nothing (a test holds the
      connection to that). Reading pauses above 8 MiB of
      undispatched bytes, and one dispatch handles at most 128 messages
      so frames run between bursts.
    - Calls are asynchronous only: a blocking call would stall the UI
      thread. Each call gets one callback with the reply, an error reply,
      or a failure (timeout, disconnect, fds refused); one timer per
      connection covers the 25 s default timeouts.
    - Received messages are validated in full once, like dbus-daemon
      does, and then decoded as borrowed slices of the receive buffer
      without copying or allocating. Outgoing messages are checked too
      (names, required fields, body against signature as it is written),
      so a bus never disconnects siv for an invalid message.
    - Authentication is SASL EXTERNAL with the uid as the initial
      response, pipelined with NEGOTIATE_UNIX_FD, BEGIN, and Hello, so a
      first call costs one round trip. Only unix sockets (paths and
      abstract names): TCP can neither pass fds nor use EXTERNAL.
    - Exported objects are static interface tables registered by
      pointer. One registration can serve a whole subtree through a
      lookup function that resolves a node from its path, and lists
      children for introspection; this is how AT-SPI (D18) publishes a
      tree of any size with no per-node state in the connection. The
      connection implements Introspectable, Properties (with
      PropertiesChanged), and Peer, and checks argument and reply
      signatures against the declarations.
    - Subscriptions are match rules sent to the bus (without waiting for
      the reply) and applied locally; a rule naming a well-known sender
      follows the name's owner, since signals carry the unique name.
    - Measured (ReleaseFast, dbus-daemon 1.14, both ends on one loop):
      20 000 pipelined calls in 0.41 s, of which siv spent 0.2 s of CPU
      for 80 000 message sends and dispatches; a sequential round trip
      through the daemon takes 0.1 ms; a reply of 1000 `(so)` structs
      encodes in 0.1 ms and validates and decodes in 0.05 ms.
    - Not built yet: ObjectManager and serving peer-to-peer
      connections.
  - Settings come only from the portal (color scheme, accent, contrast, reduced
    motion, text scale, fonts, cursor theme and size, double-click time,
    caret blinking), applied live, with built-in defaults when no portal
    runs.
    - The client (`dbus.Settings`) reads with ReadAll and follows
      SettingChanged from the portal's owner only. The standardized
      org.freedesktop.appearance keys come first; the other settings have
      no standard key, so GNOME's org.gnome.desktop.interface and
      org.gnome.desktop.a11y.interface keys (which the GNOME and GTK
      portal backends expose) come next, with
      org.gnome.desktop.peripherals.mouse for the double-click time, then
      KDE's fonts (org.kde.kdeglobals.General) and its double-click
      interval and caret blink rate (org.kde.kdeglobals.KDE, sent as
      strings; a rate of 0 turns blinking off); KDE's portal exposes no
      cursor or text scale. No portal backend exposes a double-click
      distance; it stays a toolkit default (D15).
    - Defaults: no color scheme preference, no accent, normal contrast,
      motion allowed, text scale 1, `sans-serif` 11 pt for UI and
      document text, `monospace` 11 pt, cursor theme `default` at 24 px,
      double click within 400 ms, the caret blinking with a 1.2 s cycle
      for 10 s after input (GTK's defaults). Out-of-range values (text
      scale outside 0.25–8, cursor size outside 8–512, accent components
      outside 0–1, double-click time outside 100–5000 ms, blink cycle
      outside 100–10000 ms, blink timeout outside 1 s–1 day) count as
      unset.
    - The settings are read again when the portal starts or restarts;
      when it goes away the last values stay. The first read reports
      `ready` even if nothing changed, so the application can decide when
      to show its first frame.
    - The application owns one session bus connection and one Settings
      client, started at application creation in parallel with the
      Wayland connection. The first frame waits for `ready`, at most
      100 ms (a portal being activated can take far longer), so a
      dark-theme user never sees a light first frame. The typical cost
      must fit D25's 20 ms first-frame budget: measured (`zig build
      test-integration-dbus`, `SIV_MEASURE=1`) from connecting to the
      session bus to the portal's answer through dbus-daemon, the median
      is 0.3 ms (ReleaseFast) to 0.7 ms (Debug), and the test fails above
      20 ms. A round trip to a real xdg-desktop-portal 1.16 (without a
      settings backend) took 0.4–0.5 ms in the same setup.
    - The UI follows the settings through `ui.Desktop` (reduced motion,
      accent color, text scale, double-click time, caret blink cycle and
      timeout, color scheme, contrast, and the UI font's size), whose
      fields have the names of `dbus.Settings.Values` and their types or
      enums with the same tags, applied per window with
      `ui.Window.setDesktop`: a text scale change reshapes text, theme
      changes repaint (D29), and carets restart their blink. The accent
      draws focus rings and focused selections through the theme; without
      one the toolkit's blue stays. An application's own reduced-motion
      flag applies whatever the desktop says.
    - `src/app/desktop.zig` starts the bus connection and the Settings
      client in `App.create` before the compositor connects to Wayland,
      copies the values into every window's `ui.Desktop` (new windows
      start with them) on the first read and on every change, and makes
      the desktop font the default family of the shared `ui.Fonts`,
      unless the application chose one (`siv_app_set_default_font`), as
      its reduced-motion flag also wins. A new default family or text
      scale reshapes text in the default family and measures and redraws
      canvases, whose text follows the text scale too (D28).
    - First frames wait by holding the compositor's frame events: a
      window whose frame arrives before the settings is asked for a frame
      again once they are ready, 100 ms after `App.create` passed, or the
      bus disconnected. Without a session bus nothing waits. The headless
      backend does not read the settings (tests stay independent of the
      desktop); `SIV_APP_NO_DESKTOP_SETTINGS` opts a Wayland application
      out.
    - Measured end to end (`zig build test-integration`, `SIV_MEASURE=1`;
      headless backend, private dbus-daemon, a stand-in portal on its own
      thread), from `App.create` to the first presented frame: median
      3.5 ms with settings against 3.0 ms without (ReleaseFast), 8.3 ms
      against 7.9 ms (Debug); the settings are ready 2.8 ms (7 ms) after
      `App.create`, mostly because they are read in the first dispatch
      after the application has created its window. A portal that never
      answers delays the first frame to 100–102 ms. The test fails above
      20 ms of CPU time for the process, which is what the first frame
      costs siv: with four busy loops beside the test, its wall time grows
      to 25–33 ms while its CPU time stays at 8–11 ms (Debug).
    - The color scheme, contrast, accent, and font size drive the theme
      (D29); the cursor theme and size go to the platform for themed
      cursors (D16).
  - Portals for files, URIs, notifications, printing, screen capture, global
    shortcuts, and the document portal. No built-in file chooser: the portal is
    the system chooser.
    - The clients are their own module, `src/portal` (imports `dbus` and
      `loop`), on the application's session bus connection; `src/dbus`
      stays the protocol and the Settings client. They work the same in
      Flatpak and outside it; what differs is handled in one place each
      (below).
    - Requests (`portal.Request`): the client picks `handle_token`, so the
      request path (/org/freedesktop/portal/desktop/request/SENDER/TOKEN)
      is known before the call, and subscribes to its Response first,
      with the portal's name as sender, so no response is missed or
      spoofed. A call made before the bus answered Hello waits for the
      unique name. If a portal replies with another path (before 0.9),
      the subscription moves there. Cancelling sends Request.Close. Error
      replies that mean the service, interface, or method is missing are
      `unavailable`; other errors and a lost bus are `failed`. Sessions
      (screen cast, global shortcuts) are the same with
      `session_handle_token` and Session.Closed.
    - Parent windows: "wayland:<handle>" from exporting the toplevel with
      xdg-foreign-v2 (`Platform.exportToplevel`), made on the compositor
      thread the first time a window needs one and kept for the window's
      lifetime rather than per dialog (GTK unexports after each dialog;
      the handle is an unguessable token, and one export per window costs
      nothing more). Without the protocol, for popups, and without a
      window the parent is "", and the dialog is just not modal. A window
      destroyed while its export is on the way releases the waiting
      requests with "". The headless backend exports "headless-<id>".
    - Local files open by descriptor: `siv_open_uri` sends a file:// URI
      to OpenFile (or OpenDirectory for show-in-folder) with an O_PATH fd,
      O_RDWR when writable, because the portal refuses file URIs from
      sandboxed applications and checks the fd's writability.
    - Application ids: inside Flatpak (/.flatpak-info) the portal knows
      it. A host application with an id (`siv_app_desc.app_id`) sends
      org.freedesktop.host.portal.Registry.Register (xdg-desktop-portal
      1.19 and later) right after connecting, before the Settings read,
      since Register must precede every other call; older portals' errors
      are ignored, and they derive the id from the systemd scope.
    - Activation tokens: requests that open another application
      (OpenURI) carry an xdg-activation token for the window's last key or
      button serial, so the opened application may take focus
      (`Platform.requestActivationToken`).
    - Notifications: actions are application actions (`siv_app_add_action`,
      shared with org.freedesktop.Application, see Lifecycle), sent as
      "app.<name>", GLib's convention, which desktops that activate
      applications over D-Bus expect; ActionInvoked strips the prefix.
      Targets are strings. Version 2 keys (display hints) are sent only
      when the portal's Notification version, read at startup, allows
      them: version 1 portals refuse unknown keys.
    - Inhibit lasts until the handle is destroyed, which closes the
      request. The portal answers only once the desktop applied it and
      never when it allowed none of the flags, so nothing waits for it.
    - Screen casts hand the application the PipeWire remote fd and the
      streams' node ids and geometry; siv does not link PipeWire. Restore
      tokens round-trip through the descriptor and a getter.
    - Global shortcuts bind through one session per handle; triggers the
      desktop describes are kept per shortcut and updated on
      ShortcutsChanged.
    - Documents: `siv_document_export` registers a file (AddFull) with
      permissions for another application and reports its path in the
      document portal's mount.
    - C API: one-shot requests (OpenURI, screenshot, pick color, document
      export) take a `siv_portal_fn` that receives a `siv_portal_result`;
      the file chooser, inhibitions, global shortcuts, and screen casts
      are handles built up and then shown or started. Callbacks never run
      inside the call that started the request: without a session bus
      (the headless backend has none) the result is `unavailable` at the
      next dispatch. Destroying the application cancels pending requests
      and runs their destroy-notifies, before the windows go so that no
      request starts during teardown.
    - Verified (`zig build test-integration-portal`, and the C API on
      sway): Debian's xdg-desktop-portal 1.16 with
      xdg-permission-store, a PipeWire daemon, and a backend of siv's own
      implementing the impl interfaces, so the frontend's option
      validation and forwarding are real: file chooser options and
      results, cancellation, screenshots and colors, OpenURI launching a
      .desktop handler for URIs and for files by fd, show-in-folder
      through org.freedesktop.FileManager1, notifications with
      ActionInvoked forwarded back, inhibition released by Request.Close,
      global shortcut sessions and Activated, and a screen cast to a real
      PipeWire fd. On sway the backend receives "wayland:<handle>" from a
      real xdg-foreign export. 1.16 drops OpenFile's current_folder
      (version 4 of the interface, 1.18) and has no Registry. The
      hermetic tests use a stand-in frontend on the test bus.
  - Clipboard and drag-and-drop negotiate MIME types, support primary
    selection, stream through the event loop, and enforce configurable size
    limits.
    - The platform keeps each seat's wl_data_device and primary selection
      device on the compositor thread; offers announce their mime types
      before becoming the selection, and this client's sources forward
      send requests as `selection_send` events carrying the fd. The UI
      reaches the platform through `ui.Clipboard.Host` (run with
      `Compositor.call`).
    - `ui.Clipboard` is one per application. Copies keep the data and
      offer the text types (UTF-8 first, then the X11 names); pastes take
      the first text type the offer has. Pipes are non-blocking and
      streamed by the UI loop's io phase, and finished pastes are
      delivered in the dispatch phase (D5). Pastes over the limit (16 MiB
      by default) are dropped; invalid UTF-8 becomes U+FFFD and NULs are
      removed. While the application owns a selection, pasting it uses the
      data directly. A reader that closes its pipe early must not end the
      application with SIGPIPE, and a library must not change the
      process's signal dispositions: each write blocks SIGPIPE on its
      thread and takes back one it raised, so it fails with EPIPE.
    - Editors copy with Ctrl+C and Ctrl+Insert, cut with Ctrl+X and
      Shift+Delete, paste with Ctrl+V and Shift+Insert, and paste the
      primary selection with the middle button at the pointer. A non-empty
      selection in the focused editor becomes the primary selection once
      per frame. Masked editors never copy. A paste is one undo step, and
      waits behind an open transaction like input; single-line editors
      turn line breaks into spaces.
    - Applications copy and paste with `siv_clipboard_write`, which
      offers text with the window's seat and latest input serial (Wayland
      grants a selection only for input, so it is called from an input
      handler), and `siv_clipboard_read`, whose text arrives in the
      dispatch phase like an editor's paste. A paste that completes
      inside the call (this application owns the selection, or nothing is
      offered) is posted, so the callback never runs inside
      `siv_clipboard_read`; one still waiting at teardown runs only its
      destroy-notify (D5). The Lua binding awaits it in a coroutine (D23).
    - Drag and drop (`src/ui/dnd.zig`): the platform keeps each seat's
      drag offer (the offer over one of this client's surfaces) with a
      per-seat id, and this client's drag source with its icon surface,
      on the compositor thread; the UI names offers by id in
      `Compositor.post` requests (accept, receive, finish), so a request
      for an offer that is gone does nothing. A compositor may report the
      drag leaving after the drop; the platform keeps the offer until
      the UI finishes it.
    - Drop targets are nodes with a `DropTarget` (mime types, one per
      line and preferred first; actions; a preferred action) and a `drop`
      handler. A drag goes to the nearest drop target under the pointer,
      from the topmost node up, whose types and actions meet the
      drag's; that node alone sees `enter` and `move` and takes the drag
      by returning true. A node that refuses does not pass the drag to
      its ancestors: the nearest target that can take the data decides,
      as a list decides between its rows. Drop events do not bubble.
      Editors take text without a target of their own (unless masked or
      disabled): the text goes in at the drop point, sanitized like a
      paste, as one undo step.
    - The answer (the type, the node's actions, its preferred action)
      goes to the source on every change; the compositor's choice comes
      back as `drag_actions` and is delivered as another `move`. On a
      drop siv reads the whole payload in the node's type through a
      pipe on the UI loop, up to the clipboard's limit (one limit for
      pastes and drops, `siv_app_set_transfer_limit`), and then delivers
      `drop` with the bytes; a drop over the limit, or one whose node
      went away, is refused and the node hears `leave`. Streaming large
      drops to the application waits for one that needs it. A drop that
      completes while a transaction is open waits for the next frame,
      like input. A taken drop finishes with the negotiated action;
      with `ask` the application asks the user and calls
      `Window.finishDrop` (`siv_drop_finish`), and a new drag over the
      window refuses a drop still waiting.
    - Drags start from a node while a button or touch press on its
      window is held (`Window.startDrag`, with the press's serial; the
      node that had the press gets a pointer `cancel`, since the
      compositor sends no release). The data, copied, lives in the
      clipboard for the drag's life and is written to whoever asks; its
      node gets `drag` events (the target under the pointer and the
      action, the drop, and the end with the action performed, after
      which a move deletes the data). Icons are `ui.Image`s at one image
      pixel per logical pixel; rendering a node into an icon waits for
      a renderer the UI thread can use.
    - Drags this client starts and drops on itself skip the pipe: the
      offer is marked `own` and the data comes from the clipboard. In-app
      drags (`in_app`) still use a real wl_data_source, offering only a
      private mime type, rather than a source-less drag: other clients
      see a type they never take and never get data, and the end of the
      drag is reported however it ends (a source-less drag dropped
      outside the client reports nothing).
    - The headless backend simulates other clients' drags, this client's
      drags following injected pointer input across its windows, and
      drops on other clients; the sway integration test drags between
      two clients with the virtual pointer.
  - Lifecycle: `org.freedesktop.Application` activation and single instance.
    - The application id (`siv_app_desc.app_id`, reverse DNS, the
      .desktop file's name) is the bus name and, with dots as slashes and
      dashes as underscores, the object path (`portal.application`).
      Setting one connects the session bus on any backend, headless too.
    - `siv_app_launch` asks for the name without queueing. The owner is
      primary: it serves Activate, Open, and ActivateAction, and unless
      launched by D-Bus activation it activates itself (or opens its
      URIs) at the next dispatch, never inside the call. An instance that
      finds the name taken is secondary: it forwards Activate or Open,
      with its activation token, and `siv_run` returns
      (`SIV_ERROR_UNAVAILABLE` if the primary did not answer). Without an
      id, a bus, or with `SIV_LAUNCH_MULTIPLE_INSTANCES`, every launch is
      primary. The application creates its windows in `on_activate`, as
      with GApplication, so a secondary never shows one.
    - Asynchronous like every D-Bus call (above): the instance is known
      when the name request answers, so `siv_app_get_instance` reports
      `pending` until then, rather than a blocking register call.
    - Actions: ActivateAction runs the application actions notifications
      use (portals, above), with the first parameter if it is a string.
    - Activation tokens: the launcher's $XDG_ACTIVATION_TOKEN goes with
      the first activation (or is forwarded) and is removed from the
      environment so children do not reuse it; remote activations carry
      platform data's "activation-token" (or X11's "desktop-startup-id").
      `siv_window_activate` hands it to xdg-activation; for a window not
      mapped yet the platform holds it until the first buffer, since
      compositors ignore activating unmapped surfaces.
      `siv_window_request_activation_token` gets one for applications the
      application starts itself.
    - Services: D-Bus activation starts the process through the D-Bus
      service file's Exec line; siv cannot see the command line, so the
      application passes `SIV_LAUNCH_SERVICE` when its own argument says
      so, and then waits for the desktop's call. `idle_timeout_ms` ends a
      service that shows no window after an activation.
    - Desktop files: for D-Bus activation, install
      `org.example.App.desktop` with `DBusActivatable=true` (keep `Exec`
      for launchers that ignore it) and a D-Bus service file
      `$datadir/dbus-1/services/org.example.App.service`:

      ```ini
      [D-BUS Service]
      Name=org.example.App
      Exec=/usr/bin/example --service
      ```

      Desktop actions (`[Desktop Action quit]`) of a DBusActivatable
      application are invoked as ActivateAction with the action's name,
      so name them like the application actions. `StartupNotify=true`
      tells launchers to pass an activation token. Windows use the
      application id as their app id, which compositors match against
      the .desktop file.
    - Verified (`zig build test-integration`): a C program
      (test/c/lifecycle.c) started by dbus-daemon's activation when GLib's
      gdbus calls Activate, answering Open and ActivateAction without
      activating itself; launched twice, the second forwards its URI and
      token and exits while the first opens it. Hermetic tests run two
      applications on the test bus.
  - Printing and PDF export: a PDF writer lowers display lists (D9), and
    printing goes through the Print portal.
    - The writer is its own module, `src/pdf` (imports `scene`, `raster`,
      `render_cpu` for the shadow contract, `harfbuzz_subset`, and `text`
      in tests). PDF 1.7 with Flate streams and a cross-reference table;
      the same input writes the same bytes (the ID is a hash of the
      content). Pages are in points with y down from the top-left corner,
      like display lists.
    - Layers: transforms and clips are q/cm/W; opacity, blend modes, and
      forced isolation make a transparency group (a form XObject) drawn
      with an ExtGState. The W3C blend modes keep their PDF names; the
      Porter-Duff modes other than source-over draw as Normal, since PDF
      has no destination operators.
    - Gradients: linear and radial become axial and radial shadings
      whose function stitches linear segments, six per stop interval,
      each end the exact color the renderers compute there (premultiplied
      linear light, then sRGB), so only the error between samples
      remains; repeat and reflect are unrolled over the painted area (up
      to 256 periods), and alpha is a luminosity soft mask. Sweeps are a
      Coons patch mesh of 96 wedges.
    - Text: each font is embedded once, as a HarfBuzz subset of the glyphs
      the document uses (variable fonts instanced at the variation the
      text was shaped with), as a Type0 font with Identity-H encoding
      whose codes are the original glyph ids: TrueType as CIDFontType2
      with a CIDToGIDMap, CFF as an OpenType CIDFontType0 with retained
      glyph ids. The ToUnicode map comes from the runs' cluster data; the
      first glyph of a cluster maps to the cluster's whole text (so a
      ligature copies as its letters), the others to nothing. CFF2 and
      fonts without outlines draw as paths; color glyphs print as their
      outlines. Faces with synthetic bold or oblique (D13) draw as paths
      from the same HarfBuzz outlines the renderers rasterize, so print
      and screen agree, with the embedded subset as invisible text (render
      mode 3) over them for search and copy; an embedded font program
      would print the face without its synthetic style, and fill-and-
      stroke (render mode 2) with a skewed text matrix only approximates
      HarfBuzz's emboldening. The vendored build compiles HarfBuzz's subsetter sources
      next to the amalgamated core, and -fsys=harfbuzz links the system
      libharfbuzz-subset.
    - Images keep their alpha as a soft mask and their filter as
      /Interpolate; dma-buf frames (D17) have no pixels to read and are
      left out. Box shadows are an image of the blur from
      render/cpu/shadow.zig at two samples per point, clipped exactly to
      outside (inset: inside) the casting shape. Backdrop blur is left
      out: a page's backdrop is paper.
    - PDF composites in its blending color space, DeviceRGB, which is
      sRGB-encoded, not in linear light like the renderers (D11), so
      translucent paints over other content print darker than on screen
      (gradient stops themselves match). A linear-light blending space
      would match, but only Ghostscript honors it (measurements in D9).
    - C API: `siv_print_desc` describes a document for both
      `siv_pdf_write` (to a file descriptor, A4 by default) and
      `siv_print`: an optional `begin` that lays out for a
      `siv_page_setup` (paper size and margins in points, as oriented)
      and returns the page count, `draw_page` with the canvas drawing
      functions (D28), and `done` with a `siv_portal_result`. Pages are
      drawn at a dispatch, never inside the call. Text drawn while a font
      is still loading draws every page again once fonts load (three
      passes at most). The descriptor's language and direction
      apply to the pages' text; by default they are the window's when
      printing from a window, else the application's (D21). Pages use the light variant of the
      theme (paper is white) and ignore the desktop's text scaling.
      `margin` gives siv_pdf_write's page setup margins, so exported and
      printed layouts can match. A page whose drawing fails is blank, as a
      canvas would be.
    - Printing: PreparePrint shows the system's dialog (with no settings
      or page setup to start from); its response's page setup is
      GtkPageSetup's serialization, paper size and margins in millimeters
      for the portrait paper plus an orientation, which siv turns into the
      oriented page (landscape: wider than tall, its top the paper's left
      edge, as GtkPrintContext rotates). The PDF goes to Print in a memfd
      with the dialog's token. siv draws every page; the print system
      applies copies, page ranges, and n-up from the settings the
      portal's backend kept with the token.
    - Verified: `zig build test-integration-pdf` checks a page of every
      construct with qpdf --check, pdftotext, pdffonts (embedded, subset,
      ToUnicode), and colors probed in pdftoppm's rendering; on sway
      through xdg-desktop-portal 1.16 with the test backend, `siv_print`
      gets a landscape page setup and the PDF the backend receives passes
      qpdf and pdftotext. Hermetic tests read the structure, fonts, and
      ToUnicode maps back.
  - System tray (StatusNotifierItem) is an optional module.
    - `src/tray` (imports `dbus` and `loop`): optional at run time rather
      than at build time, so the ABI is the same everywhere: nothing is
      exported until the application creates an item. One item per
      application (`SIV_ERROR_BUSY` for a second): the specification
      fixes its object path, /StatusNotifierItem, and one connection
      cannot export two objects there.
    - The item asks for org.kde.StatusNotifierItem-<pid>-<n> and registers
      that name with org.kde.StatusNotifierWatcher; if the name cannot
      be had (a Flatpak sandbox may not allow owning it) it registers its
      object path, which watchers pair with the sender's unique name. It
      follows the watcher's owner and registers again whenever a watcher
      appears; `unregistered` events (no watcher, it left, or it refused)
      let the application show itself another way.
    - Properties use the specification's change signals (NewIcon,
      NewTitle, NewToolTip, NewStatus), not PropertiesChanged. Icons are a
      themed name, an image (sent as ARGB32 in network byte order), or
      both. KDE's ProvideXdgActivationToken is kept for the next Activate,
      whose event carries it for `siv_window_activate`. WindowId is 0
      (X11 only); overlay icons and attention movies are left out.
    - The menu is com.canonical.dbusmenu version 3 at /MenuBar: entries
      by application-chosen id with a parent id, kinds normal,
      separator, check, and radio, and disabled, hidden, and checked
      states. Changes bump the layout revision with one LayoutUpdated per
      dispatch; AboutToShow always answers that nothing changed, since
      the menu is kept current. Only `clicked` events reach the
      application.
    - Verified: hermetic tests with a stand-in watcher on the test bus
      (registration by name, watcher restarts, refusal, every host call,
      the layout's wire form); `zig build test-integration` reads the
      item through dbus-daemon with GLib's gdbus (introspection,
      GetAll, GetLayout, Event, Activate), also through the C API.
  - Images: wuffs (PNG, JPEG, GIF), libwebp, libavif with dav1d, libjxl.
    Decoding is async and decodes to the displayed size.
    - `src/image` (`image.decode`) takes a whole file and returns frames;
      `ui.Image.load` runs it on the worker pool (reading a path there
      too) and delivers the image in the dispatch phase (D5), and
      `siv_image_load` exposes that with a callback and destroy-notify.
      Every decoder sits behind a small C interface of siv's own
      (`src/image/*.h`), so `-fsys` builds (lcms2, libwebp, libavif,
      dav1d, libjxl) and vendored ones share siv's code; the shims also
      build against Debian 12's older libavif 0.11 and libjxl 0.7.
    - Vendored builds: wuffs is built once, here, and also decodes the
      CPU renderer's bitmap glyphs (D14); dav1d builds with meson's generated headers written by the build;
      libavif uses the part of libyuv it
      bundles; libjxl builds its decoder with Highway, without the boxes
      and JPEG reconstruction that need Brotli and without a CMS, since
      it renders XYB to linear sRGB itself and siv converts ICC profiles.
      The decoders' internal memory comes from the C allocator, as
      HarfBuzz's does; decoded pixels come from siv's allocator (D2).
    - dav1d's assembly is on for x86-64 and aarch64 (other targets use
      its C). x86-64's is NASM syntax: NASM 2.16.03 (BSD-2-Clause) is a
      pinned lazy dependency, its release tarball (which carries the
      files its perl scripts generate) compiled by Zig for the build
      machine with a configuration written in `build_steps.zig`, and run
      once per `.asm` file; aarch64's is GNU syntax that clang assembles.
      No system assembler, perl, or meson is involved, so the build stays
      reproducible, and nothing is fetched for other targets or with
      `-fsys=dav1d`. The aarch64 build passes `test-image` under
      qemu-user (`-Dtarget=aarch64-linux-musl -fqemu`) but was not timed.
    - Measured with `zig build bench-image -Doptimize=ReleaseFast --
      FILE...` (one thread, whole decode to pixels including libavif's
      YUV to RGB, best of 15) on this orb's x86-64 (AVX2), October 2026,
      before and after the assembly: a 1920×1080 4:2:0 still 100 → 42 ms,
      the same at 4:4:4 142 → 32 ms, a 3840×2160 10-bit 4:2:0 still
      590 → 287 ms, a 60-frame 1280×720 sequence 1455 → 1219 ms. The
      inputs were ffmpeg's `mandelbrot` source with `noise=alls=12`
      (stills) and its zooming `mandelbrot` with `noise=alls=8` (the
      sequence), encoded by libaom at CRF 28 and 32. After the
      assembly most of a sequence's time is libavif's portable YUV to
      RGB conversion (for a 60-frame 1280×720 `testsrc2` sequence siv
      takes 1030 ms, of which ffmpeg with the system dav1d needs 205 ms
      to decode the AV1): libavif uses libyuv's SIMD
      paths when built with all of libyuv, which siv does not vendor
      yet; that is the next step for AVIF speed.
    - Size: images larger than the bounds the caller gives (logical
      pixels times the window's scale, which then divides the pixel size
      into the image's logical size) are scaled down frame by frame while
      decoding, by area averaging in premultiplied linear light, so only
      the displayed size is kept; never up. Peak memory is one canvas at
      the file's size: none of these decoders scales while decoding
      except libwebp, and DCT scaling of JPEGs waits for a decoder that
      offers it. Limits: 64 megapixels per frame and 512 MiB files; an
      animation keeps at most 32 MiB of decoded frames, or streams
      (below).
    - Color (D11): an embedded RGB ICC profile converts through Little
      CMS to linear light with sRGB primaries, unless it is sRGB (matrix
      and curves within rounding), which keeps 8-bit pixels as they are;
      gray and CMYK profiles are ignored. AVIF and JPEG XL color given as
      CICP converts by transfer function (sRGB, BT.709, gamma, linear,
      PQ, HLG) and primaries (BT.2020 and Display P3 to sRGB). PQ and HLG
      map reference white (203 cd/m²) to 1 and clip above it, and wide
      gamuts clip to sRGB, until HDR and wide-gamut output exist. 8-bit
      sRGB images at their own size stay `rgba8_srgb`; everything else
      is `rgba16_linear_premul`.
    - Animation (GIF, APNG, WebP, AVIF sequences, JPEG XL): frames are
      decoded at the displayed size, composited by the decoder. When all
      of them fit 32 MiB (`image.Options.max_bytes`; the count comes from
      the file's headers without decoding: wuffs and libjxl read only
      frame headers, libwebp and libavif report it) they are decoded up
      front and kept, so loops cost nothing. Longer ones stream: the load
      decodes only the first frame and keeps the file, and every image
      node showing it plays it through its own `ui.Player`, an
      `image.Decoder` on the worker pool that keeps two frames decoded
      ahead of the one shown and decodes the file again for each loop.
      Each streamed frame is an image of its own, so display lists keep
      alive only what they draw, and memory stays at those frames, the
      two ahead, and one canvas at the file's size, however long the
      animation. A frame not decoded in time holds the one shown until
      it arrives (playback slows, frames are not skipped). Per-node
      players keep nodes independent (each starts at its first frame
      when shown), at the cost of decoding once per node.
    - Image nodes play animations on a timer of the window's loop that
      fires only when a frame changes, repainting only the node's layer;
      delays of 10 ms or less show for 100 ms, as in browsers; a finite
      loop count ends on the last frame. With reduced motion an
      animation shows its first frame, as canvases always do, and
      streamed ones decode nothing more.
    - The fuzz target (`zig build test-image --fuzz`) feeds every decoder
      through `decode`. Zig's fuzzer only reads coverage from Zig code
      (clang's PC table for C does not match the one it expects), so the
      C decoders run uninstrumented: crashes and undefined behavior in
      them are caught (ReleaseSafe traps it in C too), but coverage does
      not guide mutation inside them; their upstreams fuzz them on
      OSS-Fuzz. wuffs builds without `-fsanitize=function`, which traps
      its type-erased vtable calls, and dav1d's `qm.c` without
      array-bounds checks, on which clang crashes. Not yet: progressive
      display while loading, and a test of an animated JPEG XL (ffmpeg
      here writes only still ones).
  - Icons follow the freedesktop icon theme specification, rendered by siv's
    SVG parser for the subset icon themes use.

### D20. Internal handles and module boundaries

- **Requirement:** internal code stays simple and fast.
- **Decision:** generation-checked handles exist only at the ABI boundary;
  internal code uses plain indices. The application coordinator only sequences
  phases; subsystems never move into it. The headless platform backend runs the
  same loop as Wayland.
  - The coordinator is `src/app`: an `App` owns the UI loop, the worker
    pool, the fonts, the clipboard, and the compositor; a `Window` pairs a
    platform window with a `ui.Window`, and runs its text-input requests
    on the compositor thread (D8). Compositor events arrive in the dispatch
    phase and go to the window they name; close requests and configures
    also go to the window's listener. A destroyed window gets no events
    from then on, but its `ui.Window` lives until the compositor has
    released every display list it holds, no event for it is being
    delivered, and the loop has run since (the next dispatch or event
    delivery), so a handler may destroy its own window and the caller of
    destroy, such as the C API tearing down handles, may still use it.
  - `src/abi` adds only what C needs on top: handles, descriptors, the
    sticky error, and C callbacks. Both stay thin: tree, layout, input,
    and presentation logic never move into them.
- **Alternatives:** ourokit's generation checks everywhere and a coordinator
  that grew to 21.8k lines.

### D21. Internationalization

- **Requirement:** translators use standard tooling; formatting follows the
  locale.
- **Decision:** siv's own gettext `.mo` reader, CLDR plural rules and
  locale-aware number and date formatting generated from CLDR data, RTL
  mirroring of the whole UI (start/end everywhere, mirrored icons), and locale
  language tags passed into shaping.
  - Every horizontal property is logical: padding, insets, corner radii,
    alignment, flex rows, grid columns, and scroll offsets. Nodes inherit
    the window's direction unless they set their own.
  - Text aligns by its node's direction, so an English label in an RTL
    window is flush right; each paragraph's bidi base direction is still
    detected from its text, defaulting to the node's direction.
  - Image nodes can mirror in RTL (directional icons).
  - The application has a language and a direction (`siv_app_desc.language`,
    the `ltr`/`rtl` flags, `siv_app_set_language`): by default the
    process locale's ($LC_ALL, $LC_MESSAGES, $LANG, as gettext reads
    them) and the direction its language is written in (by script
    subtag, else by language: Arabic, Hebrew, Persian, Urdu, ...). The
    headless backend reads no locale, so tests do not depend on the
    environment. Windows that set no language or direction of their own
    follow the application's, also when it changes: their text shapes
    again with the new language tag and their layout mirrors. Popups take
    their parent window's when created. Printed documents default to the
    window they are printed from, else to the application (D19). AT-SPI's
    Application.GetLocale reports the application's language as a POSIX
    name ("ar-EG" is "ar_EG"; "C" when there is none), following
    `siv_app_set_language` (D18).
  - Canvas text (`siv_draw_text`) aligns the same way: each paragraph's
    base direction comes from its text for bidi ordering, but start and
    end alignment follow the canvas node's direction (a page's, when
    printing).

### D22. Stock widgets

- **Requirement:** applications in every language get a complete widget set.
- **Decision:** stock widgets are written in Zig using only public primitives:
  buttons, text fields and areas, styled-text editor, virtualized list, tree,
  table, and grid with selection models, menus, popovers, dialogs, tabs, split
  panes, sliders, spin buttons, progress, toasts. Theming uses compiled design
  tokens plus runtime overrides, follows the portal accent and color scheme, and
  includes a high-contrast variant (D29). Animation respects reduced motion.
  - **The boundary is enforced by the build.** `src/widgets` imports only
    `siv`, the generated Zig wrapper of the C ABI (D3); its exports are
    schema functions like any other, checked against the schema by
    `src/abi/abi.zig`. A stock widget therefore can do nothing that a
    widget written in C, Lua, or Rust against `siv.h` cannot. When a widget
    needs something the API lacks, the capability becomes a public
    primitive first. Primitives added this way: hidden nodes
    (`SIV_VISUAL_HIDDEN`), modal nodes (`SIV_SEMANTICS_MODAL`), the value
    step, editor placeholders, transitions, themed colors and text sizes
    (D29), default handlers and default layouts, `siv_emit`, node data,
    tree navigation (`siv_node_get_related`, `siv_node_get_window`,
    `siv_node_get_label`, `siv_node_is_rtl`), `siv_txn_fail`, one-shot
    timers, popups (D17), the `set_value`, `select`, `close`, and
    `viewport` events, and semantics for items not all in the tree
    (`level`, `position`, `set_size`, `row`, exposed as AT-SPI's
    posinset, setsize, and rowindex attributes), node animations
    (`siv_set_animation`), the key-repeat timing
    (`siv_app_get_key_repeat`), text spans with formatting commands, and
    a column header's sort order and a cell's column (`sort` and
    `column`, AT-SPI's sort and colindex attributes, as browsers expose
    aria-sort and aria-colindex).
  - **Creating:** one builder per widget, a transaction operation like the
    primitive builders (D27): `siv_button(txn, parent, &desc)` appends the
    widget and returns its root node, or 0 once the transaction has failed
    (sticky errors, D4; a widget reports its own invalid arguments with
    `siv_txn_fail`). The root is an ordinary node: layout, `siv_move`,
    `siv_remove`, and semantics overrides apply to it, and removing it
    removes the widget. Parts that hold several items are built item by
    item with child builders (`siv_radio` under a radio group), so items
    are nodes too and no descriptor needs an array of strings, which the
    schema cannot express. Text fields and areas return the editor node
    itself, so every editor function (text, selection, change events)
    works on them unchanged.
  - **Driving:** a few functions cover every widget instead of setters per
    widget kind: `siv_widget_set_label`, `siv_widget_set_disabled`,
    `siv_widget_set_value` and `siv_widget_get_value`, and
    `siv_widget_set_range`. A widget's value is one double: 0 or 1 for
    toggles (0.5 is mixed), the chosen index for choices, the number for
    ranges. They are transaction operations, so a value change lands in
    the same frame as the tree changes around it.
  - **Events** go through `siv_on` on the returned node, as for
    primitives: `activate` for buttons, `change` with `value` (and `index`
    for choices) when the user or assistive technology changed the value,
    `select` with `index` for menus and views. Setting a value from the
    application does not report it.
  - **Behavior lives in default handlers.** A widget installs its pointer,
    key, activate, focus, and `set_value` handling with `siv_on_default`,
    which runs only when the node has no `siv_on` handler of that type or
    it returned false. So `siv_on` stays the application's on every node,
    a stock widget never takes a handler slot away from it, and an
    application overrides a behavior by returning true. Widgets report
    their own events with `siv_emit`, which runs the same two slots.
  - **Layout defaults.** `siv_set_layout` replaces a node's whole layout
    (D27), which would wipe a widget's padding and least sizes the moment
    an application positions the widget. So a node can also have a
    default layout (`siv_set_default_layout`): fields its layout leaves
    zero take the default's (a size is one field, padding goes side by
    side, flags combine). Widgets put their metrics there and the
    application's `siv_set_layout` adds to them. Visuals stay the
    widget's: it restyles them on hover, press, and state changes.
  - **State lives with the node.** `siv_set_data` gives a node zeroed
    memory under a caller-chosen key, from the application's allocator
    (D2), freed with the node or when the transaction that made it aborts;
    `siv_node_get_data` finds it again from the handle. Widget handlers
    get that memory as their user data and need no destroy-notify.
  - **Keyboard, semantics, RTL:** every widget root is focusable with the
    ARIA role of its kind (a radio group is a `group` of `radio`s, a switch
    a `switch`), takes its name from its label text (D18), and exposes its
    checked, pressed, selected, or value state. Arrow keys follow WAI-ARIA
    practice and swap in right-to-left layouts (`siv_node_is_rtl`); layout
    is logical (D21), so positions mirror without widget code. Widgets
    with a value accept `set_value`: assistive technology sets a range's
    value through AT-SPI's Value interface, which the bridge forwards
    (D18), clamped and stepped by the widget like a key press.
  - **Held buttons repeat like held keys.** A spin button's decrement
    and increment buttons step on press and, while held, again after the
    seat's key-repeat delay and then at its rate, stopping on release,
    leave, cancel, or at the range's end. The timing is the compositor's
    `wl_keyboard.repeat_info`, which the platform reports as an event and
    `siv_app_get_key_repeat` exposes, so widgets written in C repeat the
    same way; it is a query, not a desktop setting pushed into windows,
    since only widgets that start a repeat need it. The press is handled,
    so the release does not activate the button as well; activation
    stays for assistive technology.
  - **Popups and overlays.** Menus and popovers are popups (D17) made
    with the public `siv_popup_create`; dialogs and toasts are overlays
    in the window's own tree.
    - A popup is created with its tree but mapped only by
      `siv_popup_show`, so that its content exists first and it can size
      to it (the root measured with loose constraints, at most the
      parent's width): the platform needs a popup's size when it is
      created. Showing takes the grab with the parent's last press or key
      serial, so it is called while handling that input; destroying a
      window destroys its popups first, and popups do not keep the
      application running.
    - A menu is a model in the tree (`siv_menu`, or the one inside a
      `siv_menu_button`): a node that takes no space with one hidden child
      per item, so items are nodes the application relabels, disables,
      and removes. `siv_menu_open` builds the popup from the model each
      time. Choosing reports `select` with the item's position (separators
      count) after the popup is gone; Up, Down, Home, End, Enter, Space,
      a mnemonic keysym per item, and Escape work as in WAI-ARIA's menu.
      An item can carry a submenu (another `siv_menu`), shown in a popup
      of the menu's popup, placed beside the item (flipping to the start
      side without room, mirrored in RTL). Enter, Space, a click, a
      mnemonic, or the arrow toward the end edge open it with the
      keyboard, focused on its first item; hovering the item opens it
      without a grab and without moving focus (a hover has no input
      serial to grab with), and hovering a sibling closes it. The arrow
      toward the start edge and Escape close only the submenu and focus
      its item again. Choosing in a submenu reports `select` on the
      submenu and closes the whole chain; a click outside dismisses the
      chain, since the compositor destroys a popup's children with it.
    - A popover is a popup whose root is a card with a content part.
      Dialogs are modal overlays over a parent stack (a scrim and a card
      with title, text, content, and actions parts) that take focus.
      Toasts are live regions at the bottom of a parent stack that fade.
      All three report `close` (Escape, a click outside or on the scrim,
      a timeout); the default handler closes them, and an application's
      `siv_on` handler that returns true keeps them.
    - Parts the application fills are reached with
      `siv_widget_get_part` (dialog content and actions, popover content,
      tabs and panels, split panes, a menu button's menu).
  - Tabs show one panel at a time by hiding the others, so panels keep
    their state, with roving focus and automatic activation. Split panes
    are a start pane of a set size, a divider that is a focusable
    separator with the size as its value, and an end pane taking the
    rest; the largest size depends on layout, so it reaches assistive
    technology from the first focus or move.
  - **Virtualized views** (lists, trees, tables, grids) make nodes only
    for the rows in view plus eight rows of overscan, from a pool.
    - The viewport primitive: a scroll node's `viewport` handler hears of
      its offset and size at safe points (D5): when the compositor reports
      that it scrolled (D8), and at the start of the frame after a layout
      changed its size, before layout, so rows a handler binds show in
      that frame. The compositor scrolls without waiting for the UI
      thread, so rows reach newly exposed space one UI frame later; the
      overscan hides that at ordinary speeds.
    - Rows are positioned children of a stack as tall as every row (in
      grids also inset from the start edge, so they mirror in RTL). Moving
      the range reassigns rows that left it to items that entered it and
      calls the application's bind callback inside the view's
      transaction, with a recycled flag so it updates rather than
      rebuilds. A rebind of everything (`siv_view_refresh`, a new count,
      a tree changing shape) keeps each row at its index, so focus stays
      put. Positions are arithmetic, never measured: rows of lists,
      trees, and tables have `item_height`, or each the height the
      application's height callback gives (grids keep fixed cells).
      With the callback the rows' tops are prefix sums (f64) in node
      data, rebuilt when the rows change (a new count, a refresh, a tree
      item expanding or collapsing: one call per row, linear like the
      selection bits and tree rows that change with them) and never while
      scrolling; the range in view is found by bisection, and Page Up and
      Page Down move by the view's height. The content's height is the
      sum, so the compositor scrolls variable rows as it scrolls fixed
      ones. Alternative: rows sized by their own layout (measured after
      a frame, estimated before). A row's height would be known only
      after it was laid out, so rows below it would move after the
      compositor had already scrolled them into view, needing scroll
      anchoring and showing a frame of wrong positions; applications
      that size rows by text measure it with `siv_app_measure_text`.
      Reverse if applications need rows sized by content they cannot
      measure, such as embedded widgets.
    - Selection is a bitset in node data, resized with the count (node
      data of another size replaces the old and keeps what fits); none,
      single, or multiple with Ctrl, Shift, and Ctrl+A. The cursor's row is
      the focused node (roving focus) and stays bound out of view. Trees
      keep their visible items flattened in node data, inserting and
      removing rows (and shifting selection bits) as items expand and
      collapse, asking the application's children and child callbacks
      only for items that become visible.
    - Rows carry their position among all items and the set's size (rows
      of tables their row index), since most of their siblings have no
      node. Tree items carry their position among their parent's
      children, the number of them, and their level, kept in the
      flattened rows, so a screen reader says "2 of 5, level 3".
    - A double click on a row activates it, like Enter: `siv_event`
      carries the click count of primary presses and the input's
      timestamp, so widgets written in C can do the same.
    - Table columns sort and resize. A sortable header (`siv_column_desc`
      flag) reports `sort` with the column and direction (ascending
      first, then flipping) on a click, Enter, or Space; the header shows
      the order, with an arrow and the semantics' `sort`, only when the
      application's handler returns true, so a header never claims an
      order the items do not have (`siv_view_set_sort` sets it without a
      report). Each resizable column has a handle at its header cell's end
      edge: dragging it moves the edge, and it is a separator whose value
      is the width (stepped to 8 px, at least the column's `min_width`),
      like a split pane's divider, so assistive technology resizes the
      column through the Value interface. A resized column becomes a px
      track; the others keep theirs. The user's resizes report `change`
      on the header cell (drags when released).
    - The header is one Tab stop with roving focus: Left and Right
      (mirrored in RTL) move between header cells, Home and End to the
      ends, Ctrl+Left and Ctrl+Right narrow and widen the focused column,
      Down enters the rows, and Up from the first row returns. Handles
      are not focusable: one per column would add a Tab stop per column,
      or a second roving order inside the header, and the keys on the
      header cell cover the keyboard.
    - Not built yet: column reordering and cells of their own sizes in
      grids.
  - **Styled text** is spans on the text and editor primitives, not a
    document model: `siv_set_text_spans` gives ranges of a node's text
    their own weight, slant, size, color (literal or themed), underline,
    and strikethrough over the node's style. Spans are kept normalized
    (sorted, disjoint, merged, none that change nothing). Each run of
    equal span style shapes as its own style run (D13), so a color
    change also splits shaping; decorations are whole-pixel rectangles
    under or through the run in its color. `siv_node_get_text_run` walks
    the runs, and AT-SPI exposes them as text attributes (D18).
    - Editors move spans as the user edits: inserted text takes the
      typing style, else that of the first replaced character, else
      that of the character before it, so typing at the end of a bold
      word stays bold. Undo steps keep the spans before and after, so
      undo and redo restore styles with the text. `siv_set_text` drops
      the spans when the text changes; `siv_set_text_spans` itself is
      not an undo step (an application's syntax highlighting must not
      fill the history), while `siv_editor_format`, the user's
      formatting command, is: it restyles the selection as one step
      with a change event, or with nothing selected sets the typing
      style, which moving the caret forgets. `siv_node_get_typing_style`
      tells a toolbar what typing would produce.
    - The stock styled-text editor is a text field with
      `SIV_TEXT_FIELD_STYLED`: Ctrl+B, Ctrl+I, and Ctrl+U toggle bold,
      italic, and underline, off when all of the selection (or the
      typing style) has the attribute, else on, as word processors do.
      Masked editors take no spans.
      Ctrl+L, Ctrl+E, Ctrl+R, and Ctrl+J align the selected paragraphs
      left, centered, right, and justified (left and right resolved by
      the editor's direction; its own start alignment clears the
      attribute).
    - Fonts added with `siv_app_add_font` form families whose styles are
      matched per span and synthesized where missing (D13), so bold and
      italic spans show with any font.
    - Spans also set a family and a width. A family is a `u32` from
      `siv_app_font_family` (interned names, 0 the default family), not a
      string: `siv_text_span` is a fixed-size value that arrays hold and
      `siv_node_get_text_run` returns through an out parameter, so a
      pointer in it would have no owner.
    - Paragraph styles (`siv_set_paragraph_spans`, D13's layout options)
      are ranges like spans, but each paragraph takes the style at its
      first character, and they are kept snapped to whole paragraphs
      (each separator with the paragraph it ends). The node's defaults
      come from its text style. Editors keep them through edits: text
      typed into a paragraph joins it, a line break starts a paragraph
      with the same style, and joining two paragraphs keeps the first's.
      Undo steps keep them before and after like spans, and
      `siv_editor_format_paragraph` is the user's command over the
      paragraphs a selection touches. An empty paragraph (empty text, or
      after a final line break) has no character to carry a style, so it
      shows the style of the paragraph before it and cannot be styled on
      its own; lists (bullets and numbering) are not built.
- **Non-goal:** a full document model with embedded tables and images.

### D23. Lua 5.5

- **Requirement:** hot reload and user extension, optional for C users.
  Lua code gets the whole C API with the same safety, and with what Lua
  makes pleasant: tables, closures, coroutines, exceptions.
- **Decision:** `libsiv-lua`, a separate library built on the C ABI. No ambient
  globals; APIs come from `require("siv")`.
  - **Library.** `src/lua/` builds `libsiv-lua.so`, which links
    `libsiv.so` and uses only the generated wrapper of the C ABI (the
    boundary of D22's widgets), and `siv-lua`, which runs an application
    (`siv-lua [--watch] app.lua`). libsiv-lua embeds Lua and exports
    exactly the Lua C API, `luaopen_siv`, `siv_lua_new` (a state with the
    chosen standard libraries and `require("siv")`), and `siv_lua_run`
    (runs a main chunk, with hot reload on request), under a version
    script (`SIV_LUA_0.1`). A host embeds Lua through it (`siv_lua.h`);
    it cannot bring a Lua of its own, since a `lua_State` from another
    build has another layout. libsiv-lua ships its own NOTICES, with
    Lua's licence from `lua.h` (the tarball has no licence file).
  - **Lua** is 5.5.1 from lua.org, pinned by URL and hash (lua.org's
    published SHA-256 matches). The build compiles the core and an
    explicit allowlist of standard libraries: base, package, coroutine,
    table, string, math, utf8, os, and io. Left out are the debug library
    (it reads any function's upvalues and the registry, where the binding
    keeps its state) and linit.c (it references every library).
    loadlib.c is built without dlopen, so `require` loads Lua source only
    and the allowlist cannot grow at run time. io and os are in because
    applications read files and the clock; a host embedding Lua for user
    extension leaves them out with `siv_lua_new`'s mask. `-fsys=lua`
    links the system liblua5.5 instead; its compiled set and C module
    loading are then the system's, and only what is opened stays the
    allowlist.
  - **Generated at compile time, not written.** `bind.zig` imports the
    schema (`src/abi/api.zig`, as data) and the generated wrapper, and
    generates one `lua_CFunction` per schema function, every conversion
    between Lua values and schema types, and a C trampoline per callback
    type, with comptime loops. A schema change that the rules cannot map
    fails the build; nothing drifts. `mapping.zig` holds the rules and
    the few facts the schema does not state: functions and fields left
    unbound with the reason (node data under pointer keys, wl_surface
    pointers, allocator hooks, and the external frame `release` callback,
    which runs on the compositor thread), which handles Lua owns, which
    functions construct them, and which callbacks complete an
    asynchronous call. Its tables are checked against the schema at
    compile time, so a new handle type or a struct with callbacks and no
    destroy-notify fails the build until classified. `gen_types.zig`
    writes lua-language-server annotations (`share/siv/lua/siv.lua`) from
    the same rules. Alternative: a text generator in `src/abi/gen` that
    writes C against `lua.h` (what D3 first sketched). Rejected: a
    generator writing marshaling code as strings that no compiler checks
    until it runs, two languages for one mapping, and more code than the
    comptime version. Reverse if another binding needs the mapping as
    text, or the comptime work slows the build noticeably.
  - **Names.** Every function is `siv.<name>` without the prefix and a
    method of the handle type of its first parameter without that type's
    name: `siv_window_set_title(w, t)` is `w:set_title(t)`, `siv_flex(t,
    p, d)` is `t:flex(p, d)`. Out parameters are return values; a buffer
    and its length are one string. `siv.methods.<type>` holds the methods,
    for extensions.
  - **Handles** are userdata, one per handle while Lua references it (a
    weak table maps handles to them), so they compare equal and serve as
    table keys. Applications, images, inhibitions, file choosers, global
    shortcuts, screen casts, and tray items are owned: collecting the
    userdata, leaving a `<close>` variable's scope, or `:destroy()`
    destroys the object. Windows (until closed), nodes (until removed),
    transactions, timers, external slots, and draw contexts (valid during
    `draw`) are not: a window does not vanish because Lua dropped it.
    Stale handles are safe, since siv checks generations (D2); destroying
    an application marks all its handles destroyed. A transaction in a
    `<close>` variable aborts unless committed.
  - **Descriptors** are tables. Zero is the default, as in C; unknown
    fields are errors (typos do not pass silently), read with `lua_next`,
    so fields from a metatable's `__index` do not count. Enums are names
    (`axis = "column"`) or integers; flags a name, a list, a set, or an
    integer. Value structs take named or positional fields; colors also
    take CSS hex strings, and a color table without alpha is opaque (the
    one default that differs from C's zero, since `{1, 1, 1}` meaning
    invisible would be a trap); edges, corners, and radii take one number
    for all sides; dimensions and tracks take a number as pixels; and a
    parameter of a value struct of numbers also takes its fields as
    consecutive arguments (`d:rect(x, y, w, h)`). Strings point into Lua
    strings without a copy (siv copies what it keeps, D2); byte arrays
    are strings. Builders take a trailing properties table: each key
    names a setter with one value (`layout`, `visual`, `semantics`,
    `text_style`, `text`, ...) and `on` holds handlers, so a node is one
    call.
  - **Errors.** A failed call raises a table `{ code = "busy", result =
    -6, func = "siv_txn_begin", message = "app.lua:12: siv_txn_begin:
    SIV_ERROR_BUSY" }` (`siv.is_error`); bad argument types are ordinary
    Lua errors. A builder that returns 0 raises its transaction's status,
    and setters raise too: Lua raises at the failing operation rather
    than keeping D4's sticky error to commit, since a Lua program has
    exceptions and a traceback at the cause beats one at the commit.
    `window:update(fn)` runs `fn(txn, root)` in a transaction held in a
    `<close>` variable, so an error aborts it and goes on with its
    traceback intact.
  - **Callbacks** are Lua functions in a userdata box (its user values)
    that the registry keeps until siv's destroy-notify releases it. They
    run under `lua_pcall` on the thread that made the siv call now on the
    stack (the main thread otherwise), so a Lua error never unwinds
    through siv's frames; a wrapper converts every argument before
    calling siv and raises only after siv returns. Event structs arrive as
    tables. An error in a callback goes to `siv.set_error_handler`'s
    function if set; otherwise it is kept, `siv_run` is quit, and the
    binding call that returns to Lua next (`app:run()`, `node:emit()`,
    ...) raises it, so an error in a handler ends the program with its
    traceback like any uncaught error. `siv-lua --watch` reports errors
    and keeps the application running instead. Alternative: printing and
    continuing by default (hides bugs in ordinary runs).
  - **Asynchronous calls** (image loads, portal requests and the file
    chooser, clipboard pastes) take a callback; given none, they wait in
    the running coroutine and return the result, raising a failed result
    (`local image = app:image_load{ path = p }`). Outside a coroutine,
    without a callback, they raise. `siv.spawn(fn)` starts a coroutine
    and `app:sleep(ms)` waits on a one-shot timer. The completion
    resumes the coroutine from its callback, at a safe point (D5).
  - **Hot reload.** `siv-lua --watch` (`SIV_LUA_WATCH`) runs the main
    chunk again when it or a Lua module it required changes. A thread
    blocks on inotify for their directories and, after 50 ms without
    changes, calls `siv_post`, the one call safe from any thread (D5), so
    an idle application pays nothing. The reload runs the chunk inside
    the running application: `siv.app_create` returns that application
    and `app:run()` returns at once. Applications opt in to keeping state
    with `siv.keep(key, make)`, whose value survives reloads; windows
    created inside `make` are kept with it, so their size and focus stay
    and the chunk rebuilds their content (keeping models, drafts, or
    nodes as it chooses, and registering new handlers, which replace the
    old ones). Windows the previous run created otherwise are destroyed
    once the new run succeeds; if it fails, its windows go, the old ones
    stay, and the error is reported. Modules required from files load
    again. Alternatives: swapping functions inside closures by name
    (needs the debug library, and breaks on any rename); polling file
    times on a timer (wakes an idle application).
  - **Threads.** A Lua state runs on the application's thread only;
    nothing in the binding runs elsewhere.
  - **Tests.** `zig build test-lua` runs the binding against `libsiv.so`
    on the headless backend (allowlist, errors, descriptors, ownership,
    callbacks, coroutines, the clipboard, hot reload through the real
    watcher). The headless tests (D24) run `examples/*.lua` unchanged
    through the binding compiled into their binary, with `app_create`
    wrapped to pick the headless backend, and compare golden images under
    `test/golden/lua/`, a hot reload included. On sway, the installed
    `siv-lua` copies from a key and an in-process Lua client pastes from a
    coroutine through a real data offer.
- **Reverse if:** event tables show up in profiles (then pass events as
  proxies valid during the call); applications need C modules (then
  build loadlib.c with dlopen behind an option).

### D24. Developer tooling and tests

- **Decision:** the inspector is a separate siv application that attaches over a
  socket the target opens only when an environment variable enables it (tree,
  properties, semantics, layout overlays, repaint flashing, frame timing). Tests
  run the real loop on the headless backend, compare CPU golden images, and diff
  CPU against Vulkan output. `zig build test` stays hermetic. `zig build
  test-integration` runs the Wayland backend against one real compositor, the
  latest sway on its headless backend, pinned through nixpkgs; other
  compositors are not part of the test suite. It also runs D-Bus against a
  private dbus-daemon, with GLib's gdbus as a second client, and AT-SPI
  against at-spi2-core's bus launcher and registry with libatspi as the
  client, and portals against xdg-desktop-portal with a backend of siv's
  own behind it; the hermetic D-Bus, AT-SPI, and portal tests use an
  in-process test bus over socketpairs.

### D25. Project

- **License:** MIT. Every dependency is MIT, BSD, or Apache-2.0; binaries ship a
  NOTICES file. Embedded data follows the same rule, with permissive
  notices of the same kind accepted (D13's American English hyphenation
  patterns: FSF all-permissive).
- **NOTICES** is generated by the build for the chosen options and
  installed as `share/licenses/siv/NOTICES` (`src/notices/`).
  - What ships is found, not listed by hand. The build walks libsiv's
    module graph and records every build.zig.zon package it reaches:
    sources, C and assembly files, include directories of modules that
    compile C (wuffs is a header), imports, and the steps that generate
    any of those, including the tools those steps run. zig-wayland's
    scanner copies its own code into the bindings; uucode's generator
    compiles the UCD into tables. A table in `src/notices/build_steps.zig`
    gives each package's licence files.
  - `-fsys` libraries are linked, not compiled, so their sections drop
    out. System libraries (libwayland-client, xkbcommon, Fontconfig, libc,
    and libvulkan loaded at run time) are not part of libsiv. Neither are
    the declarations translated from their headers.
  - Packages whose tools only run at build time are excluded by name:
    NASM and glslang, whose outputs (dav1d's objects, siv's SPIR-V) are not
    derived from them. Test-only fonts in `testdata/` are embedded only by
    tests and are not reached.
  - Zig's runtime ships with every build: the standard library,
    compiler-rt, and the UBSan runtime libsiv.a bundles, all under Zig's
    MIT licence. libc++, libc++abi, and libunwind ship when a compiled
    module links libc++. Their licence texts come from Zig's lib
    directory. Zig's own LICENSE is kept in `src/notices/`, since Zig's
    lib directory does not carry it. So is the Unicode License v3, since
    UCD.zip carries none.
  - Of dual-licensed packages, Highway's BSD-3-Clause is the one taken.
    Wuffs's LICENSE grants both MIT and Apache-2.0 and is copied whole.
  - The generator (`src/notices/gen.zig`) writes nothing and fails the
    build, including `zig build test`, in three cases:
    - A reached package has no section.
    - A section lacks the licence nearest to one of its compiled files:
      the first directory, going up from the file, that holds a LICENSE,
      LICENCE, or COPYING file. That catches bundled libraries with
      licences of their own, and every NOTICE file in that directory is
      required as Apache-2.0 4(d) asks. libavif's root LICENSE covers the
      libyuv it bundles.
    - A licence file in siv's own tree (outside `testdata/`) is in no
      section.
  - SheenBidi 3.0.0 has no NOTICE file, so its section is its Apache-2.0
    LICENSE.
- **Toolchain:** Zig 0.17.
- **Packaging:** every C dependency has a build option to use the system copy;
  the build installs pkg-config files.
- **Security:** continuous fuzzing of every parser (rasterizer inputs, SVG,
  image decoders, clipboard and drag-and-drop payloads, Wayland input, D-Bus
  messages, SASL replies, addresses, match rules, and portal font strings).
  Fuzz targets are `std.testing.fuzz` tests, so `zig build test` runs their
  corpus and `zig build test-<module> --fuzz -Doptimize=ReleaseSafe` fuzzes
  them (Zig 0.17's fuzzer finds no coverage in Debug builds).
- **Budgets enforced in CI:** first frame under 20 ms, input-to-photon within one
  frame, 120 Hz scrolling through a 100k-row virtual list, zero idle CPU and
  wakeups, fixed memory per window.

### D26. Layout

- **Requirement:** layout of large trees costs time proportional to what
  changed, never more than linear, with predictable results across box,
  flex, grid, stack, and scroll containers.
- **Decision:** one-way constraint layout in `src/ui/layout.zig`.
  Constraints (minimum and maximum width and height) go down, sizes come
  up, parents place children.
  - Text is horizontal only, so widths never depend on heights. A
    container that sizes to its content asks its children for their
    max-content width (computed bottom-up and cached per node) instead of
    laying them out twice; each child is laid out once with its final
    width, and again only to stretch it vertically.
  - Each node caches the constraints of its last layout (its children's
    positions are valid for those) and its last two sizes. A node laid out
    tight at the size its last layout chose reuses that layout. Changing a
    node marks it and its ancestors; clean subtrees cost one comparison.
  - Containers size to their content within their constraints. Stretch
    alignment, the default in boxes, flex cross axes, and grids, fills
    only children without an explicit size; flex free space and fr tracks
    exist only when the container is larger than its content (stretched,
    sized, or given a minimum).
  - Box is block flow: children stacked vertically and stretched to its
    width. Flex has an axis, gap, grow, shrink weighted by base size,
    justification, cross alignment, and wrapping. Grid has px, fr, and
    auto tracks, row-major auto placement, spans, and auto tracks that
    share leftover definite space; with indefinite space fr tracks size to
    their content in proportion. Stack overlays children with alignment or
    insets. Scroll lays out like a box in an unbounded content area.
  - There is no min-content size and no margin; gaps and padding space
    things. Borders draw over the padding and do not affect layout.
- **Alternatives:** CSS block, flex, and grid in full (intrinsic min and
  max sizes per axis, margins, multiple layout passes); Flutter's model
  without intrinsic widths (shrink-wrapping needs explicit, quadratic
  intrinsic queries).
- **Reverse if:** stock widgets need min-content sizing (for example,
  tables that never wrap words) and cannot get it from explicit sizes.

### D27. Shape of the public API

- **Requirement:** C programs build real UIs with little ceremony, and
  every binding (D3, D23) gets the same safe defaults.
- **Decision:**
  - One builder per primitive (`siv_box`, `siv_flex`, `siv_grid`,
    `siv_stack`, `siv_text`, `siv_editor`, `siv_scroll`), appending as
    the last child; `siv_move` reorders. Image nodes (`siv_image_view`)
    and canvases (`siv_canvas`, D28) are in, and so are external nodes
    (`siv_external_view`) over `siv_external` slots (D17): frame slots
    take shared-memory frames (`siv_external_submit`) and report each
    replaced frame's key when no frame reads it; surface slots hand the
    embedder a `wl_display *` and `wl_surface *` (the only pointers in
    the API) and report the size to render at, with the embedder
    contract spelled out in `siv_external_create_surface`'s
    documentation. A window takes its slots with it.
  - Producers must not wait on the UI thread (D8): `siv_external_submit`
    and `siv_external_surface_committed` work from any thread and go
    straight to the compositor's inbox, and a frame slot's `release`
    callback runs on the compositor thread (quick, calling at most
    `siv_external_submit` and `siv_post`), so a decoder recycles its
    buffers while the UI thread is blocked; then the slot's
    destroy-notify waits for its last frame's release and runs on the
    application's thread. Without `release`, releases arrive as events
    on the application's thread. Creating and destroying slots stays on
    the application's thread. Slot handles are therefore not in the
    root's handle table (which the UI thread grows): they index a slot
    array under a mutex with generations of their own, and any-thread
    calls pin the root through the object handle (`Registry.pinOwner`)
    after checking a `closing` flag that destruction sets before
    retiring the root. Each function's threading is in the header.
  - Display lists hold their own reference to every image they draw,
    from image nodes or canvases, until the compositor releases them, so
    destroying a `siv_image` affects only future draws.
  - Images come from pixels (`siv_image_create`) or files
    (`siv_image_load`, D19), which decode on a worker thread and arrive
    in a callback with a handle the application owns.
  - `siv_image` handles hold one reference to a `ui.Image`; image nodes
    and display lists hold their own, so destroying the handle never
    pulls pixels from under a frame. Canvases draw images by handle, so
    an application keeps the handles of images it may still draw.
  - Property groups are descriptors where zero is a good default (layout,
    visual, semantics, text style, flex, grid, stack). Where zero is a
    meaningful value it is not a descriptor field: opacity and the
    transform have their own setters (`siv_set_opacity`, and a frozen
    `siv_transform` value whose identity has scale 1); flex shrink 0 is
    `SIV_LAYOUT_NO_SHRINK`. Grid lines count from 1 so that 0 is
    automatic. Colors are sRGB-encoded with straight alpha, as in CSS;
    siv converts to linear light (D9, D11).
  - Events go to one handler per node and event type, with
    `bool (*)(void *user_data, siv_node, const siv_event *)`; returning
    true stops bubbling and the default action (D16). Changes to the tree
    from a handler go through a transaction like any other. A second
    slot, `siv_on_default`, holds widget behavior and runs only when the
    first is empty or declines (D22); `siv_emit` sends an event to both.
  - A close request goes to the window's `on_event`; unless it returns
    true, siv destroys the window. `siv_run` returns when `siv_app_quit`
    is called or the last window is destroyed.
  - `siv_app_dispatch` reports `SIV_ERROR_UNAVAILABLE` once the display
    connection is lost and `SIV_ERROR_OUT_OF_MEMORY` once when events
    were dropped; `SIV_ERROR_BUSY` covers a second transaction on a
    window and calls that would re-enter the loop from a callback.
  - Masked editors (D15) are an editor flag. Their text and offsets reach
    the application as the real text, never the bullets shown.
  - `SIV_APP_REDUCED_MOTION` turns off caret blinking and other motion
    whatever the desktop settings say, for kiosks and for tests that
    compare frames.
  - Drag and drop: `siv_set_drop_target` and the `SIV_EVENT_DROP`
    handler; `siv_drag_start` from a pointer handler with
    `SIV_EVENT_DRAG` events; `siv_drop_finish` for `ask`. Mime lists are
    one string with one type per line, and a drag's data is one array
    split by `lengths`, because schema arrays hold only fixed-size
    elements (D3); both stay plain C.
  - Testing input through the C ABI uses the headless backend's
    injection from Zig (`test/abi`); a public test-input API waits until
    applications ask for one.
- **Alternatives:** one generic `siv_node_create(kind)` plus setters (one
  more call for every node); a descriptor per node kind carrying every
  property (large structs, most fields unused); presence flags for every
  field whose zero is meaningful (heavier for every caller than separate
  setters for the few such properties).
- **Reverse if:** binding generators or C users need a property that a
  descriptor cannot default to zero; then split it out as above, never
  add presence flags across the board.

### D28. Canvases: custom drawing from C

- **Requirement:** custom widgets (charts, dials, editors of their own)
  draw arbitrary vector content from any language, size themselves, and
  cost nothing to keep on screen.
- **Decision:**
  - A canvas node has three callbacks in `siv_canvas_desc`: `measure`
    (constraints in, size out) during layout, `draw` during paint, and
    a destroy-notify. Both run in the frame phase, which D5 makes a safe
    point, but in the middle of layout and painting, so while they run
    calls that would change the tree or re-enter the loop
    (`siv_txn_begin`, window creation and destruction, `siv_node_focus`,
    dispatch) return `SIV_ERROR_BUSY`. Queries and `siv_post` work.
  - `measure` is asked once with an unbounded width for the preferred
    (max-content) width and once with the final constraints, like any
    leaf in D26; without it the intrinsic `width` and `height` apply.
    `siv_invalidate` redraws a canvas; `siv_invalidate_size` measures it
    again first. Both are transaction operations, so a redraw lands in
    the same frame as the tree changes around it.
  - Damage per canvas: every canvas roots its own compositor layer (D8),
    so redrawing one repaints and damages only its box and calls no
    other canvas's draw; moving, scrolling, or fading it sends layer
    properties only. Finer damage inside one canvas waits for a widget
    that needs it.
  - The drawing API mirrors the display list (D9) rather than adding a
    model of its own: a current path (move, line, quadratic, cubic,
    arc, rect, rounded rect, ellipse, close) consumed by fill, stroke,
    clip, and backdrop blur unless `KEEP_PATH` is set; paints are solid
    colors and linear, radial, and sweep gradients in sRGB, interpolated
    in linear light; strokes have width, joins, caps, miter limit, and
    dashes; images with source and destination rectangles, opacity, and
    nearest or bilinear sampling; text shaped with the application's
    fonts and fallback (D13), aligned and optionally wrapped in a width,
    and measured with `siv_app_measure_text`. Layers are explicit
    pushes, one per effect (transform, clip, opacity, blend mode), closed
    with `siv_draw_pop`; layers left open close when `draw` returns. A
    path that is a single rect or rounded rect stays a rect shape, so
    the renderer keeps exact box coverage.
  - `siv_draw` is a handle valid only during the call it is passed to.
    Drawing errors are sticky like a transaction's (D4): after the first
    failure every call does nothing, and the canvas shows nothing that
    frame, never half a drawing. To make that possible the callback draws
    into a scratch builder, which is replayed into the canvas's layer
    only when everything succeeded; draws happen only on invalidation, so
    the copy is cheap.
  - Text drawn while a font is still loading uses fallback glyphs and
    marks the canvas; it is drawn again when a font finishes, as text
    nodes are reshaped (D13). Canvas text is shaped on every draw; the
    font cache stays the only cache.
  - The tree side (`ui.Canvas`) passes the window and node to its
    callbacks, has the `measure` hook, keeps its builder balanced when
    a draw fails, and `Window.holdImage` lets a canvas's list keep the
    images it draws alive until the compositor releases it.
- **Alternatives:** recording content into the tree in a transaction
  (no callbacks during paint, but every resize needs an application
  round trip and a re-record, and measuring needs callbacks anyway); a
  cairo-style API with a current transform and saved states (a second
  state model on top of the display list's layers, and transforms would
  have to be applied to geometry on the UI thread); path objects as
  handles (lifetimes to manage for a cost only measurements would
  justify).
- **Reverse if:** profiles show canvases redrawn every frame (animation)
  spending real time in the replay copy or in reshaping text; then draw
  straight into the layer's builder with a rollback point, and cache
  shaped text per canvas.

### D29. Theming

- **Requirement:** every application follows the desktop's color scheme,
  contrast, accent, and font size live, including a high-contrast variant,
  with compiled defaults that applications can override at run time, and
  without the application rebuilding its tree when the desktop changes.
- **Decision:** themed values are public primitives that nodes reference
  and siv resolves when it paints and shapes, not values widgets copy in.
  - Tokens (`siv_color_token`, `ui.theme.ColorToken`): window, view, and
    card surfaces and their text, muted and disabled text, borders and
    separators, control rest, hover, and pressed fills and their text, the
    accent with its hover and pressed shades and the text on it,
    selections, focus rings, tracks and knobs, destructive actions, the
    modal scrim, and inverse surfaces for toasts. Visual descriptors take
    `background_token` and `border_token` and text styles `color_token`,
    each replacing the literal color when set. Text styles take a
    `size_role` (body, caption, heading, title) relative to the desktop's
    UI font size (11 pt by default, 1 pt = 4/3 logical px), multiplied by
    the text scale like every size.
  - Four compiled variants (light, dark, and high contrast of each), picked
    by the portal's color scheme and contrast unless the application fixes
    either (`siv_app_set_theme`). The portal's accent replaces `accent`,
    and the derived tokens follow it: hover and pressed shades mixed 12%
    and 24% toward black (white in dark variants), the text on it black or
    white by WCAG contrast, focus rings, and selections (30% of the accent
    over the view background, or the accent itself in high contrast).
    Application overrides (`siv_app_set_theme_color`, per variant or all)
    apply last; overriding the accent also moves what derives from it.
  - Each window resolves a palette (`ui.theme.Palette`) from the desktop
    values and the application's choices, which the coordinator passes to
    every window like the desktop settings (D19). A changed palette
    repaints every layer and redraws canvases; a changed body size
    reshapes text that has a size role and measures canvases again. The
    core's own colors come from it too: focus rings, editor selections,
    and placeholders, so the core and stock widgets agree. Canvases read
    resolved colors with `siv_window_get_color`.
  - Metrics (spacing, radii, control heights) are compiled design tokens
    of the widget library (`src/widgets/tokens.zig`); colors and text
    sizes are the runtime part.
  - Motion: `siv_set_transition` makes later changes of a node's own
    opacity and transform animate on the compositor (D8) with an ease-out
    curve; moves from layout do not animate, and neither does the first
    value. Reduced motion, from the desktop or `SIV_APP_REDUCED_MOTION`,
    turns transitions into jumps, so widgets get it right by construction.
  - Repeating motion: `siv_set_animation` runs one animation of a
    node's opacity, x or y translation, scale, or rotation on the
    compositor, finite or repeating, applied on top of the node's own
    value. Values are resolved when properties are sent: translations
    can be relative to the node's size and mirror in RTL, so distances
    follow layout without the application's thread doing anything per
    frame (D25). The animation runs only while the node has a layer and
    motion is not reduced: hiding the node destroys its layer and with
    it the animation, showing starts it over, and reduced motion sends
    the node's own value, which cancels it. Changes of the node's size,
    own value, or direction send it again from the start. Indeterminate
    progress sweeps its fill across the track this way; with reduced
    motion it is a still bar at the start.
- **Alternatives:** widgets copying resolved colors into the tree and
  rebuilding on theme changes (every widget library would need a theme
  listener and the tree churns on every desktop change); CSS-like style
  sheets with selectors (a second system to match and cascade, far more
  than tokens need); a theme per window (applications want one look).
- **Reverse if:** applications need per-subtree themes (an always-dark
  sidebar); then let a node carry a palette that its subtree resolves
  against.

## Lessons from ourokit

| ourokit | siv |
| --- | --- |
| App host, Lua-first, no stable ABI | Library, C ABI first |
| Four UI representations with lowering between them | One retained tree, transactions |
| Stock controls in Lua | Stock widgets in Zig on public primitives |
| `app/` coordinator grew to 21.8k lines | Coordinator only sequences phases |
| Rendering on the loop thread | Compositor thread with independent animation |
| Generation checks everywhere | Only at the ABI boundary |
| MCP, HTTP, PAM, audio, secrets in core | Core is UI only |
| Accessibility deferred | Semantics tree and AT-SPI from the start |
| Three text caches, FreeType raster | Two stored text objects, one font cache, HarfBuzz draw |
| Wayring and a custom dma-buf presenter | libwayland and the standard Vulkan swapchain |
| Rust toolchain for SVG, optional Pixman | No Rust; own SVG subset; no Pixman |

Kept from ourokit: callbacks only at safe points, recursive cancellation
scopes, linear-light blending with one display-list contract, pinned Unicode
conformance tests, headless snapshot tests, performance benchmarks, and the
text algorithms.

## Early risks

1. Frame clock behavior alongside Mesa's FIFO present mode (D12). Resolved:
   the clock works with Vulkan swapchains; old Mesa's FIFO can block a
   hidden window's present, so siv uses MAILBOX and guards FIFO.
2. Unhinted text quality on 1× displays (D14).
3. Standard swapchain limits on resize synchronization and frame timing (D10).

## Initial workstreams

These can proceed in parallel with disjoint ownership once the repository
skeleton and build exist.

| Workstream | Owns | Depends on |
| --- | --- | --- |
| ABI schema and code generation | `src/abi/`, generated headers and bindings | Skeleton |
| Text engine | `src/text/` | Skeleton |
| Coverage rasterizer, display list, CPU renderer | `src/raster/`, `src/scene/`, `src/render/cpu/` | Skeleton |
| Event loop and Wayland platform with `wl_shm` | `src/loop/`, `src/platform/` | Skeleton |

The retained tree, layout, compositor thread, Vulkan renderer, accessibility,
and widgets follow once these foundations land.
