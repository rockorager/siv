//! A custom widget on a canvas, in Zig: a bar chart that sizes itself to
//! its width, draws in the theme's colors, highlights the bar under the
//! pointer, and describes its data to assistive technology. Redrawing it
//! repaints the canvas alone.
//!
//!     zig build guide && ./zig-out/bin/guide-chart-zig

const std = @import("std");
const siv = @import("siv");

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" };
const sales = [_]f32{ 12, 19, 7, 15, 22, 18 };
const top: f32 = 25;

const Chart = struct {
    window: siv.Window,
    canvas: siv.Node = .null,
    hovered: ?usize = null,
    /// Where the bars are, from the last draw, for hit testing.
    bar_width: f32 = 0,
    gap: f32 = 0,
};

/// Asked for the preferred width with an unbounded maximum, then with the
/// final constraints: wide charts are half as tall as they are wide.
fn measure(_: ?*anyopaque, _: siv.Node, constraints: *const siv.Constraints) callconv(.c) siv.Size {
    const c = constraints;
    const width = if (std.math.isInf(c.max_width)) 360 else c.max_width;
    return .{ .width = width, .height = std.math.clamp(width / 2, 140, 320) };
}

fn draw(user_data: ?*anyopaque, _: siv.Node, d: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const chart: *Chart = @ptrCast(@alignCast(user_data));
    drawChart(chart, d, width, height) catch {};
}

fn drawChart(chart: *Chart, d: siv.Draw, width: f32, height: f32) !void {
    // Themed colors as the window resolves them now; the canvas is drawn
    // again when the theme changes.
    const grid = try siv.windowGetColor(chart.window, .separator);
    const bar = try siv.windowGetColor(chart.window, .accent);
    const hot = try siv.windowGetColor(chart.window, .accent_hover);
    const muted = try siv.windowGetColor(chart.window, .muted_fg);
    const ink = try siv.windowGetColor(chart.window, .window_fg);

    const label_h: f32 = 22;
    const plot_h = height - label_h;
    // Grid lines every 5 units.
    var v: f32 = 0;
    while (v <= top) : (v += 5) {
        const y = @round(plot_h - v / top * (plot_h - 8)) + 0.5;
        siv.drawMoveTo(d, 0, y);
        siv.drawLineTo(d, width, y);
    }
    siv.drawStroke(d, .{ .width = 1 }, .{ .color = grid });

    chart.gap = 12;
    chart.bar_width = (width - chart.gap * (sales.len - 1)) / sales.len;
    for (sales, months, 0..) |value, month, i| {
        const x = @as(f32, @floatFromInt(i)) * (chart.bar_width + chart.gap);
        const h = value / top * (plot_h - 8);
        const is_hot = chart.hovered == i;
        siv.drawRoundedRect(d, .{ .x = x, .y = plot_h - h, .width = chart.bar_width, .height = h }, .{ .top_left = 4, .top_right = 4 });
        siv.drawFill(d, .{ .color = if (is_hot) hot else bar }, .{});
        siv.drawText(d, x, plot_h + 4, chart.bar_width, month, .{ .size_role = .caption, .color = muted, .@"align" = .center });
        if (is_hot) {
            var buf: [16]u8 = undefined;
            const label = try std.fmt.bufPrint(&buf, "{d}", .{value});
            siv.drawText(d, x, plot_h - h - 20, chart.bar_width, label, .{ .weight = .semibold, .color = ink, .@"align" = .center });
        }
    }
}

/// The bar under the pointer, highlighted. Only a change redraws.
fn onPointer(user_data: ?*anyopaque, _: siv.Node, event: *const siv.Event) callconv(.c) siv.EventResult {
    const chart: *Chart = @ptrCast(@alignCast(user_data));
    const e = event;
    var hovered: ?usize = null;
    if (e.phase != .leave and chart.bar_width > 0) {
        const i: usize = @intFromFloat(@max(0, e.x / (chart.bar_width + chart.gap)));
        if (i < sales.len) hovered = i;
    }
    if (hovered == chart.hovered) return .pass;
    chart.hovered = hovered;
    const txn = siv.txnBegin(e.window) catch return .pass;
    siv.invalidate(txn, chart.canvas);
    siv.txnCommit(txn) catch {};
    return .pass;
}

fn build(chart: *Chart) !void {
    const txn = try siv.txnBegin(chart.window);
    errdefer siv.txnAbort(txn);
    const root = siv.windowGetRoot(chart.window);
    siv.setVisual(txn, root, .{ .background_token = .window_bg });
    const column = siv.flex(txn, root, .{ .axis = .column, .gap = 12 });
    siv.setLayout(txn, column, .{ .width = .{ .unit = .fraction, .value = 1 }, .padding = .{ .start = 20, .end = 20, .top = 16, .bottom = 16 } });
    const title = siv.text(txn, column, "Sales, first half");
    siv.setTextStyle(txn, title, .{ .size_role = .heading, .weight = .bold, .color_token = .window_fg });

    chart.canvas = siv.canvas(txn, column, .{ .user_data = chart, .draw = draw, .measure = measure });
    // A canvas is an image to assistive technology unless told more: name
    // it and give the data in words.
    const name = "Sales by month";
    const description = "January 12, February 19, March 7, April 15, May 22, June 18";
    siv.setSemantics(txn, chart.canvas, .{ .role = .image, .label = name, .description = description });
    siv.on(txn, chart.canvas, .pointer, onPointer, null, chart);
    try siv.txnCommit(txn);
}

pub fn main() !void {
    const app = try siv.appCreate(null);
    defer siv.appDestroy(app);
    const title = "Chart";
    const window = try siv.windowCreate(app, .{ .title = title, .width = 420, .height = 280 });
    var chart: Chart = .{ .window = window };
    try build(&chart);
    try siv.appRun(app);
}
