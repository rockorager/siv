//! Exports for desktop portals and application actions (D19). The
//! portal protocol is the `portal` module's and parent windows and
//! actions are the coordinator's (app/portals.zig); this file maps
//! handles, descriptors, and C callbacks onto them.
//!
//! Requests complete through C callbacks at safe points (D5); a request
//! that cannot start (no session bus) completes at the next dispatch, so
//! a callback never runs inside the call that started it. Destroying the
//! application cancels what is pending and runs the destroy-notifies.

const std = @import("std");
const linux = std.os.linux;
const t = @import("siv");
const app_mod = @import("app");
const portal = @import("portal");
const loop_mod = @import("loop");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const api = @import("api.zig");
const print = @import("print.zig");
const tray = @import("tray.zig");

const App = application.App;
const Error = application.Error;
const Loop = loop_mod.Loop;
const Parent = app_mod.portals.Parent;
const Token = app_mod.portals.Token;
const List = std.DoublyLinkedList;

pub const chooser_tag = api.spec.handleTag("siv_file_chooser");
pub const inhibition_tag = api.spec.handleTag("siv_inhibition");
pub const shortcuts_tag = api.spec.handleTag("siv_global_shortcuts");
pub const screencast_tag = api.spec.handleTag("siv_screencast");

/// What the application keeps for portals.
pub const State = struct {
    choosers: Slots(Chooser) = .{},
    inhibitions: Slots(Inhibition) = .{},
    shortcuts: Slots(Shortcuts) = .{},
    casts: Slots(Cast) = .{},
    /// One-shot requests in flight.
    ops: List = .{},
    /// Registered actions by name; the coordinator's registry points at
    /// these.
    actions: std.StringHashMapUnmanaged(*ActionEntry) = .empty,
    /// siv_app_launch's handler.
    launch: ?Launch = null,
    /// Documents being printed or written as PDF (print.zig).
    prints: print.State = .{},
    /// The tray item (tray.zig).
    tray: tray.State = .{},
};

const Launch = struct { on_activate: ?t.ActivateFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque };

fn Slots(comptime T: type) type {
    return struct {
        items: std.ArrayList(?*T) = .empty,

        fn reserve(s: *@This(), gpa: std.mem.Allocator) Error!u32 {
            for (s.items.items, 0..) |slot, i| if (slot == null) return @intCast(i);
            try s.items.append(gpa, null);
            return @intCast(s.items.items.len - 1);
        }
    };
}

/// Cancels everything pending (before windows go, so that no request
/// starts during teardown) and runs the destroy-notifies.
pub fn teardown(self: *App) void {
    const st = &self.desktop;
    const gpa = self.gpa();
    print.teardown(self);
    tray.teardown(self);
    while (st.ops.popFirst()) |n| {
        const o: *Op = @fieldParentPtr("node", n);
        o.stop();
        self.release(o.destroy, o.user_data);
        gpa.destroy(o);
    }
    for (st.choosers.items.items, 0..) |slot, i| if (slot != null) destroyChooser(self, @intCast(i));
    for (st.inhibitions.items.items, 0..) |slot, i| if (slot != null) destroyInhibition(self, @intCast(i));
    for (st.shortcuts.items.items, 0..) |slot, i| if (slot != null) destroyShortcuts(self, @intCast(i));
    for (st.casts.items.items, 0..) |slot, i| if (slot != null) destroyCast(self, @intCast(i));
    st.choosers.items.deinit(gpa);
    st.inhibitions.items.deinit(gpa);
    st.shortcuts.items.deinit(gpa);
    st.casts.items.deinit(gpa);
    var it = st.actions.iterator();
    while (it.next()) |e| {
        self.app.removeAction(e.key_ptr.*);
        self.release(e.value_ptr.*.destroy, e.value_ptr.*.user_data);
        gpa.free(e.key_ptr.*);
        gpa.destroy(e.value_ptr.*);
    }
    st.actions.deinit(gpa);
    if (st.launch) |l| self.release(l.destroy, l.user_data);
    st.launch = null;
}

/// The window a parent handle names, or null for 0.
fn parentWindow(self: *App, window: t.Window) Error!?*app_mod.Window {
    if (window == .null) return null;
    const w = try App.window(@backingInt(window), application.window_tag);
    if (w.owner != self) return error.InvalidArgument;
    return w.win;
}

fn responseOf(outcome: portal.Request.Outcome) t.PortalResponse {
    return switch (outcome) {
        .response => |r| switch (r.code) {
            .success => .success,
            .cancelled => .cancelled,
            .other => .ended,
        },
        .failed => |f| failureOf(f),
    };
}

fn failureOf(f: portal.Failure) t.PortalResponse {
    return switch (f) {
        .unavailable => .unavailable,
        .failed, .disconnected => .failed,
    };
}

fn callResult(self: *App, cb: ?t.PortalFn, user_data: ?*anyopaque, result: t.PortalResult) void {
    const f = cb orelse return;
    var r = result;
    self.enter();
    defer self.leave();
    f(user_data, &r);
}

fn dupe(self: *App, s: []const u8) Error![]u8 {
    return self.gpa().dupe(u8, s);
}

fn mapStart(err: anyerror) portal.Failure {
    return switch (err) {
        error.Disconnected => .disconnected,
        else => .failed,
    };
}

// One-shot requests ---------------------------------------------------------------

const Op = struct {
    self: *App,
    node: List.Node = .{},
    kind: Kind,
    callback: ?t.PortalFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    window: ?*app_mod.Window,
    parent: Parent = .{ .func = onParent },
    token: Token = .{ .func = onToken },
    req: portal.Request = .{ .func = onResponse },
    doc: portal.documents.Add = .{ .func = onDocument },
    /// Completes without a portal at the next dispatch.
    task: Loop.Task = .{ .func = onUnavailable },
    /// The request is waiting for its parent or token, or in flight.
    started: bool = false,
    text: []u8 = &.{},
    token_text: [256]u8 = undefined,
    token_len: usize = 0,
    flags: u32 = 0,
    app_id: []u8 = &.{},
    permissions: portal.documents.Permissions = .{},
    doc_flags: portal.documents.Flags = .{},

    const Kind = enum { open_uri, screenshot, pick_color, document, token };

    fn stop(o: *Op) void {
        o.parent.cancel();
        o.token.cancel();
        o.req.abandon();
        o.doc.cancel();
        o.self.app.loop.unschedule(&o.task);
        const gpa = o.self.gpa();
        gpa.free(o.text);
        gpa.free(o.app_id);
    }

    /// Ends the op: runs the callback, then frees it.
    fn finish(o: *Op, result: t.PortalResult) void {
        const self = o.self;
        self.desktop.ops.remove(&o.node);
        o.stop();
        callResult(self, o.callback, o.user_data, result);
        self.release(o.destroy, o.user_data);
        self.gpa().destroy(o);
    }

    fn fail(o: *Op, f: portal.Failure) void {
        o.finish(.{ .response = failureOf(f) });
    }

    fn onUnavailable(task: *Loop.Task) void {
        const o: *Op = @fieldParentPtr("task", task);
        o.fail(.unavailable);
    }

    fn onToken(tk: *Token, token: []const u8) void {
        const o: *Op = @fieldParentPtr("token", tk);
        if (o.kind == .token) return o.finish(.{ .response = .success, .token = token.ptr, .token_len = token.len });
        const n = @min(token.len, o.token_text.len);
        @memcpy(o.token_text[0..n], token[0..n]);
        o.token_len = n;
        app_mod.portals.parentOf(o.self.app, o.window, &o.parent);
    }

    fn onParent(pa: *Parent, id: []const u8) void {
        const o: *Op = @fieldParentPtr("parent", pa);
        const client = o.self.app.portals.get() orelse return o.fail(.unavailable);
        const r = switch (o.kind) {
            .open_uri => blk: {
                const f: t.OpenUriFlags = @bitCast(o.flags);
                break :blk portal.open_uri.openUri(&o.req, client, id, o.text, .{
                    .ask = f.ask,
                    .writable = f.writable,
                    .show_in_folder = f.show_in_folder,
                    .activation_token = o.token_text[0..o.token_len],
                });
            },
            .screenshot => blk: {
                const f: t.ScreenshotFlags = @bitCast(o.flags);
                break :blk portal.screenshot.screenshot(&o.req, client, id, .{ .interactive = f.interactive, .modal = !f.not_modal });
            },
            .pick_color => portal.screenshot.pickColor(&o.req, client, id),
            .document, .token => unreachable,
        };
        r catch |err| o.fail(mapStart(err));
    }

    fn onResponse(r: *portal.Request, outcome: portal.Request.Outcome) void {
        const o: *Op = @fieldParentPtr("req", r);
        var result: t.PortalResult = .{ .response = responseOf(outcome) };
        if (outcome == .response and result.response == .success) {
            const res = outcome.response.results;
            if (res.string("uri")) |u| {
                result.uri = u.ptr;
                result.uri_len = u.len;
            }
            if (portal.screenshot.color(&res)) |c| result.color = .{ .r = @floatCast(c[0]), .g = @floatCast(c[1]), .b = @floatCast(c[2]), .a = 1 };
        }
        o.finish(result);
    }

    fn onDocument(a: *portal.documents.Add, r: portal.documents.Result) void {
        const o: *Op = @fieldParentPtr("doc", a);
        switch (r) {
            .failed => |f| o.fail(f),
            .added => |x| o.finish(.{ .response = .success, .uri = x.path.ptr, .uri_len = x.path.len, .id = x.id.ptr, .id_len = x.id.len }),
        }
    }
};

fn newOp(self: *App, kind: Op.Kind, window: t.Window, cb: ?t.PortalFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) Error!*Op {
    const win = try parentWindow(self, window);
    const o = try self.gpa().create(Op);
    o.* = .{ .self = self, .kind = kind, .callback = cb, .destroy = destroy, .user_data = user_data, .window = win };
    return o;
}

/// Starts an op: without a portal it fails at the next dispatch.
fn launch(o: *Op) void {
    const self = o.self;
    self.desktop.ops.append(&o.node);
    // Activation tokens come from the compositor, not a portal.
    if (o.kind == .token) return app_mod.portals.tokenFor(self.app, o.window.?, &o.token);
    if (self.app.portals.get() == null) return self.app.loop.schedule(&o.task, .dispatch);
    switch (o.kind) {
        .open_uri => if (o.window) |w| app_mod.portals.tokenFor(self.app, w, &o.token) else app_mod.portals.parentOf(self.app, null, &o.parent),
        .document => {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (o.text.len >= path_buf.len) return o.fail(.failed);
            @memcpy(path_buf[0..o.text.len], o.text);
            path_buf[o.text.len] = 0;
            o.doc.start(self.app.portals.get().?, path_buf[0..o.text.len :0], o.app_id, o.permissions, o.doc_flags) catch |err| o.fail(mapStart(err));
        },
        .token => unreachable,
        else => app_mod.portals.parentOf(self.app, o.window, &o.parent),
    }
}

/// A call that took a destroy-notify and failed runs it (D2).
fn failed(self: ?*App, destroy: ?t.DestroyFn, user_data: ?*anyopaque, err: Error) t.Result {
    if (destroy) |d| if (self) |s| s.release(d, user_data) else d(user_data);
    return t.resultOf(err);
}

pub export fn siv_open_uri(app: t.App, window: t.Window, uri: ?[*]const u8, uri_len: usize, flags: t.OpenUriFlags, callback: ?t.PortalFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return failed(null, destroy, user_data, err);
    const s = runtime.string(uri, uri_len) catch |err| return failed(self, destroy, user_data, err);
    const fl = runtime.flags(t.OpenUriFlags, flags) catch |err| return failed(self, destroy, user_data, err);
    if (s.len == 0 or std.mem.indexOfScalar(u8, s, 0) != null) return failed(self, destroy, user_data, error.InvalidArgument);
    const o = newOp(self, .open_uri, window, callback, destroy, user_data) catch |err| return failed(self, destroy, user_data, err);
    o.text = dupe(self, s) catch {
        self.gpa().destroy(o);
        return failed(self, destroy, user_data, error.OutOfMemory);
    };
    o.flags = @bitCast(fl);
    launch(o);
    return .ok;
}

pub export fn siv_screenshot(app: t.App, window: t.Window, flags: t.ScreenshotFlags, callback: ?t.PortalFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return failed(null, destroy, user_data, err);
    const fl = runtime.flags(t.ScreenshotFlags, flags) catch |err| return failed(self, destroy, user_data, err);
    const o = newOp(self, .screenshot, window, callback, destroy, user_data) catch |err| return failed(self, destroy, user_data, err);
    o.flags = @bitCast(fl);
    launch(o);
    return .ok;
}

pub export fn siv_pick_color(app: t.App, window: t.Window, callback: ?t.PortalFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return failed(null, destroy, user_data, err);
    const o = newOp(self, .pick_color, window, callback, destroy, user_data) catch |err| return failed(self, destroy, user_data, err);
    launch(o);
    return .ok;
}

pub export fn siv_document_export(app: t.App, desc: ?*const t.DocumentDesc, callback: ?t.PortalFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return failed(null, destroy, user_data, err);
    const d = runtime.readDesc(t.DocumentDesc, desc) catch |err| return failed(self, destroy, user_data, err);
    const path = runtime.string(d.path, d.path_len) catch |err| return failed(self, destroy, user_data, err);
    const app_id = runtime.string(d.app_id, d.app_id_len) catch |err| return failed(self, destroy, user_data, err);
    const perms = runtime.flags(t.DocumentPermissions, d.permissions) catch |err| return failed(self, destroy, user_data, err);
    const fl = runtime.flags(t.DocumentFlags, d.flags) catch |err| return failed(self, destroy, user_data, err);
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return failed(self, destroy, user_data, error.InvalidArgument);
    const o = newOp(self, .document, .null, callback, destroy, user_data) catch |err| return failed(self, destroy, user_data, err);
    o.text = dupe(self, path) catch {
        self.gpa().destroy(o);
        return failed(self, destroy, user_data, error.OutOfMemory);
    };
    o.app_id = dupe(self, app_id) catch {
        self.gpa().free(o.text);
        self.gpa().destroy(o);
        return failed(self, destroy, user_data, error.OutOfMemory);
    };
    o.permissions = .{ .read = perms.read, .write = perms.write, .grant_permissions = perms.grant, .delete = perms.delete };
    o.doc_flags = .{ .reuse_existing = fl.reuse_existing, .persistent = fl.persistent, .export_directory = fl.directory };
    launch(o);
    return .ok;
}

// Notifications and actions ---------------------------------------------------------

pub export fn siv_notification_send(app: t.App, desc: ?*const t.NotificationDesc) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, dp: ?*const t.NotificationDesc) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.NotificationDesc, dp);
            const id = try runtime.string(d.id, d.id_len);
            const icon = try runtime.string(d.icon, d.icon_len);
            const icon_data = try runtime.array(u8, d.icon_data, d.icon_data_count);
            const raw_buttons = try runtime.array(t.NotificationButton, d.buttons, d.buttons_count);
            const fl = try runtime.flags(t.NotificationFlags, d.flags);
            const priority = try runtime.enumValue(t.NotificationPriority, d.priority);
            if (id.len == 0) return error.InvalidArgument;
            const gpa = self.gpa();
            // Actions use GLib's "app." names, which desktops that activate
            // applications by D-Bus expect (app/portals.zig).
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a2 = arena.allocator();
            const buttons = try a2.alloc(portal.notification.Button, raw_buttons.len);
            for (raw_buttons, buttons) |rb, *b| b.* = .{
                .label = try runtime.string(rb.label, rb.label_len),
                .action = try appAction(a2, try runtime.string(rb.action, rb.action_len)),
                .target = try runtime.string(rb.target, rb.target_len),
            };
            const default_action = try runtime.string(d.default_action, d.default_action_len);
            const client = self.app.portals.get() orelse return error.Unavailable;
            portal.notification.add(client, id, .{
                .title = try runtime.string(d.title, d.title_len),
                .body = try runtime.string(d.body, d.body_len),
                .icon = if (icon_data.len > 0) .{ .bytes = icon_data } else if (icon.len > 0) .{ .themed = icon } else .none,
                .priority = switch (priority) {
                    .normal => .normal,
                    .low => .low,
                    .high => .high,
                    .urgent => .urgent,
                    _ => unreachable,
                },
                .default_action = if (default_action.len > 0) try appAction(a2, default_action) else "",
                .default_target = try runtime.string(d.default_target, d.default_target_len),
                .buttons = buttons,
                .transient = fl.transient,
            }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else if (err == error.Disconnected) error.Unavailable else error.InvalidArgument;
        }
    }.f(app, desc));
}

fn appAction(a: std.mem.Allocator, name: []const u8) Error![]const u8 {
    if (name.len == 0) return error.InvalidArgument;
    return std.fmt.allocPrint(a, "app.{s}", .{name});
}

pub export fn siv_notification_withdraw(app: t.App, id: ?[*]const u8, id_len: usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, p: ?[*]const u8, n: usize) Error!void {
            const self = try App.get(@backingInt(a));
            const s = try runtime.string(p, n);
            const client = self.app.portals.get() orelse return error.Unavailable;
            portal.notification.remove(client, s) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unavailable;
        }
    }.f(app, id, id_len));
}

const ActionEntry = struct {
    self: *App,
    callback: t.ActionFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn run(ctx: ?*anyopaque, name: []const u8, target: []const u8, activation_token: []const u8) void {
        const e: *ActionEntry = @ptrCast(@alignCast(ctx));
        var ev: t.ActionEvent = .{
            .name = name.ptr,
            .name_len = name.len,
            .target = target.ptr,
            .target_len = target.len,
            .activation_token = activation_token.ptr,
            .activation_token_len = activation_token.len,
        };
        e.self.enter();
        defer e.self.leave();
        e.callback(e.user_data, &ev);
    }
};

pub export fn siv_app_add_action(app: t.App, name: ?[*]const u8, name_len: usize, callback: ?t.ActionFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return failed(null, destroy, user_data, err);
    const s = runtime.string(name, name_len) catch |err| return failed(self, destroy, user_data, err);
    const cb = callback orelse return failed(self, destroy, user_data, error.InvalidArgument);
    if (s.len == 0 or !std.unicode.utf8ValidateSlice(s)) return failed(self, destroy, user_data, error.InvalidArgument);
    const gpa = self.gpa();
    const st = &self.desktop;
    const entry = gpa.create(ActionEntry) catch return failed(self, destroy, user_data, error.OutOfMemory);
    entry.* = .{ .self = self, .callback = cb, .destroy = destroy, .user_data = user_data };
    st.actions.ensureUnusedCapacity(gpa, 1) catch {
        gpa.destroy(entry);
        return failed(self, destroy, user_data, error.OutOfMemory);
    };
    const key = if (st.actions.getKey(s)) |k| k else gpa.dupe(u8, s) catch {
        gpa.destroy(entry);
        return failed(self, destroy, user_data, error.OutOfMemory);
    };
    self.app.addAction(s, .{ .ctx = entry, .func = ActionEntry.run }) catch {
        if (st.actions.getKey(s) == null) gpa.free(key);
        gpa.destroy(entry);
        return failed(self, destroy, user_data, error.OutOfMemory);
    };
    const gop = st.actions.getOrPutAssumeCapacity(key);
    if (gop.found_existing) {
        const old = gop.value_ptr.*;
        self.release(old.destroy, old.user_data);
        gpa.destroy(old);
    }
    gop.value_ptr.* = entry;
    return .ok;
}

pub export fn siv_app_remove_action(app: t.App, name: ?[*]const u8, name_len: usize) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const s = runtime.string(name, name_len) catch |err| return t.resultOf(err);
    const kv = self.desktop.actions.fetchRemove(s) orelse return .error_invalid_argument;
    self.app.removeAction(s);
    self.release(kv.value.destroy, kv.value.user_data);
    self.gpa().free(kv.key);
    self.gpa().destroy(kv.value);
    return .ok;
}

// Inhibition --------------------------------------------------------------------

const Inhibition = struct {
    self: *App,
    handle: u64 = 0,
    flags: portal.inhibit.Flags,
    reason: []u8,
    parent: Parent = .{ .func = onParent },
    req: portal.Request = .{ .func = onResponse },
    started: bool = false,

    fn onParent(pa: *Parent, id: []const u8) void {
        const x: *Inhibition = @fieldParentPtr("parent", pa);
        const client = x.self.app.portals.get() orelse return;
        portal.inhibit.start(&x.req, client, id, x.flags, x.reason) catch return;
        x.started = true;
    }

    fn onResponse(_: *portal.Request, _: portal.Request.Outcome) void {
        // Nothing to report: the inhibition lasts until destroyed either way.
    }
};

pub export fn siv_inhibit(app: t.App, window: t.Window, flags: t.InhibitFlags, reason: ?[*]const u8, reason_len: usize, out: ?*t.Inhibition) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, wnd: t.Window, fl_raw: t.InhibitFlags, rp: ?[*]const u8, rn: usize, o: ?*t.Inhibition) Error!void {
            const self = try App.get(@backingInt(a));
            const fl = try runtime.flags(t.InhibitFlags, fl_raw);
            const r = try runtime.string(rp, rn);
            const dest = try runtime.out(t.Inhibition, o);
            if (@as(u32, @bitCast(fl)) == 0) return error.InvalidArgument;
            const win = try parentWindow(self, wnd);
            const gpa = self.gpa();
            const st = &self.desktop;
            const index = try st.inhibitions.reserve(gpa);
            try self.root.handles.ensureUnusedCapacity(gpa);
            const x = try gpa.create(Inhibition);
            errdefer gpa.destroy(x);
            x.* = .{ .self = self, .flags = .{ .logout = fl.logout, .user_switch = fl.user_switch, .suspend_ = fl.@"suspend", .idle = fl.idle }, .reason = try dupe(self, r) };
            x.handle = self.root.handles.insert(gpa, inhibition_tag, index) catch unreachable;
            st.inhibitions.items.items[index] = x;
            if (self.app.portals.get() != null) app_mod.portals.parentOf(self.app, win, &x.parent);
            dest.* = @fromBackingInt(x.handle);
        }
    }.f(app, window, flags, reason, reason_len, out));
}

fn destroyInhibition(self: *App, index: u32) void {
    const x = self.desktop.inhibitions.items.items[index].?;
    x.parent.cancel();
    // Closing the request ends the inhibition, answered or not.
    if (x.started) x.req.cancel();
    _ = self.root.handles.remove(x.handle, inhibition_tag) catch unreachable;
    self.desktop.inhibitions.items.items[index] = null;
    self.gpa().free(x.reason);
    self.gpa().destroy(x);
}

pub export fn siv_inhibition_destroy(inhibition: t.Inhibition) t.Result {
    const self, const index = runtime.Root.owner(App, application.app_tag, @backingInt(inhibition), inhibition_tag) catch |err| return t.resultOf(err);
    destroyInhibition(self, index);
    return .ok;
}

// The file chooser ----------------------------------------------------------------

const Chooser = struct {
    self: *App,
    handle: u64 = 0,
    /// Configuration strings and records.
    config: std.heap.ArenaAllocator,
    /// The last response's results.
    results: std.heap.ArenaAllocator,
    title: []const u8 = "",
    accept_label: []const u8 = "",
    current_name: []const u8 = "",
    current_folder: []const u8 = "",
    current_file: []const u8 = "",
    mode: portal.file_chooser.Mode = .open,
    flags: t.FileChooserFlags = .{},
    filters: std.ArrayList(FilterRec) = .empty,
    choices: std.ArrayList(ChoiceRec) = .empty,
    current_filter: ?u32 = null,
    // While shown.
    showing: bool = false,
    callback: ?t.PortalFn = null,
    destroy: ?t.DestroyFn = null,
    user_data: ?*anyopaque = null,
    window: ?*app_mod.Window = null,
    parent: Parent = .{ .func = onParent },
    req: portal.Request = .{ .func = onResponse },
    task: Loop.Task = .{ .func = onUnavailable },
    // Results.
    uris: std.ArrayList([]const u8) = .empty,
    chosen: std.ArrayList([2][]const u8) = .empty,
    selected_filter: i32 = -1,

    const FilterRec = struct { name: []const u8, patterns: std.ArrayList(portal.file_chooser.Pattern) = .empty };
    const ChoiceRec = struct { id: []const u8, label: []const u8, initial: []const u8, options: std.ArrayList(portal.file_chooser.ChoiceOption) = .empty };

    fn str(c: *Chooser, s: []const u8) Error![]const u8 {
        return c.config.allocator().dupe(u8, s);
    }

    fn onUnavailable(task: *Loop.Task) void {
        const c: *Chooser = @fieldParentPtr("task", task);
        c.complete(.{ .response = .unavailable });
    }

    fn onParent(pa: *Parent, id: []const u8) void {
        const c: *Chooser = @fieldParentPtr("parent", pa);
        c.start(id) catch |err| c.complete(.{ .response = failureOf(mapStart(err)) });
    }

    fn start(c: *Chooser, parent: []const u8) !void {
        const client = c.self.app.portals.get() orelse return error.Disconnected;
        var arena: std.heap.ArenaAllocator = .init(c.self.gpa());
        defer arena.deinit();
        const a = arena.allocator();
        const filters = try a.alloc(portal.file_chooser.Filter, c.filters.items.len);
        for (c.filters.items, filters) |rec, *f| f.* = .{ .name = rec.name, .patterns = rec.patterns.items };
        const choices = try a.alloc(portal.file_chooser.Choice, c.choices.items.len);
        for (c.choices.items, choices) |rec, *ch| ch.* = .{ .id = rec.id, .label = rec.label, .options = rec.options.items, .initial = rec.initial };
        try portal.file_chooser.start(&c.req, client, parent, .{
            .mode = c.mode,
            .title = c.title,
            .accept_label = c.accept_label,
            .modal = !c.flags.not_modal,
            .multiple = c.flags.multiple,
            .directory = c.flags.directory,
            .filters = filters,
            .current_filter = if (c.current_filter) |i| i else null,
            .choices = choices,
            .current_name = c.current_name,
            .current_folder = c.current_folder,
            .current_file = c.current_file,
        });
    }

    fn onResponse(r: *portal.Request, outcome: portal.Request.Outcome) void {
        const c: *Chooser = @fieldParentPtr("req", r);
        var response = responseOf(outcome);
        if (response == .success) c.keep(outcome.response.results) catch {
            response = .failed;
        };
        c.complete(.{ .response = response, .count = @intCast(c.uris.items.len) });
    }

    /// Copies the results the getters return.
    fn keep(c: *Chooser, results: portal.vardict.Reader) !void {
        const a = c.results.allocator();
        const res: portal.file_chooser.Results = .{ .r = results };
        if (res.uris()) |it_| {
            var it = it_;
            while (it.next()) |u| try c.uris.append(a, try a.dupe(u8, u));
        }
        for (c.choices.items) |ch| if (res.choice(ch.id)) |v| try c.chosen.append(a, .{ ch.id, try a.dupe(u8, v) });
        if (res.filterName()) |name| {
            for (c.filters.items, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) {
                c.selected_filter = @intCast(i);
                break;
            };
        }
    }

    fn complete(c: *Chooser, result: t.PortalResult) void {
        const self = c.self;
        c.showing = false;
        const cb, const destroy, const user_data = .{ c.callback, c.destroy, c.user_data };
        c.callback = null;
        c.destroy = null;
        callResult(self, cb, user_data, result);
        self.release(destroy, user_data);
    }

    /// Stops a shown dialog without running its callback.
    fn stop(c: *Chooser) void {
        if (!c.showing) return;
        c.parent.cancel();
        c.req.abandon();
        c.self.app.loop.unschedule(&c.task);
        c.showing = false;
        c.self.release(c.destroy, c.user_data);
        c.callback = null;
        c.destroy = null;
    }
};

fn chooserOf(handle: t.FileChooser) Error!struct { *App, u32, *Chooser } {
    const self, const index = try runtime.Root.owner(App, application.app_tag, @backingInt(handle), chooser_tag);
    return .{ self, index, self.desktop.choosers.items.items[index] orelse return error.InvalidHandle };
}

pub export fn siv_file_chooser_create(app: t.App, desc: ?*const t.FileChooserDesc, out: ?*t.FileChooser) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, dp: ?*const t.FileChooserDesc, o: ?*t.FileChooser) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.FileChooserDesc, dp);
            const mode = try runtime.enumValue(t.FileChooserMode, d.mode);
            const fl = try runtime.flags(t.FileChooserFlags, d.flags);
            const dest = try runtime.out(t.FileChooser, o);
            const strings = .{
                try runtime.string(d.title, d.title_len),
                try runtime.string(d.accept_label, d.accept_label_len),
                try runtime.string(d.current_name, d.current_name_len),
                try runtime.string(d.current_folder, d.current_folder_len),
                try runtime.string(d.current_file, d.current_file_len),
            };
            const gpa = self.gpa();
            const st = &self.desktop;
            const index = try st.choosers.reserve(gpa);
            try self.root.handles.ensureUnusedCapacity(gpa);
            const c = try gpa.create(Chooser);
            errdefer gpa.destroy(c);
            c.* = .{ .self = self, .config = .init(gpa), .results = .init(gpa), .mode = if (mode == .save) .save else .open, .flags = fl };
            errdefer c.config.deinit();
            c.title = try c.str(strings[0]);
            c.accept_label = try c.str(strings[1]);
            c.current_name = try c.str(strings[2]);
            c.current_folder = try c.str(strings[3]);
            c.current_file = try c.str(strings[4]);
            c.handle = self.root.handles.insert(gpa, chooser_tag, index) catch unreachable;
            st.choosers.items.items[index] = c;
            dest.* = @fromBackingInt(c.handle);
        }
    }.f(app, desc, out));
}

pub export fn siv_file_chooser_add_filter(chooser: t.FileChooser, name: ?[*]const u8, name_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.FileChooser, p: ?[*]const u8, n: usize) Error!void {
            _, _, const c = try chooserOf(h);
            const s = try runtime.string(p, n);
            try c.filters.append(c.config.allocator(), .{ .name = try c.str(s) });
        }
    }.f(chooser, name, name_len));
}

pub export fn siv_file_chooser_add_pattern(chooser: t.FileChooser, kind: t.FilePatternKind, pattern: ?[*]const u8, pattern_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.FileChooser, k: t.FilePatternKind, p: ?[*]const u8, n: usize) Error!void {
            _, _, const c = try chooserOf(h);
            const kd = try runtime.enumValue(t.FilePatternKind, k);
            const s = try runtime.string(p, n);
            if (c.filters.items.len == 0 or s.len == 0) return error.InvalidArgument;
            const rec = &c.filters.items[c.filters.items.len - 1];
            try rec.patterns.append(c.config.allocator(), .{ .kind = if (kd == .mime) .mime else .glob, .pattern = try c.str(s) });
        }
    }.f(chooser, kind, pattern, pattern_len));
}

pub export fn siv_file_chooser_set_current_filter(chooser: t.FileChooser, index: u32) t.Result {
    return application.wrap(struct {
        fn f(h: t.FileChooser, i: u32) Error!void {
            _, _, const c = try chooserOf(h);
            if (i >= c.filters.items.len) return error.InvalidArgument;
            c.current_filter = i;
        }
    }.f(chooser, index));
}

pub export fn siv_file_chooser_add_choice(chooser: t.FileChooser, id: ?[*]const u8, id_len: usize, label: ?[*]const u8, label_len: usize, initial: ?[*]const u8, initial_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.FileChooser, ip: ?[*]const u8, in: usize, lp: ?[*]const u8, ln: usize, vp: ?[*]const u8, vn: usize) Error!void {
            _, _, const c = try chooserOf(h);
            const i = try runtime.string(ip, in);
            const l = try runtime.string(lp, ln);
            const v = try runtime.string(vp, vn);
            if (i.len == 0) return error.InvalidArgument;
            try c.choices.append(c.config.allocator(), .{ .id = try c.str(i), .label = try c.str(l), .initial = try c.str(v) });
        }
    }.f(chooser, id, id_len, label, label_len, initial, initial_len));
}

pub export fn siv_file_chooser_add_choice_option(chooser: t.FileChooser, id: ?[*]const u8, id_len: usize, label: ?[*]const u8, label_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.FileChooser, ip: ?[*]const u8, in: usize, lp: ?[*]const u8, ln: usize) Error!void {
            _, _, const c = try chooserOf(h);
            const i = try runtime.string(ip, in);
            const l = try runtime.string(lp, ln);
            if (c.choices.items.len == 0 or i.len == 0) return error.InvalidArgument;
            const rec = &c.choices.items[c.choices.items.len - 1];
            try rec.options.append(c.config.allocator(), .{ .id = try c.str(i), .label = try c.str(l) });
        }
    }.f(chooser, id, id_len, label, label_len));
}

pub export fn siv_file_chooser_show(chooser: t.FileChooser, window: t.Window, callback: ?t.PortalFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    _, _, const c = chooserOf(chooser) catch |err| return failed(null, destroy, user_data, err);
    const self = c.self;
    if (c.showing) return failed(self, destroy, user_data, error.Busy);
    const win = parentWindow(self, window) catch |err| return failed(self, destroy, user_data, err);
    _ = c.results.reset(.retain_capacity);
    c.uris = .empty;
    c.chosen = .empty;
    c.selected_filter = -1;
    c.showing = true;
    c.callback = callback;
    c.destroy = destroy;
    c.user_data = user_data;
    c.window = win;
    if (self.app.portals.get() == null) {
        self.app.loop.schedule(&c.task, .dispatch);
    } else {
        app_mod.portals.parentOf(self.app, win, &c.parent);
    }
    return .ok;
}

pub export fn siv_file_chooser_cancel(chooser: t.FileChooser) t.Result {
    _, _, const c = chooserOf(chooser) catch |err| return t.resultOf(err);
    c.stop();
    return .ok;
}

pub export fn siv_file_chooser_get_uri_count(chooser: t.FileChooser, count: ?*u32) t.Result {
    _, _, const c = chooserOf(chooser) catch |err| return t.resultOf(err);
    const dest = runtime.out(u32, count) catch |err| return t.resultOf(err);
    dest.* = @intCast(c.uris.items.len);
    return .ok;
}

fn copyOut(s: []const u8, buffer: ?[*]u8, cap: usize, len: ?*usize) Error!void {
    const buf = try runtime.buffer(buffer, cap);
    const dest = try runtime.out(usize, len);
    const k = @min(s.len, buf.len);
    @memcpy(buf[0..k], s[0..k]);
    dest.* = s.len;
}

pub export fn siv_file_chooser_get_uri(chooser: t.FileChooser, index: u32, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.FileChooser, i: u32, b: ?[*]u8, cap: usize, l: ?*usize) Error!void {
            _, _, const c = try chooserOf(h);
            if (i >= c.uris.items.len) return error.InvalidArgument;
            try copyOut(c.uris.items[i], b, cap, l);
        }
    }.f(chooser, index, buffer, buffer_cap, len));
}

pub export fn siv_file_chooser_get_path(chooser: t.FileChooser, index: u32, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.FileChooser, i: u32, b: ?[*]u8, cap: usize, l: ?*usize) Error!void {
            _, _, const c = try chooserOf(h);
            if (i >= c.uris.items.len) return error.InvalidArgument;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = portal.uri.filePath(c.uris.items[i], &path_buf) orelse return error.Unsupported;
            try copyOut(path, b, cap, l);
        }
    }.f(chooser, index, buffer, buffer_cap, len));
}

pub export fn siv_file_chooser_get_choice(chooser: t.FileChooser, id: ?[*]const u8, id_len: usize, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.FileChooser, ip: ?[*]const u8, in: usize, b: ?[*]u8, cap: usize, l: ?*usize) Error!void {
            _, _, const c = try chooserOf(h);
            const s = try runtime.string(ip, in);
            for (c.chosen.items) |kv| if (std.mem.eql(u8, kv[0], s)) return copyOut(kv[1], b, cap, l);
            return error.InvalidArgument;
        }
    }.f(chooser, id, id_len, buffer, buffer_cap, len));
}

pub export fn siv_file_chooser_get_filter(chooser: t.FileChooser, index: ?*i32) t.Result {
    _, _, const c = chooserOf(chooser) catch |err| return t.resultOf(err);
    const dest = runtime.out(i32, index) catch |err| return t.resultOf(err);
    dest.* = c.selected_filter;
    return .ok;
}

fn destroyChooser(self: *App, index: u32) void {
    const c = self.desktop.choosers.items.items[index].?;
    c.stop();
    _ = self.root.handles.remove(c.handle, chooser_tag) catch unreachable;
    self.desktop.choosers.items.items[index] = null;
    c.config.deinit();
    c.results.deinit();
    self.gpa().destroy(c);
}

pub export fn siv_file_chooser_destroy(chooser: t.FileChooser) t.Result {
    const self, const index, _ = chooserOf(chooser) catch |err| return t.resultOf(err);
    destroyChooser(self, index);
    return .ok;
}

// Global shortcuts --------------------------------------------------------------------

const Shortcuts = struct {
    self: *App,
    handle: u64 = 0,
    on_event: ?t.GlobalShortcutFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(portal.global_shortcuts.Shortcut) = .empty,
    /// Triggers by shortcut index, as the desktop last described them.
    triggers: std.ArrayList([]const u8) = .empty,
    gs: portal.global_shortcuts.GlobalShortcuts = .{ .func = onEvent },
    parent: Parent = .{ .func = onParent },
    binding: bool = false,

    fn emit(s: *Shortcuts, ev: t.GlobalShortcutEvent) void {
        const f = s.on_event orelse return;
        var e = ev;
        s.self.enter();
        defer s.self.leave();
        f(s.user_data, @fromBackingInt(s.handle), &e);
    }

    fn onParent(pa: *Parent, id: []const u8) void {
        const s: *Shortcuts = @fieldParentPtr("parent", pa);
        const client = s.self.app.portals.get() orelse return s.bindFailed(.unavailable);
        if (s.gs.stage == .done) s.gs = .{ .func = onEvent };
        s.gs.bind(client, id, s.list.items) catch return s.bindFailed(.failed);
    }

    fn bindFailed(s: *Shortcuts, r: t.PortalResponse) void {
        s.binding = false;
        s.emit(.{ .type = .bound, .response = r });
    }

    fn readTriggers(s: *Shortcuts, it_: portal.global_shortcuts.BoundIterator) void {
        var it = it_;
        while (it.next()) |b| {
            for (s.list.items, 0..) |sc, i| if (std.mem.eql(u8, sc.id, b.id)) {
                s.triggers.items[i] = s.arena.allocator().dupe(u8, b.trigger) catch "";
            };
        }
    }

    fn onEvent(g: *portal.global_shortcuts.GlobalShortcuts, ev: portal.global_shortcuts.Event) void {
        const s: *Shortcuts = @fieldParentPtr("gs", g);
        switch (ev) {
            .bound => |it| {
                s.readTriggers(it);
                s.binding = false;
                s.emit(.{ .type = .bound, .response = .success });
            },
            .changed => |it| {
                s.readTriggers(it);
                s.emit(.{ .type = .changed });
            },
            .ended => |code| s.bindFailed(switch (code) {
                .success => .success,
                .cancelled => .cancelled,
                .other => .ended,
            }),
            .failed => |f| s.bindFailed(failureOf(f)),
            .activated => |a| s.emit(.{ .type = .activated, .id = a.id.ptr, .id_len = a.id.len, .timestamp_ms = a.timestamp_ms }),
            .deactivated => |a| s.emit(.{ .type = .deactivated, .id = a.id.ptr, .id_len = a.id.len, .timestamp_ms = a.timestamp_ms }),
            .closed => s.emit(.{ .type = .closed }),
        }
    }
};

fn shortcutsOf(handle: t.GlobalShortcuts) Error!struct { *App, u32, *Shortcuts } {
    const self, const index = try runtime.Root.owner(App, application.app_tag, @backingInt(handle), shortcuts_tag);
    return .{ self, index, self.desktop.shortcuts.items.items[index] orelse return error.InvalidHandle };
}

pub export fn siv_global_shortcuts_create(app: t.App, desc: ?*const t.GlobalShortcutsDesc, out: ?*t.GlobalShortcuts) t.Result {
    const d = runtime.readDesc(t.GlobalShortcutsDesc, desc) catch |err| return t.resultOf(err);
    const self = App.get(@backingInt(app)) catch |err| return failed(null, d.destroy, d.user_data, err);
    const r = struct {
        fn f(s: *App, dd: t.GlobalShortcutsDesc, o: ?*t.GlobalShortcuts) Error!void {
            const dest = try runtime.out(t.GlobalShortcuts, o);
            const gpa = s.gpa();
            const st = &s.desktop;
            const index = try st.shortcuts.reserve(gpa);
            try s.root.handles.ensureUnusedCapacity(gpa);
            const x = try gpa.create(Shortcuts);
            x.* = .{ .self = s, .on_event = dd.on_event, .destroy = dd.destroy, .user_data = dd.user_data, .arena = .init(gpa) };
            x.handle = s.root.handles.insert(gpa, shortcuts_tag, index) catch unreachable;
            st.shortcuts.items.items[index] = x;
            dest.* = @fromBackingInt(x.handle);
        }
    }.f(self, d, out);
    r catch |err| return failed(self, d.destroy, d.user_data, err);
    return .ok;
}

pub export fn siv_global_shortcuts_add(shortcuts: t.GlobalShortcuts, id: ?[*]const u8, id_len: usize, description: ?[*]const u8, description_len: usize, preferred_trigger: ?[*]const u8, preferred_trigger_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.GlobalShortcuts, ip: ?[*]const u8, in: usize, dp: ?[*]const u8, dn: usize, pp: ?[*]const u8, pn: usize) Error!void {
            _, _, const s = try shortcutsOf(h);
            if (s.binding) return error.Busy;
            const i = try runtime.string(ip, in);
            const d = try runtime.string(dp, dn);
            const pt = try runtime.string(pp, pn);
            if (i.len == 0) return error.InvalidArgument;
            for (s.list.items) |sc| if (std.mem.eql(u8, sc.id, i)) return error.InvalidArgument;
            const a = s.arena.allocator();
            try s.triggers.ensureUnusedCapacity(a, 1);
            try s.list.append(a, .{ .id = try a.dupe(u8, i), .description = try a.dupe(u8, d), .preferred_trigger = try a.dupe(u8, pt) });
            s.triggers.appendAssumeCapacity("");
        }
    }.f(shortcuts, id, id_len, description, description_len, preferred_trigger, preferred_trigger_len));
}

pub export fn siv_global_shortcuts_bind(shortcuts: t.GlobalShortcuts, window: t.Window) t.Result {
    return application.wrap(struct {
        fn f(h: t.GlobalShortcuts, wnd: t.Window) Error!void {
            const self, _, const s = try shortcutsOf(h);
            if (s.binding) return error.Busy;
            if (s.list.items.len == 0) return error.InvalidArgument;
            const win = try parentWindow(self, wnd);
            if (self.app.portals.get() == null) return error.Unavailable;
            s.binding = true;
            app_mod.portals.parentOf(self.app, win, &s.parent);
        }
    }.f(shortcuts, window));
}

pub export fn siv_global_shortcuts_get_trigger(shortcuts: t.GlobalShortcuts, id: ?[*]const u8, id_len: usize, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.GlobalShortcuts, ip: ?[*]const u8, in: usize, b: ?[*]u8, cap: usize, l: ?*usize) Error!void {
            _, _, const s = try shortcutsOf(h);
            const i = try runtime.string(ip, in);
            for (s.list.items, 0..) |sc, k| if (std.mem.eql(u8, sc.id, i)) return copyOut(s.triggers.items[k], b, cap, l);
            return error.InvalidArgument;
        }
    }.f(shortcuts, id, id_len, buffer, buffer_cap, len));
}

fn destroyShortcuts(self: *App, index: u32) void {
    const s = self.desktop.shortcuts.items.items[index].?;
    s.parent.cancel();
    s.gs.close();
    _ = self.root.handles.remove(s.handle, shortcuts_tag) catch unreachable;
    self.desktop.shortcuts.items.items[index] = null;
    self.release(s.destroy, s.user_data);
    s.arena.deinit();
    self.gpa().destroy(s);
}

pub export fn siv_global_shortcuts_destroy(shortcuts: t.GlobalShortcuts) t.Result {
    const self, const index, _ = shortcutsOf(shortcuts) catch |err| return t.resultOf(err);
    destroyShortcuts(self, index);
    return .ok;
}

// Screen casts -------------------------------------------------------------------------

const Cast = struct {
    self: *App,
    handle: u64 = 0,
    on_event: ?t.ScreencastFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    options: portal.screencast.Options,
    token_buf: [portal.screencast.max_token]u8 = undefined,
    sc: portal.screencast.ScreenCast = .{ .func = onEvent },
    parent: Parent = .{ .func = onParent },
    task: Loop.Task = .{ .func = onUnavailable },

    fn emit(c: *Cast, ev: t.ScreencastEvent) void {
        const f = c.on_event orelse return;
        var e = ev;
        c.self.enter();
        defer c.self.leave();
        f(c.user_data, @fromBackingInt(c.handle), &e);
    }

    fn onUnavailable(task: *Loop.Task) void {
        const c: *Cast = @fieldParentPtr("task", task);
        c.emit(.{ .type = .started, .response = .unavailable });
    }

    fn onParent(pa: *Parent, id: []const u8) void {
        const c: *Cast = @fieldParentPtr("parent", pa);
        const client = c.self.app.portals.get() orelse return c.emit(.{ .type = .started, .response = .unavailable });
        c.sc.start(client, id, c.options) catch c.emit(.{ .type = .started, .response = .failed });
    }

    fn onEvent(sc: *portal.screencast.ScreenCast, ev: portal.screencast.Event) void {
        const c: *Cast = @fieldParentPtr("sc", sc);
        switch (ev) {
            .started => c.emit(.{ .type = .started, .response = .success }),
            .ended => |code| c.emit(.{ .type = .started, .response = switch (code) {
                .success => .success,
                .cancelled => .cancelled,
                .other => .ended,
            } }),
            .failed => |f| c.emit(.{ .type = .started, .response = failureOf(f) }),
            .closed => c.emit(.{ .type = .closed }),
        }
    }
};

fn castOf(handle: t.Screencast) Error!struct { *App, u32, *Cast } {
    const self, const index = try runtime.Root.owner(App, application.app_tag, @backingInt(handle), screencast_tag);
    return .{ self, index, self.desktop.casts.items.items[index] orelse return error.InvalidHandle };
}

pub export fn siv_screencast_start(app: t.App, window: t.Window, desc: ?*const t.ScreencastDesc, out: ?*t.Screencast) t.Result {
    const d = runtime.readDesc(t.ScreencastDesc, desc) catch |err| return t.resultOf(err);
    const self = App.get(@backingInt(app)) catch |err| return failed(null, d.destroy, d.user_data, err);
    const r = struct {
        fn f(s: *App, wnd: t.Window, dd: t.ScreencastDesc, o: ?*t.Screencast) Error!void {
            const dest = try runtime.out(t.Screencast, o);
            const token = try runtime.string(dd.restore_token, dd.restore_token_len);
            const sources = try runtime.flags(t.ScreencastSources, dd.sources);
            const cursor = try runtime.enumValue(t.ScreencastCursor, dd.cursor);
            const persist = try runtime.enumValue(t.ScreencastPersist, dd.persist);
            const fl = try runtime.flags(t.ScreencastFlags, dd.flags);
            if (token.len > portal.screencast.max_token) return error.InvalidArgument;
            const win = try parentWindow(s, wnd);
            const gpa = s.gpa();
            const st = &s.desktop;
            const index = try st.casts.reserve(gpa);
            try s.root.handles.ensureUnusedCapacity(gpa);
            const c = try gpa.create(Cast);
            const none = @as(u32, @bitCast(sources)) == 0;
            c.* = .{
                .self = s,
                .on_event = dd.on_event,
                .destroy = dd.destroy,
                .user_data = dd.user_data,
                .options = .{
                    .types = .{ .monitor = sources.monitor or none, .window = sources.window, .virtual = sources.virtual },
                    .multiple = fl.multiple,
                    .cursor_mode = switch (cursor) {
                        .default => .default,
                        .hidden => .hidden,
                        .embedded => .embedded,
                        .metadata => .metadata,
                        _ => unreachable,
                    },
                    .persist_mode = switch (persist) {
                        .none => .none,
                        .transient => .transient,
                        .persistent => .persistent,
                        _ => unreachable,
                    },
                },
            };
            @memcpy(c.token_buf[0..token.len], token);
            c.options.restore_token = c.token_buf[0..token.len];
            c.handle = s.root.handles.insert(gpa, screencast_tag, index) catch unreachable;
            st.casts.items.items[index] = c;
            dest.* = @fromBackingInt(c.handle);
            if (s.app.portals.get() == null) s.app.loop.schedule(&c.task, .dispatch) else app_mod.portals.parentOf(s.app, win, &c.parent);
        }
    }.f(self, window, d, out);
    r catch |err| return failed(self, d.destroy, d.user_data, err);
    return .ok;
}

pub export fn siv_screencast_get_stream_count(screencast: t.Screencast, count: ?*u32) t.Result {
    _, _, const c = castOf(screencast) catch |err| return t.resultOf(err);
    const dest = runtime.out(u32, count) catch |err| return t.resultOf(err);
    dest.* = @intCast(c.sc.streams().len);
    return .ok;
}

pub export fn siv_screencast_get_stream(screencast: t.Screencast, index: u32, stream: ?*t.ScreencastStream) t.Result {
    _, _, const c = castOf(screencast) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.ScreencastStream, stream) catch |err| return t.resultOf(err);
    const streams = c.sc.streams();
    if (index >= streams.len) return .error_invalid_argument;
    const s = streams[index];
    dest.* = .{ .node_id = s.node_id, .sources = @bitCast(s.source_type & 7), .x = s.x, .y = s.y, .width = s.width, .height = s.height };
    return .ok;
}

pub export fn siv_screencast_get_restore_token(screencast: t.Screencast, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    _, _, const c = castOf(screencast) catch |err| return t.resultOf(err);
    copyOut(if (c.sc.stage == .idle) "" else c.sc.restoreToken(), buffer, buffer_cap, len) catch |err| return t.resultOf(err);
    return .ok;
}

pub export fn siv_screencast_take_pipewire_fd(screencast: t.Screencast, fd: ?*i32) t.Result {
    _, _, const c = castOf(screencast) catch |err| return t.resultOf(err);
    const dest = runtime.out(i32, fd) catch |err| return t.resultOf(err);
    dest.* = c.sc.takePipewireFd() orelse return .error_invalid_argument;
    return .ok;
}

fn destroyCast(self: *App, index: u32) void {
    const c = self.desktop.casts.items.items[index].?;
    c.parent.cancel();
    self.app.loop.unschedule(&c.task);
    if (c.sc.stage != .idle) c.sc.close();
    _ = self.root.handles.remove(c.handle, screencast_tag) catch unreachable;
    self.desktop.casts.items.items[index] = null;
    self.release(c.destroy, c.user_data);
    self.gpa().destroy(c);
}

pub export fn siv_screencast_destroy(screencast: t.Screencast) t.Result {
    const self, const index, _ = castOf(screencast) catch |err| return t.resultOf(err);
    destroyCast(self, index);
    return .ok;
}

// Lifecycle -----------------------------------------------------------------------

fn onActivate(ctx: ?*anyopaque, a: *const app_mod.lifecycle.Activation) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const l = self.desktop.launch orelse return;
    const f = l.on_activate orelse return;
    var buf: [64]t.Uri = undefined;
    const n = @min(a.uris.len, buf.len);
    var list: std.ArrayList(t.Uri) = .empty;
    defer list.deinit(self.gpa());
    const uris: []t.Uri = if (a.uris.len <= buf.len) buf[0..n] else blk: {
        list.resize(self.gpa(), a.uris.len) catch break :blk buf[0..n];
        break :blk list.items;
    };
    for (uris, a.uris[0..uris.len]) |*u, s| u.* = .{ .uri = s.ptr, .uri_len = s.len };
    var ev: t.Activation = .{
        .uris = uris.ptr,
        .uris_count = uris.len,
        .activation_token = a.token.ptr,
        .activation_token_len = a.token.len,
        .type = if (a.kind == .open) .open else .activate,
        .source = if (a.remote) .remote else .launch,
    };
    self.enter();
    defer self.leave();
    f(l.user_data, @fromBackingInt(self.root.handle), &ev);
}

pub export fn siv_app_launch(app: t.App, desc: ?*const t.LaunchDesc) t.Result {
    const d = runtime.readDesc(t.LaunchDesc, desc) catch |err| return t.resultOf(err);
    const self = App.get(@backingInt(app)) catch |err| return failed(null, d.destroy, d.user_data, err);
    const r = struct {
        fn f(s: *App, dd: t.LaunchDesc) Error!void {
            if (s.painting != 0 or s.desktop.launch != null) return error.Busy;
            const raw = try runtime.array(t.Uri, dd.uris, dd.uris_count);
            const fl = try runtime.flags(t.LaunchFlags, dd.flags);
            const gpa = s.gpa();
            const uris = try gpa.alloc([]const u8, raw.len);
            defer gpa.free(uris);
            for (raw, uris) |ru, *u| u.* = try runtime.string(ru.uri, ru.uri_len);
            s.desktop.launch = .{ .on_activate = dd.on_activate, .destroy = dd.destroy, .user_data = dd.user_data };
            errdefer s.desktop.launch = null;
            s.app.launch(.{ .uris = uris, .service = fl.service, .multiple_instances = fl.multiple_instances, .idle_timeout_ms = dd.idle_timeout_ms }, .{ .ctx = s, .func = onActivate }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Busy => error.Busy,
            };
        }
    }.f(self, d);
    r catch |err| return failed(self, d.destroy, d.user_data, err);
    return .ok;
}

pub export fn siv_app_get_instance(app: t.App, instance: ?*t.Instance) t.Result {
    const self = App.get(@backingInt(app)) catch |err| return t.resultOf(err);
    const dest = runtime.out(t.Instance, instance) catch |err| return t.resultOf(err);
    dest.* = switch (self.app.lifecycle.role) {
        .none => .none,
        .pending => .pending,
        .primary => .primary,
        .secondary => .secondary,
    };
    return .ok;
}

pub export fn siv_window_activate(window: t.Window, token: ?[*]const u8, token_len: usize) t.Result {
    const w = App.window(@backingInt(window), application.window_tag) catch |err| return t.resultOf(err);
    const s = runtime.string(token, token_len) catch |err| return t.resultOf(err);
    w.win.activate(s) catch return .error_out_of_memory;
    return .ok;
}

pub export fn siv_window_request_activation_token(window: t.Window, callback: ?t.PortalFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const w = App.window(@backingInt(window), application.window_tag) catch |err| return failed(null, destroy, user_data, err);
    const self = w.owner;
    const o = newOp(self, .token, window, callback, destroy, user_data) catch |err| return failed(self, destroy, user_data, err);
    launch(o);
    return .ok;
}
