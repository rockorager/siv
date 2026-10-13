//! A headless application driven through the exports, as a C program
//! would, with the headless platform's input injection and frame capture
//! for tests (D24).

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

const golden_dir = "test/golden/abi";
const failure_dir = ".zig-cache/golden-failures";

pub fn ok(r: t.Result) !void {
    if (r == .ok) return;
    std.debug.print("unexpected {s}\n", .{abi.siv_result_name(r)});
    return error.Unexpected;
}

pub const Harness = struct {
    app: t.App = .null,
    window: t.Window = .null,
    /// Where golden images live.
    golden: []const u8 = golden_dir,
    /// Reduced motion: no caret blinking or animations to race the
    /// captures.
    reduced_motion: bool = true,

    pub fn start(h: *Harness, width: u32, height: u32, on_event: ?t.WindowEventFn, user_data: ?*anyopaque) !void {
        try h.startWith(.{ .width = width, .height = height, .on_event = on_event, .user_data = user_data });
    }

    pub fn startWith(h: *Harness, desc: t.WindowDesc) !void {
        try ok(A.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true, .no_system_icons = true, .reduced_motion = h.reduced_motion } }, &h.app));
        // siv's test icon themes (test/icons/themes), never the system's.
        try ok(abi.icon.siv_app_add_icon_path(h.app, "test/icons/themes", 17));
        try ok(abi.icon.siv_app_set_icon_theme(h.app, "SivTest", 7));
        const tf = text.font.test_fonts;
        for ([_][]const u8{ tf.latin, tf.arabic, tf.hebrew }) |font| try ok(A.siv_app_add_font(h.app, "Droid", 5, font.ptr, font.len));
        try ok(A.siv_app_set_default_font(h.app, "Droid", 5));
        try ok(A.siv_window_create(h.app, &desc, &h.window));
    }

    pub fn stop(h: *Harness) void {
        _ = A.siv_app_destroy(h.app);
    }

    pub fn internal(h: *Harness) !*A.App {
        return A.App.get(@backingInt(h.app));
    }

    pub fn win(h: *Harness) !*A.Window {
        return A.App.window(@backingInt(h.window), A.window_tag);
    }

    /// Dispatches until every commit is presented and nothing is pending.
    /// Every shown window (popups too) has presented what it committed,
    /// and no paste or drop is still being read.
    pub fn settle(h: *Harness) !void {
        const self = try h.internal();
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        var idle: usize = 0;
        while (idle < 3) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(h.app, 2));
            // Pastes and drops read on the UI thread from data another
            // thread writes.
            const cb = &self.app.clipboard;
            var busy = self.app.fonts.loading() or self.app.icons.loading() or cb.transfers.items.len != 0 or cb.ready.items.len != 0;
            for (self.windows.items) |slot| if (slot) |w| {
                if (w.dead or !w.win.shown) continue;
                busy = busy or w.win.presented_seq == 0 or !w.win.settled();
            };
            idle = if (busy) 0 else idle + 1;
        }
    }

    /// Injects platform events as the compositor would receive them.
    pub fn inject(h: *Harness, events: []const platform.Event) !void {
        const self = try h.internal();
        const Ctx = struct {
            events: []const platform.Event,
            pub fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                for (c.events) |ev| comp.platform.headless.inject(ev);
            }
        };
        var ctx: Ctx = .{ .events = events };
        try self.app.comp.call(&ctx, Ctx.run);
    }

    /// Frames the compositor presented for the window, counting those
    /// the UI did not commit (compositor scrolling and zooming, D8).
    pub fn framesPresented(h: *Harness) !u64 {
        const self = try h.internal();
        const Ctx = struct {
            id: platform.WindowId,
            out: u64 = 0,
            pub fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                if (comp.frameStats(c.id)) |st| c.out = st.frames;
            }
        };
        var ctx: Ctx = .{ .id = (try h.win()).win.id };
        try self.app.comp.call(&ctx, Ctx.run);
        return ctx.out;
    }

    /// Dispatches until the compositor presented a frame after `since`
    /// (`framesPresented`), then settles.
    pub fn waitFrame(h: *Harness, since: u64) !void {
        const deadline = Loop.now() + 5 * std.time.ns_per_s;
        while (try h.framesPresented() <= since) {
            if (Loop.now() > deadline) return error.Timeout;
            try ok(A.siv_app_dispatch(h.app, 2));
        }
        try h.settle();
    }

    pub fn click(h: *Harness, x: f64, y: f64) !void {
        return h.clickIn(h.window, x, y);
    }

    /// A click at window coordinates of `window` (a popup, say).
    pub fn clickIn(h: *Harness, window: t.Window, x: f64, y: f64) !void {
        const id = (try A.App.window(@backingInt(window), A.window_tag)).win.id;
        try h.inject(&.{
            .{ .pointer_motion = .{ .window = id, .seat = 0, .x = x, .y = y } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } },
            .{ .pointer_button = .{ .window = id, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } },
        });
    }

    pub fn typeKey(h: *Harness, keysym: u32, chars: []const u8, mods: platform.Mods) !void {
        return h.typeKeyIn(h.window, keysym, chars, mods);
    }

    pub fn typeKeyIn(h: *Harness, window: t.Window, keysym: u32, chars: []const u8, mods: platform.Mods) !void {
        const id = (try A.App.window(@backingInt(window), A.window_tag)).win.id;
        var k: platform.Key = .{ .window = id, .seat = 0, .keycode = 0, .keysym = keysym, .state = .pressed, .mods = mods, .time = 0, .serial = 3 };
        @memcpy(k.text_buf[0..chars.len], chars);
        k.text_len = @intCast(chars.len);
        var up = k;
        up.state = .released;
        up.text_len = 0;
        try h.inject(&.{ .{ .key = k }, .{ .key = up } });
    }

    pub fn capture(h: *Harness) ![]u8 {
        return h.captureOf(h.window);
    }

    /// What a window of the application presented last (a popup, say).
    pub fn captureOf(h: *Harness, window: t.Window) ![]u8 {
        const self = try h.internal();
        const Ctx = struct {
            id: platform.WindowId,
            out: anyerror![]u8 = error.NothingPresented,
            pub fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
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
        var ctx: Ctx = .{ .id = (try A.App.window(@backingInt(window), A.window_tag)).win.id };
        try self.app.comp.call(&ctx, Ctx.run);
        return ctx.out;
    }

    /// Bounding box of the damage of the last present, in buffer pixels.
    pub fn lastDamage(h: *Harness) !?platform.Rect {
        const self = try h.internal();
        const Ctx = struct {
            id: platform.WindowId,
            out: ?platform.Rect = null,
            fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                const img = comp.platform.headless.presented(c.id) orelse return;
                c.out = img.damage;
            }
        };
        var ctx: Ctx = .{ .id = (try h.win()).win.id };
        try self.app.comp.call(&ctx, Ctx.run);
        return ctx.out;
    }

    /// The window's first subsurface (external content promoted out of
    /// the window's buffer), if any.
    pub fn subsurface(h: *Harness) !?platform.SubsurfaceState {
        const self = try h.internal();
        const Ctx = struct {
            id: platform.WindowId,
            out: ?platform.SubsurfaceState = null,
            fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                for (comp.platform.headless.subsurfaces(c.id)) |sub| if (sub) |st| {
                    c.out = st;
                    return;
                };
            }
        };
        var ctx: Ctx = .{ .id = (try h.win()).win.id };
        try self.app.comp.call(&ctx, Ctx.run);
        return ctx.out;
    }

    pub fn expectGolden(h: *Harness, name: []const u8, width: u32, height: u32) !void {
        return h.expectGoldenOf(h.window, name, width, height);
    }

    pub fn expectGoldenOf(h: *Harness, window: t.Window, name: []const u8, width: u32, height: u32) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        const got = try h.captureOf(window);
        defer gpa.free(got);
        try testing.expectEqual(@as(usize, width) * height * 4, got.len);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ h.golden, name });
        defer gpa.free(path);
        if (testing.environ.getPosix("SIV_UPDATE_GOLDEN") != null) {
            const bytes = try png.encode(gpa, width, height, got);
            defer gpa.free(bytes);
            try std.Io.Dir.cwd().createDirPath(io, h.golden);
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
        const out = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}-actual.png", .{ failure_dir, std.fs.path.basename(h.golden), name });
        defer gpa.free(out);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = actual });
        return error.GoldenMismatch;
    }
};
