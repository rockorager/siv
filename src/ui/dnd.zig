//! Drag and drop over a window's tree (D19).
//!
//! A drag over the window goes to the nearest drop target under the
//! pointer that takes one of the drag's mime types with one of its
//! actions: from the topmost node under the pointer up through its
//! ancestors. That node's `drop` handler sees `enter` and `move`, and
//! takes the drag by returning true; the answer (the mime type, the
//! node's actions, and its preferred action) goes to the source through
//! the platform, and the compositor's choice of action comes back. Editors
//! take text without a handler of their own.
//!
//! On a drop the data is read in the mime type the node takes, through a
//! pipe on the UI loop up to the clipboard's limit (or straight from this
//! application's own drag), and then the node gets `drop` with the data.
//! A drop it takes ends with the negotiated action, except `ask`: then
//! the application asks the user and calls `Window.finishDrop`. A drop
//! that arrives while a transaction is open waits for the next frame,
//! like input.
//!
//! Drags this application starts (`Window.startDrag`) live in the
//! clipboard, which reports their progress to the node that started them
//! (`notifySource`).

const std = @import("std");
const raster = @import("raster");
const platform = @import("platform");
const compositor = @import("compositor");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");
const input = @import("input.zig");
const editor = @import("editor.zig");
const Clipboard = @import("clipboard.zig");

const NodeId = node_mod.NodeId;
const Point = raster.Point;
const DragAction = platform.DragAction;
const DragActions = platform.DragActions;

/// The private mime type of in-app drags: other clients see the drag but
/// no type they know, and are never sent data.
pub const in_app_mime = "application/x-siv-in-app-drag";

/// Drag-and-drop requests for the platform, run on the compositor thread
/// (D8). `CompositorHost` implements them on a `Compositor`.
pub const Host = struct {
    ctx: ?*anyopaque,
    /// `Platform.startDrag` from this window; null on failure.
    start: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, serial: u32, mimes: []const []const u8, actions: DragActions, icon: ?*const platform.DragIcon) ?u32,
    /// Copies the offer's mime types into `out` (owned by the caller,
    /// allocated with `gpa`).
    mimes: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, offer: u32, gpa: std.mem.Allocator, out: *std.ArrayList([]u8)) error{OutOfMemory}!void,
    accept: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, offer: u32, mime: ?[]const u8, actions: DragActions, preferred: DragAction) void,
    /// Takes `fd`. False (with `fd` closed) once the offer is gone.
    receive: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, offer: u32, mime: []const u8, fd: i32) bool,
    finish: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, offer: u32, action: DragAction) void,
    /// `Platform.setDragIcon` for this client's drag `source`: false once
    /// the drag is over, error.Unsupported if it has no icon.
    set_icon: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, source: u32, icon: *const platform.DragIcon) error{ OutOfMemory, Unsupported }!bool,
    /// `Platform.cancelDrag`.
    cancel: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, source: u32) void,
};

/// `Host` on a compositor, for the window `window`. Must outlive the
/// ui.Window it serves.
pub const CompositorHost = struct {
    comp: *compositor.Compositor,
    window: platform.WindowId,
    gpa: std.mem.Allocator,

    const Compositor = compositor.Compositor;

    pub fn host(h: *CompositorHost) Host {
        return .{ .ctx = h, .start = start, .mimes = mimes, .accept = accept, .receive = receive, .finish = finish, .set_icon = setIcon, .cancel = cancel };
    }

    fn setIcon(ctx: ?*anyopaque, seat: platform.SeatId, source: u32, icon: *const platform.DragIcon) error{ OutOfMemory, Unsupported }!bool {
        const h: *CompositorHost = @ptrCast(@alignCast(ctx));
        const C = struct {
            seat: platform.SeatId,
            source: u32,
            icon: *const platform.DragIcon,
            out: error{ OutOfMemory, Unsupported }!bool = false,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                s.out = if (comp.platform.setDragIcon(s.seat, s.source, s.icon)) |ok| ok else |err| switch (err) {
                    error.Unsupported => error.Unsupported,
                    else => error.OutOfMemory,
                };
            }
        };
        var c: C = .{ .seat = seat, .source = source, .icon = icon };
        h.comp.call(&c, C.run) catch return error.OutOfMemory;
        return c.out;
    }

    fn cancel(ctx: ?*anyopaque, seat: platform.SeatId, source: u32) void {
        const h: *CompositorHost = @ptrCast(@alignCast(ctx));
        const C = struct {
            seat: platform.SeatId,
            source: u32,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                comp.platform.cancelDrag(s.seat, s.source);
            }
        };
        var c: C = .{ .seat = seat, .source = source };
        h.comp.call(&c, C.run) catch {};
    }

    fn start(ctx: ?*anyopaque, seat: platform.SeatId, serial: u32, mime_list: []const []const u8, actions: DragActions, icon: ?*const platform.DragIcon) ?u32 {
        const h: *CompositorHost = @ptrCast(@alignCast(ctx));
        const C = struct {
            window: platform.WindowId,
            seat: platform.SeatId,
            serial: u32,
            mimes: []const []const u8,
            actions: DragActions,
            icon: ?*const platform.DragIcon,
            out: ?u32 = null,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                s.out = comp.platform.startDrag(s.window, s.seat, s.serial, s.mimes, s.actions, s.icon) catch null;
            }
        };
        var c: C = .{ .window = h.window, .seat = seat, .serial = serial, .mimes = mime_list, .actions = actions, .icon = icon };
        h.comp.call(&c, C.run) catch return null;
        return c.out;
    }

    fn mimes(ctx: ?*anyopaque, seat: platform.SeatId, offer: u32, gpa: std.mem.Allocator, out: *std.ArrayList([]u8)) error{OutOfMemory}!void {
        const h: *CompositorHost = @ptrCast(@alignCast(ctx));
        const C = struct {
            seat: platform.SeatId,
            offer: u32,
            gpa: std.mem.Allocator,
            out: *std.ArrayList([]u8),
            err: ?error{OutOfMemory} = null,
            fn run(c: ?*anyopaque, comp: *Compositor) void {
                const s: *@This() = @ptrCast(@alignCast(c));
                for (comp.platform.dragMimes(s.seat, s.offer)) |m| {
                    const copy = s.gpa.dupe(u8, m) catch {
                        s.err = error.OutOfMemory;
                        return;
                    };
                    s.out.append(s.gpa, copy) catch {
                        s.gpa.free(copy);
                        s.err = error.OutOfMemory;
                        return;
                    };
                }
            }
        };
        var c: C = .{ .seat = seat, .offer = offer, .gpa = gpa, .out = out };
        try h.comp.call(&c, C.run);
        if (c.err) |e| return e;
    }

    /// The requests below go out in order with commits without waiting
    /// (`Compositor.post`).
    fn post(h: *CompositorHost, req: Request) void {
        const r = h.gpa.create(Request) catch return req.drop();
        r.* = req;
        h.comp.post(r, Request.run, Request.dropCtx) catch Request.dropCtx(r);
    }

    const Request = struct {
        gpa: std.mem.Allocator,
        seat: platform.SeatId,
        offer: u32,
        op: union(enum) {
            accept: struct { mime: ?[]u8, actions: DragActions, preferred: DragAction },
            receive: struct { mime: []u8, fd: i32 },
            finish: DragAction,
        },

        fn run(ctx: ?*anyopaque, comp: *Compositor) void {
            const r: *Request = @ptrCast(@alignCast(ctx));
            switch (r.op) {
                .accept => |a| comp.platform.acceptDrag(r.seat, r.offer, a.mime, a.actions, a.preferred),
                .receive => |*rc| {
                    _ = comp.platform.receiveDrag(r.seat, r.offer, rc.mime, rc.fd);
                    rc.fd = -1;
                },
                .finish => |action| comp.platform.finishDrag(r.seat, r.offer, action),
            }
            dropCtx(ctx);
        }

        fn drop(r: Request) void {
            switch (r.op) {
                .accept => |a| if (a.mime) |m| r.gpa.free(m),
                .receive => |rc| {
                    r.gpa.free(rc.mime);
                    if (rc.fd >= 0) _ = std.os.linux.close(rc.fd);
                },
                .finish => {},
            }
        }

        fn dropCtx(ctx: ?*anyopaque) void {
            const r: *Request = @ptrCast(@alignCast(ctx));
            const gpa = r.gpa;
            r.drop();
            gpa.destroy(r);
        }
    };

    fn accept(ctx: ?*anyopaque, seat: platform.SeatId, offer: u32, mime: ?[]const u8, actions: DragActions, preferred: DragAction) void {
        const h: *CompositorHost = @ptrCast(@alignCast(ctx));
        const copy = if (mime) |m| h.gpa.dupe(u8, m) catch return else null;
        h.post(.{ .gpa = h.gpa, .seat = seat, .offer = offer, .op = .{ .accept = .{ .mime = copy, .actions = actions, .preferred = preferred } } });
    }

    fn receive(ctx: ?*anyopaque, seat: platform.SeatId, offer: u32, mime: []const u8, fd: i32) bool {
        const h: *CompositorHost = @ptrCast(@alignCast(ctx));
        const copy = h.gpa.dupe(u8, mime) catch {
            _ = std.os.linux.close(fd);
            return false;
        };
        h.post(.{ .gpa = h.gpa, .seat = seat, .offer = offer, .op = .{ .receive = .{ .mime = copy, .fd = fd } } });
        return true;
    }

    fn finish(ctx: ?*anyopaque, seat: platform.SeatId, offer: u32, action: DragAction) void {
        const h: *CompositorHost = @ptrCast(@alignCast(ctx));
        h.post(.{ .gpa = h.gpa, .seat = seat, .offer = offer, .op = .{ .finish = action } });
    }
};

/// The drag over the window, if any.
pub const State = struct {
    /// The offer; 0 when no drag is over the window.
    offer: u32 = 0,
    seat: platform.SeatId = 0,
    /// From this application's own drag, and only offered in-app.
    own: bool = false,
    in_app: bool = false,
    /// The offer's mime types (copies).
    mimes: std.ArrayList([]u8) = .empty,
    source_actions: DragActions = .{},
    /// The compositor's choice for the current answer.
    action: DragAction = .none,
    pos: Point = .zero,
    /// The drop target the drag is over, and whether it takes the drag.
    target: NodeId = .none,
    taken: bool = false,
    /// The answer the source last got.
    answer: Answer = .{},
    dropped: bool = false,
    /// The drop's data is being read.
    reading: ?*Clipboard.Transfer = null,
    /// Read data waiting for a transaction to close.
    pending: ?[]u8 = null,
    /// A drop with the `ask` action the application has not resolved.
    asking: bool = false,
    /// The action the target's handler chose (`setAction`), instead of
    /// its preferred one; none for that.
    chosen: DragAction = .none,
    /// A handler is taking an `enter` or `move`, so `setAction` applies.
    choosing: bool = false,

    const Answer = struct { mime: ?[]const u8 = null, actions: DragActions = .{}, preferred: DragAction = .none };

    /// The platform's offer ends with the window (the compositor goes
    /// first); only local state is dropped.
    pub fn deinit(st: *State, win: *Window) void {
        stopReading(win);
        clear(win);
        st.mimes.deinit(win.gpa);
    }
};

/// The drop target a drag over `id` would go to, if `id` is one.
const Candidate = struct { node: NodeId, mime: []const u8, actions: DragActions, preferred: DragAction, editor: bool };

fn candidate(win: *Window, id: NodeId) ?Candidate {
    const st = &win.dnd;
    const n = win.node(id);
    if (n.drop.mimes.len != 0 and n.handler(.drop) != null) {
        const mime = n.drop.match(st.mimes.items) orelse return null;
        const actions = n.drop.actions.intersect(st.source_actions);
        if (actions.none()) return null;
        return .{ .node = id, .mime = mime, .actions = actions, .preferred = n.drop.preferred, .editor = false };
    }
    // Editors take text unless masked or disabled.
    if (n.kind == .editor and n.canFocus() and !n.data.editor.editor.masked) {
        const mime = Clipboard.pick(st.mimes.items, &Clipboard.text_mimes) orelse return null;
        const actions = DragActions.intersect(.{ .copy = true, .move = true }, st.source_actions);
        if (actions.none()) return null;
        return .{ .node = id, .mime = mime, .actions = actions, .preferred = .copy, .editor = true };
    }
    return null;
}

/// Drag events for this window, in the dispatch phase (queued behind an
/// open transaction like input).
pub fn handle(win: *Window, event: *const platform.Event) void {
    const st = &win.dnd;
    switch (event.*) {
        .drag_enter => |e| {
            end(win, .none);
            st.offer = e.offer;
            st.seat = e.seat;
            st.own = e.own;
            st.source_actions = e.source_actions;
            st.pos = .{ .x = @floatCast(e.x), .y = @floatCast(e.y) };
            loadMimes(win) catch {};
            route(win);
        },
        .drag_motion => |m| {
            if (st.offer == 0 or st.dropped) return;
            st.pos = .{ .x = @floatCast(m.x), .y = @floatCast(m.y) };
            route(win);
        },
        .drag_actions => |a| {
            if (st.offer != a.offer or st.dropped) return;
            const changed = a.action != st.action or @as(u8, @bitCast(a.source_actions)) != @as(u8, @bitCast(st.source_actions));
            st.action = a.action;
            st.source_actions = a.source_actions;
            if (changed) route(win);
        },
        .drag_leave => |l| {
            if (st.offer != l.offer or st.dropped) return;
            leaveTarget(win);
            clear(win);
        },
        .drag_drop => |d| {
            if (st.offer != d.offer or st.dropped) return;
            st.dropped = true;
            st.action = d.action;
            drop(win);
        },
        else => {},
    }
}

fn loadMimes(win: *Window) error{OutOfMemory}!void {
    const st = &win.dnd;
    if (st.own) {
        const cb = win.clipboard orelse return;
        const d = cb.drag orelse return;
        st.in_app = d.in_app;
        for (d.mimes) |m| {
            const copy = try win.gpa.dupe(u8, m);
            st.mimes.append(win.gpa, copy) catch |err| {
                win.gpa.free(copy);
                return err;
            };
        }
        return;
    }
    const host = win.drag_host orelse return;
    try host.mimes(host.ctx, st.seat, st.offer, win.gpa, &st.mimes);
}

/// Finds the drop target under the pointer and lets it take the drag.
fn route(win: *Window) void {
    const st = &win.dnd;
    var found: ?Candidate = null;
    var cur = input.hitTest(win, st.pos);
    while (cur != .none) : (cur = win.node(cur).parent) {
        if (candidate(win, cur)) |c| {
            found = c;
            break;
        }
    }
    const next: NodeId = if (found) |c| c.node else .none;
    const phase: node_mod.DropPhase = if (next == st.target) .move else .enter;
    if (next != st.target) {
        leaveTarget(win);
        st.chosen = .none;
    }
    st.target = next;
    st.taken = false;
    var answer: State.Answer = .{};
    if (found) |c| {
        if (c.editor) {
            st.taken = true;
        } else {
            st.choosing = true;
            st.taken = deliver(win, c.node, .{ .phase = phase, .x = 0, .y = 0, .mime = c.mime });
            st.choosing = false;
        }
        // The handler's choice, if it is one the target and source allow.
        const preferred = if (st.chosen != .none and c.actions.has(st.chosen)) st.chosen else c.preferred;
        if (st.taken) answer = .{ .mime = c.mime, .actions = c.actions, .preferred = preferred };
    }
    if (!sameAnswer(answer, st.answer)) {
        st.answer = answer;
        // The platform knows an in-app drag by its private type only.
        const mime = if (answer.mime != null and st.in_app) in_app_mime else answer.mime;
        if (win.drag_host) |h| h.accept(h.ctx, st.seat, st.offer, mime, answer.actions, answer.preferred);
    }
}

fn sameAnswer(a: State.Answer, b: State.Answer) bool {
    if ((a.mime == null) != (b.mime == null)) return false;
    if (a.mime) |m| if (!std.mem.eql(u8, m, b.mime.?)) return false;
    return @as(u8, @bitCast(a.actions)) == @as(u8, @bitCast(b.actions)) and a.preferred == b.preferred;
}

/// Calls the node's drop handler with the drag's state; coordinates are
/// made local.
fn deliver(win: *Window, id: NodeId, ev: node_mod.Drop) bool {
    if (!win.isLive(id)) return false;
    const h = win.node(id).handler(.drop) orelse return false;
    const st = &win.dnd;
    var e = ev;
    const local = input.toLocal(win, id, st.pos);
    e.x = local.x;
    e.y = local.y;
    e.action = st.action;
    e.source_actions = st.source_actions;
    e.mods = win.input.mods;
    return h.func(h.user, win, id, &.{ .drop = e }) != .pass;
}

/// From a drop handler's `enter` or `move`: asks the source for `action`
/// instead of the target's preferred one, until the drag leaves the node
/// (none returns to the preferred one). Ignored elsewhere.
pub fn setAction(win: *Window, action: DragAction) void {
    const st = &win.dnd;
    if (st.choosing) st.chosen = action;
}

/// The keyboard modifiers changed: the target hears another `move`, so
/// that Shift or Ctrl can change what a drop would do.
pub fn modifiersChanged(win: *Window) void {
    const st = &win.dnd;
    if (st.offer == 0 or st.dropped) return;
    route(win);
}

fn leaveTarget(win: *Window) void {
    const st = &win.dnd;
    const old = st.target;
    st.target = .none;
    st.taken = false;
    if (old != .none and win.isLive(old) and win.node(old).drop.mimes.len != 0) _ = deliver(win, old, .{ .phase = .leave, .x = 0, .y = 0 });
}

/// Forgets the drag (the platform already ended its offer).
fn clear(win: *Window) void {
    const st = &win.dnd;
    for (st.mimes.items) |m| win.gpa.free(m);
    st.mimes.clearRetainingCapacity();
    if (st.pending) |p| freeData(win, p);
    st.* = .{ .mimes = st.mimes };
}

/// Ends a read in flight; its completion is dropped.
fn stopReading(win: *Window) void {
    const t = win.dnd.reading orelse return;
    win.dnd.reading = null;
    const cb = win.clipboard orelse return;
    cb.abort(t);
    cb.cancel(&win.dnd);
}

/// Ends the offer with `action` (none refuses it) and forgets it.
fn end(win: *Window, action: DragAction) void {
    const st = &win.dnd;
    if (st.offer == 0) return;
    stopReading(win);
    if (win.drag_host) |h| h.finish(h.ctx, st.seat, st.offer, action);
    clear(win);
}

fn drop(win: *Window) void {
    const st = &win.dnd;
    const mime = st.answer.mime orelse return refuse(win);
    if (!st.taken or st.target == .none or st.action == .none) return refuse(win);
    if (st.own) {
        const cb = win.clipboard orelse return refuse(win);
        const d = cb.drag orelse return refuse(win);
        const data = d.dataFor(mime) orelse return refuse(win);
        const copy = win.gpa.dupe(u8, data) catch return refuse(win);
        return arrived(win, copy);
    }
    const cb = win.clipboard orelse return refuse(win);
    const host = win.drag_host orelse return refuse(win);
    var fds: [2]i32 = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return refuse(win);
    const t = cb.receive(fds[0], &win.dnd, .{ .ctx = win, .func = onData }) orelse {
        _ = std.os.linux.close(fds[1]);
        return;
    };
    st.reading = t;
    if (!host.receive(host.ctx, st.seat, st.offer, mime, fds[1])) refuse(win);
}

/// The drop failed or nobody takes it: the target hears `leave`.
fn refuse(win: *Window) void {
    leaveTarget(win);
    end(win, .none);
}

fn onData(ctx: *anyopaque, data: ?[]const u8) void {
    const win: *Window = @ptrCast(@alignCast(ctx));
    const st = &win.dnd;
    // Reads that were stopped report too; only the current one counts.
    if (st.reading == null) return;
    st.reading = null;
    const bytes = data orelse return refuse(win);
    const copy = win.gpa.dupe(u8, bytes) catch return refuse(win);
    arrived(win, copy);
}

/// The drop's data is here: the target gets it now, or after the open
/// transaction (`flush`).
fn arrived(win: *Window, data: []u8) void {
    const st = &win.dnd;
    if (editor.mustQueue(win)) {
        st.pending = data;
        win.requestFrame();
        return;
    }
    deliverDrop(win, data);
}

/// Delivers a drop that waited for a transaction to close.
pub fn flush(win: *Window) void {
    const st = &win.dnd;
    const data = st.pending orelse return;
    st.pending = null;
    deliverDrop(win, data);
}

fn deliverDrop(win: *Window, data: []u8) void {
    defer freeData(win, data);
    const st = &win.dnd;
    const target = st.target;
    const mime = st.answer.mime orelse return refuse(win);
    if (!win.isLive(target)) return refuse(win);
    var ok: bool = undefined;
    const n = win.node(target);
    if (n.drop.mimes.len == 0 and n.kind == .editor) {
        ok = dropText(win, target, data);
    } else {
        ok = deliver(win, target, .{ .phase = .drop, .x = 0, .y = 0, .mime = mime, .data = data });
    }
    if (st.offer == 0) return; // ended from the handler
    if (!ok) return end(win, .none);
    if (st.action == .ask) {
        st.asking = true;
        return;
    }
    end(win, st.action);
}

fn freeData(win: *Window, data: []u8) void {
    std.crypto.secureZero(u8, data);
    win.gpa.free(data);
}

/// Text dropped on an editor goes in at the drop point, as one undo step.
fn dropText(win: *Window, id: NodeId, data: []const u8) bool {
    const text = Clipboard.sanitize(win.gpa, data) catch return false;
    defer freeData(win, text);
    input.setFocus(win, id, false);
    if (!win.isLive(id)) return false;
    editor.dropText(win, id, win.dnd.pos, text);
    return true;
}

/// Resolves a drop whose action was `ask`: the action the user chose (copy
/// or move), or none to refuse it. Does nothing otherwise.
pub fn finishDrop(win: *Window, action: DragAction) void {
    if (!win.dnd.asking) return;
    end(win, if (action == .ask) .none else action);
}

/// A node was removed.
pub fn forget(win: *Window, id: NodeId) void {
    if (win.dnd.target == id) {
        win.dnd.target = .none;
        win.dnd.taken = false;
    }
}

/// Tells the node that started a drag how it goes.
pub fn notifySource(win: *Window, id: NodeId, ev: node_mod.Drag) void {
    if (!win.isLive(id)) return;
    const h = win.node(id).handler(.drag) orelse return;
    _ = h.func(h.user, win, id, &.{ .drag = ev });
}
