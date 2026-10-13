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
const Root = runtime.Root;

pub const request_tag = @import("api.zig").spec.handleTag("siv_image_request");

pub const Request = struct {
    app: *App,
    callback: t.ImageLoadFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    index: u32 = 0,
    handle: u64 = 0,
    loading: ?*ui.Image.Loading = null,

    /// The handle goes before the callback runs or the load is dropped.
    fn forget(r: *Request) void {
        const self = r.app;
        if (r.handle == 0) return;
        _ = self.root.handles.remove(r.handle, request_tag) catch {};
        self.image_requests.items[r.index] = null;
        r.handle = 0;
    }

    fn done(ctx: ?*anyopaque, result: ui.Image.LoadError!*ui.Image) void {
        const r: *Request = @ptrCast(@alignCast(ctx));
        const self = r.app;
        r.forget();
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
        r.forget();
        const destroy, const user_data = .{ r.destroy, r.user_data };
        self.gpa().destroy(r);
        self.release(destroy, user_data);
    }
};

pub export fn siv_image_load(app: t.App, desc: ?*const t.ImageLoadDesc, callback: ?t.ImageLoadFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, request: ?*t.ImageRequest) t.Result {
    const self = App.get(@backingInt(app)) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    load(self, desc, callback, destroy, user_data, request) catch |err| {
        // Ownership of user_data passed with the call (D2).
        self.release(destroy, user_data);
        return t.resultOf(err);
    };
    return .ok;
}

fn load(self: *App, desc: ?*const t.ImageLoadDesc, callback: ?t.ImageLoadFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque, request: ?*t.ImageRequest) Error!void {
    const cb = callback orelse return error.InvalidArgument;
    const dest = try runtime.out(t.ImageRequest, request);
    const d = try runtime.readDesc(t.ImageLoadDesc, desc);
    const fl = try runtime.flags(t.ImageLoadFlags, d.flags);
    const data = try runtime.array(u8, d.data, d.data_count);
    const path = try runtime.string(d.path, d.path_len);
    if (data.len == 0 and path.len == 0) return error.InvalidArgument;
    for ([_]f32{ d.max_width, d.max_height, d.scale }) |v| if (!(v >= 0) or !std.math.isFinite(v)) return error.InvalidArgument;
    const scale: f32 = if (d.scale == 0) 1 else d.scale;
    const gpa = self.gpa();
    const index: u32 = for (self.image_requests.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        try self.image_requests.append(gpa, null);
        break :blk @intCast(self.image_requests.items.len - 1);
    };
    try self.root.handles.ensureUnusedCapacity(gpa);
    const r = try gpa.create(Request);
    errdefer gpa.destroy(r);
    r.* = .{ .app = self, .callback = cb, .destroy = destroy, .user_data = user_data, .index = index };
    r.loading = try ui.Image.load(&self.app.pool, gpa, if (data.len != 0) .{ .bytes = data } else .{ .path = path }, .{
        .scale = scale,
        .priority = d.priority,
        .decode = .{
            .max_width = pixels(d.max_width, scale),
            .max_height = pixels(d.max_height, scale),
            .first_frame = fl.first_frame,
        },
    }, .{ .ctx = r, .func = Request.done, .destroy = Request.drop });
    r.handle = self.root.handles.insert(gpa, request_tag, index) catch unreachable;
    self.image_requests.items[index] = r;
    dest.* = @fromBackingInt(r.handle);
}

fn requestOf(request: t.ImageRequest) Error!*Request {
    const self, const index = try Root.owner(App, application.app_tag, @backingInt(request), request_tag);
    return self.image_requests.items[index] orelse error.InvalidHandle;
}

pub export fn siv_image_request_cancel(request: t.ImageRequest) t.Result {
    const r = requestOf(request) catch |err| return t.resultOf(err);
    r.forget();
    // Runs Request.drop now, or when the decode returns.
    r.loading.?.cancel();
    return .ok;
}

pub export fn siv_image_request_set_priority(request: t.ImageRequest, priority: i64) t.Result {
    const r = requestOf(request) catch |err| return t.resultOf(err);
    r.loading.?.setPriority(priority);
    return .ok;
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
            dest.* = img.frame_count;
        }
    }.f(image, count));
}
