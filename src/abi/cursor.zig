//! Exports for pointer cursors (D16): per-node cursors, a window-wide
//! override for busy states, and what client-side decorations need
//! (D17): interactive moves and resizes, the window menu, close
//! requests, and the controls to draw.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const platform = @import("platform");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;

/// Null for auto.
fn shapeOf(c: t.Cursor) Error!?ui.CursorShape {
    const v = @backingInt(try runtime.enumValue(t.Cursor, c));
    if (v == 0) return null;
    if (c == .hidden) return .hidden;
    // The CSS shapes are numbered as in cursor-shape-v1, like CursorShape.
    return @enumFromInt(v);
}

pub export fn siv_set_cursor(txn: t.Txn, node: t.Node, cursor: t.Cursor) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, c: t.Cursor) Error!void {
            const id = try tree.nodeIn(w, n);
            w.txn.ut.setCursor(id, try shapeOf(c)) catch |err| return tree.mapTxn(err);
        }
    }.f, .{ node, cursor });
}

fn windowOf(window: t.Window) Error!*Window {
    const w = try App.window(@backingInt(window), application.window_tag);
    if (w.dead) return error.InvalidHandle;
    return w;
}

pub export fn siv_window_set_cursor(window: t.Window, cursor: t.Cursor) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window, c: t.Cursor) Error!void {
            const w = try windowOf(wh);
            w.uiWin().setCursorOverride(try shapeOf(c));
        }
    }.f(window, cursor));
}

pub export fn siv_window_begin_move(window: t.Window) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window) Error!void {
            try (try windowOf(wh)).win.beginMove();
        }
    }.f(window));
}

pub export fn siv_window_begin_resize(window: t.Window, edge: t.WindowEdge) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window, e: t.WindowEdge) Error!void {
            const w = try windowOf(wh);
            const pe: platform.Edge = switch (try runtime.enumValue(t.WindowEdge, e)) {
                .none => return error.InvalidArgument,
                .top => .top,
                .bottom => .bottom,
                .left => .left,
                .top_left => .top_left,
                .bottom_left => .bottom_left,
                .right => .right,
                .top_right => .top_right,
                .bottom_right => .bottom_right,
                _ => unreachable,
            };
            try w.win.beginResize(pe);
        }
    }.f(window, edge));
}

pub export fn siv_window_show_menu(window: t.Window, x: f64, y: f64) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window, x_: f64, y_: f64) Error!void {
            if (!std.math.isFinite(x_) or !std.math.isFinite(y_)) return error.InvalidArgument;
            const w = try windowOf(wh);
            const clamp = std.math.lossyCast;
            try w.win.showWindowMenu(clamp(i32, @floor(x_)), clamp(i32, @floor(y_)));
        }
    }.f(window, x, y));
}

pub export fn siv_window_request_close(window: t.Window) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window) Error!void {
            (try windowOf(wh)).win.requestClose();
        }
    }.f(window));
}

pub export fn siv_window_get_controls(window: t.Window, controls: ?*t.WindowControls) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window, out: ?*t.WindowControls) Error!void {
            const dest = try runtime.out(t.WindowControls, out);
            const c = (try windowOf(wh)).win.controls();
            dest.* = .{ .close = c.close, .minimize = c.minimize, .maximize = c.maximize, .menu = c.menu };
        }
    }.f(window, controls));
}

comptime {
    // C values 1 to 36 are the CSS shapes in CursorShape's order.
    for (std.enums.values(ui.CursorShape)) |s| {
        if (s == .hidden) continue;
        const name = @tagName(s);
        if (@backingInt(@field(t.Cursor, name)) != @intFromEnum(s)) @compileError("siv_cursor and CursorShape differ: " ++ name);
    }
}
