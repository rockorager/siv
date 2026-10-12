//! The public C API end to end on the headless backend (D24): the exports
//! called as a C program would, with input injected into the headless
//! platform, events delivered to C callbacks, and the presented frame
//! compared with PNGs under test/golden/abi/.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const text = @import("text");
const platform = @import("platform");
const compositor = @import("compositor");
const Loop = @import("loop").Loop;
const png = @import("../render/png.zig");

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const T = abi.tree;

const golden_dir = "test/golden/abi";
const failure_dir = ".zig-cache/golden-failures";

fn ok(r: t.Result) !void {
    if (r == .ok) return;
    std.debug.print("unexpected {s}\n", .{abi.siv_result_name(r)});
    return error.Unexpected;
}

const Harness = struct {
    app: t.App = .null,
    window: t.Window = .null,

    fn start(h: *Harness, width: u32, height: u32, on_event: ?t.WindowEventFn, user_data: ?*anyopaque) !void {
        try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true } }, &h.app));
        const tf = text.font.test_fonts;
        for ([_][]const u8{ tf.latin, tf.arabic, tf.hebrew }) |font| try ok(A.siv_app_add_font(h.app, "Droid", 5, font.ptr, font.len));
        try ok(A.siv_app_set_default_font(h.app, "Droid", 5));
        try ok(A.siv_window_create(h.app, &.{ .width = width, .height = height, .on_event = on_event, .user_data = user_data }, &h.window));
    }

    fn stop(h: *Harness) void {
        _ = A.siv_app_destroy(h.app);
    }

    fn internal(h: *Harness) !*A.App {
        return A.App.get(@backingInt(h.app));
    }

    fn win(h: *Harness) !*A.Window {
        return A.App.window(@backingInt(h.window), A.window_tag);
    }

    /// Dispatches until every commit is presented and nothing is pending.
    fn settle(h: *Harness) !void {
        const self = try h.internal();
        const w = try h.win();
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        var idle: usize = 0;
        while (idle < 3) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(h.app, 2));
            const busy = w.win.presented_seq == 0 or !w.win.settled() or self.app.fonts.loading();
            idle = if (busy) 0 else idle + 1;
        }
    }

    /// Injects platform events as the compositor would receive them.
    fn inject(h: *Harness, events: []const platform.Event) !void {
        const self = try h.internal();
        const Ctx = struct {
            events: []const platform.Event,
            fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                for (c.events) |ev| comp.platform.headless.inject(ev);
            }
        };
        var ctx: Ctx = .{ .events = events };
        try self.app.comp.call(&ctx, Ctx.run);
    }

    fn click(h: *Harness, x: f64, y: f64) !void {
        const id = (try h.win()).win.id;
        try h.inject(&.{
            .{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } },
        });
    }

    fn typeKey(h: *Harness, keysym: u32, chars: []const u8, mods: platform.Mods) !void {
        const id = (try h.win()).win.id;
        var k: platform.Key = .{ .window = id, .seat = 0, .keycode = 0, .keysym = keysym, .state = .pressed, .mods = mods, .time = 0, .serial = 3 };
        @memcpy(k.text_buf[0..chars.len], chars);
        k.text_len = @intCast(chars.len);
        var up = k;
        up.state = .released;
        up.text_len = 0;
        try h.inject(&.{ .{ .key = k }, .{ .key = up } });
    }

    fn capture(h: *Harness) ![]u8 {
        const self = try h.internal();
        const Ctx = struct {
            id: platform.WindowId,
            out: anyerror![]u8 = error.NothingPresented,
            fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                const img = comp.platform.headless.presented(c.id) orelse return;
                const out = testing.allocator.alloc(u8, @as(usize, img.width) * img.height * 4) catch |e| {
                    c.out = e;
                    return;
                };
                for (0..img.height) |y| for (0..img.width) |x| {
                    const p = img.pixels[y * img.stride + x * 4 ..][0..4];
                    out[(y * img.width + x) * 4 ..][0..4].* = .{ p[2], p[1], p[0], p[3] };
                };
                c.out = out;
            }
        };
        var ctx: Ctx = .{ .id = (try h.win()).win.id };
        try self.app.comp.call(&ctx, Ctx.run);
        return ctx.out;
    }

    fn expectGolden(h: *Harness, name: []const u8, width: u32, height: u32) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        const got = try h.capture();
        defer gpa.free(got);
        try testing.expectEqual(@as(usize, width) * height * 4, got.len);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ golden_dir, name });
        defer gpa.free(path);
        if (testing.environ.getPosix("SIV_UPDATE_GOLDEN") != null) {
            const bytes = try png.encode(gpa, width, height, got);
            defer gpa.free(bytes);
            try std.Io.Dir.cwd().createDirPath(io, golden_dir);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            return;
        }
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
        defer gpa.free(bytes);
        const want = try png.decode(gpa, bytes);
        defer want.deinit(gpa);
        try testing.expectEqual(width, want.width);
        try testing.expectEqual(height, want.height);
        // Every channel within 3, at most 0.5% of pixels off by more than 1.
        var worst: u8 = 0;
        var off: usize = 0;
        for (want.pixels, got) |a, b| {
            const d = if (a > b) a - b else b - a;
            worst = @max(worst, d);
            if (d > 1) off += 1;
        }
        if (worst <= 3 and off * 200 <= got.len / 4) return;
        std.debug.print("golden {s}: max channel difference {d}, {d} channels off by more than 1\n", .{ name, worst, off });
        try std.Io.Dir.cwd().createDirPath(io, failure_dir);
        const actual = try png.encode(gpa, width, height, got);
        defer gpa.free(actual);
        const out = try std.fmt.allocPrint(gpa, "{s}/abi-{s}-actual.png", .{ failure_dir, name });
        defer gpa.free(out);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = actual });
        return error.GoldenMismatch;
    }
};

fn srgb8(r: u8, g: u8, b: u8) t.Color {
    return .{ .r = @as(f32, @floatFromInt(r)) / 255, .g = @as(f32, @floatFromInt(g)) / 255, .b = @as(f32, @floatFromInt(b)) / 255, .a = 1 };
}

const ink = srgb8(0x18, 0x18, 0x1b);
const blue = srgb8(0x25, 0x63, 0xeb);
const panel = srgb8(0xf4, 0xf4, 0xf5);
const border = srgb8(0xa1, 0xa1, 0xaa);

/// What the C callbacks saw.
const Log = struct {
    clicks: u32 = 0,
    label: t.Node = .null,
    changes: u32 = 0,
    last_text: [64]u8 = undefined,
    last_len: usize = 0,
    caret: u32 = 0,
    focus_gained: u32 = 0,
    focus_lost: u32 = 0,
    keys: u32 = 0,
    scroll_dy: f32 = 0,
    pointer_downs: u32 = 0,
    down_x: f32 = 0,
    closes: u32 = 0,
    keep_open: bool = true,
    destroyed: u32 = 0,

    /// Counts the click and relabels the button from inside the callback.
    fn onActivate(user_data: ?*anyopaque, _: t.Node, event: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.clicks += 1;
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Count: {d}", .{log.clicks}) catch unreachable;
        var txn: t.Txn = .null;
        if (T.siv_txn_begin(event.?.window, &txn) != .ok) return false;
        _ = T.siv_set_text(txn, log.label, label.ptr, label.len);
        return T.siv_txn_commit(txn) == .ok;
    }

    fn onChange(user_data: ?*anyopaque, _: t.Node, event: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        const e = event.?;
        std.debug.assert(e.type == .change);
        log.changes += 1;
        log.last_len = e.text_len;
        @memcpy(log.last_text[0..e.text_len], e.text.?[0..e.text_len]);
        log.caret = e.caret;
        return true;
    }

    fn onFocus(user_data: ?*anyopaque, _: t.Node, event: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        if (event.?.flags.gained) log.focus_gained += 1 else log.focus_lost += 1;
        return false;
    }

    fn onKey(user_data: ?*anyopaque, _: t.Node, event: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        if (event.?.flags.pressed) log.keys += 1;
        return false;
    }

    fn onScroll(user_data: ?*anyopaque, _: t.Node, event: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.scroll_dy += event.?.dy;
        return true;
    }

    fn onPointer(user_data: ?*anyopaque, _: t.Node, event: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        const e = event.?;
        if (e.phase == .down) {
            log.pointer_downs += 1;
            log.down_x = e.x;
        }
        return false;
    }

    fn onWindow(user_data: ?*anyopaque, _: t.Window, event: ?*const t.WindowEvent) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(user_data));
        if (event.?.type == .close_requested) log.closes += 1;
        return log.keep_open;
    }

    fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
        const log: *Log = @ptrCast(@alignCast(user_data));
        log.destroyed += 1;
    }
};

const Form = struct { button: t.Node, editor: t.Node, check: t.Node, wheel: t.Node };

/// A small form built only through the exports: a heading, a button that
/// counts clicks, an editor, a checkbox row, a grid, and a wheel target.
fn buildForm(h: *Harness, log: *Log) !Form {
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const root = A.siv_window_root(h.window);
    _ = T.siv_set_visual(txn, root, &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    const column = T.siv_flex(txn, root, &.{ .axis = .column, .gap = 8 });
    _ = T.siv_set_layout(txn, column, &.{ .padding = .{ .start = 12, .end = 12, .top = 12, .bottom = 12 } });
    _ = T.siv_set_visual(txn, column, &.{ .background = panel });

    const title = T.siv_text(txn, column, "Settings".ptr, 8);
    _ = T.siv_set_text_style(txn, title, &.{ .font_size = 18, .color = ink });
    _ = T.siv_set_semantics(txn, title, &.{ .role = .heading });

    const row = T.siv_flex(txn, column, &.{ .gap = 8, .align_items = .center });
    const name = T.siv_text(txn, row, "Clicks".ptr, 6);
    _ = T.siv_set_text_style(txn, name, &.{ .color = ink });
    _ = T.siv_set_layout(txn, name, &.{ .grow = 1 });
    const button = T.siv_box(txn, row);
    _ = T.siv_set_layout(txn, button, &.{ .padding = .{ .start = 10, .end = 10, .top = 4, .bottom = 4 } });
    _ = T.siv_set_visual(txn, button, &.{ .background = blue, .radius = .{ .top_start = 6, .top_end = 6, .bottom_end = 6, .bottom_start = 6 } });
    _ = T.siv_set_semantics(txn, button, &.{ .role = .button, .flags = .{ .focusable = true } });
    log.label = T.siv_text(txn, button, "Count: 0".ptr, 8);
    _ = T.siv_set_text_style(txn, log.label, &.{ .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
    _ = T.siv_on(txn, button, .activate, Log.onActivate, null, log);
    _ = T.siv_on(txn, button, .focus, Log.onFocus, null, log);

    const editor = T.siv_editor(txn, column, .{});
    _ = T.siv_set_layout(txn, editor, &.{ .padding = .{ .start = 4, .end = 4, .top = 2, .bottom = 2 } });
    _ = T.siv_set_visual(txn, editor, &.{ .background = .{ .r = 1, .g = 1, .b = 1, .a = 1 }, .border_color = border, .border_width = 1 });
    _ = T.siv_set_text_style(txn, editor, &.{ .color = ink });
    _ = T.siv_on(txn, editor, .change, Log.onChange, Log.onDestroy, log);
    _ = T.siv_on(txn, editor, .focus, Log.onFocus, null, log);
    _ = T.siv_on(txn, editor, .key, Log.onKey, null, log);

    const check_row = T.siv_flex(txn, column, &.{ .gap = 6, .align_items = .center });
    const check = T.siv_box(txn, check_row);
    _ = T.siv_set_layout(txn, check, &.{ .width = .{ .unit = .px, .value = 14 }, .height = .{ .unit = .px, .value = 14 } });
    _ = T.siv_set_visual(txn, check, &.{ .border_color = border, .border_width = 2, .radius = .{ .top_start = 3, .top_end = 3, .bottom_end = 3, .bottom_start = 3 } });
    _ = T.siv_set_semantics(txn, check, &.{ .role = .checkbox, .checked = .on, .label = "Notify".ptr, .label_len = 6, .flags = .{ .focusable = true } });
    _ = T.siv_on(txn, check, .pointer, Log.onPointer, null, log);
    const notify = T.siv_text(txn, check_row, "Notify me".ptr, 9);
    _ = T.siv_set_text_style(txn, notify, &.{ .color = ink, .font_size = 13 });

    const tracks = [_]t.Track{ .{ .unit = .px, .value = 30 }, .{ .unit = .fr, .value = 1 }, .{ .unit = .fr, .value = 2 } };
    const grid = T.siv_grid(txn, column, &.{ .columns = &tracks, .columns_count = tracks.len, .column_gap = 4 });
    for ([_]t.Color{ blue, border, ink }) |c| {
        const cell = T.siv_box(txn, grid);
        _ = T.siv_set_layout(txn, cell, &.{ .height = .{ .unit = .px, .value = 10 } });
        _ = T.siv_set_visual(txn, cell, &.{ .background = c, .radius = .{ .top_start = 3, .top_end = 3, .bottom_end = 3, .bottom_start = 3 } });
    }
    const wheel = T.siv_box(txn, column);
    _ = T.siv_set_layout(txn, wheel, &.{ .height = .{ .unit = .px, .value = 12 } });
    _ = T.siv_on(txn, wheel, .scroll, Log.onScroll, null, log);
    try ok(T.siv_txn_status(txn));
    try ok(T.siv_txn_commit(txn));
    return .{ .button = button, .editor = editor, .check = check, .wheel = wheel };
}

fn center(node: t.Node) !struct { f64, f64 } {
    var r: t.Rect = undefined;
    try ok(T.siv_node_get_rect(node, &r));
    return .{ r.x + r.width / 2, r.y + r.height / 2 };
}

test "C API: a form built through the exports renders, and input reaches C callbacks" {
    var log: Log = .{};
    var h: Harness = .{};
    try h.start(240, 190, Log.onWindow, &log);
    defer h.stop();
    const form = try buildForm(&h, &log);
    try h.settle();
    try h.expectGolden("form", 240, 190);

    // A click activates the button; its callback commits a transaction.
    const bx, const by = try center(form.button);
    try h.click(bx, by);
    try h.settle();
    try testing.expectEqual(1, log.clicks);
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    try ok(T.siv_node_get_text(log.label, &buf, buf.len, &len));
    try testing.expectEqualStrings("Count: 1", buf[0..len]);
    const w = try h.win();
    try testing.expect(w.win.ui.semantics.find(.button, "Count: 1") != null);
    try testing.expect(w.win.ui.semantics.find(.checkbox, "Notify") != null);
    try testing.expect(w.win.ui.semantics.find(.heading, "Settings") != null);

    // Pointer events carry node coordinates.
    const cx, const cy = try center(form.check);
    try h.click(cx, cy);
    try h.settle();
    try testing.expectEqual(1, log.pointer_downs);
    try testing.expectApproxEqAbs(@as(f32, 7), log.down_x, 0.01);

    // Typing into the focused editor sends key and change events.
    const ex, const ey = try center(form.editor);
    try h.click(ex, ey);
    try h.typeKey('h', "h", .{});
    try h.typeKey('i', "i", .{});
    try h.settle();
    try testing.expectEqual(2, log.changes);
    try testing.expectEqualStrings("hi", log.last_text[0..log.last_len]);
    try testing.expectEqual(2, log.caret);
    try testing.expectEqual(2, log.keys);
    try ok(T.siv_node_get_text(form.editor, &buf, buf.len, &len));
    try testing.expectEqualStrings("hi", buf[0..len]);
    try h.expectGolden("form-typed", 240, 190);

    // Tab moves focus from the editor to the checkbox; the editor hears.
    const lost = log.focus_lost;
    try h.typeKey(0xff09, "", .{});
    try h.settle();
    try testing.expectEqual(lost + 1, log.focus_lost);

    // Scroll input over a node with a scroll handler reaches it.
    const wx, const wy = try center(form.wheel);
    const id = w.win.id;
    try h.inject(&.{
        .{ .pointer_motion = .{ .window = id, .seat = 0, .x = wx, .y = wy } },
        .{ .scroll = .{ .window = id, .seat = 0, .dy = 15, .source = .finger } },
    });
    try h.settle();
    try testing.expectEqual(@as(f32, 15), log.scroll_dy);

    // A handled close request keeps the window; an unhandled one destroys
    // it, which releases its handlers, and siv_run returns.
    const Close = struct {
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            comp.platform.headless.requestClose(@as(*platform.WindowId, @ptrCast(@alignCast(ctx))).*);
        }
    };
    var wid = id;
    const self = try h.internal();
    try self.app.comp.call(&wid, Close.run);
    try h.settle();
    try testing.expectEqual(1, log.closes);
    log.keep_open = false;
    try self.app.comp.call(&wid, Close.run);
    try ok(A.siv_run(h.app));
    try testing.expectEqual(2, log.closes);
    try testing.expectEqual(1, log.destroyed);
    try testing.expectEqual(t.Result.error_invalid_handle, A.siv_window_destroy(h.window));
}

test "C API: destroying the window from its own handler defers releases until the handler returns" {
    const Ctx = struct {
        h: *Harness,
        released_during: bool = false,
        released: u32 = 0,
        running: bool = false,

        fn onActivate(user_data: ?*anyopaque, _: t.Node, _: ?*const t.Event) callconv(.c) bool {
            const c: *@This() = @ptrCast(@alignCast(user_data));
            c.running = true;
            defer c.running = false;
            _ = A.siv_window_destroy(c.h.window);
            return false;
        }

        fn onDestroy(user_data: ?*anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(user_data));
            if (c.running) c.released_during = true;
            c.released += 1;
        }
    };
    var h: Harness = .{};
    try h.start(80, 60, null, null);
    defer h.stop();
    var ctx: Ctx = .{ .h = &h };
    var txn: t.Txn = .null;
    try ok(T.siv_txn_begin(h.window, &txn));
    const root = A.siv_window_root(h.window);
    const outer = T.siv_box(txn, root);
    const inner = T.siv_box(txn, outer);
    _ = T.siv_set_layout(txn, inner, &.{ .height = .{ .unit = .px, .value = 30 } });
    _ = T.siv_on(txn, inner, .activate, Ctx.onActivate, Ctx.onDestroy, &ctx);
    // The event bubbles on to a handler of the destroyed window: skipped.
    _ = T.siv_on(txn, outer, .activate, Ctx.onActivate, Ctx.onDestroy, &ctx);
    try ok(T.siv_txn_commit(txn));
    try h.settle();
    try h.click(10, 10);
    try ok(A.siv_run(h.app));
    try testing.expect(!ctx.released_during);
    try testing.expectEqual(2, ctx.released);
}

test "C API: siv_post races siv_app_destroy without losing a destroy-notify" {
    const Counts = struct {
        posted: std.atomic.Value(u32) = .init(0),
        released: std.atomic.Value(u32) = .init(0),
        fn run(_: ?*anyopaque) callconv(.c) void {}
        fn destroy(user_data: ?*anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(user_data));
            _ = c.released.fetchAdd(1, .seq_cst);
        }
    };
    const Poster = struct {
        fn post(app: t.App, c: *Counts, stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.seq_cst)) {
                switch (A.siv_post(app, Counts.run, Counts.destroy, c)) {
                    .ok => _ = c.posted.fetchAdd(1, .seq_cst),
                    .error_invalid_handle => return,
                    else => unreachable,
                }
            }
        }
    };
    for (0..20) |_| {
        var counts: Counts = .{};
        var stop: std.atomic.Value(bool) = .init(false);
        var app: t.App = .null;
        try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true } }, &app));
        var threads: [3]std.Thread = undefined;
        for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Poster.post, .{ app, &counts, &stop });
        try ok(A.siv_app_dispatch(app, 0));
        try ok(A.siv_app_destroy(app));
        stop.store(true, .seq_cst);
        for (threads) |th| th.join();
        // Every successful post was released exactly once: run and then
        // destroyed, or destroyed with the application.
        try testing.expectEqual(counts.posted.load(.seq_cst), counts.released.load(.seq_cst));
    }
}
