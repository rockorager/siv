//! The guide's first program in Zig: a window with a title, a button, and
//! a label that counts the button's clicks.
//!
//!     zig build guide && ./zig-out/bin/guide-hello-zig

const std = @import("std");
const siv = @import("siv");

const Counter = struct {
    label: siv.Node = .null,
    clicks: u32 = 0,
};

/// Runs on the application's thread when the button is clicked, or
/// activated with Enter, Space, or a screen reader.
fn onClick(user_data: ?*anyopaque, _: siv.Node, event: *const siv.Event) callconv(.c) siv.EventResult {
    const counter: *Counter = @ptrCast(@alignCast(user_data));
    counter.clicks += 1;
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Clicked {d} time{s}", .{ counter.clicks, if (counter.clicks == 1) "" else "s" }) catch unreachable;
    const txn = siv.txnBegin(event.window) catch return .pass;
    siv.setText(txn, counter.label, label);
    siv.txnCommit(txn) catch {};
    return .handled;
}

fn build(window: siv.Window, counter: *Counter) !void {
    const txn = try siv.txnBegin(window);
    errdefer siv.txnAbort(txn);
    const root = siv.windowGetRoot(window);
    siv.setVisual(txn, root, .{ .background_token = .window_bg });
    const column = siv.flex(txn, root, .{ .axis = .column, .gap = 12, .align_items = .start });
    siv.setLayout(txn, column, .{ .padding = .{ .start = 24, .end = 24, .top = 24, .bottom = 24 } });

    const title = siv.text(txn, column, "Hello, siv");
    siv.setTextStyle(txn, title, .{ .size_role = .title, .weight = .bold, .color_token = .window_fg });
    siv.setSemantics(txn, title, .{ .role = .heading, .level = 1 });

    const label = "Click me";
    const button = siv.pushButton(txn, column, .{ .label = label, .style = .primary });
    siv.on(txn, button, .activate, onClick, null, counter);

    counter.label = siv.text(txn, column, "Not clicked yet");
    siv.setTextStyle(txn, counter.label, .{ .color_token = .window_fg });
    try siv.txnCommit(txn);
}

pub fn main() !void {
    const app = try siv.appCreate(null);
    defer siv.appDestroy(app);
    const title = "Hello";
    const window = try siv.windowCreate(app, .{ .title = title, .width = 320, .height = 160 });
    var counter: Counter = .{};
    try build(window, &counter);
    try siv.appRun(app);
}
