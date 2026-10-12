//! Exports for the system tray (D19): one StatusNotifierItem per
//! application (the `tray` module) on its session bus connection. Events
//! reach the C callback at safe points: the connection dispatches them in
//! the loop's dispatch phase (D5).

const std = @import("std");
const t = @import("siv");
const tray = @import("tray");
const ui = @import("ui");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const canvas = @import("canvas.zig");
const api = @import("api.zig");

const App = application.App;
const Error = application.Error;

pub const tray_tag = api.spec.handleTag("siv_tray_item");

pub const State = struct {
    item: ?*Tray = null,
};

const Tray = struct {
    self: *App,
    handle: u64 = 0,
    item: tray.Item,
    on_event: ?t.TrayFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn onEvent(it: *tray.Item, ev: tray.Item.Event) void {
        const x: *Tray = @fieldParentPtr("item", it);
        const f = x.on_event orelse return;
        var e: t.TrayEvent = switch (ev) {
            .registered => .{ .type = .registered },
            .unregistered => .{ .type = .unregistered },
            .activate => |a| .{ .type = .activate, .x = a.x, .y = a.y, .activation_token = a.token.ptr, .activation_token_len = a.token.len },
            .secondary_activate => |a| .{ .type = .secondary_activate, .x = a.x, .y = a.y },
            .context_menu => |a| .{ .type = .context_menu, .x = a.x, .y = a.y },
            .scroll => |s| .{ .type = .scroll, .delta = s.delta, .flags = .{ .horizontal = s.horizontal } },
            .menu => |id| .{ .type = .menu, .menu_item = @intCast(id) },
        };
        x.self.enter();
        defer x.self.leave();
        f(x.user_data, @fromBackingInt(x.handle), &e);
    }
};

pub fn teardown(self: *App) void {
    if (self.desktop.tray.item) |x| destroy(self, x);
}

fn destroy(self: *App, x: *Tray) void {
    x.item.deinit();
    _ = self.root.handles.remove(x.handle, tray_tag) catch unreachable;
    self.desktop.tray.item = null;
    self.release(x.destroy, x.user_data);
    self.gpa().destroy(x);
}

fn trayOf(handle: t.TrayItem) Error!*Tray {
    const self, _ = try runtime.Root.owner(App, application.app_tag, @backingInt(handle), tray_tag);
    return self.desktop.tray.item orelse error.InvalidHandle;
}

fn mapErr(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArgument => error.InvalidArgument,
        else => error.Unavailable,
    };
}

pub export fn siv_tray_item_create(app: t.App, desc: ?*const t.TrayItemDesc, out: ?*t.TrayItem) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, dp: ?*const t.TrayItemDesc, o: ?*t.TrayItem) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.TrayItemDesc, dp);
            const dest = try runtime.out(t.TrayItem, o);
            var id = try runtime.string(d.id, d.id_len);
            const title = try runtime.string(d.title, d.title_len);
            const icon = try runtime.string(d.icon_name, d.icon_name_len);
            const category = try runtime.enumValue(t.TrayCategory, d.category);
            const fl = try runtime.flags(t.TrayFlags, d.flags);
            if (self.desktop.tray.item != null) return error.Busy;
            const client = self.app.portals.get() orelse return error.Unavailable;
            if (id.len == 0) id = self.app.app_id.slice();
            if (id.len == 0) return error.InvalidArgument;
            const gpa = self.gpa();
            try self.root.handles.ensureUnusedCapacity(gpa);
            const x = try gpa.create(Tray);
            errdefer gpa.destroy(x);
            x.* = .{ .self = self, .item = .init(gpa, Tray.onEvent), .on_event = d.on_event, .destroy = d.destroy, .user_data = d.user_data };
            x.item.start(client.conn, .{
                .id = id,
                .title = title,
                .icon_name = icon,
                .item_is_menu = fl.item_is_menu,
                .category = switch (category) {
                    .application_status => .application_status,
                    .communications => .communications,
                    .system_services => .system_services,
                    .hardware => .hardware,
                    _ => unreachable,
                },
            }) catch |err| {
                x.item.deinit();
                return mapErr(err);
            };
            x.handle = self.root.handles.insert(gpa, tray_tag, 0) catch unreachable;
            self.desktop.tray.item = x;
            dest.* = @fromBackingInt(x.handle);
        }
    }.f(app, desc, out));
}

pub export fn siv_tray_item_set_title(item: t.TrayItem, title: ?[*]const u8, title_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.TrayItem, p: ?[*]const u8, n: usize) Error!void {
            const x = try trayOf(h);
            try x.item.setTitle(try runtime.string(p, n));
        }
    }.f(item, title, title_len));
}

pub export fn siv_tray_item_set_status(item: t.TrayItem, status: t.TrayStatus) t.Result {
    return application.wrap(struct {
        fn f(h: t.TrayItem, s: t.TrayStatus) Error!void {
            const x = try trayOf(h);
            x.item.setStatus(switch (try runtime.enumValue(t.TrayStatus, s)) {
                .active => .active,
                .passive => .passive,
                .needs_attention => .needs_attention,
                _ => unreachable,
            });
        }
    }.f(item, status));
}

/// An image as the specification's ARGB32 in network byte order.
fn pixmapOf(gpa: std.mem.Allocator, img: *ui.Image) Error![]u8 {
    const w = img.width;
    const h = img.height;
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(out);
    for (0..h) |y| for (0..w) |x| {
        const p = img.pixels[y * img.stride + x * 4 ..][0..4];
        const o = out[(y * w + x) * 4 ..][0..4];
        o.* = switch (img.format) {
            .rgba8_srgb => .{ p[3], p[0], p[1], p[2] },
            .bgra8_srgb => .{ p[3], p[2], p[1], p[0] },
            .bgrx8_srgb => .{ 255, p[2], p[1], p[0] },
            else => return error.Unsupported,
        };
    };
    return out;
}

fn setIcon(h: t.TrayItem, name_ptr: ?[*]const u8, name_len: usize, image: t.Image, comptime attention: bool) Error!void {
    const x = try trayOf(h);
    const name = try runtime.string(name_ptr, name_len);
    const gpa = x.self.gpa();
    var argb: []u8 = &.{};
    defer gpa.free(argb);
    var pixmap: ?tray.Item.Pixmap = null;
    if (image != .null) {
        const img = try canvas.imageOf(x.self, image);
        if (img.width > std.math.maxInt(i32) or img.height > std.math.maxInt(i32)) return error.InvalidArgument;
        argb = try pixmapOf(gpa, img);
        pixmap = .{ .width = @intCast(img.width), .height = @intCast(img.height), .argb = argb };
    }
    (if (attention) x.item.setAttentionIcon(name, pixmap) else x.item.setIcon(name, pixmap)) catch |err| return mapErr(err);
}

pub export fn siv_tray_item_set_icon(item: t.TrayItem, icon_name: ?[*]const u8, icon_name_len: usize, image: t.Image) t.Result {
    return application.wrap(setIcon(item, icon_name, icon_name_len, image, false));
}

pub export fn siv_tray_item_set_attention_icon(item: t.TrayItem, icon_name: ?[*]const u8, icon_name_len: usize, image: t.Image) t.Result {
    return application.wrap(setIcon(item, icon_name, icon_name_len, image, true));
}

pub export fn siv_tray_item_set_tooltip(item: t.TrayItem, title: ?[*]const u8, title_len: usize, body: ?[*]const u8, body_len: usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.TrayItem, tp: ?[*]const u8, tn: usize, bp: ?[*]const u8, bn: usize) Error!void {
            const x = try trayOf(h);
            try x.item.setToolTip(try runtime.string(tp, tn), try runtime.string(bp, bn));
        }
    }.f(item, title, title_len, body, body_len));
}

pub export fn siv_tray_item_set_menu_item(item: t.TrayItem, desc: ?*const t.TrayMenuItemDesc) t.Result {
    return application.wrap(struct {
        fn f(h: t.TrayItem, dp: ?*const t.TrayMenuItemDesc) Error!void {
            const x = try trayOf(h);
            const d = try runtime.readDesc(t.TrayMenuItemDesc, dp);
            const kind = try runtime.enumValue(t.TrayMenuItemKind, d.kind);
            const fl = try runtime.flags(t.TrayMenuItemFlags, d.flags);
            if (d.id == 0 or d.id > std.math.maxInt(i32) or d.parent > std.math.maxInt(i32)) return error.InvalidArgument;
            x.item.menu.set(.{
                .id = @intCast(d.id),
                .parent = @intCast(d.parent),
                .label = try runtime.string(d.label, d.label_len),
                .icon_name = try runtime.string(d.icon_name, d.icon_name_len),
                .kind = switch (kind) {
                    .normal => .normal,
                    .separator => .separator,
                    .check => .check,
                    .radio => .radio,
                    _ => unreachable,
                },
                .enabled = !fl.disabled,
                .visible = !fl.hidden,
                .checked = fl.checked,
            }) catch |err| return mapErr(err);
        }
    }.f(item, desc));
}

pub export fn siv_tray_item_remove_menu_item(item: t.TrayItem, id: u32) t.Result {
    const x = trayOf(item) catch |err| return t.resultOf(err);
    if (id != 0 and id <= std.math.maxInt(i32)) x.item.menu.remove(@intCast(id));
    return .ok;
}

pub export fn siv_tray_item_destroy(item: t.TrayItem) t.Result {
    const x = trayOf(item) catch |err| return t.resultOf(err);
    destroy(x.self, x);
    return .ok;
}
