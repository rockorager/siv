//! The Zig module: its types against the C header, and a page loaded
//! through it on siv's headless backend.
const std = @import("std");
const siv = @import("siv");
const webview = @import("siv_webview");
const h = @import("c_header");

test "the Zig types match the C header" {
    inline for (.{ .{ webview.Event, h.siv_webview_event }, .{ webview.Desc, h.siv_webview_desc }, .{ webview.State, h.siv_webview_state } }) |pair| {
        const Z, const C = pair;
        try std.testing.expectEqual(@sizeOf(C), @sizeOf(Z));
        inline for (@typeInfo(C).@"struct".field_names) |field| {
            const name = comptime if (@hasField(Z, field)) field else field ++ "_ptr";
            try std.testing.expectEqual(@offsetOf(C, field), @offsetOf(Z, name));
        }
    }
    try std.testing.expectEqual(@as(u32, h.SIV_WEBVIEW_DEVELOPER_EXTRAS), @as(u32, @bitCast(webview.Flags{ .developer_extras = true })));
    try std.testing.expectEqual(@as(u32, h.SIV_WEBVIEW_CAN_GO_FORWARD), @as(u32, @bitCast(webview.EventFlags{ .can_go_forward = true })));
    try std.testing.expectEqual(@as(c_int, h.SIV_WEBVIEW_EVENT_LOAD_FAILED), @intFromEnum(webview.EventType.load_failed));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const Seen = struct {
    title: [64]u8 = undefined,
    title_len: usize = 0,

    fn onEvent(ud: ?*anyopaque, _: webview.Webview, e: *const webview.Event) callconv(.c) bool {
        const s: *Seen = @ptrCast(@alignCast(ud.?));
        if (e.type == .title) {
            const t = e.text();
            s.title_len = @min(t.len, s.title.len);
            @memcpy(s.title[0..s.title_len], t[0..s.title_len]);
        }
        return false;
    }
};

test "a page's title through the Zig module" {
    if (!webview.engineAvailable(.auto)) return error.SkipZigTest;
    _ = setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    const app = try siv.appCreate(.{ .backend = .headless });
    defer siv.appDestroy(app);
    const window = try siv.windowCreate(app, .{ .width = 200, .height = 100 });
    var seen: Seen = .{};
    const wv = try webview.create(window, .{ .on_event = Seen.onEvent, .user_data = &seen, .flags = .{ .ephemeral = true } });
    defer wv.destroy();
    const txn = try siv.txnBegin(window);
    const node = wv.view(txn, siv.windowGetRoot(window));
    try siv.txnCommit(txn);
    try std.testing.expect(node != .null);
    try std.testing.expectEqual(node, wv.node());
    try wv.loadHtml("<title>Zig</title>", "");
    var tries: u32 = 0;
    while (!std.mem.eql(u8, seen.title[0..seen.title_len], "Zig") and tries < 1500) : (tries += 1) try siv.appDispatch(app, 20);
    try std.testing.expectEqualStrings("Zig", seen.title[0..seen.title_len]);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Zig", try wv.title(&buf));
    try std.testing.expectError(error.Busy, wv.goBack());
}
