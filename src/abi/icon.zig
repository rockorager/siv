//! Exports for themed icons (D19): siv_icon_load through the
//! application's `ui.Icons`, the icon theme and search path, the
//! rasterization of vector images for the places that need pixels (drag
//! icons, tray pixmaps), and window icons (D17).

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const scene = @import("scene");
const render_cpu = @import("render_cpu");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const canvas = @import("canvas.zig");

const App = application.App;
const Error = application.Error;
const platform = @import("platform");

const Request = struct {
    app: *App,
    callback: t.ImageLoadFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn done(ctx: ?*anyopaque, image: ?*ui.Image) void {
        const r: *Request = @ptrCast(@alignCast(ctx));
        const self = r.app;
        var code: t.Result = .ok;
        var handle: t.Image = .null;
        if (image) |img| {
            handle = canvas.adoptImage(self, img) catch blk: {
                img.release();
                code = .error_out_of_memory;
                break :blk .null;
            };
        } else code = .error_unavailable;
        self.enter();
        defer self.leave();
        r.callback(r.user_data, code, handle);
    }

    fn drop(ctx: ?*anyopaque) void {
        const r: *Request = @ptrCast(@alignCast(ctx));
        const self = r.app;
        const destroy, const user_data = .{ r.destroy, r.user_data };
        self.gpa().destroy(r);
        self.release(destroy, user_data);
    }
};

pub export fn siv_icon_load(app: t.App, desc: ?*const t.IconDesc, callback: ?t.ImageLoadFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    load(self, desc, callback, destroy, user_data) catch |err| {
        // Ownership of user_data passed with the call (D2).
        self.release(destroy, user_data);
        return t.resultOf(err);
    };
    return .ok;
}

fn load(self: *App, desc: ?*const t.IconDesc, callback: ?t.ImageLoadFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) Error!void {
    const cb = callback orelse return error.InvalidArgument;
    const d = try runtime.readDesc(t.IconDesc, desc);
    const fl = try runtime.flags(t.IconFlags, d.flags);
    const name = try runtime.string(d.name, d.name_len);
    if (std.mem.trim(u8, name, " \t\r\n").len == 0 or name.len > 4096) return error.InvalidArgument;
    for ([_]f32{ d.logical_size, d.scale }) |v| if (!(v >= 0) or !std.math.isFinite(v)) return error.InvalidArgument;
    const gpa = self.gpa();
    const r = try gpa.create(Request);
    errdefer gpa.destroy(r);
    r.* = .{ .app = self, .callback = cb, .destroy = destroy, .user_data = user_data };
    const style: @import("icon").Style = switch (try runtime.enumValue(t.IconStyle, d.style)) {
        .default => .default,
        .symbolic => .symbolic,
        .regular => .regular,
        _ => unreachable,
    };
    try self.app.icons.request(name, if (d.logical_size == 0) 16 else @min(d.logical_size, 4096), if (d.scale == 0) 1 else @min(d.scale, 16), .{
        .rtl = fl.rtl,
        .fallbacks = !fl.no_fallbacks,
        .style = style,
    }, .{ .ctx = r, .func = Request.done, .destroy = Request.drop });
}

pub export fn siv_app_set_icon_theme(app: t.App, name: ?[*]const u8, name_len: usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, p: ?[*]const u8, n: usize) Error!void {
            const self = try App.get(@backingInt(a));
            const s = try runtime.string(p, n);
            if (s.len > 255 or std.mem.indexOfScalar(u8, s, '/') != null) return error.InvalidArgument;
            try self.app.setIconTheme(s);
        }
    }.f(app, name, name_len));
}

pub export fn siv_app_add_icon_path(app: t.App, path: ?[*]const u8, path_len: usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, p: ?[*]const u8, n: usize) Error!void {
            const self = try App.get(@backingInt(a));
            const s = try runtime.string(p, n);
            if (s.len == 0 or s.len >= 4096 or std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidArgument;
            try self.app.icons.addSearchPath(s);
            // A tray host looks the application's icons up there too.
            if (self.desktop.tray.item) |x| x.item.setIconThemePath(s) catch {};
        }
    }.f(app, path, path_len));
}

/// A vector image as pixels (`rgba16_linear_premul`) at `pixels` per
/// logical pixel, its roles in the application's theme colors; other
/// images as they are, with a reference of their own.
pub fn rasterize(self: *App, img: *ui.Image, scale: f32) Error!*ui.Image {
    const doc = img.vector orelse return img.retain();
    const gpa = self.gpa();
    const w: u32 = @intFromFloat(@max(1, @min(@ceil(@as(f32, @floatFromInt(img.width)) * scale), 1024)));
    const h: u32 = @intFromFloat(@max(1, @min(@ceil(@as(f32, @floatFromInt(img.height)) * scale), 1024)));
    var b = scene.Builder.init(gpa);
    defer b.deinit();
    var colors: @import("svg").Colors = .{};
    const palette = canvas.lightPalette(self);
    ui.iconColors(&colors, &palette, palette.color(.window_fg));
    doc.draw(&b, .xywh(0, 0, @floatFromInt(w), @floatFromInt(h)), if (doc.recolors) &colors else null) catch |err| return canvas.mapScene(err);
    const list = b.finish(0) catch return error.InvalidArgument;
    const r = render_cpu.Renderer.create(gpa, render_cpu.Executor.serial) catch return error.OutOfMemory;
    defer r.destroy();
    r.resize(w, h) catch return error.OutOfMemory;
    r.render(list, .{}) catch return error.OutOfMemory;
    const px = r.pixels();
    const out = try gpa.alignedAlloc(u8, .@"16", @as(usize, w) * h * 8);
    errdefer gpa.free(out);
    @memcpy(out, std.mem.sliceAsBytes(px[0 .. @as(usize, w) * h]));
    return ui.Image.fromPixels(gpa, out, w, h, .rgba16_linear_premul, scale);
}

// Window icons (D17) ------------------------------------------------------------

/// Sizes for a compositor that states no preference.
const default_icon_sizes = [_]u32{ 32, 48, 64, 128 };

pub export fn siv_window_set_icon(window: t.Window, icon_name: ?[*]const u8, icon_name_len: usize, image: t.Image) t.Result {
    return application.wrap(setWindowIcon(window, icon_name, icon_name_len, image));
}

fn setWindowIcon(window: t.Window, name_ptr: ?[*]const u8, name_len: usize, image: t.Image) Error!void {
    const w = try App.window(@backingInt(window), application.window_tag);
    if (w.dead or w.parent != null) return error.InvalidArgument;
    const self = w.owner;
    const name = try runtime.string(name_ptr, name_len);
    if (name.len > 255 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidArgument;
    // A newer icon wins over loads still on the way.
    w.icon_generation +%= 1;
    if (name.len == 0 and image == .null) {
        if (!try w.win.setIcon(null)) return error.Unsupported;
        return;
    }
    var size_buf: [8]u32 = undefined;
    var sizes = try self.app.iconSizes(&size_buf);
    if (sizes.len == 0) sizes = @constCast(&default_icon_sizes);
    const scale: u32 = @intFromFloat(@max(1, @ceil(w.win.state.scale.toFloat())));
    if (image != .null) {
        const src = try canvas.imageOf(self, image);
        return sendIcon(w, name, src, sizes, scale);
    }
    // A name alone: the compositor may know it; siv draws it from the
    // theme too, for compositors that do not.
    if (!try w.win.setIcon(&.{ .name = name })) return error.Unsupported;
    var largest: u32 = 0;
    for (sizes) |sz| largest = @max(largest, sz);
    const gpa = self.gpa();
    const r = try gpa.create(IconLoad);
    errdefer gpa.destroy(r);
    r.* = .{ .app = self, .window = window, .generation = w.icon_generation, .scale = scale, .name = try gpa.dupe(u8, name) };
    errdefer gpa.free(r.name);
    r.size_count = @intCast(sizes.len);
    @memcpy(r.sizes[0..sizes.len], sizes);
    try self.app.icons.request(name, @floatFromInt(largest), @floatFromInt(scale), .{}, .{ .ctx = r, .func = IconLoad.done, .destroy = IconLoad.drop });
}

const IconLoad = struct {
    app: *App,
    window: t.Window,
    generation: u32,
    scale: u32,
    name: []u8,
    sizes: [8]u32 = undefined,
    size_count: u8 = 0,

    fn done(ctx: ?*anyopaque, image: ?*ui.Image) void {
        const r: *IconLoad = @ptrCast(@alignCast(ctx));
        const img = image orelse return;
        defer img.release();
        const w = App.window(@backingInt(r.window), application.window_tag) catch return;
        if (w.dead or w.icon_generation != r.generation) return;
        // Without memory the window keeps the icon it has by name.
        sendIcon(w, r.name, img, r.sizes[0..r.size_count], r.scale) catch {};
    }

    fn drop(ctx: ?*anyopaque) void {
        const r: *IconLoad = @ptrCast(@alignCast(ctx));
        const gpa = r.app.gpa();
        gpa.free(r.name);
        gpa.destroy(r);
    }
};

/// Sends a window icon: a vector image drawn at each size, any other
/// image once at its own size, square.
fn sendIcon(w: *application.Window, name: []const u8, src: *ui.Image, sizes: []const u32, scale: u32) Error!void {
    const self = w.owner;
    const gpa = self.gpa();
    var images: [8]platform.IconImage = undefined;
    var n: usize = 0;
    defer for (images[0..n]) |img| gpa.free(img.pixels);
    if (src.vector != null) {
        for (sizes[0..@min(sizes.len, images.len)]) |sz| {
            const px = sz * scale;
            const raster = try rasterize(self, src, @as(f32, @floatFromInt(px)) / @as(f32, @floatFromInt(@max(src.width, src.height, 1))));
            defer raster.release();
            images[n] = .{ .pixels = try squarePixels(gpa, raster, px), .size = px, .scale = scale };
            n += 1;
        }
    } else {
        const px = @min(@max(src.width, src.height), 1024);
        images[0] = .{ .pixels = try squarePixels(gpa, src, px), .size = px, .scale = 1 };
        n = 1;
    }
    if (!try w.win.setIcon(&.{ .name = name, .images = images[0..n] })) return error.Unsupported;
}

/// An image centered in a `size`-pixel square as premultiplied BGRA, the
/// format of wl_shm's ARGB8888.
fn squarePixels(gpa: std.mem.Allocator, img: *const ui.Image, size: u32) Error![]u8 {
    const out = try gpa.alloc(u8, @as(usize, size) * size * 4);
    @memset(out, 0);
    const w = @min(img.width, size);
    const h = @min(img.height, size);
    const ox = (size - w) / 2;
    const oy = (size - h) / 2;
    for (0..h) |y| for (0..w) |x| {
        const o = out[((oy + y) * size + ox + x) * 4 ..][0..4];
        switch (img.format) {
            .rgba16_linear_premul => {
                const c = std.mem.bytesAsValue([4]u16, img.pixels[y * img.stride + x * 8 ..][0..8]).*;
                const a: f32 = @as(f32, @floatFromInt(c[3])) / 65535;
                var rgb: [3]u8 = .{ 0, 0, 0 };
                // Encoded straight, then premultiplied in sRGB, as
                // compositors blend.
                if (a > 0) for (0..3) |i| {
                    const lin = @as(f32, @floatFromInt(c[i])) / 65535 / a;
                    rgb[i] = @intFromFloat(@round(std.math.clamp(scene.linearToSrgb(lin), 0, 1) * 255 * a));
                };
                o.* = .{ rgb[2], rgb[1], rgb[0], @intFromFloat(@round(a * 255)) };
            },
            else => {
                const p = img.pixels[y * img.stride + x * 4 ..][0..4];
                const rgba: [4]u8 = switch (img.format) {
                    .rgba8_srgb => p.*,
                    .bgra8_srgb => .{ p[2], p[1], p[0], p[3] },
                    .bgrx8_srgb => .{ p[2], p[1], p[0], 255 },
                    .rgba16_linear_premul => unreachable,
                };
                const a: u32 = rgba[3];
                o.* = .{
                    @intCast((@as(u32, rgba[2]) * a + 127) / 255),
                    @intCast((@as(u32, rgba[1]) * a + 127) / 255),
                    @intCast((@as(u32, rgba[0]) * a + 127) / 255),
                    rgba[3],
                };
            },
        }
    };
    return out;
}
