//! Exports for external content (D17): slots for frames the application
//! submits and for wl_surfaces an embedder renders into, and the external
//! nodes that show them. The compositor owns the slots; this file maps
//! handles and C callbacks onto them.
//!
//! Producers run on threads of their own, and video must not stall when
//! the UI thread is busy (D8), so `siv_external_submit` works from any
//! thread and goes straight to the compositor, and a slot's `release`
//! callback runs on the compositor thread. That is why slot handles are
//! not in the root's handle table, which belongs to the UI thread: they
//! index `App.externals` under `App.ext_lock`, with generations of their
//! own, and any-thread calls pin the root first (`Root.pinOwner`).

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const compositor = @import("compositor");
const platform = @import("platform");
const runtime = @import("runtime.zig");
const handles = @import("handles.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");
const api = @import("api.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;
const c = std.c;

pub const external_tag = api.spec.handleTag("siv_external");

pub const External = struct {
    /// UI thread only.
    window: *Window,
    /// For any-thread calls.
    platform_window: platform.WindowId,
    id: compositor.ExternalId,
    handle: u64,
    on_event: ?t.ExternalEventFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    surface: ?compositor.Compositor.ExternalSurface = null,
    /// Releases go to the C `release` callback on the compositor thread,
    /// which then owns the destroy-notify.
    hooked: bool = false,
};

/// The slot state every thread may touch, under `App.ext_lock`.
pub const Slots = struct {
    lock: c.pthread_mutex_t = .{},
    items: std.ArrayList(?*External) = .empty,
    gens: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *Slots, gpa: std.mem.Allocator) void {
        s.items.deinit(gpa);
        s.gens.deinit(gpa);
        _ = c.pthread_mutex_destroy(&s.lock);
    }
};

/// What the compositor thread calls for a slot with a `release` callback.
/// Outlives the slot's record until the compositor drops it.
const Producer = struct {
    app: *App,
    handle: u64,
    release: t.ExternalReleaseFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn released(ctx: ?*anyopaque, key: u64) void {
        const p: *Producer = @ptrCast(@alignCast(ctx));
        p.release(p.user_data, @fromBackingInt(p.handle), key);
    }

    /// The compositor will not call again: the destroy-notify runs on the
    /// application's thread (D2), and this record goes.
    fn dropped(ctx: ?*anyopaque) void {
        const p: *Producer = @ptrCast(@alignCast(ctx));
        const app, const destroy, const user_data = .{ p.app, p.destroy, p.user_data };
        app.gpa().destroy(p);
        const d = destroy orelse return;
        app.app.post(noop, d, user_data) catch d(user_data);
    }

    fn noop(_: ?*anyopaque) callconv(.c) void {}
};

/// Runs `f(app, slot)` with the slot locked, from any thread.
fn withSlot(handle: t.External, comptime f: anytype, args: anytype) Error!void {
    const h = @backingInt(handle);
    const self = try runtime.Root.pinOwner(App, application.app_tag, h);
    defer runtime.Root.unpin(h);
    if (self.closing.load(.seq_cst)) return error.InvalidHandle;
    const s = &self.externals;
    _ = c.pthread_mutex_lock(&s.lock);
    defer _ = c.pthread_mutex_unlock(&s.lock);
    const fields = handles.Fields.decode(h);
    if (fields.type != external_tag or fields.index >= s.items.items.len) return error.InvalidHandle;
    if (s.gens.items[fields.index] != fields.generation) return error.InvalidHandle;
    const x = s.items.items[fields.index] orelse return error.InvalidHandle;
    return @call(.auto, f, .{ self, x } ++ args);
}

fn create(window: t.Window, desc_ptr: ?*const t.ExternalDesc, out: ?*t.External, surface: bool) Error!void {
    const w = try App.window(@backingInt(window), application.window_tag);
    const self = w.owner;
    if (self.painting != 0) return error.Busy;
    const desc = try runtime.readDesc(t.ExternalDesc, desc_ptr);
    if (surface and desc.release != null) return error.InvalidArgument;
    const dest = try runtime.out(t.External, out);
    const gpa = self.gpa();
    const s = &self.externals;

    const x = try gpa.create(External);
    errdefer gpa.destroy(x);
    x.* = .{ .window = w, .platform_window = w.win.id, .id = 0, .handle = 0, .on_event = desc.on_event, .destroy = desc.destroy, .user_data = desc.user_data };
    const producer: ?*Producer = if (desc.release) |r| blk: {
        const p = try gpa.create(Producer);
        p.* = .{ .app = self, .handle = 0, .release = r, .destroy = desc.destroy, .user_data = desc.user_data };
        break :blk p;
    } else null;
    errdefer if (producer) |p| gpa.destroy(p);

    _ = c.pthread_mutex_lock(&s.lock);
    const index: u32 = for (s.items.items, 0..) |slot, i| {
        if (slot == null) break @intCast(i);
    } else blk: {
        s.items.ensureUnusedCapacity(gpa, 1) catch {
            _ = c.pthread_mutex_unlock(&s.lock);
            return error.OutOfMemory;
        };
        s.gens.ensureUnusedCapacity(gpa, 1) catch {
            _ = c.pthread_mutex_unlock(&s.lock);
            return error.OutOfMemory;
        };
        s.items.appendAssumeCapacity(null);
        // Unrelated to other roots' generations, as the handle table's are.
        s.gens.appendAssumeCapacity(self.root.handles.seed);
        break :blk @intCast(s.items.items.len - 1);
    };
    _ = c.pthread_mutex_unlock(&s.lock);
    if (index > handles.max_index) return error.LimitExceeded;

    if (surface) {
        const es = w.win.createExternalSurface() catch |err| return mapApp(err);
        x.id = es.id;
        x.surface = es;
    } else {
        x.id = w.win.createExternal() catch |err| return mapApp(err);
    }
    errdefer w.win.destroyExternal(x.id) catch {};

    _ = c.pthread_mutex_lock(&s.lock);
    const gen: u22 = @truncate(s.gens.items[index]);
    x.handle = handles.Fields.encode(.{ .type = external_tag, .root = handles.Fields.decode(self.root.handle).root, .generation = gen, .index = @intCast(index) });
    s.items.items[index] = x;
    _ = c.pthread_mutex_unlock(&s.lock);

    if (producer) |p| {
        p.handle = x.handle;
        // Frames sent after this go to the hook; the compositor owns the
        // producer record from here, even if this fails.
        x.hooked = true;
        self.app.comp.setExternalReleaseHook(w.win.id, x.id, .{ .ctx = p, .released = Producer.released, .dropped = Producer.dropped }) catch {
            // The errdefers above free the rest.
            x.hooked = false;
            remove(self, x);
            return error.OutOfMemory;
        };
    }
    dest.* = @fromBackingInt(x.handle);
}

fn mapApp(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
}

/// Takes a slot out of the table; its handle stops working at once.
fn remove(self: *App, x: *External) void {
    const s = &self.externals;
    _ = c.pthread_mutex_lock(&s.lock);
    defer _ = c.pthread_mutex_unlock(&s.lock);
    const index = handles.Fields.decode(x.handle).index;
    s.items.items[index] = null;
    s.gens.items[index] +%= 1;
}

/// The slot's record goes; its destroy-notify runs here unless the
/// compositor runs it after the last release.
fn forget(self: *App, x: *External) void {
    remove(self, x);
    if (!x.hooked) self.release(x.destroy, x.user_data);
    self.gpa().destroy(x);
}

pub export fn siv_external_create(window: t.Window, desc: ?*const t.ExternalDesc, external: ?*t.External) t.Result {
    return application.wrap(create(window, desc, external, false));
}

pub export fn siv_external_create_surface(window: t.Window, desc: ?*const t.ExternalDesc, external: ?*t.External) t.Result {
    return application.wrap(create(window, desc, external, true));
}

pub export fn siv_external_get_wayland(external: t.External, display: ?*?*anyopaque, surface: ?*?*anyopaque) t.Result {
    return application.wrap(withSlot(external, struct {
        fn f(_: *App, x: *External, d: ?*?*anyopaque, s: ?*?*anyopaque) Error!void {
            const dd = try runtime.out(?*anyopaque, d);
            const ds = try runtime.out(?*anyopaque, s);
            const es = x.surface orelse return error.InvalidArgument;
            dd.* = es.display;
            ds.* = es.surface;
        }
    }.f, .{ display, surface }));
}

pub export fn siv_external_submit(external: t.External, frame: ?*const t.ExternalFrameDesc) t.Result {
    return application.wrap(withSlot(external, struct {
        fn f(self: *App, x: *External, ptr: ?*const t.ExternalFrameDesc) Error!void {
            if (x.surface != null) return error.InvalidArgument;
            const d = try runtime.readDesc(t.ExternalFrameDesc, ptr);
            _ = try runtime.enumValue(t.ExternalFormat, d.format);
            if (d.width == 0 or d.height == 0 or d.fd < 0 or d.width > 1 << 15 or d.height > 1 << 15) return error.InvalidArgument;
            const stride = if (d.stride == 0) d.width * 4 else d.stride;
            if (stride < d.width * 4) return error.InvalidArgument;
            // Straight to the compositor: thread-safe, and in order with
            // the slot's other messages.
            self.app.comp.setExternalFrame(x.platform_window, x.id, .{ .fd = d.fd, .offset = d.offset, .width = d.width, .height = d.height, .stride = stride, .key = d.key }) catch |err|
                return mapApp(err);
        }
    }.f, .{frame}));
}

pub export fn siv_external_surface_committed(external: t.External, width: u32, height: u32) t.Result {
    return application.wrap(withSlot(external, struct {
        fn f(self: *App, x: *External, wd: u32, ht: u32) Error!void {
            if (x.surface == null) return error.InvalidArgument;
            try self.app.comp.externalSurfaceCommitted(x.platform_window, x.id, wd, ht);
        }
    }.f, .{ width, height }));
}

/// The slot an UI-thread call names.
fn uiSlot(handle: t.External) Error!*External {
    var out: *External = undefined;
    try withSlot(handle, struct {
        fn f(_: *App, x: *External, o: **External) Error!void {
            o.* = x;
        }
    }.f, .{&out});
    return out;
}

pub export fn siv_external_destroy(external: t.External) t.Result {
    const x = uiSlot(external) catch |err| return t.resultOf(err);
    const self = x.window.owner;
    if (self.painting != 0) return .error_busy;
    x.window.win.destroyExternal(x.id) catch return .error_out_of_memory;
    forget(self, x);
    return .ok;
}

/// The window is gone, and the compositor destroyed its slots with it.
pub fn forgetWindow(w: *Window) void {
    const self = w.owner;
    for (self.externals.items.items) |slot| if (slot) |x| if (x.window == w) forget(self, x);
}

/// An event for one of the window's slots (application.zig).
pub fn deliver(w: *Window, id: compositor.ExternalId, ev: t.ExternalEvent) void {
    const self = w.owner;
    for (self.externals.items.items) |slot| if (slot) |x| if (x.window == w and x.id == id) {
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
        const x = try uiSlot(external);
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
