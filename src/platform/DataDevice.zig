//! A seat's clipboard (wl_data_device) and primary selection
//! (zwp_primary_selection_device_v1), D19. Offers collect their mime types
//! until the device announces them as the selection; this client's sources
//! forward send requests as `selection_send` events with the fd, which the
//! UI writes and closes.
//!
//! Drag and drop: an offer that enters one of this client's surfaces is the
//! seat's drag, named by an id in its events, until it leaves or, after a
//! drop, until the UI finishes it (a compositor may report the drag
//! leaving after the drop; the offer stays). This client's drags are
//! sources with an optional icon surface; data requests and progress go
//! to the UI as events. While this client's own drag is under way, an
//! offer that enters is that drag (one drag per seat at a time).

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland").client.wl;
const zwp = @import("wayland").client.zwp;
const platform = @import("platform.zig");
const Wayland = @import("Wayland.zig");
const DataDevice = @This();

const Kind = platform.SelectionKind;

backend: *Wayland,
seat: platform.SeatId,
device: ?*wl.DataDevice = null,
primary: ?*zwp.PrimarySelectionDeviceV1 = null,
/// Offers announced but not yet the selection.
pending: std.ArrayList(*Offer) = .empty,
current: [2]?*Offer = .{ null, null },
sources: [2]?*Source = .{ null, null },
next_source: u32 = 0,
drag: ?Drag = null,
next_drag: u32 = 0,
drag_source: ?*DragSource = null,

/// The offer over one of this client's surfaces.
const Drag = struct {
    /// Null for a drag without a source (never this client's own).
    offer: ?*Offer,
    id: u32,
    /// Of the enter event; wl_data_offer.accept needs it.
    serial: u32,
    window: platform.WindowId,
    dropped: bool = false,
};

const Offer = struct {
    kind: Kind,
    proxy: union(enum) { clipboard: *wl.DataOffer, primary: *zwp.PrimarySelectionOfferV1 },
    mimes: std.ArrayList([]const u8) = .empty,
    dev: *DataDevice,
    source_actions: platform.DragActions = .{},
    action: platform.DragAction = .none,

    fn destroy(o: *Offer) void {
        const gpa = o.dev.backend.allocator;
        switch (o.proxy) {
            inline else => |p| p.destroy(),
        }
        for (o.mimes.items) |m| gpa.free(m);
        o.mimes.deinit(gpa);
        gpa.destroy(o);
    }

    fn addMime(o: *Offer, mime: [*:0]const u8) void {
        const gpa = o.dev.backend.allocator;
        const copy = gpa.dupe(u8, std.mem.span(mime)) catch return o.dev.backend.queue.fail(error.OutOfMemory);
        o.mimes.append(gpa, copy) catch {
            gpa.free(copy);
            o.dev.backend.queue.fail(error.OutOfMemory);
        };
    }
};

const Source = struct {
    kind: Kind,
    id: u32,
    proxy: union(enum) { clipboard: *wl.DataSource, primary: *zwp.PrimarySelectionSourceV1 },
    mimes: std.ArrayList([]const u8) = .empty,
    dev: *DataDevice,

    fn destroy(s: *Source) void {
        const gpa = s.dev.backend.allocator;
        switch (s.proxy) {
            inline else => |p| p.destroy(),
        }
        for (s.mimes.items) |m| gpa.free(m);
        s.mimes.deinit(gpa);
        gpa.destroy(s);
    }

    fn send(s: *Source, mime: [*:0]const u8, fd: i32) void {
        const m = std.mem.span(mime);
        for (s.mimes.items, 0..) |own, i| if (std.mem.eql(u8, own, m)) {
            s.dev.backend.queue.push(.{ .selection_send = .{ .seat = s.dev.seat, .kind = s.kind, .source = s.id, .mime = @intCast(i), .fd = fd } });
            return;
        };
        _ = linux.close(fd);
    }

    fn cancel(s: *Source) void {
        const dev = s.dev;
        dev.backend.queue.push(.{ .selection_cancelled = .{ .seat = dev.seat, .kind = s.kind, .source = s.id } });
        if (dev.sources[@intFromEnum(s.kind)] == s) dev.sources[@intFromEnum(s.kind)] = null;
        s.destroy();
    }
};

pub fn create(backend: *Wayland, seat: platform.SeatId) !*DataDevice {
    const dev = try backend.allocator.create(DataDevice);
    dev.* = .{ .backend = backend, .seat = seat };
    return dev;
}

/// Gets the devices for managers that are bound (called again as they
/// appear).
pub fn bind(dev: *DataDevice, seat_proxy: *wl.Seat) void {
    const b = dev.backend;
    if (dev.device == null) if (b.data_device_manager) |m| {
        dev.device = m.getDataDevice(seat_proxy) catch return b.queue.fail(error.OutOfMemory);
        dev.device.?.setListener(*DataDevice, onDevice, dev);
    };
    if (dev.primary == null) if (b.primary_selection_manager) |m| {
        dev.primary = m.getDevice(seat_proxy) catch return b.queue.fail(error.OutOfMemory);
        dev.primary.?.setListener(*DataDevice, onPrimary, dev);
    };
}

pub fn destroy(dev: *DataDevice) void {
    for (dev.pending.items) |o| o.destroy();
    dev.pending.deinit(dev.backend.allocator);
    for (dev.current) |o| if (o) |offer| offer.destroy();
    for (dev.sources) |s| if (s) |src| src.destroy();
    dev.endDrag();
    if (dev.drag_source) |s| s.destroy();
    if (dev.device) |d| if (d.getVersion() >= 2) d.release() else d.destroy();
    if (dev.primary) |p| p.destroy();
    dev.backend.allocator.destroy(dev);
}

fn adopt(dev: *DataDevice, o: *Offer) void {
    dev.pending.append(dev.backend.allocator, o) catch {
        o.destroy();
        dev.backend.queue.fail(error.OutOfMemory);
    };
}

/// Removes a pending offer by proxy and returns it.
fn take(dev: *DataDevice, proxy: anytype) ?*Offer {
    for (dev.pending.items, 0..) |o, i| {
        const match = switch (o.proxy) {
            inline else => |p| @intFromPtr(p) == @intFromPtr(proxy),
        };
        if (match) return dev.pending.swapRemove(i);
    }
    return null;
}

fn setCurrent(dev: *DataDevice, kind: Kind, o: ?*Offer) void {
    const slot = &dev.current[@intFromEnum(kind)];
    if (slot.*) |old| old.destroy();
    slot.* = o;
    dev.backend.queue.push(.{ .selection = .{ .seat = dev.seat, .kind = kind, .offer = o != null } });
}

fn onDevice(_: *wl.DataDevice, event: wl.DataDevice.Event, dev: *DataDevice) void {
    const gpa = dev.backend.allocator;
    switch (event) {
        .data_offer => |e| {
            const o = gpa.create(Offer) catch {
                e.id.destroy();
                return dev.backend.queue.fail(error.OutOfMemory);
            };
            o.* = .{ .kind = .clipboard, .proxy = .{ .clipboard = e.id }, .dev = dev };
            e.id.setListener(*Offer, onDataOffer, o);
            dev.adopt(o);
        },
        .enter => |e| {
            const offer = if (e.id) |id| dev.take(id) else null;
            const window = Wayland.windowOf(e.surface) orelse {
                if (offer) |o| o.destroy();
                return;
            };
            dev.endDrag();
            dev.next_drag += 1;
            dev.drag = .{ .offer = offer, .id = dev.next_drag, .serial = e.serial, .window = window };
            dev.backend.queue.push(.{ .drag_enter = .{
                .window = window,
                .seat = dev.seat,
                .offer = dev.next_drag,
                .x = e.x.toDouble(),
                .y = e.y.toDouble(),
                .serial = e.serial,
                .source_actions = if (offer) |o| o.source_actions else .{},
                .own = dev.drag_source != null,
            } });
        },
        .motion => |m| if (dev.drag) |d| if (!d.dropped) {
            dev.backend.queue.push(.{ .drag_motion = .{ .window = d.window, .seat = dev.seat, .x = m.x.toDouble(), .y = m.y.toDouble(), .time = m.time } });
        },
        .leave => if (dev.drag) |d| if (!d.dropped) {
            dev.endDrag();
            dev.backend.queue.push(.{ .drag_leave = .{ .window = d.window, .seat = dev.seat, .offer = d.id } });
        },
        .drop => if (dev.drag) |*d| if (!d.dropped) {
            d.dropped = true;
            dev.backend.queue.push(.{ .drag_drop = dev.offerEvent(d.*) });
        },
        .selection => |e| dev.setCurrent(.clipboard, if (e.id) |id| dev.take(id) else null),
    }
}

fn onDataOffer(_: *wl.DataOffer, event: wl.DataOffer.Event, o: *Offer) void {
    switch (event) {
        .offer => |e| o.addMime(e.mime_type),
        .source_actions => |e| {
            o.source_actions = actionsOf(e.source_actions);
            o.dev.offerChanged(o);
        },
        .action => |e| {
            o.action = actionOf(e.dnd_action);
            o.dev.offerChanged(o);
        },
    }
}

fn offerEvent(dev: *const DataDevice, d: Drag) platform.DragOffer {
    return .{
        .window = d.window,
        .seat = dev.seat,
        .offer = d.id,
        .source_actions = if (d.offer) |o| o.source_actions else .{},
        .action = if (d.offer) |o| o.action else .none,
    };
}

/// The current drag's offer changed its actions.
fn offerChanged(dev: *DataDevice, o: *Offer) void {
    const d = dev.drag orelse return;
    if (d.offer != o) return;
    dev.backend.queue.push(.{ .drag_actions = dev.offerEvent(d) });
}

/// Drops the drag over a destroyed window.
pub fn forgetWindow(dev: *DataDevice, id: platform.WindowId) void {
    if (dev.drag) |d| if (d.window == id) dev.endDrag();
}

/// Forgets the seat's drag, destroying its offer (which refuses it if it
/// was dropped and not finished).
fn endDrag(dev: *DataDevice) void {
    const d = dev.drag orelse return;
    if (d.offer) |o| o.destroy();
    dev.drag = null;
}

fn actionsOf(a: wl.DataDeviceManager.DndAction) platform.DragActions {
    return .{ .copy = a.copy, .move = a.move, .ask = a.ask };
}

fn actionOf(a: wl.DataDeviceManager.DndAction) platform.DragAction {
    if (a.copy) return .copy;
    if (a.move) return .move;
    if (a.ask) return .ask;
    return .none;
}

fn dndActions(a: platform.DragActions) wl.DataDeviceManager.DndAction {
    return .{ .copy = a.copy, .move = a.move, .ask = a.ask };
}

fn dndAction(a: platform.DragAction) wl.DataDeviceManager.DndAction {
    return dndActions(.of(a));
}

fn onPrimary(_: *zwp.PrimarySelectionDeviceV1, event: zwp.PrimarySelectionDeviceV1.Event, dev: *DataDevice) void {
    const gpa = dev.backend.allocator;
    switch (event) {
        .data_offer => |e| {
            const o = gpa.create(Offer) catch {
                e.offer.destroy();
                return dev.backend.queue.fail(error.OutOfMemory);
            };
            o.* = .{ .kind = .primary, .proxy = .{ .primary = e.offer }, .dev = dev };
            e.offer.setListener(*Offer, onPrimaryOffer, o);
            dev.adopt(o);
        },
        .selection => |e| dev.setCurrent(.primary, if (e.id) |id| dev.take(id) else null),
    }
}

fn onPrimaryOffer(_: *zwp.PrimarySelectionOfferV1, event: zwp.PrimarySelectionOfferV1.Event, o: *Offer) void {
    switch (event) {
        .offer => |e| o.addMime(e.mime_type),
    }
}

fn onDataSource(_: *wl.DataSource, event: wl.DataSource.Event, s: *Source) void {
    switch (event) {
        .send => |e| s.send(e.mime_type, e.fd),
        .cancelled => s.cancel(),
        else => {},
    }
}

fn onPrimarySource(_: *zwp.PrimarySelectionSourceV1, event: zwp.PrimarySelectionSourceV1.Event, s: *Source) void {
    switch (event) {
        .send => |e| s.send(e.mime_type, e.fd),
        .cancelled => s.cancel(),
    }
}

pub fn setSelection(dev: *DataDevice, kind: Kind, mimes: []const []const u8, serial: u32) platform.Error!u32 {
    const b = dev.backend;
    const gpa = b.allocator;
    const k = @intFromEnum(kind);
    if (mimes.len == 0) {
        if (dev.sources[k]) |s| {
            switch (kind) {
                .clipboard => if (dev.device) |d| d.setSelection(null, serial),
                .primary => if (dev.primary) |d| d.setSelection(null, serial),
            }
            s.destroy();
            dev.sources[k] = null;
        }
        return 0;
    }
    const s = try gpa.create(Source);
    errdefer gpa.destroy(s);
    dev.next_source += 1;
    s.* = .{ .kind = kind, .id = dev.next_source, .proxy = undefined, .dev = dev };
    errdefer {
        for (s.mimes.items) |m| gpa.free(m);
        s.mimes.deinit(gpa);
    }
    for (mimes) |m| {
        const c = try gpa.dupe(u8, m);
        s.mimes.append(gpa, c) catch {
            gpa.free(c);
            return error.OutOfMemory;
        };
    }
    var buf: [256]u8 = undefined;
    switch (kind) {
        .clipboard => {
            const d = dev.device orelse return error.MissingGlobal;
            const p = b.data_device_manager.?.createDataSource() catch return error.OutOfMemory;
            s.proxy = .{ .clipboard = p };
            p.setListener(*Source, onDataSource, s);
            for (s.mimes.items) |m| p.offer(z(&buf, m));
            d.setSelection(p, serial);
        },
        .primary => {
            const d = dev.primary orelse return error.MissingGlobal;
            const p = b.primary_selection_manager.?.createSource() catch return error.OutOfMemory;
            s.proxy = .{ .primary = p };
            p.setListener(*Source, onPrimarySource, s);
            for (s.mimes.items) |m| p.offer(z(&buf, m));
            d.setSelection(p, serial);
        },
    }
    // The compositor cancels the previous source itself; forget it here.
    if (dev.sources[k]) |old| {
        b.queue.push(.{ .selection_cancelled = .{ .seat = dev.seat, .kind = kind, .source = old.id } });
        old.destroy();
    }
    dev.sources[k] = s;
    return s.id;
}

fn z(buf: *[256]u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn selectionMimes(dev: *DataDevice, kind: Kind) []const []const u8 {
    const o = dev.current[@intFromEnum(kind)] orelse return &.{};
    return o.mimes.items;
}

pub fn receiveSelection(dev: *DataDevice, kind: Kind, mime: []const u8, fd: i32) bool {
    defer _ = linux.close(fd);
    const o = dev.current[@intFromEnum(kind)] orelse return false;
    var buf: [256]u8 = undefined;
    switch (o.proxy) {
        inline else => |p| p.receive(z(&buf, mime), fd),
    }
    // libwayland duplicates the fd when it marshals the request, so it
    // is closed here; the prepare hook flushes before the loop sleeps.
    return true;
}

// Drag and drop requests ------------------------------------------------------

/// The seat's drag if it is `id` and still has its offer.
fn dragOffer(dev: *DataDevice, id: u32) ?*Offer {
    const d = dev.drag orelse return null;
    if (d.id != id) return null;
    return d.offer;
}

pub fn dragMimes(dev: *DataDevice, id: u32) []const []const u8 {
    const o = dev.dragOffer(id) orelse return &.{};
    return o.mimes.items;
}

pub fn acceptDrag(dev: *DataDevice, id: u32, mime: ?[]const u8, actions: platform.DragActions, preferred: platform.DragAction) void {
    const o = dev.dragOffer(id) orelse return;
    const p = o.proxy.clipboard;
    var buf: [256]u8 = undefined;
    p.accept(dev.drag.?.serial, if (mime) |m| z(&buf, m) else null);
    // Actions exist from version 3; older sources copy.
    if (p.getVersion() >= 3) {
        const allowed = if (mime == null) platform.DragActions{} else actions;
        p.setActions(dndActions(allowed), dndAction(if (allowed.has(preferred)) preferred else .none));
    }
}

pub fn receiveDrag(dev: *DataDevice, id: u32, mime: []const u8, fd: i32) bool {
    defer _ = linux.close(fd);
    const o = dev.dragOffer(id) orelse return false;
    var buf: [256]u8 = undefined;
    o.proxy.clipboard.receive(z(&buf, mime), fd);
    return true;
}

pub fn finishDrag(dev: *DataDevice, id: u32, action: platform.DragAction) void {
    const d = dev.drag orelse return;
    if (d.id != id) return;
    if (d.offer) |o| if (d.dropped and action != .none and action != .ask) {
        const p = o.proxy.clipboard;
        if (p.getVersion() >= 3) {
            // An ask drop ends with the action the user chose.
            if (o.action != action) p.setActions(dndAction(action), dndAction(action));
            p.finish();
        }
    };
    dev.endDrag();
}

/// This client's drag: a wl_data_source and its icon surface.
const DragSource = struct {
    dev: *DataDevice,
    id: u32,
    proxy: *wl.DataSource,
    mimes: std.ArrayList([]const u8) = .empty,
    icon: ?*wl.Surface = null,
    icon_buffer: ?*wl.Buffer = null,
    /// The hotspot the icon surface's offsets have placed so far.
    icon_offset: [2]i32 = .{ 0, 0 },
    dropped: bool = false,
    /// The compositor's latest choice: what a finished drop performed.
    last_action: platform.DragAction = .none,

    fn destroy(s: *DragSource) void {
        const gpa = s.dev.backend.allocator;
        s.proxy.destroy();
        if (s.icon) |i| i.destroy();
        if (s.icon_buffer) |b| b.destroy();
        for (s.mimes.items) |m| gpa.free(m);
        s.mimes.deinit(gpa);
        if (s.dev.drag_source == s) s.dev.drag_source = null;
        gpa.destroy(s);
    }

    fn push(s: *DragSource, phase: platform.DragSource.Phase, action: platform.DragAction, accepted: bool) void {
        s.dev.backend.queue.push(.{ .drag_source = .{ .seat = s.dev.seat, .source = s.id, .phase = phase, .action = action, .accepted = accepted } });
    }
};

fn onDragSource(_: *wl.DataSource, event: wl.DataSource.Event, s: *DragSource) void {
    switch (event) {
        .target => |e| s.push(.target, .none, e.mime_type != null),
        .send => |e| {
            const m = std.mem.span(e.mime_type);
            for (s.mimes.items, 0..) |own, i| if (std.mem.eql(u8, own, m)) {
                s.dev.backend.queue.push(.{ .drag_send = .{ .seat = s.dev.seat, .source = s.id, .mime = @intCast(i), .fd = e.fd } });
                return;
            };
            _ = linux.close(e.fd);
        },
        .action => |e| {
            s.last_action = actionOf(e.dnd_action);
            s.push(.action, s.last_action, false);
        },
        .dnd_drop_performed => {
            s.dropped = true;
            s.push(.dropped, .none, false);
        },
        .dnd_finished => {
            s.push(.finished, s.last_action, false);
            s.destroy();
        },
        .cancelled => {
            s.push(.cancelled, .none, false);
            s.destroy();
        },
    }
}

pub fn startDrag(dev: *DataDevice, origin: *wl.Surface, mimes: []const []const u8, actions: platform.DragActions, icon: ?*const platform.DragIcon, serial: u32) platform.Error!u32 {
    const b = dev.backend;
    const gpa = b.allocator;
    const device = dev.device orelse return error.MissingGlobal;
    const s = try gpa.create(DragSource);
    s.* = .{ .dev = dev, .id = 0, .proxy = undefined };
    var created = false;
    errdefer if (created) s.destroy() else {
        for (s.mimes.items) |m| gpa.free(m);
        s.mimes.deinit(gpa);
        gpa.destroy(s);
    };
    for (mimes) |m| {
        const c = try gpa.dupe(u8, m);
        s.mimes.append(gpa, c) catch {
            gpa.free(c);
            return error.OutOfMemory;
        };
    }
    s.proxy = b.data_device_manager.?.createDataSource() catch return error.OutOfMemory;
    created = true;
    s.proxy.setListener(*DragSource, onDragSource, s);
    var buf: [256]u8 = undefined;
    for (s.mimes.items) |m| s.proxy.offer(z(&buf, m));
    if (s.proxy.getVersion() >= 3) s.proxy.setActions(dndActions(actions));
    if (icon) |i| try dev.makeIcon(s, i);
    // One drag per seat: a new one replaces the old.
    if (dev.drag_source) |old| {
        old.push(.cancelled, .none, false);
        old.destroy();
    }
    dev.next_source += 1;
    s.id = dev.next_source;
    device.startDrag(s.proxy, origin, s.icon, serial);
    if (s.icon) |surface| surface.commit();
    dev.drag_source = s;
    return s.id;
}

/// The icon surface: the hotspot goes under the pointer.
fn makeIcon(dev: *DataDevice, s: *DragSource, icon: *const platform.DragIcon) platform.Error!void {
    const b = dev.backend;
    if (icon.width == 0 or icon.height == 0) return;
    s.icon_buffer = try dev.iconBuffer(icon);
    const surface = b.compositor.?.createSurface() catch return error.OutOfMemory;
    s.icon = surface;
    // Icons never take input.
    const empty = b.compositor.?.createRegion() catch return error.OutOfMemory;
    surface.setInputRegion(empty);
    empty.destroy();
    s.icon_offset = placeIcon(surface, s.icon_buffer.?, icon, .{ 0, 0 });
}

/// Replaces the icon of this client's drag `source`, while it lasts;
/// false once it is over.
pub fn setDragIcon(dev: *DataDevice, source: u32, icon: *const platform.DragIcon) platform.Error!bool {
    const s = dev.drag_source orelse return false;
    if (s.id != source) return false;
    const surface = s.icon orelse return error.Unsupported;
    const buffer = try dev.iconBuffer(icon);
    s.icon_offset = placeIcon(surface, buffer, icon, s.icon_offset);
    surface.commit();
    // The surface holds the new buffer from this commit on.
    if (s.icon_buffer) |old| old.destroy();
    s.icon_buffer = buffer;
    return true;
}

/// Cancels this client's drag `source`, as if dropped nowhere: its node
/// hears `cancelled`.
pub fn cancelDrag(dev: *DataDevice, source: u32) void {
    const s = dev.drag_source orelse return;
    if (s.id != source) return;
    s.push(.cancelled, .none, false);
    s.destroy();
}

/// The icon's pixels in a wl_shm buffer.
fn iconBuffer(dev: *DataDevice, icon: *const platform.DragIcon) platform.Error!*wl.Buffer {
    const b = dev.backend;
    const stride = icon.width * 4;
    const size = @as(usize, stride) * icon.height;
    if (size > std.math.maxInt(i32) or icon.stride < stride) return error.SystemResources;
    const fd_rc = linux.memfd_create("siv-drag-icon", linux.MFD.CLOEXEC);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.SystemResources;
    const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(addr) != .SUCCESS) return error.SystemResources;
    const mem: [*]u8 = @ptrFromInt(addr);
    for (0..icon.height) |y| @memcpy(mem[y * stride ..][0..stride], icon.pixels[y * icon.stride ..][0..stride]);
    _ = linux.munmap(mem, size);
    const pool = b.shm.?.createPool(fd, @intCast(size)) catch return error.OutOfMemory;
    defer pool.destroy();
    return pool.createBuffer(0, @intCast(icon.width), @intCast(icon.height), @intCast(stride), .argb8888) catch return error.OutOfMemory;
}

/// Attaches an icon's buffer so that its hotspot is under the pointer.
/// Surface offsets add up, so the move is from the hotspot of `before`
/// (the offset the last icon placed, in logical pixels), which it
/// returns updated.
fn placeIcon(surface: *wl.Surface, buffer: *wl.Buffer, icon: *const platform.DragIcon, before: [2]i32) [2]i32 {
    const scale: i32 = @intCast(@max(icon.scale, 1));
    if (surface.getVersion() >= 3) surface.setBufferScale(scale);
    const hx = @divTrunc(icon.hotspot_x, scale);
    const hy = @divTrunc(icon.hotspot_y, scale);
    const dx = before[0] - hx;
    const dy = before[1] - hy;
    if (surface.getVersion() >= 5) {
        surface.attach(buffer, 0, 0);
        surface.offset(dx, dy);
    } else surface.attach(buffer, dx, dy);
    if (surface.getVersion() >= 4) surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32)) else surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    return .{ hx, hy };
}
