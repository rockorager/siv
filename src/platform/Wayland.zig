//! Wayland backend (D7, D12, D16, D17) on libwayland-client through the
//! zig-wayland bindings.
//!
//! The display fd is a loop source. Its io handler reads and dispatches
//! Wayland events; listeners only update state and queue platform events
//! (D5). A prepare hook dispatches events other threads read into the
//! default queue and flushes requests before the loop sleeps, watching for
//! writability when the socket is full.
//!
//! Windows are xdg_toplevels presented with wl_shm buffers. Each has a frame
//! clock driven by frame callbacks and wp_presentation feedback, and a scale
//! from wp_fractional_scale_v1 (with wp_viewporter), wl_surface's preferred
//! buffer scale, or the outputs it is on, in that order.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zxdg = wayland.client.zxdg;
const xkb = @import("xkbcommon");
const platform = @import("platform.zig");
const Loop = platform.Loop;
const FrameClock = platform.FrameClock;
const shm_buffers = @import("shm.zig");
pub const Seat = @import("Seat.zig");
const Wayland = @This();

const Error = platform.Error;
const WindowId = platform.WindowId;
const OutputId = platform.OutputId;
const SeatId = platform.SeatId;
const WindowState = platform.WindowState;
const Size = platform.Size;
const Rect = platform.Rect;
const Buffer = platform.Buffer;

loop: *Loop,
allocator: Allocator,
queue: platform.EventQueue,
display: *wl.Display,
registry: *wl.Registry,

compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,
wm_base: ?*xdg.WmBase = null,
viewporter: ?*wp.Viewporter = null,
presentation: ?*wp.Presentation = null,
fractional_manager: ?*wp.FractionalScaleManagerV1 = null,
decoration_manager: ?*zxdg.DecorationManagerV1 = null,
/// Clock of wp_presentation timestamps; converted to CLOCK_MONOTONIC, the
/// loop's clock, when it differs (weston uses CLOCK_MONOTONIC_RAW).
presentation_clock: linux.clockid_t = .MONOTONIC,

outputs: std.ArrayList(?*Output) = .empty,
seats: std.ArrayList(?*Seat) = .empty,
windows: std.ArrayList(?*Window) = .empty,
/// The window whose frame event is being delivered; cleared if the sink
/// destroys it.
frame_window: ?*Window = null,

xkb_context: *xkb.struct_xkb_context,
compose_table: ?*xkb.struct_xkb_compose_table = null,

source: Loop.Source,
hook: Loop.Hook = .{ .func = prepare },
dead: bool = false,

pub const Options = struct {
    /// Socket name or path; null uses $WAYLAND_DISPLAY.
    display: ?[*:0]const u8 = null,
};

pub const Output = struct {
    backend: *Wayland,
    id: OutputId,
    global: u32,
    proxy: *wl.Output,
    info: platform.OutputInfo = .{},
    /// Accumulates events until wl_output.done.
    pending: platform.OutputInfo = .{},
    announced: bool = false,
};

const Window = struct {
    backend: *Wayland,
    id: WindowId,
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    viewport: ?*wp.Viewport = null,
    fractional: ?*wp.FractionalScaleV1 = null,

    state: WindowState = .{},
    pending: Pending = .{},
    default_size: Size,
    configured: bool = false,
    ack_serial: ?u32 = null,

    clock: FrameClock = .{},
    frame_task: Loop.Task = .{ .func = runFrame },
    frame_callback: ?*wl.Callback = null,
    feedbacks: [4]?*wp.PresentationFeedback = @splat(null),

    entered: [8]OutputId = undefined,
    entered_len: usize = 0,
    preferred_buffer_scale: i32 = 0,
    fractional_v120: u32 = 0,
    applied_buffer_scale: i32 = 1,
    applied_destination: Size = .{},

    swapchain: shm_buffers.Swapchain = .{},

    /// xdg_toplevel state collected until xdg_surface.configure.
    const Pending = struct {
        width: u32 = 0,
        height: u32 = 0,
        states: platform.WindowStates = .{},
        bounds: ?Size = null,
        capabilities: platform.WmCapabilities = .{},
        decoration: platform.Decoration = .client,
    };
};

pub fn create(loop: *Loop, allocator: Allocator, sink: platform.Sink, options: Options) Error!*Wayland {
    const display = wl.Display.connect(options.display) catch return error.ConnectionLost;
    errdefer display.disconnect();
    const registry = display.getRegistry() catch return error.OutOfMemory;
    const context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.OutOfMemory;
    errdefer xkb.xkb_context_unref(context);

    const self = try allocator.create(Wayland);
    errdefer allocator.destroy(self);
    self.* = .{
        .loop = loop,
        .allocator = allocator,
        .queue = .{ .loop = loop, .allocator = allocator, .sink = sink },
        .display = display,
        .registry = registry,
        .xkb_context = context,
        .compose_table = xkb.xkb_compose_table_new_from_locale(context, composeLocale(), xkb.XKB_COMPOSE_COMPILE_NO_FLAGS),
        .source = .{ .fd = display.getFd(), .events = linux.EPOLL.IN, .func = onReadable },
    };
    errdefer self.teardown();

    registry.setListener(*Wayland, onRegistry, self);
    // Globals, then their initial events: shm formats, output modes, seat
    // capabilities and keymaps.
    if (display.roundtrip() != .SUCCESS) return error.ConnectionLost;
    if (self.compositor == null or self.shm == null or self.wm_base == null) return error.MissingGlobal;
    if (display.roundtrip() != .SUCCESS) return error.ConnectionLost;

    self.loop.addSource(&self.source) catch return error.SystemResources;
    self.loop.addHook(&self.hook);
    return self;
}

pub fn destroy(self: *Wayland) void {
    if (!self.dead) {
        self.loop.removeSource(&self.source);
        self.loop.removeHook(&self.hook);
    }
    self.teardown();
    self.allocator.destroy(self);
}

fn teardown(self: *Wayland) void {
    for (self.windows.items, 0..) |w, i| if (w != null) self.destroyWindow(@intCast(i));
    for (self.seats.items) |s| if (s) |seat| seat.destroy();
    for (self.outputs.items) |o| if (o) |out| self.destroyOutput(out);
    self.windows.deinit(self.allocator);
    self.seats.deinit(self.allocator);
    self.outputs.deinit(self.allocator);
    if (self.decoration_manager) |m| m.destroy();
    if (self.fractional_manager) |m| m.destroy();
    if (self.presentation) |p| p.destroy();
    if (self.viewporter) |v| v.destroy();
    if (self.wm_base) |b| b.destroy();
    if (self.shm) |s| if (s.getVersion() >= 2) s.release() else wlDestroy(s);
    if (self.compositor) |c| wlDestroy(c);
    self.registry.destroy();
    _ = self.display.flush();
    self.display.disconnect();
    xkb.xkb_compose_table_unref(self.compose_table);
    xkb.xkb_context_unref(self.xkb_context);
    self.queue.deinit();
}

/// Destroys a proxy without a destructor request.
fn wlDestroy(proxy: anytype) void {
    @as(*wl.Proxy, @ptrCast(proxy)).destroy();
}

fn composeLocale() [*:0]const u8 {
    for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        if (std.c.getenv(name)) |v| if (v[0] != 0) return v;
    }
    return "C";
}

// Connection ---------------------------------------------------------------

fn onReadable(source: *Loop.Source, events: u32) void {
    const self: *Wayland = @fieldParentPtr("source", source);
    if (events & linux.EPOLL.OUT != 0) self.flush();
    if (events & linux.EPOLL.IN != 0) {
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return self.fail();
        }
        switch (self.display.readEvents()) {
            .SUCCESS, .AGAIN => {},
            else => return self.fail(),
        }
        if (self.display.dispatchPending() != .SUCCESS) return self.fail();
    } else if (events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
        self.fail();
    }
}

fn prepare(hook: *Loop.Hook) void {
    const self: *Wayland = @fieldParentPtr("hook", hook);
    // Events another thread (a Vulkan driver) read into our queue do not
    // make the fd readable again.
    if (self.display.dispatchPending() != .SUCCESS) return self.fail();
    self.flush();
}

fn flush(self: *Wayland) void {
    if (self.dead) return;
    const events: u32 = switch (self.display.flush()) {
        .SUCCESS => linux.EPOLL.IN,
        .AGAIN => linux.EPOLL.IN | linux.EPOLL.OUT,
        else => return self.fail(),
    };
    self.loop.modifySource(&self.source, events) catch self.fail();
}

fn fail(self: *Wayland) void {
    if (self.dead) return;
    self.dead = true;
    self.loop.removeSource(&self.source);
    self.loop.removeHook(&self.hook);
    const code = self.display.getError();
    std.log.scoped(.wayland).err("connection failed: errno {d}", .{code});
    self.queue.fail(if (code == @intFromEnum(linux.E.PROTO)) error.ProtocolError else error.ConnectionLost);
}

// Globals ----------------------------------------------------------------

fn onRegistry(registry: *wl.Registry, event: wl.Registry.Event, self: *Wayland) void {
    switch (event) {
        .global => |g| self.addGlobal(registry, g.name, std.mem.span(g.interface), g.version) catch {
            self.queue.fail(error.OutOfMemory);
        },
        .global_remove => |g| {
            for (self.outputs.items) |o| if (o) |out| if (out.global == g.name) {
                self.removeOutput(out);
                return;
            };
            for (self.seats.items, 0..) |s, i| if (s) |seat| if (seat.global == g.name) {
                seat.destroy();
                self.seats.items[i] = null;
                return;
            };
        },
    }
}

fn is(interface: []const u8, comptime T: type) bool {
    return std.mem.eql(u8, interface, std.mem.span(T.interface.name));
}

fn addGlobal(self: *Wayland, registry: *wl.Registry, name: u32, interface: []const u8, version: u32) !void {
    if (is(interface, wl.Compositor)) {
        self.compositor = try registry.bind(name, wl.Compositor, version);
    } else if (is(interface, wl.Shm)) {
        self.shm = try registry.bind(name, wl.Shm, version);
    } else if (is(interface, xdg.WmBase)) {
        const base = try registry.bind(name, xdg.WmBase, version);
        base.setListener(*Wayland, onWmBase, self);
        self.wm_base = base;
    } else if (is(interface, wp.Viewporter)) {
        self.viewporter = try registry.bind(name, wp.Viewporter, version);
    } else if (is(interface, wp.Presentation)) {
        const p = try registry.bind(name, wp.Presentation, version);
        p.setListener(*Wayland, onPresentation, self);
        self.presentation = p;
    } else if (is(interface, wp.FractionalScaleManagerV1)) {
        self.fractional_manager = try registry.bind(name, wp.FractionalScaleManagerV1, version);
    } else if (is(interface, zxdg.DecorationManagerV1)) {
        self.decoration_manager = try registry.bind(name, zxdg.DecorationManagerV1, version);
    } else if (is(interface, wl.Output)) {
        try self.addOutput(registry, name, version);
    } else if (is(interface, wl.Seat)) {
        const slot = try reserveSlot(Seat, self.allocator, &self.seats);
        const seat = try Seat.create(self, @intCast(slot), registry, name, version);
        self.seats.items[slot] = seat;
    }
}

/// Index of a free slot in `list`, appending one if needed.
fn reserveSlot(comptime T: type, allocator: Allocator, list: *std.ArrayList(?*T)) Allocator.Error!usize {
    for (list.items, 0..) |item, i| if (item == null) return i;
    try list.append(allocator, null);
    return list.items.len - 1;
}

fn onWmBase(base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Wayland) void {
    switch (event) {
        .ping => |p| base.pong(p.serial),
    }
}

fn onPresentation(_: *wp.Presentation, event: wp.Presentation.Event, self: *Wayland) void {
    switch (event) {
        .clock_id => |c| self.presentation_clock = @enumFromInt(c.clk_id),
    }
}

// Outputs ----------------------------------------------------------------

fn addOutput(self: *Wayland, registry: *wl.Registry, name: u32, version: u32) !void {
    const slot = try reserveSlot(Output, self.allocator, &self.outputs);
    const out = try self.allocator.create(Output);
    errdefer self.allocator.destroy(out);
    out.* = .{
        .backend = self,
        .id = @intCast(slot),
        .global = name,
        .proxy = try registry.bind(name, wl.Output, version),
    };
    out.proxy.setListener(*Output, onOutput, out);
    self.outputs.items[slot] = out;
}

fn destroyOutput(self: *Wayland, out: *Output) void {
    if (out.proxy.getVersion() >= 3) out.proxy.release() else wlDestroy(out.proxy);
    self.outputs.items[out.id] = null;
    self.allocator.destroy(out);
}

fn removeOutput(self: *Wayland, out: *Output) void {
    const id = out.id;
    if (out.announced) self.queue.push(.{ .output_removed = id });
    self.destroyOutput(out);
    for (self.windows.items) |w| if (w) |win| {
        if (removeEntered(win, id)) updateScale(win);
    };
}

pub fn output(self: *Wayland, id: OutputId) ?*const platform.OutputInfo {
    if (id >= self.outputs.items.len) return null;
    const out = self.outputs.items[id] orelse return null;
    return if (out.announced) &out.info else null;
}

fn onOutput(_: *wl.Output, event: wl.Output.Event, out: *Output) void {
    const p = &out.pending;
    switch (event) {
        .geometry => |g| {
            p.x = g.x;
            p.y = g.y;
            p.physical_width_mm = g.physical_width;
            p.physical_height_mm = g.physical_height;
            p.make.set(std.mem.span(g.make));
            p.model.set(std.mem.span(g.model));
            p.transform = @intCast(@intFromEnum(g.transform));
        },
        .mode => |m| if (m.flags.current) {
            p.width = m.width;
            p.height = m.height;
            p.refresh_mhz = m.refresh;
        },
        .scale => |s| p.scale = s.factor,
        .name => |n| p.name.set(std.mem.span(n.name)),
        .description => |d| p.description.set(std.mem.span(d.description)),
        .done => {
            const self = out.backend;
            const scale_changed = out.info.scale != p.scale;
            out.info = p.*;
            self.queue.push(if (out.announced) .{ .output_changed = out.id } else .{ .output_added = out.id });
            out.announced = true;
            if (scale_changed) for (self.windows.items) |w| if (w) |win| {
                if (std.mem.indexOfScalar(OutputId, win.entered[0..win.entered_len], out.id) != null) updateScale(win);
            };
        },
    }
}

fn outputOf(proxy: ?*wl.Output) ?*Output {
    const p = proxy orelse return null;
    return @ptrCast(@alignCast(p.getUserData() orelse return null));
}

// Windows ----------------------------------------------------------------

fn get(self: *Wayland, id: WindowId) *Window {
    return self.windows.items[id].?;
}

/// The window of a surface from an input event, if it is one of ours.
pub fn windowOf(surface: ?*wl.Surface) ?WindowId {
    const s = surface orelse return null;
    const w: *Window = @ptrCast(@alignCast(s.getUserData() orelse return null));
    return w.id;
}

pub fn createWindow(self: *Wayland, options: platform.WindowOptions) Error!WindowId {
    const slot = try reserveSlot(Window, self.allocator, &self.windows);
    const surface = self.compositor.?.createSurface() catch return error.OutOfMemory;
    errdefer surface.destroy();
    const xdg_surface = self.wm_base.?.getXdgSurface(surface) catch return error.OutOfMemory;
    errdefer xdg_surface.destroy();
    const toplevel = xdg_surface.getToplevel() catch return error.OutOfMemory;
    errdefer toplevel.destroy();
    const w = try self.allocator.create(Window);
    errdefer self.allocator.destroy(w);
    w.* = .{
        .backend = self,
        .id = @intCast(slot),
        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .default_size = .{ .width = options.width, .height = options.height },
    };
    errdefer {
        if (w.decoration) |d| d.destroy();
        if (w.viewport) |v| v.destroy();
        if (w.fractional) |f| f.destroy();
    }
    if (self.fractional_manager != null and self.viewporter != null) {
        w.fractional = self.fractional_manager.?.getFractionalScale(surface) catch return error.OutOfMemory;
        w.viewport = self.viewporter.?.getViewport(surface) catch return error.OutOfMemory;
    }
    if (self.decoration_manager) |m| {
        w.decoration = m.getToplevelDecoration(toplevel) catch return error.OutOfMemory;
    }

    surface.setListener(*Window, onSurface, w);
    xdg_surface.setListener(*Window, onXdgSurface, w);
    toplevel.setListener(*Window, onToplevel, w);
    if (w.fractional) |f| f.setListener(*Window, onFractionalScale, w);
    if (w.decoration) |d| {
        d.setListener(*Window, onDecoration, w);
        d.setMode(switch (options.decoration) {
            .client => .client_side,
            .server => .server_side,
        });
    }
    if (options.title.len > 0) setString(toplevel, xdg.Toplevel.setTitle, options.title);
    if (options.app_id.len > 0) setString(toplevel, xdg.Toplevel.setAppId, options.app_id);
    // The initial commit without a buffer asks for the first configure.
    surface.commit();
    self.windows.items[slot] = w;
    return w.id;
}

pub fn destroyWindow(self: *Wayland, id: WindowId) void {
    const w = self.get(id);
    if (self.frame_window == w) self.frame_window = null;
    for (self.seats.items) |s| if (s) |seat| seat.forgetWindow(id);
    self.queue.purge(id);
    self.loop.unschedule(&w.frame_task);
    for (w.feedbacks) |f| if (f) |fb| fb.destroy();
    if (w.frame_callback) |cb| cb.destroy();
    if (w.fractional) |f| f.destroy();
    if (w.viewport) |v| v.destroy();
    if (w.decoration) |d| d.destroy();
    w.toplevel.destroy();
    w.xdg_surface.destroy();
    w.swapchain.deinit();
    w.surface.destroy();
    self.allocator.destroy(w);
    self.windows.items[id] = null;
}

pub fn windowState(self: *Wayland, id: WindowId) *const WindowState {
    return &self.get(id).state;
}

pub fn requestFrame(self: *Wayland, id: WindowId) void {
    const w = self.get(id);
    w.clock.request();
    scheduleFrame(w);
}

pub fn acquireBuffer(self: *Wayland, id: WindowId) Error!Buffer {
    const w = self.get(id);
    return w.swapchain.acquire(self.allocator, self.shm.?, w.state.bufferWidth(), w.state.bufferHeight());
}

pub fn present(self: *Wayland, id: WindowId, buffer: Buffer, damage: ?[]const Rect) void {
    const w = self.get(id);
    const sb = w.swapchain.get(buffer.slot);
    const surface = w.surface;
    ackPending(w);

    if (w.viewport) |vp| {
        const dest: Size = .{ .width = w.state.width, .height = w.state.height };
        if (!std.meta.eql(dest, w.applied_destination)) {
            vp.setDestination(@intCast(dest.width), @intCast(dest.height));
            w.applied_destination = dest;
        }
        setBufferScale(w, 1);
    } else {
        setBufferScale(w, @intCast(w.state.scale.v120 / 120));
    }

    surface.attach(sb.buffer, 0, 0);
    const all = [_]Rect{.{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) }};
    for (damage orelse &all) |r| {
        if (surface.getVersion() >= 4) surface.damageBuffer(r.x, r.y, r.width, r.height) else surface.damage(0, 0, all[0].width, all[0].height);
    }
    if (w.frame_callback == null) {
        if (surface.frame()) |cb| {
            cb.setListener(*Window, onFrameDone, w);
            w.frame_callback = cb;
        } else |_| {}
    }
    if (self.presentation) |p| for (&w.feedbacks) |*slot| if (slot.* == null) {
        if (p.feedback(surface)) |fb| {
            fb.setListener(*Window, onFeedback, w);
            slot.* = fb;
        } else |_| {}
        break;
    };
    surface.commit();
    sb.busy = true;
    if (w.frame_callback != null) w.clock.committed();
}

pub fn setTitle(self: *Wayland, id: WindowId, title: []const u8) void {
    setString(self.get(id).toplevel, xdg.Toplevel.setTitle, title);
}

/// Sends a string request, truncating at a UTF-8 boundary to keep it on
/// the stack (the protocol limits messages to 4 KiB anyway).
fn setString(toplevel: *xdg.Toplevel, comptime request: anytype, s: []const u8) void {
    var buf: platform.BoundedString(1023) = .{};
    buf.set(s);
    buf.buf[buf.len] = 0;
    request(toplevel, buf.buf[0..buf.len :0]);
}

pub fn setMaximized(self: *Wayland, id: WindowId, maximized: bool) void {
    const t = self.get(id).toplevel;
    if (maximized) t.setMaximized() else t.unsetMaximized();
}

pub fn setFullscreen(self: *Wayland, id: WindowId, fullscreen: bool) void {
    const t = self.get(id).toplevel;
    if (fullscreen) t.setFullscreen(null) else t.unsetFullscreen();
}

pub fn setMinimized(self: *Wayland, id: WindowId) void {
    self.get(id).toplevel.setMinimized();
}

pub fn setSizeLimits(self: *Wayland, id: WindowId, min: Size, max: Size) void {
    const t = self.get(id).toplevel;
    t.setMinSize(@intCast(min.width), @intCast(min.height));
    t.setMaxSize(@intCast(max.width), @intCast(max.height));
}

pub fn beginMove(self: *Wayland, id: WindowId, seat: SeatId, serial: u32) void {
    const s = self.seatProxy(seat) orelse return;
    self.get(id).toplevel.move(s, serial);
}

pub fn beginResize(self: *Wayland, id: WindowId, seat: SeatId, serial: u32, edge: platform.Edge) void {
    const s = self.seatProxy(seat) orelse return;
    self.get(id).toplevel.resize(s, serial, @enumFromInt(@intFromEnum(edge)));
}

pub fn showWindowMenu(self: *Wayland, id: WindowId, seat: SeatId, serial: u32, x: i32, y: i32) void {
    const s = self.seatProxy(seat) orelse return;
    self.get(id).toplevel.showWindowMenu(s, serial, x, y);
}

pub fn setWindowGeometry(self: *Wayland, id: WindowId, g: Rect) void {
    self.get(id).xdg_surface.setWindowGeometry(g.x, g.y, g.width, g.height);
}

pub fn setRegion(self: *Wayland, id: WindowId, kind: platform.Region, rects: ?[]const Rect) Error!void {
    const w = self.get(id);
    const region: ?*wl.Region = if (rects) |rs| blk: {
        const r = self.compositor.?.createRegion() catch return error.OutOfMemory;
        for (rs) |rect| r.add(rect.x, rect.y, rect.width, rect.height);
        break :blk r;
    } else null;
    defer if (region) |r| r.destroy();
    switch (kind) {
        .input => w.surface.setInputRegion(region),
        .@"opaque" => w.surface.setOpaqueRegion(region),
    }
}

fn seatProxy(self: *Wayland, id: SeatId) ?*wl.Seat {
    if (id >= self.seats.items.len) return null;
    return if (self.seats.items[id]) |s| s.proxy else null;
}

fn onXdgSurface(_: *xdg.Surface, event: xdg.Surface.Event, w: *Window) void {
    switch (event) {
        .configure => |c| {
            const p = w.pending;
            var next = w.state;
            next.width = if (p.width != 0) p.width else if (w.configured) w.state.width else w.default_size.width;
            next.height = if (p.height != 0) p.height else if (w.configured) w.state.height else w.default_size.height;
            next.states = p.states;
            next.bounds = p.bounds;
            next.capabilities = p.capabilities;
            next.decoration = p.decoration;
            next.scale = computeScale(w);
            const changed = !w.configured or !std.meta.eql(next, w.state);
            w.state = next;
            w.configured = true;
            w.ack_serial = c.serial;
            w.clock.configured = true;
            w.clock.suspended = next.states.suspended;
            if (changed) w.backend.queue.push(.{ .configure = .{ .window = w.id, .state = next } });
            w.clock.force();
            scheduleFrame(w);
        },
    }
}

fn onToplevel(_: *xdg.Toplevel, event: xdg.Toplevel.Event, w: *Window) void {
    switch (event) {
        .configure => |c| {
            w.pending.width = @intCast(@max(c.width, 0));
            w.pending.height = @intCast(@max(c.height, 0));
            var states: platform.WindowStates = .{};
            for (c.states.slice(xdg.Toplevel.State)) |s| switch (s) {
                .maximized => states.maximized = true,
                .fullscreen => states.fullscreen = true,
                .resizing => states.resizing = true,
                .activated => states.activated = true,
                .tiled_left => states.tiled_left = true,
                .tiled_right => states.tiled_right = true,
                .tiled_top => states.tiled_top = true,
                .tiled_bottom => states.tiled_bottom = true,
                .suspended => states.suspended = true,
                _ => {},
            };
            w.pending.states = states;
        },
        .close => w.backend.queue.push(.{ .close_requested = w.id }),
        .configure_bounds => |b| w.pending.bounds = if (b.width > 0 and b.height > 0)
            .{ .width = @intCast(b.width), .height = @intCast(b.height) }
        else
            null,
        .wm_capabilities => |c| {
            var caps: platform.WmCapabilities = .{ .window_menu = false, .maximize = false, .fullscreen = false, .minimize = false };
            for (c.capabilities.slice(xdg.Toplevel.WmCapabilities)) |cap| switch (cap) {
                .window_menu => caps.window_menu = true,
                .maximize => caps.maximize = true,
                .fullscreen => caps.fullscreen = true,
                .minimize => caps.minimize = true,
                _ => {},
            };
            w.pending.capabilities = caps;
        },
    }
}

fn onDecoration(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, w: *Window) void {
    switch (event) {
        // Applied with the xdg_surface.configure that follows.
        .configure => |c| w.pending.decoration = switch (c.mode) {
            .server_side => .server,
            else => .client,
        },
    }
}

fn onSurface(_: *wl.Surface, event: wl.Surface.Event, w: *Window) void {
    switch (event) {
        .enter => |e| {
            const out = outputOf(e.output) orelse return;
            if (std.mem.indexOfScalar(OutputId, w.entered[0..w.entered_len], out.id) != null) return;
            if (w.entered_len == w.entered.len) return;
            w.entered[w.entered_len] = out.id;
            w.entered_len += 1;
            updateScale(w);
        },
        .leave => |e| {
            const out = outputOf(e.output) orelse return;
            if (removeEntered(w, out.id)) updateScale(w);
        },
        .preferred_buffer_scale => |s| {
            w.preferred_buffer_scale = s.factor;
            updateScale(w);
        },
        .preferred_buffer_transform => {},
    }
}

fn removeEntered(w: *Window, id: OutputId) bool {
    const i = std.mem.indexOfScalar(OutputId, w.entered[0..w.entered_len], id) orelse return false;
    w.entered[i] = w.entered[w.entered_len - 1];
    w.entered_len -= 1;
    return true;
}

fn onFractionalScale(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, w: *Window) void {
    switch (event) {
        .preferred_scale => |s| {
            w.fractional_v120 = s.scale;
            updateScale(w);
        },
    }
}

fn onFrameDone(cb: *wl.Callback, event: wl.Callback.Event, w: *Window) void {
    switch (event) {
        .done => {
            cb.destroy();
            w.frame_callback = null;
            w.clock.done();
            // Until presentation feedback arrives, trust the output mode.
            if (w.clock.last_present_ns == null) w.clock.refresh_ns = outputRefresh(w);
            scheduleFrame(w);
        },
    }
}

fn onFeedback(fb: *wp.PresentationFeedback, event: wp.PresentationFeedback.Event, w: *Window) void {
    switch (event) {
        .sync_output => return,
        .presented => |p| {
            const sec = (@as(u64, p.tv_sec_hi) << 32) | p.tv_sec_lo;
            const ns = sec * std.time.ns_per_s + p.tv_nsec;
            if (toMonotonic(w.backend.presentation_clock, ns)) |t| w.clock.presented(t, p.refresh);
        },
        .discarded => {},
    }
    for (&w.feedbacks) |*slot| if (slot.* == fb) {
        slot.* = null;
    };
    fb.destroy();
}

/// Converts a timestamp on `clock` to CLOCK_MONOTONIC by sampling both
/// clocks now; the error is the clocks' drift since the timestamp.
fn toMonotonic(clock: linux.clockid_t, ns: u64) ?u64 {
    if (clock == .MONOTONIC) return ns;
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(clock, &ts)) != .SUCCESS) return null;
    const clock_now: i128 = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    const t = @as(i128, ns) - clock_now + Loop.now();
    return if (t > 0) @intCast(t) else null;
}

fn runFrame(task: *Loop.Task) void {
    const w: *Window = @fieldParentPtr("frame_task", task);
    if (!w.clock.ready()) return;
    const self = w.backend;
    const time = w.clock.begin(Loop.now());
    self.frame_window = w;
    self.queue.sink.send(&.{ .frame = .{ .window = w.id, .time = time } });
    if (self.frame_window == null) return; // destroyed by the sink
    self.frame_window = null;
    // A configure must be acknowledged even if the frame showed nothing.
    if (w.ack_serial != null) {
        ackPending(w);
        w.surface.commit();
    }
}

fn scheduleFrame(w: *Window) void {
    if (w.clock.ready()) w.backend.loop.schedule(&w.frame_task, .frame);
}

fn ackPending(w: *Window) void {
    const serial = w.ack_serial orelse return;
    w.xdg_surface.ackConfigure(serial);
    w.ack_serial = null;
}

fn setBufferScale(w: *Window, scale: i32) void {
    if (scale == w.applied_buffer_scale or w.surface.getVersion() < 3) return;
    w.surface.setBufferScale(scale);
    w.applied_buffer_scale = scale;
}

fn computeScale(w: *const Window) platform.Scale {
    if (w.fractional != null and w.fractional_v120 != 0) return .{ .v120 = w.fractional_v120 };
    if (w.preferred_buffer_scale > 0) return .int(@intCast(w.preferred_buffer_scale));
    var scale: i32 = 1;
    for (w.entered[0..w.entered_len]) |id| {
        if (w.backend.output(id)) |info| scale = @max(scale, info.scale);
    }
    return .int(@intCast(scale));
}

/// Re-renders at a new scale. Before the first configure the scale is only
/// recorded; the configure applies it.
fn updateScale(w: *Window) void {
    const scale = computeScale(w);
    if (scale.v120 == w.state.scale.v120) return;
    w.state.scale = scale;
    if (!w.configured) return;
    w.backend.queue.push(.{ .configure = .{ .window = w.id, .state = w.state } });
    w.clock.request();
    scheduleFrame(w);
}

/// Refresh interval of the fastest output the window is on.
fn outputRefresh(w: *const Window) u64 {
    var mhz: i32 = 0;
    for (w.entered[0..w.entered_len]) |id| {
        if (w.backend.output(id)) |info| mhz = @max(mhz, info.refresh_mhz);
    }
    if (mhz <= 0) return FrameClock.default_refresh_ns;
    return @as(u64, 1_000_000_000_000) / @as(u64, @intCast(mhz));
}

test {
    std.testing.refAllDecls(@This());
}

// Tests against a real compositor --------------------------------------------

const testing = std.testing;
const Compositor = @import("test_compositor.zig").Compositor;
const VirtualPointer = @import("test_compositor.zig").VirtualPointer;

/// Answers every frame with a solid buffer and records what it saw.
const TestApp = struct {
    backend: *Wayland = undefined,
    events: std.ArrayList(platform.Event) = .empty,
    frames: usize = 0,
    frame_times: std.ArrayList(u64) = .empty,
    /// The frame clock's inputs when each frame began.
    frame_basis: std.ArrayList(struct { begin: u64, last_present: ?u64, refresh: u64 }) = .empty,
    last_buffer: Size = .{},
    animate: bool = false,
    closed: bool = false,

    fn deinit(app: *TestApp) void {
        app.events.deinit(testing.allocator);
        app.frame_times.deinit(testing.allocator);
        app.frame_basis.deinit(testing.allocator);
    }

    fn sink(app: *TestApp) platform.Sink {
        return .{ .ctx = app, .func = onEvent };
    }

    fn onEvent(ctx: ?*anyopaque, ev: *const platform.Event) void {
        const app: *TestApp = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .frame => |f| {
                app.frames += 1;
                app.frame_times.append(testing.allocator, f.time.present_ns) catch unreachable;
                const clock = app.backend.get(f.window).clock;
                app.frame_basis.append(testing.allocator, .{
                    .begin = Loop.now(),
                    .last_present = clock.last_present_ns,
                    .refresh = clock.refresh_ns,
                }) catch unreachable;
                const buf = app.backend.acquireBuffer(f.window) catch |err| std.debug.panic("acquire: {t}", .{err});
                @memset(std.mem.bytesAsSlice(u32, buf.pixels), 0xff2266aa);
                app.last_buffer = .{ .width = buf.width, .height = buf.height };
                app.backend.present(f.window, buf, null);
                if (app.animate) app.backend.requestFrame(f.window);
            },
            .close_requested => |id| {
                app.closed = true;
                app.backend.destroyWindow(id);
            },
            .failed => |err| std.debug.panic("platform failed: {t}", .{err}),
            else => {},
        }
        app.events.append(testing.allocator, ev.*) catch unreachable;
    }

    fn count(app: *const TestApp, tag: std.meta.Tag(platform.Event)) usize {
        var n: usize = 0;
        for (app.events.items) |e| n += @intFromBool(e == tag);
        return n;
    }

    fn last(app: *const TestApp, tag: std.meta.Tag(platform.Event)) ?platform.Event {
        var i = app.events.items.len;
        while (i > 0) {
            i -= 1;
            if (app.events.items[i] == tag) return app.events.items[i];
        }
        return null;
    }
};

fn runUntil(loop: *Loop, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    const deadline = Loop.now() + 5 * std.time.ns_per_s;
    while (!cond(ctx)) {
        if (Loop.now() > deadline) return error.Timeout;
        try loop.dispatch(50);
    }
}

const Harness = struct {
    compositor: Compositor,
    loop: Loop = undefined,
    app: TestApp = .{},

    fn start(h: *Harness) !void {
        try h.compositor.start();
        errdefer h.compositor.stop();
        h.loop = try Loop.init(testing.allocator);
        errdefer h.loop.deinit();
        h.app.backend = try Wayland.create(&h.loop, testing.allocator, h.app.sink(), .{ .display = h.compositor.display });
    }

    fn stop(h: *Harness) void {
        h.app.backend.destroy();
        h.loop.deinit();
        h.app.deinit();
        h.compositor.stop();
    }

    /// Creates a window and waits until its first frame was presented.
    fn mapWindow(h: *Harness, options: platform.WindowOptions) !WindowId {
        const id = try h.app.backend.createWindow(options);
        try runUntil(&h.loop, &h.app, struct {
            fn f(a: *TestApp) bool {
                return a.frames >= 1;
            }
        }.f);
        return id;
    }
};

test "sway: outputs, configure, decorations, frame clock, scale, close" {
    var h: Harness = .{ .compositor = .{ .kind = .sway } };
    try h.start();
    defer h.stop();
    const app = &h.app;
    const backend = app.backend;

    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.output_added) >= 1;
        }
    }.f);
    const out = backend.output(app.last(.output_added).?.output_added).?;
    try testing.expectEqualStrings("HEADLESS-1", out.name.slice());
    try testing.expectEqual(@as(i32, 1280), out.width);

    const id = try h.mapWindow(.{ .title = "siv test", .decoration = .server });
    // The first configure lets the client choose (640x480 by default); once
    // mapped, sway tiles the only window over the whole output.
    try testing.expectEqual(@as(u32, 640), app.last(.configure).?.configure.state.width);
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.last_buffer.width == 1280;
        }
    }.f);
    const state = backend.windowState(id);
    try testing.expectEqual(@as(u32, 1280), state.width);
    try testing.expectEqual(@as(u32, 720), state.height);
    try testing.expectEqual(platform.Decoration.server, state.decoration);
    try testing.expect(state.states.activated);
    try testing.expectEqual(Size{ .width = 1280, .height = 720 }, app.last_buffer);

    // Animate: one frame per frame callback, each predicted later than the
    // last. (wlroots 0.15 headless sends no presentation feedback; see the
    // weston test for that.)
    app.animate = true;
    backend.requestFrame(id);
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.frames >= 12;
        }
    }.f);
    app.animate = false;
    const times = app.frame_times.items;
    for (times[times.len - 6 ..], times[times.len - 7 .. times.len - 1]) |b, a| try testing.expect(b > a);
    // The refresh estimate comes from the output mode.
    try testing.expectEqual(@as(u64, 1_000_000_000_000 / @as(u64, @intCast(out.refresh_mhz))), backend.get(id).clock.refresh_ns);

    // Integer output scale (sway 1.7 has no fractional-scale-v1): the
    // window reconfigures and renders twice as many pixels.
    try h.compositor.command("output HEADLESS-1 scale 2");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.last_buffer.width == 2 * a.backend.windows.items[0].?.state.width and
                a.backend.windows.items[0].?.state.scale.v120 == 240;
        }
    }.f);
    try testing.expectEqual(@as(u32, 640), backend.windowState(id).width);
    try testing.expect(app.count(.output_changed) >= 1);

    try h.compositor.command("kill");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.closed;
        }
    }.f);
}

test "weston: presentation feedback drives the frame clock" {
    var h: Harness = .{ .compositor = .{ .kind = .weston } };
    try h.start();
    defer h.stop();
    const app = &h.app;
    const backend = app.backend;
    const id = try h.mapWindow(.{});
    app.animate = true;
    backend.requestFrame(id);
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.frames >= 20;
        }
    }.f);
    app.animate = false;

    const clock = &backend.get(id).clock;
    // Weston stamps presentation with CLOCK_MONOTONIC_RAW; siv converts it
    // to the loop's clock, so the last presentation is recent.
    try testing.expectEqual(linux.clockid_t.MONOTONIC_RAW, backend.presentation_clock);
    const last = clock.last_present_ns.?;
    const now = Loop.now();
    try testing.expect(last <= now + std.time.ns_per_ms and now - last < 200 * std.time.ns_per_ms);
    try testing.expect(clock.refresh_ns > 15 * std.time.ns_per_ms and clock.refresh_ns < 18 * std.time.ns_per_ms);

    // Once feedback arrives, each frame is predicted for the first refresh
    // cycle after the last presentation that is still in the future.
    // (Weston's headless output presents on a timer rather than a real
    // vblank, so the actual cadence is not checked.)
    var predicted_from_feedback: usize = 0;
    for (app.frame_times.items, app.frame_basis.items) |t, basis| {
        const last_present = basis.last_present orelse continue;
        try testing.expect(t > basis.begin);
        try testing.expectEqual(@as(u64, 0), (t - last_present) % basis.refresh);
        try testing.expect(t - basis.begin <= basis.refresh);
        predicted_from_feedback += 1;
    }
    try testing.expect(predicted_from_feedback >= 10);
}

test "sway: pointer, scrolling, keyboard text and repeat, touch" {
    var h: Harness = .{ .compositor = .{ .kind = .sway } };
    try h.start();
    defer h.stop();
    const app = &h.app;
    const id = try h.mapWindow(.{});

    var vp = try VirtualPointer.connect(&h.compositor);
    defer vp.deinit();
    // The virtual device gives the seat its pointer capability.
    try vp.sync();
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            const seat = a.backend.seats.items[0] orelse return false;
            return seat.pointer != null;
        }
    }.f);
    vp.moveTo(100, 120);
    vp.button(0x110, true);
    vp.button(0x110, false);
    vp.wheel(15, 1);
    try vp.sync();
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.scroll) >= 1 and a.count(.pointer_button) >= 2;
        }
    }.f);
    const motion = app.last(.pointer_motion) orelse app.last(.pointer_enter).?;
    const pos = switch (motion) {
        .pointer_motion, .pointer_enter => |m| m,
        else => unreachable,
    };
    try testing.expectEqual(id, pos.window);
    try testing.expectEqual(@as(f64, 100), pos.x);
    try testing.expectEqual(@as(f64, 120), pos.y);
    const button = app.last(.pointer_button).?.pointer_button;
    try testing.expectEqual(@as(u32, 0x110), button.button); // BTN_LEFT
    try testing.expect(!button.pressed);
    const scroll = app.last(.scroll).?.scroll;
    try testing.expectEqual(platform.ScrollSource.wheel, scroll.source);
    try testing.expectEqual(@as(i32, 120), scroll.v120_y); // one detent down
    try testing.expectEqual(@as(f64, 15), scroll.dy);
    try testing.expectEqual(@as(f64, 0), scroll.dx);

    // Text through wtype's virtual keyboard and the keymap it uploads, then
    // a key held past the repeat delay (sway: 600 ms at 25 Hz). The first
    // pause lets the seat gain its keyboard before keys arrive.
    const wtype = try h.compositor.spawnClient(&[_:null]?[*:0]const u8{ "wtype", "-s", "300", "hé", "-P", "x", "-s", "900", "-p", "x" });
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            const l = a.last(.key) orelse return false;
            return l.key.state == .released and l.key.keysym == 'x';
        }
    }.f);
    try h.compositor.wait(wtype);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (app.events.items) |e| if (e == .key and e.key.state == .pressed) try text.appendSlice(testing.allocator, e.key.text());
    try testing.expectEqualStrings("héx", text.items);
    try testing.expect(app.count(.keyboard_enter) >= 1);

    var repeats: usize = 0;
    for (app.events.items) |e| {
        if (e == .key and e.key.state == .repeated) {
            try testing.expectEqualStrings("x", e.key.text());
            repeats += 1;
        }
    }
    // About (900 - 600) ms at 25 Hz; allow for scheduling slack.
    try testing.expect(repeats >= 3 and repeats <= 12);

    // Sway 1.7 cannot inject touch, so feed wl_touch events for the real
    // surface to the seat's listener. Two contacts in one frame, then a
    // frame with a move, a shape change, and a lift.
    const seat = app.backend.seats.items[0].?;
    const surface = app.backend.get(id).surface;
    const touch: *wl.Touch = @ptrFromInt(0x1000); // the listener ignores it
    const fx = wl.Fixed.fromDouble;
    const before = app.events.items.len;
    Seat.onTouch(touch, .{ .down = .{ .serial = 5, .time = 1, .surface = surface, .id = 7, .x = fx(10), .y = fx(20) } }, seat);
    Seat.onTouch(touch, .{ .down = .{ .serial = 6, .time = 1, .surface = surface, .id = 8, .x = fx(30), .y = fx(40) } }, seat);
    Seat.onTouch(touch, .frame, seat);
    Seat.onTouch(touch, .{ .motion = .{ .time = 2, .id = 7, .x = fx(11), .y = fx(21) } }, seat);
    Seat.onTouch(touch, .{ .shape = .{ .id = 7, .major = fx(6), .minor = fx(4) } }, seat);
    Seat.onTouch(touch, .{ .up = .{ .serial = 9, .time = 2, .id = 8 } }, seat);
    Seat.onTouch(touch, .frame, seat);
    try h.loop.dispatch(0);
    var touch_events: std.ArrayList(platform.Event) = .empty;
    defer touch_events.deinit(testing.allocator);
    for (app.events.items[before..]) |e| switch (e) {
        .touch_down, .touch_motion, .touch_up, .touch_frame, .touch_cancel => try touch_events.append(testing.allocator, e),
        else => {},
    };
    const got = touch_events.items;
    const tags = [_]std.meta.Tag(platform.Event){ .touch_down, .touch_down, .touch_frame, .touch_motion, .touch_up, .touch_frame };
    try testing.expectEqual(tags.len, got.len);
    for (tags, got) |tag, e| try testing.expectEqual(tag, std.meta.activeTag(e));
    try testing.expectEqual(@as(i32, 7), got[0].touch_down.id);
    try testing.expectEqual(id, got[0].touch_down.window);
    try testing.expectEqual(@as(f64, 11), got[3].touch_motion.x);
    try testing.expectEqual(@as(f64, 6), got[3].touch_motion.major);
    try testing.expectEqual(@as(i32, 8), got[4].touch_up.id);
    try testing.expectEqual(@as(f64, 30), got[4].touch_up.x);
}

test "sway: output hotplug" {
    var h: Harness = .{ .compositor = .{ .kind = .sway } };
    try h.start();
    defer h.stop();
    const app = &h.app;
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.output_added) == 1;
        }
    }.f);

    try h.compositor.command("create_output");
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.output_added) == 2;
        }
    }.f);
    const added = app.last(.output_added).?.output_added;
    try testing.expectEqualStrings("HEADLESS-2", app.backend.output(added).?.name.slice());

    // Sway 1.7 has no command that removes a wl_output global (disabling
    // keeps it), so deliver the global_remove sway would send on unplug.
    const backend = app.backend;
    onRegistry(backend.registry, .{ .global_remove = .{ .name = backend.outputs.items[added].?.global } }, backend);
    try runUntil(&h.loop, app, struct {
        fn f(a: *TestApp) bool {
            return a.count(.output_removed) == 1;
        }
    }.f);
    try testing.expectEqual(added, app.last(.output_removed).?.output_removed);
    try testing.expect(app.backend.output(added) == null);
}
