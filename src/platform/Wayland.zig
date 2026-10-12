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
