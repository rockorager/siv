//! Exports for decoding images (D19): siv_image_load runs on the worker
//! pool through ui.Image.load, and images report their size and frames.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
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

    fn done(ctx: ?*anyopaque, result: ui.Image.LoadError!*ui.Image) void {
        const r: *Request = @ptrCast(@alignCast(ctx));
        const self = r.app;
        var code: t.Result = .ok;
        var handle: t.Image = .null;
        if (result) |img| {
            handle = canvas.adoptImage(self, img) catch blk: {
                img.release();
                code = .error_out_of_memory;
                break :blk .null;
            };
        } else |err| code = switch (err) {
            error.OutOfMemory => .error_out_of_memory,
            error.Unsupported => .error_unsupported,
            error.InvalidImage => .error_invalid_argument,
            error.TooLarge => .error_limit_exceeded,
            error.ReadFailed => .error_unavailable,
        };
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

pub export fn siv_image_load(app: t.App, desc: ?*const t.ImageLoadDesc, callback: ?t.ImageLoadFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
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

fn load(self: *App, desc: ?*const t.ImageLoadDesc, callback: ?t.ImageLoadFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) Error!void {
    const cb = callback orelse return error.InvalidArgument;
    const d = try runtime.readDesc(t.ImageLoadDesc, desc);
    const fl = try runtime.flags(t.ImageLoadFlags, d.flags);
    const data = try runtime.array(u8, d.data, d.data_count);
    const path = try runtime.string(d.path, d.path_len);
    if (data.len == 0 and path.len == 0) return error.InvalidArgument;
    for ([_]f32{ d.max_width, d.max_height, d.scale }) |v| if (!(v >= 0) or !std.math.isFinite(v)) return error.InvalidArgument;
    const scale: f32 = if (d.scale == 0) 1 else d.scale;
    const gpa = self.gpa();
    const r = try gpa.create(Request);
    errdefer gpa.destroy(r);
    r.* = .{ .app = self, .callback = cb, .destroy = destroy, .user_data = user_data };
    try ui.Image.load(&self.app.pool, gpa, if (data.len != 0) .{ .bytes = data } else .{ .path = path }, .{
        .scale = scale,
        .decode = .{
            .max_width = pixels(d.max_width, scale),
            .max_height = pixels(d.max_height, scale),
            .first_frame = fl.first_frame,
        },
    }, .{ .ctx = r, .func = Request.done, .destroy = Request.drop });
}

fn pixels(logical: f32, scale: f32) u32 {
    if (logical == 0) return 0;
    return @intFromFloat(@max(1, @min(@ceil(logical * scale), 1 << 20)));
}

pub export fn siv_image_get_size(image: t.Image, size: ?*t.Size) t.Result {
    return application.wrap(struct {
        fn f(h: t.Image, out: ?*t.Size) Error!void {
            const self, _ = try runtime.Root.owner(App, application.app_tag, @backingInt(h), canvas.image_tag);
            const img = try canvas.imageOf(self, h);
            const dest = try runtime.out(t.Size, out);
            const s = img.logicalSize();
            dest.* = .{ .width = s[0], .height = s[1] };
        }
    }.f(image, size));
}

pub export fn siv_image_get_frame_count(image: t.Image, count: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(h: t.Image, out: ?*u32) Error!void {
            const self, _ = try runtime.Root.owner(App, application.app_tag, @backingInt(h), canvas.image_tag);
            const img = try canvas.imageOf(self, h);
            const dest = try runtime.out(u32, out);
            dest.* = @intCast(@max(img.frames.len, 1));
        }
    }.f(image, count));
}
