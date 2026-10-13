//! Exports for applications' own tests (D27, api_testing.zig): input
//! injected into the headless backend's simulated seat, waiting until the
//! application is idle, captures of what windows presented, and queries
//! of the semantics tree. The headless platform lives on the compositor
//! thread, so injection and captures run there through
//! `Compositor.call`; the semantics tree is the UI thread's.

const std = @import("std");
const t = @import("siv");
const platform = @import("platform");
const compositor = @import("compositor");
const ui = @import("ui");
const loop_mod = @import("loop");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const wrap = application.wrap;

/// Input serials and times, as a seat counts them.
var serial: std.atomic.Value(u32) = .init(1);

fn nextSerial() u32 {
    return serial.fetchAdd(1, .monotonic);
}

fn headlessApp(self: *App) Error!void {
    if (self.app.comp.platform != .headless) return error.Unsupported;
}

/// A window of the headless backend.
fn headlessWindow(handle: t.Window) Error!*Window {
    const w = try App.window(@backingInt(handle), application.window_tag);
    try headlessApp(w.owner);
    if (w.dead) return error.InvalidHandle;
    return w;
}

/// Runs `func(headless, ctx)` on the compositor thread and waits for it.
fn onHeadless(self: *App, ctx: anytype, comptime func: fn (*platform.Headless, @TypeOf(ctx)) void) Error!void {
    const C = struct {
        inner: @TypeOf(ctx),
        fn run(p: ?*anyopaque, comp: *compositor.Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(p));
            func(comp.platform.headless, s.inner);
        }
    };
    var cx: C = .{ .inner = ctx };
    try self.app.comp.call(&cx, C.run);
}

fn inject(w: *Window, events: []const platform.Event) Error!void {
    try onHeadless(w.owner, events, struct {
        fn f(hl: *platform.Headless, evs: []const platform.Event) void {
            for (evs) |ev| hl.inject(ev);
        }
    }.f);
}

fn buttonCode(b: t.PointerButton) Error!u32 {
    return switch (try runtime.enumValue(t.PointerButton, b)) {
        .primary => 0x110,
        .secondary => 0x111,
        .middle => 0x112,
        .other => 0x113,
        _ => unreachable,
    };
}

fn motion(w: *Window, x: f32, y: f32) platform.Event {
    return .{ .pointer_motion = .{ .window = w.win.id, .seat = 0, .x = x, .y = y, .time = nextSerial() } };
}

fn button(w: *Window, code: u32, pressed: bool) platform.Event {
    const s = nextSerial();
    return .{ .pointer_button = .{ .window = w.win.id, .seat = 0, .button = code, .pressed = pressed, .time = s, .serial = s } };
}

/// Whether nothing the application waits for is in flight.
fn idle(self: *App) bool {
    const app = self.app;
    if (app.fonts.loading() or app.icons.loading() or self.jobs != 0) return false;
    const cb = &app.clipboard;
    if (cb.transfers.items.len != 0 or cb.ready.items.len != 0) return false;
    for (self.image_requests.items) |r| if (r != null) return false;
    for (self.windows.items) |slot| if (slot) |w| {
        if (w.dead or !w.win.shown) continue;
        if (w.win.presented_seq == 0 or !w.win.settled()) return false;
    };
    return true;
}

/// Dispatches until idle for three dispatches in a row (a frame's events
/// can start more work), or until `timeout_ms` pass.
fn settle(self: *App, timeout_ms: u32) Error!bool {
    if (self.depth != 0) return error.Busy;
    const deadline = loop_mod.Loop.now() + @as(u64, timeout_ms) * std.time.ns_per_ms;
    var quiet: u32 = 0;
    while (quiet < 3) {
        if (loop_mod.Loop.now() > deadline) return false;
        // A destroyed window or a callback's error can end the
        // application's run; dispatching still works.
        self.app.dispatch(2) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Busy => error.Busy,
            error.Unavailable => error.Unavailable,
        };
        quiet = if (idle(self)) quiet + 1 else 0;
    }
    return true;
}

pub export fn siv_test_settle(app: t.App, timeout_ms: u32, settled: ?*bool) t.Result {
    return wrap(struct {
        fn f(a: t.App, ms: u32, out: ?*bool) Error!void {
            const self = try App.get(@backingInt(a));
            try headlessApp(self);
            const dest = try runtime.out(bool, out);
            dest.* = try settle(self, ms);
        }
    }.f(app, timeout_ms, settled));
}

pub export fn siv_test_pointer_move(window: t.Window, x: f32, y: f32) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, px: f32, py: f32) Error!void {
            const w = try headlessWindow(wh);
            try inject(w, &.{motion(w, px, py)});
        }
    }.f(window, x, y));
}

pub export fn siv_test_pointer_button(window: t.Window, pointer_button: t.PointerButton, pressed: bool) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, b: t.PointerButton, down: bool) Error!void {
            const w = try headlessWindow(wh);
            try inject(w, &.{button(w, try buttonCode(b), down)});
        }
    }.f(window, pointer_button, pressed));
}

pub export fn siv_test_click(window: t.Window, x: f32, y: f32, pointer_button: t.PointerButton) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, px: f32, py: f32, b: t.PointerButton) Error!void {
            const w = try headlessWindow(wh);
            const code = try buttonCode(b);
            try inject(w, &.{ motion(w, px, py), button(w, code, true), button(w, code, false) });
        }
    }.f(window, x, y, pointer_button));
}

pub export fn siv_test_scroll(window: t.Window, dx: f32, dy: f32) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, sx: f32, sy: f32) Error!void {
            const w = try headlessWindow(wh);
            if (!std.math.isFinite(sx) or !std.math.isFinite(sy)) return error.InvalidArgument;
            const detents = 120 / platform.Scroll.detent_px;
            try inject(w, &.{.{ .scroll = .{
                .window = w.win.id,
                .seat = 0,
                .time = nextSerial(),
                .dx = sx,
                .dy = sy,
                .v120_x = @intFromFloat(@round(@as(f64, sx) * detents)),
                .v120_y = @intFromFloat(@round(@as(f64, sy) * detents)),
                .source = .wheel,
            } }});
        }
    }.f(window, dx, dy));
}

fn keyEvents(w: *Window, keysym: u32, mods: platform.Mods, text: []const u8) Error![2]platform.Event {
    if (text.len > platform.Key.max_text) return error.InvalidArgument;
    const s = nextSerial();
    var down: platform.Key = .{ .window = w.win.id, .seat = 0, .keycode = 0, .keysym = keysym, .state = .pressed, .mods = mods, .time = s, .serial = s };
    @memcpy(down.text_buf[0..text.len], text);
    down.text_len = @intCast(text.len);
    var up = down;
    up.state = .released;
    up.text_len = 0;
    return .{ .{ .key = down }, .{ .key = up } };
}

pub export fn siv_test_key(window: t.Window, keysym: t.Key, modifiers: t.Modifiers, text: ?[*]const u8, text_len: usize) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, k: t.Key, m: t.Modifiers, p: ?[*]const u8, n: usize) Error!void {
            const w = try headlessWindow(wh);
            const fl = try runtime.flags(t.Modifiers, m);
            const s = try runtime.string(p, n);
            const mods: platform.Mods = .{ .shift = fl.shift, .ctrl = fl.ctrl, .alt = fl.alt, .super = fl.super, .caps_lock = fl.caps_lock, .num_lock = fl.num_lock };
            try inject(w, &try keyEvents(w, @bitCast(@backingInt(k)), mods, s));
        }
    }.f(window, keysym, modifiers, text, text_len));
}

pub export fn siv_test_type(window: t.Window, text: ?[*]const u8, text_len: usize) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, p: ?[*]const u8, n: usize) Error!void {
            const w = try headlessWindow(wh);
            const s = try runtime.string(p, n);
            const view = std.unicode.Utf8View.init(s) catch return error.InvalidArgument;
            var it = view.iterator();
            while (it.nextCodepointSlice()) |ch| {
                const cp = std.unicode.utf8Decode(ch) catch unreachable;
                const keysym: u32, const produced: []const u8 = switch (cp) {
                    '\n' => .{ 0xff0d, "\r" },
                    '\t' => .{ 0xff09, "\t" },
                    0x20...0x7e, 0xa0...0xff => .{ @as(u32, cp), ch },
                    else => .{ 0x0100_0000 + @as(u32, cp), ch },
                };
                try inject(w, &try keyEvents(w, keysym, .{}, produced));
            }
        }
    }.f(window, text, text_len));
}

pub export fn siv_test_close(window: t.Window) t.Result {
    return wrap(struct {
        fn f(wh: t.Window) Error!void {
            const w = try headlessWindow(wh);
            try inject(w, &.{.{ .close_requested = w.win.id }});
        }
    }.f(window));
}

pub export fn siv_test_drop(window: t.Window, x: f32, y: f32, mime_type: ?[*]const u8, mime_type_len: usize, data: ?[*]const u8, data_count: usize) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, px: f32, py: f32, mp: ?[*]const u8, mn: usize, dp: ?[*]const u8, dn: usize) Error!void {
            const w = try headlessWindow(wh);
            const D = struct {
                window: platform.WindowId,
                mimes: []const []const u8,
                data: []const u8,
                x: f64,
                y: f64,
                err: ?Error = null,
                fn offer(hl: *platform.Headless, d: *@This()) void {
                    hl.offerDrag(0, d.window, d.mimes, d.data, .{ .copy = true, .move = true }, d.x, d.y) catch |e| {
                        d.err = switch (e) {
                            error.OutOfMemory => error.OutOfMemory,
                            else => error.Unavailable,
                        };
                    };
                }
                fn drop(hl: *platform.Headless, _: *@This()) void {
                    hl.dropDrag(0);
                }
            };
            if (w.owner.depth != 0) return error.Busy;
            var d: D = .{ .window = w.win.id, .mimes = &.{try runtime.string(mp, mn)}, .data = try runtime.array(u8, dp, dn), .x = px, .y = py };
            if (d.mimes[0].len == 0) return error.InvalidArgument;
            try onHeadless(w.owner, &d, D.offer);
            if (d.err) |e| return e;
            // The drop goes where the application said it would take
            // the data, so it answers the offer first.
            _ = try settle(w.owner, 5000);
            try onHeadless(w.owner, &d, D.drop);
        }
    }.f(window, x, y, mime_type, mime_type_len, data, data_count));
}

pub export fn siv_test_capture(window: t.Window, pixels: ?[*]u8, pixels_cap: usize, len: ?*usize, width: ?*u32, height: ?*u32) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, p: ?[*]u8, cap: usize, out_len: ?*usize, out_w: ?*u32, out_h: ?*u32) Error!void {
            const w = try headlessWindow(wh);
            const C = struct {
                id: platform.WindowId,
                buf: []u8,
                presented: bool = false,
                width: u32 = 0,
                height: u32 = 0,
                fn run(hl: *platform.Headless, c: *@This()) void {
                    const img = hl.presented(c.id) orelse return;
                    c.presented = true;
                    c.width = img.width;
                    c.height = img.height;
                    // The headless buffers are wl_shm ARGB8888: B, G, R, A
                    // in memory.
                    var i: usize = 0;
                    outer: for (0..img.height) |y| for (0..img.width) |x| {
                        if (i + 4 > c.buf.len) break :outer;
                        const px = img.pixels[y * img.stride + x * 4 ..][0..4];
                        c.buf[i..][0..4].* = .{ px[2], px[1], px[0], px[3] };
                        i += 4;
                    };
                }
            };
            var c: C = .{ .id = w.win.id, .buf = try runtime.buffer(p, cap) };
            const dl = try runtime.out(usize, out_len);
            var sw: u32 = 0;
            var sh: u32 = 0;
            const dw = runtime.optOut(u32, out_w, &sw);
            const dh = runtime.optOut(u32, out_h, &sh);
            try onHeadless(w.owner, &c, C.run);
            if (!c.presented) return error.Unavailable;
            dl.* = @as(usize, c.width) * c.height * 4;
            dw.* = c.width;
            dh.* = c.height;
        }
    }.f(window, pixels, pixels_cap, len, width, height));
}

fn semanticsOf(w: *Window) Error!*const ui.semantics.Tree {
    return w.uiWin().semanticsTree() catch error.OutOfMemory;
}

fn toggle(v: ui.Toggle) t.Toggle {
    return switch (v) {
        .unset => .unset,
        .off => .off,
        .on => .on,
        .mixed => .mixed,
    };
}

fn describe(n: *const ui.semantics.Node) t.TestNode {
    const b = n.bounds;
    const v = n.value orelse ui.Range{ .min = 0, .max = 0, .now = 0 };
    return .{
        .bounds = .{ .x = b.x0, .y = b.y0, .width = b.x1 - b.x0, .height = b.y1 - b.y0 },
        .role = @fromBackingInt(@intFromEnum(n.role) + 1),
        .flags = .{ .focusable = n.focusable, .focused = n.focused, .disabled = n.disabled, .actionable = n.actionable, .has_value = n.value != null, .modal = n.modal },
        .checked = toggle(n.checked),
        .pressed = toggle(n.pressed),
        .selected = toggle(n.selected),
        .expanded = toggle(n.expanded),
        .value_min = v.min,
        .value_max = v.max,
        .value_now = v.now,
        .level = n.level,
        .position = n.position,
        .set_size = n.set_size,
        .row = n.row,
        .column = n.column,
        .sort = switch (n.sort) {
            .none => .none,
            .ascending => .ascending,
            .descending => .descending,
        },
    };
}

/// The node `q` matches, in tree order.
fn match(tree: *const ui.semantics.Tree, q_ptr: ?*const t.TestQuery) Error!?*const ui.semantics.Node {
    const q = try runtime.readDesc(t.TestQuery, q_ptr);
    const want = try runtime.string(q.name, q.name_len);
    const role = try runtime.enumValue(t.Role, q.role);
    const fl = try runtime.flags(t.TestQueryFlags, q.flags);
    var seen: u32 = 0;
    for (tree.nodes.items) |*n| {
        if (role != .default and @backingInt(role) != @intFromEnum(n.role) + 1) continue;
        if (fl.focused and !n.focused) continue;
        if (want.len != 0 and !std.mem.eql(u8, tree.name(n.*), want)) continue;
        if (seen == q.index) return n;
        seen += 1;
    }
    return null;
}

pub export fn siv_test_find(window: t.Window, query: ?*const t.TestQuery, found: ?*bool, node: ?*t.TestNode) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, q: ?*const t.TestQuery, out_found: ?*bool, out_node: ?*t.TestNode) Error!void {
            const w = try App.window(@backingInt(wh), application.window_tag);
            const df = try runtime.out(bool, out_found);
            var scratch: t.TestNode = .{};
            const dn = runtime.optOut(t.TestNode, out_node, &scratch);
            const n = try match(try semanticsOf(w), q);
            df.* = n != null;
            dn.* = if (n) |x| describe(x) else .{};
        }
    }.f(window, query, found, node));
}

pub export fn siv_test_get_name(window: t.Window, query: ?*const t.TestQuery, name: ?[*]u8, name_cap: usize, len: ?*usize) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, q: ?*const t.TestQuery, np: ?[*]u8, cap: usize, out_len: ?*usize) Error!void {
            const w = try App.window(@backingInt(wh), application.window_tag);
            const buf = try runtime.buffer(np, cap);
            const dl = try runtime.out(usize, out_len);
            const tree = try semanticsOf(w);
            const s = if (try match(tree, q)) |n| tree.name(n.*) else "";
            const k = @min(s.len, buf.len);
            @memcpy(buf[0..k], s[0..k]);
            dl.* = s.len;
        }
    }.f(window, query, name, name_cap, len));
}

fn writeToggle(wr: *std.Io.Writer, label: []const u8, v: ui.Toggle) !void {
    if (v != .unset) try wr.print(" {s}={t}", .{ label, v });
}

pub export fn siv_test_dump(window: t.Window, text: ?[*]u8, text_cap: usize, len: ?*usize) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, p: ?[*]u8, cap: usize, out_len: ?*usize) Error!void {
            const w = try App.window(@backingInt(wh), application.window_tag);
            const buf = try runtime.buffer(p, cap);
            const dl = try runtime.out(usize, out_len);
            const tree = try semanticsOf(w);
            var aw: std.Io.Writer.Allocating = .init(w.owner.gpa());
            defer aw.deinit();
            dump(&aw.writer, tree) catch return error.OutOfMemory;
            const s = aw.written();
            const k = @min(s.len, buf.len);
            @memcpy(buf[0..k], s[0..k]);
            dl.* = s.len;
        }
    }.f(window, text, text_cap, len));
}

fn dump(wr: *std.Io.Writer, tree: *const ui.semantics.Tree) !void {
    for (tree.nodes.items) |*n| {
        var depth: usize = 0;
        var parent = n.parent;
        while (parent != ui.semantics.none) : (parent = tree.nodes.items[parent].parent) depth += 1;
        try wr.splatByteAll(' ', depth * 2);
        try wr.print("{t} \"{s}\"", .{ n.role, tree.name(n.*) });
        if (n.focused) try wr.writeAll(" focused");
        if (n.disabled) try wr.writeAll(" disabled");
        try writeToggle(wr, "checked", n.checked);
        try writeToggle(wr, "pressed", n.pressed);
        try writeToggle(wr, "selected", n.selected);
        try writeToggle(wr, "expanded", n.expanded);
        if (n.value) |v| try wr.print(" value={d}", .{v.now});
        if (n.level != 0) try wr.print(" level={d}", .{n.level});
        const b = n.bounds;
        try wr.print(" {d},{d} {d}x{d}\n", .{ b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0 });
    }
}

pub export fn siv_test_get_popup(app: t.App) t.Window {
    const self = App.get(@backingInt(app)) catch return .null;
    // A popup opened from a popup (a submenu) is the newest of its chain:
    // the deepest, and of those the last created.
    var best: ?*Window = null;
    var best_depth: u32 = 0;
    for (self.windows.items) |slot| if (slot) |w| {
        if (w.dead or w.parent == null or !w.win.shown) continue;
        var depth: u32 = 0;
        var up = w.parent;
        while (up) |u| : (up = u.parent) depth += 1;
        if (depth >= best_depth) {
            best = w;
            best_depth = depth;
        }
    };
    return if (best) |w| @fromBackingInt(w.handle) else .null;
}
