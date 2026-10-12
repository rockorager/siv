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
  generate `siv.h`, the Zig wrapper, the Lua binding, reference documentation,
  a published JSON description for external generators, and the linker
  version script. libsiv's own exports use the generated Zig wrapper's types
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
    frame's damage in buffer pixels. Vulkan becomes a second variant with
    its own swapchain; the tree, animation, and damage tracking above it
    do not change.
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
  - Measured (`zig build test-headless`, `test-integration` with
    `SIV_MEASURE=1`, 60 Hz): on headless, key-to-photon with the
    compositor thread has a median of 7 ms against 7.6 ms rendering on the
    UI thread (both within one frame). On sway, using presentation
    feedback while the UI thread sleeps, wheel-to-photon has a median of
    2.4 ms (ReleaseFast) or 9 ms (Debug). A 500 ms animation while the UI
    thread spins drops no frames on either backend, at 1280×720 on sway;
    rendering on the UI thread (headless) misses 23 of the stall's 24
    vblanks. Input waits behind a frame being rendered on the compositor
    thread, so a slow frame delays input by up to its render time.
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
    images, and backdrop blurs draw into the innermost layer. The stack form
    maps to PDF's q/Q, clipping paths, and transparency groups.
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
    Decoding to the displayed size on the pool (D19) is not built yet.
  - Damage: layers with a nonzero id are matched across lists. A layer's
    version covers everything except its transform and opacity, including
    the order of its child layers. `scene.damage.Tracker` returns device
    rectangles (merged; more than 16 collapse to their bounds).
- **Alternatives:** pixel-only scene (cannot produce PDF).
- **Reverse if:** a construct cannot be lowered to all three backends. Watch:
  PDF has no sweep-gradient shading, so sweeps need a function-based shading
  or tessellation there.

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
    every blend mode, blur, COLRv1, and bitmap glyphs, and damage-only
    frames match full CPU frames; the validation layer reports nothing.
  - Runtime fallback to CPU on `VK_ERROR_DEVICE_LOST` or GPU removal. Device
    selection on multi-GPU systems follows dma-buf feedback.
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
    dark text, black behind light text), from a table per foreground
    luminance (16 levels). Color glyphs are not corrected.
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
- **Reverse if:** never. Use `commit-timing-v1` for frames scheduled beyond the
  next refresh (media with timestamps) once mutter fixes the stall. Early risk:
  confirm frame callbacks and presentation feedback behave correctly alongside
  Mesa's FIFO present mode.

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
  - Unsafe-to-break line edges are reshaped inline.
  - Hyphenation from Liang patterns (check each pattern file's license); an
    optional Knuth–Plass breaker for document views.
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
  - Not yet built: tab stops (a tab is four spaces wide), breaking inside an
    overlong word, hyphenation, and Knuth–Plass.
  - Text nodes (`src/ui`) reuse a `Layout` built for another width when its
    lines would break the same way (its widest line fits and it was built
    at least as wide), and align lines in the node themselves, so a node
    that shrinks to its text needs one layout. One style per text node for
    now.
  - Besides the font cache, `ui.Fonts` remembers Fontconfig's fallback
    chain per query (family, weight, slant, language), since sorting fonts
    on every reshape costs milliseconds. It holds font ids, not fonts.
- **Alternatives:** Pango (GLib dependency, blocking font load, single-threaded
  layout objects); libraqm (no wrapping or fallback); Parley (Rust toolchain);
  kb_text_shape (no cluster mapping, so no editing).
- **Reverse if:** the engine cannot reach Pango-level correctness on the
  shaping and bidi test corpora.

### D14. Glyph rasterization without FreeType

- **Requirement:** identical CPU and Vulkan output, color glyphs, variable fonts.
- **Decision:** glyph outlines and COLRv1 paint go through HarfBuzz's draw and
  paint APIs into siv's coverage rasterizer, shared with paths. CBDT/sbix emoji
  decode through wuffs. Glyphs are cached by face, glyph, pixel size, and 1/4-
  pixel horizontal phase; Vulkan uploads CPU-rasterized coverage. Without
  hinting, baselines (and ideally x-heights) snap to pixels, small sizes get
  slight stem darkening, and text coverage gets a contrast correction. No LCD
  subpixel antialiasing.
  - The glyph cache belongs to the renderer and keys on the text engine's
    face content hash, so it never needs invalidation when faces are
    recreated. Color glyphs also key on the foreground color.
  - COLRv0/v1 paint lowers into a display list that the CPU renderer draws
    into a 16-bit bitmap; Vulkan uploads the same bitmaps. CBDT/sbix PNGs
    arrive through the same paint callbacks, decode with wuffs (behind
    `src/render/cpu/image_decode.h`, which the D19 image pipeline can
    share), and are box-filtered to their device size in linear light.
  - At 32 px and below the x-height is scaled vertically to a whole pixel
    (at most ±8%). Stem darkening adds 0.25 px of stroke at 10 px and below,
    falling to none at 18 px. Both are first guesses for the evaluation
    below.
  - Runs under rotation, skew, non-uniform scale, or above 256 px draw their
    outlines as paths; color glyphs lose their colors there.
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
    focus from a pointer press shows none. Theming will set its color.

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
    - `ui.Window.popupPositioner` anchors a popup to a node with logical
      placements: `below` (menus: start edge, flip up, slide sideways,
      shrink), `beside` (submenus: end edge, flip to the start side), and
      `tooltip` (centered below). In RTL they mirror.
    - The headless backend places popups with the same rules
      (`platform.positioner.place`: flip, then slide, then resize, per
      axis) against its output and simulates grab dismissal; the sway
      integration tests check real placement.
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
    - Not yet: dma-buf frames and their import as textures (with the
      Vulkan renderer), and handing embedders a `wl_surface*`.
  - Fractional scale, preferred buffer scale, output hotplug, `xdg-activation`,
    idle inhibit, `xdg-dialog`, toplevel icons, and session restore.

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
  - AT-SPI objects will be one D-Bus subtree registration (D19) whose
    lookup maps `/org/a11y/atspi/accessible/<id>` to a semantics node and
    its interfaces, so exporting the tree costs nothing per node.
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
    - Not built yet: org.freedesktop.Application, ObjectManager, the
      other portals, and serving peer-to-peer connections.
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
      timeout), whose fields have the names and types of
      `dbus.Settings.Values`, applied per window with
      `ui.Window.setDesktop`: a text scale change reshapes text, an accent
      change repaints, and carets restart their blink. The accent draws
      focus rings and, at 30% alpha, focused selections; without one the
      toolkit's blue stays. An application's own reduced-motion flag
      applies whatever the desktop says.
    - Not wired yet in `src/app`: copying the values into `ui.Desktop`
      for every window and setting the default font family on the shared
      `ui.Fonts`. The font size, color scheme, contrast, and cursor theme
      wait for the theme and stock widgets (D22) and pointer cursors.
  - Portals for files, URIs, notifications, printing, screen capture, global
    shortcuts, and the document portal. No built-in file chooser: the portal is
    the system chooser.
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
      data directly.
    - Editors copy with Ctrl+C and Ctrl+Insert, cut with Ctrl+X and
      Shift+Delete, paste with Ctrl+V and Shift+Insert, and paste the
      primary selection with the middle button at the pointer. A non-empty
      selection in the focused editor becomes the primary selection once
      per frame. Masked editors never copy. A paste is one undo step, and
      waits behind an open transaction like input; single-line editors
      turn line breaks into spaces.
    - Drag and drop offers are refused until drag and drop is built.
  - Lifecycle: `org.freedesktop.Application` activation and single instance.
  - System tray (StatusNotifierItem) is an optional module.
  - Images: wuffs (PNG, JPEG, GIF), libwebp, libavif with dav1d, libjxl.
    Decoding is async and decodes to the displayed size.
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
    released every display list it holds and no event for it is being
    delivered, so a handler may destroy its own window.
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

### D22. Stock widgets

- **Requirement:** applications in every language get a complete widget set.
- **Decision:** stock widgets are written in Zig using only public primitives:
  buttons, text fields and areas, styled-text editor, virtualized list, tree,
  table, and grid with selection models, menus, popovers, dialogs, tabs, split
  panes, sliders, spin buttons, progress, toasts. Theming uses compiled design
  tokens plus runtime overrides, follows the portal accent and color scheme, and
  includes a high-contrast variant. Animation respects reduced motion.
- **Non-goal:** a full document model with embedded tables and images.

### D23. Lua 5.5

- **Requirement:** hot reload and user extension, optional for C users.
- **Decision:** `libsiv-lua`, a separate library built on the C ABI. No ambient
  globals; APIs come from `require("siv")`.

### D24. Developer tooling and tests

- **Decision:** the inspector is a separate siv application that attaches over a
  socket the target opens only when an environment variable enables it (tree,
  properties, semantics, layout overlays, repaint flashing, frame timing). Tests
  run the real loop on the headless backend, compare CPU golden images, and diff
  CPU against Vulkan output. `zig build test` stays hermetic. `zig build
  test-integration` runs the Wayland backend against one real compositor, the
  latest sway on its headless backend, pinned through nixpkgs; other
  compositors are not part of the test suite. It also runs D-Bus against a
  private dbus-daemon, with GLib's gdbus as a second client; the hermetic
  D-Bus tests use an in-process test bus over socketpairs.

### D25. Project

- **License:** MIT. Every dependency is MIT, BSD, or Apache-2.0; binaries ship a
  NOTICES file.
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
    the last child; `siv_move` reorders. Images, canvases, and external
    nodes need pixel, drawing, and surface APIs and come later.
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
    from a handler go through a transaction like any other.
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

1. Frame clock behavior alongside Mesa's FIFO present mode (D12).
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
