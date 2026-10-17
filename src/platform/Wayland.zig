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
const zwp = wayland.client.zwp;
const zwlr = wayland.client.zwlr;
const ext = wayland.client.ext;
const xkb = @import("xkbcommon");
const platform = @import("platform.zig");
const Loop = platform.Loop;
const FrameClock = platform.FrameClock;
const Timer = @import("loop").Timer;
const shm_buffers = @import("shm.zig");
pub const Seat = @import("Seat.zig");
const TextInput = @import("TextInput.zig");
const DataDevice = @import("DataDevice.zig");
const cursor = @import("cursor.zig");
const syncobj = @import("syncobj.zig");
const Foreign = @import("Foreign.zig");
const Wayland = @This();

const log = std.log.scoped(.wayland);

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
subcompositor: ?*wl.Subcompositor = null,
reposition_token: u32 = 0,
shm: ?*wl.Shm = null,
wm_base: ?*xdg.WmBase = null,
viewporter: ?*wp.Viewporter = null,
presentation: ?*wp.Presentation = null,
fractional_manager: ?*wp.FractionalScaleManagerV1 = null,
decoration_manager: ?*zxdg.DecorationManagerV1 = null,
fifo_manager: ?*wp.FifoManagerV1 = null,
dmabuf: ?*zwp.LinuxDmabufV1 = null,
dmabuf_feedback: ?*zwp.LinuxDmabufFeedbackV1 = null,
/// The compositor's main device (dev_t) from dma-buf default feedback.
main_device: ?u64 = null,
/// Its format table (format, padding, modifier entries), mapped.
dmabuf_table: []align(std.heap.page_size_min) const u8 = &.{},
/// (format, modifier) pairs of every tranche, sorted, and those of the
/// feedback still arriving.
dmabuf_formats: std.ArrayList(FormatModifier) = .empty,
dmabuf_pending: std.ArrayList(FormatModifier) = .empty,
/// Every dma-buf wl_buffer not yet released (D17).
dmabuf_buffers: std.ArrayList(*DmabufBuffer) = .empty,
/// Explicit synchronization of the dma-bufs subsurfaces show
/// (linux-drm-syncobj-v1, D17), set up at the first one.
syncobj_manager: ?*wp.LinuxDrmSyncobjManagerV1 = null,
explicit: ?Explicit = null,
/// Set up, or found unavailable: implicit synchronization from then on
/// when `explicit` is null.
sync_tried: bool = false,
/// Failed after it was set up: implicit synchronization for what is
/// attached from then on; `explicit` stays for the buffers still in flight.
sync_disabled: bool = false,
/// Translucent subsurfaces and solid-color ones (D17).
alpha_modifier: ?*wp.AlphaModifierV1 = null,
single_pixel: ?*wp.SinglePixelBufferManagerV1 = null,
text_input_manager: ?*zwp.TextInputManagerV3 = null,
data_device_manager: ?*wl.DataDeviceManager = null,
primary_selection_manager: ?*zwp.PrimarySelectionDeviceManagerV1 = null,
cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
gestures: ?*zwp.PointerGesturesV1 = null,
tablet_manager: ?*zwp.TabletManagerV2 = null,
pointer_constraints: ?*zwp.PointerConstraintsV1 = null,
relative_manager: ?*zwp.RelativePointerManagerV1 = null,
shortcuts_manager: ?*zwp.KeyboardShortcutsInhibitManagerV1 = null,
idle_manager: ?*zwp.IdleInhibitManagerV1 = null,
dialog_manager: ?*xdg.WmDialogV1 = null,
icon_manager: ?*xdg.ToplevelIconManagerV1 = null,
/// Icon sizes the compositor prefers, and those still arriving.
icon_sizes: std.ArrayList(u32) = .empty,
icon_sizes_pending: std.ArrayList(u32) = .empty,
session_manager: ?*xdg.SessionManagerV1 = null,
/// The session joined (`startSession`), if any.
session: ?*xdg.SessionV1 = null,
/// Themed cursors, without cursor-shape-v1.
cursor_theme: cursor.Theme,
exporter: ?*zxdg.ExporterV2 = null,
importer: ?*zxdg.ImporterV2 = null,
activation: ?*xdg.ActivationV1 = null,
/// Activation tokens requested and not yet done.
tokens: std.ArrayList(*TokenRequest) = .empty,
/// The desktop shell (D31): layer surfaces, the session lock (with
/// `locked` once the compositor confirmed it), toplevels, workspaces,
/// and idle watches, and background blur.
layer_shell: ?*zwlr.LayerShellV1 = null,
lock_manager: ?*ext.SessionLockManagerV1 = null,
lock: ?*ext.SessionLockV1 = null,
locked: bool = false,
foreign: Foreign = undefined,
effect_manager: ?*ext.BackgroundEffectManagerV1 = null,
blur_capable: bool = false,
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

const FormatModifier = struct { format: u32, modifier: u64 };

/// A dma-buf frame's wl_buffer. The producer's frame is in use until the
/// compositor releases every wl_buffer made from it, so each lives until
/// its release even after a subsurface replaces it. A buffer is attached
/// once: showing a frame again after hiding it makes a new one, so that a
/// release always means the end of one attachment.
const DmabufBuffer = struct {
    backend: *Wayland,
    buffer: *wl.Buffer,
    window: WindowId,
    key: u64,
    /// No subsurface shows it any more.
    retired: bool = false,
    released: bool = false,
    /// Attached with explicit synchronization: wl_buffer.release is
    /// undefined then, and the compositor signals this timeline point
    /// instead, which an eventfd in the loop watches.
    release: ?*Timeline = null,
    release_point: u64 = 0,
    source: Loop.Source = .{ .fd = -1, .events = linux.EPOLL.IN, .func = onReleasePoint },
};

/// A DRM syncobj timeline imported into the compositor, and the last
/// point used on it.
const Timeline = struct {
    handle: u32,
    proxy: *wp.LinuxDrmSyncobjTimelineV1,
    point: u64 = 0,
};

/// Explicit synchronization (linux-drm-syncobj-v1) of the dma-buf frames
/// subsurfaces show.
const Explicit = struct {
    device: syncobj.Device,
    /// Every frame's acquire point, signaled from the CPU as it is
    /// attached: siv shows a frame only once its writes are done (its
    /// implicit fences or the producer's fence signaled, D17).
    acquire: *Timeline,
    /// Release timelines not in use. Each frame in flight has one of its
    /// own, since the compositor may signal release points out of order.
    free: std.ArrayList(*Timeline) = .empty,
};

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

/// A wl_subsurface showing external frames (D17), synchronized with its
/// parent's commits.
const Subsurface = struct {
    surface: *wl.Surface,
    /// Null while an embedder's surface is hidden: without the role it is
    /// unmapped, and its buffer stays the embedder's.
    subsurface: ?*wl.Subsurface,
    viewport: ?*wp.Viewport,
    /// An embedder renders into `surface` (`createEmbedSurface`).
    embed: bool = false,
    buffer: ?*wl.Buffer = null,
    /// `buffer` is this dma-buf's.
    dmabuf: ?*DmabufBuffer = null,
    key: u64 = 0,
    attached: bool = false,
    below: bool = false,
    source: @FieldType(platform.SubsurfaceState, "source") = null,
    /// The viewport destination an embedder's surface was given.
    dest: [2]i32 = .{ 0, 0 },
    /// Its alpha multiplier (alpha-modifier-v1), made when first needed.
    alpha: Alpha = .{},
    /// The solid color below it, made when first needed.
    solid: ?*Solid = null,
    /// Explicit synchronization of its dma-buf frames, made at the first
    /// one and destroyed before a shared-memory frame is attached, which
    /// explicit synchronization does not cover.
    syncobj: ?*wp.LinuxDrmSyncobjSurfaceV1 = null,

    fn destroy(s: *Subsurface, gpa: Allocator) void {
        if (s.solid) |x| x.destroy(gpa);
        s.alpha.deinit();
        if (s.syncobj) |x| x.destroy();
        if (s.buffer) |b| b.destroy();
        if (s.viewport) |v| v.destroy();
        if (s.subsurface) |sub| sub.destroy();
        s.surface.destroy();
        gpa.destroy(s);
    }
};

/// A surface's alpha multiplier: the wp_alpha_modifier_surface_v1, made
/// the first time the alpha drops below 1, and the factor it was given.
const Alpha = struct {
    proxy: ?*wp.AlphaModifierSurfaceV1 = null,
    factor: u32 = std.math.maxInt(u32),

    /// Sets the alpha the surface's next commit applies; true if it
    /// changed. Needs the global unless the alpha is 1.
    fn set(a: *Alpha, manager: ?*wp.AlphaModifierV1, surface: *wl.Surface, alpha: f32) bool {
        const factor: u32 = @intFromFloat(@round(@as(f64, std.math.clamp(alpha, 0, 1)) * std.math.maxInt(u32)));
        if (factor == a.factor) return false;
        const proxy = a.proxy orelse blk: {
            const p = (manager orelse return false).getSurface(surface) catch return false;
            a.proxy = p;
            break :blk p;
        };
        proxy.setMultiplier(factor);
        a.factor = factor;
        return true;
    }

    /// Before the surface: requests on it after are a protocol error.
    fn deinit(a: *Alpha) void {
        if (a.proxy) |p| p.destroy();
        a.proxy = null;
    }
};

/// A solid color on a subsurface of its own, directly below a subsurface
/// showing external content (D17): a 1x1 single-pixel buffer scaled by
/// its viewport. Synchronized like the content's, so it moves with the
/// window's commits.
const Solid = struct {
    surface: *wl.Surface,
    subsurface: *wl.Subsurface,
    viewport: *wp.Viewport,
    buffer: ?*wl.Buffer = null,
    rgba: [4]u32 = .{ 0, 0, 0, 0 },
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    alpha: Alpha = .{},
    attached: bool = false,

    fn destroy(x: *Solid, gpa: Allocator) void {
        x.alpha.deinit();
        if (x.buffer) |b| b.destroy();
        x.viewport.destroy();
        x.subsurface.destroy();
        x.surface.destroy();
        gpa.destroy(x);
    }
};

/// A toplevel icon object and the buffers it holds.
const Icon = struct {
    proxy: *xdg.ToplevelIconV1,
    buffers: [max_icon_images]?*wl.Buffer = @splat(null),

    fn destroy(icon: Icon) void {
        icon.proxy.destroy();
        for (icon.buffers) |b| if (b) |buf| buf.destroy();
    }
};

const max_icon_images = 16;

pub const Window = struct {
    backend: *Wayland,
    id: WindowId,
    surface: *wl.Surface,
    /// Toplevels and popups; null for layer and lock windows.
    xdg_surface: ?*xdg.Surface,
    /// The role: a toplevel, a popup, a layer surface, or a lock surface.
    toplevel: ?*xdg.Toplevel = null,
    popup: ?*xdg.Popup = null,
    layer: ?*zwlr.LayerSurfaceV1 = null,
    lock_surface: ?*ext.SessionLockSurfaceV1 = null,
    /// Layer windows: what was asked for, and the output it is on (lock
    /// windows too).
    layer_state: platform.LayerState = .{},
    zone: i32 = 0,
    output_id: ?OutputId = null,
    /// Background blur (ext-background-effect-v1) and the region last set.
    effect: ?*ext.BackgroundEffectSurfaceV1 = null,
    blur_region: std.ArrayList(Rect) = .empty,
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    viewport: ?*wp.Viewport = null,
    fractional: ?*wp.FractionalScaleV1 = null,
    fifo: ?*wp.FifoV1 = null,
    /// A Vulkan swapchain commits the surface (`presentExternal`).
    external: bool = false,

    state: WindowState = .{},
    pending: Pending = .{},
    default_size: Size,
    configured: bool = false,
    ack_serial: ?u32 = null,
    /// The sink deferred the pending configure in the current frame.
    ack_deferred: bool = false,
    /// When a deferred configure must be acknowledged anyway.
    ack_deadline: ?u64 = null,
    ack_timer: Timer = .{ .func = onAckTimeout },

    clock: FrameClock = .{},
    frame_task: Loop.Task = .{ .func = runFrame },
    frame_callback: ?*wl.Callback = null,
    /// Frame callbacks asked for with `frame_callback` on the window's
    /// shown frame-slot subsurfaces (D17): a compositor sends frame
    /// callbacks only to visible surfaces, and an opaque subsurface that
    /// covers the window hides it. The first callback of the set to fire
    /// ends the frame; the rest are destroyed with it.
    sub_frame_callbacks: std.ArrayList(*wl.Callback) = .empty,
    /// Predicted presentation time of the frame being rendered.
    frame_target_ns: ?u64 = null,
    feedbacks: [4]Feedback = @splat(.{}),

    entered: [8]OutputId = undefined,
    entered_len: usize = 0,
    preferred_buffer_scale: i32 = 0,
    fractional_v120: u32 = 0,
    applied_buffer_scale: i32 = 1,
    applied_destination: Size = .{},

    swapchain: shm_buffers.Swapchain = .{},
    subsurfaces: std.ArrayList(?*Subsurface) = .empty,
    /// Shown while a pointer is over the window.
    cursor: platform.CursorShape = .default,
    /// The xdg-foreign export, and its handle once the compositor sent it.
    exported: ?*zxdg.ExportedV2 = null,
    export_handle: ?platform.Handle = null,
    /// Another client's toplevel imported as this one's parent.
    imported: ?*zxdg.ImportedV2 = null,
    /// A buffer was committed: the window is mapped.
    mapped: bool = false,
    /// An activation asked for before the window was mapped, sent once
    /// it is (compositors ignore activating an unmapped surface).
    pending_activation: ?platform.Handle = null,
    /// Pointer constraint and shortcut inhibition the window asked for;
    /// each seat holds the protocol objects.
    constraint: platform.ConstraintOptions = .{},
    inhibit_shortcuts: bool = false,
    /// Toplevels: the modal dialog role (xdg-dialog-v1), the icon set last
    /// with its buffers (kept until replaced: buffers must outlive the icon
    /// object, which must outlive the commit that applies it), idle
    /// inhibition with its count, and the window's session object and name.
    dialog: ?*xdg.DialogV1 = null,
    icon: ?Icon = null,
    idle: ?*zwp.IdleInhibitorV1 = null,
    idle_count: u32 = 0,
    session: ?*xdg.ToplevelSessionV1 = null,
    session_name: platform.BoundedString(255) = .{},

    /// Presentation feedback for one commit and the time it was predicted for.
    const Feedback = struct {
        proxy: ?*wp.PresentationFeedback = null,
        target_ns: ?u64 = null,
    };

    /// xdg_toplevel state collected until xdg_surface.configure.
    const Pending = struct {
        width: u32 = 0,
        height: u32 = 0,
        states: platform.WindowStates = .{},
        bounds: ?Size = null,
        capabilities: platform.WmCapabilities = .{},
        decoration: platform.Decoration = .client,
        popup: @FieldType(WindowState, "popup") = null,
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
        .cursor_theme = .init(allocator),
        .compose_table = xkb.xkb_compose_table_new_from_locale(context, composeLocale(), xkb.XKB_COMPOSE_COMPILE_NO_FLAGS),
        .source = .{ .fd = display.getFd(), .events = linux.EPOLL.IN, .func = onReadable },
    };
    self.foreign = .{ .backend = self };
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
    self.foreign.deinit();
    // A lock still held keeps the session locked: dropped, not destroyed.
    self.unlockSession(true);
    if (self.lock_manager) |m| m.destroy();
    if (self.layer_shell) |m| if (m.getVersion() >= 3) m.destroy() else wlDestroy(m);
    if (self.effect_manager) |m| m.destroy();
    // A compositor remembers a session's toplevels as they are destroyed,
    // but drops what a client sent just before hanging up (libwayland's
    // server destroys a client on hangup without reading on), so wait for
    // it to process their destruction, briefly.
    if (self.session != null) self.sync(100 * std.time.ns_per_ms);
    for (self.tokens.items) |t| {
        t.proxy.destroy();
        self.allocator.destroy(t);
    }
    self.tokens.deinit(self.allocator);
    if (self.exporter) |m| m.destroy();
    if (self.importer) |m| m.destroy();
    if (self.activation) |m| m.destroy();
    for (self.seats.items) |s| if (s) |seat| seat.destroy();
    self.cursor_theme.deinit();
    if (self.cursor_shape_manager) |m| m.destroy();
    if (self.gestures) |m| if (m.getVersion() >= 2) m.release() else wlDestroy(m);
    if (self.tablet_manager) |m| m.destroy();
    if (self.pointer_constraints) |m| m.destroy();
    if (self.relative_manager) |m| m.destroy();
    if (self.shortcuts_manager) |m| m.destroy();
    if (self.idle_manager) |m| m.destroy();
    if (self.dialog_manager) |m| m.destroy();
    if (self.icon_manager) |m| m.destroy();
    self.icon_sizes.deinit(self.allocator);
    self.icon_sizes_pending.deinit(self.allocator);
    if (self.session) |x| x.destroy();
    if (self.session_manager) |m| m.destroy();
    for (self.outputs.items) |o| if (o) |out| self.destroyOutput(out);
    self.windows.deinit(self.allocator);
    self.seats.deinit(self.allocator);
    self.outputs.deinit(self.allocator);
    if (self.text_input_manager) |m| m.destroy();
    if (self.primary_selection_manager) |m| m.destroy();
    if (self.data_device_manager) |m| wlDestroy(m);
    if (self.decoration_manager) |m| m.destroy();
    if (self.fifo_manager) |m| m.destroy();
    if (self.dmabuf_feedback) |f| f.destroy();
    if (self.dmabuf) |m| m.destroy();
    for (self.dmabuf_buffers.items) |b| {
        self.endRelease(b, false);
        b.buffer.destroy();
        self.allocator.destroy(b);
    }
    self.dmabuf_buffers.deinit(self.allocator);
    if (self.explicit) |*e| {
        for (e.free.items) |t| self.destroyTimeline(e.device, t);
        e.free.deinit(self.allocator);
        self.destroyTimeline(e.device, e.acquire);
        e.device.close();
        self.explicit = null;
    }
    if (self.syncobj_manager) |m| m.destroy();
    self.dmabuf_formats.deinit(self.allocator);
    self.dmabuf_pending.deinit(self.allocator);
    if (self.dmabuf_table.len > 0) _ = linux.munmap(self.dmabuf_table.ptr, self.dmabuf_table.len);
    if (self.alpha_modifier) |m| m.destroy();
    if (self.single_pixel) |m| m.destroy();
    if (self.fractional_manager) |m| m.destroy();
    if (self.presentation) |p| p.destroy();
    if (self.viewporter) |v| v.destroy();
    if (self.wm_base) |b| b.destroy();
    if (self.shm) |s| if (s.getVersion() >= 2) s.release() else wlDestroy(s);
    if (self.subcompositor) |c| c.destroy();
    if (self.compositor) |c| wlDestroy(c);
    self.registry.destroy();
    _ = self.display.flush();
    self.display.disconnect();
    xkb.xkb_compose_table_unref(self.compose_table);
    xkb.xkb_context_unref(self.xkb_context);
    self.queue.deinit();
}

/// Waits, at most `timeout_ns`, until the compositor processed every
/// request sent so far, dispatching what arrives meanwhile.
fn sync(self: *Wayland, timeout_ns: u64) void {
    if (self.dead) return;
    const cb = self.display.sync() catch return;
    defer cb.destroy();
    var done = false;
    cb.setListener(*bool, struct {
        fn f(_: *wl.Callback, _: wl.Callback.Event, d: *bool) void {
            d.* = true;
        }
    }.f, &done);
    const deadline = Loop.now() + timeout_ns;
    while (!done) {
        const now = Loop.now();
        if (now >= deadline) return;
        if (self.display.flush() == .SUCCESS) {} else return;
        while (!self.display.prepareRead()) {
            if (self.display.dispatchPending() != .SUCCESS) return;
        }
        var fds = [_]linux.pollfd{.{ .fd = self.display.getFd(), .events = linux.POLL.IN, .revents = 0 }};
        const ms: i32 = @intCast(@max(1, (deadline - now) / std.time.ns_per_ms));
        if (linux.poll(&fds, 1, ms) == 1) {
            if (self.display.readEvents() != .SUCCESS) return;
        } else self.display.cancelRead();
        if (self.display.dispatchPending() != .SUCCESS) return;
    }
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
    } else if (is(interface, wl.Subcompositor)) {
        self.subcompositor = try registry.bind(name, wl.Subcompositor, version);
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
    } else if (is(interface, wp.FifoManagerV1)) {
        self.fifo_manager = try registry.bind(name, wp.FifoManagerV1, version);
    } else if (is(interface, zwp.LinuxDmabufV1)) {
        // Default feedback (version 4) names the main device and the
        // formats external dma-buf frames may have on subsurfaces.
        if (version < 4) return;
        const m = try registry.bind(name, zwp.LinuxDmabufV1, 4);
        self.dmabuf = m;
        const fb = try m.getDefaultFeedback();
        fb.setListener(*Wayland, onDmabufFeedback, self);
        self.dmabuf_feedback = fb;
    } else if (is(interface, wp.LinuxDrmSyncobjManagerV1)) {
        self.syncobj_manager = try registry.bind(name, wp.LinuxDrmSyncobjManagerV1, 1);
    } else if (is(interface, wp.AlphaModifierV1)) {
        self.alpha_modifier = try registry.bind(name, wp.AlphaModifierV1, 1);
    } else if (is(interface, wp.SinglePixelBufferManagerV1)) {
        self.single_pixel = try registry.bind(name, wp.SinglePixelBufferManagerV1, 1);
    } else if (is(interface, zwp.TextInputManagerV3)) {
        const m = try registry.bind(name, zwp.TextInputManagerV3, version);
        self.text_input_manager = m;
        for (self.seats.items) |s| if (s) |seat| seat.addTextInput(m);
    } else if (is(interface, wl.DataDeviceManager)) {
        self.data_device_manager = try registry.bind(name, wl.DataDeviceManager, @min(version, 3));
        for (self.seats.items) |s| if (s) |seat| seat.data.bind(seat.proxy);
    } else if (is(interface, zwp.PrimarySelectionDeviceManagerV1)) {
        self.primary_selection_manager = try registry.bind(name, zwp.PrimarySelectionDeviceManagerV1, version);
        for (self.seats.items) |s| if (s) |seat| seat.data.bind(seat.proxy);
    } else if (is(interface, wp.CursorShapeManagerV1)) {
        self.cursor_shape_manager = try registry.bind(name, wp.CursorShapeManagerV1, @min(version, 2));
        for (self.seats.items) |s| if (s) |seat| seat.addShapeDevice();
    } else if (is(interface, zwp.TabletManagerV2)) {
        const m = try registry.bind(name, zwp.TabletManagerV2, @min(version, 2));
        self.tablet_manager = m;
        for (self.seats.items) |s| if (s) |seat| seat.addTablet(m);
    } else if (is(interface, zwp.PointerConstraintsV1)) {
        self.pointer_constraints = try registry.bind(name, zwp.PointerConstraintsV1, 1);
    } else if (is(interface, zwp.RelativePointerManagerV1)) {
        self.relative_manager = try registry.bind(name, zwp.RelativePointerManagerV1, 1);
    } else if (is(interface, zwp.KeyboardShortcutsInhibitManagerV1)) {
        self.shortcuts_manager = try registry.bind(name, zwp.KeyboardShortcutsInhibitManagerV1, 1);
    } else if (is(interface, zwp.IdleInhibitManagerV1)) {
        self.idle_manager = try registry.bind(name, zwp.IdleInhibitManagerV1, 1);
    } else if (is(interface, xdg.WmDialogV1)) {
        self.dialog_manager = try registry.bind(name, xdg.WmDialogV1, 1);
    } else if (is(interface, xdg.ToplevelIconManagerV1)) {
        const m = try registry.bind(name, xdg.ToplevelIconManagerV1, 1);
        m.setListener(*Wayland, onIconManager, self);
        self.icon_manager = m;
    } else if (is(interface, xdg.SessionManagerV1)) {
        self.session_manager = try registry.bind(name, xdg.SessionManagerV1, 1);
    } else if (is(interface, zwp.PointerGesturesV1)) {
        self.gestures = try registry.bind(name, zwp.PointerGesturesV1, @min(version, 3));
        for (self.seats.items) |s| if (s) |seat| seat.addGestures();
    } else if (is(interface, zxdg.ExporterV2)) {
        self.exporter = try registry.bind(name, zxdg.ExporterV2, 1);
    } else if (is(interface, zxdg.ImporterV2)) {
        self.importer = try registry.bind(name, zxdg.ImporterV2, 1);
    } else if (is(interface, xdg.ActivationV1)) {
        self.activation = try registry.bind(name, xdg.ActivationV1, 1);
    } else if (is(interface, zwlr.LayerShellV1)) {
        self.layer_shell = try registry.bind(name, zwlr.LayerShellV1, @min(version, 4));
    } else if (is(interface, ext.SessionLockManagerV1)) {
        self.lock_manager = try registry.bind(name, ext.SessionLockManagerV1, 1);
    } else if (is(interface, ext.BackgroundEffectManagerV1)) {
        const m = try registry.bind(name, ext.BackgroundEffectManagerV1, 1);
        m.setListener(*Wayland, onEffectManager, self);
        self.effect_manager = m;
    } else if (is(interface, ext.ForeignToplevelListV1)) {
        self.foreign.list_global = .{ .name = name, .version = version };
    } else if (is(interface, zwlr.ForeignToplevelManagerV1)) {
        self.foreign.wlr_global = .{ .name = name, .version = version };
    } else if (is(interface, ext.WorkspaceManagerV1)) {
        self.foreign.workspace_global = .{ .name = name, .version = version };
    } else if (is(interface, ext.IdleNotifierV1)) {
        self.foreign.idle_global = .{ .name = name, .version = version };
    } else if (is(interface, wl.Output)) {
        try self.addOutput(registry, name, version);
    } else if (is(interface, wl.Seat)) {
        const slot = try reserveSlot(Seat, self.allocator, &self.seats);
        const seat = try Seat.create(self, @intCast(slot), registry, name, version);
        self.seats.items[slot] = seat;
        if (self.text_input_manager) |m| seat.addTextInput(m);
        if (self.tablet_manager) |m| seat.addTablet(m);
    }
}

/// Index of a free slot in `list`, appending one if needed.
fn reserveSlot(comptime T: type, allocator: Allocator, list: *std.ArrayList(?*T)) Allocator.Error!usize {
    for (list.items, 0..) |item, i| if (item == null) return i;
    try list.append(allocator, null);
    return list.items.len - 1;
}

fn onDmabufFeedback(_: *zwp.LinuxDmabufFeedbackV1, event: zwp.LinuxDmabufFeedbackV1.Event, self: *Wayland) void {
    switch (event) {
        .main_device => |e| {
            const bytes = e.device.slice(u8);
            if (bytes.len == @sizeOf(u64)) self.main_device = std.mem.readInt(u64, bytes[0..8], @import("builtin").cpu.arch.endian());
        },
        .format_table => |e| {
            defer _ = linux.close(e.fd);
            if (self.dmabuf_table.len > 0) _ = linux.munmap(self.dmabuf_table.ptr, self.dmabuf_table.len);
            self.dmabuf_table = &.{};
            const rc = linux.mmap(null, e.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, e.fd, 0);
            if (e.size == 0 or linux.errno(rc) != .SUCCESS) return;
            self.dmabuf_table = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(rc))[0..e.size];
        },
        .tranche_formats => |e| for (e.indices.slice(u16)) |i| {
            if (@as(usize, i) * 16 + 16 > self.dmabuf_table.len) continue;
            const entry = self.dmabuf_table[@as(usize, i) * 16 ..][0..16];
            const native = @import("builtin").cpu.arch.endian();
            self.dmabuf_pending.append(self.allocator, .{ .format = std.mem.readInt(u32, entry[0..4], native), .modifier = std.mem.readInt(u64, entry[8..16], native) }) catch {};
        },
        .done => {
            std.mem.swap(std.ArrayList(FormatModifier), &self.dmabuf_formats, &self.dmabuf_pending);
            self.dmabuf_pending.clearRetainingCapacity();
            std.mem.sort(FormatModifier, self.dmabuf_formats.items, {}, lessFormat);
        },
        else => {},
    }
}

fn lessFormat(_: void, a: FormatModifier, b: FormatModifier) bool {
    return if (a.format != b.format) a.format < b.format else a.modifier < b.modifier;
}

pub fn supportsDmabuf(self: *Wayland, format: u32, modifier: u64) bool {
    const key: FormatModifier = .{ .format = format, .modifier = modifier };
    return std.sort.binarySearch(FormatModifier, self.dmabuf_formats.items, key, struct {
        fn order(k: FormatModifier, item: FormatModifier) std.math.Order {
            if (k.format != item.format) return std.math.order(k.format, item.format);
            return std.math.order(k.modifier, item.modifier);
        }
    }.order) != null;
}

fn onDmabufRelease(_: *wl.Buffer, _: wl.Buffer.Event, b: *DmabufBuffer) void {
    // Undefined with explicit synchronization: the release point says.
    if (b.release != null) return;
    b.released = true;
    if (b.retired) b.backend.finishDmabuf(b);
}

/// The compositor signaled a buffer's release point: it is done with it.
fn onReleasePoint(source: *Loop.Source, _: u32) void {
    const b: *DmabufBuffer = @fieldParentPtr("source", source);
    const self = b.backend;
    self.endRelease(b, true);
    b.released = true;
    if (b.retired) self.finishDmabuf(b);
}

/// Explicit synchronization, set up the first time a dma-buf is attached:
/// the compositor offers linux-drm-syncobj-v1 and its main device has
/// timeline syncobjs with eventfd waits. Null keeps implicit
/// synchronization.
fn explicitSync(self: *Wayland) ?*Explicit {
    if (self.sync_disabled) return null;
    if (self.explicit) |*e| return e;
    if (self.sync_tried) return null;
    self.sync_tried = true;
    const manager = self.syncobj_manager orelse return null;
    const device = syncobj.Device.open(self.main_device orelse return null) orelse {
        log.info("the compositor offers explicit synchronization, but its device has no timeline syncobjs with eventfd waits (Linux 6.6); implicit synchronization", .{});
        return null;
    };
    const acquire = self.makeTimeline(manager, device) catch {
        device.close();
        return null;
    };
    self.explicit = .{ .device = device, .acquire = acquire };
    return &self.explicit.?;
}

fn makeTimeline(self: *Wayland, manager: *wp.LinuxDrmSyncobjManagerV1, device: syncobj.Device) !*Timeline {
    const handle = try device.create();
    errdefer device.destroy(handle);
    const fd = try device.exportFd(handle);
    // libwayland duplicates the fd as it sends it.
    defer _ = linux.close(fd);
    const t = try self.allocator.create(Timeline);
    errdefer self.allocator.destroy(t);
    t.* = .{ .handle = handle, .proxy = try manager.importTimeline(fd) };
    return t;
}

fn destroyTimeline(self: *Wayland, device: syncobj.Device, t: *Timeline) void {
    t.proxy.destroy();
    device.destroy(t.handle);
    self.allocator.destroy(t);
}

/// Stops watching a buffer's release point. Its timeline is reused once
/// the point signaled (`reuse`), and destroyed otherwise.
fn endRelease(self: *Wayland, b: *DmabufBuffer, reuse: bool) void {
    const t = b.release orelse return;
    b.release = null;
    self.loop.removeSource(&b.source);
    _ = linux.close(b.source.fd);
    const e = &self.explicit.?;
    if (reuse) e.free.append(self.allocator, t) catch self.destroyTimeline(e.device, t) else self.destroyTimeline(e.device, t);
}

/// Before `b` is attached to `s`: its acquire and release points, so that
/// the commit carries them, with explicit synchronization. Without it, or
/// if anything fails (which turns it off for the connection), `s` falls
/// back to implicit synchronization.
fn syncAttach(self: *Wayland, s: *Subsurface, b: *DmabufBuffer) void {
    const e = self.explicitSync() orelse return unsync(s);
    self.explicitPoints(e, s, b) catch |err| {
        log.warn("explicit synchronization failed ({t}); implicit synchronization from now on", .{err});
        // In-flight buffers keep their release points; nothing new uses
        // the timelines.
        for (e.free.items) |t| self.destroyTimeline(e.device, t);
        e.free.clearRetainingCapacity();
        unsync(s);
        self.disableSync();
    };
}

fn explicitPoints(self: *Wayland, e: *Explicit, s: *Subsurface, b: *DmabufBuffer) !void {
    const t = e.free.pop() orelse try self.makeTimeline(self.syncobj_manager.?, e.device);
    errdefer e.free.append(self.allocator, t) catch self.destroyTimeline(e.device, t);
    const efd = try syncobj.eventFd();
    errdefer _ = linux.close(efd);
    try e.device.watch(t.handle, t.point + 1, efd);
    // The frame's writes are done (siv attaches only ready frames), so
    // its acquire point is signaled at once.
    try e.device.signal(e.acquire.handle, e.acquire.point + 1);
    e.acquire.point += 1;
    const surface = s.syncobj orelse try self.syncobj_manager.?.getSurface(s.surface);
    s.syncobj = surface;
    b.source.fd = efd;
    try self.loop.addSource(&b.source);
    t.point += 1;
    b.release = t;
    b.release_point = t.point;
    surface.setAcquirePoint(e.acquire.proxy, @truncate(e.acquire.point >> 32), @truncate(e.acquire.point));
    surface.setReleasePoint(t.proxy, @truncate(t.point >> 32), @truncate(t.point));
}

/// Turns explicit synchronization off for buffers attached from now on.
fn disableSync(self: *Wayland) void {
    for (self.windows.items) |w| if (w) |win| for (win.subsurfaces.items) |sub| if (sub) |x| unsync(x);
    // `explicit` stays for the buffers still in flight; `syncAttach` checks.
    self.sync_disabled = true;
}

/// Back to implicit synchronization for what is attached next. Points
/// set since the last commit are discarded with the object.
fn unsync(s: *Subsurface) void {
    if (s.syncobj) |x| x.destroy();
    s.syncobj = null;
}

/// Whether dma-buf frames are attached with explicit synchronization
/// (tests).
pub fn explicitSyncActive(self: *Wayland) bool {
    return self.explicit != null and !self.sync_disabled;
}

/// A subsurface stops showing its dma-buf buffer, which then lives until
/// released.
fn retireDmabuf(self: *Wayland, s: *Subsurface) void {
    const b = s.dmabuf orelse return;
    s.dmabuf = null;
    s.buffer = null;
    s.key = 0;
    s.attached = false;
    b.retired = true;
    if (b.released) self.finishDmabuf(b);
}

/// Destroys a released, retired buffer, and tells the compositor thread
/// once no buffer of the frame remains in use.
fn finishDmabuf(self: *Wayland, b: *DmabufBuffer) void {
    const window, const key = .{ b.window, b.key };
    for (self.dmabuf_buffers.items, 0..) |x, i| if (x == b) {
        _ = self.dmabuf_buffers.swapRemove(i);
        break;
    };
    b.buffer.destroy();
    self.allocator.destroy(b);
    if (!self.dmabufBusy(window, key)) self.queue.push(.{ .subsurface_released = .{ .window = window, .key = key } });
}

/// Whether the compositor may still read the window's dma-buf frame with
/// this key.
pub fn dmabufBusy(self: *Wayland, window: WindowId, key: u64) bool {
    for (self.dmabuf_buffers.items) |b| if (b.window == window and b.key == key and !(b.retired and b.released)) return true;
    return false;
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
    self.foreign.outputRemoved(id);
    // A lock window's output is gone; layer windows hear it from the
    // compositor (closed).
    for (self.windows.items) |w| if (w) |win| if (win.lock_surface != null and win.output_id == id) {
        self.queue.push(.{ .closed = win.id });
    };
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

pub fn outputOf(proxy: ?*wl.Output) ?*Output {
    const p = proxy orelse return null;
    return @ptrCast(@alignCast(p.getUserData() orelse return null));
}

// Windows ----------------------------------------------------------------

pub fn get(self: *Wayland, id: WindowId) *Window {
    return self.windows.items[id].?;
}

/// The window of a surface from an input event, if it is one of ours.
pub fn windowOf(surface: ?*wl.Surface) ?WindowId {
    const s = surface orelse return null;
    const w: *Window = @ptrCast(@alignCast(s.getUserData() orelse return null));
    return w.id;
}

pub fn createWindow(self: *Wayland, options: platform.WindowOptions) Error!WindowId {
    return switch (options.role) {
        .toplevel => self.createToplevel(options),
        .layer => |l| self.createLayer(l),
        .lock => |o| self.createLockSurface(o),
    };
}

fn createToplevel(self: *Wayland, options: platform.WindowOptions) Error!WindowId {
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
    errdefer self.dropSurfaceExtensions(w);
    try self.addSurfaceExtensions(w);
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
    var has_parent = false;
    if (options.parent) |pid| if (self.get(pid).toplevel) |pt| {
        toplevel.setParent(pt);
        has_parent = true;
    };
    // Another client's window (a portal request's parent): imported by
    // its handle; the compositor parents this toplevel to it.
    if (options.parent == null and options.foreign_parent.len > 0) if (self.importer) |m| {
        var zbuf: [256]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&zbuf, "{s}", .{options.foreign_parent}, 0)) |z| {
            w.imported = m.importToplevel(z) catch null;
        } else |_| {}
        if (w.imported) |imp| {
            imp.setListener(*Window, onImported, w);
            imp.setParentOf(surface);
            has_parent = true;
        }
    };
    if (has_parent and options.modal) if (self.dialog_manager) |m| {
        w.dialog = m.getXdgDialog(toplevel) catch null;
        if (w.dialog) |d| d.setModal();
    };
    // Restored before the first commit, as the protocol requires.
    w.session_name.set(options.session_name);
    if (self.session != null) self.addToSession(w, true);
    // The initial commit without a buffer asks for the first configure.
    surface.commit();
    self.windows.items[slot] = w;
    return w.id;
}

/// The scale and pacing objects every window has when the compositor
/// offers them.
fn addSurfaceExtensions(self: *Wayland, w: *Window) Error!void {
    if (self.fractional_manager != null and self.viewporter != null) {
        w.fractional = self.fractional_manager.?.getFractionalScale(w.surface) catch return error.OutOfMemory;
        w.viewport = self.viewporter.?.getViewport(w.surface) catch return error.OutOfMemory;
    }
    if (self.fifo_manager) |m| w.fifo = m.getFifo(w.surface) catch return error.OutOfMemory;
}

fn dropSurfaceExtensions(_: *Wayland, w: *Window) void {
    if (w.effect) |e| e.destroy();
    if (w.fifo) |f| f.destroy();
    if (w.decoration) |d| d.destroy();
    if (w.viewport) |v| v.destroy();
    if (w.fractional) |f| f.destroy();
}

/// A layer surface (wlr-layer-shell, D31). Its state goes out before the
/// initial commit, which asks for the first configure.
fn createLayer(self: *Wayland, role: platform.LayerRole) Error!WindowId {
    const shell = self.layer_shell orelse return error.Unsupported;
    const st = role.state;
    // A zero size on an axis without both anchors is a protocol error;
    // so is keyboard on_demand before version 4.
    if (!st.valid()) return error.Unsupported;
    if (st.keyboard == .on_demand and shell.getVersion() < 4) return error.Unsupported;
    const out: ?*wl.Output = if (role.output) |id| self.outputProxy(id) orelse return error.Unsupported else null;
    const slot = try reserveSlot(Window, self.allocator, &self.windows);
    const surface = self.compositor.?.createSurface() catch return error.OutOfMemory;
    errdefer surface.destroy();
    var ns: platform.BoundedString(255) = .{};
    ns.set(role.namespace);
    ns.buf[ns.len] = 0;
    const layer = shell.getLayerSurface(surface, out, layerOf(st.layer), ns.buf[0..ns.len :0]) catch return error.OutOfMemory;
    errdefer layer.destroy();
    const w = try self.allocator.create(Window);
    errdefer self.allocator.destroy(w);
    w.* = .{
        .backend = self,
        .id = @intCast(slot),
        .surface = surface,
        .xdg_surface = null,
        .layer = layer,
        .layer_state = st,
        .output_id = role.output,
        .default_size = .{ .width = st.width, .height = st.height },
    };
    errdefer self.dropSurfaceExtensions(w);
    try self.addSurfaceExtensions(w);
    surface.setListener(*Window, onSurface, w);
    layer.setListener(*Window, onLayerSurface, w);
    if (w.fractional) |f| f.setListener(*Window, onFractionalScale, w);
    sendLayerState(w, st.width, st.height);
    surface.commit();
    self.windows.items[slot] = w;
    return w.id;
}

fn layerOf(l: platform.Layer) zwlr.LayerShellV1.Layer {
    return switch (l) {
        .background => .background,
        .bottom => .bottom,
        .top => .top,
        .overlay => .overlay,
    };
}

/// Sends a layer surface's double-buffered state; the zone follows the
/// size given (the configured one, for an automatic zone).
fn sendLayerState(w: *Window, width: u32, height: u32) void {
    const l = w.layer.?;
    const st = w.layer_state;
    l.setSize(st.width, st.height);
    l.setAnchor(.{ .top = st.anchor.top, .bottom = st.anchor.bottom, .left = st.anchor.left, .right = st.anchor.right });
    l.setMargin(st.margin.top, st.margin.right, st.margin.bottom, st.margin.left);
    w.zone = st.zone(width, height);
    l.setExclusiveZone(w.zone);
    l.setKeyboardInteractivity(switch (st.keyboard) {
        .none => .none,
        .exclusive => .exclusive,
        .on_demand => if (l.getVersion() >= 4) .on_demand else .none,
    });
    if (l.getVersion() >= 2) l.setLayer(layerOf(st.layer));
}

pub fn setLayer(self: *Wayland, id: WindowId, state: platform.LayerState) void {
    const w = self.get(id);
    if (w.layer == null or !state.valid()) return;
    w.layer_state = state;
    w.default_size = .{ .width = state.width, .height = state.height };
    sendLayerState(w, w.state.width, w.state.height);
    if (w.configured) w.surface.commit();
}

fn onLayerSurface(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, w: *Window) void {
    switch (event) {
        .configure => |c| {
            w.pending.width = c.width;
            w.pending.height = c.height;
            // An automatic zone follows the size, sent with the commit
            // that answers this configure.
            if (w.layer_state.auto_exclusive) {
                const width = if (c.width != 0) c.width else w.default_size.width;
                const height = if (c.height != 0) c.height else w.default_size.height;
                const zone = w.layer_state.zone(width, height);
                if (zone != w.zone) {
                    w.zone = zone;
                    w.layer.?.setExclusiveZone(zone);
                }
            }
            applyConfigure(w, c.serial);
        },
        .closed => w.backend.queue.push(.{ .closed = w.id }),
    }
}

/// A lock surface (ext-session-lock, D31) on an output, for the lock in
/// progress.
fn createLockSurface(self: *Wayland, output_id: OutputId) Error!WindowId {
    const lock = self.lock orelse return error.Unsupported;
    const out = self.outputProxy(output_id) orelse return error.Unsupported;
    // One lock surface per output, or a protocol error.
    for (self.windows.items) |x| if (x) |o| if (o.lock_surface != null and o.output_id == output_id) return error.Unsupported;
    const slot = try reserveSlot(Window, self.allocator, &self.windows);
    const surface = self.compositor.?.createSurface() catch return error.OutOfMemory;
    errdefer surface.destroy();
    const ls = lock.getLockSurface(surface, out) catch return error.OutOfMemory;
    errdefer ls.destroy();
    const w = try self.allocator.create(Window);
    errdefer self.allocator.destroy(w);
    w.* = .{
        .backend = self,
        .id = @intCast(slot),
        .surface = surface,
        .xdg_surface = null,
        .lock_surface = ls,
        .output_id = output_id,
        .default_size = .{ .width = 1, .height = 1 },
    };
    errdefer self.dropSurfaceExtensions(w);
    try self.addSurfaceExtensions(w);
    surface.setListener(*Window, onSurface, w);
    ls.setListener(*Window, onLockSurface, w);
    if (w.fractional) |f| f.setListener(*Window, onFractionalScale, w);
    // A lock surface gets its configure without a commit; committing
    // before acking it is a protocol error.
    self.windows.items[slot] = w;
    return w.id;
}

fn onLockSurface(_: *ext.SessionLockSurfaceV1, event: ext.SessionLockSurfaceV1.Event, w: *Window) void {
    switch (event) {
        .configure => |c| {
            w.pending.width = c.width;
            w.pending.height = c.height;
            applyConfigure(w, c.serial);
        },
    }
}

pub fn lockSession(self: *Wayland) Error!void {
    const m = self.lock_manager orelse return error.Unsupported;
    if (self.lock != null) return error.Unsupported;
    const lock = m.lock() catch return error.OutOfMemory;
    lock.setListener(*Wayland, onLock, self);
    self.lock = lock;
    self.locked = false;
}

fn onLock(_: *ext.SessionLockV1, event: ext.SessionLockV1.Event, self: *Wayland) void {
    switch (event) {
        .locked => {
            self.locked = true;
            self.queue.push(.{ .lock = .locked });
        },
        .finished => {
            // The lock is inert: destroy it, and its windows are closed.
            if (self.lock) |l| l.destroy();
            self.lock = null;
            self.locked = false;
            self.closeLockWindows();
            self.queue.push(.{ .lock = .finished });
        },
    }
}

fn closeLockWindows(self: *Wayland) void {
    for (self.windows.items) |w| if (w) |win| if (win.lock_surface != null) self.queue.push(.{ .closed = win.id });
}

pub fn unlockSession(self: *Wayland, abandon: bool) void {
    const lock = self.lock orelse return;
    self.lock = null;
    if (self.locked and abandon) {
        // Dropped without a request: the session stays locked.
        wlDestroy(lock);
    } else if (self.locked) {
        lock.unlockAndDestroy();
    } else lock.destroy();
    self.locked = false;
    if (!abandon) self.closeLockWindows();
}

pub fn startToplevels(self: *Wayland) Error!void {
    return self.foreign.startToplevels();
}

pub fn stopToplevels(self: *Wayland) void {
    self.foreign.stopToplevels();
}

pub fn toplevelInfo(self: *Wayland, id: u32) ?platform.ToplevelInfo {
    return self.foreign.toplevel(id);
}

pub fn toplevelRequest(self: *Wayland, id: u32, request: platform.ToplevelRequest) bool {
    return self.foreign.toplevelRequest(id, request);
}

pub fn startWorkspaces(self: *Wayland) Error!void {
    return self.foreign.startWorkspaces();
}

pub fn stopWorkspaces(self: *Wayland) void {
    self.foreign.stopWorkspaces();
}

pub fn workspaceInfo(self: *Wayland, id: u32) ?platform.WorkspaceInfo {
    return self.foreign.workspace(id);
}

pub fn workspaceRequest(self: *Wayland, id: u32, request: platform.WorkspaceRequest) bool {
    return self.foreign.workspaceRequest(id, request);
}

pub fn createIdleWatch(self: *Wayland, timeout_ms: u32, ignore_inhibitors: bool) Error!u32 {
    return self.foreign.createIdleWatch(timeout_ms, ignore_inhibitors);
}

pub fn destroyIdleWatch(self: *Wayland, id: u32) void {
    self.foreign.destroyIdleWatch(id);
}

fn onEffectManager(_: *ext.BackgroundEffectManagerV1, event: ext.BackgroundEffectManagerV1.Event, self: *Wayland) void {
    switch (event) {
        .capabilities => |c| {
            const blur = @as(u32, @bitCast(c.flags)) & 1 != 0;
            if (blur == self.blur_capable) return;
            self.blur_capable = blur;
            self.queue.push(.{ .blur_capable = blur });
        },
    }
}

pub fn shellCapabilities(self: *Wayland) platform.ShellCapabilities {
    const f = &self.foreign;
    return .{
        .layers = self.layer_shell != null,
        .lock = self.lock_manager != null,
        .toplevels = f.list_global != null or f.wlr_global != null,
        .toplevel_management = f.wlr_global != null,
        .workspaces = f.workspace_global != null,
        .idle = f.idle_global != null,
        .blur = self.blur_capable,
    };
}

pub fn canBlur(self: *Wayland) bool {
    return self.blur_capable;
}

/// The window's background effect object exists only while it blurs
/// something: Hyprland (0.56) damages the whole surface at every commit
/// of a surface that has one, region or not, so a window committing a
/// small change each frame (a web view's animation, its display link)
/// was recomposited whole each frame.
pub fn setBlurRegion(self: *Wayland, id: WindowId, region: []const Rect) void {
    const w = self.get(id);
    const manager = self.effect_manager orelse return;
    if (!self.blur_capable and w.blur_region.items.len == 0) return;
    if (sameRects(w.blur_region.items, region)) return;
    w.blur_region.clearRetainingCapacity();
    w.blur_region.appendSlice(self.allocator, region) catch {
        // Without memory to remember it, send it anyway; the next call
        // sends it again.
    };
    if (region.len == 0) {
        // Gone with the next commit.
        if (w.effect) |e| e.destroy();
        w.effect = null;
        return;
    }
    if (w.effect == null) w.effect = manager.getBackgroundEffect(w.surface) catch return self.queue.fail(error.OutOfMemory);
    const effect = w.effect.?;
    const r = self.compositor.?.createRegion() catch return self.queue.fail(error.OutOfMemory);
    defer r.destroy();
    for (region) |rect| r.add(rect.x, rect.y, rect.width, rect.height);
    effect.setBlurRegion(r);
}

fn sameRects(a: []const Rect, b: []const Rect) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

/// The proxy of an announced output.
pub fn outputProxy(self: *Wayland, id: OutputId) ?*wl.Output {
    if (id >= self.outputs.items.len) return null;
    const out = self.outputs.items[id] orelse return null;
    return if (out.announced) out.proxy else null;
}

pub fn firstSeat(self: *Wayland) ?*wl.Seat {
    for (self.seats.items) |s| if (s) |seat| return seat.proxy;
    return null;
}

/// An xdg_popup placed by an xdg_positioner; the grab, if any, is taken
/// before the first commit as the protocol requires.
pub fn createPopup(self: *Wayland, options: platform.PopupOptions) Error!WindowId {
    const parent = self.get(options.parent);
    const pos = options.positioner;
    const slot = try reserveSlot(Window, self.allocator, &self.windows);
    const surface = self.compositor.?.createSurface() catch return error.OutOfMemory;
    errdefer surface.destroy();
    const xdg_surface = self.wm_base.?.getXdgSurface(surface) catch return error.OutOfMemory;
    errdefer xdg_surface.destroy();
    const positioner = try self.makePositioner(pos);
    defer positioner.destroy();
    // A layer window's popups have no xdg parent; the layer surface
    // adopts them before the first commit.
    if (parent.xdg_surface == null and parent.layer == null) return error.Unsupported;
    const popup = xdg_surface.getPopup(parent.xdg_surface, positioner) catch return error.OutOfMemory;
    errdefer popup.destroy();
    if (parent.layer) |l| l.getPopup(popup);
    const w = try self.allocator.create(Window);
    errdefer self.allocator.destroy(w);
    w.* = .{
        .backend = self,
        .id = @intCast(slot),
        .surface = surface,
        .xdg_surface = xdg_surface,
        .popup = popup,
        .default_size = .{ .width = pos.width, .height = pos.height },
    };
    errdefer self.dropSurfaceExtensions(w);
    try self.addSurfaceExtensions(w);
    surface.setListener(*Window, onSurface, w);
    xdg_surface.setListener(*Window, onXdgSurface, w);
    popup.setListener(*Window, onPopup, w);
    if (w.fractional) |f| f.setListener(*Window, onFractionalScale, w);
    if (options.grab) |g| if (self.seatProxy(g.seat)) |seat| popup.grab(seat, g.serial);
    if (!options.input) {
        const empty = self.compositor.?.createRegion() catch return error.OutOfMemory;
        surface.setInputRegion(empty);
        empty.destroy();
    }
    surface.commit();
    self.windows.items[slot] = w;
    return w.id;
}

fn makePositioner(self: *Wayland, pos: platform.Positioner) Error!*xdg.Positioner {
    const positioner = self.wm_base.?.createPositioner() catch return error.OutOfMemory;
    positioner.setSize(@intCast(@max(pos.width, 1)), @intCast(@max(pos.height, 1)));
    const ar = pos.anchor_rect;
    positioner.setAnchorRect(ar.x, ar.y, @max(ar.width, 1), @max(ar.height, 1));
    positioner.setAnchor(@enumFromInt(@intFromEnum(pos.anchor)));
    positioner.setGravity(@enumFromInt(@intFromEnum(pos.gravity)));
    positioner.setConstraintAdjustment(@bitCast(pos.adjustment));
    positioner.setOffset(pos.offset_x, pos.offset_y);
    if (pos.reactive and positioner.getVersion() >= 3) positioner.setReactive();
    return positioner;
}

pub fn repositionPopup(self: *Wayland, id: WindowId, pos: platform.Positioner) void {
    const w = self.get(id);
    const popup = w.popup orelse return;
    // Needs xdg_wm_base 3; older compositors keep the first placement.
    if (popup.getVersion() < 3) return;
    const positioner = self.makePositioner(pos) catch return self.queue.fail(error.OutOfMemory);
    defer positioner.destroy();
    self.reposition_token +%= 1;
    popup.reposition(positioner, self.reposition_token);
}

fn onPopup(_: *xdg.Popup, event: xdg.Popup.Event, w: *Window) void {
    switch (event) {
        .configure => |c| {
            w.pending.width = @intCast(@max(c.width, 0));
            w.pending.height = @intCast(@max(c.height, 0));
            w.pending.popup = .{ .x = c.x, .y = c.y };
        },
        .popup_done => w.backend.queue.push(.{ .close_requested = w.id }),
        .repositioned => {},
    }
}

pub fn destroyWindow(self: *Wayland, id: WindowId) void {
    const w = self.get(id);
    if (self.frame_window == w) self.frame_window = null;
    for (self.seats.items) |s| if (s) |seat| seat.forgetWindow(id);
    self.queue.purge(id);
    self.loop.unschedule(&w.frame_task);
    self.loop.cancelTimer(&w.ack_timer);
    for (w.feedbacks) |f| if (f.proxy) |fb| fb.destroy();
    endFrameCallbacks(w);
    w.sub_frame_callbacks.deinit(self.allocator);
    if (w.effect) |e| e.destroy();
    w.blur_region.deinit(self.allocator);
    if (w.fifo) |f| f.destroy();
    if (w.fractional) |f| f.destroy();
    if (w.viewport) |v| v.destroy();
    if (w.decoration) |d| d.destroy();
    for (w.subsurfaces.items) |sub| if (sub) |x| {
        self.retireDmabuf(x);
        x.destroy(self.allocator);
    };
    if (w.exported) |e| e.destroy();
    if (w.imported) |i| i.destroy();
    if (w.dialog) |d| d.destroy();
    if (w.icon) |i| i.destroy();
    if (w.idle) |i| i.destroy();
    w.subsurfaces.deinit(self.allocator);
    if (w.toplevel) |t| t.destroy();
    // After the toplevel: compositors remember a toplevel's state when its
    // role is destroyed while it is still in the session (KWin does).
    if (w.session) |x| x.destroy();
    if (w.popup) |p| p.destroy();
    if (w.xdg_surface) |x| x.destroy();
    if (w.layer) |l| l.destroy();
    if (w.lock_surface) |l| l.destroy();
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

pub fn deferConfigure(self: *Wayland, id: WindowId) bool {
    const w = self.get(id);
    if (w.ack_serial == null) return false;
    const now = Loop.now();
    if (w.ack_deadline) |d| {
        if (now >= d) return false;
    } else {
        const d = now + platform.configure_timeout_ns;
        self.loop.startTimer(&w.ack_timer, d, 0) catch return false;
        w.ack_deadline = d;
    }
    w.ack_deferred = true;
    return true;
}

pub fn acquireBuffer(self: *Wayland, id: WindowId) Error!Buffer {
    const w = self.get(id);
    return w.swapchain.acquire(self.allocator, self.shm.?, w.state.bufferWidth(), w.state.bufferHeight());
}

pub fn present(self: *Wayland, id: WindowId, buffer: Buffer, damage: ?[]const Rect) void {
    const w = self.get(id);
    const sb = w.swapchain.get(buffer.slot);
    const surface = w.surface;
    self.beforeCommit(w);
    surface.attach(sb.buffer, 0, 0);
    const all = [_]Rect{.{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) }};
    for (damage orelse &all) |r| {
        if (surface.getVersion() >= 4) surface.damageBuffer(r.x, r.y, r.width, r.height) else surface.damage(0, 0, all[0].width, all[0].height);
    }
    surface.commit();
    sb.busy = true;
    if (w.frame_callback != null) w.clock.committed();
    self.mappedNow(w);
}

/// The wl_display and the window's wl_surface, for a Vulkan swapchain.
pub fn vulkanSurface(self: *Wayland, id: WindowId) ?platform.VulkanSurface {
    return .{ .display = self.display, .surface = self.get(id).surface };
}

pub fn mainDevice(self: *Wayland) ?u64 {
    return self.main_device;
}

/// Hands the window's commits to a Vulkan swapchain, or takes them back.
/// While external, the window has no wp_fifo_v1: Mesa's WSI creates one for
/// every swapchain (since Mesa 25), and a second is a protocol error.
pub fn setExternalPresenter(self: *Wayland, id: WindowId, on: bool) void {
    const w = self.get(id);
    if (w.external == on) return;
    w.external = on;
    if (on) {
        if (w.fifo) |f| f.destroy();
        w.fifo = null;
    } else if (self.fifo_manager) |m| {
        w.fifo = m.getFifo(w.surface) catch null;
    }
}

pub fn frameCallbackPending(self: *Wayland, id: WindowId) bool {
    return self.get(id).frame_callback != null;
}

pub fn presentExternal(self: *Wayland, id: WindowId, commit: platform.ExternalCommit) anyerror!void {
    const w = self.get(id);
    std.debug.assert(w.external);
    self.beforeCommit(w);
    // On failure nothing was committed; the requests above stay pending
    // and apply with the next commit.
    try commit.func(commit.ctx);
    if (w.frame_callback != null) w.clock.committed();
    self.mappedNow(w);
}

/// Asks for the window's next frame callback, and on its shown frame-slot
/// subsurfaces, unless one is outstanding; it applies with the next
/// commit.
fn askFrameCallback(self: *Wayland, w: *Window) void {
    if (w.frame_callback != null) return;
    const cb = w.surface.frame() catch return;
    cb.setListener(*Window, onFrameDone, w);
    w.frame_callback = cb;
    self.requestSubsurfaceFrames(w);
}

/// Everything a frame's commit carries besides its buffer and damage: the
/// configure ack, the viewport or buffer scale, the frame callback, FIFO
/// barriers, and presentation feedback.
fn beforeCommit(self: *Wayland, w: *Window) void {
    const surface = w.surface;
    w.clock.handedOff(Loop.now());
    const answers_configure = w.ack_serial != null;
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

    self.askFrameCallback(w);
    // FIFO (D12): an animation frame waits for the previous commit's
    // barrier, so no frame replaces one that was never shown. Answers to
    // configures go out at once.
    if (w.fifo) |f| {
        if (!answers_configure) f.waitBarrier();
        f.setBarrier();
    }
    const target = w.frame_target_ns;
    if (self.presentation) |p| for (&w.feedbacks) |*slot| if (slot.proxy == null) {
        if (p.feedback(surface)) |fb| {
            fb.setListener(*Window, onFeedback, w);
            slot.* = .{ .proxy = fb, .target_ns = target };
        } else |_| {}
        break;
    };
    w.frame_target_ns = null;
}

pub fn setTitle(self: *Wayland, id: WindowId, title: []const u8) void {
    setString(self.get(id).toplevel orelse return, xdg.Toplevel.setTitle, title);
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
    const t = self.get(id).toplevel orelse return;
    if (maximized) t.setMaximized() else t.unsetMaximized();
}

pub fn setFullscreen(self: *Wayland, id: WindowId, fullscreen: bool) void {
    const t = self.get(id).toplevel orelse return;
    if (fullscreen) t.setFullscreen(null) else t.unsetFullscreen();
}

pub fn setMinimized(self: *Wayland, id: WindowId) void {
    if (self.get(id).toplevel) |t| t.setMinimized();
}

pub fn setSizeLimits(self: *Wayland, id: WindowId, min: Size, max: Size) void {
    const t = self.get(id).toplevel orelse return;
    t.setMinSize(@intCast(min.width), @intCast(min.height));
    t.setMaxSize(@intCast(max.width), @intCast(max.height));
}

pub fn beginMove(self: *Wayland, id: WindowId, seat: SeatId, serial: u32) void {
    const s = self.seatProxy(seat) orelse return;
    if (self.get(id).toplevel) |t| t.move(s, serial);
}

pub fn beginResize(self: *Wayland, id: WindowId, seat: SeatId, serial: u32, edge: platform.Edge) void {
    const s = self.seatProxy(seat) orelse return;
    if (self.get(id).toplevel) |t| t.resize(s, serial, @enumFromInt(@intFromEnum(edge)));
}

pub fn showWindowMenu(self: *Wayland, id: WindowId, seat: SeatId, serial: u32, x: i32, y: i32) void {
    const s = self.seatProxy(seat) orelse return;
    if (self.get(id).toplevel) |t| t.showWindowMenu(s, serial, x, y);
}

pub fn setWindowGeometry(self: *Wayland, id: WindowId, g: Rect) void {
    if (self.get(id).xdg_surface) |x| x.setWindowGeometry(g.x, g.y, g.width, g.height);
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

pub fn setTextInput(self: *Wayland, id: SeatId, state: *const platform.TextInputState) void {
    if (id >= self.seats.items.len) return;
    const seat = self.seats.items[id] orelse return;
    if (seat.text_input) |ti| ti.update(state);
}

pub fn createSubsurface(self: *Wayland, id: WindowId) Error!platform.SubsurfaceId {
    const w = self.get(id);
    const sc = self.subcompositor orelse return error.MissingGlobal;
    const slot = try reserveSlot(Subsurface, self.allocator, &w.subsurfaces);
    const surface = self.compositor.?.createSurface() catch return error.OutOfMemory;
    errdefer surface.destroy();
    const subsurface = sc.getSubsurface(surface, w.surface) catch return error.OutOfMemory;
    errdefer subsurface.destroy();
    const viewport = if (self.viewporter) |v| v.getViewport(surface) catch return error.OutOfMemory else null;
    errdefer if (viewport) |v| v.destroy();
    // External content never takes input; the window below gets it.
    const empty = self.compositor.?.createRegion() catch return error.OutOfMemory;
    surface.setInputRegion(empty);
    empty.destroy();
    const s = try self.allocator.create(Subsurface);
    s.* = .{ .surface = surface, .subsurface = subsurface, .viewport = viewport };
    w.subsurfaces.items[slot] = s;
    return @intCast(slot);
}

pub fn createEmbedSurface(self: *Wayland, id: WindowId) Error!platform.EmbedSurface {
    const sub = try self.createSubsurface(id);
    const s = self.get(id).subsurfaces.items[sub].?;
    s.embed = true;
    // Hidden until it has a place.
    s.subsurface.?.destroy();
    s.subsurface = null;
    return .{ .sub = sub, .display = self.display, .surface = s.surface };
}

pub fn destroySubsurface(self: *Wayland, id: WindowId, sub: platform.SubsurfaceId) void {
    const w = self.get(id);
    if (w.subsurfaces.items[sub]) |s| {
        self.retireDmabuf(s);
        s.destroy(self.allocator);
    }
    w.subsurfaces.items[sub] = null;
}

pub fn setSubsurface(self: *Wayland, id: WindowId, sub: platform.SubsurfaceId, state: *const platform.SubsurfaceState) Error!void {
    const w = self.get(id);
    const s = w.subsurfaces.items[sub] orelse return;
    if (s.embed) return self.setEmbedSurface(w, s, state);
    const frame = (if (state.visible) state.frame else null) orelse {
        if (s.attached) {
            s.surface.attach(null, 0, 0);
            s.surface.commit();
            s.attached = false;
            // Shown again, it gets a new buffer.
            self.retireDmabuf(s);
        }
        self.setSolid(w, s, null, 1, false);
        return;
    };
    // The surface shows a frame: a new one damages only what changed.
    const showing = s.attached;
    if (s.buffer == null or s.key != frame.key) {
        const buffer = if (frame.dmabuf) |d| blk: {
            const params = (self.dmabuf orelse return error.MissingGlobal).createParams() catch return error.OutOfMemory;
            defer params.destroy();
            for (d.planes[0..d.plane_count], 0..) |pl, i| params.add(pl.fd, @intCast(i), pl.offset, pl.stride, @truncate(d.modifier >> 32), @truncate(d.modifier));
            // The compositor advertised the format and modifier
            // (`supportsDmabuf`); a buffer it still cannot import is a
            // protocol error, as with Mesa's WSI.
            break :blk params.createImmed(@intCast(frame.width), @intCast(frame.height), d.format, .{}) catch return error.OutOfMemory;
        } else blk: {
            const size = @as(usize, frame.offset) + @as(usize, frame.stride) * frame.height;
            const pool = self.shm.?.createPool(frame.fd, @intCast(size)) catch return error.OutOfMemory;
            defer pool.destroy();
            break :blk pool.createBuffer(@intCast(frame.offset), @intCast(frame.width), @intCast(frame.height), @intCast(frame.stride), .xrgb8888) catch return error.OutOfMemory;
        };
        var tracked: ?*DmabufBuffer = null;
        if (frame.dmabuf != null) {
            const b = self.allocator.create(DmabufBuffer) catch {
                buffer.destroy();
                return error.OutOfMemory;
            };
            b.* = .{ .backend = self, .buffer = buffer, .window = id, .key = frame.key };
            self.dmabuf_buffers.append(self.allocator, b) catch {
                self.allocator.destroy(b);
                buffer.destroy();
                return error.OutOfMemory;
            };
            buffer.setListener(*DmabufBuffer, onDmabufRelease, b);
            tracked = b;
        }
        if (s.dmabuf != null) self.retireDmabuf(s) else if (s.buffer) |old| old.destroy();
        s.buffer = buffer;
        s.dmabuf = tracked;
        s.key = frame.key;
        s.attached = false;
    }
    if (!s.attached) {
        if (s.dmabuf) |b| self.syncAttach(s, b) else unsync(s);
        s.surface.attach(s.buffer, 0, 0);
        const all = [_]platform.Rect{.{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) }};
        const damage = (if (showing) frame.damage.slice() else null) orelse &all;
        for (damage) |r| s.surface.damageBuffer(r.x, r.y, r.width, r.height);
        s.attached = true;
    }
    s.subsurface.?.setPosition(state.rect.x, state.rect.y);
    var restack = false;
    if (state.below != s.below) {
        if (state.below) s.subsurface.?.placeBelow(w.surface) else s.subsurface.?.placeAbove(w.surface);
        s.below = state.below;
        restack = true;
    }
    if (s.viewport) |v| {
        if (!std.meta.eql(state.source, s.source)) {
            const minus_one = wl.Fixed.fromInt(-1);
            if (state.source) |src| {
                v.setSource(wl.Fixed.fromDouble(src.x), wl.Fixed.fromDouble(src.y), wl.Fixed.fromDouble(src.width), wl.Fixed.fromDouble(src.height));
            } else v.setSource(minus_one, minus_one, minus_one, minus_one);
            s.source = state.source;
        }
        v.setDestination(@max(state.rect.width, 1), @max(state.rect.height, 1));
    }
    _ = s.alpha.set(self.alpha_modifier, s.surface, state.alpha);
    s.surface.commit();
    self.setSolid(w, s, state.background, state.alpha, restack);
}

/// Shows, moves, or hides the solid color directly below `s`. Its
/// position and stacking apply with the window's commit; `restack` puts it
/// back below `s` after `s` itself was restacked (or newly made, which
/// puts a subsurface on top).
fn setSolid(self: *Wayland, w: *Window, s: *Subsurface, background: ?platform.SubsurfaceState.Background, alpha: f32, restack: bool) void {
    const want = background orelse {
        if (s.solid) |x| if (x.attached) {
            x.surface.attach(null, 0, 0);
            x.surface.commit();
            x.attached = false;
        };
        return;
    };
    const manager = self.single_pixel orelse return;
    if (self.viewporter == null) return;
    var placed = restack;
    const x = s.solid orelse blk: {
        const x = self.makeSolid(w) catch return self.queue.fail(error.OutOfMemory);
        s.solid = x;
        placed = true;
        break :blk x;
    };
    if (placed) x.subsurface.placeBelow(s.surface);
    x.subsurface.setPosition(want.rect.x, want.rect.y);
    var dirty = false;
    var old: ?*wl.Buffer = null;
    if (x.buffer == null or !std.meta.eql(x.rgba, want.rgba)) {
        const buffer = manager.createU32RgbaBuffer(want.rgba[0], want.rgba[1], want.rgba[2], want.rgba[3]) catch return self.queue.fail(error.OutOfMemory);
        // The one shown goes once the new one is committed.
        old = x.buffer;
        x.buffer = buffer;
        x.rgba = want.rgba;
        x.attached = false;
    }
    if (!x.attached) {
        x.surface.attach(x.buffer, 0, 0);
        x.surface.damageBuffer(0, 0, 1, 1);
        x.attached = true;
        dirty = true;
    }
    if (want.rect.width != x.rect.width or want.rect.height != x.rect.height or dirty) {
        x.viewport.setDestination(@max(want.rect.width, 1), @max(want.rect.height, 1));
        dirty = true;
    }
    x.rect = want.rect;
    if (x.alpha.set(self.alpha_modifier, x.surface, alpha)) dirty = true;
    if (dirty) x.surface.commit();
    if (old) |b| b.destroy();
}

fn makeSolid(self: *Wayland, w: *Window) Error!*Solid {
    const surface = self.compositor.?.createSurface() catch return error.OutOfMemory;
    errdefer surface.destroy();
    const sub = self.subcompositor.?.getSubsurface(surface, w.surface) catch return error.OutOfMemory;
    errdefer sub.destroy();
    const viewport = self.viewporter.?.getViewport(surface) catch return error.OutOfMemory;
    errdefer viewport.destroy();
    const empty = self.compositor.?.createRegion() catch return error.OutOfMemory;
    surface.setInputRegion(empty);
    empty.destroy();
    const x = try self.allocator.create(Solid);
    x.* = .{ .surface = surface, .subsurface = sub, .viewport = viewport };
    return x;
}

pub fn subsurfaceFeatures(self: *Wayland) platform.SubsurfaceFeatures {
    return .{ .alpha = self.alpha_modifier != null, .solid = self.single_pixel != null and self.viewporter != null };
}

/// Places an embedder's surface. Position and stacking apply with the
/// window's commit. The viewport's source and destination are the
/// surface's own state, so when they change the surface is committed here
/// too; being synchronized, it applies with the window's commit as well.
/// That commit may fall between the embedder's attach and commit on its
/// thread, which is harmless as long as it attaches only finished frames
/// of the size it was told (D17).
fn setEmbedSurface(self: *Wayland, w: *Window, s: *Subsurface, state: *const platform.SubsurfaceState) Error!void {
    if (!state.visible) {
        if (s.subsurface) |sub| sub.destroy();
        s.subsurface = null;
        self.setSolid(w, s, null, 1, false);
        return;
    }
    var restack = false;
    const sub = s.subsurface orelse blk: {
        const sub = self.subcompositor.?.getSubsurface(s.surface, w.surface) catch return error.OutOfMemory;
        s.subsurface = sub;
        s.below = false;
        restack = true;
        break :blk sub;
    };
    sub.setPosition(state.rect.x, state.rect.y);
    if (state.below != s.below) {
        if (state.below) sub.placeBelow(w.surface) else sub.placeAbove(w.surface);
        s.below = state.below;
        restack = true;
    }
    var commit = false;
    if (s.viewport) |v| {
        const source_changed = !std.meta.eql(state.source, s.source);
        if (source_changed) {
            const minus_one = wl.Fixed.fromInt(-1);
            if (state.source) |src| {
                v.setSource(wl.Fixed.fromDouble(src.x), wl.Fixed.fromDouble(src.y), wl.Fixed.fromDouble(src.width), wl.Fixed.fromDouble(src.height));
            } else v.setSource(minus_one, minus_one, minus_one, minus_one);
            s.source = state.source;
        }
        const dest: [2]i32 = .{ @max(state.rect.width, 1), @max(state.rect.height, 1) };
        if (!std.meta.eql(dest, s.dest) or source_changed) {
            v.setDestination(dest[0], dest[1]);
            s.dest = dest;
            commit = true;
        }
    }
    // The alpha multiplier is the surface's state too.
    if (s.alpha.set(self.alpha_modifier, s.surface, state.alpha)) commit = true;
    if (commit) s.surface.commit();
    self.setSolid(w, s, state.background, state.alpha, restack);
}

/// A bare commit asks for a frame callback too, so that frames that only
/// change subsurfaces (a promoted external frame) are paced by the
/// compositor like the rest: one per refresh while it draws the window,
/// none while it does not (D12, D17).
pub fn commitWindow(self: *Wayland, id: WindowId) void {
    const w = self.get(id);
    self.askFrameCallback(w);
    w.surface.commit();
    if (w.frame_callback != null) w.clock.committed();
}

fn seatData(self: *Wayland, id: SeatId) ?*DataDevice {
    if (id >= self.seats.items.len) return null;
    return if (self.seats.items[id]) |s| s.data else null;
}

pub fn setSelection(self: *Wayland, id: SeatId, kind: platform.SelectionKind, mimes: []const []const u8, serial: u32) Error!u32 {
    const dev = self.seatData(id) orelse return error.MissingGlobal;
    return dev.setSelection(kind, mimes, serial);
}

pub fn selectionMimes(self: *Wayland, id: SeatId, kind: platform.SelectionKind) []const []const u8 {
    const dev = self.seatData(id) orelse return &.{};
    return dev.selectionMimes(kind);
}

pub fn receiveSelection(self: *Wayland, id: SeatId, kind: platform.SelectionKind, mime: []const u8, fd: i32) bool {
    const dev = self.seatData(id) orelse {
        _ = linux.close(fd);
        return false;
    };
    return dev.receiveSelection(kind, mime, fd);
}

pub fn setCursor(self: *Wayland, id: WindowId, shape: platform.CursorShape) void {
    const w = self.get(id);
    if (w.cursor == shape) return;
    w.cursor = shape;
    self.reapplyCursors(id);
}

pub fn setCursorTheme(self: *Wayland, name: []const u8, size: u32) void {
    if (!self.cursor_theme.set(name, size)) return;
    for (self.seats.items) |s| if (s) |seat| if (seat.pointer_focus != null and seat.shape_device == null) seat.applyCursor();
}

/// Shows the window's cursor again on the seats over it: it changed, or
/// a themed one must be loaded for a new scale.
fn reapplyCursors(self: *Wayland, id: WindowId) void {
    for (self.seats.items) |s| if (s) |seat| {
        if (seat.pointer_focus == id) seat.applyCursor();
        if (seat.tablet) |t| t.reapplyCursors(id);
    };
}

pub fn setPointerConstraint(self: *Wayland, id: WindowId, options: platform.ConstraintOptions) void {
    const w = self.get(id);
    w.constraint = options;
    for (self.seats.items) |s| if (s) |seat| seat.applyConstraint(w);
}

pub fn inhibitShortcuts(self: *Wayland, id: WindowId, on: bool) void {
    const w = self.get(id);
    if (w.inhibit_shortcuts == on) return;
    w.inhibit_shortcuts = on;
    for (self.seats.items) |s| if (s) |seat| seat.applyInhibitor(w);
}

// Window features (D17) ------------------------------------------------------

fn onIconManager(_: *xdg.ToplevelIconManagerV1, event: xdg.ToplevelIconManagerV1.Event, self: *Wayland) void {
    switch (event) {
        .icon_size => |e| if (e.size > 0) self.icon_sizes_pending.append(self.allocator, @intCast(e.size)) catch self.queue.fail(error.OutOfMemory),
        .done => {
            std.mem.swap(std.ArrayList(u32), &self.icon_sizes, &self.icon_sizes_pending);
            self.icon_sizes_pending.clearRetainingCapacity();
        },
    }
}

pub fn iconSizes(self: *Wayland) []const u32 {
    return self.icon_sizes.items;
}

pub fn setIcon(self: *Wayland, id: WindowId, icon: ?*const platform.ToplevelIcon) bool {
    const m = self.icon_manager orelse return false;
    const w = self.get(id);
    const toplevel = w.toplevel orelse return false;
    var made: ?Icon = null;
    if (icon) |ic| made = self.makeIcon(ic) catch |err| {
        self.queue.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.SystemResources);
        return true;
    };
    m.setIcon(toplevel, if (made) |i| i.proxy else null);
    // The old icon and its buffers go once the new one is set.
    if (w.icon) |old| old.destroy();
    w.icon = made;
    // Icons apply with the next commit; a mapped window's frames may be
    // far off.
    if (w.mapped) self.commitWindow(id);
    return true;
}

/// An icon object with the name and one wl_shm buffer per image, all in
/// one pool.
fn makeIcon(self: *Wayland, icon: *const platform.ToplevelIcon) !Icon {
    const proxy = try self.icon_manager.?.createIcon();
    var out: Icon = .{ .proxy = proxy };
    errdefer out.destroy();
    if (icon.name.len > 0) {
        var buf: platform.BoundedString(1023) = .{};
        buf.set(icon.name);
        buf.buf[buf.len] = 0;
        proxy.setName(buf.buf[0..buf.len :0]);
    }
    const images = icon.images[0..@min(icon.images.len, max_icon_images)];
    var total: usize = 0;
    for (images) |img| total += @as(usize, img.size) * img.size * 4;
    if (total == 0) return out;
    if (total > std.math.maxInt(i32)) return error.SystemResources;
    const fd_rc = linux.memfd_create("siv-toplevel-icon", linux.MFD.CLOEXEC);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(total))) != .SUCCESS) return error.SystemResources;
    const addr = linux.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(addr) != .SUCCESS) return error.SystemResources;
    const mem: [*]u8 = @ptrFromInt(addr);
    defer _ = linux.munmap(mem, total);
    const pool = try self.shm.?.createPool(fd, @intCast(total));
    defer pool.destroy();
    var offset: usize = 0;
    for (images, 0..) |img, i| {
        const bytes = @as(usize, img.size) * img.size * 4;
        @memcpy(mem[offset..][0..bytes], img.pixels[0..bytes]);
        const b = try pool.createBuffer(@intCast(offset), @intCast(img.size), @intCast(img.size), @intCast(img.size * 4), .argb8888);
        out.buffers[i] = b;
        proxy.addBuffer(b, @intCast(@max(img.scale, 1)));
        offset += bytes;
    }
    return out;
}

pub fn inhibitIdle(self: *Wayland, id: WindowId, on: bool) bool {
    const m = self.idle_manager orelse return false;
    const w = self.get(id);
    if (on) {
        w.idle_count += 1;
        if (w.idle == null) w.idle = m.createInhibitor(w.surface) catch blk: {
            self.queue.fail(error.OutOfMemory);
            break :blk null;
        };
    } else if (w.idle_count > 0) {
        w.idle_count -= 1;
        if (w.idle_count == 0) if (w.idle) |i| {
            i.destroy();
            w.idle = null;
        };
    }
    return true;
}

pub fn startSession(self: *Wayland, reason: platform.SessionReason, id: []const u8) void {
    const m = self.session_manager orelse return self.queue.push(.{ .session = .{ .kind = .unavailable } });
    if (self.session) |old| old.destroy();
    for (self.windows.items) |w| if (w) |win| if (win.session) |x| {
        x.destroy();
        win.session = null;
    };
    var buf: platform.BoundedString(4000) = .{};
    buf.set(id);
    buf.buf[buf.len] = 0;
    const r: xdg.SessionManagerV1.Reason = switch (reason) {
        .launch => .launch,
        .recover => .recover,
        .restore => .session_restore,
    };
    const session = m.getSession(r, if (id.len > 0) buf.buf[0..buf.len :0] else null) catch return self.queue.fail(error.OutOfMemory);
    session.setListener(*Wayland, onSession, self);
    self.session = session;
    // Windows that are already mapped can only be added.
    for (self.windows.items) |w| if (w) |win| self.addToSession(win, false);
}

pub fn removeSession(self: *Wayland) void {
    const session = self.session orelse return;
    for (self.windows.items) |w| if (w) |win| if (win.session) |x| {
        x.destroy();
        win.session = null;
    };
    session.remove();
    self.session = null;
}

/// Adds a toplevel with a session name to the session, restoring it when
/// `restore` (before its first commit). Names already in use are skipped,
/// since a repeated name is a protocol error.
fn addToSession(self: *Wayland, w: *Window, restore: bool) void {
    const session = self.session orelse return;
    const toplevel = w.toplevel orelse return;
    if (w.session_name.len == 0 or w.session != null) return;
    for (self.windows.items) |o| if (o) |other| if (other != w and other.session != null and std.mem.eql(u8, other.session_name.slice(), w.session_name.slice())) {
        std.log.scoped(.wayland).warn("session name '{s}' is in use by another window", .{w.session_name.slice()});
        return;
    };
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..w.session_name.len], w.session_name.slice());
    buf[w.session_name.len] = 0;
    const name = buf[0..w.session_name.len :0];
    const x = (if (restore) session.restoreToplevel(toplevel, name) else session.addToplevel(toplevel, name)) catch return self.queue.fail(error.OutOfMemory);
    x.setListener(*Window, onToplevelSession, w);
    w.session = x;
}

fn onSession(_: *xdg.SessionV1, event: xdg.SessionV1.Event, self: *Wayland) void {
    var ev: platform.SessionEvent = .{ .kind = switch (event) {
        .created => .created,
        .restored => .restored,
        .replaced => .replaced,
    } };
    if (event == .created) ev.id.set(std.mem.span(event.created.session_id));
    if (event == .replaced) {
        // The session and its toplevel objects are inert now.
        for (self.windows.items) |w| if (w) |win| if (win.session) |x| {
            x.destroy();
            win.session = null;
        };
        if (self.session) |x| x.destroy();
        self.session = null;
    }
    self.queue.push(.{ .session = ev });
}

fn onToplevelSession(_: *xdg.ToplevelSessionV1, event: xdg.ToplevelSessionV1.Event, w: *Window) void {
    switch (event) {
        .restored => w.backend.queue.push(.{ .window_restored = w.id }),
    }
}

pub fn startDrag(self: *Wayland, id: WindowId, seat: SeatId, serial: u32, mimes: []const []const u8, actions: platform.DragActions, icon: ?*const platform.DragIcon) Error!u32 {
    const dev = self.seatData(seat) orelse return error.MissingGlobal;
    return dev.startDrag(self.get(id).surface, mimes, actions, icon, serial);
}

pub fn dragMimes(self: *Wayland, seat: SeatId, offer: u32) []const []const u8 {
    const dev = self.seatData(seat) orelse return &.{};
    return dev.dragMimes(offer);
}

pub fn acceptDrag(self: *Wayland, seat: SeatId, offer: u32, mime: ?[]const u8, actions: platform.DragActions, preferred: platform.DragAction) void {
    if (self.seatData(seat)) |dev| dev.acceptDrag(offer, mime, actions, preferred);
}

pub fn receiveDrag(self: *Wayland, seat: SeatId, offer: u32, mime: []const u8, fd: i32) bool {
    const dev = self.seatData(seat) orelse {
        _ = linux.close(fd);
        return false;
    };
    return dev.receiveDrag(offer, mime, fd);
}

pub fn finishDrag(self: *Wayland, seat: SeatId, offer: u32, action: platform.DragAction) void {
    if (self.seatData(seat)) |dev| dev.finishDrag(offer, action);
}

pub fn setDragIcon(self: *Wayland, seat: SeatId, source: u32, icon: *const platform.DragIcon) Error!bool {
    const dev = self.seatData(seat) orelse return false;
    return dev.setDragIcon(source, icon);
}

pub fn cancelDrag(self: *Wayland, seat: SeatId, source: u32) void {
    if (self.seatData(seat)) |dev| dev.cancelDrag(source);
}

// Desktop integration (D19) ---------------------------------------------------

pub fn exportToplevel(self: *Wayland, id: WindowId) void {
    const w = self.get(id);
    if (w.export_handle) |h| return self.queue.push(.{ .exported = .{ .window = id, .handle = h } });
    if (w.exported != null) return; // the handle is on its way
    const none: platform.Event = .{ .exported = .{ .window = id, .handle = .{} } };
    // Only toplevels can be exported.
    if (w.toplevel == null) return self.queue.push(none);
    const exporter = self.exporter orelse return self.queue.push(none);
    const e = exporter.exportToplevel(w.surface) catch return self.queue.push(none);
    e.setListener(*Window, onExported, w);
    w.exported = e;
}

/// The parent went (or its handle was never valid): the window stays,
/// without a parent.
fn onImported(imp: *zxdg.ImportedV2, event: zxdg.ImportedV2.Event, w: *Window) void {
    switch (event) {
        .destroyed => {
            imp.destroy();
            w.imported = null;
        },
    }
}

fn onExported(_: *zxdg.ExportedV2, event: zxdg.ExportedV2.Event, w: *Window) void {
    switch (event) {
        .handle => |h| {
            var handle: platform.Handle = .{};
            handle.set(std.mem.span(h.handle));
            w.export_handle = handle;
            w.backend.queue.push(.{ .exported = .{ .window = w.id, .handle = handle } });
        },
    }
}

const TokenRequest = struct {
    backend: *Wayland,
    proxy: *xdg.ActivationTokenV1,
    window: WindowId,
    request: u32,
};

pub fn requestActivationToken(self: *Wayland, id: WindowId, request: u32, seat: SeatId, serial: u32, app_id: []const u8) void {
    const none: platform.Event = .{ .activation_token = .{ .window = id, .request = request, .token = .{} } };
    const activation = self.activation orelse return self.queue.push(none);
    self.tokens.ensureUnusedCapacity(self.allocator, 1) catch return self.queue.push(none);
    const t = self.allocator.create(TokenRequest) catch return self.queue.push(none);
    const proxy = activation.getActivationToken() catch {
        self.allocator.destroy(t);
        return self.queue.push(none);
    };
    t.* = .{ .backend = self, .proxy = proxy, .window = id, .request = request };
    proxy.setListener(*TokenRequest, onToken, t);
    if (self.seatProxy(seat)) |s| if (serial != 0) proxy.setSerial(serial, s);
    if (app_id.len > 0 and app_id.len < 256) {
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..app_id.len], app_id);
        buf[app_id.len] = 0;
        proxy.setAppId(buf[0..app_id.len :0]);
    }
    if (self.windows.items[id]) |w| proxy.setSurface(w.surface);
    proxy.commit();
    self.tokens.appendAssumeCapacity(t);
}

fn onToken(proxy: *xdg.ActivationTokenV1, event: xdg.ActivationTokenV1.Event, t: *TokenRequest) void {
    switch (event) {
        .done => |d| {
            const self = t.backend;
            var token: platform.Handle = .{};
            token.set(std.mem.span(d.token));
            self.queue.push(.{ .activation_token = .{ .window = t.window, .request = t.request, .token = token } });
            proxy.destroy();
            for (self.tokens.items, 0..) |x, i| if (x == t) {
                _ = self.tokens.swapRemove(i);
                break;
            };
            self.allocator.destroy(t);
        },
    }
}

pub fn activate(self: *Wayland, id: WindowId, token: []const u8) void {
    if (self.activation == null or token.len == 0 or token.len >= 256) return;
    const w = self.get(id);
    var handle: platform.Handle = .{};
    handle.set(token);
    if (!w.mapped) {
        w.pending_activation = handle;
        return;
    }
    self.sendActivation(w, handle.slice());
}

fn sendActivation(self: *Wayland, w: *Window, token: []const u8) void {
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..token.len], token);
    buf[token.len] = 0;
    self.activation.?.activate(buf[0..token.len :0], w.surface);
}

fn mappedNow(self: *Wayland, w: *Window) void {
    if (w.mapped) return;
    w.mapped = true;
    const t = w.pending_activation orelse return;
    w.pending_activation = null;
    self.sendActivation(w, t.slice());
}

fn seatProxy(self: *Wayland, id: SeatId) ?*wl.Seat {
    if (id >= self.seats.items.len) return null;
    return if (self.seats.items[id]) |s| s.proxy else null;
}

fn onXdgSurface(_: *xdg.Surface, event: xdg.Surface.Event, w: *Window) void {
    switch (event) {
        .configure => |c| applyConfigure(w, c.serial),
    }
}

/// A configure is complete (xdg_surface, layer, or lock surface): the
/// window takes the pending state, and a frame answers it.
fn applyConfigure(w: *Window, serial: u32) void {
    const p = w.pending;
    var next = w.state;
    next.width = if (p.width != 0) p.width else if (w.configured) w.state.width else w.default_size.width;
    next.height = if (p.height != 0) p.height else if (w.configured) w.state.height else w.default_size.height;
    next.states = p.states;
    next.bounds = p.bounds;
    next.capabilities = p.capabilities;
    next.decoration = p.decoration;
    next.popup = p.popup;
    next.scale = computeScale(w);
    const changed = !w.configured or !std.meta.eql(next, w.state);
    const rescaled = next.scale.v120 != w.state.scale.v120;
    w.state = next;
    if (rescaled) w.backend.reapplyCursors(w.id);
    w.configured = true;
    w.ack_serial = serial;
    w.clock.configured = true;
    w.clock.suspended = next.states.suspended;
    if (changed) w.backend.queue.push(.{ .configure = .{ .window = w.id, .state = next } });
    w.clock.force();
    scheduleFrame(w);
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

/// Asks for a frame callback on each shown frame-slot subsurface, so that
/// the window's frame ends even when they hide it (see
/// `Window.sub_frame_callbacks`). Each is synchronized, so its commit
/// waits for the window's, which follows. Embedders' surfaces are left
/// alone: committing them is the embedder's (D17).
fn requestSubsurfaceFrames(self: *Wayland, w: *Window) void {
    for (w.subsurfaces.items) |sub| {
        const s = sub orelse continue;
        if (s.embed or s.subsurface == null or !s.attached) continue;
        w.sub_frame_callbacks.ensureUnusedCapacity(self.allocator, 1) catch return;
        const cb = s.surface.frame() catch return;
        cb.setListener(*Window, onFrameDone, w);
        w.sub_frame_callbacks.appendAssumeCapacity(cb);
        s.surface.commit();
    }
}

/// Destroys the window's outstanding frame callbacks; events already
/// queued for them are dropped.
fn endFrameCallbacks(w: *Window) void {
    if (w.frame_callback) |cb| cb.destroy();
    w.frame_callback = null;
    for (w.sub_frame_callbacks.items) |cb| cb.destroy();
    w.sub_frame_callbacks.clearRetainingCapacity();
}

fn onFrameDone(cb: *wl.Callback, event: wl.Callback.Event, w: *Window) void {
    _ = cb;
    switch (event) {
        .done => {
            // The first of the set: the window or one of its subsurfaces
            // reached the screen.
            endFrameCallbacks(w);
            w.clock.doneAt(Loop.now());
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
            const target = for (w.feedbacks) |f| {
                if (f.proxy == fb) break f.target_ns;
            } else null;
            if (toMonotonic(w.backend.presentation_clock, ns)) |t| w.clock.presented(t, p.refresh, target);
        },
        .discarded => {},
    }
    for (&w.feedbacks) |*slot| if (slot.proxy == fb) {
        slot.* = .{};
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
    w.frame_target_ns = time.present_ns;
    w.ack_deferred = false;
    self.queue.sink.send(&.{ .frame = .{ .window = w.id, .time = time } });
    if (self.frame_window == null) return; // destroyed by the sink
    self.frame_window = null;
    w.frame_target_ns = null;
    // A configure must be acknowledged even if the frame showed nothing,
    // unless the sink deferred it.
    if (w.ack_serial != null and !w.ack_deferred) {
        ackPending(w);
        w.surface.commit();
    }
}

fn scheduleFrame(w: *Window) void {
    if (w.clock.ready()) w.backend.loop.schedule(&w.frame_task, .frame);
}

fn ackPending(w: *Window) void {
    const serial = w.ack_serial orelse return;
    if (w.xdg_surface) |x| x.ackConfigure(serial) else if (w.layer) |l| l.ackConfigure(serial) else if (w.lock_surface) |l| l.ackConfigure(serial);
    w.ack_serial = null;
    w.ack_deferred = false;
    w.ack_deadline = null;
    w.backend.loop.cancelTimer(&w.ack_timer);
}

/// A deferred configure ran out of time: force a frame that answers it.
fn onAckTimeout(timer: *Timer) void {
    const w: *Window = @fieldParentPtr("ack_timer", timer);
    w.clock.force();
    scheduleFrame(w);
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
    w.backend.reapplyCursors(w.id);
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

test "presentation timestamps convert between clocks" {
    // Weston stamps presentation with CLOCK_MONOTONIC_RAW.
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC_RAW, &ts);
    const raw: u64 = @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
    const mono = toMonotonic(.MONOTONIC_RAW, raw).?;
    const now = Loop.now();
    try std.testing.expect(mono <= now and now - mono < std.time.ns_per_ms);
    try std.testing.expectEqual(@as(?u64, 12345), toMonotonic(.MONOTONIC, 12345));
}

test "commits carry no commit-timing timestamps" {
    // Regression guard. Mutter 50 holds a timed commit until its frame clock
    // reaches the target, but when the last presentation lacks the vsync
    // flag (headless outputs, or before it has an update-time estimate) it
    // extrapolates from time 0 and schedules the wakeup at about target +
    // now, so the window never maps or freezes mid-animation. siv's target
    // is always the next refresh, which a timestamp cannot improve; re-add
    // commit-timing-v1 only for frames scheduled further ahead.
    for (@import("protocols.zig").globals) |global| {
        try std.testing.expect(!std.mem.eql(u8, global[0], "wp_commit_timing_manager_v1"));
    }
}
