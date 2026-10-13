//! Stock widgets and theming, in Zig: a settings form whose widgets report
//! changes through `change` handlers, a dark-theme switch, an accent color
//! of the application's own, and a toast.
//!
//!     zig build guide && ./zig-out/bin/guide-settings-zig

const std = @import("std");
const siv = @import("siv");

const Form = struct {
    app: siv.App,
    root: siv.Node = .null,
    volume_label: siv.Node = .null,
    level: siv.Node = .null,
};

fn handler(comptime f: fn (*Form, *const siv.Event) anyerror!void) siv.EventFn {
    return struct {
        fn call(user_data: ?*anyopaque, _: siv.Node, event: ?*const siv.Event) callconv(.c) siv.EventResult {
            f(@ptrCast(@alignCast(user_data)), event.?) catch return .pass;
            return .handled;
        }
    }.call;
}

/// The switch's value is 0 or 1. The theme follows the desktop unless the
/// application chooses; choosing repaints every window.
fn onDarkTheme(form: *Form, event: *const siv.Event) !void {
    try siv.appSetTheme(form.app, &.{ .scheme = if (event.value != 0) .dark else .follow });
}

/// A slider reports its new value; setting another widget's value from the
/// application reports nothing.
fn onVolume(form: *Form, event: *const siv.Event) !void {
    var buf: [32]u8 = undefined;
    const label = try std.fmt.bufPrint(&buf, "Volume: {d:.0}", .{event.value});
    const txn = try siv.txnBegin(event.window);
    errdefer siv.txnAbort(txn);
    siv.setText(txn, form.volume_label, label);
    siv.widgetSetValue(txn, form.level, event.value);
    try siv.txnCommit(txn);
}

fn onSave(form: *Form, event: *const siv.Event) !void {
    const message = "Settings saved";
    const txn = try siv.txnBegin(event.window);
    errdefer siv.txnAbort(txn);
    _ = siv.toast(txn, form.root, &.{ .text = message, .text_len = message.len });
    try siv.txnCommit(txn);
}

fn caption(txn: siv.Txn, parent: siv.Node, s: []const u8) !siv.Node {
    const node = siv.text(txn, parent, s);
    siv.setTextStyle(txn, node, &.{ .size_role = .caption, .color_token = .muted_fg });
    return node;
}

fn build(window: siv.Window, form: *Form) !void {
    const txn = try siv.txnBegin(window);
    errdefer siv.txnAbort(txn);
    form.root = siv.windowRoot(window);
    siv.setVisual(txn, form.root, &.{ .background_token = .window_bg });
    const column = siv.flex(txn, form.root, &.{ .axis = .column, .gap = 12, .align_items = .start });
    siv.setLayout(txn, column, &.{ .padding = .{ .start = 24, .end = 24, .top = 20, .bottom = 20 } });

    const title = siv.text(txn, column, "Settings");
    siv.setTextStyle(txn, title, &.{ .size_role = .title, .weight = .bold, .color_token = .window_fg });
    siv.setSemantics(txn, title, &.{ .role = .heading, .level = 1 });

    const name_hint = "Display name";
    const name = siv.textField(txn, column, &.{ .placeholder = name_hint, .placeholder_len = name_hint.len });
    siv.setLayout(txn, name, &.{ .width = .{ .unit = .px, .value = 260 } });

    const dark_label = "Dark theme";
    const dark = siv.@"switch"(txn, column, &.{ .label = dark_label, .label_len = dark_label.len });
    siv.on(txn, dark, .change, handler(onDarkTheme), null, form);
    const stats_label = "Send usage statistics";
    _ = siv.checkBox(txn, column, &.{ .label = stats_label, .label_len = stats_label.len, .checked = .on });

    // Choices are built item by item; the group's value is the index.
    const channel_label = "Update channel";
    _ = try caption(txn, column, channel_label);
    const channel = siv.radioGroup(txn, column, &.{ .label = channel_label, .label_len = channel_label.len });
    for ([_][]const u8{ "Stable", "Beta", "Nightly" }) |option| {
        _ = siv.radio(txn, channel, &.{ .label = option.ptr, .label_len = option.len });
    }

    form.volume_label = try caption(txn, column, "Volume: 40");
    const volume_label = "Volume";
    const volume = siv.slider(txn, column, &.{ .label = volume_label, .label_len = volume_label.len, .value = 40, .step = 1 });
    siv.setLayout(txn, volume, &.{ .width = .{ .unit = .px, .value = 260 } });
    siv.on(txn, volume, .change, handler(onVolume), null, form);
    const level_label = "Level";
    form.level = siv.progressBar(txn, column, &.{ .label = level_label, .label_len = level_label.len, .value = 40 });
    siv.setLayout(txn, form.level, &.{ .width = .{ .unit = .px, .value = 260 } });

    const copies_label = "Copies";
    _ = siv.spinButton(txn, column, &.{ .label = copies_label, .label_len = copies_label.len, .min = 1, .max = 10, .value = 2 });

    const buttons = siv.flex(txn, column, &.{ .gap = 8 });
    const cancel_label = "Cancel";
    _ = siv.pushButton(txn, buttons, &.{ .label = cancel_label, .label_len = cancel_label.len });
    const save_label = "Save";
    const save = siv.pushButton(txn, buttons, &.{ .label = save_label, .label_len = save_label.len, .style = .primary });
    siv.on(txn, save, .activate, handler(onSave), null, form);
    try siv.txnCommit(txn);
}

pub fn main() !void {
    const app = try siv.appCreate(null);
    defer siv.appDestroy(app);
    // The application's own accent, in every variant of the theme. Hover
    // and pressed shades, focus rings, and selections follow it.
    try siv.appSetThemeColor(app, .all, .accent, .{ .r = 0.49, .g = 0.23, .b = 0.93, .a = 1 });
    const title = "Settings";
    const window = try siv.windowCreate(app, &.{ .title = title, .title_len = title.len, .width = 420, .height = 460 });
    var form: Form = .{ .app = app };
    try build(window, &form);
    try siv.appRun(app);
}
