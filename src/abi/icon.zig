//! Exports for themed icons (D19): siv_icon_load through the
//! application's `ui.Icons`, the icon theme and search path, and the
//! rasterization of vector images for the places that need pixels (drag
//! icons, tray pixmaps).

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
