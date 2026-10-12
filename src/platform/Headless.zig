//! Headless backend (D20, D24): windows, outputs, and input without a
//! compositor, on the same loop and frame clock as the Wayland backend.
//! Tests drive the simulated compositor (configure, scale, close, input,
//! hotplug) and read back presented pixels for golden images.
//!
//! Frame callbacks complete at simulated vblanks: multiples of `refresh_ns`
//! from backend creation, timed with loop timers. Configures carry serials
//! and are acknowledged like on Wayland: by a present, at the end of the
//! frame that answers them unless deferred, or when a deferral times out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("platform.zig");
const Loop = platform.Loop;
const Timer = @import("loop").Timer;
const FrameClock = platform.FrameClock;
const Headless = @This();

const Error = platform.Error;
const WindowId = platform.WindowId;
const OutputId = platform.OutputId;
const SeatId = platform.SeatId;
const WindowState = platform.WindowState;
const Buffer = platform.Buffer;
const Rect = platform.Rect;
const Size = platform.Size;

loop: *Loop,
allocator: Allocator,
queue: platform.EventQueue,
windows: std.ArrayList(?*Window) = .empty,
/// The window whose frame event is being delivered; cleared if the sink
/// destroys it.
frame_window: ?*Window = null,
outputs: std.ArrayList(?platform.OutputInfo) = .empty,
refresh_ns: u64,
epoch_ns: u64,
/// Text input state each seat last committed (tests read it back).
text_inputs: [8]TextInputRecord = @splat(.{}),
/// Simulated clipboard and primary selection per seat.
selections: [8][2]SimSelection = @splat(@splat(.{})),
next_source: u32 = 0,
/// dma-buf formats and modifiers subsurfaces accept (tests add them).
dmabuf_formats: std.ArrayList([2]u64) = .empty,
/// Simulated drag and drop per seat, and where each seat's pointer is.
drags: [8]SimDrag = @splat(.{}),
next_offer: u32 = 0,
pointers: [8]SimPointer = @splat(.{}),

pub const Options = struct {
    refresh_ns: u64 = FrameClock.default_refresh_ns,
    /// The initial output. Windows take its integer scale.
    output: platform.OutputInfo = defaultOutput(),
};

fn defaultOutput() platform.OutputInfo {
    var info: platform.OutputInfo = .{ .width = 1920, .height = 1080, .refresh_mhz = 60000 };
    info.name.set("HEADLESS-1");
    info.description.set("siv headless output");
    return info;
}

const Window = struct {
    hl: *Headless,
    id: WindowId,
    state: WindowState,
    title: platform.BoundedString(256) = .{},
    clock: FrameClock = .{},
    frame_task: Loop.Task = .{ .func = runFrame },
    vblank: Timer = .{ .func = onVblank },
    slots: [2]Slot = .{ .{}, .{} },
    /// Slot shown on the simulated screen.
    front: ?u8 = null,
    damage: ?Rect = null,
    /// Serial of the last configure sent, and of the one awaiting an ack.
    configure_serial: u32 = 0,
    ack_serial: ?u32 = null,
    last_ack: ?Ack = null,
    ack_deferred: bool = false,
    ack_deadline: ?u64 = null,
    ack_timer: Timer = .{ .func = onAckTimeout },
    /// Popups: the parent window, and whether it holds a grab.
    parent: ?WindowId = null,
    grab: bool = false,
    /// Top-left corner in output coordinates (toplevels at the origin).
    origin: struct { x: i32 = 0, y: i32 = 0 } = .{},
    /// Subsurface states as applied by the window's commits, and as set
    /// since (applied by the next commit, like sync subsurfaces).
    subsurfaces: std.ArrayList(?platform.SubsurfaceState) = .empty,
    pending_subsurfaces: std.ArrayList(?platform.SubsurfaceState) = .empty,
    /// Commits without a buffer (`commitWindow`).
    bare_commits: u32 = 0,

    const Slot = struct { pixels: []u8 = &.{}, width: u32 = 0, height: u32 = 0 };
};

/// How a configure was acknowledged.
pub const Ack = struct {
    serial: u32,
    /// With a presented buffer, rather than a bare commit.
    with_buffer: bool,
    /// CLOCK_MONOTONIC time of the ack.
    time_ns: u64,
};

/// Presented pixels, in the format of `platform.Buffer`.
pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    /// Bounding box of the damage passed to the last present.
    damage: ?Rect,
};

pub fn create(loop: *Loop, allocator: Allocator, sink: platform.Sink, options: Options) Error!*Headless {
    const hl = try allocator.create(Headless);
    errdefer allocator.destroy(hl);
    hl.* = .{
        .loop = loop,
        .allocator = allocator,
        .queue = .{ .loop = loop, .allocator = allocator, .sink = sink },
        .refresh_ns = options.refresh_ns,
        .epoch_ns = Loop.now(),
    };
    _ = try hl.addOutput(options.output);
    return hl;
}

/// A seat's last committed text input state; `surrounding` is a copy.
pub const TextInputRecord = struct {
    state: platform.TextInputState = .{},
    surrounding: platform.BoundedString(platform.TextInputState.max_surrounding) = .{},
    /// Commits so far (the protocol's serial).
    commits: u32 = 0,
};

/// One seat's clipboard or primary selection: the current offer (another
/// client's data, or this client's own source offered back, as Wayland
/// does) and this client's source.
const SimSelection = struct {
    offer: bool = false,
    /// The offer is this client's source: receiving asks it to send.
    own: bool = false,
    mimes: std.ArrayList([]u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    source: u32 = 0,
    source_mimes: std.ArrayList([]u8) = .empty,

    fn clearMimes(list: *std.ArrayList([]u8), gpa: Allocator) void {
        for (list.items) |m| gpa.free(m);
        list.clearRetainingCapacity();
    }

    fn deinit(sel: *SimSelection, gpa: Allocator) void {
        clearMimes(&sel.mimes, gpa);
        clearMimes(&sel.source_mimes, gpa);
        sel.mimes.deinit(gpa);
        sel.source_mimes.deinit(gpa);
        sel.data.deinit(gpa);
    }
};

const SimPointer = struct { window: ?WindowId = null, x: f64 = 0, y: f64 = 0 };

/// One seat's drag and drop as the simulated compositor sees it: the
/// offer over one of this client's windows (another client's drag, or
/// this client's own), how the client answered it, and this client's
/// drag source.
pub const SimDrag = struct {
    /// The offer's id; 0 when no drag is over a window of this client.
    offer: u32 = 0,
    window: WindowId = 0,
    own: bool = false,
    /// Another client's drag: its mime types, data (the same for every
    /// type), and actions.
    mimes: std.ArrayList([]u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    source_actions: platform.DragActions = .{},
    /// The client's answer: the mime type it accepts (an index into the
    /// offer's types), the actions it takes, and the one it prefers.
    accepted: ?usize = null,
    actions: platform.DragActions = .{},
    preferred: platform.DragAction = .none,
    /// The action negotiated from both sides.
    action: platform.DragAction = .none,
    dropped: bool = false,
    /// How the client ended the last dropped offer: the action it
    /// performed, or none if it refused the drop.
    result: ?platform.DragAction = null,
    /// This client's drag source (0 when none) and what it offers.
    source: u32 = 0,
    source_mimes: std.ArrayList([]u8) = .empty,
    own_actions: platform.DragActions = .{},
    icon: ?struct { width: u32, height: u32, hotspot_x: i32, hotspot_y: i32 } = null,
    /// This client's drag is over another client's window.
    outside: bool = false,

    fn deinit(d: *SimDrag, gpa: Allocator) void {
        SimSelection.clearMimes(&d.mimes, gpa);
        SimSelection.clearMimes(&d.source_mimes, gpa);
        d.mimes.deinit(gpa);
        d.source_mimes.deinit(gpa);
        d.data.deinit(gpa);
    }

    pub fn acceptedMime(d: *const SimDrag) ?[]const u8 {
        const list = if (d.own) d.source_mimes.items else d.mimes.items;
        const i = d.accepted orelse return null;
        return if (i < list.len) list[i] else null;
    }
};

pub fn destroy(hl: *Headless) void {
    for (&hl.selections) |*seat| for (seat) |*sel| sel.deinit(hl.allocator);
    for (&hl.drags) |*d| d.deinit(hl.allocator);
    for (hl.windows.items, 0..) |w, i| if (w != null) hl.destroyWindow(@intCast(i));
    hl.windows.deinit(hl.allocator);
    hl.outputs.deinit(hl.allocator);
    hl.dmabuf_formats.deinit(hl.allocator);
    hl.queue.deinit();
    hl.allocator.destroy(hl);
}

fn get(hl: *Headless, id: WindowId) *Window {
    return hl.windows.items[id].?;
}

fn primaryScale(hl: *Headless) platform.Scale {
    for (hl.outputs.items) |o| if (o) |info| return .int(@intCast(@max(info.scale, 1)));
    return .{};
}

// Platform interface ------------------------------------------------------

pub fn createWindow(hl: *Headless, options: platform.WindowOptions) Error!WindowId {
    const slot = for (hl.windows.items, 0..) |w, i| {
        if (w == null) break i;
    } else blk: {
        try hl.windows.append(hl.allocator, null);
        break :blk hl.windows.items.len - 1;
    };
    const w = try hl.allocator.create(Window);
    w.* = .{
        .hl = hl,
        .id = @intCast(slot),
        .state = .{
            .width = options.width,
            .height = options.height,
            .scale = hl.primaryScale(),
            .decoration = options.decoration,
            .states = .{ .activated = true },
        },
    };
    w.title.set(options.title);
    hl.windows.items[slot] = w;
    // Like a compositor: the initial configure, answered by a frame.
    hl.sendConfigure(w);
    return w.id;
}

/// Places the popup with `platform.positioner.place` against the first
/// output, like a compositor would.
pub fn createPopup(hl: *Headless, options: platform.PopupOptions) Error!WindowId {
    const parent = hl.get(options.parent);
    const r = platform.positioner.place(options.positioner, hl.popupArea(parent));
    const id = try hl.createWindow(.{ .width = @intCast(r.width), .height = @intCast(r.height) });
    const w = hl.get(id);
    w.parent = options.parent;
    w.grab = options.grab != null;
    w.origin = .{ .x = parent.origin.x + r.x, .y = parent.origin.y + r.y };
    w.state.popup = .{ .x = r.x, .y = r.y };
    // The configure createWindow queued carries the placement.
    for (hl.queue.items.items) |*ev| if (ev.* == .configure and ev.configure.window == id) {
        ev.configure.state = w.state;
    };
    return id;
}

pub fn createSubsurface(hl: *Headless, id: WindowId) Error!platform.SubsurfaceId {
    const w = hl.get(id);
    try w.pending_subsurfaces.append(hl.allocator, .{});
    errdefer _ = w.pending_subsurfaces.pop();
    try w.subsurfaces.append(hl.allocator, .{});
    return @intCast(w.subsurfaces.items.len - 1);
}

pub fn createEmbedSurface(hl: *Headless, id: WindowId) Error!platform.EmbedSurface {
    const sub = try hl.createSubsurface(id);
    const w = hl.get(id);
    w.subsurfaces.items[sub].?.embed = true;
    w.pending_subsurfaces.items[sub].?.embed = true;
    return .{ .sub = sub };
}

pub fn destroySubsurface(hl: *Headless, id: WindowId, sub: platform.SubsurfaceId) void {
    const w = hl.get(id);
    const shown = [_]?platform.SubsurfaceState{ w.subsurfaces.items[sub], w.pending_subsurfaces.items[sub] };
    w.subsurfaces.items[sub] = null;
    w.pending_subsurfaces.items[sub] = null;
    for (shown) |st| if (dmabufKey(st)) |key| releaseDmabuf(w, key);
}

pub fn setSubsurface(hl: *Headless, id: WindowId, sub: platform.SubsurfaceId, state: *const platform.SubsurfaceState) Error!void {
    hl.get(id).pending_subsurfaces.items[sub] = state.*;
}

/// No Wayland objects: windows present through `acquireBuffer` only.
pub fn vulkanSurface(_: *Headless, _: WindowId) ?platform.VulkanSurface {
    return null;
}

pub fn mainDevice(_: *Headless) ?u64 {
    return null;
}

pub fn setExternalPresenter(_: *Headless, _: WindowId, _: bool) void {}

pub fn frameCallbackPending(hl: *Headless, id: WindowId) bool {
    return hl.get(id).clock.waiting;
}

pub fn presentExternal(_: *Headless, _: WindowId, _: platform.ExternalCommit) anyerror!void {
    return error.Unsupported; // vulkanSurface is null, so nothing presents externally
}

pub fn commitWindow(hl: *Headless, id: WindowId) void {
    const w = hl.get(id);
    w.bare_commits += 1;
    applySubsurfaces(w);
}

/// Applies pending subsurface states. Like a compositor, it releases a
/// dma-buf frame as soon as no state shows it.
fn applySubsurfaces(w: *Window) void {
    for (w.subsurfaces.items, w.pending_subsurfaces.items) |old, new| {
        const key = dmabufKey(old) orelse continue;
        if (dmabufKey(new) != key) releaseDmabuf(w, key);
    }
    @memcpy(w.subsurfaces.items, w.pending_subsurfaces.items);
}

fn dmabufKey(state: ?platform.SubsurfaceState) ?u64 {
    const st = state orelse return null;
    if (!st.visible) return null;
    const f = st.frame orelse return null;
    return if (f.dmabuf != null) f.key else null;
}

fn releaseDmabuf(w: *Window, key: u64) void {
    if (!w.hl.dmabufBusy(w.id, key)) w.hl.queue.push(.{ .subsurface_released = .{ .window = w.id, .key = key } });
}

/// Lets subsurfaces show dma-bufs of this format and modifier.
pub fn addDmabufFormat(hl: *Headless, format: u32, modifier: u64) Allocator.Error!void {
    try hl.dmabuf_formats.append(hl.allocator, .{ format, modifier });
}

pub fn supportsDmabuf(hl: *Headless, format: u32, modifier: u64) bool {
    for (hl.dmabuf_formats.items) |f| if (f[0] == format and f[1] == modifier) return true;
    return false;
}

/// Whether an applied state shows the dma-buf frame (pending ones count
/// once applied).
pub fn dmabufBusy(hl: *Headless, id: WindowId, key: u64) bool {
    for (hl.get(id).subsurfaces.items) |st| if (dmabufKey(st) == key) return true;
    return false;
}

/// The window's subsurfaces as its last commit applied them.
pub fn subsurfaces(hl: *Headless, id: WindowId) []const ?platform.SubsurfaceState {
    return hl.get(id).subsurfaces.items;
}

/// How many commits carried no buffer.
pub fn bareCommits(hl: *Headless, id: WindowId) u32 {
    return hl.get(id).bare_commits;
}

pub fn repositionPopup(hl: *Headless, id: WindowId, pos: platform.Positioner) void {
    const w = hl.get(id);
    const parent = hl.get(w.parent orelse return);
    const r = platform.positioner.place(pos, hl.popupArea(parent));
    w.origin = .{ .x = parent.origin.x + r.x, .y = parent.origin.y + r.y };
    w.state.popup = .{ .x = r.x, .y = r.y };
    w.state.width = @intCast(r.width);
    w.state.height = @intCast(r.height);
    hl.sendConfigure(w);
}

/// Where popups of `parent` may go: the first output, in its coordinates.
fn popupArea(hl: *Headless, parent: *const Window) platform.positioner.Rect {
    const out = hl.output(0);
    const scale: i32 = if (out) |o| @max(o.scale, 1) else 1;
    return .{
        .x = -parent.origin.x,
        .y = -parent.origin.y,
        .width = if (out) |o| @divTrunc(o.width, scale) else std.math.maxInt(i16),
        .height = if (out) |o| @divTrunc(o.height, scale) else std.math.maxInt(i16),
    };
}

/// Whether `id` is `window` or one of its ancestors.
fn inChain(hl: *Headless, window: WindowId, id: WindowId) bool {
    var cur: ?WindowId = window;
    while (cur) |c| : (cur = hl.get(c).parent) if (c == id) return true;
    return false;
}

pub fn destroyWindow(hl: *Headless, id: WindowId) void {
    const w = hl.get(id);
    hl.loop.unschedule(&w.frame_task);
    hl.loop.cancelTimer(&w.vblank);
    hl.loop.cancelTimer(&w.ack_timer);
    if (hl.frame_window == w) hl.frame_window = null;
    for (&hl.drags, 0..) |*d, seat| if (d.offer != 0 and d.window == id) hl.endOffer(@intCast(seat), d);
    for (&hl.pointers) |*p| if (p.window == id) {
        p.window = null;
    };
    for (w.slots) |s| hl.allocator.free(s.pixels);
    w.subsurfaces.deinit(hl.allocator);
    w.pending_subsurfaces.deinit(hl.allocator);
    hl.queue.purge(id);
    hl.allocator.destroy(w);
    hl.windows.items[id] = null;
}

pub fn windowState(hl: *Headless, id: WindowId) *const WindowState {
    return &hl.get(id).state;
}

pub fn requestFrame(hl: *Headless, id: WindowId) void {
    const w = hl.get(id);
    w.clock.request();
    hl.scheduleFrame(w);
}

pub fn deferConfigure(hl: *Headless, id: WindowId) bool {
    const w = hl.get(id);
    if (w.ack_serial == null) return false;
    const now = Loop.now();
    if (w.ack_deadline) |d| {
        if (now >= d) return false;
    } else {
        const d = now + platform.configure_timeout_ns;
        hl.loop.startTimer(&w.ack_timer, d, 0) catch return false;
        w.ack_deadline = d;
    }
    w.ack_deferred = true;
    return true;
}

pub fn acquireBuffer(hl: *Headless, id: WindowId) Error!Buffer {
    const w = hl.get(id);
    const index: u8 = if (w.front) |f| 1 - f else 0;
    const s = &w.slots[index];
    const width = w.state.bufferWidth();
    const height = w.state.bufferHeight();
    if (s.width != width or s.height != height) {
        const pixels = try hl.allocator.alloc(u8, @as(usize, width) * height * 4);
        hl.allocator.free(s.pixels);
        s.* = .{ .pixels = pixels, .width = width, .height = height };
    }
    return .{ .pixels = s.pixels, .width = width, .height = height, .stride = width * 4, .slot = index };
}

pub fn present(hl: *Headless, id: WindowId, buffer: Buffer, damage: ?[]const Rect) void {
    const w = hl.get(id);
    applySubsurfaces(w);
    hl.ack(w, true);
    w.front = buffer.slot;
    w.damage = if (damage) |rects| bounds(rects) else .{
        .x = 0,
        .y = 0,
        .width = @intCast(buffer.width),
        .height = @intCast(buffer.height),
    };
    w.clock.committed();
    const now = Loop.now();
    const vblank = hl.epoch_ns + ((now - hl.epoch_ns) / hl.refresh_ns + 1) * hl.refresh_ns;
    hl.loop.startTimer(&w.vblank, vblank, 0) catch {
        // Without a timer the frame callback would never come.
        w.clock.done();
        hl.queue.fail(error.OutOfMemory);
    };
}

pub fn output(hl: *Headless, id: OutputId) ?*const platform.OutputInfo {
    if (id >= hl.outputs.items.len) return null;
    return if (hl.outputs.items[id]) |*info| info else null;
}

pub fn setTitle(hl: *Headless, id: WindowId, text: []const u8) void {
    hl.get(id).title.set(text);
}

pub fn setMaximized(hl: *Headless, id: WindowId, maximized: bool) void {
    hl.get(id).state.states.maximized = maximized;
    hl.fillOutput(id);
}

pub fn setFullscreen(hl: *Headless, id: WindowId, fullscreen: bool) void {
    hl.get(id).state.states.fullscreen = fullscreen;
    hl.fillOutput(id);
}

pub fn setMinimized(_: *Headless, _: WindowId) void {}
pub fn setSizeLimits(_: *Headless, _: WindowId, _: Size, _: Size) void {}
pub fn beginMove(_: *Headless, _: WindowId, _: SeatId, _: u32) void {}
pub fn beginResize(_: *Headless, _: WindowId, _: SeatId, _: u32, _: platform.Edge) void {}
pub fn showWindowMenu(_: *Headless, _: WindowId, _: SeatId, _: u32, _: i32, _: i32) void {}
pub fn setWindowGeometry(_: *Headless, _: WindowId, _: Rect) void {}
pub fn setRegion(_: *Headless, _: WindowId, _: platform.Region, _: ?[]const Rect) Error!void {}

pub fn setTextInput(hl: *Headless, seat: SeatId, state: *const platform.TextInputState) void {
    if (seat >= hl.text_inputs.len) return;
    const r = &hl.text_inputs[seat];
    r.surrounding.set(state.surrounding);
    r.state = state.*;
    r.state.surrounding = r.surrounding.slice();
    r.commits += 1;
}

fn selectionOf(hl: *Headless, seat: SeatId, kind: platform.SelectionKind) ?*SimSelection {
    if (seat >= hl.selections.len) return null;
    return &hl.selections[seat][@intFromEnum(kind)];
}

fn copyMimes(hl: *Headless, list: *std.ArrayList([]u8), mimes: []const []const u8) Error!void {
    SimSelection.clearMimes(list, hl.allocator);
    for (mimes) |m| {
        const c = try hl.allocator.dupe(u8, m);
        list.append(hl.allocator, c) catch {
            hl.allocator.free(c);
            return error.OutOfMemory;
        };
    }
}

pub fn setSelection(hl: *Headless, seat: SeatId, kind: platform.SelectionKind, mimes: []const []const u8, _: u32) Error!u32 {
    const sel = hl.selectionOf(seat, kind) orelse return error.OutOfMemory;
    if (sel.source != 0) hl.queue.push(.{ .selection_cancelled = .{ .seat = seat, .kind = kind, .source = sel.source } });
    sel.source = 0;
    try hl.copyMimes(&sel.source_mimes, mimes);
    if (mimes.len == 0) {
        if (sel.own) {
            sel.offer = false;
            sel.own = false;
            hl.queue.push(.{ .selection = .{ .seat = seat, .kind = kind, .offer = false } });
        }
        return 0;
    }
    hl.next_source += 1;
    sel.source = hl.next_source;
    // The compositor offers the new selection to its client too.
    try hl.copyMimes(&sel.mimes, mimes);
    sel.data.clearRetainingCapacity();
    sel.offer = true;
    sel.own = true;
    hl.queue.push(.{ .selection = .{ .seat = seat, .kind = kind, .offer = true } });
    return sel.source;
}

pub fn selectionMimes(hl: *Headless, seat: SeatId, kind: platform.SelectionKind) []const []const u8 {
    const sel = hl.selectionOf(seat, kind) orelse return &.{};
    return if (sel.offer) sel.mimes.items else &.{};
}

pub fn receiveSelection(hl: *Headless, seat: SeatId, kind: platform.SelectionKind, mime: []const u8, fd: i32) bool {
    const sel = hl.selectionOf(seat, kind) orelse {
        _ = std.os.linux.close(fd);
        return false;
    };
    if (!sel.offer) {
        _ = std.os.linux.close(fd);
        return false;
    }
    if (sel.own) {
        const index = for (sel.source_mimes.items, 0..) |m, i| {
            if (std.mem.eql(u8, m, mime)) break i;
        } else {
            _ = std.os.linux.close(fd);
            return false;
        };
        hl.queue.push(.{ .selection_send = .{ .seat = seat, .kind = kind, .source = sel.source, .mime = @intCast(index), .fd = fd } });
        return true;
    }
    // Another client writes its data, possibly more than a pipe holds.
    return hl.writeAsync(sel.data.items, fd);
}

/// Writes `bytes` (copied) to `fd` on a thread of its own, as another
/// client would, and closes it.
fn writeAsync(hl: *Headless, bytes: []const u8, fd: i32) bool {
    const data = hl.allocator.dupe(u8, bytes) catch {
        _ = std.os.linux.close(fd);
        return false;
    };
    const Writer = struct {
        fn run(gpa: Allocator, buf: []u8, out: i32) void {
            // Freed before the reader sees the end of the data, so a test
            // that reads to the end leaks nothing.
            defer _ = std.os.linux.close(out);
            defer gpa.free(buf);
            var done: usize = 0;
            while (done < buf.len) {
                const n = std.os.linux.write(out, buf[done..].ptr, buf.len - done);
                if (std.os.linux.errno(n) != .SUCCESS) return;
                done += n;
            }
        }
    };
    const t = std.Thread.spawn(.{}, Writer.run, .{ hl.allocator, data, fd }) catch {
        hl.allocator.free(data);
        _ = std.os.linux.close(fd);
        return false;
    };
    t.detach();
    return true;
}

/// Simulates another client taking the selection with `data` in `mimes`.
pub fn offerSelection(hl: *Headless, seat: SeatId, kind: platform.SelectionKind, mimes: []const []const u8, data: []const u8) Error!void {
    const sel = hl.selectionOf(seat, kind) orelse return error.OutOfMemory;
    if (sel.source != 0) hl.queue.push(.{ .selection_cancelled = .{ .seat = seat, .kind = kind, .source = sel.source } });
    sel.source = 0;
    try hl.copyMimes(&sel.mimes, mimes);
    sel.data.clearRetainingCapacity();
    try sel.data.appendSlice(hl.allocator, data);
    sel.offer = true;
    sel.own = false;
    hl.queue.push(.{ .selection = .{ .seat = seat, .kind = kind, .offer = true } });
}

/// Simulates another client pasting this client's selection in `mime`:
/// returns the read end of the pipe the client writes to.
pub fn requestSelection(hl: *Headless, seat: SeatId, kind: platform.SelectionKind, mime: []const u8) !i32 {
    const sel = hl.selectionOf(seat, kind) orelse return error.NoSelection;
    if (sel.source == 0) return error.NoSelection;
    const index = for (sel.source_mimes.items, 0..) |m, i| {
        if (std.mem.eql(u8, m, mime)) break i;
    } else return error.NoSuchMime;
    var fds: [2]i32 = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.SystemResources;
    hl.queue.push(.{ .selection_send = .{ .seat = seat, .kind = kind, .source = sel.source, .mime = @intCast(index), .fd = fds[1] } });
    return fds[0];
}

// Drag and drop -------------------------------------------------------------

fn dragOf(hl: *Headless, seat: SeatId) ?*SimDrag {
    return if (seat < hl.drags.len) &hl.drags[seat] else null;
}

/// The seat's offer if it is `offer`.
fn dragOffer(hl: *Headless, seat: SeatId, offer: u32) ?*SimDrag {
    const d = hl.dragOf(seat) orelse return null;
    return if (d.offer != 0 and d.offer == offer) d else null;
}

pub fn startDrag(hl: *Headless, _: WindowId, seat: SeatId, _: u32, mimes: []const []const u8, actions: platform.DragActions, icon: ?*const platform.DragIcon) Error!u32 {
    const d = hl.dragOf(seat) orelse return error.MissingGlobal;
    try hl.copyMimes(&d.source_mimes, mimes);
    if (d.source != 0) hl.queue.push(.{ .drag_source = .{ .seat = seat, .source = d.source, .phase = .cancelled } });
    hl.endOffer(seat, d);
    hl.next_source += 1;
    d.source = hl.next_source;
    d.own_actions = actions;
    d.outside = false;
    d.icon = if (icon) |i| .{ .width = i.width, .height = i.height, .hotspot_x = i.hotspot_x, .hotspot_y = i.hotspot_y } else null;
    // The pointer leaves the window for the drag, which enters the window
    // under the pointer at once.
    const p = hl.pointers[seat];
    if (p.window) |w| {
        hl.queue.push(.{ .pointer_leave = .{ .window = w, .seat = seat, .serial = 0 } });
        hl.enterOwn(seat, d, w, p.x, p.y);
    }
    return d.source;
}

fn enterOwn(hl: *Headless, seat: SeatId, d: *SimDrag, window: WindowId, x: f64, y: f64) void {
    hl.next_offer += 1;
    d.offer = hl.next_offer;
    d.window = window;
    d.own = true;
    d.accepted = null;
    d.actions = .{};
    d.preferred = .none;
    d.action = .none;
    d.dropped = false;
    hl.queue.push(.{ .drag_enter = .{ .window = window, .seat = seat, .offer = d.offer, .x = x, .y = y, .source_actions = d.own_actions, .own = true } });
}

/// Forgets the offer over this client's window (a leave without event).
fn endOffer(_: *Headless, _: SeatId, d: *SimDrag) void {
    d.offer = 0;
    d.accepted = null;
    d.dropped = false;
}

/// Ends this client's drag: its source learns the outcome and the
/// pointer comes back to the window under it.
fn endSource(hl: *Headless, seat: SeatId, d: *SimDrag, action: platform.DragAction) void {
    if (d.source == 0) return;
    hl.queue.push(.{ .drag_source = .{ .seat = seat, .source = d.source, .phase = if (action == .none) .cancelled else .finished, .action = action } });
    d.source = 0;
    d.outside = false;
    const p = hl.pointers[seat];
    if (p.window) |w| hl.queue.push(.{ .pointer_enter = .{ .window = w, .seat = seat, .x = p.x, .y = p.y } });
}

pub fn dragMimes(hl: *Headless, seat: SeatId, offer: u32) []const []const u8 {
    const d = hl.dragOffer(seat, offer) orelse return &.{};
    return if (d.own) d.source_mimes.items else d.mimes.items;
}

pub fn acceptDrag(hl: *Headless, seat: SeatId, offer: u32, mime: ?[]const u8, actions: platform.DragActions, preferred: platform.DragAction) void {
    const d = hl.dragOffer(seat, offer) orelse return;
    if (d.dropped) return;
    const list = if (d.own) d.source_mimes.items else d.mimes.items;
    d.accepted = if (mime) |m| for (list, 0..) |own, i| {
        if (std.mem.eql(u8, own, m)) break i;
    } else null else null;
    d.actions = actions;
    d.preferred = preferred;
    const source = if (d.own) d.own_actions else d.source_actions;
    const action: platform.DragAction = if (d.accepted == null) .none else platform.DragActions.negotiate(source, actions, preferred);
    if (d.own) hl.queue.push(.{ .drag_source = .{ .seat = seat, .source = d.source, .phase = .target, .accepted = d.accepted != null } });
    if (action == d.action) return;
    d.action = action;
    hl.queue.push(.{ .drag_actions = .{ .window = d.window, .seat = seat, .offer = d.offer, .source_actions = source, .action = action } });
    if (d.own) hl.queue.push(.{ .drag_source = .{ .seat = seat, .source = d.source, .phase = .action, .action = action } });
}

pub fn receiveDrag(hl: *Headless, seat: SeatId, offer: u32, mime: []const u8, fd: i32) bool {
    const d = hl.dragOffer(seat, offer) orelse {
        _ = std.os.linux.close(fd);
        return false;
    };
    if (!d.own) return hl.writeAsync(d.data.items, fd);
    for (d.source_mimes.items, 0..) |m, i| if (std.mem.eql(u8, m, mime)) {
        hl.queue.push(.{ .drag_send = .{ .seat = seat, .source = d.source, .mime = @intCast(i), .fd = fd } });
        return true;
    };
    _ = std.os.linux.close(fd);
    return false;
}

pub fn finishDrag(hl: *Headless, seat: SeatId, offer: u32, action: platform.DragAction) void {
    const d = hl.dragOffer(seat, offer) orelse return;
    if (!d.dropped) {
        hl.endOffer(seat, d);
        return;
    }
    const done: platform.DragAction = if (action == .ask) .none else action;
    d.result = done;
    const own = d.own;
    hl.endOffer(seat, d);
    if (own) hl.endSource(seat, d, done);
}

/// Simulates another client's drag entering `window` at (x, y), offering
/// `data` in each of `mimes` with `actions`.
pub fn offerDrag(hl: *Headless, seat: SeatId, window: WindowId, mimes: []const []const u8, data: []const u8, actions: platform.DragActions, x: f64, y: f64) Error!void {
    const d = hl.dragOf(seat) orelse return error.OutOfMemory;
    try hl.copyMimes(&d.mimes, mimes);
    d.data.clearRetainingCapacity();
    try d.data.appendSlice(hl.allocator, data);
    d.source_actions = actions;
    d.result = null;
    hl.next_offer += 1;
    d.offer = hl.next_offer;
    d.window = window;
    d.own = false;
    d.accepted = null;
    d.actions = .{};
    d.preferred = .none;
    d.action = .none;
    d.dropped = false;
    hl.queue.push(.{ .drag_enter = .{ .window = window, .seat = seat, .offer = d.offer, .x = x, .y = y, .source_actions = actions } });
}

/// Moves another client's drag within the window it is over.
pub fn moveDrag(hl: *Headless, seat: SeatId, x: f64, y: f64) void {
    const d = hl.dragOf(seat) orelse return;
    if (d.offer == 0 or d.dropped) return;
    hl.queue.push(.{ .drag_motion = .{ .window = d.window, .seat = seat, .x = x, .y = y } });
}

/// The drag over this client's window leaves it (to another client, or
/// it was cancelled).
pub fn leaveDrag(hl: *Headless, seat: SeatId) void {
    const d = hl.dragOf(seat) orelse return;
    if (d.offer == 0 or d.dropped) return;
    hl.queue.push(.{ .drag_leave = .{ .window = d.window, .seat = seat, .offer = d.offer } });
    hl.endOffer(seat, d);
    if (d.source != 0) d.outside = true;
}

/// The user drops the drag over this client's window. As compositors do,
/// a drag no target accepted with an action is cancelled instead.
pub fn dropDrag(hl: *Headless, seat: SeatId) void {
    const d = hl.dragOf(seat) orelse return;
    if (d.offer == 0 or d.dropped) return;
    if (d.accepted == null or d.action == .none) {
        hl.queue.push(.{ .drag_leave = .{ .window = d.window, .seat = seat, .offer = d.offer } });
        d.result = .none;
        hl.endOffer(seat, d);
        if (d.own) hl.endSource(seat, d, .none);
        return;
    }
    d.dropped = true;
    hl.queue.push(.{ .drag_drop = .{ .window = d.window, .seat = seat, .offer = d.offer, .source_actions = if (d.own) d.own_actions else d.source_actions, .action = d.action } });
    if (d.own) hl.queue.push(.{ .drag_source = .{ .seat = seat, .source = d.source, .phase = .dropped } });
}

/// Simulates another client's window taking this client's drag, which
/// left this client's windows (`leaveDrag`): the client accepts `mime`
/// with `action` and the user drops it there. Returns the read end of the
/// pipe the data comes through; null (and the drag cancelled) without a
/// mime type.
pub fn dropOutside(hl: *Headless, seat: SeatId, mime: ?[]const u8, action: platform.DragAction) !?i32 {
    const d = hl.dragOf(seat) orelse return error.NoDrag;
    if (d.source == 0 or !d.outside) return error.NoDrag;
    const m = mime orelse {
        hl.endSource(seat, d, .none);
        return null;
    };
    const index = for (d.source_mimes.items, 0..) |own, i| {
        if (std.mem.eql(u8, own, m)) break i;
    } else return error.NoSuchMime;
    hl.queue.push(.{ .drag_source = .{ .seat = seat, .source = d.source, .phase = .target, .accepted = true } });
    hl.queue.push(.{ .drag_source = .{ .seat = seat, .source = d.source, .phase = .action, .action = action } });
    hl.queue.push(.{ .drag_source = .{ .seat = seat, .source = d.source, .phase = .dropped } });
    var fds: [2]i32 = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.SystemResources;
    hl.queue.push(.{ .drag_send = .{ .seat = seat, .source = d.source, .mime = @intCast(index), .fd = fds[1] } });
    return fds[0];
}

/// The other client finishes the drop `dropOutside` started.
pub fn finishOutside(hl: *Headless, seat: SeatId, action: platform.DragAction) void {
    const d = hl.dragOf(seat) orelse return;
    if (d.outside) hl.endSource(seat, d, action);
}

/// The seat's drag and drop state.
pub fn drag(hl: *const Headless, seat: SeatId) *const SimDrag {
    return &hl.drags[seat];
}

/// Pointer input while this client's drag is under way: the compositor
/// turns motion into drag motion and the release into the drop, and
/// sends no pointer events. Returns whether it consumed the event.
fn dragInput(hl: *Headless, event: platform.Event) bool {
    switch (event) {
        .pointer_enter, .pointer_motion => |m| {
            if (m.seat >= hl.pointers.len) return false;
            hl.pointers[m.seat] = .{ .window = m.window, .x = m.x, .y = m.y };
            const d = &hl.drags[m.seat];
            if (d.source == 0) return false;
            if (d.offer != 0 and d.window == m.window) {
                if (!d.dropped) hl.queue.push(.{ .drag_motion = .{ .window = m.window, .seat = m.seat, .x = m.x, .y = m.y, .time = m.time } });
                return true;
            }
            if (d.offer != 0) {
                if (d.dropped) return true;
                hl.queue.push(.{ .drag_leave = .{ .window = d.window, .seat = m.seat, .offer = d.offer } });
            }
            hl.enterOwn(m.seat, d, m.window, m.x, m.y);
            d.outside = false;
            return true;
        },
        .pointer_leave => |l| {
            if (l.seat >= hl.pointers.len) return false;
            hl.pointers[l.seat].window = null;
            return hl.drags[l.seat].source != 0;
        },
        .pointer_button => |b| {
            if (b.seat >= hl.pointers.len) return false;
            const d = &hl.drags[b.seat];
            if (d.source == 0) return false;
            if (!b.pressed and d.offer != 0) hl.dropDrag(b.seat);
            return true;
        },
        else => return false,
    }
}

/// What a seat's text input last committed.
pub fn textInput(hl: *const Headless, seat: SeatId) *const TextInputRecord {
    return &hl.text_inputs[seat];
}

fn fillOutput(hl: *Headless, id: WindowId) void {
    const w = hl.get(id);
    const info = hl.output(0) orelse return;
    const scale: u32 = @intCast(@max(info.scale, 1));
    if (w.state.states.maximized or w.state.states.fullscreen) {
        w.state.width = @as(u32, @intCast(info.width)) / scale;
        w.state.height = @as(u32, @intCast(info.height)) / scale;
    }
    hl.sendConfigure(w);
}

// Simulated compositor ----------------------------------------------------

/// A compositor-initiated configure. Null keeps the current value.
pub fn configure(hl: *Headless, id: WindowId, size: ?Size, states: ?platform.WindowStates) void {
    const w = hl.get(id);
    if (size) |s| {
        w.state.width = s.width;
        w.state.height = s.height;
    }
    if (states) |s| w.state.states = s;
    w.clock.suspended = w.state.states.suspended;
    hl.sendConfigure(w);
}

/// Sets a window's preferred scale, as fractional-scale-v1 would.
pub fn setScale(hl: *Headless, id: WindowId, scale: platform.Scale) void {
    const w = hl.get(id);
    w.state.scale = scale;
    hl.sendConfigure(w);
}

pub fn requestClose(hl: *Headless, id: WindowId) void {
    hl.queue.push(.{ .close_requested = id });
}

/// Delivers an input event in the dispatch phase, like a seat would.
pub fn inject(hl: *Headless, event: platform.Event) void {
    if (hl.dragInput(event)) return;
    // A press outside the chain of a grabbing popup dismisses the popups
    // and goes nowhere else, as a compositor's popup grab does.
    if (event == .pointer_button and event.pointer_button.pressed) {
        const target = event.pointer_button.window;
        var dismissed = false;
        var i = hl.windows.items.len;
        while (i > 0) {
            i -= 1;
            const w = hl.windows.items[i] orelse continue;
            // Presses in the popup or its child popups keep it open; the
            // parent window is outside the grab.
            if (!w.grab or (target < hl.windows.items.len and hl.windows.items[target] != null and hl.inChain(target, w.id))) continue;
            w.grab = false;
            hl.queue.push(.{ .close_requested = w.id });
            dismissed = true;
        }
        if (dismissed) return;
    }
    hl.queue.push(event);
}

pub fn addOutput(hl: *Headless, info: platform.OutputInfo) Error!OutputId {
    try hl.outputs.append(hl.allocator, info);
    const id: OutputId = @intCast(hl.outputs.items.len - 1);
    hl.queue.push(.{ .output_added = id });
    return id;
}

pub fn removeOutput(hl: *Headless, id: OutputId) void {
    hl.outputs.items[id] = null;
    hl.queue.push(.{ .output_removed = id });
}

/// The window's last presented frame.
pub fn presented(hl: *Headless, id: WindowId) ?Image {
    const w = hl.get(id);
    const s = w.slots[w.front orelse return null];
    return .{ .pixels = s.pixels, .width = s.width, .height = s.height, .stride = s.width * 4, .damage = w.damage };
}

/// How the window's last acknowledged configure was answered.
pub fn lastAck(hl: *Headless, id: WindowId) ?Ack {
    return hl.get(id).last_ack;
}

/// Serial of the configure awaiting an ack, if any.
pub fn pendingConfigure(hl: *Headless, id: WindowId) ?u32 {
    return hl.get(id).ack_serial;
}

/// The window's title as last set.
pub fn title(hl: *Headless, id: WindowId) []const u8 {
    return hl.get(id).title.slice();
}

// Frames ------------------------------------------------------------------

fn sendConfigure(hl: *Headless, w: *Window) void {
    w.configure_serial += 1;
    w.ack_serial = w.configure_serial;
    hl.queue.push(.{ .configure = .{ .window = w.id, .state = w.state } });
    w.clock.configured = true;
    w.clock.force();
    hl.scheduleFrame(w);
}

fn scheduleFrame(hl: *Headless, w: *Window) void {
    if (w.clock.ready()) hl.loop.schedule(&w.frame_task, .frame);
}

fn runFrame(task: *Loop.Task) void {
    const w: *Window = @fieldParentPtr("frame_task", task);
    if (!w.clock.ready()) return;
    const hl = w.hl;
    const time = w.clock.begin(Loop.now());
    hl.frame_window = w;
    w.ack_deferred = false;
    hl.queue.sink.send(&.{ .frame = .{ .window = w.id, .time = time } });
    if (hl.frame_window == null) return; // destroyed by the sink
    hl.frame_window = null;
    if (!w.ack_deferred) hl.ack(w, false);
}

fn ack(hl: *Headless, w: *Window, with_buffer: bool) void {
    const serial = w.ack_serial orelse return;
    w.last_ack = .{ .serial = serial, .with_buffer = with_buffer, .time_ns = Loop.now() };
    if (!with_buffer) applySubsurfaces(w);
    w.ack_serial = null;
    w.ack_deferred = false;
    w.ack_deadline = null;
    hl.loop.cancelTimer(&w.ack_timer);
}

/// A deferred configure ran out of time: force a frame that answers it.
fn onAckTimeout(timer: *Timer) void {
    const w: *Window = @fieldParentPtr("ack_timer", timer);
    w.clock.force();
    w.hl.scheduleFrame(w);
}

fn onVblank(timer: *Timer) void {
    const w: *Window = @fieldParentPtr("vblank", timer);
    w.clock.done();
    w.clock.presented(timer.deadline, w.hl.refresh_ns, null);
    w.hl.scheduleFrame(w);
}

fn bounds(rects: []const Rect) ?Rect {
    if (rects.len == 0) return null;
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    for (rects) |r| {
        x0 = @min(x0, r.x);
        y0 = @min(y0, r.y);
        x1 = @max(x1, r.x + r.width);
        y1 = @max(y1, r.y + r.height);
    }
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

const testing = std.testing;

/// A minimal application: answers every frame by filling the window with
/// a color and records events.
const TestApp = struct {
    hl: *Headless = undefined,
    frames: usize = 0,
    configures: usize = 0,
    last_frame: ?platform.Frame = null,
    color: u32 = 0xff336699,
    keep_animating: bool = false,
    closed: bool = false,
    keys: usize = 0,

    fn onEvent(ctx: ?*anyopaque, ev: *const platform.Event) void {
        const app: *TestApp = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .configure => app.configures += 1,
            .frame => |f| {
                app.frames += 1;
                app.last_frame = f;
                const buf = app.hl.acquireBuffer(f.window) catch unreachable;
                const words = std.mem.bytesAsSlice(u32, buf.pixels);
                @memset(words, app.color);
                app.hl.present(f.window, buf, null);
                if (app.keep_animating) app.hl.requestFrame(f.window);
            },
            .close_requested => |id| {
                app.closed = true;
                app.hl.destroyWindow(id);
            },
            .key => app.keys += 1,
            else => {},
        }
    }
};

test "initial configure produces one frame; animation follows vblanks" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    var app: TestApp = .{};
    const hl = try create(&loop, testing.allocator, .{ .ctx = &app, .func = TestApp.onEvent }, .{
        .refresh_ns = 2 * std.time.ns_per_ms,
    });
    defer hl.destroy();
    app.hl = hl;

    const id = try hl.createWindow(.{ .width = 40, .height = 30, .title = "test" });
    try loop.dispatch(0);
    try testing.expectEqual(@as(usize, 1), app.configures);
    try testing.expectEqual(@as(usize, 1), app.frames);
    const img = hl.presented(id).?;
    try testing.expectEqual(@as(u32, 40), img.width);
    try testing.expectEqual(@as(u32, 0xff336699), std.mem.readInt(u32, img.pixels[0..4], .little));

    // Nothing requested: the loop goes idle.
    try loop.dispatch(10);
    try testing.expectEqual(@as(usize, 1), app.frames);

    // Animating: one frame per vblank, each predicted on the vblank grid.
    app.keep_animating = true;
    hl.requestFrame(id);
    var times: [4]u64 = undefined;
    for (&times, 0..) |*t, i| {
        while (app.frames < 2 + i) try loop.dispatch(-1);
        t.* = app.last_frame.?.time.present_ns;
    }
    // Whole vblanks apart; more than one only if the test thread stalled.
    for (times[1..], times[0..3]) |b, a| {
        try testing.expect(b > a);
        try testing.expectEqual(@as(u64, 0), (b - a) % hl.refresh_ns);
    }
}

test "scale and maximize reconfigure; buffers follow the buffer size" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    var app: TestApp = .{};
    const hl = try create(&loop, testing.allocator, .{ .ctx = &app, .func = TestApp.onEvent }, .{});
    defer hl.destroy();
    app.hl = hl;

    const id = try hl.createWindow(.{ .width = 100, .height = 50 });
    try loop.dispatch(0);
    hl.setScale(id, .{ .v120 = 150 });
    try loop.dispatch(0);
    try testing.expectEqual(@as(usize, 2), app.frames);
    try testing.expectEqual(@as(u32, 125), hl.presented(id).?.width);
    try testing.expectEqual(@as(u32, 63), hl.presented(id).?.height); // 62.5 rounds up

    hl.setMaximized(id, true);
    try loop.dispatch(0);
    const s = hl.windowState(id);
    try testing.expect(s.states.maximized);
    try testing.expectEqual(@as(u32, 1920), s.width);
    try testing.expectEqual(@as(u32, 2400), hl.presented(id).?.width);
}

test "a deferred configure is acked by the next present or after the timeout" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    const App = struct {
        hl: *Headless = undefined,
        /// Defer configures instead of presenting.
        hold: bool = true,
        frames: usize = 0,
        deferred: usize = 0,
        refused: usize = 0,

        fn onEvent(ctx: ?*anyopaque, ev: *const platform.Event) void {
            const app: *@This() = @ptrCast(@alignCast(ctx));
            const f = switch (ev.*) {
                .frame => |f| f,
                else => return,
            };
            app.frames += 1;
            if (app.hold) {
                if (app.hl.deferConfigure(f.window)) app.deferred += 1 else app.refused += 1;
                return;
            }
            const buf = app.hl.acquireBuffer(f.window) catch unreachable;
            app.hl.present(f.window, buf, null);
        }
    };
    var app: App = .{};
    const hl = try create(&loop, testing.allocator, .{ .ctx = &app, .func = App.onEvent }, .{});
    defer hl.destroy();
    app.hl = hl;

    // The initial configure's frame defers; nothing is acknowledged.
    const id = try hl.createWindow(.{ .width = 40, .height = 30 });
    try loop.dispatch(0);
    try testing.expectEqual(@as(usize, 1), app.deferred);
    try testing.expectEqual(@as(?u32, 1), hl.pendingConfigure(id));
    try testing.expect(hl.lastAck(id) == null);
    // The next present acknowledges it with its buffer.
    app.hold = false;
    hl.requestFrame(id);
    try loop.dispatch(0);
    try testing.expectEqual(@as(?u32, null), hl.pendingConfigure(id));
    try testing.expectEqual(Ack{ .serial = 1, .with_buffer = true, .time_ns = hl.lastAck(id).?.time_ns }, hl.lastAck(id).?);
    try testing.expect(!hl.deferConfigure(id));

    // A resize the sink never answers: deferred until the timeout, then a
    // forced frame refuses the deferral and the configure is acknowledged
    // without a buffer.
    app.hold = true;
    const start = Loop.now();
    hl.configure(id, .{ .width = 80, .height = 60 }, null);
    while (hl.pendingConfigure(id) != null) try loop.dispatch(-1);
    const ack_info = hl.lastAck(id).?;
    try testing.expectEqual(@as(u32, 2), ack_info.serial);
    try testing.expect(!ack_info.with_buffer);
    try testing.expect(ack_info.time_ns - start >= platform.configure_timeout_ns);
    try testing.expectEqual(@as(usize, 2), app.deferred);
    try testing.expectEqual(@as(usize, 1), app.refused);
}

test "close, input injection, and output hotplug arrive in the dispatch phase" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    var app: TestApp = .{};
    const hl = try create(&loop, testing.allocator, .{ .ctx = &app, .func = TestApp.onEvent }, .{});
    defer hl.destroy();
    app.hl = hl;

    const id = try hl.createWindow(.{});
    try loop.dispatch(0);
    hl.inject(.{ .key = .{ .window = id, .seat = 0, .keycode = 38, .keysym = 'a', .state = .pressed, .mods = .{}, .time = 0, .serial = 1 } });
    hl.requestClose(id);
    // Queued after the close: purged when the app destroys the window.
    hl.inject(.{ .key = .{ .window = id, .seat = 0, .keycode = 38, .keysym = 'a', .state = .released, .mods = .{}, .time = 0, .serial = 2 } });
    const out = try hl.addOutput(.{ .scale = 2 });
    try loop.dispatch(0);
    try testing.expect(app.closed);
    try testing.expectEqual(@as(usize, 1), app.keys);
    try testing.expectEqual(@as(i32, 2), hl.output(out).?.scale);
    hl.removeOutput(out);
    try testing.expect(hl.output(out) == null);
}

test "drags from other clients and from this client negotiate, transfer, and finish" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();
    const Rec = struct {
        events: std.ArrayList(platform.Event) = .empty,
        seen: usize = 0,
        fn onEvent(ctx: ?*anyopaque, ev: *const platform.Event) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            if (ev.* == .frame or ev.* == .configure) return;
            r.events.append(testing.allocator, ev.*) catch unreachable;
        }
        /// Events since the last call; valid until the next dispatch.
        fn take(r: *@This()) []platform.Event {
            const new = r.events.items[r.seen..];
            r.seen = r.events.items.len;
            return new;
        }
    };
    var rec: Rec = .{};
    defer rec.events.deinit(testing.allocator);
    const hl = try create(&loop, testing.allocator, .{ .ctx = &rec, .func = Rec.onEvent }, .{});
    defer hl.destroy();
    const a = try hl.createWindow(.{});
    const b = try hl.createWindow(.{});
    try loop.dispatch(0);
    _ = rec.take();

    // Another client's drag: refused, then accepted with move preferred
    // from a copy-or-move source, dropped, read, finished.
    try hl.offerDrag(0, a, &.{ "text/uri-list", "text/plain" }, "file:///x", .{ .copy = true, .move = true }, 5, 6);
    try loop.dispatch(0);
    var evs = rec.take();
    try testing.expectEqual(@as(usize, 1), evs.len);
    const offer = evs[0].drag_enter.offer;
    try testing.expect(!evs[0].drag_enter.own);
    try testing.expectEqual(@as(usize, 2), hl.dragMimes(0, offer).len);
    hl.acceptDrag(0, offer, "text/plain", .{ .copy = true, .move = true, .ask = true }, .move);
    hl.dropDrag(0);
    try loop.dispatch(0);
    evs = rec.take();
    try testing.expectEqual(platform.DragAction.move, evs[0].drag_actions.action);
    try testing.expectEqual(platform.DragAction.move, evs[1].drag_drop.action);
    var fds: [2]i32 = undefined;
    _ = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
    try testing.expect(hl.receiveDrag(0, offer, "text/plain", fds[1]));
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const r = std.os.linux.read(fds[0], buf[n..].ptr, buf.len - n);
        if (std.os.linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    _ = std.os.linux.close(fds[0]);
    try testing.expectEqualStrings("file:///x", buf[0..n]);
    hl.finishDrag(0, offer, .move);
    try testing.expectEqual(@as(?platform.DragAction, .move), hl.drag(0).result);
    // Requests for a finished offer do nothing.
    try testing.expectEqual(@as(usize, 0), hl.dragMimes(0, offer).len);

    // A drop nobody accepted is cancelled: a leave, no drop.
    try hl.offerDrag(0, a, &.{"image/png"}, "", .{ .copy = true }, 1, 1);
    hl.dropDrag(0);
    try loop.dispatch(0);
    evs = rec.take();
    try testing.expect(evs[0] == .drag_enter and evs[1] == .drag_leave);
    try testing.expectEqual(@as(?platform.DragAction, .none), hl.drag(0).result);

    // This client's drag: started over window a, it enters a at once,
    // follows the pointer to b, and drops there.
    hl.inject(.{ .pointer_motion = .{ .window = a, .seat = 0, .x = 10, .y = 10 } });
    try loop.dispatch(0);
    _ = rec.take();
    const src = try hl.startDrag(a, 0, 1, &.{"application/x-row"}, .{ .move = true }, null);
    hl.inject(.{ .pointer_motion = .{ .window = b, .seat = 0, .x = 20, .y = 30 } });
    try loop.dispatch(0);
    evs = rec.take();
    try testing.expect(evs[0] == .pointer_leave);
    try testing.expect(evs[1].drag_enter.own and evs[1].drag_enter.window == a);
    try testing.expect(evs[2] == .drag_leave);
    try testing.expectEqual(b, evs[3].drag_enter.window);
    const own_offer = evs[3].drag_enter.offer;
    hl.acceptDrag(0, own_offer, "application/x-row", .{ .copy = true, .move = true }, .copy);
    hl.inject(.{ .pointer_button = .{ .window = b, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } });
    try loop.dispatch(0);
    evs = rec.take();
    // Copy is not offered: move.
    try testing.expectEqual(platform.DragAction.move, hl.drag(0).action);
    try testing.expect(evs[evs.len - 2] == .drag_drop);
    try testing.expectEqual(platform.DragSource.Phase.dropped, evs[evs.len - 1].drag_source.phase);
    hl.finishDrag(0, own_offer, .move);
    try loop.dispatch(0);
    evs = rec.take();
    try testing.expectEqual(src, evs[0].drag_source.source);
    try testing.expectEqual(platform.DragSource.Phase.finished, evs[0].drag_source.phase);
    try testing.expectEqual(platform.DragAction.move, evs[0].drag_source.action);
    try testing.expectEqual(b, evs[1].pointer_enter.window);

    // Dragged out to another client, which reads it and finishes.
    _ = try hl.startDrag(b, 0, 3, &.{ "text/plain", "UTF8_STRING" }, .{ .copy = true }, null);
    hl.leaveDrag(0);
    const fd = (try hl.dropOutside(0, "UTF8_STRING", .copy)).?;
    _ = std.os.linux.close(fd);
    try loop.dispatch(0);
    evs = rec.take();
    const send = evs[evs.len - 1].drag_send;
    try testing.expectEqual(@as(u8, 1), send.mime);
    _ = std.os.linux.close(send.fd);
    hl.finishOutside(0, .copy);
    try loop.dispatch(0);
    evs = rec.take();
    try testing.expectEqual(platform.DragSource.Phase.finished, evs[0].drag_source.phase);
}
