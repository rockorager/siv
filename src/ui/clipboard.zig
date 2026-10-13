//! Clipboard and primary selection (D19), one per application like Fonts.
//!
//! Copying keeps the data here and offers it through the platform, on the
//! compositor thread (`Host`, D8). When another client pastes it, the
//! platform forwards a `selection_send` event with a pipe, which is
//! written from the UI loop without blocking. Pasting asks the platform to
//! have the owner write the best text type into a pipe, read on the UI
//! loop up to a size limit. While this application owns a selection,
//! pasting it takes the data directly.
//!
//! Drag and drop moves data the same way (dnd.zig routes drags over a
//! window's nodes): drops are read here as raw bytes, and the data of this
//! application's drag lives here while the drag lasts, written to whoever
//! asks for it.
//!
//! Selection and drag source events belong to no window: the application
//! passes them to `handleEvent` once, not through every window.

const std = @import("std");
const linux = std.os.linux;
const platform = @import("platform");
const Loop = @import("loop").Loop;

const Window = @import("Window.zig");
const NodeId = @import("node.zig").NodeId;
const dnd = @import("dnd.zig");

const Clipboard = @This();
pub const Kind = platform.SelectionKind;

gpa: std.mem.Allocator,
loop: *Loop,
host: Host,
/// Largest paste accepted, in bytes; larger transfers are dropped.
limit: usize = 16 << 20,
owned: [2]?Owned = .{ null, null },
/// Whether the seat's selection has an offer (from any client).
offered: [2]bool = .{ false, false },
transfers: std.ArrayList(*Transfer) = .empty,
/// Finished pastes, reported in the dispatch phase (D5): transfers end in
/// the io phase, where application code must not run.
ready: std.ArrayList(Ready) = .empty,
task: Loop.Task = .{ .func = deliver },
/// This application's drag, while it lasts.
drag: ?DragOut = null,

/// The data of this application's drag: mime types and data in offer
/// order (copied), and the node that started it, which hears how it goes.
pub const DragOut = struct {
    seat: platform.SeatId,
    source: u32,
    mimes: []const []const u8,
    data: []const []const u8,
    actions: platform.DragActions,
    /// Offered to other clients under a private mime type only.
    in_app: bool,
    origin: ?*Window,
    node: NodeId,

    fn free(d: DragOut, gpa: std.mem.Allocator) void {
        for (d.mimes) |m| gpa.free(m);
        for (d.data) |b| {
            std.crypto.secureZero(u8, @constCast(b));
            gpa.free(b);
        }
        gpa.free(d.mimes);
        gpa.free(d.data);
    }

    /// The data in `mime`.
    pub fn dataFor(d: *const DragOut, mime: []const u8) ?[]const u8 {
        for (d.mimes, d.data) |m, b| if (std.mem.eql(u8, m, mime)) return b;
        return null;
    }
};

const Ready = struct { done: Done, owner: ?*anyopaque, text: ?[]u8, mime: usize = 0 };

/// Text types, preferred first. Offered for copies, sought for pastes.
pub const text_mimes = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING" };

/// Platform requests, run on the compositor thread (`Compositor.call`).
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// `Platform.setSelection`; null on failure.
    set_selection: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, kind: Kind, mimes: []const []const u8, serial: u32) ?u32,
    /// Picks the first of `prefs` the offer has (`pick`) and calls
    /// `Platform.receiveSelection` with `fd`, which it then owns. Returns
    /// the index in `prefs` of the type picked, or null (with `fd` closed)
    /// when the offer has none.
    receive: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, kind: Kind, prefs: []const []const u8, fd: i32) ?usize,
};

/// What this application offers as a selection: its types, and the data
/// of each (a text copy offers every text type with one text).
const Owned = struct {
    seat: platform.SeatId,
    source: u32,
    /// `text_mimes` for text copies (not owned), else owned copies.
    mimes: []const []const u8,
    /// One per type, or one for all of them.
    data: [][]u8,

    fn dataAt(o: *const Owned, index: usize) ?[]const u8 {
        if (o.data.len == 1) return o.data[0];
        return if (index < o.data.len) o.data[index] else null;
    }

    /// The index of the first of `prefs` offered.
    fn find(o: *const Owned, prefs: []const []const u8) ?struct { pref: usize, mime: usize } {
        for (prefs, 0..) |p, pi| for (o.mimes, 0..) |m, mi| if (std.mem.eql(u8, m, p)) return .{ .pref = pi, .mime = mi };
        return null;
    }
};

/// Called with the pasted text (valid UTF-8, owned by the callee for the
/// call only) or null if there was none or it failed. A paste of chosen
/// types (`pasteTypes`) calls `typed` instead, with the bytes as they
/// are and the index of the type among those asked for.
pub const Done = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, data: ?[]const u8) void,
    typed: ?*const fn (ctx: *anyopaque, mime: usize, data: ?[]const u8) void = null,

    fn report(d: Done, mime: usize, data: ?[]const u8) void {
        if (d.typed) |f| f(d.ctx, mime, data) else d.func(d.ctx, data);
    }
};

pub const Transfer = struct {
    cb: *Clipboard,
    source: Loop.Source,
    direction: enum { read, write },
    buf: std.ArrayList(u8) = .empty,
    written: usize = 0,
    /// A read of bytes as they are, not text.
    raw: bool = false,
    done: ?Done = null,
    /// Whose paste it is, to cancel when it goes away.
    owner: ?*anyopaque = null,
    /// A typed paste: the index of the type picked among those asked for.
    mime: usize = 0,
};

pub fn init(gpa: std.mem.Allocator, loop: *Loop, host: Host) Clipboard {
    return .{ .gpa = gpa, .loop = loop, .host = host };
}

/// Pastes still in flight report null.
pub fn deinit(cb: *Clipboard) void {
    while (cb.transfers.items.len != 0) {
        const t = cb.transfers.items[cb.transfers.items.len - 1];
        const d = t.done;
        t.done = null;
        cb.finish(t, false);
        if (d) |done| done.report(t.mime, null);
    }
    cb.transfers.deinit(cb.gpa);
    cb.loop.unschedule(&cb.task);
    for (cb.ready.items) |r| {
        cb.freeText(r.text);
        r.done.report(r.mime, null);
    }
    cb.ready.deinit(cb.gpa);
    for (&cb.owned) |*o| cb.dropOwned(o);
    if (cb.drag) |d| d.free(cb.gpa);
    cb.drag = null;
}

/// A window is going away: its drag, if any, reports to nobody.
pub fn forgetWindow(cb: *Clipboard, win: *Window) void {
    if (cb.drag) |*d| if (d.origin == win) {
        d.origin = null;
    };
}

/// Copies `items` (mime type and data pairs) for a drag. The caller
/// starts it and hands the result to `adoptDrag`, or frees it.
pub fn copyDrag(cb: *Clipboard, items: []const DragItem) error{OutOfMemory}!DragOut {
    const gpa = cb.gpa;
    const mimes = try gpa.alloc([]const u8, items.len);
    errdefer gpa.free(mimes);
    const data = try gpa.alloc([]const u8, items.len);
    errdefer gpa.free(data);
    var n: usize = 0;
    errdefer for (0..n) |i| {
        gpa.free(mimes[i]);
        gpa.free(data[i]);
    };
    while (n < items.len) : (n += 1) {
        mimes[n] = try gpa.dupe(u8, items[n].mime);
        data[n] = gpa.dupe(u8, items[n].data) catch |err| {
            gpa.free(mimes[n]);
            return err;
        };
    }
    return .{ .seat = 0, .source = 0, .mimes = mimes, .data = data, .actions = .{}, .in_app = false, .origin = null, .node = .none };
}

pub const DragItem = struct { mime: []const u8, data: []const u8 };

/// Makes `d` this application's drag, replacing the previous one, whose
/// node hears that it ended.
pub fn adoptDrag(cb: *Clipboard, d: DragOut) void {
    const old = cb.drag;
    cb.drag = d;
    if (old) |o| {
        o.free(cb.gpa);
        if (o.origin) |win| dnd.notifySource(win, o.node, .{ .phase = .end });
    }
}

pub fn freeDrag(cb: *Clipboard, d: DragOut) void {
    d.free(cb.gpa);
}

/// Reads bytes as they are from `fd` (another client writes them), up to
/// the limit. `done` runs in the dispatch phase with the bytes, or null
/// on failure or above the limit. Returns the transfer, to `abort` it.
pub fn receive(cb: *Clipboard, fd: i32, owner: ?*anyopaque, done: Done) ?*Transfer {
    nonblocking(fd);
    const t = cb.start(fd, .read, owner, done) orelse return null;
    t.raw = true;
    return t;
}

/// Ends a transfer as failed.
pub fn abort(cb: *Clipboard, t: *Transfer) void {
    cb.finish(t, false);
}

fn dropOwned(cb: *Clipboard, o: *?Owned) void {
    if (o.*) |own| {
        for (own.data) |d| {
            std.crypto.secureZero(u8, d);
            cb.gpa.free(d);
        }
        cb.gpa.free(own.data);
        if (own.mimes.ptr != &text_mimes) {
            for (own.mimes) |m| cb.gpa.free(m);
            cb.gpa.free(own.mimes);
        }
    }
    o.* = null;
}

/// The first of `prefs` that `offered` contains.
pub fn pick(offered: []const []const u8, prefs: []const []const u8) ?[]const u8 {
    for (prefs) |p| for (offered) |o| if (std.mem.eql(u8, o, p)) return p;
    return null;
}

/// Offers `text` as the seat's clipboard or primary selection. `serial`
/// is the input event that asked for it.
pub fn copy(cb: *Clipboard, kind: Kind, seat: platform.SeatId, serial: u32, text: []const u8) error{OutOfMemory}!void {
    const data = try cb.gpa.alloc([]u8, 1);
    errdefer cb.gpa.free(data);
    data[0] = try cb.gpa.dupe(u8, text);
    cb.offer(kind, seat, serial, .{ .seat = seat, .source = 0, .mimes = &text_mimes, .data = data });
}

/// Offers `items` (copied), each a MIME type and its data, as the seat's
/// clipboard or primary selection: files as text/uri-list, an image as
/// image/png. `serial` is the input event that asked for it.
pub fn copyItems(cb: *Clipboard, kind: Kind, seat: platform.SeatId, serial: u32, items: []const DragItem) error{OutOfMemory}!void {
    const gpa = cb.gpa;
    const mimes = try gpa.alloc([]const u8, items.len);
    var nm: usize = 0;
    errdefer {
        for (mimes[0..nm]) |m| gpa.free(m);
        gpa.free(mimes);
    }
    const data = try gpa.alloc([]u8, items.len);
    var nd: usize = 0;
    errdefer {
        for (data[0..nd]) |d| gpa.free(d);
        gpa.free(data);
    }
    for (items) |it| {
        mimes[nm] = try gpa.dupe(u8, it.mime);
        nm += 1;
        data[nd] = try gpa.dupe(u8, it.data);
        nd += 1;
    }
    cb.offer(kind, seat, serial, .{ .seat = seat, .source = 0, .mimes = mimes, .data = data });
}

/// Makes `o` (whose memory it takes) the selection of its kind.
fn offer(cb: *Clipboard, kind: Kind, seat: platform.SeatId, serial: u32, o: Owned) void {
    var own: ?Owned = o;
    const source = cb.host.set_selection(cb.host.ctx, seat, kind, o.mimes, serial) orelse return cb.dropOwned(&own);
    own.?.source = source;
    const slot = &cb.owned[@intFromEnum(kind)];
    cb.dropOwned(slot);
    slot.* = own;
}

/// Pastes text from the seat's selection; `done` runs on the UI thread,
/// possibly before this returns.
pub fn paste(cb: *Clipboard, kind: Kind, seat: platform.SeatId, owner: ?*anyopaque, done: Done) void {
    if (cb.owned[@intFromEnum(kind)]) |o| if (o.seat == seat) {
        const hit = o.find(&text_mimes) orelse return done.func(done.ctx, null);
        done.func(done.ctx, o.dataAt(hit.mime));
        return;
    };
    if (!cb.offered[@intFromEnum(kind)]) return done.func(done.ctx, null);
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return done.func(done.ctx, null);
    nonblocking(fds[0]);
    const t = cb.start(fds[0], .read, owner, done) orelse {
        _ = linux.close(fds[1]);
        return;
    };
    if (cb.host.receive(cb.host.ctx, seat, kind, &text_mimes, fds[1]) == null) cb.finish(t, false);
}

/// Pastes the first of `prefs` (MIME types, preferred first) the seat's
/// selection has, as raw bytes: `done.typed` runs on the UI thread with
/// the index of the type in `prefs`, possibly before this returns.
pub fn pasteTypes(cb: *Clipboard, kind: Kind, seat: platform.SeatId, prefs: []const []const u8, owner: ?*anyopaque, done: Done) void {
    if (cb.owned[@intFromEnum(kind)]) |o| if (o.seat == seat) {
        const hit = o.find(prefs) orelse return done.report(0, null);
        done.report(hit.pref, o.dataAt(hit.mime));
        return;
    };
    if (!cb.offered[@intFromEnum(kind)]) return done.report(0, null);
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return done.report(0, null);
    nonblocking(fds[0]);
    const t = cb.start(fds[0], .read, owner, done) orelse {
        _ = linux.close(fds[1]);
        return;
    };
    t.raw = true;
    if (cb.host.receive(cb.host.ctx, seat, kind, prefs, fds[1])) |i| t.mime = i else cb.finish(t, false);
}

/// Ends the pastes `owner` is waiting for (it is going away): their
/// callbacks run now with null, so they can free what they hold.
pub fn cancel(cb: *Clipboard, owner: *anyopaque) void {
    var r: usize = 0;
    while (r < cb.ready.items.len) {
        if (cb.ready.items[r].owner == owner) {
            const item = cb.ready.orderedRemove(r);
            cb.freeText(item.text);
            item.done.report(item.mime, null);
        } else r += 1;
    }
    var i: usize = 0;
    while (i < cb.transfers.items.len) {
        const t = cb.transfers.items[i];
        if (t.owner == owner) {
            const d = t.done;
            const m = t.mime;
            t.done = null;
            cb.finish(t, false);
            if (d) |done| done.report(m, null);
        } else i += 1;
    }
}

/// Handles selection events; returns whether the event was one.
pub fn handleEvent(cb: *Clipboard, event: *const platform.Event) bool {
    switch (event.*) {
        .selection => |s| cb.offered[@intFromEnum(s.kind)] = s.offer,
        .selection_cancelled => |c| {
            const slot = &cb.owned[@intFromEnum(c.kind)];
            if (slot.*) |o| if (o.source == c.source and o.seat == c.seat) cb.dropOwned(slot);
        },
        .selection_send => |s| {
            const o = cb.owned[@intFromEnum(s.kind)] orelse {
                _ = linux.close(s.fd);
                return true;
            };
            const data = if (o.source == s.source) o.dataAt(s.mime) else null;
            cb.send(s.fd, data orelse {
                _ = linux.close(s.fd);
                return true;
            });
        },
        .drag_send => |s| {
            const d = cb.drag orelse {
                _ = linux.close(s.fd);
                return true;
            };
            // An in-app drag's private type has no data to give away.
            if (d.source != s.source or d.seat != s.seat or d.in_app or s.mime >= d.data.len) {
                _ = linux.close(s.fd);
                return true;
            }
            cb.send(s.fd, d.data[s.mime]);
        },
        .drag_source => |s| {
            const d = cb.drag orelse return true;
            if (d.source != s.source or d.seat != s.seat) return true;
            const ev: @import("node.zig").Drag = switch (s.phase) {
                .target => .{ .phase = .move, .accepted = s.accepted, .action = s.action },
                .action => .{ .phase = .move, .accepted = true, .action = s.action },
                .dropped => .{ .phase = .drop },
                .finished => .{ .phase = .end, .action = s.action },
                .cancelled => .{ .phase = .end },
            };
            if (ev.phase == .end) {
                d.free(cb.gpa);
                cb.drag = null;
            }
            if (d.origin) |win| dnd.notifySource(win, d.node, ev);
        },
        else => return false,
    }
    return true;
}

/// Writes `data` (copied) to `fd` without blocking, then closes it.
fn send(cb: *Clipboard, fd: i32, data: []const u8) void {
    nonblocking(fd);
    const t = cb.start(fd, .write, null, null) orelse return;
    t.buf.appendSlice(cb.gpa, data) catch return cb.finish(t, false);
    // Write what fits now; the loop does the rest.
    onReady(&t.source, linux.EPOLL.OUT);
}

fn nonblocking(fd: i32) void {
    const o_nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, flags | o_nonblock);
}

fn start(cb: *Clipboard, fd: i32, direction: @FieldType(Transfer, "direction"), owner: ?*anyopaque, done: ?Done) ?*Transfer {
    const t = cb.gpa.create(Transfer) catch {
        _ = linux.close(fd);
        if (done) |d| d.report(0, null);
        return null;
    };
    t.* = .{
        .cb = cb,
        .source = .{ .fd = fd, .events = if (direction == .read) linux.EPOLL.IN else linux.EPOLL.OUT, .func = onReady },
        .direction = direction,
        .owner = owner,
        .done = done,
    };
    cb.transfers.append(cb.gpa, t) catch {
        cb.gpa.destroy(t);
        _ = linux.close(fd);
        if (done) |d| d.report(0, null);
        return null;
    };
    cb.loop.addSource(&t.source) catch {
        cb.finish(t, false);
        return null;
    };
    return t;
}

/// Ends a transfer: closes its pipe, reports a paste, frees it.
fn finish(cb: *Clipboard, t: *Transfer, ok: bool) void {
    cb.loop.removeSource(&t.source);
    _ = linux.close(t.source.fd);
    for (cb.transfers.items, 0..) |x, i| if (x == t) {
        _ = cb.transfers.swapRemove(i);
        break;
    };
    if (t.done) |d| {
        const text = if (!ok or t.direction != .read) null else if (t.raw) cb.gpa.dupe(u8, t.buf.items) catch null else sanitize(cb.gpa, t.buf.items) catch null;
        cb.ready.append(cb.gpa, .{ .done = d, .owner = t.owner, .text = text, .mime = t.mime }) catch {
            cb.freeText(text);
        };
        cb.loop.schedule(&cb.task, .dispatch);
    }
    std.crypto.secureZero(u8, t.buf.items);
    t.buf.deinit(cb.gpa);
    cb.gpa.destroy(t);
}

fn freeText(cb: *Clipboard, text: ?[]u8) void {
    if (text) |s| {
        std.crypto.secureZero(u8, s);
        cb.gpa.free(s);
    }
}

fn deliver(task: *Loop.Task) void {
    const cb: *Clipboard = @fieldParentPtr("task", task);
    while (cb.ready.items.len != 0) {
        const r = cb.ready.orderedRemove(0);
        defer cb.freeText(r.text);
        r.done.report(r.mime, r.text);
    }
}

/// Runs in the loop's io phase: only moves bytes; completions are
/// delivered in the dispatch phase.
fn onReady(source: *Loop.Source, events: u32) void {
    const t: *Transfer = @fieldParentPtr("source", source);
    const cb = t.cb;
    _ = events;
    switch (t.direction) {
        .write => while (t.written < t.buf.items.len) {
            const rest = t.buf.items[t.written..];
            const n = writePipe(source.fd, rest);
            switch (linux.errno(n)) {
                .SUCCESS => t.written += n,
                .INTR => {},
                .AGAIN => return,
                else => return cb.finish(t, false),
            }
        } else cb.finish(t, true),
        .read => while (true) {
            t.buf.ensureUnusedCapacity(cb.gpa, 16 * 1024) catch return cb.finish(t, false);
            const space = t.buf.unusedCapacitySlice();
            const n = linux.read(source.fd, space.ptr, space.len);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return cb.finish(t, true);
                    t.buf.items.len += n;
                    if (t.buf.items.len > cb.limit) return cb.finish(t, false);
                },
                .INTR => {},
                .AGAIN => return,
                else => return cb.finish(t, false),
            }
        },
    }
}

/// write() to a pipe another client reads. If it closed its end, the
/// write fails with EPIPE and raises SIGPIPE, whose default action ends
/// the process: an application would die of a paste abandoned midway.
/// SIGPIPE is blocked on this thread around the write, and one the write
/// raised is taken back.
fn writePipe(fd: i32, bytes: []const u8) usize {
    var pipe_set = linux.sigemptyset();
    linux.sigaddset(&pipe_set, .PIPE);
    var old: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, &pipe_set, &old);
    defer _ = linux.sigprocmask(linux.SIG.SETMASK, &old, null);
    var pending: linux.sigset_t = undefined;
    _ = linux.syscall2(.rt_sigpending, @intFromPtr(&pending), linux.NSIG / 8);
    const n = linux.write(fd, bytes.ptr, bytes.len);
    // One SIGPIPE that was pending already is someone else's.
    if (linux.errno(n) == .PIPE and !linux.sigismember(&pending, .PIPE)) {
        const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = linux.syscall4(.rt_sigtimedwait, @intFromPtr(&pipe_set), 0, @intFromPtr(&zero), linux.NSIG / 8);
    }
    return n;
}

/// Valid UTF-8, with each invalid sequence replaced by U+FFFD and NUL
/// bytes dropped.
pub fn sanitize(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (n != 0 and i + n <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + n])) {
            if (bytes[i] != 0) try out.appendSlice(gpa, bytes[i .. i + n]);
            i += n;
        } else {
            try out.appendSlice(gpa, "\u{fffd}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "sanitize keeps valid text and replaces the rest" {
    const s = try sanitize(std.testing.allocator, "a\xffb\x00\xc3\xa9");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a\u{fffd}b\u{e9}", s);
    try std.testing.expectEqualStrings("UTF8_STRING", pick(&.{ "image/png", "UTF8_STRING", "text/plain" }, &text_mimes).?);
}

test "fuzz: pasted and dropped text sanitizes to valid UTF-8 without NULs" {
    try std.testing.fuzz({}, fuzzSanitize, .{ .corpus = &.{ "plain", "a\xffb\x00\xc3", "\xf0\x9f\x98\x80\xed\xa0\x80" } });
}

fn fuzzSanitize(_: void, smith: *std.testing.Smith) !void {
    var buf: [1024]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const out = try sanitize(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0) == null);
    // Valid input without NULs comes out unchanged.
    if (std.unicode.utf8ValidateSlice(input) and std.mem.indexOfScalar(u8, input, 0) == null) try std.testing.expectEqualStrings(input, out);
}

test "a paste whose reader closes early ends without SIGPIPE" {
    const gpa = std.testing.allocator;
    var loop = try Loop.init(gpa);
    defer loop.deinit();
    const Fake = struct {
        fn set(_: ?*anyopaque, _: platform.SeatId, _: Kind, _: []const []const u8, _: u32) ?u32 {
            return 1;
        }
        fn receive(_: ?*anyopaque, _: platform.SeatId, _: Kind, _: []const []const u8, fd: i32) ?usize {
            _ = linux.close(fd);
            return null;
        }
    };
    var cb = init(gpa, &loop, .{ .set_selection = Fake.set, .receive = Fake.receive });
    defer cb.deinit();
    try cb.copy(.clipboard, 0, 1, "copied");

    // Another client asks for the selection and closes its end before
    // reading. SIGPIPE's default action would end the application; here
    // it is blocked, so one the write raised stays pending.
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    _ = linux.close(fds[0]);
    var pipe_set = linux.sigemptyset();
    linux.sigaddset(&pipe_set, .PIPE);
    var old: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, &pipe_set, &old);
    defer _ = linux.sigprocmask(linux.SIG.SETMASK, &old, null);
    try std.testing.expect(cb.handleEvent(&.{ .selection_send = .{ .seat = 0, .kind = .clipboard, .source = 1, .mime = 0, .fd = fds[1] } }));
    var pending: linux.sigset_t = undefined;
    _ = linux.syscall2(.rt_sigpending, @intFromPtr(&pending), linux.NSIG / 8);
    const raised = linux.sigismember(&pending, .PIPE);
    if (raised) {
        const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = linux.syscall4(.rt_sigtimedwait, @intFromPtr(&pipe_set), 0, @intFromPtr(&zero), linux.NSIG / 8);
    }
    try std.testing.expect(!raised);
    try std.testing.expectEqual(@as(usize, 0), cb.transfers.items.len);
}
