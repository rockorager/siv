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
//! Selection events belong to no window: the application passes them to
//! `handleEvent` once, not through every window.

const std = @import("std");
const linux = std.os.linux;
const platform = @import("platform");
const Loop = @import("loop").Loop;

const Clipboard = @This();
const Kind = platform.SelectionKind;

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

const Ready = struct { done: Done, owner: ?*anyopaque, text: ?[]u8 };

/// Text types, preferred first. Offered for copies, sought for pastes.
pub const text_mimes = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING" };

/// Platform requests, run on the compositor thread (`Compositor.call`).
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// `Platform.setSelection`; null on failure.
    set_selection: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, kind: Kind, mimes: []const []const u8, serial: u32) ?u32,
    /// Picks the first of `prefs` the offer has (`pick`) and calls
    /// `Platform.receiveSelection` with `fd`, which it then owns. False
    /// (with `fd` closed) when the offer has none.
    receive: *const fn (ctx: ?*anyopaque, seat: platform.SeatId, kind: Kind, prefs: []const []const u8, fd: i32) bool,
};

const Owned = struct {
    seat: platform.SeatId,
    source: u32,
    data: []u8,
};

/// Called with the pasted text (valid UTF-8, owned by the callee for the
/// call only) or null if there was none or it failed.
pub const Done = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, data: ?[]const u8) void,
};

const Transfer = struct {
    cb: *Clipboard,
    source: Loop.Source,
    direction: enum { read, write },
    buf: std.ArrayList(u8) = .empty,
    written: usize = 0,
    done: ?Done = null,
    /// Whose paste it is, to cancel when it goes away.
    owner: ?*anyopaque = null,
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
        if (d) |done| done.func(done.ctx, null);
    }
    cb.transfers.deinit(cb.gpa);
    cb.loop.unschedule(&cb.task);
    for (cb.ready.items) |r| {
        cb.freeText(r.text);
        r.done.func(r.done.ctx, null);
    }
    cb.ready.deinit(cb.gpa);
    for (&cb.owned) |*o| cb.dropOwned(o);
}

fn dropOwned(cb: *Clipboard, o: *?Owned) void {
    if (o.*) |own| {
        std.crypto.secureZero(u8, own.data);
        cb.gpa.free(own.data);
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
    const data = try cb.gpa.dupe(u8, text);
    const source = cb.host.set_selection(cb.host.ctx, seat, kind, &text_mimes, serial) orelse {
        cb.gpa.free(data);
        return;
    };
    const slot = &cb.owned[@intFromEnum(kind)];
    cb.dropOwned(slot);
    slot.* = .{ .seat = seat, .source = source, .data = data };
}

/// Pastes text from the seat's selection; `done` runs on the UI thread,
/// possibly before this returns.
pub fn paste(cb: *Clipboard, kind: Kind, seat: platform.SeatId, owner: ?*anyopaque, done: Done) void {
    if (cb.owned[@intFromEnum(kind)]) |o| if (o.seat == seat) {
        done.func(done.ctx, o.data);
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
    if (!cb.host.receive(cb.host.ctx, seat, kind, &text_mimes, fds[1])) cb.finish(t, false);
}

/// Ends the pastes `owner` is waiting for (it is going away): their
/// callbacks run now with null, so they can free what they hold.
pub fn cancel(cb: *Clipboard, owner: *anyopaque) void {
    var r: usize = 0;
    while (r < cb.ready.items.len) {
        if (cb.ready.items[r].owner == owner) {
            const item = cb.ready.orderedRemove(r);
            cb.freeText(item.text);
            item.done.func(item.done.ctx, null);
        } else r += 1;
    }
    var i: usize = 0;
    while (i < cb.transfers.items.len) {
        const t = cb.transfers.items[i];
        if (t.owner == owner) {
            const d = t.done;
            t.done = null;
            cb.finish(t, false);
            if (d) |done| done.func(done.ctx, null);
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
            if (o.source != s.source) {
                _ = linux.close(s.fd);
                return true;
            }
            nonblocking(s.fd);
            const t = cb.start(s.fd, .write, null, null) orelse return true;
            t.buf.appendSlice(cb.gpa, o.data) catch {
                cb.finish(t, false);
                return true;
            };
            // Write what fits now; the loop does the rest.
            onReady(&t.source, linux.EPOLL.OUT);
        },
        else => return false,
    }
    return true;
}

fn nonblocking(fd: i32) void {
    const o_nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, flags | o_nonblock);
}

fn start(cb: *Clipboard, fd: i32, direction: @FieldType(Transfer, "direction"), owner: ?*anyopaque, done: ?Done) ?*Transfer {
    const t = cb.gpa.create(Transfer) catch {
        _ = linux.close(fd);
        if (done) |d| d.func(d.ctx, null);
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
        if (done) |d| d.func(d.ctx, null);
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
        const text = if (ok and t.direction == .read) sanitize(cb.gpa, t.buf.items) catch null else null;
        cb.ready.append(cb.gpa, .{ .done = d, .owner = t.owner, .text = text }) catch {
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
        r.done.func(r.done.ctx, r.text);
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
            const n = linux.write(source.fd, rest.ptr, rest.len);
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

/// Valid UTF-8, with each invalid sequence replaced by U+FFFD and NUL
/// bytes dropped.
fn sanitize(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u8 {
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
