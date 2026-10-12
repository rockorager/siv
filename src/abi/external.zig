//! Exports for external content (D17): slots for frames the application
//! submits and for wl_surfaces an embedder renders into, and the external
//! nodes that show them. The compositor owns the slots; this file maps
//! handles and C callbacks onto them.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const compositor = @import("compositor");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");
const api = @import("api.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;

pub const external_tag = api.spec.handleTag("siv_external");

pub const External = struct {
    window: *Window,
    id: compositor.ExternalId,
    handle: u64,
    on_event: ?t.ExternalEventFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    surface: ?compositor.Compositor.ExternalSurface = null,
};

fn get(handle: t.External) Error!struct { *App, u32, *External } {
    const self, const index = try runtime.Root.owner(App, application.app_tag, @backingInt(handle), external_tag);
    return .{ self, index, self.externals.items[index] orelse return error.InvalidHandle };
}

fn create(window: t.Window, desc_ptr: ?*const t.ExternalDesc, out: ?*t.External, surface: bool) Error!void {
    const w = try App.window(@backingInt(window), application.window_tag);
    const self = w.owner;
    if (self.painting != 0) return error.Busy;
    const desc = try runtime.readDesc(t.ExternalDesc, desc_ptr);
    const dest = try runtime.out(t.External, out);
    const gpa = self.gpa();
    const index: u32 = for (self.externals.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        try self.externals.append(gpa, null);
        break :blk @intCast(self.externals.items.len - 1);
    };
    try self.root.handles.ensureUnusedCapacity(gpa);
    const x = try gpa.create(External);
    errdefer gpa.destroy(x);
    x.* = .{ .window = w, .id = 0, .handle = 0, .on_event = desc.on_event, .destroy = desc.destroy, .user_data = desc.user_data };
    if (surface) {
        const es = w.win.createExternalSurface() catch |err| return mapApp(err);
        x.id = es.id;
        x.surface = es;
    } else {
        x.id = w.win.createExternal() catch |err| return mapApp(err);
    }
    x.handle = self.root.handles.insert(gpa, external_tag, index) catch unreachable;
    self.externals.items[index] = x;
    dest.* = @fromBackingInt(x.handle);
}

fn mapApp(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
}

pub export fn siv_external_create(window: t.Window, desc: ?*const t.ExternalDesc, external: ?*t.External) t.Result {
    return application.wrap(create(window, desc, external, false));
}

pub export fn siv_external_create_surface(window: t.Window, desc: ?*const t.ExternalDesc, external: ?*t.External) t.Result {
    return application.wrap(create(window, desc, external, true));
}

pub export fn siv_external_get_wayland(external: t.External, display: ?*?*anyopaque, surface: ?*?*anyopaque) t.Result {
    return application.wrap(struct {
        fn f(e: t.External, d: ?*?*anyopaque, s: ?*?*anyopaque) Error!void {
            _, _, const x = try get(e);
            const dd = try runtime.out(?*anyopaque, d);
            const ds = try runtime.out(?*anyopaque, s);
            const es = x.surface orelse return error.InvalidArgument;
            dd.* = es.display;
            ds.* = es.surface;
        }
    }.f(external, display, surface));
}

pub export fn siv_external_submit(external: t.External, frame: ?*const t.ExternalFrameDesc) t.Result {
    return application.wrap(struct {
        fn f(e: t.External, ptr: ?*const t.ExternalFrameDesc) Error!void {
            _, _, const x = try get(e);
            if (x.surface != null) return error.InvalidArgument;
            const d = try runtime.readDesc(t.ExternalFrameDesc, ptr);
            _ = try runtime.enumValue(t.ExternalFormat, d.format);
            if (d.width == 0 or d.height == 0 or d.fd < 0 or d.width > 1 << 15) return error.InvalidArgument;
            const stride = if (d.stride == 0) d.width * 4 else d.stride;
            if (stride < d.width * 4) return error.InvalidArgument;
            x.window.win.setExternalFrame(x.id, .{ .fd = d.fd, .offset = d.offset, .width = d.width, .height = d.height, .stride = stride, .key = d.key }) catch |err| return mapApp(err);
        }
    }.f(external, frame));
}

pub export fn siv_external_surface_committed(external: t.External, width: u32, height: u32) t.Result {
    return application.wrap(struct {
        fn f(e: t.External, wd: u32, ht: u32) Error!void {
            _, _, const x = try get(e);
            if (x.surface == null) return error.InvalidArgument;
            try x.window.win.externalSurfaceCommitted(x.id, wd, ht);
        }
    }.f(external, width, height));
}

pub export fn siv_external_destroy(external: t.External) t.Result {
    const self, const index, const x = get(external) catch |err| return t.resultOf(err);
    if (self.painting != 0) return .error_busy;
    x.window.win.destroyExternal(x.id) catch return .error_out_of_memory;
    forget(self, index);
    return .ok;
}

fn forget(self: *App, index: u32) void {
    const x = self.externals.items[index].?;
    _ = self.root.handles.remove(x.handle, external_tag) catch unreachable;
    self.externals.items[index] = null;
    self.release(x.destroy, x.user_data);
    self.gpa().destroy(x);
}

/// The window is gone, and the compositor destroyed its slots with it.
pub fn forgetWindow(w: *Window) void {
    const self = w.owner;
    for (self.externals.items, 0..) |slot, i| if (slot) |x| if (x.window == w) forget(self, @intCast(i));
}

/// An event for one of the window's slots (application.zig).
pub fn deliver(w: *Window, id: compositor.ExternalId, ev: t.ExternalEvent) void {
    const self = w.owner;
    for (self.externals.items) |slot| if (slot) |x| if (x.window == w and x.id == id) {
        const f = x.on_event orelse return;
        var e = ev;
        self.enter();
        defer self.leave();
        f(x.user_data, @fromBackingInt(x.handle), &e);
        return;
    };
}

// External nodes --------------------------------------------------------------

fn viewOf(w: *Window, external: t.External, size: t.Size, fit: t.Fit) Error!ui.External {
    if (!(size.width >= 0) or !(size.height >= 0) or !std.math.isFinite(size.width) or !std.math.isFinite(size.height)) return error.InvalidArgument;
    const id: compositor.ExternalId = if (external == .null) 0 else blk: {
        _, _, const x = try get(external);
        if (x.window != w) return error.InvalidArgument;
        break :blk x.id;
    };
    return .{
        .id = id,
        .width = size.width,
        .height = size.height,
        .fit = switch (try runtime.enumValue(t.Fit, fit)) {
            .contain => .contain,
            .cover => .cover,
            .fill => .fill,
            .none => .none,
            _ => unreachable,
        },
    };
}

pub export fn siv_external_view(txn: t.Txn, parent: t.Node, external: t.External, size: t.Size, fit: t.Fit) t.Node {
    return tree.build(txn, struct {
        fn f(w: *Window, p: t.Node, e: t.External, s: t.Size, ft: t.Fit) Error!NodeId {
            const view = try viewOf(w, e, s, ft);
            const id = try tree.create(w, p, .external);
            w.txn.ut.setExternal(id, view) catch |err| return tree.mapTxn(err);
            return id;
        }
    }.f, .{ parent, external, size, fit });
}

pub export fn siv_set_external_view(txn: t.Txn, node: t.Node, external: t.External, size: t.Size, fit: t.Fit) t.Result {
    return tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, e: t.External, s: t.Size, ft: t.Fit) Error!void {
            const id = try tree.nodeIn(w, n);
            w.txn.ut.setExternal(id, try viewOf(w, e, s, ft)) catch |err| return tree.mapTxn(err);
        }
    }.f, .{ node, external, size, fit });
}
