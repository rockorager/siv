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
