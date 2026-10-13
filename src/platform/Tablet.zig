//! A seat's tablets (tablet-v2, D16): tools and pads. A tool's events are
//! collected until its `frame` and queued as `platform.TabletTool` events
//! carrying the tool's whole state; pad buttons, rings, strips, dials, and
//! mode switches become `platform.TabletPad` events for the window the pad
//! focuses. While a tool is near a window it shows that window's cursor.

const std = @import("std");
const wl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const zwp = @import("wayland").client.zwp;
const platform = @import("platform.zig");
const Wayland = @import("Wayland.zig");
const cursor = @import("cursor.zig");
const Tablet = @This();

const WindowId = platform.WindowId;

backend: *Wayland,
seat: platform.SeatId,
proxy: *zwp.TabletSeatV2,
tablets: std.ArrayList(*zwp.TabletV2) = .empty,
tools: std.ArrayList(?*Tool) = .empty,
pads: std.ArrayList(?*Pad) = .empty,

pub const Tool = struct {
    tablet: *Tablet,
    /// Null for tools a test feeds without the compositor.
    proxy: ?*zwp.TabletToolV2,
    state: platform.TabletTool,
    /// The window the tool is near, and the serial of its proximity_in,
    /// which cursor requests name.
    window: ?WindowId = null,
    proximity_serial: u32 = 0,
    shape_device: ?*wp.CursorShapeDeviceV1 = null,
    cursor_surface: ?*wl.Surface = null,
    // What the frame being collected changed.
    entered: bool = false,
    left: bool = false,
    went_down: bool = false,
    went_up: bool = false,
    moved: bool = false,
    buttons: [8]Button = undefined,
    button_count: u8 = 0,

    const Button = struct { code: u32, pressed: bool, serial: u32 };
};

pub const Pad = struct {
    tablet: *Tablet,
    index: u32,
    proxy: *zwp.TabletPadV2,
    window: ?WindowId = null,
    groups: std.ArrayList(*Group) = .empty,
    /// Rings, strips, and dials so far, numbering them across groups.
    rings: u32 = 0,
    strips: u32 = 0,
    dials: u32 = 0,
};

pub const Group = struct {
    pad: *Pad,
    index: u32,
    proxy: *zwp.TabletPadGroupV2,
    mode: u32 = 0,
    buttons: std.ArrayList(u32) = .empty,
    controls: std.ArrayList(*Control) = .empty,
};

/// A ring, strip, or dial, collected until its frame.
pub const Control = struct {
    group: *Group,
    kind: platform.PadControl,
    index: u32,
    proxy: *wl.Proxy,
    value: f64 = 0,
    stop: bool = false,
    changed: bool = false,
};

pub fn create(backend: *Wayland, manager: *zwp.TabletManagerV2, seat: platform.SeatId, seat_proxy: *wl.Seat) !*Tablet {
    const proxy = try manager.getTabletSeat(seat_proxy);
    errdefer proxy.destroy();
    const t = try backend.allocator.create(Tablet);
    t.* = .{ .backend = backend, .seat = seat, .proxy = proxy };
    proxy.setListener(*Tablet, onSeat, t);
    return t;
}

pub fn destroy(t: *Tablet) void {
    const gpa = t.backend.allocator;
    for (t.tools.items) |tool| if (tool) |x| t.freeTool(x);
    for (t.pads.items) |pad| if (pad) |p| t.freePad(p);
    for (t.tablets.items) |tab| tab.destroy();
    t.tools.deinit(gpa);
    t.pads.deinit(gpa);
    t.tablets.deinit(gpa);
    t.proxy.destroy();
    gpa.destroy(t);
}

pub fn forgetWindow(t: *Tablet, id: WindowId) void {
    for (t.tools.items) |tool| if (tool) |x| if (x.window == id) {
        x.window = null;
        x.state.tip = false;
    };
    for (t.pads.items) |pad| if (pad) |p| if (p.window == id) {
        p.window = null;
    };
}

fn push(t: *Tablet, event: platform.Event) void {
    t.backend.queue.push(event);
}

fn oom(t: *Tablet) void {
    t.backend.queue.fail(error.OutOfMemory);
}

fn onSeat(_: *zwp.TabletSeatV2, event: zwp.TabletSeatV2.Event, t: *Tablet) void {
    switch (event) {
        .tablet_added => |e| {
            e.id.setListener(*Tablet, onTablet, t);
            t.tablets.append(t.backend.allocator, e.id) catch {
                e.id.destroy();
                t.oom();
            };
        },
        .tool_added => |e| {
            const tool = t.addTool(e.id) catch {
                e.id.destroy();
                return t.oom();
            };
            e.id.setListener(*Tool, onTool, tool);
            if (t.backend.cursor_shape_manager) |m| tool.shape_device = m.getTabletToolV2(e.id) catch null;
        },
        .pad_added => |e| t.addPad(e.id) catch {
            e.id.destroy();
            t.oom();
        },
    }
}

fn onTablet(proxy: *zwp.TabletV2, event: zwp.TabletV2.Event, t: *Tablet) void {
    switch (event) {
        .removed => {
            for (t.tablets.items, 0..) |tab, i| if (tab == proxy) {
                _ = t.tablets.swapRemove(i);
                break;
            };
            proxy.destroy();
        },
        else => {},
    }
}

// Tools ---------------------------------------------------------------------

/// Adds a tool in a free slot. `proxy` is null for a tool a test feeds
/// without the compositor (no cursor requests are made for it).
pub fn addTool(t: *Tablet, proxy: ?*zwp.TabletToolV2) !*Tool {
    const gpa = t.backend.allocator;
    const slot = for (t.tools.items, 0..) |x, i| {
        if (x == null) break i;
    } else blk: {
        try t.tools.append(gpa, null);
        break :blk t.tools.items.len - 1;
    };
    const tool = try gpa.create(Tool);
    tool.* = .{ .tablet = t, .proxy = proxy, .state = .{ .window = 0, .seat = t.seat, .tool = @intCast(slot), .phase = .motion } };
    t.tools.items[slot] = tool;
    return tool;
}

fn freeTool(t: *Tablet, tool: *Tool) void {
    if (tool.shape_device) |d| d.destroy();
    if (tool.cursor_surface) |s| s.destroy();
    if (tool.proxy) |p| p.destroy();
    t.tools.items[tool.state.tool] = null;
    t.backend.allocator.destroy(tool);
}

pub fn onTool(_: *zwp.TabletToolV2, event: zwp.TabletToolV2.Event, tool: *Tool) void {
    const s = &tool.state;
    switch (event) {
        .type => |e| s.kind = switch (@intFromEnum(e.tool_type)) {
            0x141 => .eraser,
            0x142 => .brush,
            0x143 => .pencil,
            0x144 => .airbrush,
            0x145 => .finger,
            0x146 => .mouse,
            0x147 => .lens,
            else => .pen,
        },
        .hardware_serial => |e| s.serial_number = @as(u64, e.hardware_serial_hi) << 32 | e.hardware_serial_lo,
        .hardware_id_wacom, .done => {},
        .capability => |e| switch (@intFromEnum(e.capability)) {
            1 => s.axes.tilt = true,
            2 => s.axes.pressure = true,
            3 => s.axes.distance = true,
            4 => s.axes.rotation = true,
            5 => s.axes.slider = true,
            6 => s.axes.wheel = true,
            else => {},
        },
        .removed => {
            // A tool removed near a window leaves it first.
            if (tool.window != null) {
                tool.left = true;
                flush(tool, s.time);
            }
            tool.tablet.freeTool(tool);
        },
        .proximity_in => |e| {
            tool.window = Wayland.windowOf(e.surface);
            tool.proximity_serial = e.serial;
            tool.entered = tool.window != null;
            applyCursor(tool);
        },
        .proximity_out => tool.left = true,
        .down => |e| {
            s.tip = true;
            s.serial = e.serial;
            tool.went_down = true;
        },
        .up => {
            s.tip = false;
            tool.went_up = true;
        },
        .motion => |e| {
            s.x = e.x.toDouble();
            s.y = e.y.toDouble();
            tool.moved = true;
        },
        .pressure => |e| {
            s.pressure = @as(f64, @floatFromInt(e.pressure)) / 65535;
            tool.moved = true;
        },
        .distance => |e| {
            s.distance = @as(f64, @floatFromInt(e.distance)) / 65535;
            tool.moved = true;
        },
        .tilt => |e| {
            s.tilt_x = e.tilt_x.toDouble();
            s.tilt_y = e.tilt_y.toDouble();
            tool.moved = true;
        },
        .rotation => |e| {
            s.rotation = e.degrees.toDouble();
            tool.moved = true;
        },
        .slider => |e| {
            s.slider = @as(f64, @floatFromInt(e.position)) / 65535;
            tool.moved = true;
        },
        .wheel => |e| {
            s.wheel += e.degrees.toDouble();
            s.wheel_clicks += e.clicks;
            tool.moved = true;
        },
        .button => |e| if (tool.button_count < tool.buttons.len) {
            tool.buttons[tool.button_count] = .{ .code = e.button, .pressed = e.state == .pressed, .serial = e.serial };
            tool.button_count += 1;
        },
        .frame => |e| flush(tool, e.time),
    }
}

/// Queues a frame's events: proximity_in, down, motion when only axes
/// changed, buttons, up, proximity_out, each with the whole state.
fn flush(tool: *Tool, time: u32) void {
    const t = tool.tablet;
    defer {
        tool.entered = false;
        tool.left = false;
        tool.went_down = false;
        tool.went_up = false;
        tool.moved = false;
        tool.button_count = 0;
        tool.state.wheel = 0;
        tool.state.wheel_clicks = 0;
    }
    const w = tool.window orelse return;
    var ev = tool.state;
    ev.window = w;
    ev.time = time;
    ev.button = 0;
    ev.pressed = false;
    if (tool.entered) {
        ev.phase = .proximity_in;
        t.push(.{ .tablet_tool = ev });
    }
    if (tool.went_down) {
        ev.phase = .down;
        t.push(.{ .tablet_tool = ev });
    }
    if (tool.moved and !tool.entered and !tool.went_down and !tool.went_up) {
        ev.phase = .motion;
        t.push(.{ .tablet_tool = ev });
    }
    for (tool.buttons[0..tool.button_count]) |b| {
        var bev = ev;
        bev.phase = .button;
        bev.button = b.code;
        bev.pressed = b.pressed;
        bev.serial = b.serial;
        t.push(.{ .tablet_tool = bev });
    }
    if (tool.went_up) {
        ev.phase = .up;
        t.push(.{ .tablet_tool = ev });
    }
    if (tool.left) {
        ev.phase = .proximity_out;
        ev.tip = false;
        t.push(.{ .tablet_tool = ev });
        tool.window = null;
        tool.state.tip = false;
    }
}

/// Shows the cursor of the window the tool is near: a cursor-shape-v1
/// shape, or the theme's image (without animation).
pub fn applyCursor(tool: *Tool) void {
    const proxy = tool.proxy orelse return;
    const b = tool.tablet.backend;
    const id = tool.window orelse return;
    if (id >= b.windows.items.len) return;
    const w = b.windows.items[id] orelse return;
    const shape = w.cursor;
    if (shape == .hidden) return proxy.setCursor(tool.proximity_serial, null, 0, 0);
    if (tool.shape_device) |d| {
        const sh = if (d.getVersion() >= 2) shape else cursor.v1Shape(shape);
        return d.setShape(tool.proximity_serial, @enumFromInt(@intFromEnum(sh)));
    }
    const theme = &b.cursor_theme;
    const px: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(theme.size)) * w.state.scale.toFloat()));
    const loaded = theme.get(b.shm.?, shape, px) orelse theme.get(b.shm.?, .default, px) orelse return;
    const surface = tool.cursor_surface orelse blk: {
        const s = b.compositor.?.createSurface() catch return tool.tablet.oom();
        tool.cursor_surface = s;
        break :blk s;
    };
    const f = loaded.frames[0];
    const scale: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(@max(loaded.nominal, 1))) / @as(f64, @floatFromInt(@max(theme.size, 1)))))));
    if (surface.getVersion() >= 3) surface.setBufferScale(scale);
    proxy.setCursor(tool.proximity_serial, surface, @divTrunc(@as(i32, @intCast(f.xhot)), scale), @divTrunc(@as(i32, @intCast(f.yhot)), scale));
    surface.attach(f.buffer, 0, 0);
    surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    surface.commit();
}

/// Shows a window's cursor again on the tools near it.
pub fn reapplyCursors(t: *Tablet, id: WindowId) void {
    for (t.tools.items) |tool| if (tool) |x| if (x.window == id) applyCursor(x);
}

// Pads ----------------------------------------------------------------------

fn addPad(t: *Tablet, proxy: *zwp.TabletPadV2) !void {
    const gpa = t.backend.allocator;
    const slot = for (t.pads.items, 0..) |x, i| {
        if (x == null) break i;
    } else blk: {
        try t.pads.append(gpa, null);
        break :blk t.pads.items.len - 1;
    };
    const pad = try gpa.create(Pad);
    pad.* = .{ .tablet = t, .index = @intCast(slot), .proxy = proxy };
    t.pads.items[slot] = pad;
    proxy.setListener(*Pad, onPad, pad);
}

fn freePad(t: *Tablet, pad: *Pad) void {
    const gpa = t.backend.allocator;
    for (pad.groups.items) |g| {
        for (g.controls.items) |c| {
            switch (c.kind) {
                .ring => @as(*zwp.TabletPadRingV2, @ptrCast(c.proxy)).destroy(),
                .strip => @as(*zwp.TabletPadStripV2, @ptrCast(c.proxy)).destroy(),
                .dial => @as(*zwp.TabletPadDialV2, @ptrCast(c.proxy)).destroy(),
                else => unreachable,
            }
            gpa.destroy(c);
        }
        g.controls.deinit(gpa);
        g.buttons.deinit(gpa);
        g.proxy.destroy();
        gpa.destroy(g);
    }
    pad.groups.deinit(gpa);
    pad.proxy.destroy();
    t.pads.items[pad.index] = null;
    gpa.destroy(pad);
}

fn padEvent(pad: *Pad, control: platform.PadControl, group: ?*Group) ?platform.TabletPad {
    const w = pad.window orelse return null;
    return .{
        .window = w,
        .seat = pad.tablet.seat,
        .pad = pad.index,
        .control = control,
        .group = if (group) |g| g.index else 0,
        .mode = if (group) |g| g.mode else 0,
    };
}

pub fn onPad(_: *zwp.TabletPadV2, event: zwp.TabletPadV2.Event, pad: *Pad) void {
    const t = pad.tablet;
    switch (event) {
        .group => |e| {
            const g = t.backend.allocator.create(Group) catch {
                e.pad_group.destroy();
                return t.oom();
            };
            g.* = .{ .pad = pad, .index = @intCast(pad.groups.items.len), .proxy = e.pad_group };
            pad.groups.append(t.backend.allocator, g) catch {
                e.pad_group.destroy();
                t.backend.allocator.destroy(g);
                return t.oom();
            };
            e.pad_group.setListener(*Group, onGroup, g);
        },
        .path, .buttons, .done => {},
        .button => |e| {
            const group = for (pad.groups.items) |g| {
                if (std.mem.indexOfScalar(u32, g.buttons.items, e.button) != null) break g;
            } else null;
            var ev = padEvent(pad, .button, group) orelse return;
            ev.index = e.button;
            ev.pressed = e.state == .pressed;
            ev.time = e.time;
            t.push(.{ .tablet_pad = ev });
        },
        .enter => |e| pad.window = Wayland.windowOf(e.surface),
        .leave => pad.window = null,
        .removed => t.freePad(pad),
    }
}

fn onGroup(_: *zwp.TabletPadGroupV2, event: zwp.TabletPadGroupV2.Event, g: *Group) void {
    const pad = g.pad;
    const t = pad.tablet;
    switch (event) {
        .buttons => |e| {
            g.buttons.clearRetainingCapacity();
            g.buttons.appendSlice(t.backend.allocator, e.buttons.slice(u32)) catch t.oom();
        },
        .ring => |e| {
            const c = addControl(g, .ring, @ptrCast(e.ring), &pad.rings) orelse return e.ring.destroy();
            e.ring.setListener(*Control, onRing, c);
        },
        .strip => |e| {
            const c = addControl(g, .strip, @ptrCast(e.strip), &pad.strips) orelse return e.strip.destroy();
            e.strip.setListener(*Control, onStrip, c);
        },
        .dial => |e| {
            const c = addControl(g, .dial, @ptrCast(e.dial), &pad.dials) orelse return e.dial.destroy();
            e.dial.setListener(*Control, onDial, c);
        },
        .modes, .done => {},
        .mode_switch => |e| {
            g.mode = e.mode;
            var ev = padEvent(pad, .mode, g) orelse return;
            ev.time = e.time;
            ev.serial = e.serial;
            t.push(.{ .tablet_pad = ev });
        },
    }
}

fn addControl(g: *Group, kind: platform.PadControl, proxy: *wl.Proxy, counter: *u32) ?*Control {
    const gpa = g.pad.tablet.backend.allocator;
    const c = gpa.create(Control) catch {
        g.pad.tablet.oom();
        return null;
    };
    c.* = .{ .group = g, .kind = kind, .index = counter.*, .proxy = proxy };
    g.controls.append(gpa, c) catch {
        gpa.destroy(c);
        g.pad.tablet.oom();
        return null;
    };
    counter.* += 1;
    return c;
}

fn controlFrame(c: *Control, time: u32) void {
    defer {
        c.changed = false;
        c.stop = false;
        if (c.kind == .dial) c.value = 0;
    }
    if (!c.changed) return;
    const g = c.group;
    var ev = padEvent(g.pad, c.kind, g) orelse return;
    ev.index = c.index;
    ev.value = c.value;
    ev.stop = c.stop;
    ev.time = time;
    g.pad.tablet.push(.{ .tablet_pad = ev });
}

pub fn onRing(_: *zwp.TabletPadRingV2, event: zwp.TabletPadRingV2.Event, c: *Control) void {
    switch (event) {
        .source => {},
        .angle => |e| {
            c.value = e.degrees.toDouble();
            c.changed = true;
        },
        .stop => {
            c.stop = true;
            c.changed = true;
        },
        .frame => |e| controlFrame(c, e.time),
    }
}

pub fn onStrip(_: *zwp.TabletPadStripV2, event: zwp.TabletPadStripV2.Event, c: *Control) void {
    switch (event) {
        .source => {},
        .position => |e| {
            c.value = @as(f64, @floatFromInt(e.position)) / 65535;
            c.changed = true;
        },
        .stop => {
            c.stop = true;
            c.changed = true;
        },
        .frame => |e| controlFrame(c, e.time),
    }
}

pub fn onDial(_: *zwp.TabletPadDialV2, event: zwp.TabletPadDialV2.Event, c: *Control) void {
    switch (event) {
        .delta => |e| {
            c.value += @as(f64, @floatFromInt(e.value120)) / 120;
            c.changed = true;
        },
        .frame => |e| controlFrame(c, e.time),
    }
}
