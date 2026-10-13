//! siv_clipboard_write and siv_clipboard_read on the headless backend:
//! a copy offers the text to other clients, pastes of this application's
//! own selection and of another client's arrive in the dispatch phase,
//! never inside the call, and destroying the application runs only the
//! destroy-notify of a paste still waiting.

const std = @import("std");
const abi = @import("abi");
const platform = @import("platform");
const compositor = @import("compositor");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const C = abi.clipboard;
const Harness = harness.Harness;
const ok = harness.ok;

const Paste = struct {
    calls: u32 = 0,
    destroyed: u32 = 0,
    got_null: bool = false,
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn done(user_data: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void {
        const p: *Paste = @ptrCast(@alignCast(user_data));
        p.calls += 1;
        if (text) |s| {
            @memcpy(p.buf[0..len], s[0..len]);
            p.len = len;
        } else p.got_null = true;
    }

    fn destroy(user_data: ?*anyopaque) callconv(.c) void {
        const p: *Paste = @ptrCast(@alignCast(user_data));
        p.destroyed += 1;
    }

    fn got(p: *const Paste) []const u8 {
        return p.buf[0..p.len];
    }
};

fn offer(h: *Harness, data: []const u8) !void {
    const self = try h.internal();
    const Ctx = struct {
        data: []const u8,
        pub fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            comp.platform.headless.offerSelection(0, .clipboard, &.{"text/plain;charset=utf-8"}, c.data) catch unreachable;
        }
    };
    var ctx: Ctx = .{ .data = data };
    try self.app.comp.call(&ctx, Ctx.run);
}

test "clipboard: write, read back, and read another client's selection" {
    var h: Harness = .{};
    try h.start(100, 60, null, null);
    defer h.stop();
    try h.settle();

    // Our own selection: delivered later, not inside the call.
    try ok(C.siv_clipboard_write(h.window, .clipboard, "copied", 6));
    var own: Paste = .{};
    try ok(C.siv_clipboard_read(h.window, .clipboard, Paste.done, Paste.destroy, &own));
    try testing.expectEqual(0, own.calls);
    try h.settle();
    try testing.expectEqual(1, own.calls);
    try testing.expectEqual(1, own.destroyed);
    try testing.expectEqualStrings("copied", own.got());

    // Another client's offer is read through a pipe.
    try offer(&h, "from elsewhere");
    try h.settle();
    var other: Paste = .{};
    try ok(C.siv_clipboard_read(h.window, .clipboard, Paste.done, Paste.destroy, &other));
    try h.settle();
    try testing.expectEqual(1, other.calls);
    try testing.expectEqual(1, other.destroyed);
    try testing.expectEqualStrings("from elsewhere", other.got());

    // Nothing in the primary selection: the callback gets NULL.
    var empty: Paste = .{};
    try ok(C.siv_clipboard_read(h.window, .primary, Paste.done, Paste.destroy, &empty));
    try h.settle();
    try testing.expect(empty.got_null and empty.calls == 1 and empty.destroyed == 1);

    // Errors run the destroy-notify at once.
    var bad: Paste = .{};
    try testing.expectEqual(t.Result.error_invalid_argument, C.siv_clipboard_read(h.window, .clipboard, null, Paste.destroy, &bad));
    try testing.expectEqual(t.Result.error_unsupported, C.siv_clipboard_read(h.window, @enumFromInt(7), Paste.done, Paste.destroy, &bad));
    try testing.expectEqual(t.Result.error_invalid_handle, C.siv_clipboard_read(.null, .clipboard, Paste.done, Paste.destroy, &bad));
    try testing.expectEqual(3, bad.destroyed);
    try testing.expectEqual(0, bad.calls);
}

test "clipboard: a paste waiting at teardown runs only its destroy-notify" {
    var h: Harness = .{};
    try h.start(100, 60, null, null);
    try h.settle();
    try ok(C.siv_clipboard_write(h.window, .clipboard, "x", 1));
    var p: Paste = .{};
    try ok(C.siv_clipboard_read(h.window, .clipboard, Paste.done, Paste.destroy, &p));
    h.stop();
    try testing.expectEqual(0, p.calls);
    try testing.expectEqual(1, p.destroyed);
}

// Any MIME type: siv_clipboard_write_data and siv_clipboard_read_data.

const linux = std.os.linux;
const capi = t.c;

const uris = "file:///tmp/a%20b\r\nfile:///tmp/c\r\n";
const plain = "/tmp/a b\n/tmp/c";

const Copier = struct {
    result: t.Result = .error_busy,

    fn onKey(ud: ?*anyopaque, _: t.Node, ev: ?*const t.Event) callconv(.c) bool {
        const s: *Copier = @ptrCast(@alignCast(ud.?));
        if (!ev.?.flags.pressed) return false;
        const mimes = "text/uri-list\ntext/plain;charset=utf-8";
        const data = uris ++ plain;
        const lengths = [_]usize{ uris.len, plain.len };
        s.result = capi.siv_clipboard_write_data(ev.?.window, .clipboard, &.{ .mimes = mimes, .mimes_len = mimes.len, .data = data, .data_count = data.len, .lengths = &lengths, .lengths_count = 2 });
        return true;
    }
};

const Reader = struct {
    calls: u32 = 0,
    destroyed: u32 = 0,
    result: t.Result = .error_busy,
    index: u32 = 99,
    mime: [64]u8 = undefined,
    mime_len: usize = 0,
    data: [256]u8 = undefined,
    data_len: usize = 0,

    fn got(ud: ?*anyopaque, d: ?*const t.ClipboardData) callconv(.c) void {
        const r: *Reader = @ptrCast(@alignCast(ud.?));
        const x = d.?;
        r.calls += 1;
        r.result = x.result;
        r.index = x.index;
        r.mime_len = x.mime_len;
        if (x.mime_len > 0) @memcpy(r.mime[0..x.mime_len], x.mime.?[0..x.mime_len]);
        r.data_len = x.data_count;
        if (x.data_count > 0) @memcpy(r.data[0..x.data_count], x.data.?[0..x.data_count]);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const r: *Reader = @ptrCast(@alignCast(ud.?));
        r.destroyed += 1;
    }

    fn wait(r: *Reader, h: *Harness) !void {
        const deadline = @import("loop").Loop.now() + 10 * std.time.ns_per_s;
        while (r.destroyed == 0) {
            if (@import("loop").Loop.now() > deadline) return error.Timeout;
            try ok(capi.siv_app_dispatch(h.app, 5));
        }
    }
};

/// Runs `f(headless, ctx)` on the compositor thread.
fn onHeadless(h: *Harness, ctx: anytype, comptime f: fn (*platform.Headless, @TypeOf(ctx)) void) !void {
    const self = try h.internal();
    const Ctx = struct {
        inner: @TypeOf(ctx),
        fn run(p: ?*anyopaque, comp: *compositor.Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(p));
            f(comp.platform.headless, s.inner);
        }
    };
    var cx: Ctx = .{ .inner = ctx };
    try self.app.comp.call(&cx, Ctx.run);
}

const Request = struct { mime: []const u8, fd: i32 = -1 };

/// What another client pasting this application's clipboard in `mime`
/// reads.
fn pasteElsewhere(h: *Harness, mime: []const u8, out: []u8) ![]u8 {
    var req: Request = .{ .mime = mime };
    try onHeadless(h, &req, struct {
        fn f(hl: *platform.Headless, r: *Request) void {
            r.fd = hl.requestSelection(0, .clipboard, r.mime) catch -1;
        }
    }.f);
    if (req.fd < 0) return error.NoSelection;
    defer _ = linux.close(req.fd);
    const flags = linux.fcntl(req.fd, linux.F.GETFL, 0);
    _ = linux.fcntl(req.fd, linux.F.SETFL, flags | @as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
    var n: usize = 0;
    const deadline = @import("loop").Loop.now() + 10 * std.time.ns_per_s;
    while (true) {
        try ok(capi.siv_app_dispatch(h.app, 5));
        const rc = linux.read(req.fd, out[n..].ptr, out.len - n);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) break else {
                n += rc;
            },
            .AGAIN => {},
            else => return error.ReadFailed,
        }
        if (@import("loop").Loop.now() > deadline) return error.Timeout;
    }
    return out[0..n];
}

const DataOffer = struct { mimes: []const []const u8, data: []const u8 };

test "clipboard: data in two MIME types, pasted elsewhere and read back by type" {
    var h: Harness = .{};
    try h.start(200, 100, null, null);
    defer h.stop();
    var copier: Copier = .{};
    var txn: t.Txn = .null;
    try ok(capi.siv_txn_begin(h.window, &txn));
    _ = capi.siv_on(txn, capi.siv_window_root(h.window), .key, Copier.onKey, null, &copier);
    try ok(capi.siv_txn_commit(txn));
    try h.settle();
    // Ctrl+C copies, from the key's handler.
    try h.typeKey('c', "c", .{ .ctrl = true });
    try h.settle();
    try ok(copier.result);

    // Another client pastes each type and gets that type's share.
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(uris, try pasteElsewhere(&h, "text/uri-list", &buf));
    try testing.expectEqualStrings(plain, try pasteElsewhere(&h, "text/plain;charset=utf-8", &buf));

    // Reading the application's own clipboard takes the first type it
    // has, never inside the call.
    var own: Reader = .{};
    const want = "x-special/gnome-copied-files\ntext/uri-list";
    try ok(capi.siv_clipboard_read_data(h.window, .clipboard, want, want.len, Reader.got, Reader.destroy, &own));
    try testing.expectEqual(@as(u32, 0), own.calls);
    try own.wait(&h);
    try testing.expectEqual(@as(u32, 1), own.calls);
    try ok(own.result);
    try testing.expectEqual(@as(u32, 1), own.index);
    try testing.expectEqualStrings("text/uri-list", own.mime[0..own.mime_len]);
    try testing.expectEqualStrings(uris, own.data[0..own.data_len]);

    // Another client's offer, through a pipe.
    var data_offer: DataOffer = .{ .mimes = &.{ "image/png", "text/uri-list" }, .data = "file:///x\r\n" };
    try onHeadless(&h, &data_offer, struct {
        fn f(hl: *platform.Headless, o: *DataOffer) void {
            hl.offerSelection(0, .clipboard, o.mimes, o.data) catch unreachable;
        }
    }.f);
    try h.settle();
    var other: Reader = .{};
    try ok(capi.siv_clipboard_read_data(h.window, .clipboard, want, want.len, Reader.got, Reader.destroy, &other));
    try other.wait(&h);
    try ok(other.result);
    try testing.expectEqualStrings("text/uri-list", other.mime[0..other.mime_len]);
    try testing.expectEqualStrings("file:///x\r\n", other.data[0..other.data_len]);

    // None of the types: unavailable, and still only after the call.
    var none: Reader = .{};
    try ok(capi.siv_clipboard_read_data(h.window, .clipboard, "application/x-none", 18, Reader.got, Reader.destroy, &none));
    try testing.expectEqual(@as(u32, 0), none.calls);
    try none.wait(&h);
    try testing.expectEqual(t.Result.error_unavailable, none.result);
    try testing.expectEqual(@as(usize, 0), none.mime_len);

    // Bad arguments fail at once and hand user_data back.
    var bad: Reader = .{};
    try testing.expectEqual(t.Result.error_invalid_argument, capi.siv_clipboard_read_data(h.window, .clipboard, "", 0, Reader.got, Reader.destroy, &bad));
    try testing.expectEqual(@as(u32, 1), bad.destroyed);
    const lengths = [_]usize{9};
    try testing.expectEqual(t.Result.error_invalid_argument, capi.siv_clipboard_write_data(h.window, .clipboard, &.{ .mimes = "a/b\nc/d", .mimes_len = 7, .data = "x", .data_count = 1, .lengths = &lengths, .lengths_count = 1 }));

    // A read still waiting when the application goes runs only its
    // destroy-notify.
    var late: Reader = .{};
    try ok(capi.siv_clipboard_read_data(h.window, .clipboard, "text/uri-list", 13, Reader.got, Reader.destroy, &late));
    h.stop();
    h.app = .null;
    try testing.expectEqual(@as(u32, 0), late.calls);
    try testing.expectEqual(@as(u32, 1), late.destroyed);
}
