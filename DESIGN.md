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
  - Padding stays forbidden, since C does not zero the padding of an
    automatic struct and siv could not tell old garbage from a new field.
    Where a descriptor would end 4 bytes short, the schema declares a
    reserved field (`reserved0`, an unsigned integer): it must be zero,
    `SIV_ERROR_UNSUPPORTED` otherwise (checked by `runtime.readDesc`), so a
    later version can turn it into a real field. Bindings leave it out
    (the Lua tables do not have it). Found by the file manager in
    `apps/files`, whose image load priority otherwise had to be 64-bit.
  - Value structs are frozen, so where one will plausibly grow it ends in
    reserved fields now (D30): `siv_text_span` in eight (room for a
    background, an underline style, a baseline shift, letter spacing),
    `siv_paragraph_span` in four (list markers, a paragraph's own
    direction), `siv_tab_stop` in one (a leader), `siv_text_metrics`
    in one (a line count), and `siv_tablet_sample` in four (axes tablets
    may add, D16). They must be zero where the caller passes the
    struct (`SIV_ERROR_UNSUPPORTED` otherwise) and siv writes zero where
    it fills one, so a later version gives them a meaning without a new
    struct. The others are complete (sizes, rectangles, colors,
    transforms, gradient stops) or fixed by what they describe (a dma-buf
    plane, a screen cast stream, a notification button). Descriptors need
    no such room: they grow by appending.
  - Strings are pointer and length; embedded NUL is allowed. siv copies what
    it keeps. Static strings siv returns are also NUL-terminated.
  - Callbacks take `void *user_data` as their first parameter; a callback
    parameter is followed by its `user_data`.
  - Fallible functions return `siv_result` (0 is success, errors negative),
    write outputs through trailing pointers only on success, and have no
    effect when they fail.
  - **The result rule.** A function returns `siv_result` exactly when the
    caller must learn whether it worked, and then ignoring it warns
    (`SIV_NODISCARD`, every one: the schema has no exception). Functions
    that cannot fail return void: teardown (destroying, cancelling,
    removing, withdrawing; a stale handle does nothing, as `free(NULL)`
    does) and the operations of a transaction or a drawing, whose failure
    is the transaction's or drawing's sticky error (D4, D28), read with
    `siv_txn_status` or `siv_draw_status` and reported by
    `siv_txn_commit`. `siv_app_destroy` from a callback destroys the
    application when the dispatch running it returns instead of failing
    with `SIV_ERROR_BUSY`. Before, results that "could be ignored"
    (teardown, transaction operations, and a few window requests) were
    marked case by case, so C callers could not tell a checked call from
    an unchecked one, and window requests that can fail (`siv_window_set_title`
    copies, `siv_window_set_cursor` validates) did not warn (D30).
  - Unknown flag bits, and unknown values of closed
    enums, are `SIV_ERROR_UNSUPPORTED`. The schema marks each enum closed
    (the default: exactly its values) or open (`siv_key`: it names some
    values of a larger set and passes every other value through); the
    generated headers, Zig wrapper (`pub const open`), JSON, documentation,
    Lua binding (any integer for open enums, only named values for closed
    ones), and Lua annotations follow the mark.
  - No global state; multiple applications per process are allowed. The one
    process-wide structure is a fixed, lock-free table of 1024 root slots
    that lets any handle be validated without its root. It holds no
    configuration and needs no initialization.
  - Thread-local storage stays small: libsiv sets Zig's
    `std_options.signal_stack_size` to null, since a library installs no
    crash handler to use the per-thread alternative signal stack Zig
    otherwise reserves (256 KiB of thread-local storage in every thread of
    the host process). With it, a host thread created with a 512 KiB
    stack failed to start (EINVAL); found by the file manager in
    `apps/files`, whose inotify thread did. The export check fails the
    build above 4 KiB of thread-local storage.
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
    versions, and SONAME against the schema.
  - **Versioning and deprecation.** The rules that hold before and after
    1.0, written down before 1.0 as this decision promised:
    - `siv_version()` reports the loaded library and `SIV_VERSION` the
      header. Every declaration, field, enum value, flag, and function in
      the schema records the release that added it (`since`), and the
      JSON carries it, so a generator can target a minimum version.
    - **0.x.** A minor release may change anything; every symbol carries
      that minor release's node (`SIV_0.<minor>`), so a program built
      against an older one refuses to load rather than misbehave. Patch
      releases (0.x.y) change no signature, layout, or documented
      behavior. Renames and removals take effect at once, without
      deprecated aliases: an alias would carry the new node as well and
      save no binary, and every second name is one more for bindings to
      carry to 1.0. Each one is listed in D30 with what replaces it.
    - **From 1.0, within a major version,** nothing is removed or renamed,
      and no signature, layout, or documented meaning changes: functions,
      types, enum values, flag bits, descriptor fields, and value structs
      stay. What may be added: functions (with the node of the release
      that adds them, `SIV_1.<minor>`), descriptor fields at the end,
      enum values, flag bits, meanings for reserved fields, callbacks in
      descriptors. A program built against 1.n runs on every 1.m with m
      at least n. One built against 1.m that uses something newer than
      1.n fails detectably on 1.n: a missing symbol version when it loads,
      for functions; `SIV_ERROR_UNSUPPORTED`, for descriptor fields, enum
      values, and flag bits the older library does not know (the
      descriptor rules above).
    - **Deprecation.** A function with a better replacement is marked in
      the schema (`Function.deprecated`: the release and the replacement,
      which must exist). The header declares it with
      `SIV_DEPRECATED("use siv_x")`, a compiler warning that
      `SIV_NO_DEPRECATED_WARNINGS` silences; the reference, the JSON, and
      the Lua annotations (`---@deprecated`) say so, and the Lua binding
      keeps binding it. It keeps working, as documented, for the rest of
      the major version, and the next major release removes it.
      Deprecations come in minor releases, never in patch releases. Types,
      fields, and enum values are deprecated in their documentation the
      same way and stay until the next major release.
    - **Behavior.** Making code do what its documentation says is a fix;
      changing documented behavior is a break, held for a major release
      unless security requires it.
    - **Major releases** change the SONAME (`libsiv.so.2`) and the node
      prefix (`SIV_2.0`), so the old and new libraries install side by
      side and every binary keeps the one it was built against.
    - `libsiv-lua` follows libsiv's version and these rules: its names,
      tables, and errors derive from the schema (D23).
    - Enforced today: exports, symbol versions, and the SONAME match the
      schema, deprecated functions name a replacement that exists, and
      `since` is never newer than the library. Not built yet: from 1.0,
      a check that compares the schema with the last release's published
      JSON and fails on removals, changed signatures, and moved or
      retyped fields; until there is a release, there is nothing to
      compare with.
  - Every function except `siv_post` (and `siv_version`,
    `siv_result_name`, and the external content producer calls of D27)
    is called on the thread that created the root. The schema says which
    (`Function.thread`: the application's thread or any; a callback's
    `thread`: the application's thread at a safe point, a worker, the
    compositor thread, or any for allocator hooks), so the header's
    comments, the reference, the JSON (`thread`), and the Lua mapping,
    which refuses to bind a callback that runs off the application's
    thread, follow one source instead of prose in each function's
    documentation (D30). The header opens with these conventions.
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
  - Out parameters a caller may not need take NULL (`Param.optional`,
    "May be NULL." in the header): an event's `handled`, the request of a
    load, the timer of a one-shot, a popover's content. C callers no
    longer declare a variable to throw away; the others stay required,
    since a missing one is a bug.
  - Queries that answer with a handle return it (`Function.ret` a handle),
    0 when there is none or an argument is invalid, as builders return 0:
    `siv_node_get_related`, `siv_node_get_window`, `siv_window_get_root`,
    `siv_window_get_focus`, `siv_window_get_app`, `siv_menu_get_item`,
    `siv_view_get_row`, `siv_widget_get_part`. They nest in other calls
    (`siv_menu_open(siv_widget_get_part(b, SIV_WIDGET_PART_MENU, 0), b)`),
    and a 0 passed on is reported by the call that gets it (a transaction
    operation's sticky error). Lua returns nil for 0. Queries with other
    answers keep the out parameter, since only a handle has a value that
    means none.
  - `SIV_STR("literal")` in siv.h passes a string literal and its length,
    as a parameter or, since a string's length field follows its pointer,
    in a designated initializer (`.label = SIV_STR("Save")`); `"" s ""`
    rejects anything but a literal, whose `sizeof` is its length plus one.
  - Arrays are a const pointer and `<name>_count`; functions that fill
    caller memory take `char *` and `<name>_cap`, write at most that much,
    and report the full length, so callers can size a second call.
  - Bytes that are not text are unsigned: `uint8_t *` for pixels, a
    bitset, encoded images, font files, and clipboard or drop data,
    whether the library reads them (arrays of `uint8_t`) or fills them
    (buffers marked `bytes` in the schema). `char *` is for UTF-8 text
    only, so C callers index pixels without casting away the sign and
    bindings map each to their byte and string types.
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
  - **The Zig wrapper** has the C ABI's types and functions as they are
    (`siv.c`, extern structs matching the header) and an idiomatic
    function per schema function, which Zig applications use: errors as
    Zig errors, a trailing out parameter as the return value, strings and
    arrays as slices. Its rules (D30):
    - Descriptor parameters take `T.Options`, a struct with the
      descriptor's fields but strings and arrays as slices and no size or
      reserved fields (`siv.pushButton(txn, row, .{ .label = "Save" })`),
      or null for defaults; the function builds the extern descriptor on
      its stack (`T.fromOptions`). Extern structs cannot hold slices, so
      a second type is the price of not writing `.label_len`.
    - Callbacks receive descriptors as `*const T`, not `?*const T`: siv
      never passes them NULL, and the optional made every handler start
      with `ev.?`. The C header is unchanged (a pointer is a pointer).
    - Transaction and drawing operations and teardown return nothing
      (D2's result rule), so setters read like builders (`siv.setLayout(
      txn, node, .{ ... })` without `try`) and the transaction's error
      comes from `txnCommit`, the same sticky model; nothing falls back
      to `siv.c` for it.
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
  siv_node row = siv_flex(t, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_ROW, .gap = 8));
  siv_text(t, row, "Hello", 5);
  siv_on(t, button, SIV_EVENT_TYPE_ACTIVATE, on_click, NULL, user);
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
  - External nodes, the last of the closed set, are built (D17, D27):
    `siv_external_view` over a slot of shared-memory or dma-buf frames,
    or a `wl_surface` the embedder renders into.
  - At the C ABI (`src/abi/tree.zig`), builders (`siv_flex`, `siv_text`,
    ...) return the new node's handle directly, as in the example above,
    and errors are sticky: the first operation that fails records its
    error in the transaction; every later operation does nothing and
    returns it (builders return 0), and `siv_txn_commit` discards the
    whole transaction and returns that error. `siv_txn_status` reads it
    early. A C program builds a subtree without checking each call and
    still never commits half of it. Setters and the other transaction
    operations return nothing (D2's result rule): their failure is the
    transaction's.
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
    in the dispatch phase. A job is compute work or blocking work, which
    run on separate threads (D6); either way its completion is a safe
    point. Pool threads come and go (started for a burst of jobs, gone
    after 5 s idle, D6), so nothing may rely on a job running on a
    particular or long-lived thread: thread-local state does not survive
    between jobs.
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
  deadlines from a userspace timer heap. `siv_app_get_fd()` and
  `siv_app_dispatch(timeout)` embed it; `siv_app_run()` owns it. File I/O runs on the
  worker pool.
  - The loop fd stays readable while any work is pending (the eventfd is
    written when work is scheduled for a phase that already ran), so an
    embedder only needs to poll it and call `siv_app_dispatch(0)`. An idle
    loop with no armed timers blocks indefinitely.
  - Worker threads start on demand up to a limit, block when idle, and
    exit after 5 s without work (`Pool.idle_timeout_ns`), in both lanes
    below. A burst (an icon theme read at startup filled the blocking
    lane's 8 threads; a fork-join starts a compute worker per CPU) left
    an idle window with 27 threads, 7 after the timeout (the UI and
    compositor threads, and Mesa's shader cache threads). Starting one
    again costs tens of microseconds, once per burst.
  - One worker pool per application, shared by file I/O, decode, and raster
    tiles, so the loop and the renderer never oversubscribe the CPU. It has
    two modes on the same threads and queue: async jobs (completions
    delivered by the loop, D5) and blocking fork-join, in which the calling
    thread also runs the job and helpers that have not started when it
    finishes are dropped, so fork-join never waits behind queued I/O.
  - Two classes of job, on separate threads of the one pool. Compute
    jobs (decoding, fork-join tiles, `SIV_JOB_COMPUTE`) run on at most one
    worker per CPU, highest priority first and in submission order within
    a priority; fork-join helpers go before every queued job, so tiles
    never queue behind decodes (D8). Blocking jobs (file reads,
    application jobs by default) run on a lane of up to 8 threads of
    their own that never take compute work, so a copy of a large tree
    waiting on a disk or a network file system cannot hold a worker that
    decoding or rendering needs; the lane may be wider than the CPU
    because its threads mostly wait. Found by the file manager in
    `apps/files`, where several copies at once left thumbnails queued
    and fork-join rendering on the compositor thread alone.
    Alternatives: a cap on how many workers application jobs take (still
    oversubscribes when they compute, and still blocks decodes behind
    them up to the cap); a thread per blocking job (unbounded threads
    for a burst of small reads).
  - Applications use the same pool through `siv_job_start`: `work` on a
    worker thread, then `done` and the destroy-notify at a safe point
    (D5). A file manager reading a folder of 100 000 entries or copying
    gigabytes needs blocking I/O off the UI thread, and a pool of its own
    would oversubscribe the CPU against siv's decoders and tiles; found
    by the file manager in `apps/files`. Jobs cannot be stopped once
    running (the work checks a flag of its own for cancellation), and
    destroying the application waits for running ones, so long jobs
    check that flag often.
  - Applications watch their own descriptors in the loop with
    `siv_app_watch_fd` (readable, writable; hangup and error reported):
    the io phase records readiness and schedules a dispatch task, so the
    callback runs at a safe point (D5) in the same iteration, and
    `siv_watch_destroy` is safe from it. Level-triggered, like the
    loop's own sources; regular files and directories, which epoll
    refuses, are invalid arguments. A file manager follows the shown
    folder with inotify; without it, it ran a thread blocked in poll(2)
    that posted changes, with the lifetime handling a cross-thread post
    needs. Found by the file manager in `apps/files`. Alternative: an
    edge-triggered watch (the application must drain every time or
    lose wakeups, an easy bug to write in every binding).
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
  Its helpers jump the compute queue, and blocking I/O has threads of its
  own (D6), so neither queued decodes nor long application jobs keep
  helpers from joining.
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
  - Touchpad pinches route by the same rules (`update.Scroll`), with
    "can still move" read as "zooms": with ctrl, alt, or super held, or
    over a wheel region (nodes with scroll or gesture handlers), they go
    to the UI; otherwise the first input-enabled zoomable scroll
    container under the pointer zooms in the compositor, and without one
    the UI gets them. A pinch keeps its first target until it ends. A
    zoomable container (`Scroll.min_zoom` below `max_zoom`) scales its
    children about its viewport's top-left corner; offsets are in zoomed
    pixels and clamped to the zoomed content. A pinch zooms to its start
    zoom times the pinch's scale, keeping the content point under the
    pointer (between the fingers) in place, and pans with the fingers'
    motion; `scrolled` reports the zoom with the offset. Vector content
    stays sharp, since every frame rasterizes the display lists at the
    composed transform (D9): no layout or repaint runs while zooming. UI
    handlers that decline a pinch pass it on with `zoom_by`, relative
    like `scroll_by`; the application's own zoom is `zoom_to`, which keeps
    the content at the viewport's corner. A hold gesture (fingers resting
    on the touchpad) stops every fling in the window, which is what
    libinput's hold exists for; holds and swipes also go on to the UI.
    Alternative: zoom only in UI handlers, relaying out per step (a busy
    UI thread would freeze the pinch, against this decision's
    requirement).
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
    send properties only. A node that moves without rooting a layer
    changes its descendants' places too: they repaint, down to the
    layers they root, since some paint into layers the moved node does
    not root (a chunk after a descendant's layer, painted in its
    container's coordinates). Marking only the moved node left a bar's
    controls after a combo box (which roots a layer, for the wheel)
    where they had been when a row appeared below it (siv-columns' file
    chooser opening its command line). One exception: text taller than four viewports
    of its scroll container paints only the lines within a viewport above
    and below what it shows, and the UI repaints it when a `scrolled`
    report (or a layout) shows lines outside that band, about once per
    viewport scrolled. Otherwise a keystroke in a long document painted
    all of it (1.4 MB: 1.4 M glyphs into the display list per key); the
    compositor keeps scrolling smoothly in between, since the band is a
    viewport ahead.
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
    application sets in a transaction are `scroll_to`. Corrections that
    keep a long text in place while its metrics change (D13) and the
    scrolls that show an editor's caret (D15) are `scroll_by` as well,
    in the commit with the content they answer: one that scrolls up goes
    before the commit's other ops, so that the container's new, smaller
    extent does not clamp the offset first, and one that scrolls down
    after them, once the extent has room (`paint.ScrollBy.early`).
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
  - Measured (`zig build bench-latency` and `zig build bench-pacing`, 60
    Hz): on headless, key-to-photon with the
    compositor thread has a median of 7 ms against 7.6 ms rendering on the
    UI thread (both within one frame). On sway, using presentation
    feedback while the UI thread sleeps, wheel-to-photon has a median of
    2.4 ms (ReleaseFast) or 9 ms (Debug). A 500 ms animation while the UI
    thread spins drops no frames on either backend, at 1280×720 on sway;
    rendering on the UI thread (headless) misses 23 of the stall's 24
    vblanks. These timings are checked by hand (`zig build bench-latency`,
    test/compositor/latency.zig), not in `zig build test`, where the rest
    of the suite beside them makes the machine, not siv, decide them (D24);
    `zig build test` checks that the compositor thread finishes an
    animation while the UI thread does not dispatch
    (src/compositor/tests.zig), and `zig build bench-pacing` counts drops
    on sway (D12). Input waits behind a frame
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
  - A layer can composite its content in sRGB (`Layer.srgb`, for SVG,
    D11): the renderers encode every color drawn in it (solid paints,
    gradient stops, shadows, glyph colors, image texels), so blending,
    coverage, and gradient interpolation inside work on encoded values;
    the layer is isolated and converts its result (unpremultiply,
    transfer function, premultiply, through the same 16-bit tables in
    both renderers) when it composites into a parent of the other space.
    An isolated layer without the flag works in linear light even inside
    one; a layer that is not isolated draws in its parent's space.
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
    contract exactly. A page is a square that would hold the frame's
    masks, 256 to 2048 px in steps of 256, grown to the largest mask:
    pages fixed at 2048 px, two layers for each frame in flight, cost
    16 MiB of VRAM from the first path on (siv-columns' command line,
    whose border is four band masks, on RADV), a quarter of its GPU
    memory. Glyphs come from the CPU glyph cache (D14) through an R8 and
    an RGBA16 atlas, each made with its first glyph: most windows never
    show a color glyph, and the RGBA16 atlas (1024 px square) is 8 MiB of
    VRAM, a fifth of siv-columns' at startup. Isolated layers render into
    per-depth FP16 images and composite back with fixed-function
    source-over, or for other blend modes against a copy of their
    backdrop. A backdrop blur copies its backdrop and runs the CPU's
    separable passes in FP32. Layers that composite in sRGB (D11) get
    encoded colors at prepare time; image and color glyph texels and a
    layer's texels on its way into a parent of the other space convert in
    the shader through the CPU's 16-bit tables (a sRGB-to-linear table
    joined the lookup buffer), so both renderers match the `srgb` golden
    image.
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
    tables and dither, so swapchain images need no buffer age. Encoding
    only what changed since a swapchain image last showed (its age, kept
    per image, with each frame's redrawn regions) was tried and dropped:
    on RADV (Radeon 760M, 1280×800, five swapchain images) the whole
    encode takes about 0.2 ms, and keeping an image's contents (a
    transition from the present layout instead of from undefined, and a
    load) made it slower: 0.26 against 0.20 ms per typing frame, 0.72
    against 0.21 ms per frame of a scrolling list. Where the GPU time goes
    is the draw pass.
  - Overdraw: an instance gets a hole where a later opaque draw into the
    same target covers it (a solid paint of alpha 1 with analytic
    coverage, inside the full-coverage part of its shape and of every
    clip); the vertex shader draws it as the four quads around the hole,
    so those pixels are not shaded (`Renderer.occlude`, not in frames
    with a backdrop blur, which reads around its own pixels). A
    rectangle's or rounded rectangle's stroke is drawn as the four bands
    around its empty inside, each its own mask. A 100,000-row list
    scrolling on the compositor shaded three full-window quads per frame
    (the window's background, the view's, and its border as one mask
    rasterized over the whole window): GPU time per frame 1.68 to 1.05
    ms (gpui 0.96), the draw pass alone 1.38 to 0.74 ms; frames are
    unchanged (the Vulkan tests compare them with the CPU's).
  - Two draw pipelines from the one fragment shader: a specialization
    constant selects a variant for the common draws (solid paint with
    rectangle, rounded rectangle, or glyph coverage, and at most two
    analytic clips; `Renderer.simpleDraw`), from which the driver drops
    every other path, and runs of such instances are drawn with it. The
    variant evaluates the same formulas, so frames are unchanged (the
    Vulkan tests compare both against the CPU). RADV's shader statistics
    (`RADV_DEBUG=shaderstats`; RGP is not available here) put the full
    shader at 23,560 instructions in 110 KB with 56 VGPRs, the variant at
    943 instructions in 4.4 KB with 24. GPU timestamps of the draw pass
    per frame, full shader against the two pipelines: the 1.4 MB
    document scrolling 0.84 to 0.54 ms, the grid 0.53 to 0.43 ms, the
    100,000-row list 0.65 to 0.39 ms. The encode (about 0.2 ms) is
    untouched.
  - Path coverage of up to 262,144 pixels a frame is rasterized on the
    compositor thread instead of the worker pool, whose dozen threads
    woke every frame for a border's four bands: with the bands, that
    list's CPU time per frame went from 2.39 to 1.51 ms (gpui 2.04).
  - sRGB attachments, which encode in hardware with blending still in
    linear light, were measured as the working image instead of FP16:
    the draw pass took the same time (0.643 against 0.644 ms per frame of
    that list, 0.224 against 0.238 ms per typing frame; its shader, not
    memory, is the cost) and the encode, reading half the bytes, 0.02 ms
    less, while banding came back (D11). Kept FP16.
  - Descriptors: storage buffers and the atlases in one set per frame, and a
    second set of two textures per draw that needs one (images, layers,
    backdrops); image draws batch per image. No descriptor indexing:
    lavapipe (Mesa 22.3, the test device) has none.
  - libvulkan is loaded with dlopen, so libsiv has no link dependency on it
    and starts on machines without a loader.
  - Shaders are GLSL compiled to SPIR-V 1.6 by glslang 16.6 built from the
    source pinned in build.zig.zon, and the SPIR-V is committed beside them
    (`src/render/vulkan/shaders/*.spv`), so builds run no shader compiler.
    `zig build shaders` compiles them again and rewrites the SPIR-V and
    `glsl.sha256`, the hashes of the GLSL it came from (`-fsys=glslang`
    runs the system glslangValidator instead); a render-vulkan test
    compares those hashes with the GLSL, so an edit without regenerating
    fails `zig build test`. The check needs no compiler, which answers the
    old objection to checked-in SPIR-V (drift without a check). Before,
    every build compiled glslang (about 80 s of a cold build, in Debug;
    optimized builds exceeded 7 GiB with four jobs) and the shaders (D25,
    Build cost). Alternatives: shaderc, DXC, Slang, or Tint (larger C++
    builds wrapping the same work); Zig's SPIR-V backend (experimental,
    with no image fetch or descriptor helpers in std). glslang's generated
    parser is GPL-3.0 with the Bison exception; it runs only when
    regenerating and nothing of it ships. Reverse if Zig's SPIR-V backend
    compiles these shaders into SPIR-V that drivers accept.
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
  - `exit` waits for a device thread that is still starting (up to 2 s).
    Loading the driver runs its libraries' static constructors on that
    thread: Mesa's drivers link libLLVM, whose constructors register about
    2700 command-line options and their destructors (8 ms on RADV). An
    application that returned from `main` meanwhile (an error path without
    `siv_app_destroy`) ran those destructors under the constructors, and
    LLVM aborted with "Option 'print-inst-addrs' registered more than
    once": one libLLVM, loaded once, its registry torn down mid-build, not
    two copies. `exit` runs the exiting thread's thread-local destructors
    first, so the compositor registers one (glibc's
    `__cxa_thread_atexit_impl`; none elsewhere) on the thread that creates
    it, which waits for that thread's device threads. Loading the driver on
    the UI thread instead would add those 8 ms to startup. `exit` from
    another thread is not covered.
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
    window: the swapchain's color space must say it, not siv. It applies
    to explicit synchronization already: Mesa's WSI makes the swapchain
    surface's wp_linux_drm_syncobj_surface_v1 and sets its points, so
    siv makes none on window surfaces. CPU-rendered windows and popups
    present wl_shm, which linux-drm-syncobj-v1 does not take (compositors
    read or copy shared memory at commit). siv's explicit synchronization
    covers the dma-buf frames it attaches to subsurfaces (D17).
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
  - Measured against 8-bit sRGB storage (a Vulkan sRGB working image,
    blending in linear light in hardware): across a dark gradient (sRGB
    20 to 36 over 1024 px) the FP16 path's output changes value 513 times
    with runs of one value up to 34 px, as the CPU's does; 8-bit storage
    changed 191 times with runs up to 83 px, and under three translucent
    layers 43 times with runs up to 290 px (FP16: 470 and 110). Each
    blend rounds to 8 bits, and the encode's dither cannot bring back what
    storage already rounded away.
  - Exception: SVG content composites in sRGB, as the SVG specification
    says (`color-interpolation` defaults to sRGB) and as icons were
    designed: in linear light Breeze's translucent highlights and shading
    looked lighter than in GTK or Qt (23% of its icons differed from
    librsvg; with sRGB layers 0.16%, D19). Display lists have a layer
    flag for it (`Layer.srgb`, D9), which the CPU and Vulkan renderers
    implement with the same arithmetic and PDF ignores (it blends in
    DeviceRGB, which is sRGB-encoded, D19 Printing). What an sRGB layer
    holds composites onto its parent in linear light like any layer.
- **Alternatives:** gamma-space blending everywhere (incorrect gradients and
  alpha); pure linear text (looks thin); 8-bit sRGB working images
  (banding, above).
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
  - Applications see presentation too: each window reports
    `SIV_WINDOW_EVENT_TYPE_PRESENTED` when a frame with everything committed
    so far reaches the display server, with the commit count it shows,
    the predicted presentation time, and the commit time (CLOCK_MONOTONIC).
    It rides on the compositor's existing "presented" message, so it
    costs no wakeup and none comes while idle. Startup to first frame,
    or a change reaching the screen, is measurable without siv's
    internals; found by the file manager in `apps/files`, whose
    benchmark read `presented_seq`. The time is the frame clock's
    prediction rather than the later feedback, so the event is not held
    back a refresh.
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
  - A text node's text is shaped and laid out in blocks
    (`text.blocks`): runs of whole bidi paragraphs of about 8 KB, each
    with its own `ShapedParagraph` and `Layout` and its own copy of its
    bytes, shared by reference count between a text and the one an edit
    built from it (a rope with paragraph-aligned leaves). Paragraphs are
    independent (bidi, line, grapheme, and word boundaries all break
    after a separator; shaping stops there), so the blocks give the
    whole text's lines, carets, movement, and hit tests, which randomized
    tests compare with a single `Layout` of the text, edit after edit.
    `ShapedText` holds the blocks' offsets, styles, and paragraph counts;
    `TextLayout` stacks their layouts, adds the space between paragraphs
    at block boundaries, and answers the editor's queries in the block
    holding the offset. An edit reshapes the block it falls in: within
    it, only the paragraph it touched and one on each side
    (`ShapedParagraph.initReusing`), whose lines alone are broken again
    (`Layout.initReusing`); other blocks are kept as they are. A block
    next to the change is redone too when the change touches its
    separator (CR then LF), and a block that grows past twice the size
    splits at the next edit. What stays linear is small: comparing the
    old and new bytes block by block (memcmp-speed) and a few words per
    block of offsets. Arrays are built in scratch memory and kept at
    their exact size (glyphs and lines outside the arena, which grows by
    half again what it holds). Measured on a 1.4 MB, 4,000-paragraph
    editor (bench/gpui-compare, RADV): key to photon 299 ms with whole
    reshaping, 22 ms with paragraph reuse over flat arrays, 3.1 ms in
    blocks (gpui 3.6 ms); resident memory 284 MiB to 160 MiB.
  - Memory is bounded (October 2026). Every block keeps its bytes, its
    styles, its paragraph count, and, once laid out, its exact metrics
    (`blocks.Metrics`: height, line count, widest line, and its first
    paragraph's space before and last's space after), a few dozen bytes;
    the heavy part, its `ShapedParagraph` and `Layout` (shaped runs,
    break opportunities, lines, caret stops, positioned glyphs), stays
    only while a `blocks.Residency` keeps it. That was 65 times the
    block's bytes for the 1.4 MB editor (330 KB of shaping and 210 KB of
    lines per 8 KB block, two thirds of them glyphs and caret stops), so
    keeping every block cost 91 MiB where gpui keeps 6. The application
    has one residency for all its windows (`ui.Fonts.residency`), with a
    budget of 16 MiB (`residency_budget`: about 30 such blocks, several
    screens beyond those shown), its blocks in order of use; `trim`
    evicts the least recently used beyond the budget after every frame
    and after each background job, sparing the blocks used since the
    last trim (what a frame or an operation is using, however large)
    and blocks shaped while a font they wanted was loading (shaping
    them again once it loads would differ; their text reshapes then
    anyway). Only long texts (64 KB or more) use it; shorter ones keep
    everything, as before. Whatever needs an evicted block builds it
    again (`ShapedBlock.ensure`, `LayoutBlock.ensure`), from its own
    bytes and styles: editing (the edited block reshapes as before,
    reusing the old block's paragraphs when they are in memory), caret
    movement, selection, hit testing, painting, and AT-SPI's text
    extents and character queries. A block built again is the block it
    was (shaping and layout are deterministic over the same fonts, and a
    debug assertion compares its metrics with the kept ones); randomized
    tests compare a bounded text with a kept one block by block (lines,
    caret stops, glyphs, metrics, and tops) and query by query, with
    evictions between queries, across chains of edits. The text
    queries now return `OutOfMemory`, since they may lay out: the editor
    ignores a key it cannot lay out for, and AT-SPI answers nothing.
    PDF output needs nothing of this: pages are canvases (D19), whose
    text is shaped and laid out whole for the page. Measured
    (bench/gpui-compare round 4, five runs): the 1.4 MB editor's
    resident memory at the end of its scenario 152 MiB to 89 MiB (gpui
    82), key to photon unchanged (3.3 ms median); 100 MB of logs 6.6 GiB
    to 292 MiB (gpui 434), first frame in 216 ms (gpui 469). A jump to
    the end or a search result shows in 4 to 6 ms, 9 to 13 ms the first
    time, which shapes a few blocks again (gpui 8 ms, 22 ms at most). A
    keystroke in the logs cost 27 ms (gpui 3.6): the editor's text was
    one buffer that an edit copied, and finding what an edit changed
    compared the texts block by block; the text is a rope now, and the
    change comes from it (D15), 5.3 ms. Alternatives: no
    budget, laying out only the blocks shown each frame, as gpui does
    (the editor's queries then cost a layout every time, and the
    scrollbar is an estimate for good); a budget per text (an
    application with several long texts would multiply it).
  - A long text shapes only its first blocks (32 KB, more than a
    screen) before its first frame; the rest is split into blocks at
    once (a block's end is searched from `block_bytes` past its start,
    less the three bytes a separator may take, and separators are found
    16 bytes at a time, so 100 MB splits in milliseconds), and laid out
    with estimated metrics: the height per byte and line height of the
    blocks measured. The worker pool shapes the estimated blocks in jobs
    of eight (`text_node.Shaping`), low priority, under the font cache's
    shared lock; each job's blocks are installed on the UI thread
    (`ShapedBlock.install`), measured (`TextLayout.measureShaped`), and
    trimmed at once, so a job's blocks are the most a delivery adds to
    the budget (48 blocks a job held a whole budget's worth each). A job
    holds references to its blocks, which do not change while other
    blocks are edited: editing no longer shapes the rest first, and a
    text whose fonts change, or a node that goes away, orphans its
    jobs. When the last job is done, the heap is trimmed (glibc's
    `malloc_trim`, looked up weakly): evicted blocks and each worker's
    intermediates leave free pages behind. Metrics are exact once known:
    a block is measured when its estimate is replaced, for good, and a
    query that reaches an estimated block (a caret, a hit test, a line
    by index, painting) measures it first, which moves only the blocks
    after it (`TextLayout.generation` counts such changes). The line
    count, height, and tops are exact once every block before them is
    measured. A width change lays out the blocks in memory and
    estimates the others, which the pool shapes again, instead of
    reshaping every evicted block on the UI thread. The size threshold
    for estimating is the long-text one (64 KB): a jump to the end of
    the 1.4 MB editor measures the blocks it shows rather than shaping
    the 1.4 MB first (about 100 ms, the old behavior); tens of megabytes
    was the other candidate. Tops are doubles: summed in floats, the
    heights of a 100 MB text lose whole pixels.
  - Positioned glyphs, which only painting reads, are kept by a text of
    more than four blocks only for the blocks it paints: others are laid
    out without them (`Options.glyphs`; lines, runs, and carets are the
    same) and laid out again with them when painted
    (`TextLayout.withGlyphs`), and painting drops them from blocks
    outside what it painted. A block reshaped from one that had glyphs
    keeps them, so typing does not lay out twice. Measured on the 1.4 MB
    editor: startup to first frame 99 ms to 35 ms (gpui 87 ms); resident
    memory at the end of the scenario 163 MiB to 150 MiB, 30 MiB of
    glyphs less and some of the pool's heaps more (gpui 82 MiB, which
    shapes lines lazily and stores no per-glyph layout); key to photon
    unchanged (3.4 ms).
  - A long text in a scroll container stays where it is shown while
    metrics elsewhere change: estimates replaced by measurements, blocks
    laid out for another width, edits in other blocks (`text_node.settle`,
    after layout). The scroll position the text keeps is an anchor
    (`text_node.Anchor`): the block at the top of what is shown, compared
    by address, and the distance from the start of its line there (by
    byte, so a new width finds the line again; through
    `ShapedParagraph.Reuse` when an edit reshaped the block). After each
    layout the anchor's new position, less its old, is the correction,
    sent as a relative `scroll_by` in the same commit as the content it
    corrects for (D8), so no frame shows the content moved and scrolling
    the compositor does meanwhile is kept. Then the blocks within a
    viewport of what is shown are measured (painting draws them), and
    the anchor is corrected again until none is estimated; layout runs
    again in the same frame when heights changed. The compositor's
    `scrolled` reports move the anchor. A text above the viewport moves
    what follows it by its change of height, through the same anchor.
    Far down a long text, floats are coarser than pixels (2 px apart past
    16.7 M), so painting places a band's lines in a layer at the band's
    first block's top, relative to it in doubles, and lines keep their
    spacing; only the band as a whole may be a pixel off.
  - Unsafe-to-break line edges are reshaped inline.
  - Hyphenation from Liang patterns (each pattern file's licence checked);
    an optional Knuth–Plass breaker for document views.
  - Horizontal text only; vertical CJK is a non-goal.
  - The font cache never reads files. Fonts enter with caller-supplied bytes or
    as pending Fontconfig sources; shaping skips pending fonts and lists the
    ones it wanted, and the text node loads them on the worker pool and
    rebuilds its `ShapedParagraph`. A style's fallback chain is Fontconfig's
    coverage-trimmed sort for the query. Shaping asks for the first
    pending font of a chain and for a fallback only when a grapheme
    needs it: asking for every pending font before the first was ready
    read the whole chain, CJK and color emoji included, to show "Hello"
    (siv-files measured 70 MiB of heap and 40 ms of startup from it).
  - siv never fails or crashes for want of fonts. The font cache has a
    built-in last-resort face (`text.font.last_resort`, generated by
    `src/text/last_resort/make_last_resort.py`, 668 bytes): a hollow box
    of 0.6 em for .notdef, which every character maps to, and an empty
    quarter-em glyph for space and no-break space, so words stay apart.
    A style's chain may be empty; text whose chain has no ready font
    shapes with it, and lines without a font take its metrics, so text
    lays out and shows boxes with `missing` set. A chain with a font
    still loading shows nothing until it loads instead, as before, so
    text does not flash boxes at startup. `siv_app_has_fonts` tells the
    application whether the default family resolves to any font (added
    or Fontconfig's): false with `SIV_APP_NO_SYSTEM_FONTS` and no font
    added, or where Fontconfig finds none. Before, an empty chain was
    invalid styles, and the first text layout reached an unreachable;
    found by the user guide's tests. Alternatives: a bundled real font
    (megabytes, and a licence to carry, D25); Unicode's Last Resort font
    (glyphs per block, but OFL); hex boxes of the code points (readable,
    but a glyph made per code point at draw time, outside any font).
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
  - Truncation (`SIV_TEXT_ELLIPSIZE`, `siv_text_style_desc.max_lines`,
    CSS text-overflow and line-clamp) works in the text node, not the
    engine: when the layout has more lines than allowed, or a line wider
    than the node's box with ellipsizing on, the node shows a cut copy:
    the text up to a grapheme boundary of its last allowed line, trailing
    white space trimmed, plus "…" (nothing without ellipsizing), shaped
    and laid out like the original. The boundary is the largest one at
    which the copy still ends on that line and fits, found by bisection
    over the line's caret stops: about log2 of its graphemes extra
    layouts, only for text that does not fit, kept until the width or
    the text changes. The ellipsis is a neutral character at the logical
    end, so it lands on the visual end of the paragraph's direction. The
    node's text, accessible name, and max-content width stay whole, so a
    table cell grows back when its column does. Found by the file
    manager in `apps/files`, whose names were clipped mid-glyph.
    Alternative: truncating inside `Layout` by glyph positions (exact per
    visual line, but needs bidi-aware cutting and reshaping of the edge,
    which the copy gets for free).
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
    rectangles come from the text's `TextLayout` (D13), which finds the
    block holding the offset first, so they cost a block, not the text.
    Arrows move visually, Ctrl+arrows by words, Home and End to the
    line's edges in reading order, Up and Down keep a preferred x. A
    single-line editor scrolls its text to keep the caret in view and
    drops line breaks from typed text.
  - A text node's bytes are a rope (`text.Rope`, October 2026): a
    height-balanced tree of immutable leaves of up to 4 KB, shared by
    reference count between a text and the texts edits made from it. An
    edit (`Txn.replaceText`) copies the leaves holding its ends and the
    path to them and shares the rest, so it costs the edit and the log
    of the text's size; the old text stays whole for the transaction to
    restore on abort and is released at commit. A text of up to 4 KB is
    one leaf, which reads as one buffer (`Rope.flat`), so labels and
    fields cost what they did. What an edit changed is found from the
    ropes (`Rope.commonPrefix`, `commonSuffix`), which skip the subtrees
    the old and new texts share: a text node keeps the rope it last
    shaped (with any preedit, itself a rope sharing all but one leaf
    with the content), and gives the change to shaping
    (`ShapedText.initEdit`), which compares and builds only the blocks
    it touches, copying their bytes out of the rope a block at a time.
    Before, the node's text was one buffer: each edit copied all of it,
    and shaping compared all of it with the old blocks. Measured
    (bench/gpui-compare round 5, five runs): a keystroke in 100 MB of
    logs 26.9 ms to 5.3 ms (gpui 3.5), in the 1.4 MB document 3.4 to
    2.8 ms (gpui 3.5); memory unchanged. What is left at 100 MB is
    bookkeeping per block, 12,800 of them (the new text's arrays of
    offsets, restacking heights), and laying out the edited block;
    two linear passes that remained in it went: comparing every kept
    block's styles with the text's (a text with one style keeps it,
    `ShapedText.only_style`) and finding old layouts through a map of
    every block (the blocks an edit kept pair up from both ends). The queries keep their meaning:
    `siv_node_get_text` copies the text into the caller's buffer and
    returns its length; `siv_node_get_text_range` copies a piece from an
    offset, so a long text is read (searched, saved) without a buffer
    as long as it (D30); a change event still passes the whole text,
    copied into one buffer for its handler when the text is longer than
    a leaf, so a change handler on a long text costs a copy a change.
    Undo copies the bytes an edit removed, the input method gets up to
    1000 bytes each side of the selection, copies to the clipboard copy
    the selection, AT-SPI's snapshot copies the text as before, and
    paragraph lookups (`spans.paragraphAt`) look back and ahead from the
    offset rather than scanning from the start. Masked editors keep their
    secret in locked pages as before; their bullets are a rope like any
    text. Alternatives: a piece table (an edit appends to a buffer and
    splits a piece; the pieces still need a tree to find an offset in
    the log of their number, and the buffer grows with every edit); a
    gap buffer (cheap typing at one place, a copy of the gap's distance
    when the caret jumps, and no old text to restore without a copy).
  - An editor in a scroll container scrolls it to show its caret after
    the caret moves by keys, typing, an input method, AT-SPI, undo, or
    the application's `siv_set_selection` (`Window.reveal`, handled after
    layout by `text_node.settle`), by the least distance that shows the
    caret's line. Pointer presses and drags, which put the caret where
    they point, and select-all do not scroll. Before, Ctrl+End left a
    multiline editor's caret out of view, and an application could not
    show a search result at all; found when benchmarking jumps in long
    documents (D13). Alternative: a public call to scroll an offset into
    view (an application would still need to call it after every
    keyboard move).
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
  - Scroll distance has one source, `platform.Scroll.delta`, which the
    compositor (for the container it scrolls) and the UI (for handlers
    and `scroll_by`) apply to the raw event, each once. A wheel detent
    (`axis_value120`, or `axis_discrete` × 120 before wl_pointer v8)
    scrolls a viewport `extent` logical pixels long by extent^(2/3), as
    GTK 4 does (`get_wheel_detent_scroll_step`), but at least 60 pixels,
    about Firefox's three lines, and at most the extent: 100 pixels for
    a 1000-pixel list, about four of siv-columns' 26-pixel rows, and 60
    below 465 pixels. High-resolution fractions scale it, and the steps
    win over the distance the compositor sends beside them, which is 15
    per detent and which Hyprland rounds to whole detents for
    high-resolution wheels (`emulate_discrete_scroll`). Touchpad
    distances (axis source finger or continuous, in surface pixels) are
    multiplied by 4, Firefox's factor (GTK 4's GDK delta × 40 for the
    pan gesture over GTK 3's ÷ 10); kinetic scrolling starts from the
    multiplied velocity, as in GTK. Other distances (no source, or a
    wheel without steps, as `siv_test_scroll` injects) are used as sent.
    Scale plays no part: axis values are surface (logical) pixels.
    Before, a detent scrolled the compositor's 15 pixels (GTK 4: 71 to
    100 for 600- to 1000-pixel views; Firefox: about 57) and a touchpad
    1:1, which users found too slow. Elsewhere: GTK 4 scales touchpads by 2.5
    (`MAGIC_SCROLL_FACTOR`); Qt 6 scrolls three single steps a detent
    (three rows in item views) and turns touchpad pixels into
    angleDelta × 12; Chromium scrolls 120 pixels a detent and
    multiplies touchpad distances by 12 (2.5 behind a disabled flag).
    No setting: no portal or GNOME key sets scroll speed, and the
    compositors that have one (Hyprland's and sway's `scroll_factor`,
    KWin's scrolling speed) scale both the steps and the distances
    before siv sees them. Ctrl+wheel zooms by detents, not distance.
  - Key text omits C0 control characters and DEL; the keysym identifies those
    keys. A key that continues or cancels a compose sequence is delivered
    with `composing` set and no text, so shortcuts still see it.
  - Keysyms are the schema enum `siv_key`, which names the keys
    applications commonly bind (navigation, editing, function keys,
    modifiers, and the XF86 Back, Forward, Copy, Cut, Paste keys):
    `SIV_KEY_ESCAPE` in C, `.escape` in Zig, `"escape"` in Lua. It is
    open: every other keysym passes through as its number, and character
    keys are their Latin-1 code point (`'a'`). Found by the file manager
    in `apps/files`, which, like every program and the stock widgets,
    had written out its own keysym table.
  - Routing (`src/ui/input.zig`): pointer events go to the topmost
    hit-testable node (or the node a button press went to, until release)
    and bubble to the root until a handler stops them; keyboard events
    start at the focused node. Default actions run unless a handler
    prevented them: a
    primary press focuses the nearest focusable ancestor, a release over
    the pressed node activates it, Tab and Shift+Tab move focus in tree
    order (logical, so the same in RTL), Enter and Space activate the
    focused node, and arrow and page keys scroll the nearest scroll node.
    Touch drives the primary pointer until gestures exist.
  - Pointer buttons are primary, secondary, middle, back, and forward
    (a mouse's side buttons: evdev BTN_SIDE or BTN_BACK, and BTN_EXTRA
    or BTN_FORWARD), and every press and release also carries the
    button's evdev code (`siv_event.button_code`), so an application
    binds any other button without siv naming it. Found by siv-files,
    whose history buttons are what users press the side buttons for;
    they were all "other".
  - Touchpad gestures (pointer-gestures, version 3 for holds) are
    `platform.Gesture` events: swipe (three or more fingers), pinch
    (scale relative to the start, rotation since the last event, the
    fingers' motion), and hold, each with begin, update, and end or
    cancel. The compositor routes pinches (D8); in the UI the rest bubble
    as `gesture` events (`SIV_EVENT_GESTURE`) from the node under the
    pointer when the gesture began, and the gesture's later events go
    there too, as a press's do. A pinch no handler prevents zooms the
    nearest zoomable scroll node (`siv_set_scroll_zoom_range`), as does
    Ctrl+wheel, by 10% a detent, so a zoomable view zooms the same with
    a mouse. Nodes with a gesture handler get a wheel region, like nodes
    with a scroll handler, so pinches over them reach the UI first.
    Viewport events carry the zoom. Sway cannot make gestures on its
    headless backend: the integration test binds the real gesture
    objects (version 3) and feeds their listeners, as for touch.
  - Tablets (tablet-v2, `src/platform/Tablet.zig`): each seat's tablet
    seat tracks tools and pads. A tool's events are collected until its
    `frame` and become `platform.TabletTool` events in the order
    proximity_in, down, motion (only when nothing else happened), buttons,
    up, proximity_out, each carrying the tool's whole state (position,
    pressure and distance 0 to 1, tilt and rotation in degrees, slider -1
    to 1, wheel, tip contact, kind, axes, hardware serial), so a stroke
    starts from `down` with its pressure. While a tool is near a window
    it shows that window's cursor, through cursor-shape-v1's tablet tool
    device or the theme's first frame. Pad buttons, rings (degrees),
    strips (0 to 1), dials (detents), and mode switches become
    `platform.TabletPad` events for the window the pad focuses, with the
    control's group and that group's mode, so an application can give a
    control one action per mode.
  - Tablet events in the UI (`SIV_EVENT_TABLET`) use the pointer's
    phases: enter and leave for proximity, down and up for the tip
    (button primary) and the tool's buttons (BTN_STYLUS secondary,
    BTN_STYLUS2 middle, others other), move for motion. They bubble from
    the node under the tool, or the node the tip went down on until it
    lifts. High-frequency motion (tablets report at 200 Hz and more)
    costs handlers one call per frame: motion is queued on the window
    and delivered at the start of the next frame (a safe point, D5, before
    viewport handlers and layout, so what a handler draws shows in that
    frame), one move event per run of one tool's samples, whose
    `samples` hold every position since the last move, oldest first, in
    the node's coordinates (`siv_tablet_sample`, laid out like the
    tree's samples so C gets them without a copy). A sample carries every
    axis `siv_tablet_axes` names, the wheel as the degrees it turned
    since the previous sample (the event's `wheel` is their sum), and
    ends in four reserved fields: the struct is a frozen value struct
    (D2) and tablets keep adding axes (D30). Any other tablet or
    pad event delivers queued motion first, keeping order; more than 256
    queued samples are delivered at once, for windows that draw no
    frames. This is the web's rAF-aligned pointer events with coalesced
    events, without a second, unaligned stream: drawing programs want
    every sample, everything else the latest. Alternative: an event per
    sample (handlers and hit tests at the tablet's rate on the UI
    thread); coalescing in the compositor thread's outbox (no fewer
    wakeups, and the latency is a frame either way).
  - Unless a handler prevents it, a tablet event then acts as the
    pointer: proximity enters and leaves, motion moves, the tip clicks
    with the primary button, BTN_STYLUS and BTN_STYLUS2 with the
    secondary and middle ones. Compositors send tablet-v2 clients no
    emulated pointer events, so without this a pen could not press a
    button; a canvas that handles the pen's events keeps them for
    itself. Pad events (`SIV_EVENT_PAD`) go from the focused node up, like
    keys, with no default action.
  - Sway on its headless backend has no tablets: the integration test
    checks that the tablet seat binds and feeds tool, pad, and ring
    listeners events for the real surface (tools fed without a
    compositor object make no cursor requests). `examples/sketch.lua`
    draws pressure-sensitive strokes from the samples, erases with the
    eraser end, and zooms with pinches; the headless Lua test drives it
    with injected tablet and pinch events against golden images.
  - Pointer constraints and relative motion are per window and on
    request: `siv_window_set_pointer_constraint` locks or confines the
    pointer to a node's box (the root: the whole window), one-shot by
    default (the compositor's deactivation ends it, as browsers' pointer
    lock does) or persistent, and with the relative flag sends the node
    relative motion as pointer move events marked relative (accelerated
    and raw deltas, also while locked or against an edge). The tree keeps
    the request and sends the box again whenever layout moves it; a
    removed or hidden node ends it. The platform makes the constraint for
    every seat's pointer (pointer-constraints) and a relative pointer per
    seat on the first request (relative-pointer), forwarding relative
    motion only to windows that asked. The compositor decides when a
    constraint is active; window events (`pointer_constrained`,
    `pointer_unconstrained`) report it, and after a one-shot constraint
    ends, asking again makes a new one. Window-level rather than a node
    property: the protocol constrains a surface, one at a time, and a
    lock is a mode the application enters (a 3D view's drag, a game)
    rather than a property of a node in the tree.
  - Shortcut inhibition (`siv_window_inhibit_shortcuts`,
    keyboard-shortcuts-inhibit) asks for the compositor's own shortcuts
    as keys while the window has focus, for remote desktops, virtual
    machines, and terminals; `shortcuts_inhibited` and
    `shortcuts_restored` window events report what the compositor
    granted.
  - Verified on sway 1.12 (`zig build test-integration`): a lock over
    the focused window activates at once, a virtual pointer's motion then
    arrives only as relative motion (the pointer stays put), and ending
    the lock lets it move; sway grants a shortcut inhibitor to the
    focused window. The headless backend grants both at once and
    simulates the compositor ending a constraint.
  - Every pointer, key, and scroll event names its target, the node it
    was delivered to first (`siv_event.target`), so a handler on an
    ancestor tells its own events from a descendant's: a list row ignores
    keys aimed at an editor inside it (renaming the item in place). A
    primary press in an editor is the editor's: its release activates no
    ancestor. Found by the file manager in `apps/files`, whose rename
    field lost every space to the row's selection keys.
  - A handler's result (`siv_event_result`) makes two separate requests,
    as the DOM's `stopPropagation` and `preventDefault` do: `stop` keeps
    the event from the ancestors, `prevent` skips the default actions
    (the node's `siv_on_default` handler, those of the nodes above, and
    siv's own: typing, focusing, activating, Tab), `handled` is both,
    and `pass` neither. Once prevented, the event bubbles on with
    `SIV_EVENT_PREVENTED`. It is one enum rather than two flag bits so
    that a C handler returning `true` still means handled. So an editor
    can keep its keys from the window's shortcuts (`stop`) and still type
    them, and an application can veto a press's focus change without
    hiding the press from ancestors (`prevent`). `siv_window_get_focus`
    names the focused node, where key events start. Found by the file
    manager in `apps/files`, whose window-wide shortcuts saw every key
    typed into its search, location, and rename fields: with one
    `bool`, it had to track focus on each editor to leave Backspace to
    them. Alternative: two flag bits (a C `return true` would then mean
    stop alone, silently changing behavior).
  - Keys have a capture phase. Before the focused node sees a key, it
    goes down from the root through the capture handlers of the focused
    node's ancestors and the node itself (`siv_on_capture`, so far keys
    only), root first, with `SIV_EVENT_CAPTURING` set. The same results
    apply: `pass` goes on; `handled` ends the key (no other handler, no
    default); `stop` skips the remaining capture handlers and every
    `siv_on` handler on the way up, while `siv_on_default` handlers and
    siv's own defaults still run, as `stopPropagation` in the DOM's
    capture phase leaves the default action; `prevent` goes on, marked
    prevented. A node's capture handler is a tree handler kind of its own
    (`key_capture`) beside the sixteen event types. Found by
    siv-columns, a vim-style file manager: a focused list row's default
    handler takes Space, Enter, the arrows, and the page keys before any
    ancestor, and `bind` gets the row's body, so the application's
    keymap had to go on the body's parent, leaning on the row's shape.
    With a capture handler on the window's root, the keymap sees every
    key first and passes those it does not bind. Alternatives: rows that
    ask the view root's handler first (one widget, not the general
    case); a window-level key callback outside the tree (no stop,
    prevent, or focus-relative routing).
  - Focus moved by the keyboard shows a ring drawn by the core (2 px,
    outside the node), so keyboard-only use works without widget code;
    focus from a pointer press shows none. Its color is the theme's
    `focus_ring` (D29). Inside a scroll node the ring stays within the
    content's extent (the content box, or the viewport where the content
    is smaller), moving inside the node's box on the sides where it would
    pass that edge, so the viewport's clip cannot cut it: a view row is
    as wide as its viewport, and its ring lost its sides (and the first
    row its top). Rows keep their layout; found by the user guide's tree
    and table screenshots. Alternatives: insetting every row's ring
    (rows in no scroll node would differ for nothing); padding the
    viewport by the ring's width (changes every scroll node's layout).
  - Focus the application moves (`siv_node_focus`) follows the input
    modality, as CSS :focus-visible does: each window remembers whether
    its latest key press or pointer, touch, or tablet press came last,
    and the moved focus shows the ring after a key. So arrow keys in a
    composite widget, which move focus from a key handler, mark where it
    went, in stock widgets (radio groups, tabs, view rows) and an
    application's alike, and a click that moves focus elsewhere does
    not. Before, `siv_node_focus` never showed the ring, so keyboard
    users lost their place in every roving widget; found by the user
    guide (`docs/guide`), whose arrow-key sample showed it. Alternative:
    a flag on `siv_node_focus` (every caller would pass the modality it
    cannot know better than siv).
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
    - A popup and its parent's response to the input that opened it show
      in one refresh. The protocol makes a popup's first buffer wait for
      its configure (a round trip), so it cannot be committed with the
      parent's frame; instead the parent's frames wait (up to 50 ms) until
      the popup's first frame, and the parent's is rendered right after it
      in the same loop iteration, so both commits leave in one flush (a
      Vulkan present flushes the connection) and the compositor takes them
      together. Popups up to 512×512 logical pixels present with the CPU
      renderer: creating a swapchain for each menu opened took about 2 ms
      before its first frame. Measured on the gallery's menu button (sway
      1.12, 60 Hz), click to menu shown, median of 20: headless output
      19.5 ms before, 5.7 ms after, popup and parent in the same refresh 0
      and 15 times in 20; on a KMS output with real vblank (vkms) 30.5 ms
      before, 19.6 ms after, same refresh 0 and 17 times. The parent's
      own response to such a click comes about as much later (headless
      3.1 to 5.9 ms), since it waits for the popup.
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
      `on_event`. With `SIV_POPUP_AT_RECT` it is placed against a
      rectangle inside its anchor (`anchor_rect`, in the anchor's
      coordinates from its last layout) instead of the anchor's box, and
      `siv_menu_open_at` opens a menu at a point of a node: a context menu
      at the click. Before, a menu could open only below a node, so the
      file manager in `apps/files` moved a 1×1 anchor node to the pointer
      and opened the menu a frame later, after the anchor's layout.
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
  - Tooltips are a core primitive, not a widget: `siv_set_tooltip(txn,
    node, text)` gives any node one, so application widgets (D22) get
    them as stock ones do.
    - The tree (`ui.input`) decides when: the pointer resting on a node
      or a descendant without a tooltip of its own, or keyboard focus
      (with the focus ring, so not a click) arriving on it, asks the
      host for that node's tooltip; a press, a key, scrolling, the
      pointer leaving, or the node's removal asks for none. After a
      press or key the tooltip stays hidden until the pointer reaches
      another node, so typing in a field does not bring it back.
    - The coordinator (`src/app`) decides how: after 500 ms (GTK's
      value; the settings portal has no such setting), or at once
      within a second of the last tooltip hiding, as the user moves
      along a toolbar, it shows the text in an `xdg_popup` without a
      grab, `tooltip` placement, and the theme's inverse colors, at most
      360 pixels wide. Such popups take no pointer input (an empty input
      region), so the pointer reaching one does not leave the node and
      hide it.
    - The delay is not an application setting: one application with a
      shorter delay than the rest would make the desktop inconsistent,
      and the user, not the application, is the one with a preference.
      If the settings portal ever offers a tooltip delay, siv follows it
      as it follows the double-click time.
    - The tooltip is the node's accessible description (D18) unless the
      node sets one or the tooltip repeats its name, as an icon-only
      button's does; the popup itself has the `tooltip` role. Screen
      readers read the description on focus, so the popup is not
      announced.
    - Before, an application wanting a tooltip built a popup itself and
      timed it with `siv_timer_start`, and stock icon-only buttons had
      none (D30).
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
      positive scale and its clips are rectangles, and it is opaque or
      (with alpha-modifier-v1, below) uncovered.
      Promoted frames go to a synchronized `wl_subsurface` as a wl_shm
      buffer from the producer's own memory (no copy), scaled with
      `wp_viewport` and cropped to the clips through its source rectangle.
      If nothing painted later overlaps it, the subsurface is above the
      window. If something does (video controls), it goes below the window
      and composition punches a hole: the window is cleared to transparent
      over the visible part (a `src`-blend layer), so the opaque frame
      shows through and the later content composites over it there.
      Rounded or rotated clips, other transforms, and opacity that the
      compositor cannot apply composite the frame as an image
      (`bgrx8_srgb`). Changing modes redraws the layer.
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
        one shows at once, scaled to whatever frame it has. Rotated
        placements, and translucent ones that something covers or that
        a compositor without alpha-modifier-v1 shows, are cropped on
        their bounding box and go below the window with a hole at full
        opacity. It is shown in one place only.
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
    - Frame callbacks under covering frames: compositors send frame
      callbacks only to surfaces that are visible (wlroots culls occluded
      scene buffers), and an opaque promoted frame over the whole window
      (fullscreen video, a webview filling its window) hides the window,
      so the frame clock waited forever for the window's callback and the
      window never presented again, black if it happened before its first
      frame reached the screen. Each frame that asks for a callback on the
      window now also asks on every shown frame-slot subsurface (a frame
      request and a bare commit, cached until the window's commit), and the
      first callback of the set ends the frame; the others are destroyed.
      Embedders' surfaces are left out (their commits are theirs), so an
      embedder surface covering the window still hides its callbacks.
      Presentation feedback stays on the window, so a covered window's
      frame clock predicts from the output's refresh. Found by
      siv-webview's spike; checked on sway 1.12 with its Vulkan renderer
      (`zig build test-integration`: a Vulkan window covered by a
      promoted udmabuf frame animates; without the change it stops).
      Alternative: never promote a frame that covers the window (a
      fullscreen video would then be copied every frame).
    - Explicit synchronization (linux-drm-syncobj-v1) for every buffer
      siv attaches itself. Requirement: NVIDIA's driver sets no implicit
      fences on the dma-bufs it writes or reads, so polling a frame's
      dma-buf says nothing there, and `wl_buffer.release` can come while
      the compositor's GPU still reads the buffer, after which a producer
      overwrites what is on screen.
      - Covered: dma-buf frames on frame slots' subsurfaces, the only
        buffers siv attaches that are not wl_shm or single-pixel. Not
        covered, and why: shared-memory frames and siv's windows and
        popups (the CPU renderer presents wl_shm, which compositors read
        or copy at commit; the protocol takes only dma-bufs,
        `unsupported_buffer` otherwise), Vulkan windows (Mesa's WSI makes
        the surface's `wp_linux_drm_syncobj_surface_v1` itself; a second
        is `surface_exists`), embedders' surfaces (likewise their EGL's or
        Vulkan's), and the solid-color subsurfaces below (single-pixel
        buffers have no contents to wait for).
      - Producers' acquire fences: `ExternalFrame.fence` (in C,
        `siv_external_frame_desc.fence` with `SIV_EXTERNAL_FRAME_FENCE`)
        is a sync_file signaled when the frame's writes are done, from an
        exported Vulkan semaphore or EGL native fence. The compositor
        thread watches it in its loop instead of the dma-buf (a sync_file
        polls readable once signaled), the readiness path of implicit
        fences: the previous frame stays until it signals, and composited
        frames are copied only after it.
      - Attaching: the platform opens the render node of linux-dmabuf's
        main device (for a primary node, its sibling in sysfs, else the
        node itself) at the first dma-buf frame, and needs timeline
        syncobjs and `DRM_IOCTL_SYNCOBJ_EVENTFD` (Linux 6.6), which a probe
        syncobj shows. Each attachment gets an acquire point on one
        timeline, signaled from the CPU as it is attached (siv attaches
        only frames whose writes are done, so there is nothing to wait
        for), and a release point on a timeline of its own, since the
        compositor may signal release points out of order and signaling
        one signals every earlier point on it; release timelines are
        pooled and reused once their point signaled. The surface's syncobj
        object is made at its first dma-buf and destroyed before a
        shared-memory frame is attached to it.
      - Release: an eventfd per buffer in flight, registered on its
        release point, is a loop source; when it fires the buffer is
        released, as `wl_buffer.release` does under implicit
        synchronization (a frame still goes back only once every
        wl_buffer made from it was released). `wl_buffer.release`,
        undefined while the surface has a syncobj object, is ignored for
        such buffers.
      - Fallback: implicit synchronization when the compositor offers no
        global (pixman sway, older compositors), there is no main device,
        or the device lacks timelines or eventfd waits (logged once). If
        anything fails after that (an ioctl, an allocation), explicit
        synchronization is off for the connection: every surface's syncobj
        object goes before its next attachment, and buffers already in
        flight keep their release points.
      - Alternatives: passing a producer's fence on as the acquire point
        without waiting for it (the compositor would wait instead, but a
        composited frame needs the same readiness, the previous frame must
        stay on screen meanwhile, and the commit carrying it waits for the
        window's frame anyway, so nothing is gained); importing the
        dma-buf's implicit fence into the acquire point
        (`DMA_BUF_IOCTL_EXPORT_SYNC_FILE`, the same as the CPU signal once
        siv has waited for it); a thread blocking in
        `DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT` for kernels before 6.6
        (compositors that offer the protocol, wlroots for one, need
        eventfd waits themselves); exporting release points as sync_files
        (needs a fence already attached to the point, which the compositor
        adds only when it submits its work).
      - Verified: the frame fence path on the headless backend (a pipe
        stands in for the sync_file); the ioctl numbers against drm.h;
        on sway, that pixman sway offers no global and frames keep
        implicit synchronization. The dma-buf integration test asserts
        explicit synchronization wherever sway offers the global (a GPU
        renderer, `SIV_SWAY_RENDERER=vulkan`, on Linux 6.6), with its
        releases (sway stopped, then resumed) coming from release points,
        and the syncobj test (`platform/syncobj.zig`) runs on any render
        node. On an AMD GPU (Radeon 760M, RADV, Linux 7.2) with sway 1.12
        (wlroots 0.20.2), whose Vulkan and GLES2 renderers offer the
        global: every attachment carries its acquire and release points
        (WAYLAND_DEBUG), each frame goes back only once the eventfd on its
        release point fired with the point signaled, bare commits (moves,
        fades) with the dma-buf still attached are accepted, and with the
        global hidden (`WLR_RENDER_NO_EXPLICIT_SYNC=1`) frames keep
        implicit synchronization and `wl_buffer.release`. Not verified:
        NVIDIA. Reverse if a compositor's release points prove
        unreliable where `wl_buffer.release` is not; then wait for both.
    - Translucent placements (alpha-modifier-v1): a placement whose
      layers' opacity multiplies to less than 1 stays on its subsurface
      when nothing covers it, above the window with the compositor
      applying the opacity (`SubsurfaceState.alpha`; for an embedder's
      surface siv commits it, as for the viewport). A fade of such a
      placement is a bare commit per step, not a repaint. Covered, a hole
      cannot show it at less than full opacity (it clears the window to
      what is below it, the desktop), so frames are composited and
      embedders' surfaces go below at full opacity, as without the
      protocol. Before, every translucent frame was composited and every
      translucent embedder surface was shown at full opacity. Verified on
      the headless backend and on sway, whose screenshot (grim,
      wlr-screencopy) shows the frame blended at half opacity. The
      compositor blends as it does: sway's pixman and GLES2 renderers
      blend encoded sRGB values (50% blue over white gives 128), its
      Vulkan renderer linear light (186) as siv does (187), so on the
      former a translucent promoted frame looks darker than the same
      frame composited by siv.
    - Backgrounds (single-pixel-buffer-v1): an external view's
      `background` fills its content box behind the content, such as the
      bars around letterboxed video. While the content is on a
      subsurface, an opaque background is a solid-color subsurface
      directly below it (a 1×1 single-pixel buffer scaled by its
      viewport, `SubsurfaceState.background`) and the window paints
      nothing there: above the window with the content, or below it with
      the window's hole covering the whole box (a punch-through hole). A
      translucent one goes on a subsurface only above the window; below
      it the window paints it, under a hole over the content alone, as it
      does any background while the content is composited or the
      compositor lacks the protocol. The background takes the content's
      alpha, and the placement's occlusion counts its box, so content
      over a bar puts both below the window. Requirement: a fullscreen
      player's window is otherwise a window-sized buffer of black that the
      compositor blends under the video every frame; a solid-color buffer
      it can treat as a color (culled, or a plane's background), and the
      window's own pixels there never change. Verified on the headless
      backend and on sway (screenshots show the bars from the solid
      subsurface, which the probe shows attached).
    - The escape hatch: protocols siv does not support itself (content
      type, tearing control, toplevel tags, protocols yet to come) are
      reachable without forking siv. `siv_app_get_wayland` returns siv's
      `wl_display`, and `siv_window_get_wayland` a window's `wl_surface`
      and `xdg_toplevel` (null for popups); both are null on the headless
      backend. The rules, in the header and the guide:
      - Never commit the surface, attach or damage a buffer, or change
        its size, scale, regions, or role; never set a listener or user
        data on either object; never make an `xdg_toplevel` request siv
        makes (title, app id, parent, size limits, states, move, resize,
        window menu). siv owns presentation, configure acks, and the frame
        clock (D8, D12): a commit of the application's own would present a
        buffer siv did not choose, ack the wrong serial or none, and break
        frame pacing.
      - Never create an object of an interface siv or Mesa's Vulkan WSI
        may already have on the surface (`wp_viewport`,
        `wp_fractional_scale_v1`, `wp_fifo_v1`, `wp_commit_timer_v1`,
        `wp_linux_drm_syncobj_surface_v1`, `wp_tearing_control_v1`,
        `wp_alpha_modifier_surface_v1`, color management and
        representation, decorations, dialogs, icons, sessions, foreign
        exports): each allows one per surface, and a second is a protocol
        error that ends the connection.
      - Only set extra double-buffered state, which siv's next commit of
        the window applies; `siv_window_request_commit` makes siv commit
        at its next frame even if nothing changed (a bare commit, as for
        subsurface changes).
      - Threads: requests may come from any thread (libwayland serializes
        them); siv's compositor thread reads the display with
        `wl_display_prepare_read` and dispatches its default queue, so the
        application binds through an event queue of its own and never
        dispatches, reads, or round-trips the default queue, as for
        surface slots above.
      - Lifetime: the objects are the window's and go with it (also when
        a close request its `on_event` does not take destroys it); the
        application destroys what it made on them first.
      - The guide's sample (`docs/guide/examples/wayland.c`) binds
        content-type-v1 this way; run on sway by hand, it sets the type
        and siv's commit applies it, without protocol errors.
      - Alternatives: a siv call per protocol (each an ABI addition and a
        maintenance cost for protocols few applications need); a hook that
        runs application code on the compositor thread before each commit
        (ties the application to siv's thread and frame timing, while the
        protocols it would serve only need state set before some commit);
        handing out the surface without rules (applications would commit
        it, and every frame-clock bug would be theirs and siv's at once).
        Reverse if applications need state in the same commit as a
        particular frame; then add the hook.
    - External nodes are in the C API (D27): `siv_external_view` over
      `siv_external_create` and `siv_external_create_surface` slots.
  - Fractional scale, preferred buffer scale, output hotplug, `xdg-activation`,
    idle inhibit, `xdg-dialog`, toplevel icons, and session restore.
    - Built: fractional scale (`wp_fractional_scale_v1` with
      `wp_viewporter`), else `wl_surface`'s preferred buffer scale, else
      the scale of the outputs a window is on, with outputs added and
      removed as the compositor announces them (`src/platform/Wayland.zig`);
      xdg-foreign-v2 exports of toplevels (portal dialog parents, D19);
      and xdg-activation-v1 tokens and activation. Sway marks an
      activated window urgent unless `focus_on_window_activation focus`;
      the integration test sets it.
    - Native dialogs: a window created with a parent
      (`siv_window_desc.parent`, xdg_toplevel.set_parent) stays above it,
      and with `SIV_WINDOW_MODAL` is modal (xdg-dialog-v1 where offered,
      so compositors can attach and dim it). siv keeps input from the
      parent while a modal dialog is shown, on every compositor: button
      presses, keys, scrolling, touch, gestures, tablets, input-method
      text, and relative motion for the parent and its popups go
      nowhere, while motion, focus, and modifiers still arrive. Without
      that, modality would depend on the compositor (sway 1.12 has no
      xdg-dialog). A dialog is destroyed with its parent, before it, as
      popups are. When to use which: siv's in-window dialog (`siv_dialog`,
      a modal node, D22) is the default, since it looks and behaves the
      same everywhere, follows the window, and needs nothing from the
      compositor; a native dialog suits content that should move on its
      own, be larger than its parent, or outlive a glance (preferences,
      properties, a second document view). Reverse if compositors
      without xdg-dialog become rare and native dialogs prove the better
      default.
    - Another application's window can be a native dialog's parent:
      `siv_window_desc.parent_handle` takes the handle that window
      exported (xdg-foreign v2), as a portal request names it
      ("wayland:HANDLE", or bare), and siv imports it
      (`zxdg_importer_v2`, `set_parent_of`) before the first commit, so
      the compositor stacks the window over it and, with
      `SIV_WINDOW_MODAL`, makes it modal through xdg-dialog. siv cannot
      keep input from another client, so modality there is the
      compositor's. An "x11:" handle, one the compositor does not know
      (the import is destroyed at once), and a compositor without
      xdg-foreign leave a window without a parent rather than failing:
      the caller asked for a dialog, and a plain window still serves.
      Found by siv-columns, which serves the FileChooser portal: its
      picker belongs to the window that asked for it. Sway floats a
      toplevel with a parent, which the integration test checks.
    - Window icons (`siv_window_set_icon`, xdg-toplevel-icon-v1): a
      themed name, an image, or both. A name goes to the compositor at
      once; siv also loads it through the icon module (`ui.Icons`, so the
      application's own icon directories count) once, at the largest
      size the compositor prefers, and sends it drawn at each preferred
      size (32, 48, 64, and 128 without a preference) times the window's
      integer scale, for compositors that cannot find the name, as for
      icons only the application installs or Flatpak applications. Vector
      images are drawn at each size, others sent once at their own size,
      centered in a square (the protocol takes square wl_shm buffers).
      The icon object and its buffers are kept until replaced: the
      protocol needs the buffers for as long as the icon exists and the
      icon until a commit applies it, for which a mapped window commits at
      once. A newer call drops icon loads still on the way.
    - Session restore (xdg-session-management-v1):
      `siv_app_start_session` joins the session an earlier run's
      `created` event named, or a new one, with a reason (launch,
      recover, restore), and windows with a `session_name` (unique, the
      same every run) created afterwards are restored before they map
      (`restore_toplevel`, so before the first commit), reported by a
      `restored` window event; windows that already exist are added.
      Sessions are the application's to keep: siv returns the id and
      never stores it. A repeated name is skipped with a warning instead
      of the protocol error; ids and names longer than 255 bytes are
      refused. `siv_app_remove_session` asks the compositor to forget it;
      without the protocol the callback gets `unavailable`. The headless
      backend keeps sessions process-wide, as a compositor outlives its
      clients, so a test restores a window in a second application.
      Compositors remember a toplevel's state when its xdg_toplevel is
      destroyed while it is still in the session (KWin 6.7 does), so a
      window destroys its xdg_toplevel before its toplevel session
      object; and libwayland's server destroys a client on hangup without
      reading what it sent last, so a connection with a session waits (at
      most 100 ms) for the compositor to process the windows' destruction
      before it disconnects. Both found against KWin 6.7.5
      (`kwin_wayland --virtual`), where a second run then restores the
      window; sway has no session management, so this is not in the
      integration tests.
    - Also checked by hand, not in the tests: labwc (wlroots 0.19) and
      KWin 6.7.5 take the modal dialog role and window icons (KWin asks
      for 96 px icons, labwc states no size) without protocol errors.
    - Idle inhibition: the portal's Inhibit (D19) and idle-inhibit-
      unstable-v1 behind one call, `siv_inhibit`. The rule: an inhibition
      of idling alone for a window uses the compositor's protocol when it
      has one, since it holds exactly while the window is visible (a
      video, a presentation, a game), needs no portal or D-Bus, and ends
      with the window; anything else (logout, user switching, suspend, or
      idling without a window, as for a download or music) goes to the
      portal, the only path for those, as does idling on compositors
      without the protocol. The platform counts inhibitions per window
      and keeps one inhibitor while any is held. Verified on sway 1.12
      with an ext-idle-notify client: with the window inhibiting, the
      seat never goes idle within a 300 ms timeout; without, it does.
    - Sway 1.12 offers none of xdg-dialog, xdg-toplevel-icon, or session
      management, so the integration test checks that they degrade
      (a dialog is a toplevel with a parent, setting an icon reports it
      unsupported, a session `unavailable`) without protocol errors;
      their behavior is tested on the headless backend through the C
      API.

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
    items, table rows and cells, and similar roles without a label take
    their name from their descendants' text, as ARIA 1.2 names them (a
    focused row of a file list reads "notes.txt 1.2 kB ... Text", not
    nothing; found by the file manager in `apps/files`).
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
    input (D15). Masked editors have neither. In a long text, extents
    and character queries lay out the block they reach if it was evicted
    or estimated (D13), and answer nothing if that fails for memory. Copies carry the serial of
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
  - The root of a window without a title bar (a layer or lock window,
    D31) is AT-SPI's `window` rather than `frame`.
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
  - Applications use D-Bus through `siv_dbus_*` (`src/abi/api_dbus.zig`,
    implemented in `src/abi/dbus.zig`), so a file manager can mount
    drives over UDisks2 and serve org.freedesktop.FileManager1 without a
    second D-Bus library or loop.
    - `siv_dbus_connect` gives the session bus (the application's own
      connection, shared with portals and accessibility; unavailable on
      the headless backend), the system bus, an address, or a connected
      socket (tests, embedders); the others are connections of their own.
    - Messages are written and read value by value with D-Bus type
      codes (`siv_dbus_message_write_int(m, 'u', 3)`, `_write_open(m,
      'a', "{sv}")`, `siv_dbus_reader_read_type`, `_read_enter`), so C,
      Zig, and Lua read and write any signature with sixteen functions
      instead of one per type; the encoder checks each value against the
      signature as it is written. A failed write marks the message, the
      writes after it do nothing, and sending it fails
      (`siv_dbus_message_status` says why), so a builder needs no check
      per call. A string read into too small a buffer reads nothing and
      reports its length, which is how the Lua binding grows its buffer.
      A call flagged `secret` (a LUKS passphrase for UDisks2) is built
      with an allocator that zeroes memory before freeing it and never
      remaps, and the connection wipes its body after writing it rather
      than reusing the buffer, so the secret does not linger in the heap
      (siv-files' unlock dialog; the masked editor already keeps typed
      text in locked memory, D15).
    - Calls take one callback with the reply, an error reply, or a
      failure (type `failed`: NoReply on timeout, Disconnected), at a safe
      point after the call returns. Signals are subscriptions on a match
      (sender, path, path namespace, interface, member, arg0); names are
      owned and watched with a callback per change.
    - An exported object is one interface at one path, copied from a
      descriptor: calls reach `on_call` with an invocation handle, which
      the application answers then or later (a reply whose signature is
      not the declared one becomes an error reply), and properties go
      through `get_property` and `set_property`; introspection,
      Properties with PropertiesChanged, and Peer come from the
      connection. An invocation not answered when its object or
      connection goes gets an UnknownObject error, so callers never wait
      for a timeout.
    - Handles follow D2: everything made on a connection goes with it,
      with destroy-notifies; readers live only during their callback.
      Closing a connection from one of its own callbacks defers freeing
      it to a later dispatch.
  - Settings come from the portal (color scheme, accent, contrast, reduced
    motion, text scale, cursor theme and size, double-click time, caret
    blinking, and fonts on GNOME and KDE), applied live, with built-in
    defaults when no portal runs. Fonts come from Fontconfig elsewhere,
    and the user's theme from its files (D29).
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
      scale reshapes text and measures and redraws canvases, whose text
      follows the text scale too (D28).
    - Fonts come from Fontconfig's generic families: `sans-serif` for UI
      and document text and `monospace` for monospace text, which the
      user's fonts.conf and conf.d resolve, as they do for Qt
      applications and terminals; Omarchy's `omarchy font set` rewrites
      ~/.config/fontconfig/fonts.conf so that its font comes first for
      `monospace`, and sets no GNOME key. The portal's font names
      (GNOME's font-name and monospace-font-name, KDE's fonts) and the
      size they carry apply only on desktops that own a font setting,
      which their users change instead of Fontconfig's configuration:
      GNOME and KDE, by $XDG_CURRENT_DESKTOP's colon-separated names
      (`ubuntu:GNOME` counts). There "monospace" in a text style
      resolves to the portal's monospace family (`ui.Fonts`
      `setMonospace`). Elsewhere (sway, Hyprland and Omarchy, niri) the
      portal's GTK backend reports GNOME's defaults, Adwaita Sans and
      Adwaita Mono, which nobody chose there, so they are ignored and
      the size is 11 pt, times the text scale, which the portal does
      carry on every desktop (Omarchy's `omarchy display text size`
      sets it). No signal in the portal is cleaner: KDE's portal answers
      for org.kde.kdeglobals only on KDE, but GNOME's keys come from the
      GTK backend on every desktop that runs it. `siv_app_set_default_font`
      still wins for the default family.
    - Fontconfig's configuration is followed live (`src/app/fontconfig.zig`):
      the directories of every configuration file the last load read
      (`FcConfigGetConfigFiles`: fonts.conf, conf.d, what they include),
      and `$XDG_CONFIG_HOME/fontconfig`, its conf.d, and their parent
      even before they exist, are watched with inotify on the loop as
      D29 watches theme files: nothing runs while idle, a burst is one
      reload after 50 ms of quiet. A change loads Fontconfig again on
      the worker pool (`FcInitLoadConfigAndFonts`, which reads its
      caches), then the loop swaps the snapshot, drops every resolved
      chain, and reshapes text in every window, so `omarchy font set`
      changes open windows' monospace text. Only where the desktop's
      settings apply (a display, without
      `SIV_APP_FLAGS_NO_DESKTOP_SETTINGS`). Newly installed fonts are
      not watched for; a configuration change picks them up.
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
    - Any MIME type, as drags do: `siv_clipboard_write_data` offers MIME
      lines and data split by `lengths` (D27), each type written to
      whoever asks for it through the loop like text, and
      `siv_clipboard_read_data` names the types it takes, preferred first,
      and gets the first one offered as raw bytes up to the transfer
      limit, by a post like a text paste. A file manager copies files as
      text/uri-list with x-special/gnome-copied-files to say whether a
      paste moves them, and pastes files other applications copied; found
      by the file manager in `apps/files`. `ui.Clipboard` keeps one text
      for every text type of a text copy and per-type data otherwise, and
      learns which type a paste picked.
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
      which a move deletes the data). Icons are `ui.Image`s shown at
      their logical size, at their scale where it is a whole number (the
      icon surface's buffer scale), the hotspot in logical pixels; vector
      images are rasterized at the window's scale rounded up. Rendering
      a node into an icon still waits for a renderer the UI thread can
      use; `siv_image_draw` draws one instead, with canvas operations
      rasterized on the CPU. The icon can be replaced while the drag
      lasts (`Window.setDragIcon`: a new buffer on the same surface,
      offset so the new hotspot is under the pointer), to show what a
      drop would do, and the drag cancelled (`Window.cancelDrag`: the
      source destroyed, its node hearing the end with no action), for
      Escape where the compositor still sends the window keys. A drag
      started without an icon has no surface to give one later.
    - The target decides the action, not only the source: a handler's
      `enter` or `move` may choose one (`dnd.setAction`) over its
      preferred one, until the drag leaves it, so that a file manager
      moves within a filesystem and copies across. Drop events carry the
      keyboard modifiers, and a modifier change during a drag routes it
      again (another `move`), so Shift and Ctrl take effect without the
      pointer moving; found by Strider's in-window drags. When the tree
      changes under a drag that rests (a spring-loaded folder opened, its
      row replaced), the frame that lays it out routes the drag again if
      another target is under it now, as hover is refreshed; without it,
      the release dropped on nothing.
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
      with its activation token, and `siv_app_run` returns
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
      IconThemePath is the last directory the application added for its
      icons (`siv_app_add_icon_path`, D19), so a host finds the
      application's own icons by name; vector images (SVG files, themed
      icons) become 64 px pixmaps, which panels scale down to their 16
      to 48 px.
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
      Each load returns a `siv_image_request` and takes a priority, which
      orders it among queued compute jobs (D6): cancelling one that waits
      means it never decodes, and one being decoded is dropped when it
      returns; either way only the destroy-notify runs. A grid of
      thumbnails asks newest first and cancels what scrolled out of
      view, so scrolling past thousands of photos decodes only those
      shown. Found by the file manager in `apps/files`, which kept its
      own queue, three in flight, to avoid decoding everything it bound.
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
      Debug builds leave libjxl out unless `-Djxl` (JPEG XL then fails
      as unsupported, and its test skips): compiling it with Highway was
      most of a cold `zig build test`, and one test decodes JPEG XL
      (D25, Build cost). Release builds and `-fsys=libjxl` include it,
      so CI, which links the system's, runs that test.
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
    - Two modules: `src/icon` (imports nothing) finds files, `src/svg`
      (imports `scene` and `raster`) parses SVG and lowers it to display
      lists (D9), so the CPU renderer, Vulkan, and PDF draw icons with no
      code of their own. `ui.Icons` (one per application, like
      `ui.Fonts`) holds the theme name and a cache and loads on the
      worker pool; `ui.Image` gains a vector variant (`Image.vector`).
    - Lookup (`icon.Themes`) is the specification's FindIcon: the theme,
      its index.theme parents, hicolor, then unthemed files in the base
      directories and /usr/share/pixmaps. Base directories, in order:
      directories the application adds (`siv_app_add_icon_path`, its own
      icons), $XDG_DATA_HOME/icons, ~/.icons, $XDG_DATA_DIRS/icons. A
      directory matches by Size, Scale, and Type (Fixed, Scalable,
      Threshold), else the closest by DirectorySizeDistance wins;
      directory order breaks ties, then base order. Every name (and its
      fallbacks) is tried in a theme before its parents, as GTK does, so
      a theme's own `folder` beats its parent's `folder-documents`.
      KDE's ScaledDirectories are read with Directories.
    - Names: several, one per line, the first found winning; generic
      fallbacks shorten at dashes keeping `-symbolic`
      (`folder-documents-symbolic` → `folder-symbolic`); in right-to-left
      layouts `-rtl` variants come first (Adwaita has both
      `go-next-rtl-symbolic` and `go-next-symbolic-rtl`); a style asks
      for each name's symbolic or regular variant first (GTK's
      FORCE_SYMBOLIC and FORCE_REGULAR).
    - Formats: SVG and PNG. XPM is not decoded. GTK's `.symbolic.png`
      (a channel-coded rendering for GTK's recoloring) is not an icon
      file to siv: its name ends in `.symbolic`, so the lookup passes it
      and finds the theme's scalable SVG of the same icon.
    - Each theme's index.theme is parsed and every directory it lists is
      read once (getdents, names keyed to directory and format), on first
      use, on a worker under the `Themes` mutex; later lookups touch no
      files. Icon loads run on the pool's blocking lane (D6): the theme
      read and the file read wait on the file system, while parsing an
      icon takes a fraction of a millisecond. Measured on this orb (Debian 12, ReleaseFast, warm page
      cache, the C allocator): Adwaita 43 (5,555 files in 97
      directories) in 3 to 5 ms, Breeze 5.103 (8,700 files and links in
      86 directories) in 8 to 12 ms, a cached lookup in under 1 µs.
      GTK's icon-theme.cache (a prebuilt hash of the same names) would
      skip the scan; reverse if theme reads show up at startup. Themes
      are not watched for newly installed icons.
    - The theme comes from the portal: GNOME's icon-theme, else KDE's
      org.kde.kdeglobals.Icons Theme (D19 settings), else Adwaita, GTK's
      default (hicolor follows every theme anyway);
      `siv_app_set_icon_theme` fixes one. A new theme or search path
      drops the cache, and image nodes showing icons load them again.
    - Cache: loaded icons by names, logical size (rounded), scale,
      direction, fallbacks, and style, with misses remembered, within a
      memory budget (16 MiB: a vector icon's document arena, a PNG's
      pixels, and a small cost per entry), dropping the least recently
      looked-up entries when a load would exceed it (loads in flight
      stay). A dropped icon costs nothing on screen: display lists copy
      paths and retain pixels; a node that paints it again loads it
      again, so the budget sits far above what windows show (thousands of
      vector icons, about 60 PNGs of 256 px).
    - Image nodes show an icon by name (`siv_image_view_desc.icon`, with
      `icon_size`): the node's intrinsic size is the icon's from the
      start, so nothing moves when it arrives; until then it shows
      nothing, and the window repaints icon nodes when a load finishes.
      A window's first frame waits for the icons it shows, as long as it
      may wait for the settings: 100 ms from the window's creation. The
      frame is built (which starts the loads), but while icons load and
      the time has not passed it is not committed; its changes go with
      the commit of the frame that comes when the icons arrive or the
      time is up. Measured end to end (`test-integration`,
      `SIV_MEASURE=1`, ReleaseSafe, headless backend, stand-in portal,
      the installed Adwaita): a window showing 20 icons (12 symbolic
      at 16 px, 8 PNG at 48 px) presents its first frame, with all of
      them, a median 11–13 ms after `App.create`, against 6.4 ms
      without icons (the settings arrive after 6 ms): the theme's read
      takes 3.5 ms and a load 10–150 µs (an SVG parse or a 48 px PNG
      decode), on the blocking lane, with the general-purpose allocator
      (the testing allocator's bookkeeping made loads ten times slower).
      That fits the 100 ms well, so icons do not pop in; a slower disk delays the first frame by at most the
      same 100 ms and then the icons arrive later. Canvases draw icons by
      name (`siv_draw_icon`) and draw again when a missing one loads, as
      with fonts (D28), as do printed pages. `siv_icon_load` delivers an
      icon as a `siv_image`, which does not follow later theme changes,
      and returns a `siv_image_request` like `siv_image_load`, so a grid
      scrolled past its icons cancels them (`siv_image_request_cancel`
      releases the user data at once and drops the icon when it arrives;
      priorities apply to decodes only, icons load in order on the
      blocking lane). `siv_image_load` parses SVG files into vector
      images too.
    - Vector images draw from the document on every paint: the display
      list copies the paths, so nothing ties the list to the document.
      Where pixels are needed (drag icons, tray pixmaps) the ABI
      rasterizes a vector image with the CPU renderer.
    - Symbolic icons (`*-symbolic`) follow GTK's convention: shapes take
      the foreground; shapes of class `success`, `warning`, or `error`
      take those colors. siv's foreground is the node's color (literal or
      token, else `window_fg`); success and warning are theme tokens
      added for icons (D29), error is `destructive`. Where GTK's style
      sheet (`rect, circle, path { fill: fg !important }`) differs, siv
      chose: every basic shape and path is recolored, not only rect,
      circle, and path; strokes are recolored like fills; `fill="none"`
      stays unpainted (GTK's `!important` fills it); and a color that
      already stands for a KDE role keeps that role. The opacity
      attributes stay.
    - KDE's convention (Breeze, FollowsColorScheme): the
      `current-color-scheme` style sheet's `.ColorScheme-*` rules set
      `color`, which shapes use through `currentColor`. A `color` set by
      a rule whose selector is one such class stands for its role
      (Text, View, Button, and Window text: foreground; their
      backgrounds: background; Highlight, focus, hover, and link colors:
      accent; HighlightedText: accent_fg; Positive, Neutral, and
      NegativeText: success, warning, error), so Breeze folders take the
      accent and its text-colored icons turn light in dark themes, as
      KIconLoader does. siv recolors these wherever they appear, without
      reading FollowsColorScheme: outside Breeze-like themes the classes
      do not occur.
    - SVG subset (`svg.parse`): XML with entities (including a
      DOCTYPE's internal ones), the `<style>` sheets and `style`
      attributes (selectors of names, classes, ids, attribute tests,
      `:first-child`, descendant and child combinators; specificity,
      source order, `!important`, `inherit`), presentation attributes,
      inheritance; `svg` (view box, preserveAspectRatio, nested), `g`,
      `a`, `switch`, `use` (with `symbol`), path, rect, circle, ellipse,
      line, polyline, polygon; transforms; fill and stroke with their
      opacities, rules, widths, joins, caps, miter limits, dashes, and
      paint-order; linear and radial gradients (units, gradientTransform,
      spreadMethod, href inheritance, a focal point outside the circle
      moved onto it as SVG 1.1 says); opacity, mix-blend-mode, and
      isolation; clip paths; luminance and alpha masks; and the filters
      icons use: one feColorMatrix (matrix, saturate, hueRotate,
      luminanceToAlpha) or one feGaussianBlur; embedded images (`image`
      with a base64 `data:` URI in any format siv decodes, placed by
      preserveAspectRatio, at most 1024 × 1024 pixels), which Adwaita's
      full-color icons use for shading since release 45. Left out: text,
      images in files, patterns, markers, and other filters; an element
      whose filter is not drawable draws without it (a drop shadow is
      lost, not its shape); color filters and mask luminance do not apply
      to images, which then draw nothing. Of the installed themes, every one of 647 Adwaita
      and 8,704 Breeze SVGs parses.
    - Lowering: transforms are applied to the points, so paths reach the
      list in the root's user space; strokes under non-uniform transforms
      go in a transformed layer so their outline follows. Opacity of a
      single draw folds into its paint; groups with opacity, blend modes,
      or clips become layers. A clip path's shapes join into one path
      filled nonzero (exact unless their windings cancel; one shape keeps
      its clip-rule). A mask is an isolated layer of the content whose
      last child is the mask's content composited with dst_in, its colors
      turned into alpha (luminance times alpha, or alpha for mask-type
      alpha) per paint, which is exact for the white and black masks
      icons use and approximate where colored mask shapes overlap. A
      feColorMatrix applies to each paint's colors, exact for its uses in
      icons (Adwaita's masks recolor shapes white). A blur is an isolated
      layer clipped to the filter region whose content is blurred by a
      backdrop blur, which PDF leaves out (D9), so printed blurs are
      sharp. An embedded image's pixels live in the document's arena, so
      a display list drawn from a document with images retains the
      document (`Document.has_images`), unlike one of paths only.
    - Clip paths that coincide with what they clip: renderers combine a
      clip's coverage with a draw's by multiplying them (D9), which along
      an edge the two share squares its coverage, and exporters (Adwaita
      since 45) wrap every shape in a clip path of the same outline, so
      edges came out thin and light (10% of Adwaita 48's full-color icons
      differed from librsvg, whose clipping intersects the outlines
      exactly). The lowering takes out of a clip layer what the clip path
      does not cut: a fill that holds the clip path draws as the clip
      path, one inside it as itself, and a nested layer whose clip lies
      inside keeps only its own; what still needs the clip stays in
      copies of the layer, in order (an isolated layer only loses its
      clip when nothing needs it). Containment is tested on the flattened
      outlines, within a thousandth of the view box (`svg/contain.zig`). The PDF writer draws an isolated layer ending in a dst_in
      layer through a soft mask of that layer's alpha, so masks print.
    - Compositing (D11): SVG content composites in sRGB, as the
      specification's `color-interpolation: sRGB` default says and as
      icon designers' tools and every other renderer do. A drawing gets
      an sRGB layer (`Layer.srgb`, D9) at its root, except a document of
      one solid draw, which looks the same either way and stays a plain
      draw. `color-interpolation: linearRGB` is honored where a file sets
      it: on the root (no sRGB layer), on a container (its content gets a
      layer of its own space when that differs from its parent's), and on
      a gradient. Isolated layers inside (opacity, blend modes, masks)
      keep the space they are in. A blur filter works in
      `color-interpolation-filters`' space, linearRGB by default, with
      the element drawn in its own space in a layer inside; a
      feColorMatrix applies to linear or encoded components the same way.
      Gradients interpolate in the space of the layer they draw in; where
      the gradient's color-interpolation differs, the lowering adds
      sub-stops computed in the gradient's space (premultiplied), 16 per
      interval while at most 256 fit, within half a level of 8 bits. Role
      colors are resolved when drawn, so the sub-stops are computed then.
      What an icon's layer holds composites onto the window in linear
      light like everything else, so only an icon's edges against what
      is below it differ from GTK's. An sRGB layer costs an isolated
      buffer per drawn icon (on Vulkan a render pass break), which the
      lone-draw exception spares most symbolic icons.
    - Measured (`zig build test-integration-icons`: every SVG of the
      installed themes drawn by siv and by librsvg's rsvg-convert at
      32 px; an icon differs when over 2% of its pixels are off by more
      than 24 of 255). Geometry, with the icon and a white background in
      one sRGB layer so that siv blends exactly as librsvg does: 0 of 648
      Adwaita icons and 8 of 5,052 Breeze icons (0.16%) differ. As siv
      draws them, against librsvg's pixels composited over white in
      linear light: also 0 and 8 (before sRGB layers: 0 and 1,178, 23%).
      The 8: three with text (kwave, kbruch, applets-template), which siv
      leaves out, one with filters it leaves out (rocs's drop shadows), and four
      within a few percent of the threshold from antialiasing of
      overlapping subpaths and many blurs (firewall-applet-shields_up,
      kmahjongg, kiten, preferences-desktop-navigation). Four earlier unexplained ones
      were siv's bugs or the test's, now fixed: a one-stop gradient's
      stop-opacity was replaced by fill-opacity instead of multiplied
      (yakuake); the root clipped to its view box instead of its viewport,
      cutting content beyond the view box that meet leaves visible
      (kdesvn); circles and ellipses started at the top instead of at
      (cx + rx, cy) as SVG says, which moves dashes
      (tool_elliptical_selection); and the test drew non-square icons
      (preferences-desktop-touchscreen's 32 × 33 view box, an
      animation's 16 × 240 sprite sheet) into a square where
      rsvg-convert's viewport is the intrinsic size scaled to fit. The
      test fails above 1% for either theme.
    - The comparison is opt in (`zig build test-integration-icons`, not
      part of `test-integration`): what it finds depends on the installed
      theme releases, which adopt SVG features at their own pace, and a
      gate must fail on siv's bugs, not on a machine's packages. Adwaita
      48 (Arch) differed in 10.1% of its 70 full-color icons, from the
      exporter's clip paths and embedded images above. Measured with
      `SIV_ICON_ADWAITA` pointed at unpacked releases, geometry and as
      drawn: Adwaita 43 (Debian 12) 0 and 0 of 648; 48.1, 0 and 1 of 701;
      51.0, 0 and 1 of 715 (0 and 1 of the 70 full-color ones, which
      alone would fail the 1% bound by one icon). The one as drawn is
      application-x-addon, whose differing pixels are where its embedded
      192 × 152 shading image shows at 32 px; likely cause, not yet
      confirmed: siv's renderers sample a minified image bilinearly
      without averaging its area, which librsvg does. What it
      found stays checked in the default tests: the svg module tests and
      a test icon written as exporters write them
      (`hicolor/scalable/apps/siv-test-exported.svg`) in the icons golden
      image.
    - Verified: module tests for lookup (siv's test themes in
      test/icons/themes: inheritance, hicolor, sizes, scales, fallbacks,
      RTL), the cascade, symbolic and KDE recoloring, gradients, clip
      paths, masks, and `use`; golden images of the test icons
      (test/golden/render/icons.png, which Vulkan matches) and of icon
      buttons, menus, image nodes, and canvases in light, dark, and
      another icon theme (test/golden/widgets/icons-*.png); and the
      real-theme comparison above in `test-integration-icons`. Adwaita and
      Breeze are LGPL and CC-BY-SA, so neither their files nor images of
      them are in the repository (D25): the integration test reads the
      installed packages (adwaita-icon-theme, breeze-icon-theme) and
      makes its reference with librsvg (librsvg2-bin), a test-time tool
      like gdbus. The test themes are siv's own drawings (MIT).
    - Fuzz targets: the SVG parser (XML, CSS, path data, lowering, and
      drawing) and index.theme (D25).

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
  - A text node may set its base direction (`siv_text_style_desc.direction`:
    auto, ltr, rtl) apart from its layout direction, which still aligns
    it. Text with no strong character, such as a date "2026-10-13 14:05",
    otherwise takes an RTL node's direction and shows its runs of digits
    swapped; set to ltr, it reads in order and stays flush with the
    node's start. This is the isolation applications would otherwise get
    by inserting U+200E, which then shows up in accessible names (AT-SPI
    clients read "\u200e2026-10-13"); the text stays unmarked. Found by
    the file manager in `apps/files`. A per-node property rather than a
    span attribute: the case is a whole label (dates, sizes, paths), and
    a span would need isolates inserted into the bidi pass. Reverse if
    mixed runs inside one label need it.
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
  table, and grid with selection models, menus, combo boxes, popovers, dialogs,
  tabs, split panes, sliders, spin buttons, progress, toasts. Theming uses compiled design
  tokens plus runtime overrides, follows the portal accent and color scheme, and
  includes a high-contrast variant (D29). Animation respects reduced motion.
  - **The boundary is enforced by the build.** `src/widgets` imports only
    `siv`, the generated Zig wrapper of the C ABI (D3); its exports are
    schema functions like any other, checked against the schema by
    `src/abi/abi.zig`. A stock widget therefore can do nothing that a
    widget written in C, Lua, or Rust against `siv.h` cannot. When a widget
    needs something the API lacks, the capability becomes a public
    primitive first. Primitives added this way: hidden nodes
    (`SIV_VISUAL_HIDDEN`, and `siv_set_hidden` apart from the visual:
    a widget draws its own visual, which `siv_set_visual` replaced
    whole, so hiding a text field or a button erased its border and
    fill, and a button set its visual again on hover and reappeared;
    found by siv-files), modal nodes (`SIV_SEMANTICS_MODAL`), the value
    step, editor placeholders, transitions, themed colors and text sizes
    (D29), default handlers and default layouts, `siv_node_emit`, node data,
    the widget interface (`siv_set_widget`),
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
    primitive builders (D27): `siv_push_button(txn, parent, &desc)` appends the
    widget and returns its root node, or 0 once the transaction has failed
    (sticky errors, D4; a widget reports its own invalid arguments with
    `siv_txn_fail`). The root is an ordinary node: layout, `siv_move`,
    `siv_remove`, and semantics overrides apply to it, and removing it
    removes the widget. Parts that hold several items are built item by
    item with child builders (`siv_radio` under a radio group), so items
    are nodes too and no descriptor needs an array of strings, which the
    schema cannot express. Child builders take descriptors like the
    others (`siv_radio_desc`, `siv_tab_desc`, `siv_menu_item_desc`,
    `siv_column_desc`), so an item gains options without a new function:
    a radio disabled from the start was the first (D30). Text fields and areas return the editor node
    itself, so every editor function (text, selection, change events)
    works on them unchanged.
  - **Driving:** a few functions cover every widget instead of setters per
    widget kind: `siv_widget_set_label`, `siv_widget_set_icon`,
    `siv_widget_set_disabled`, `siv_widget_set_value` and
    `siv_widget_get_value`, `siv_widget_set_range`, and
    `siv_widget_get_part`. A widget's value is one double: 0 or 1 for
    toggles (0.5 is mixed), the chosen index for choices, the number for
    ranges. They are transaction operations, so a value change lands in
    the same frame as the tree changes around it.
  - **The widget interface.** The generic calls know no widget kinds:
    each dispatches through the node's interface, a `siv_widget_desc`
    set with `siv_set_widget` (callbacks for `set_label`, `set_icon`,
    `set_disabled`, `set_value`, `set_range`, `get_value`, `get_part`,
    and `focus`, with user data and a destroy-notify), copied and kept
    with the transaction like handlers (`src/abi/widget.zig`). Stock
    widgets set theirs on their root through the same public call
    (`setInterface` in `src/widgets/widgets.zig`), so an application's
    widget, such as the canvas dial in `examples/gauge.c` and
    `examples/gauge.lua`, answers `siv_widget_set_value` and the rest
    exactly as a slider does, and generic code (a form library, the Lua
    binding, an inspector) drives both without telling them apart.
    - siv checks what every widget would check before calling: a string,
      a finite value, min at most max and a step of at least 0. A NULL
      callback refuses its call with `SIV_ERROR_INVALID_ARGUMENT`, as the
      stock widgets refused calls that do not apply to their kind.
      Setters run inside the caller's transaction, which they are given,
      and report what they refuse with `siv_txn_fail`; getters run
      outside one and return their answer (a part's node, or 0 for none),
      since callbacks have no out parameters (D3).
    - `focus` makes `siv_node_focus` on a widget focus the node it
      chooses: a view's cursor row (moving the cursor to the first row if
      it has none), the selected tab or radio, a spin button's field, a
      split pane's divider. Roving focus otherwise needs a call per
      widget kind, which only stock widgets could have.
    - `siv_widget_part` is open (D2): an application's widget answers for
      the named parts and numbers its own from 0x10000 up. `siv_menu_item`,
      `siv_menu_open`, and `siv_menu_get_item` take a menu or any widget
      whose `menu` part is one, so an application's own menu button works
      with them as the stock one does.
    - Before, the calls switched on the stock widget's kind inside
      `src/widgets`, so they failed on every other node: a Lua
      application could not drive its own dial with `widget_set_value`,
      and code that drives widgets generically had to special-case
      application widgets.
    - Alternatives: a widget class registered once (a type handle) with
      per-node user data (one more handle type and lifetime to save a
      copy of eight pointers on widget roots only, which a hash map by
      node keeps); events (`siv_node_emit` of a `set_label` event: events
      return no value for `get_value` and `get_part`, and the `siv_on`
      slot is the application's, so its handler would swallow the
      widget's own calls); a public enum of stock kinds (a closed set no
      application widget could join).
    - Reverse if a generic call needs an answer the callbacks cannot
      give, or interfaces show up in profiles of large trees.
  - **Events** go through `siv_on` on the returned node, as for
    primitives: `activate` for buttons, `change` with `value` (and `index`
    for choices) when the user or assistive technology changed the value,
    `select` with `index` for menus and views. Setting a value from the
    application does not report it.
  - **Behavior lives in default handlers.** A widget installs its pointer,
    key, activate, focus, and `set_value` handling with `siv_on_default`,
    which runs only when the node has no `siv_on` handler of that type or
    it returned pass or stop, and nothing below prevented the default.
    So `siv_on` stays the application's on every node, a stock widget
    never takes a handler slot away from it, and an application overrides
    a behavior by returning handled or prevent. Widgets report
    their own events with `siv_node_emit`, which runs the same two slots.
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
    - A toast may carry an action (`siv_toast_desc.action`, "Undo"): a
      button in its card, in the accent since a flat button's control
      color does not read on the inverse surface. Pressing it reports
      `activate` on the toast, which then closes; such a toast stays 8 s
      by default instead of 4, and only its action takes the pointer.
      Found by siv-files, which drew an undo bar of its own because
      toasts took text only.
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
      hides (`siv_set_hidden`), and removes. `siv_menu_open` builds the
      popup from the model each time, leaving out hidden items and the
      separators that would end up first, last, or doubled. Choosing reports `select` with the item's position (separators
      count) after the popup is gone; Up, Down, Home, End, Enter, Space,
      a mnemonic keysym per item, and Escape work as in WAI-ARIA's menu.
      `siv_menu_get_item` finds an item by that same position, so an
      application that builds menus from tables checks and disables items
      by index; found by the file manager in `apps/files`, which walked
      the menu's children to do it.
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
    - A combo box (`siv_combo_box`, options added with
      `siv_combo_box_item`) is a button showing the selected option that
      opens the options below it in a popup (WAI-ARIA's select-only
      combobox). Its options are a model like a menu's (hidden children
      holding their labels), so they are nodes the application relabels,
      disables, and removes, and the list is built from them on each
      opening, the selected option focused and checked. Its value is the
      selected index, through the generic `siv_widget_set_value` and
      `siv_widget_get_value` like a radio group's, and choosing reports
      `change` with value and index; `siv_widget_get_part` with
      `SIV_WIDGET_PART_ITEM` finds an option by index.
      - Closed, Up, Down, Home, and End select at once (as Qt's combo box
        does), skipping disabled options; Space, Enter, a
        click, or Alt+Down open the list, where the same keys move the
        focus without choosing, Enter, Space, or a click choose, and
        Escape or Tab close it unchanged.
      - Typeahead: typed text within a second of the last key (the key
        events' timestamps, so no timer) selects, or in the list focuses,
        the next enabled option whose label starts with it,
        case-insensitively for ASCII; the same letter typed again cycles
        through the options that start with it.
      - Semantics: the root is a `combo_box` named by the descriptor's
        label and `expanded` while the list is open; the list is a
        `list` named the same, its rows `list_item`s with `selected` on
        the chosen one.
      - RTL needs nothing of its own: the row's layout, the popup's
        `below` placement, and the check mark's end edge are logical.
      - The list scrolls past 320 pixels and is at least as wide as the
        combo box.
      - Alternatives: a menu button whose menu items are radio-checked
        (no selected value to read or set, and screen readers announce a
        menu rather than a choice); an editable combo box (a text field
        with completion, which the editor and a popup already allow;
        reverse if applications keep building one).
    - A popover is a popup whose root is a card with a content part.
      Dialogs are modal overlays over a parent stack (a scrim and a card
      with title, text, content, and actions parts) that take focus.
      Toasts are live regions at the bottom of a parent stack that fade.
      All three report `close` (Escape, a click outside or on the scrim,
      a timeout); the default handler closes them, and an application's
      `siv_on` handler that returns true keeps them.
    - Buttons, toggle buttons, check boxes, and switches take a mnemonic
      keysym, underlined at the first matching letter of the label. In a
      dialog, the key alone presses the first enabled control with it
      (Alt and the key while a text field has focus, which types the
      letter otherwise), so a dialog is driven from the keyboard with its
      accelerators in view, as menu items' mnemonics drive menus.
    - Parts the application fills are reached with
      `siv_widget_get_part` (dialog content and actions, popover content,
      tabs and panels, split panes, a menu button's menu, a table's
      column header cells, a combo box's options).
  - **Icons** (D19): push, toggle, and menu buttons take a themed icon
    name (`icon` in their descriptors), shown before the label in the
    label's color token, so it follows hover, press, disabled, and theme
    changes; with `SIV_WIDGET_ICON_ONLY` the label is hidden and becomes
    the button's accessible name, and the button is square; the label
    also shows as the button's tooltip (D17), since a sighted user
    otherwise has only the icon to go by. The button sets the tooltip
    when its label or icon changes, so an application's own
    `siv_set_tooltip` on it holds until then. Menu items
    take one too; when any item of a menu has an icon, every row has the
    slot, so labels line up. `siv_widget_set_icon` changes the icon, as
    `siv_widget_set_label` the label (the file manager's view toggle
    shows the view it switches to). The image node's setter replaces the whole
    view, so a widget keeps the icon's name in a hidden text node to
    recolor it: public primitives only, and no string storage of the
    widget's own. Found by the file manager (`apps/files`), whose
    Back, Forward, and Up buttons were text.
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
      rebuilds: set whenever an earlier bind filled the row, for the
      same item too (a rebind), not only for another (the reference
      said only another until the user guide's table sample read it). A
      rebind of everything (`siv_view_refresh`, a new count,
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
    - The frame (border, rounded corners, clip) is the view's root; its
      header and scroll sit inside the border, the header's top corners
      and the scroll's open corners rounded to the border's inner curve.
      Clipping is to the border box, so a header filling the root's
      width painted over the left and right border and the top corners'
      arc, and selected rows over the sides (siv-files' table showed a
      broken top-left corner next to its sidebar).
    - A primary press on a view's own empty space (below the rows, or
      its frame) focuses the view and goes no further. Applications
      listen for an item's activation on the view's root, which made the
      root activatable, so such a press, reaching no row, activated it on
      release as a button's would, reporting item 0: siv-columns entered
      its first folder on a click below the last entry. Clicks there
      select nothing and leave the selection as it is; an application
      that wants them to clear it handles the press itself.
    - `SIV_VIEW_FLAT` drops the frame: no border, radius, or inset, so
      rows reach the view's edges square. A view that sits edge to edge
      on a surface of its own (siv-columns' columns, separated by rules)
      has no frame to stay inside; with the frame's inner rounding its
      first selected row had round top corners over square bottom ones.
      Framed stays the default, since a view on a window or a card reads
      as a box. Reverse if flat views need a frame's focus treatment.
    - Selection is a bitset in node data, resized with the count (node
      data of another size replaces the old and keeps what fits); none,
      single, or multiple with Ctrl, Shift, and Ctrl+A. The cursor's row is
      the focused node (roving focus) and stays bound out of view. An
      empty view's scroll node (the list, tree, or table for assistive
      technology) is focusable while the view has no rows, so focus can
      rest in it: `siv_node_focus` on an empty view did nothing, and an
      editor beside it kept the focus (Escape from siv-columns' chooser
      path could not reach an empty folder). Focus in the view follows
      the count after the commit: to the cursor's row when rows arrive,
      to the view when they go. With rows it is not a stop, so Tab
      still stops once. Rows
      handle only keys aimed at themselves (`siv_event.target`, D16) and
      leave presses in an editor inside them alone, so an application can
      rename an item in place with an editor in its row; presses on a
      stock control in a row (a button, toggle, check box, switch, radio,
      slider, spin button, menu button, or combo box) are the control's
      too, since a row that handled the press kept siv from activating
      the control on release (a drive's eject button in siv-files'
      sidebar did nothing). Keys with Alt or
      Super, and Enter with Ctrl or Shift, are left to the application:
      a row's handler runs before its ancestors' and returned handled for
      Alt+Up and Alt+Home (moving the cursor) and Ctrl+Enter (activating),
      so a file manager's window-wide Alt+Up and Ctrl+Enter never ran
      while a view had focus (found by siv-files). The whole
      selection is also read and replaced as a bitset in one call
      (`siv_view_get_selection`, `siv_view_set_selection`), and setting
      one item restyles only its row: the file manager in `apps/files`
      took 0.8 s for Ctrl+A over 100 000 entries and 1.5 s to keep a
      selection across a new sort order with a call (and a restyle of
      every row) per item. A plain press on an item of a larger
      selection keeps the selection, so that a drag from it carries
      every item, and the release collapses it to the item unless a drag
      started (its pointer cancel), as file managers do. `select` names
      the range of rows that holds every item whose selection changed
      (`changed_index`, `changed_count`; a bound, not an exact set, so a
      collapse of scattered items is one range), so an application that
      keeps totals over the selection, such as the size of the selected
      files, reads only that range of the bitset. The cursor is read and
      moved (`siv_view_get_cursor`, `siv_view_set_cursor`, which also
      moves the Shift anchor) and focused (`siv_node_focus` on the view,
      whose widget interface chooses the cursor's row: the view itself is
      not focusable), and the node bind
      filled for a row is reached with `siv_view_get_row` while bound,
      for a menu at the cursor's item. Found by the file manager in
      `apps/files`, which intercepted presses on selected items itself,
      read the whole bitset on every change, and walked the view's
      subtree for the cursor's row. A view has no widget value: its
      value was its cursor, a second way to move it beside
      `siv_view_set_cursor` (which also moves the Shift anchor), and
      views report `select`, not `change`; `siv_view_focus` gave way to
      `siv_node_focus` (D30). Trees
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
      on the header cell (drags when released). The header cell is a
      widget whose value is the width, so the application reads and sets
      it with `siv_widget_get_value` and `siv_widget_set_value` (finding
      a cell by index with `siv_widget_get_part`'s `column` part): the
      value a widget reports in `change` is the value it takes.
      `siv_view_set_column_width` and `siv_view_get_column_width` did the
      same by index and are gone (D30).
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
      `siv_app_get_font_family` (interned names, 0 the default family), not a
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
    script (`SIV_LUA_0.1`), for embedders without a Lua (`siv_lua.h`).
    `siv_lua_push_handle(L, type, handle)` pushes a handle the host made
    (its application, a window, a node) as the binding's userdata,
    never owned by Lua, so scripts a program runs for configuration or
    plugins reach the program's own siv objects; the host names the type
    as `siv.methods` does, since handles are opaque (D2). A Zig program
    linking siv statically gets the same through the `siv-lua-static`
    module: the binding's object (with Lua, unless `-fsys=lua`), the Lua
    C API translated, and `siv_lua.h`'s functions, linked against
    libsiv.a (D25).
    libsiv-lua ships its own NOTICES, with Lua's licence from `lua.h`
    (the tarball has no licence file).
  - **A Lua C module for hosts with their own Lua.** Editors, games, and
    other programs that already embed Lua 5.5 load `siv.so`
    (`lib/lua/5.5/siv.so`, on the default `package.cpath` under a
    prefix): the same binding with only `luaopen_siv` exported and no
    Lua inside, its `lua_*` references resolved from the process that
    loads it, so `require("siv")` works from the stock `lua` interpreter
    and from any host whose Lua symbols are visible to modules (as
    distributions build them). `luaopen_siv` checks the host's Lua
    version and number types with `luaL_checkversion`. The host's
    libraries are its own (the allowlist applies to libsiv-lua);
    `siv.reload` belongs to `siv-lua`, which owns the main chunk.
    Alternative: one library that both bundles Lua and loads into hosts
    (two Lua copies in one process, with states of one used by the
    other). `zig build test-lua` runs `require("siv")` from the stock
    interpreter built from the pinned release.
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
    so fields from a metatable's `__index` do not count; reserved fields
    are not among them. A field whose C name is a Lua keyword also
    takes a plain name, and output tables carry both: span ends are
    `stop` or `["end"]` (`mapping.zig` lists the aliases).
    Enums are names (`axis = "column"`) or integers,
    any integer for open enums (keysyms) and only the values named for
    closed ones; flags a name, a list, a set, or an integer. Value structs take named or positional fields; colors also
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
    tables; a callback returns enums as names, value structs as tables
    or several values, and handles as handles or nil (a widget's
    `get_part` and `focus`). An error in a callback goes to
    `siv.set_error_handler`'s
    function if set; otherwise it is kept, `siv_app_run` is quit, and the
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
    resumes the coroutine from its callback, at a safe point (D5). Given
    a callback, they return their out values (an image load's request,
    to cancel it); waiting drops them. Event handlers return `true` for
    handled or a `siv_event_result` name (`"stop"`, `"prevent"`).
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
    nothing in the binding runs elsewhere, except a job's work.
  - **Jobs.** `app:job_start(flags, work, args, done)` runs `work` on
    the worker pool through `siv_job_start` (`job.zig`, written by hand
    since the work cannot run in the application's state): `work` runs
    in a fresh Lua state of its own on the worker, with only the base,
    string, table, math, and utf8 libraries, and gets copies of `args`;
    copies of its results come back, and `done(true, ...)` or
    `done(false, message)` runs at a safe point. Copies take nil,
    booleans, numbers, strings, and tables of them, 64 deep; `work`
    may use no upvalues but `_ENV`, so the error names a local it
    captured rather than its being nil on the worker. Without `done`
    it waits in the running coroutine like the asynchronous calls.
    Alternatives: no jobs in Lua (CPU work would block the application
    thread or need a C module); one long-lived worker state (shared
    globals across jobs and a lock where siv's pool already schedules);
    lanes-style shared tables (a second runtime to trust). Reverse if
    starting a state per job shows up in profiles (then keep a state per
    worker).
  - **Tests.** The headless test binary (D24) runs the binding on the
    headless backend (`test/lua/binding.zig`: allowlist, errors,
    descriptors, ownership, callbacks, coroutines, jobs, the clipboard,
    hot reload through the real watcher) and `examples/*.lua` unchanged,
    with `app_create` wrapped to pick the headless backend, comparing
    golden images under `test/golden/lua/`, a hot reload included. It
    links the binding as an object compiled from the generated wrapper
    and the schema alone, whose siv_* calls resolve to the exports in the
    binary, and reaches it through its C API (`test/lua/api.zig`), so a
    change in siv does not compile the binding's 10 s of comptime again.
    Against `libsiv.so`, the stock interpreter loads siv.so (`zig build
    test-lua`). Before, a test binary of the binding linked `libsiv.so`
    and compiled again whenever it changed. On sway, the installed
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
  CPU against Vulkan output. `zig build test` stays hermetic, and it is the
  only gate: run it, and wait for it to pass, before every push; CI runs
  it and nothing else. `zig build test-integration` runs the Wayland
  backend against one real compositor, the latest sway on its headless
  backend, pinned through nixpkgs; other compositors are not part of the
  test suite. It also runs D-Bus against a private dbus-daemon, with
  GLib's gdbus as a second client, and AT-SPI against at-spi2-core's bus
  launcher and registry with libatspi as the client, and portals against
  xdg-desktop-portal with a backend of siv's own behind it; the hermetic
  D-Bus, AT-SPI, and portal tests use an in-process test bus over
  socketpairs.
  - Real-compositor testing is not routine (the user's decision,
    2026-10-13, after a cold `zig build test` took 31 minutes on a 4-core
    orb and 77 on GitHub's runner, with the sway suite on top). `zig build
    test-integration` and its `test-integration-*` parts, like
    `test-integration-icons` and `bench-pacing`, are opt-in steps run by
    hand and part of no one's gate. What they need (Nix with the pinned
    sway, wtype, and grim; dbus-daemon and gdbus; xdg-desktop-portal and
    PipeWire; at-spi2-core, libatspi, and Orca; qpdf and poppler; the
    Adwaita and Breeze themes and rsvg-convert) is installed by
    `.agents/setup-integration`, not by `.agents/setup`, so that a normal
    orb sets up with the build's own packages only.
  - CI (`.github/workflows/ci.yml`, GitHub Actions) runs `zig build test
    -j16` on every push and pull request, with no compositor or desktop
    services, in an Arch Linux container: its packages are new enough
    for every `-fsys` option (HarfBuzz 14.6, Lua 5.5, Little CMS, libwebp,
    libavif, libjxl, glslang), so the job compiles none of the vendored C
    and C++ libraries but SheenBidi, which no distribution packages, and
    wuffs, which has no system library (D25, Build cost). Fedora 43 has
    HarfBuzz 11.5 and Lua 5.4, too old; Debian 12, the orb base, has
    HarfBuzz 6.0, no Lua 5.5, and no SheenBidi, and its older lcms2,
    libwebp, libavif, dav1d, and libjxl pass `zig build test` with
    `-fsys`. Its Vulkan tests run on lavapipe. Zig's global cache and the
    fetched packages are cached between runs. `test` already builds the
    examples, apps, the guide, and the Lua module.
  - What `zig build test` builds (consolidated 2026-10-13; there were
    29 test binaries and 45 programs, six of them compiling all of siv):
    - One headless test binary, rooted at `tests.zig` at the top of the
      tree so that it reaches `docs/` and `apps/`: `test/headless.zig`
      (renderers, UI, compositor, the C API, widgets, Lua in process),
      the guide's samples (`docs/guide/tests`), the files app's headless
      tests, and the C examples compiled in with main renamed. It runs
      as eight processes at once, each with every eighth test, through
      `test/runner.zig` (Zig's runner with `--shard`), and always runs:
      the guide reads files the build does not track.
    - A unit-test binary per module (19), since Zig runs only the root
      module's tests; each builds in 1 to 8 s on the self-hosted backend,
      and the text tests run as four processes.
    - `abi-unit`: the schema, generators, handles, descriptors, and
      allocation hooks, which need nothing of siv; the rest of the abi
      module is tested through the C API in the headless binary.
    - What needs the real shared libraries: `abi-wrapper` (the Zig
      wrappers' layouts against the C headers, linking libsiv.so and the
      ABI test library), the C programs `smoke.c` and `app.c` against
      libsiv.so and `abi.c` against the ABI test library, the guide's
      `counter_test.c`, the stock Lua interpreter loading siv.so, and
      the export check of both libraries.
    - The build tools' own tests (`lua-gen-types` with the Lua mapping's
      checks, `notices`, `lua-notices`), built for the host.
    - Programs compiled so that they keep up with the API: siv-lua,
      siv-files, and the guide's Zig package sample. The guide's other
      samples and the C examples build as programs only in `zig build
      guide` and `zig build examples`.
  - The suite (cut 2026-10-13, measured per test with `--time-report`):
    tests stay when they catch a plausible regression through public
    behavior. Removed as covered elsewhere: line breaking's "revision 57"
    case (LineBreakTest has `2013 × 00A0`), bidi's L2 reordering case (the
    conformance tests check every reordering), the app's posted-closure
    test (`test/c/app.c` and the loop's tests), D-Bus's namespace and
    signature-iterator tests (match rules and the signature fuzz corpus),
    the portal option round trip (every portal test), the platform's
    fractional-scale rounding (the headless backend's scale test), a
    span-family test in src/ui (the C API's rich-text golden image), and
    the Lua widgets example's dark theme (the widgets' and the guide's
    dark tests). Made cheaper with the same properties: the block-shaping
    equivalence tests in src/text (fewer rounds, the flat comparison
    after a round's last edit; 16 s to a few), the rope, layout-reuse,
    long-editor, long-text, and paragraphAt tests (smaller texts or fewer
    steps, still past the sizes that pick their paths), the D-Bus large
    message (9 MiB, still past the 8 MiB read pause) and pipelined calls
    (1000), and the Vulkan pipeline-cache test (two devices). Kept: the
    Unicode conformance tests, the wake-race test at 50 000 iterations
    (10 000 missed the bug it guards), the tooltip test's real delays,
    and the fuzz corpora.
  - Run by hand, not in CI, because they need a quiet machine or a real
    GPU: the GPU tests (`SIV_SWAY_RENDERER=vulkan zig build
    test-integration`, sway rendering and presenting on the GPU), frame
    pacing (`zig build bench-pacing`), input-to-photon latency on the
    headless backend (`zig build bench-latency`, D8), the budgets'
    benchmarks (D25), and fuzzing (D25).
  - Protocols sway 1.12 lacks (xdg-dialog-v1, xdg-toplevel-icon-v1,
    xdg-session-management-v1; D17) are covered by the headless tests
    (`test/abi/windows.zig`: dialogs, icons, session restore through the
    C API) and, on sway, by a platform test that they degrade cleanly (a
    dialog is a toplevel with a parent, no icon sizes, an `unavailable`
    session). They were also checked by
    hand against labwc (headless wlroots: dialogs and icons) and KWin
    6.7.5 (all three; KWin asks for 96 px icons and restores a second
    run's windows), which are not in the suite. To repeat it: build
    `pkgs.labwc` and `pkgs.kdePackages.kwin` from the nixpkgs revision
    `.agents/sway.nix` pins (a copy of it with those two paths, then
    `nix-build`); start labwc with `XDG_RUNTIME_DIR` set to a private
    directory, `WLR_BACKENDS=headless WLR_RENDERER=pixman
    WLR_LIBINPUT_NO_DEVICES=1`, and KWin with `dbus-run-session --
    kwin_wayland --virtual --no-lockscreen --socket wayland-k`; then copy
    the sway window-features test in `src/platform/integration_tests.zig`
    into a scratch test that connects to that socket
    (`Wayland.create(..., .{ .display = path })`), run it with `zig
    build test-integration -Dtest-filter=<its name>`, and check that it
    reports no protocol errors, that the dialog has its role, the icon
    sizes the compositor asked for, and on KWin that a second run given
    the first run's session id gets `window_restored`. The check found
    the two session bugs fixed in D17 (destroy order and a sync before
    disconnecting).
  - The desktop shell (D31): sway 1.12 offers every shell protocol siv
    binds except ext-background-effect-v1 (its globals:
    zwlr_layer_shell_v1 5, ext_session_lock_manager_v1 1,
    ext_foreign_toplevel_list_v1 1, zwlr_foreign_toplevel_manager_v1 3,
    ext_workspace_manager_v1 1, ext_idle_notifier_v1 2), so
    `src/platform/integration_tests.zig` checks for real: layer surfaces
    placed by anchors, a toplevel tiled clear of an automatic exclusive
    zone and of a taller one after `setLayer`, a popup of a layer surface,
    an exclusive-keyboard overlay on a hotplugged output that gets wtype's
    keys and is closed when the output is unplugged; the lock with a lock
    surface per output, locked, a second client refused, a lock surface
    for an output plugged in while locked and closed with it, unlocked;
    this client's own toplevels in the wlr list (states, outputs, a title
    change, a close request that reaches the window) and in the ext list
    (an identifier, no management); sway's workspaces, one made by a sway
    command and switching back by request; idle after a timeout and back
    with virtual pointer motion; and that a blur region on sway sends
    nothing. `src/abi/integration_shell.zig` runs `examples/shell.c` on
    sway end to end (the bar lists sway's workspaces and a real window,
    a click switches workspace, the lock button locks, a wrong and a
    right password typed with wtype go through the PAM conversation on a
    worker thread, the session unlocks). Only headless: the blur region's
    geometry and capability changes, denial and takeover of a lock left
    behind by a client that went away, and toplevel and workspace
    requests on objects other clients own (the requests sway took are
    verified on this client's own window and sway's workspaces).
    Background blur needs a compositor with ext-background-effect-v1
    (KWin 6.7, mutter 51, niri, Hyprland after hyprwm/Hyprland#13211);
    none is in the suite, so it was checked by hand: KWin 6.7.5 from the
    pinned nixpkgs (`pkgs.kdePackages.kwin`, with `pkgs.mesa` for
    llvmpipe), started as for the window features above, in an orb
    without a GPU. It offers ext_background_effect_manager_v1 but
    announces no blur capability there (KWin blurs only when it composites
    with OpenGL, which its virtual backend does on a DRM render node), and
    siv behaved as it should: `SIV_CAPABILITIES_BLUR` unset, an effect
    object per surface, no region sent, no protocol error. What remains
    unverified on a real compositor is the region itself, which needs a
    machine with a render node. To repeat it there: a scratch C program
    with a window whose root is translucent and a rounded child marked
    `SIV_VISUAL_WINDOW_BLUR`, run with `WAYLAND_DEBUG=client` against
    `kwin_wayland --virtual` (or niri 26.04 or Hyprland 0.56.2 nested,
    from the same nixpkgs; mutter there is 50.4, before the protocol),
    should log `capabilities(1)`, then
    `ext_background_effect_surface_v1.set_blur_region` with `wl_region.add`
    rectangles matching the child's rounded box in the same commit as its
    frame, again when the child moves, and no protocol error; on screen,
    what is behind the child shows blurred.
  - Not built yet: the inspector. The counters it would show exist
    (`ui.Window`'s, the compositor's presentation timing), and tests and
    benchmarks read them.
  - The user guide (`docs/guide`) is tested like code: every code block
    in it is quoted from a sample in `docs/guide/examples`, and `zig
    build guide` (part of `test`) builds each sample as a program and
    runs it unchanged on the headless backend, driving it like a user and
    comparing its windows with the screenshots the guide shows. C samples
    are compiled a second time with `siv_app_create`, `siv_window_create`,
    `siv_app_run`, and `siv_app_dispatch` renamed to the harness's, which pick
    the headless backend and run the test; Zig samples import a copy of
    the generated wrapper with the same four renamed; Lua samples run
    through the binding with `app_create` wrapped, as the Lua examples'
    tests do. So a renamed function breaks the guide's build, and a
    changed behavior its screenshots.

### D25. Project

- **License:** MIT. Every dependency, code and embedded data alike, is
  under a permissive, OSI-approved licence without copyleft: MIT, BSD,
  Apache-2.0, and others of that kind such as HPND (the wlr-protocols
  descriptions siv generates bindings from, D31, whose notices are
  gathered in `src/notices/wlr-protocols-LICENSE.txt` since that
  repository has no licence file; much of wayland-protocols uses the same
  notice). Embedded data may also carry permissive notices of the same
  kind that are not OSI licences (D13's American English hyphenation
  patterns: FSF all-permissive; the Unicode License v3). Binaries ship a
  NOTICES file. Copyleft stays out, weak copyleft included: no LGPL or
  MPL code, and no protocol under such a licence (org_kde_kwin_blur is
  LGPL). Before, only MIT, BSD, and Apache-2.0 were named, which left
  HPND, a licence of the same kind, to a reading of "permissive notices"
  meant for data; the user widened the rule for wlr-protocols (D30).
  The NOTICES checker (below) checks that every shipped package's licence
  texts are in NOTICES, not which licence they are, so an HPND package
  passes like an MIT one (wlr_protocols does); the kind of licence is
  checked when a dependency is added.
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
- **Build cost.** A cold `zig build test` took 31m42s on a 4-core orb
  (4789 s of CPU) and 77 minutes on GitHub's 2-core runner (2026-10-13).
  Measured with `--summary all`, `--time-report`, step timelines from
  `--webui`, and process sampling:
  - Most of it was vendored C and C++: a C source on a Zig module is
    compiled again by every compilation that includes the module (Zig
    0.17 keys its C object cache per compilation; one libjxl file was
    compiled ten times with identical output), so each test binary that
    imported `image` or `text` compiled libjxl with Highway, HarfBuzz,
    and the decoders in Debug with UBSan, 2 to 4 minutes each.
  - Then siv itself: six binaries compiled all of siv (headless, the
    guide, the files app, the abi module's tests, libsiv.so, and the Lua
    binding against it), each 15 to 26 s, libsiv.so through LLVM; the Lua
    binding's comptime added 10 s to every binary that had it, and three
    of them compiled again whenever libsiv.so changed. Tests ran in about
    70 s of CPU, a third of it waiting on real timers.
  - And the build runner: by default Zig 0.17 makes about two steps at
    once on a 4-core orb (its thread pool has CPU count − 1 slots, and
    a step holds one while it waits on its compiler or test), so
    `zig build test -j16` is the gate's command (AGENTS.md); `-j16` takes
    a one-line change from about 60 s to 28 s.
  So:
  - Every vendored library is compiled into objects (`addObject`), once
    per build, without debug info, and linked through the module that
    translates its header, so libsiv.a still contains it. Zig 0.17's
    linker crashes on an object merged from several C++ files (their
    COMDAT groups, whether merged by Zig or by LLD), so libjxl and
    Highway get an object per file and HarfBuzz's subsetter one unity
    file of its 18 files, which also parses HarfBuzz's headers once
    (24 s in Debug against 170 s per file optimized). HarfBuzz is
    compiled with libc++'s headers but nothing links libc++ for it.
  - C compiles in the build's mode, except HarfBuzz, optimized in Debug
    builds: shaping is most of the text and headless tests' run time,
    which optimized HarfBuzz cuts by a third, while the decoders' tests
    take 0.1 s either way. Debug builds leave libjxl out unless `-Djxl`
    (D19), compile Highway for the baseline target only when it is in,
    and build dav1d without its assembly, so NASM is neither built nor
    run.
  - The shaders' SPIR-V is committed (D10), so glslang is not built.
  - One headless test binary (D24) replaces six, and runs as eight
    processes. The Lua binding is linked into it, into libsiv-lua.so,
    and into the Lua module as objects compiled from the generated
    wrapper and the schema alone, so a change in siv relinks them.
  - The headless latency and smoothness measurements moved to `zig build
    bench-latency` (D8, D24), and the suite was cut where tests cost more
    than they protected (D24, The suite).
  - Measured after, 4-core orb, `-j16`: a cold `zig build test` in
    1m25s with Zig's global cache warm (as in an orb after
    setup, or CI with its cache), 4m19s with every cache empty, of
    which Zig building its own build runner (90 s), translate-c (55 s),
    and runtimes takes about three minutes; a rerun with nothing changed in
    9.4 s (4.6 s before; the headless binary always runs, since the
    guide's tests read files the build does not track); after a one-line
    change in src/ui in 28 to 30 s (1m47s before), of which libsiv.so's
    LLVM compile, 25 s, is the critical path. Without `-j`: 1m48s cold, 13.6 s with nothing changed, 50 s after a one-line change.
    The vendored C now costs about 100 s of CPU once (HarfBuzz 43 s, one
    file on the critical path; its subsetter 24 s; the decoders and Lua
    the rest). Arch with every `-fsys` option (CI) takes 3m29s with
    every cache empty, most of it Zig building its own tools.
  - Not done: libsiv.so from a self-hosted object linked by LLD would
    save LLVM's 17 s on every change, but Zig 0.17 spent more than four
    minutes merging the C objects into that object without finishing;
    `-fincremental` writes objects LLD rejects in Zig 0.17. Module tests
    stay one binary per module: Zig runs only the root module's tests,
    and each builds in 1 to 8 s on the self-hosted backend.
  - Prebuilt C libraries for orbs (the user asked, 2026-10-13): nixpkgs
    at the revision `.agents/sway.nix` pins has HarfBuzz 13.2 (siv needs
    14), no SheenBidi, and libraries that need glibc 2.38 to 2.43, which
    Debian 12's 2.36 cannot load; Debian 12 packages only the decoders
    (lcms2 2.14, libwebp 1.2.4, libavif 0.11.1, dav1d 1.0, libjxl 0.7),
    which pass `zig build test` with `-fsys`; upstream publishes Linux
    binaries only for libjxl (0.11.1 .debs for Debian 12, shared
    libraries), libwebp (a static, position-independent archive), and
    glslang. HarfBuzz, SheenBidi, Lua 5.5, Little CMS, dav1d, and libavif
    have none. Orbs keep building from source: what remains costs about
    100 s of CPU once, and the orb snapshot keeps it.
- **Packaging:** every C dependency has a build option to use the system copy;
  the build installs pkg-config files.
  - siv is also a Zig package: a program depends on it in build.zig.zon,
    imports its `siv` module (the generated wrapper, linked against
    libsiv.so), installs `dependency.artifact("siv")` (libsiv.so) and the
    `notices` named path (NOTICES) beside itself, and builds with siv's
    own steps. The static library's artifact is `siv-static`, installed
    as libsiv.a, so the two artifacts' names differ: with both named
    `siv`, `dependency.artifact` refused the ambiguous name. And the
    NOTICES generator takes siv's own files by builder rather than by
    the lack of a package hash, which siv has as a dependency: it failed
    the dependent's install, reporting siv as a package without a
    licence. Found by the user guide's package sample
    (`docs/guide/examples/zig-package`).
  - A program that ships as one file links siv statically through the
    `siv-static` module: the same generated wrapper linked against
    libsiv.a. One that also embeds Lua for its users' scripts imports
    `siv-lua-static` (D23) and installs the `lua-notices` named path
    beside `notices`. Before, a static consumer recreated the module from
    the wrapper's source and the `siv-static` artifact in its own
    build.zig, and could not link the Lua binding statically at all.
    Found by siv-columns, a file manager configured in Lua.
- **Security:** fuzzing of every parser (rasterizer inputs, SVG,
  image decoders, clipboard and drag-and-drop payloads, Wayland input, D-Bus
  messages, SASL replies, addresses, match rules, portal font strings,
  and icon themes' index.theme files).
  Fuzz targets are `std.testing.fuzz` tests, so `zig build test` (and so
  CI) runs their corpus. Fuzzing itself runs by hand, not in CI: `zig
  build test-<module> --fuzz -Doptimize=ReleaseSafe` for each module with
  targets (dbus, icon, image, platform, svg, ui) fuzzes until stopped
  (Zig 0.17's fuzzer finds no coverage in Debug builds).
- **Budgets:** first frame under 20 ms, input-to-photon within one
  frame, 120 Hz scrolling through a 100k-row virtual list, zero idle CPU and
  wakeups, fixed memory per window. They are checked by hand, not in CI,
  on a quiet machine with a real GPU, since shared CI runners give noisy
  timings and no GPU: `zig build bench-pacing` measures pacing on sway and
  fails past D12's thresholds, and `zig build bench-text`,
  `bench-render-cpu`, and `bench-image -- FILE...` (all with
  `-Doptimize=ReleaseFast`) print timings to compare with the budgets and
  with earlier results before a change that could affect them lands.

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
  - A node's own largest size (`max_width`, `max_height`) wins over a
    parent that stretches it, as CSS max-width does, and the node is
    placed at the start; its own smallest size wins over its largest.
    Before, the parent's minimum won, so a stretched label ignored its
    `max_width` and an inset child of the window's root (which
    stretches) filled the window; found by the user guide
    (`docs/guide`). The window's root is a stack whose alignment is
    stretch on both axes, unlike a stack's default of start, so a single
    child fills the window; `siv_window_get_root` says so.
  - Box is block flow: children stacked vertically and stretched to its
    width. A child with a fraction height takes that fraction of the box's
    height when the box has a definite one (stretched by its parent, or
    sized), as widths resolve against its width; otherwise fractions are
    auto. Split panes are boxes stretched by their flex row, so a list or
    editor fills its pane with a fraction height of 1 (the file manager in
    `apps/files` found the view squashed to its header). Flex has an
    axis, gap, grow, shrink weighted by base size, justification, cross
    alignment, and wrapping. Grid has px, fr, and
    auto tracks, row-major auto placement, spans, and auto tracks that
    share leftover definite space; with indefinite space fr tracks size to
    their content in proportion. Stack overlays children with alignment or
    insets. Scroll lays out like a box in an unbounded content area.
  - There is no min-content size and no margin; gaps and padding space
    things. Borders draw over the padding and do not affect layout.
  - `SIV_VISUAL_CLIP` clips a node's own image or canvas content to its
    rounded border box, not only its descendants (external content
    already was), so a photo with rounded corners is one image node
    rather than an image in a clipping box; found by the user guide.
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
  - **Names** follow one pattern, so a binding can map them mechanically
    (D23's methods): `siv_<object>_<verb>` for an object's calls
    (`siv_window_set_title`, `siv_app_run`), `siv_<verb>` for transaction
    operations on nodes (`siv_set_layout`, `siv_move`, `siv_on`),
    `siv_<object>_get_<thing>` for queries, whether they write an out
    parameter (`siv_node_get_rect`, `siv_app_get_fd`) or return a handle
    (`siv_node_get_related`, `siv_window_get_root`, D2), and
    `siv_<object>_is_<state>` for boolean ones. Only `siv_version`,
    `siv_result_name`, and the builders return a value without `get_`.
    Calls on a node outside a transaction are `siv_node_*`
    (`siv_node_focus`, `siv_node_emit`), except families named for their
    widget (`siv_view_*`, `siv_menu_*`, `siv_editor_*`, `siv_widget_*`).
    Structs that siv fills (events, results) have no `_desc` suffix;
    structs the caller fills do. The pre-1.0 review renamed what broke
    the pattern (D30).
  - One builder per primitive (`siv_box`, `siv_flex`, `siv_grid`,
    `siv_stack`, `siv_text`, `siv_editor`, `siv_scroll`), appending as
    the last child; `siv_move` reorders. Image nodes (`siv_image_view`)
    and canvases (`siv_canvas`, D28) are in, and so are external nodes
    (`siv_external_view`) over `siv_external` slots (D17): frame slots
    take shared-memory frames (`siv_external_submit`) and report each
    replaced frame's key when no frame reads it; surface slots hand the
    embedder a `wl_display *` and `wl_surface *` and report the size to
    render at, with the embedder contract spelled out in
    `siv_external_create_surface`'s documentation. A window takes its
    slots with it.
  - The Wayland escape hatch (D17): `siv_app_get_wayland` (the
    `wl_display *`), `siv_window_get_wayland` (a window's `wl_surface *`
    and `xdg_toplevel *`, the latter optional and NULL for popups), and
    `siv_window_request_commit`. With `siv_external_get_wayland` they are
    the only pointers in the API, as `void *` out parameters, so the
    header needs no Wayland headers. They are application's-thread calls
    (the objects they return may then be used from any thread, by D17's
    rules, which their documentation carries in full); on the headless
    backend they succeed with NULL, as `siv_external_get_wayland` does,
    so that code testing for NULL runs unchanged in headless tests
    (`SIV_ERROR_UNSUPPORTED` would add a second way to say the same).
    `siv_window_request_commit` exists because the rules forbid
    committing: without it, state set on an idle window would wait for
    an unrelated redraw.
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
    in a callback with a handle the application owns. SVG files and
    themed icons (`siv_icon_load`) are vector images: the same handle,
    drawn from the document at whatever size image nodes and
    `siv_draw_image` give them.
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
    first is empty or declines (D22); `siv_node_emit` sends an event to both.
  - A close request goes to the window's `on_event`; unless it returns
    true, siv destroys the window. `siv_app_run` returns when `siv_app_quit`
    is called or nothing keeps the application running: no toplevel or
    layer window is left, no session lock holds, and no output watch is
    set (D31). Popups and lock windows do not count: popups belong to a window, and lock windows come
    and go with outputs while the lock they belong to is what holds.
    Before, layer windows did not count either, so an application whose
    only window was a bar never returned on its own (D30).
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
    handler, whose `enter` and `move` may choose the action
    (`siv_drop_set_action`) from the event's modifiers; `siv_drag_start`
    from a pointer handler with `SIV_EVENT_DRAG` events, and
    `siv_drag_set_icon` and `siv_drag_cancel` while it lasts;
    `siv_drop_finish` for `ask`. `siv_image_draw` makes an image from
    canvas drawing operations (a drag icon of an item's icon and name),
    rasterized on the CPU at the window's scale rounded up, as tray and
    drag icons rasterize vector images; text and icons draw only once
    loaded, since the call returns at once. Mime lists are
    one string with one type per line, and a drag's data is one array
    split by `lengths`, because schema arrays hold only fixed-size
    elements (D3); both stay plain C.
  - **Testing applications.** `siv_test_*` (`api_testing.zig`,
    `testing.zig`) lets an application's own tests drive it on the
    headless backend through the C API, and so the Zig wrapper and Lua:
    pointer moves, buttons, clicks, wheel scrolling, keys with their
    text, typed strings, modifiers held on their own, close requests,
    and another client's drop are
    injected into the simulated seat on the compositor thread;
    `siv_test_settle` dispatches until no work is in flight, with a
    timeout: no transaction is open, every shown window presented what
    it committed and wants no frame, no tooltip waits for its delay
    (so a test hovers, settles, and finds the tooltip shown), no font,
    icon, image load,
    `siv_job_start` job, paste, or drop is in flight, and the compositor
    owes no frame (`Compositor.owesFrames`: a commit not yet presented,
    a frame asked for by input, the UI, a compositor-side scroll, a
    popup, or a timer and not yet composed, a fling or single-run
    animation still running, events posted to the UI and not yet
    delivered, or input the headless backend has not handled). The
    headless backend presents as the compositor commits, so no frame
    owed means every one owed is presented. It waits on the loop rather
    than for quiet time: when it finds frames owed, the compositor posts
    `Event.idle` once none are, which wakes the loop. Repeating
    animations (`iterations` other than 1: a caret's blink, a spinner)
    never end and are not waited for, so a capture may catch them in
    any phase; reduced motion stops them. It used to stop after three
    idle 2 ms dispatches, which returned before a frame the compositor
    owed for a wheel scroll whenever that frame waited for the next
    vblank (test/abi/settle.zig forces a 300 ms refresh to show it); `siv_test_capture` copies the last presented buffer as
    premultiplied RGBA, `siv_test_capture_tooltip` a window's shown
    tooltip, which has no window handle, and `siv_test_capture_drag_icon`
    the icon of the application's drag as the platform got it; `siv_test_find`, `siv_test_get_name`, and
    `siv_test_dump` read the semantics tree (D18) by role, exact name,
    focus, and index; `siv_test_get_popup` finds the newest shown popup.
    The simulated desktop shell (D31) is played by `siv_test_add_output`
    and `siv_test_remove_output` (hotplug), `siv_test_add_toplevel`,
    `siv_test_set_toplevel`, and `siv_test_remove_toplevel` (other
    clients' windows), `siv_test_add_workspace` and
    `siv_test_remove_workspace`, `siv_test_set_idle` (the user away or
    back), and `siv_test_set_blur` (a compositor that blurs), and read
    with `siv_test_get_blur_region_count`, `siv_test_get_blur_rect`, and
    `siv_test_is_locked`. A semantics query made between a transaction
    and its frame no longer keeps stale bounds after the frame: the tree
    stays marked for rebuilding while a layout is pending.
    Injection, settling, and captures fail with `SIV_ERROR_UNSUPPORTED`
    on Wayland, where a compositor owns input. Queries go through the
    semantics tree rather than nodes, so a test finds controls as a
    screen reader does and an unlabelled control fails it; the guide's
    samples are tested only through these calls. `siv_test_drop`
    dispatches between the drag's entry and the drop, since a drop goes
    where the application said it takes the data. Portal requests and
    the application's own threads are not waited for: tests wait for
    their effect. siv's own tests (`test/abi`) keep driving the headless
    platform directly, for protocol states the public calls do not
    reach. Alternatives: a test-only library beside libsiv (a second ABI
    to version and ship, and Lua could not reach it); node handles in
    query results (rows of views and parts of widgets have none, and
    tests would bind to the tree's shape); settling inside each
    injection call (hides when work happens and cannot run from a
    callback). Reverse if applications need input the simulated seat
    cannot express (touch, tablets, gestures); then add calls in the
    same family.
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
    Drawing errors are sticky like a transaction's (D4), so drawing calls
    return nothing and `siv_draw_status` reads the error: after the first
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
  and the user's own theme (siv's theme.toml, Omarchy's themes), with
  compiled defaults that applications can override at run time, and
  without the application rebuilding its tree when the desktop or the
  theme changes.
- **Decision:** themed values are public primitives that nodes reference
  and siv resolves when it paints and shapes, not values widgets copy in.
  - Tokens (`siv_color_token`, `ui.theme.ColorToken`): window, view, and
    card surfaces and their text, muted and disabled text, borders and
    separators, control rest, hover, and pressed fills and their text, the
    accent with its hover and pressed shades and the text on it,
    selections, focus rings, tracks and knobs, destructive actions, the
    modal scrim, inverse surfaces for toasts, the success and warning
    colors of symbolic icons (D19), and two panes recessed from the view
    (sidebar and secondary sidebar, as libadwaita names them: navigation
    lists, the outer columns of a column browser, each a step from the
    view and readable with view text, distinct in high contrast too). Visual descriptors take
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
  - The user's theme is a layer between the desktop and the
    application: compiled variants, then the desktop's scheme,
    contrast, and accent, then the user's theme, then application
    overrides, which win but should stay rare. Derived colors (accent
    shades, the text on it, focus rings, selections) come from the final
    accent over the final view background, except where a layer at or
    above the accent's sets one itself: the desktop's accent under an
    Omarchy theme takes the theme's selection, and an application's
    accent moves the theme's selection too. A theme names the scheme it
    is for (Omarchy's `mode`, theme.toml's `scheme`), which picks the
    variant over the desktop's color scheme, so the palette and its
    variant never disagree while `omarchy-theme-set` updates the portal's
    color scheme after the files; a theme without one follows the
    desktop. It fills only its variant, and the rest stay compiled. In
    high contrast, from the desktop or the application, the compiled
    high-contrast palette applies unchanged: Omarchy has no high-contrast
    variant, and a theme's colors would undo what the user asked for.
    - Two sources. `$XDG_CONFIG_HOME/siv/theme.toml`, siv's own format:
      tokens by their names (`view_bg`), at the top level for both
      schemes or in `[light]` and `[dark]` tables, which win; `scheme`;
      colors `#rgb`, `#rrggbb`, `#rrggbbaa`. It is generic, so
      matugen or pywal templates can write it. And Omarchy's current
      theme, `~/.local/state/omarchy/current/theme/colors.toml`
      (Omarchy 4), else `~/.config/omarchy/current/theme/colors.toml`
      (3.3, the first with colors.toml; older themes have none, and
      Omarchy now generates one from their alacritty.toml). theme.toml
      decides when it exists, since it is a choice made for siv;
      `base = "omarchy"` in it lays it over Omarchy's theme, to change
      a token or two of every Omarchy theme. `SIV_THEME=none` turns user
      themes off; `SIV_THEME=FILE` reads that theme.toml or, by its
      name, colors.toml instead. On the headless backend, and with
      `SIV_APP_FLAGS_NO_DESKTOP_SETTINGS`, siv looks for neither, so
      tests do not depend on the user's files; `SIV_THEME=FILE` still
      applies, which is how an application renders itself under a
      theme in its tests.
    - Omarchy's keys (its docs/theming.md) resolve as its own
      omarchy-theme-color does: canonical names over the legacy short
      ones (`bg`, `fg`, ...), ANSI `color0`–`color15` as fallbacks,
      missing shades mixed in sRGB as it mixes them, the accent falling
      back to blue; mode from `mode`, the legacy `theme_type`, a
      `light.mode` file, then the background's brightness. Then:
      `background` → view; `dark_background` → window and secondary
      sidebar; `darker_background` → sidebar; `lighter_background` →
      control rest (hover and pressed 10% and 20% toward the text) and,
      in dark themes, cards (light themes' cards are the background);
      `foreground` → every text token; muted text the foreground mixed
      toward the background as far as 40% while it keeps 4.5:1 on the
      view and both sidebars; disabled text halfway to the background
      (Omarchy's `dark_foreground` in themes with an even ramp, legible
      in those whose is not, such as white's); `muted` → borders, with
      separators 60% of it over the background and tracks halfway
      between it and `lighter_background`; `accent` → accent, with
      siv's shades; `selection` → selected rows, tinted toward the
      accent until it stands 1.2:1 from the view and both sidebars
      (light themes' selection is as dark as their sidebars: catppuccin
      latte, rose pine), with `bright_foreground` or the foreground on
      it, whichever contrasts more, black or white below 4.5:1; `red`,
      `green`, `yellow` → destructive (with black or white on it),
      success, and warning, which applications use for syntax and
      status colors; knobs light (the bright foreground halfway to white
      in dark themes, the background in light ones) unless the accent
      is too light for it (kanagawa's accent is its text color), then
      dark; foreground and background swapped for inverse surfaces; the
      scrim stays. Rendered against all 23 of Omarchy's themes; the
      widget gallery's goldens show tokyo-night and catppuccin-latte.
    - Parsing is a small TOML subset (`ui.user_theme.Parser`: comments,
      tables, basic and literal strings, numbers, booleans) with a fuzz
      target. A line that does not parse is skipped, and so is every
      entry under a header that does not parse or an array of tables;
      arrays, inline tables, and multi-line strings are skipped whole.
      A bad, partial, or missing file falls back token by token to the
      compiled palette, never to garbage: a token is set only by a color
      that parses. Files over 64 KiB are not themes.
    - Read on the worker pool at startup and on every change; first
      frames wait for the first read as they wait for the desktop
      settings (D19), within the same 100 ms. Watched with inotify on
      the loop (D6): no thread, nothing runs while nothing changes.
      Each file is watched through its directory and that directory's
      parent, since Omarchy deletes the current theme and renames
      `next-theme` into place, and a theme.toml may come with its
      folder. Events restart a 50 ms quiet timer, so a burst is one
      read; watches are added again before each read, so a change after
      them is seen and one before them is read. A read that finds
      Omarchy's theme gone but a `next-theme` keeps the theme it has
      until the rename, so nothing flashes the compiled colors. A new
      palette repaints every window as a desktop change does.
    - No API names the active theme: applications see its colors through
      the tokens and `siv_window_get_color`, and none has needed to
      know where they came from.
  - Each window resolves a palette (`ui.theme.Palette`) from the desktop
    values and the application's choices, which the coordinator passes to
    every window like the desktop settings (D19). A changed palette
    repaints every layer and redraws canvases; a changed body size
    reshapes text that has a size role and measures canvases again. The
    core's own colors come from it too: focus rings, editor selections,
    and placeholders, so the core and stock widgets agree. Canvases read
    resolved colors with `siv_window_get_color`.
  - Font families are not part of the theme: Fontconfig's generic
    families decide them, or the desktop's fonts on GNOME and KDE, live
    (D19). theme.toml has no font setting, since fonts.conf is where
    users choose fonts for every toolkit, and an Omarchy theme switch
    changes no font (`omarchy font set` is its own command). Text sizes
    follow the desktop's text scale, which Omarchy sets too.
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

### D30. The pre-1.0 API review

- **Requirement:** the API grew across parallel workstreams; before 1.0
  freezes it (D2's versioning), one pass reads all of it as a binding
  author and an application author would and makes it consistent: names,
  argument order, ownership, threading notes, error conventions, no two
  ways to do one thing, no gap that makes a common task awkward, and room
  to grow where growth is plausible.
- **Decision:** the changes below, each recorded with its reason in the
  decision it belongs to. Before 1.0 renames and removals take effect at
  once, without deprecated aliases (D2), so this list is what bindings and
  applications follow; the Lua names follow the C ones (D23).

  | Change | Replaces | Why |
  | --- | --- | --- |
  | `siv_set_widget`, `siv_widget_desc` (D22) | the generic calls switching on stock kinds | application widgets take part in `siv_widget_*` and `siv_node_focus` |
  | `SIV_WIDGET_PART_COLUMN`; `siv_widget_part` open (D22) | — | header cells by index; parts of application widgets |
  | views have no widget value (D22) | `siv_widget_set_value`/`get_value` on views | one way to move the cursor: `siv_view_set_cursor`, `siv_view_get_cursor` |
  | `siv_node_focus` on a view (D22) | `siv_view_focus` | the widget interface's `focus` covers every roving widget |
  | header cell value (D22) | `siv_view_set_column_width`, `siv_view_get_column_width` | the value a widget reports in `change` is the value it takes |
  | `siv_radio(txn, group, &siv_radio_desc)` (D22) | `siv_radio(txn, group, label)` | items grow options (a disabled radio now, its `flags`) without new functions |
  | `siv_tab(txn, tabs, &siv_tab_desc)` (D22) | `siv_tab(txn, tabs, label)` | likewise (an icon, a close button) |
  | `siv_external_view(txn, parent, &siv_external_view_desc)` and `siv_set_external_view` (D27) | slot, size, and fit as arguments | like `siv_image_view`; the Lua builder takes an `external_view` property |
  | `thread` on schema functions and callbacks; the header's conventions comment (D2) | "Any thread." in prose | binding generators (a Rust `Send` bound, a Lua check) read it instead of parsing documentation |
  | `deprecated` on schema functions, `SIV_DEPRECATED` (D2) | — | the deprecation rules D2 promised before 1.0, with the mechanism that carries them out |
  | `siv_app_run` | `siv_run` | it is an application's call, like `siv_app_dispatch` and `siv_app_quit` (Lua: `app:run()` as before, `siv.app_run`) |
  | `siv_app_get_fd` | `siv_app_fd` | queries with an out parameter are `get_` (D27; Lua `app:get_fd()`) |
  | `siv_app_get_font_family` | `siv_app_font_family` | likewise, beside `siv_app_get_font_family_name` (Lua `app:get_font_family(name)`) |
  | `siv_notification_send` | `siv_notify` | pairs with `siv_notification_withdraw` (Lua `app:notification_send{}`) |
  | `siv_node_emit` | `siv_emit` | calls on a node outside a transaction are `siv_node_*` (Lua `node:emit` as before) |
  | `siv_pointer_button`, `SIV_POINTER_BUTTON_*` | `siv_button`, `SIV_BUTTON_*` | `siv_button_desc` and `siv_button_style` are the push button widget's; the event field is still `button` |
  | `siv_size_role`, `SIV_SIZE_ROLE_*` | `siv_text_role`, `SIV_TEXT_ROLE_*` | a themed text size beside `siv_role`, the accessibility role, read as a role for text; it is the type of `size_role` |
  | `siv_screencast_cursor`, `siv_screencast_persist` | `siv_cursor_mode`, `siv_persist_mode` | they belong to the screen cast family; `siv_cursor` is the pointer's shape |
  | `siv_icon_load(..., &request)` (D19) | no request | icon loads cancel like image loads |
  | transaction operations (`siv_set_*`, `siv_on`, `siv_move`, `siv_widget_set_*`, `siv_view_set_*`, ...), drawing operations, `siv_txn_fail`, and teardown (`*_destroy`, `*_cancel`, `siv_txn_abort`, `siv_app_remove_action`, `siv_notification_withdraw`, `siv_tray_item_remove_menu_item`) return void (D2) | `siv_result` that callers could ignore | the result rule: every `siv_result` warns when ignored, and functions that cannot fail return nothing; a transaction's failure is read from the transaction, as for builders |
  | `siv_app_quit`, window requests, `siv_drop_finish`, `siv_app_set_transfer_limit`, `siv_window_activate`, `siv_txn_status`, `siv_draw_status` warn when ignored (D2) | ignorable | they can fail |
  | `siv_app_destroy` from a callback is deferred to the end of the dispatch (D2) | `SIV_ERROR_BUSY` | teardown cannot fail |
  | optional out parameters: `siv_node_emit`'s `handled`, `siv_image_load`'s and `siv_icon_load`'s `request`, `siv_timer_start`'s `timer`, `siv_popover_create`'s `content` (D2) | required | C callers do not declare values they throw away |
  | `siv_node_get_related`, `siv_node_get_window`, `siv_window_get_focus`, `siv_window_get_app`, `siv_menu_get_item`, `siv_view_get_row`, `siv_widget_get_part` return the handle, 0 for none (D2) | `siv_result` and an out handle | handle queries nest like builders; 0 already meant none |
  | `siv_window_get_root` (Lua `window:get_root()`, Zig `windowGetRoot`) | `siv_window_root` | queries are `get_` however they answer (D27) |
  | `SIV_STR` in siv.h (D2) | each sample's `S(s)` | one helper for string literals |
  | Zig: descriptor parameters take `T.Options` with slices (D3) | `?*const T` with `.x` and `.x_len` | strings and arrays as slices |
  | Zig: callbacks get `*const T` descriptors (D3) | `?*const T` | siv never passes NULL; no `ev.?` |
  | `siv_bind_fn`'s `recycled` documented as any row bound before (D22) | "showed another item before" | a bind trusting the old words could add a second set of nodes on a rebind |
  | artifacts `siv` (libsiv.so) and `siv-static` (libsiv.a); `notices` named path (D25) | two artifacts named `siv` | a Zig package could not install libsiv.so, or build as a dependency |
  | stretched nodes keep their own largest size; the root's stretch documented (D26) | the parent's stretch winning | a stretched node's `max_width` did nothing |
  | `SIV_VISUAL_CLIP` clips the node's own image and canvas (D26) | descendants only | rounded images needed a wrapper box |
  | Lua `stop` for span ends (D23) | `["end"]` only | `end` is a Lua keyword; both names work and output tables carry both |
  | Lua `app:job_start` (D23) | `siv_job_start` unbound | CPU work from Lua ran on the application's thread; the work now runs in a Lua state of its own on the worker pool |
  | `siv_test_*`: headless input, settling, captures, semantics queries (D27) | test-only Zig access to the headless platform | applications test themselves through the C API, the Zig wrapper, and Lua, as the guide's samples now are |
  | `siv_node_focus` shows the ring after a key (D16) | `siv_node_focus` never showing it | focus moved by arrow keys in roving widgets was unmarked |
  | `siv_test_capture`'s `pixels` and `siv_view_get_selection`'s `bits` are `uint8_t *` (D2) | `char *` | binary data is unsigned, like the byte arrays the library reads; `char *` means text |
  | `siv_combo_box`, `siv_combo_box_item`, `SIV_WIDGET_PART_ITEM` (D22) | a menu button with radio items, or a widget of the application's own | choosing one of several options in little space is among the most common controls, and needs list semantics and typeahead each application would redo |
  | `siv_test_capture_tooltip`; `siv_test_settle` waits for a tooltip's delay (D27) | — | tooltips are popups without a handle, and tests could not see one or know when it would show |
  | `siv_set_tooltip` (D17); icon-only buttons show their label as one (D22) | a popup and timer per application | a common need every toolkit has; a core primitive so application widgets get it too |
  | reserved fields in `siv_text_span`, `siv_paragraph_span`, `siv_tab_stop`, `siv_text_metrics` (D2) | — | frozen value structs that will plausibly grow; descriptors grow by appending |
  | `siv_tablet_sample.wheel` and four reserved fields (D16) | — | the axes flags named a wheel the sample could not carry; tablets grow axes, and a frozen struct cannot |
  | `siv_app_get_wayland`, `siv_window_get_wayland`, `siv_window_request_commit` (D17, D27) | the display only through a surface slot, and no window objects | protocols siv does not support (content type, tearing control, toplevel tags) need no fork of siv; the rules keep siv's commits and frame clock its own |
  | `siv_external_frame_desc.flags` and `fence`, `SIV_EXTERNAL_FRAME_FENCE` (D17) | implicit fences only | drivers without implicit synchronization (NVIDIA's) could not say when a dma-buf frame was written |
  | `siv_external_view_desc.background` (D17) | a background the window painted under the video | bars behind video and punch-through holes become solid-color subsurfaces (single-pixel-buffer-v1) |
  | translucent external placements stay on their subsurface when uncovered (D17) | composited frames, embedders' surfaces at full opacity | alpha-modifier-v1 applies the opacity; fades cost bare commits |
  | the shell module (D31): `siv_layer_create`, `siv_window_set_layer`, `siv_app_watch_outputs`, `siv_lock_*`, `siv_toplevel_*`, `siv_workspace_*`, `siv_idle_watch_*`, `siv_app_get_capabilities` and their types | — | bars, docks, launchers, notifications, and lock screens through siv's windows and events, `SIV_ERROR_UNSUPPORTED` where the compositor lacks a protocol |
  | `SIV_VISUAL_WINDOW_BLUR` (D31) | — | the compositor's blur behind translucent windows (ext-background-effect-v1), region kept in step with every frame |
  | `SIV_WINDOW_EVENT_TYPE_CLOSED` (D31) | — | a layer or lock window whose surface the compositor took away; destroyed after the event |
  | `SIV_ERROR_UNSUPPORTED` also means the compositor lacks a protocol (D31) | only unknown values and fields | the window icon call already used it so; now documented on the result |
  | `siv_test_add_output`, `siv_test_remove_output`, `siv_test_*_toplevel`, `siv_test_*_workspace`, `siv_test_set_idle`, `siv_test_set_blur`, `siv_test_get_blur_region_count`, `siv_test_get_blur_rect`, `siv_test_is_locked` (D27, D31) | — | applications test their shell components headless, as the shell example does |
  | permissive, OSI-approved, non-copyleft licences such as HPND (D25) | MIT, BSD, or Apache-2.0 only | wlr-protocols' layer shell and toplevel management are HPND |
  | layer windows and an active session lock keep `siv_app_run` running (D27, D31) | shell windows counted for nothing; applications called `siv_app_quit` themselves | a bar or a lock screen alone is an application like any other; lock windows still do not count, as they follow outputs |
  | an output watch keeps `siv_app_run` running with no window (D27, D31) | a bar ended with its last output | closing a laptop lid with only an external monitor, or a monitor vanishing during a dock or KVM switch, killed the bar instead of letting it come back on `added` |
  | `siv_test_find` after a transaction and before its frame keeps no stale bounds (D27) | bounds of the frame before the query, kept until the next change | a query between a transaction and its frame (on a display, where there is no settling) cleared the semantics tree's dirty flag, so the frame's layout never refreshed the bounds |
  | `siv_node_get_text_range` (D15) | reading a long text whole with `siv_node_get_text` | a text node's text is a rope; an application searching or saving 100 MB needed a buffer as long, and a copy of all of it each time |

  Statements this document made that were no longer true are fixed where
  they stood: external nodes are built and in the C API (D4, D17);
  fractional and preferred buffer scale and output hotplug are built
  (D17); the inspector and CI are not (D24, D25); D4's example used
  constants and a `siv_on` signature that no longer exist, D22 called
  `siv_push_button` `siv_button`, and D12 and the file manager's log
  misspelled `SIV_WINDOW_EVENT_TYPE_PRESENTED`.
- **Reverse if:** a binding cannot express one of these without special
  cases; then the schema needs a construct, not an exception.

### D31. The desktop shell module

- **Requirement:** siv is a good toolkit for desktop shell components:
  bars, docks, launchers, notification popups, on-screen displays,
  wallpapers, and lock screens, written in C or Lua like any siv
  application, with the same tree, widgets, accessibility, and tests.
- **Decision:** an optional module of the C API (`src/abi/api_shell.zig`,
  `src/abi/shell.zig`) over the platform, compositor, and coordinator
  layers: layer windows, the session lock, the desktop's toplevels and
  workspaces, idle notification, outputs, compositor blur behind windows,
  and the capabilities that say which of them the compositor offers.
  Optional means nothing is bound until an application asks: an ordinary
  application never receives the desktop's window list, and a compositor
  without a protocol (GNOME has none of these) answers
  `SIV_ERROR_UNSUPPORTED` for it, which `siv_app_get_capabilities` tells
  in advance. It is not a separate Zig module or library: layer and lock
  surfaces are roles of siv's own windows, committed with siv's frames,
  so they live where windows live (`platform.Role`, D8, D17); the data
  protocols ride along so that shell data arrives as ordinary siv events
  at safe points (D5) rather than on a Wayland queue of the
  application's own.
  - **Protocols** (`src/platform/protocols.zig`):
    wlr-layer-shell-unstable-v1 (version 4) and
    wlr-foreign-toplevel-management-unstable-v1 (3) from wlr-protocols,
    pinned to a commit (no releases; HPND notices, D25);
    ext-session-lock-v1, ext-foreign-toplevel-list-v1, ext-workspace-v1,
    ext-idle-notify-v1 (2), and ext-background-effect-v1 from
    wayland-protocols 1.49, which already has them all. org_kde_kwin_blur
    is left out: its protocol XML is LGPL (D25).
  - **Windows have roles** (`platform.Role`: toplevel, layer, lock). A
    layer window (`siv_layer_create`) is a `siv_window` like any other:
    its tree, transactions, popups, menus, tooltips, canvases, and
    external content work unchanged, and the toplevel-only calls do
    nothing. Its placement is a `siv_layer_desc`: layer (top by default,
    so zero means the common case), anchors, margins, keyboard mode
    (none, exclusive, on demand), size (0 on an axis anchored to both
    edges spans the output), exclusive zone, and
    `SIV_LAYER_AUTO_EXCLUSIVE`, which reserves the window's own size along
    its edge and follows it as the compositor resizes the window, the
    zone a bar always wants and one the application could only compute
    after the configure. `siv_window_set_layer` changes all of that
    later; output, namespace, and callbacks stay those of creation,
    since the protocol cannot move a surface between outputs. A zero
    size without both anchors is `SIV_ERROR_INVALID_ARGUMENT` before it
    can be the protocol error it would be. Size negotiation is the
    configure path every window has (D8): the compositor's size arrives
    as `resized`, the layout answers it in the commit that acknowledges
    it.
  - **Popups of layer windows** are xdg_popups without an xdg parent that
    the layer surface adopts (`zwlr_layer_surface_v1.get_popup`) before
    their first commit, so menus, combo boxes, and tooltips (D17) work
    from a bar. Lock surfaces cannot have popups (the protocol gives them
    no xdg parent): creating one fails, and tooltips there do not show;
    lock screens use in-window widgets.
  - **Accessibility** (D18): layer and lock windows are frameless
    (`ui.Window.frameless`), so their root is AT-SPI's `window` (69: a
    top-level window without a title or border) rather than `frame`.
    Applications give the root the role of what it is, as the example
    does: `toolbar` for a bar, `alert` (AT-SPI notification) for a
    notification, `dialog` for a lock screen's prompt; popups keep their
    menu and tooltip roles.
  - **Outputs** are handles (`siv_output`), reported by
    `siv_app_watch_outputs` as added, changed, and removed events with
    what wl_output says (name, description, make, model, position, mode,
    integer scale, transform, physical size); a new callback hears
    every output there is at the next dispatch, each exactly once as
    added (a replay and the compositor's event can cross). Layer windows
    name an output by handle. A removed output's layer windows are closed
    by the compositor (`zwlr_layer_surface_v1.closed`), its lock windows
    by siv; either way the window gets `SIV_WINDOW_EVENT_TYPE_CLOSED`
    (new) and is destroyed after it, whatever the callback returns, since
    its surface shows nothing more.
  - **The session lock** (`siv_lock_create`): siv makes the lock window
    of every output when the lock is requested and of every output that
    appears while it holds, and reports each as a `window` event for the
    application to build (a clock, a masked editor), before `locked`.
    One lock surface per output is the protocol's rule and the part
    every hand-written lock screen gets wrong on hotplug, so siv owns it.
    `denied` (the compositor refused, another client holds a lock) and
    `finished` (it ended the lock itself) are the protocol's finished
    before and after locked. `siv_lock_unlock` unlocks and destroys the
    lock with its windows; `siv_lock_destroy` lets go without unlocking,
    so a lock screen that fails leaves the session locked (the
    compositor shows a solid color until a new lock client unlocks), the
    protocol's crash semantics and the safe direction. Lock windows
    share the lock's `user_data` and get no destroy-notify of their own;
    siv destroys them before the lock's destroy-notify runs, so a late
    event never reaches released user data. Authentication stays the
    application's: siv provides masked editors whose text lives in
    locked memory (D15), and the application runs PAM on the worker pool
    (`siv_job_start`, D6) so the lock screen stays responsive while PAM
    sleeps after a failure; `examples/shell.c` shows the pattern, loading
    libpam at run time so the example builds without PAM's headers.
  - **Toplevels** (`siv_toplevel_list_create`): wlr-foreign-toplevel-
    management when the compositor offers it, since it carries states,
    outputs, and parents and is the one that accepts activate, close,
    minimize, maximize, and fullscreen; otherwise
    ext-foreign-toplevel-list, whose toplevels have titles, app ids, and
    stable identifiers only and whose requests fail with
    `SIV_ERROR_UNSUPPORTED` (`SIV_TOPLEVEL_MANAGED` unset). The two
    protocols share no key, so siv never mixes them: pairing a wlr handle
    with an ext handle by title and app id would send a close to the
    wrong one of two "foot" windows. Each toplevel event carries the
    whole description (title, app id, identifier, states, parent,
    outputs), so a task list rebuilds from events without queries; a
    removed event carries the last values.
  - **Workspaces** (`siv_workspace_list_create`, ext-workspace-v1): the
    compositor's changes arrive atomically at its `done`, then one event
    per changed workspace, with name, identifier, states (active, urgent,
    hidden), capabilities, and the outputs of its group, so a switcher
    per output filters by output without a group object. Activate,
    deactivate, and remove are committed at once. Groups, creating
    workspaces, and assigning them to groups are not in the API yet.
  - **Idle** (`siv_idle_watch_create`, ext-idle-notify-v1): true after
    the timeout without input, false when input resumes; idle inhibitors
    (D17's `siv_inhibit`) hold it off unless `SIV_IDLE_IGNORE_INHIBITORS`
    (version 2's input idle notification), which a screen lock wants.
  - **Ids and handles** (D2, D20): the platform numbers toplevels,
    workspaces, and idle watches with ids it never reuses, so an event the
    UI thread handles late cannot name a newer object, and the UI reads
    the details on the compositor thread (`Compositor.call`) when it
    handles the event; an object gone by then is skipped, its removal
    follows. The C handles (`siv_output`, `siv_toplevel`,
    `siv_workspace`) are generation-checked like every other: valid from
    the added event until the removed one, invalid in every later call.
    One toplevel list and one workspace list per application
    (`SIV_ERROR_BUSY` for a second): the platform has one subscription,
    and replaying it for a second list would run callbacks outside a
    safe point.
  - **Background blur** (ext-background-effect-v1):
    `SIV_VISUAL_WINDOW_BLUR` on a node means "blur what is behind the
    window under this node's rounded border box", for frosted bars,
    notifications, launchers, translucent windows, and popups. A marked
    node roots a compositor layer with a blur shape (`Op.set_blur`, D8),
    and every frame the compositor thread computes the surface's region
    from the shapes as that frame shows them, through transforms, scroll
    offsets and zoom, clips, and running animations, and sets it with
    the frame's own commit, so the region never lags the content,
    including scrolling and animation the UI thread never sees.
    Region rectangles are rounded inward to whole pixels; rounded corners
    become six bands per corner inside the curve (at most about a pixel
    of unblurred sliver for radii up to 16, never blur outside the
    corner), a rotated shape its bounding box, rounded clips their
    rectangles; a fully transparent layer blurs nothing. The region is
    sent only when it changes. Without the protocol or its blur
    capability nothing is sent, and `SIV_CAPABILITIES_BLUR` tells the
    application to pick a more opaque background, as the example does.
    siv's own backdrop blur (D9, `siv_draw_backdrop_blur`) is separate:
    it blurs the window's own content. siv creates the surface's
    ext_background_effect_surface_v1 with the window (one per surface is
    the protocol's rule), so `siv_window_get_wayland` users must not
    (D27), nor a layer or lock surface; that call's toplevel is NULL for
    layer and lock windows.
  - **Shell windows and the run loop** (D27): layer windows keep
    `siv_app_run` running exactly as toplevels do, and a session lock
    keeps it running until it is unlocked, destroyed, denied, or finished
    (`app.App.lock_held`); individual lock windows do not count, since
    they come and go with outputs. An output watch
    (`siv_app_watch_outputs`) keeps it running too, with no window at
    all (`app.App.holdRun`): an application that watches outputs makes its
    windows per output and makes them again on `added`, so the moment
    with no output (a laptop lid closed with only an external monitor, a
    monitor gone during a dock or KVM switch) must not end it. So a lock
    screen of nothing else returns from `siv_app_run` once it unlocks; a
    shell of layer windows without a watch returns when its last one
    closes; and a shell that watches outputs, like the example, runs until
    it clears the watch or calls `siv_app_quit`. Before, layer and lock
    windows counted for nothing and such applications ran until
    `siv_app_quit`; then layer windows counted but a bar died with its
    last output; the user chose the rule above (D30).
  - **Tests.** The headless backend simulates every protocol: layer
    windows placed by their anchors and margins on their output (other
    windows' exclusive zones are not simulated), popups placed against
    them, a process-wide lock store (one holder, an abandoned lock taken
    over by the next client, as sway allows), other clients' toplevels
    and workspaces that apply requests as sway does, idle with
    inhibitors, output hotplug, and a compositor that blurs on request;
    `siv_test_*` gains the calls that play the other clients and the user
    (D27). `test/abi/shell.zig` covers the C API, `test/lua/binding.zig` the
    binding, `src/compositor/tree.zig` the blur region's geometry,
    `src/a11y/tests.zig` the frameless role, and `examples/shell.c` runs
    unchanged both headless (`test/abi/shell_example.zig`, with a
    golden image of its bar and lock screen) and on sway
    (`src/abi/integration_shell.zig`), compiled a second time with main,
    `siv_app_create`, `siv_app_run`, the clock, the user, and dlopen
    renamed, as the guide's samples are (D24); its libpam is a fake that
    accepts one password. On sway 1.12 (`src/platform/integration_tests.zig`,
    D24) every protocol but background blur is verified for real.
- **Alternatives:** applications binding these protocols on a Wayland
  queue of their own through an escape hatch (fine for the data
  protocols, impossible for layer and lock surfaces, which are roles of
  surfaces siv creates and commits, and every Lua shell would need FFI);
  a separate libsiv-shell (the roles need the platform's window
  internals); siv choosing the outputs a lock covers but leaving window
  creation to the application (hotplug is exactly what such code gets
  wrong); the ext toplevel list always, with wlr management paired by
  title (guesswork that misdirects requests); a blur region the UI thread
  computes at layout (lags compositor-side scrolling and animations by a
  frame or more); org_kde_kwin_blur for KWin (LGPL protocol XML).
- **Reverse if:** wayland-protocols gains a toplevel management protocol
  keyed by ext-foreign-toplevel-list handles that compositors adopt (then
  use the ext list always and management through it); libraries in one
  application need separate toplevel or workspace subscriptions (then
  replay at a safe point for each list); compositors commonly toggle blur
  at run time (then report the capability change as an application
  event); applications need groups, workspace creation, output logical
  geometry (xdg-output), or minimize rectangles (then add them in the same
  families).
- **Open, recorded rather than settled:** whether a layer window with
  `SIV_LAYER_AUTO_EXCLUSIVE` should also reserve its margin (compositors
  add the margin themselves today, so siv does not); whether lock windows
  should get tooltips through an in-window fallback; and the exclusive
  edge of layer-shell version 5, not exposed since an automatic zone
  covers the bars and docks it is for.

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
