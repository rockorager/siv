const std = @import("std");
const siv = @import("siv");

pub fn main() !void {
    const app = try siv.appCreate(null);
    defer siv.appDestroy(app) catch {};
    const title = "Hello";
    const window = try siv.windowCreate(app, &.{ .title = title, .title_len = title.len, .width = 320, .height = 120 });
    const txn = try siv.txnBegin(window);
    errdefer siv.txnAbort(txn) catch {};
    const root = siv.windowRoot(window);
    try siv.setVisual(txn, root, &.{ .background_token = .window_bg });
    const label = siv.text(txn, root, "Hello from a Zig package");
    try siv.setLayout(txn, label, &.{ .align_x = .center, .align_y = .center });
    try siv.setTextStyle(txn, label, &.{ .size_role = .heading, .color_token = .window_fg });
    try siv.txnCommit(txn);
    try siv.appRun(app);
}
