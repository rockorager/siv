//! A seat's clipboard (wl_data_device) and primary selection
//! (zwp_primary_selection_device_v1), D19. Offers collect their mime types
//! until the device announces them as the selection; this client's sources
//! forward send requests as `selection_send` events with the fd, which the
//! UI writes and closes. Drag and drop offers are refused for now.

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

const Offer = struct {
    kind: Kind,
    proxy: union(enum) { clipboard: *wl.DataOffer, primary: *zwp.PrimarySelectionOfferV1 },
    mimes: std.ArrayList([]const u8) = .empty,
    dev: *DataDevice,

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
        // Drag and drop is not supported yet: refuse its offers.
        .enter => |e| if (e.id) |id| if (dev.take(id)) |o| o.destroy(),
        .leave, .motion, .drop => {},
        .selection => |e| dev.setCurrent(.clipboard, if (e.id) |id| dev.take(id) else null),
    }
}

fn onDataOffer(_: *wl.DataOffer, event: wl.DataOffer.Event, o: *Offer) void {
    switch (event) {
        .offer => |e| o.addMime(e.mime_type),
        .source_actions, .action => {},
    }
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
