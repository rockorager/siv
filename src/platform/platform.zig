//! Platform backends (D7, D12, D16, D17, D20): Wayland through libwayland-
//! client with wl_shm presentation, xkbcommon input, and the headless backend
//! that runs the same loop for tests.
//!
//! Both backends share the types below and report to one `Sink`. Platform
//! listeners only update state and queue events (D5); the queue is
//! delivered to the sink in the loop's dispatch phase, and `frame` events
//! in the frame phase. Windows, outputs, and seats are plain indices (D20).
//!
//! Imports: loop, wayland (zig-wayland bindings; protocols are listed in
//! protocols.zig), xkbcommon.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Loop = @import("loop").Loop;

pub const FrameClock = @import("FrameClock.zig");
pub const positioner = @import("positioner.zig");
pub const Positioner = positioner.Positioner;
pub const Headless = @import("Headless.zig");
pub const Wayland = @import("Wayland.zig");
/// Sway on its headless backend, for other modules' integration tests.
pub const test_sway = @import("test_sway.zig");

pub const WindowId = u32;
pub const OutputId = u32;
pub const SeatId = u32;

/// A backend chosen at runtime. Every window call forwards to it.
pub const Platform = union(enum) {
    wayland: *Wayland,
    headless: *Headless,

    pub fn createWindow(p: Platform, options: WindowOptions) Error!WindowId {
        return switch (p) {
            inline else => |b| b.createWindow(options),
        };
    }

    /// Creates a popup (an xdg_popup, D17) placed by `options.positioner`
    /// relative to its parent. Its configure carries the placement the
    /// compositor chose (`WindowState.popup`); when the compositor
    /// dismisses it (a grab ended), a `close_requested` event follows.
    /// Destroy popups before their parent, topmost first.
    pub fn createPopup(p: Platform, options: PopupOptions) Error!WindowId {
        return switch (p) {
            inline else => |b| b.createPopup(options),
        };
    }

    pub fn destroyWindow(p: Platform, id: WindowId) void {
        switch (p) {
            inline else => |b| b.destroyWindow(id),
        }
    }

    pub fn window(p: Platform, id: WindowId) *const WindowState {
        return switch (p) {
            inline else => |b| b.windowState(id),
        };
    }

    /// Asks for a `frame` event. Frames follow the window's frame clock.
    pub fn requestFrame(p: Platform, id: WindowId) void {
        switch (p) {
            inline else => |b| b.requestFrame(id),
        }
    }

    /// A buffer of the window's current buffer size to render into. Call
    /// from a `frame` event.
    pub fn acquireBuffer(p: Platform, id: WindowId) Error!Buffer {
        return switch (p) {
            inline else => |b| b.acquireBuffer(id),
        };
    }

    /// Leaves the configure this frame answers unacknowledged, for a sink
    /// that has no content laid out for it yet. Call from a `frame` event
    /// instead of presenting. The next `present` acknowledges it. If none
    /// comes within `configure_timeout_ns` of the first deferral, the
    /// window gets a forced frame in which this returns false, and the
    /// configure is acknowledged with or without a new buffer, so a
    /// stalled sink cannot freeze the window. Also false when no configure
    /// is pending.
    pub fn deferConfigure(p: Platform, id: WindowId) bool {
        return switch (p) {
            inline else => |b| b.deferConfigure(id),
        };
    }

    /// Shows `buffer`. `damage` is in buffer pixels; null damages all.
    pub fn present(p: Platform, id: WindowId, buffer: Buffer, damage: ?[]const Rect) void {
        switch (p) {
            inline else => |b| b.present(id, buffer, damage),
        }
    }

    pub fn output(p: Platform, id: OutputId) ?*const OutputInfo {
        return switch (p) {
            inline else => |b| b.output(id),
        };
    }

    pub fn setTitle(p: Platform, id: WindowId, title: []const u8) void {
        switch (p) {
            inline else => |b| b.setTitle(id, title),
        }
    }

    pub fn setMaximized(p: Platform, id: WindowId, maximized: bool) void {
        switch (p) {
            inline else => |b| b.setMaximized(id, maximized),
        }
    }

    pub fn setFullscreen(p: Platform, id: WindowId, fullscreen: bool) void {
        switch (p) {
            inline else => |b| b.setFullscreen(id, fullscreen),
        }
    }

    pub fn setMinimized(p: Platform, id: WindowId) void {
        switch (p) {
            inline else => |b| b.setMinimized(id),
        }
    }

    pub fn setSizeLimits(p: Platform, id: WindowId, min: Size, max: Size) void {
        switch (p) {
            inline else => |b| b.setSizeLimits(id, min, max),
        }
    }

    // Client-side decoration hooks (D17). `serial` comes from the pointer
    // button or touch down event that started the interaction.

    pub fn beginMove(p: Platform, id: WindowId, seat: SeatId, serial: u32) void {
        switch (p) {
            inline else => |b| b.beginMove(id, seat, serial),
        }
    }

    pub fn beginResize(p: Platform, id: WindowId, seat: SeatId, serial: u32, edge: Edge) void {
        switch (p) {
            inline else => |b| b.beginResize(id, seat, serial, edge),
        }
    }

    pub fn showWindowMenu(p: Platform, id: WindowId, seat: SeatId, serial: u32, x: i32, y: i32) void {
        switch (p) {
            inline else => |b| b.showWindowMenu(id, seat, serial, x, y),
        }
    }

    /// The window's visible bounds in surface coordinates, excluding client-
    /// side shadows.
    pub fn setWindowGeometry(p: Platform, id: WindowId, geometry: Rect) void {
        switch (p) {
            inline else => |b| b.setWindowGeometry(id, geometry),
        }
    }

    /// Where the surface accepts input, in surface coordinates; null for
    /// everywhere. Client-side shadows outside the resize edges are excluded.
    pub fn setInputRegion(p: Platform, id: WindowId, region: ?[]const Rect) Error!void {
        return switch (p) {
            inline else => |b| b.setRegion(id, .input, region),
        };
    }

    pub fn setOpaqueRegion(p: Platform, id: WindowId, region: ?[]const Rect) Error!void {
        return switch (p) {
            inline else => |b| b.setRegion(id, .@"opaque", region),
        };
    }

    /// Moves a popup with a new positioner (xdg_popup.reposition); a
    /// configure with the new placement follows. For anchors that move,
    /// such as a completion list following the caret.
    pub fn repositionPopup(p: Platform, id: WindowId, pos: Positioner) void {
        switch (p) {
            inline else => |b| b.repositionPopup(id, pos),
        }
    }

    // Subsurfaces (D17): external content shown without copying, above the
    // window's own content, in sync with the window's commits.

    pub fn createSubsurface(p: Platform, id: WindowId) Error!SubsurfaceId {
        return switch (p) {
            inline else => |b| b.createSubsurface(id),
        };
    }

    pub fn destroySubsurface(p: Platform, id: WindowId, sub: SubsurfaceId) void {
        switch (p) {
            inline else => |b| b.destroySubsurface(id, sub),
        }
    }

    /// Shows a frame at a place in the parent, or hides the subsurface.
    /// Applies with the window's next commit.
    pub fn setSubsurface(p: Platform, id: WindowId, sub: SubsurfaceId, state: *const SubsurfaceState) Error!void {
        return switch (p) {
            inline else => |b| b.setSubsurface(id, sub, state),
        };
    }

    /// The Wayland objects a Vulkan swapchain presents to (D10). Null on
    /// the headless backend.
    pub fn vulkanSurface(p: Platform, id: WindowId) ?VulkanSurface {
        return switch (p) {
            inline else => |b| b.vulkanSurface(id),
        };
    }

    /// The compositor's main device (a dev_t) from dma-buf feedback, which
    /// picks the GPU on multi-GPU systems (D10). Null if unknown.
    pub fn mainDevice(p: Platform) ?u64 {
        return switch (p) {
            inline else => |b| b.mainDevice(),
        };
    }

    /// Hands the window's commits to an external presenter (a Vulkan
    /// swapchain on `vulkanSurface`), or takes them back before presenting
    /// buffers again.
    pub fn setExternalPresenter(p: Platform, id: WindowId, on: bool) void {
        switch (p) {
            inline else => |b| b.setExternalPresenter(id, on),
        }
    }

    /// The window's last commit still awaits its frame callback.
    pub fn frameCallbackPending(p: Platform, id: WindowId) bool {
        return switch (p) {
            inline else => |b| b.frameCallbackPending(id),
        };
    }

    /// Like `present`, for a window with an external presenter: sets up
    /// everything the frame clock needs (configure ack, scale, frame
    /// callback, presentation feedback) and then runs `commit`, which must
    /// commit the surface once (vkQueuePresentKHR), so that all of it lands
    /// in that commit. Call from a `frame` event. Returns commit's error.
    pub fn presentExternal(p: Platform, id: WindowId, commit: ExternalCommit) anyerror!void {
        return switch (p) {
            inline else => |b| b.presentExternal(id, commit),
        };
    }

    /// Commits the window without a new buffer, so that subsurface changes
    /// apply when its own content did not change.
    pub fn commitWindow(p: Platform, id: WindowId) void {
        switch (p) {
            inline else => |b| b.commitWindow(id),
        }
    }

    /// Updates a seat's text input (text-input-v3, D15): enables or
    /// disables it and sends the surrounding text, content type, and
    /// cursor rectangle, then commits. Only meaningful while the seat's
    /// text input has entered a window (`text_input_enter`).
    pub fn setTextInput(p: Platform, seat: SeatId, state: *const TextInputState) void {
        switch (p) {
            inline else => |b| b.setTextInput(seat, state),
        }
    }

    // Clipboard and primary selection (D19). The client owning a selection
    // answers `selection_send` events by writing the data to their fd;
    // pasting reads another client's offer through a pipe.

    /// Offers data as a seat's selection in `mimes` (copied); `serial` is
    /// the input event that triggered it. Returns the source's id. No
    /// mime types clears the selection if this client owns it.
    pub fn setSelection(p: Platform, seat: SeatId, kind: SelectionKind, mimes: []const []const u8, serial: u32) Error!u32 {
        return switch (p) {
            inline else => |b| b.setSelection(seat, kind, mimes, serial),
        };
    }

    /// The mime types of the seat's current selection offer, valid until
    /// the next platform event; empty without an offer.
    pub fn selectionMimes(p: Platform, seat: SeatId, kind: SelectionKind) []const []const u8 {
        return switch (p) {
            inline else => |b| b.selectionMimes(seat, kind),
        };
    }

    /// Asks the selection's owner to write `mime` data to `fd`, which the
    /// platform closes. False without an offer.
    pub fn receiveSelection(p: Platform, seat: SeatId, kind: SelectionKind, mime: []const u8, fd: i32) bool {
        return switch (p) {
            inline else => |b| b.receiveSelection(seat, kind, mime, fd),
        };
    }
};

pub const SubsurfaceId = u32;

/// Opaque XRGB8888 pixels in mappable shared memory (wl_shm).
pub const ShmFrame = struct {
    fd: i32,
    offset: u32 = 0,
    width: u32,
    height: u32,
    stride: u32,
    /// Changes when the pixels change.
    key: u64,
};

pub const SubsurfaceState = struct {
    visible: bool = false,
    /// Position and size in the parent surface (logical); the frame (or
    /// its `source` part) is scaled to it.
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    frame: ?ShmFrame = null,
    /// The part of the frame to show, in buffer pixels (wp_viewport's
    /// source rectangle); null shows all of it.
    source: ?struct { x: f32, y: f32, width: f32, height: f32 } = null,
    /// Below the parent surface, showing through its transparent pixels,
    /// instead of above it.
    below: bool = false,
};

pub const SelectionKind = enum(u8) {
    /// Copy and paste (wl_data_device).
    clipboard,
    /// The last selected text, pasted with the middle button
    /// (zwp_primary_selection_v1).
    primary,
};

/// The seat's selection changed to a new offer (or none); its mime types
/// are in `Platform.selectionMimes`.
pub const Selection = struct { seat: SeatId, kind: SelectionKind, offer: bool };

/// Another client wants this client's selection: write it in the mime
/// type at index `mime` of `setSelection`'s list to `fd`, then close it.
pub const SelectionSend = struct { seat: SeatId, kind: SelectionKind, source: u32, mime: u8, fd: i32 };

/// This client's selection source was replaced; drop its data.
pub const SelectionCancelled = struct { seat: SeatId, kind: SelectionKind, source: u32 };

/// text-input-v3 content purpose.
pub const ContentPurpose = enum(u32) { normal, alpha, digits, number, phone, url, email, name, password, pin, date, time, datetime, terminal };

/// text-input-v3 content hints.
pub const ContentHint = packed struct(u32) {
    completion: bool = false,
    spellcheck: bool = false,
    auto_capitalization: bool = false,
    lowercase: bool = false,
    uppercase: bool = false,
    titlecase: bool = false,
    hidden_text: bool = false,
    sensitive_data: bool = false,
    latin: bool = false,
    multiline: bool = false,
    _: u22 = 0,
};

/// What a client tells the input method about the focused text field.
pub const TextInputState = struct {
    enabled: bool = false,
    /// Text around the cursor, at most `max_surrounding` bytes, valid
    /// during the call.
    surrounding: []const u8 = "",
    /// Byte offsets into `surrounding`.
    cursor: u32 = 0,
    anchor: u32 = 0,
    /// The input method caused this change (it applied a commit).
    from_input_method: bool = false,
    hint: ContentHint = .{},
    purpose: ContentPurpose = .normal,
    /// The caret, in surface coordinates.
    cursor_rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// The protocol's limit on surrounding text.
    pub const max_surrounding = 4000;
};

/// Text-input changes the input method sent with one `done`. Apply in
/// order: replace the preedit, delete around the cursor, insert the commit
/// text, then show the new preedit. A commit longer than `max_text` comes
/// in several events; all but the last have `more` set, the first carries
/// the deletion, and the last the preedit.
pub const TextInput = struct {
    window: WindowId,
    seat: SeatId,
    serial: u32 = 0,
    /// Bytes to delete before and after the cursor (excluding a selection).
    delete_before: u32 = 0,
    delete_after: u32 = 0,
    commit_buf: [max_text]u8 = undefined,
    commit_len: u16 = 0,
    preedit_buf: [max_text]u8 = undefined,
    preedit_len: u16 = 0,
    /// Cursor range in the preedit, in bytes; both -1 hides the cursor.
    cursor_begin: i32 = 0,
    cursor_end: i32 = 0,
    more: bool = false,

    pub const max_text = 128;

    pub fn commit(t: *const TextInput) []const u8 {
        return t.commit_buf[0..t.commit_len];
    }

    pub fn preedit(t: *const TextInput) []const u8 {
        return t.preedit_buf[0..t.preedit_len];
    }

    /// Splits one `done` into events; `emit` gets each in order.
    pub fn split(window: WindowId, seat: SeatId, serial: u32, delete_before: u32, delete_after: u32, commit_text: []const u8, preedit_text: []const u8, cursor_begin: i32, cursor_end: i32, ctx: anytype, comptime emit: fn (@TypeOf(ctx), TextInput) void) void {
        var rest = commit_text;
        var first = true;
        while (true) {
            var ev: TextInput = .{ .window = window, .seat = seat, .serial = serial };
            if (first) {
                ev.delete_before = delete_before;
                ev.delete_after = delete_after;
            }
            var n = @min(rest.len, max_text);
            while (n < rest.len and n > 0 and rest[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(ev.commit_buf[0..n], rest[0..n]);
            ev.commit_len = @intCast(n);
            rest = rest[n..];
            ev.more = rest.len != 0;
            if (!ev.more) {
                // A preedit too long to show is cut at a character boundary.
                var m = @min(preedit_text.len, max_text);
                while (m < preedit_text.len and m > 0 and preedit_text[m] & 0xc0 == 0x80) m -= 1;
                @memcpy(ev.preedit_buf[0..m], preedit_text[0..m]);
                ev.preedit_len = @intCast(m);
                ev.cursor_begin = if (cursor_begin > m) @intCast(m) else cursor_begin;
                ev.cursor_end = if (cursor_end > m) @intCast(m) else cursor_end;
            }
            emit(ctx, ev);
            first = false;
            if (!ev.more) return;
        }
    }
};

pub const Error = error{
    OutOfMemory,
    /// Every buffer of the window is still held by the compositor.
    NoBufferAvailable,
    /// The compositor connection failed or was closed.
    ConnectionLost,
    /// The compositor reported a protocol error.
    ProtocolError,
    /// The compositor lacks a required global (wl_compositor, wl_shm,
    /// xdg_wm_base, or ARGB8888 shm buffers).
    MissingGlobal,
    SystemResources,
};

pub const Size = struct { width: u32 = 0, height: u32 = 0 };

/// How long a configure may stay unacknowledged after `deferConfigure`;
/// well under compositors' own resize timeouts (sway waits 200 ms).
pub const configure_timeout_ns: u64 = 100 * std.time.ns_per_ms;

pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

pub const Region = enum { input, @"opaque" };

pub const Edge = enum(u32) {
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
};

/// Output scale in 1/120 steps (wp_fractional_scale_v1).
pub const Scale = struct {
    v120: u32 = 120,

    pub fn int(factor: u32) Scale {
        return .{ .v120 = factor * 120 };
    }

    /// Buffer pixels for `logical` surface pixels, rounded half away from
    /// zero as wp_fractional_scale_v1 specifies.
    pub fn apply(s: Scale, logical: u32) u32 {
        return @intCast((@as(u64, logical) * s.v120 + 60) / 120);
    }

    pub fn toFloat(s: Scale) f64 {
        return @as(f64, @floatFromInt(s.v120)) / 120;
    }
};

pub const Decoration = enum {
    /// The application draws decorations.
    client,
    /// The compositor draws decorations.
    server,
};

pub const PopupOptions = struct {
    parent: WindowId,
    positioner: Positioner,
    /// Takes an explicit grab for this input event (a press or key):
    /// keyboard focus moves to the popup, and input outside the popup
    /// chain dismisses it. Without it, the popup is passive (a tooltip).
    grab: ?struct { seat: SeatId, serial: u32 } = null,
};

pub const WindowOptions = struct {
    title: []const u8 = "",
    app_id: []const u8 = "",
    /// Logical size used when the compositor lets the client choose.
    width: u32 = 640,
    height: u32 = 480,
    /// Preferred decoration mode. The compositor decides; the result is in
    /// `WindowState.decoration`. `.client` opts into client-side decorations
    /// for header-bar layouts.
    decoration: Decoration = .server,
};

pub const WindowStates = packed struct(u16) {
    maximized: bool = false,
    fullscreen: bool = false,
    resizing: bool = false,
    activated: bool = false,
    tiled_left: bool = false,
    tiled_right: bool = false,
    tiled_top: bool = false,
    tiled_bottom: bool = false,
    suspended: bool = false,
    _: u7 = 0,
};

/// Window management features the compositor offers, for client-side
/// decoration buttons. Compositors without xdg_toplevel.wm_capabilities
/// offer everything.
pub const WmCapabilities = packed struct(u8) {
    window_menu: bool = true,
    maximize: bool = true,
    fullscreen: bool = true,
    minimize: bool = true,
    _: u4 = 0,
};

/// A window's configured state, as of its last `configure` event.
pub const WindowState = struct {
    /// Logical (surface) size.
    width: u32 = 0,
    height: u32 = 0,
    scale: Scale = .{},
    states: WindowStates = .{},
    decoration: Decoration = .client,
    capabilities: WmCapabilities = .{},
    /// Largest useful logical size, if the compositor says.
    bounds: ?Size = null,
    /// Popups: where the compositor placed it, relative to the parent's
    /// surface, with the size above.
    popup: ?struct { x: i32, y: i32 } = null,

    pub fn bufferWidth(s: WindowState) u32 {
        return s.scale.apply(s.width);
    }

    pub fn bufferHeight(s: WindowState) u32 {
        return s.scale.apply(s.height);
    }
};

/// Pixels to render a frame into: premultiplied ARGB8888, stored as B, G, R,
/// A bytes (little-endian 0xAARRGGBB words).
/// A `wl_display *` and a window's `wl_surface *`.
pub const VulkanSurface = struct { display: *anyopaque, surface: *anyopaque };

/// The commit of an external presenter (see `Platform.presentExternal`).
pub const ExternalCommit = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const Buffer = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    /// Backend slot of the buffer.
    slot: u8,
};

pub fn BoundedString(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        /// Copies `s`, truncated at a UTF-8 boundary if too long.
        pub fn set(self: *Self, s: []const u8) void {
            var n = @min(s.len, capacity);
            while (n < s.len and n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const OutputInfo = struct {
    name: BoundedString(64) = .{},
    description: BoundedString(256) = .{},
    make: BoundedString(64) = .{},
    model: BoundedString(64) = .{},
    /// Position in the compositor's global space.
    x: i32 = 0,
    y: i32 = 0,
    physical_width_mm: i32 = 0,
    physical_height_mm: i32 = 0,
    /// Current mode in hardware pixels.
    width: i32 = 0,
    height: i32 = 0,
    refresh_mhz: i32 = 0,
    /// Integer scale (wl_output.scale).
    scale: i32 = 1,
    /// wl_output.transform.
    transform: u32 = 0,
};

pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _: u2 = 0,
};

pub const Focus = struct { window: WindowId, seat: SeatId, serial: u32 };

pub const Key = struct {
    window: WindowId,
    seat: SeatId,
    /// XKB keycode (evdev code + 8).
    keycode: u32,
    /// XKB keysym; the composed keysym when a compose sequence completes.
    keysym: u32,
    state: State,
    mods: Mods,
    time: u32,
    serial: u32,
    /// UTF-8 text the key produced, including composed text.
    text_buf: [max_text]u8 = undefined,
    text_len: u8 = 0,
    /// The key is part of an unfinished compose sequence.
    composing: bool = false,

    pub const max_text = 32;
    pub const State = enum { pressed, released, repeated };

    pub fn text(k: *const Key) []const u8 {
        return k.text_buf[0..k.text_len];
    }
};

pub const Modifiers = struct { window: WindowId, seat: SeatId, mods: Mods };

pub const PointerMotion = struct {
    window: WindowId,
    seat: SeatId,
    /// Surface-local logical coordinates.
    x: f64,
    y: f64,
    time: u32 = 0,
    serial: u32 = 0,
};

pub const Button = struct {
    window: WindowId,
    seat: SeatId,
    /// Linux input event code (BTN_LEFT is 0x110).
    button: u32,
    pressed: bool,
    time: u32,
    serial: u32,
};

pub const ScrollSource = enum { unknown, wheel, finger, continuous, wheel_tilt };

/// One pointer frame of scrolling.
pub const Scroll = struct {
    /// Logical pixels per wheel detent (120 v120 units) for events that
    /// carry only discrete steps, matching wl_pointer's legacy axis value.
    pub const detent_px: f64 = 15;

    /// The scroll distance in logical pixels, from the high-resolution
    /// steps when the event has no continuous distance on an axis.
    pub fn delta(s: Scroll) struct { x: f64, y: f64 } {
        return .{
            .x = if (s.dx != 0) s.dx else @as(f64, @floatFromInt(s.v120_x)) / 120 * detent_px,
            .y = if (s.dy != 0) s.dy else @as(f64, @floatFromInt(s.v120_y)) / 120 * detent_px,
        };
    }

    window: WindowId,
    seat: SeatId,
    time: u32 = 0,
    /// Scroll distance in logical pixels.
    dx: f64 = 0,
    dy: f64 = 0,
    /// High-resolution wheel steps; 120 is one detent.
    v120_x: i32 = 0,
    v120_y: i32 = 0,
    source: ScrollSource = .unknown,
    /// The fingers left the surface or the wheel stopped on that axis;
    /// kinetic scrolling starts here (D16).
    stop_x: bool = false,
    stop_y: bool = false,
    /// The physical motion is opposite to the scroll direction (natural
    /// scrolling).
    inverted_x: bool = false,
    inverted_y: bool = false,
};

pub const Touch = struct {
    window: WindowId,
    seat: SeatId,
    id: i32,
    x: f64 = 0,
    y: f64 = 0,
    /// Contact ellipse axes in logical pixels, 0 if unknown.
    major: f64 = 0,
    minor: f64 = 0,
    /// Contact orientation in degrees.
    orientation: f64 = 0,
    time: u32 = 0,
    serial: u32 = 0,
};

pub const Configure = struct { window: WindowId, state: WindowState };

pub const Frame = struct { window: WindowId, time: FrameClock.Time };

pub const Event = union(enum) {
    output_added: OutputId,
    output_changed: OutputId,
    output_removed: OutputId,
    /// The window's size, scale, states, or decoration mode changed. The
    /// next frame must use them.
    configure: Configure,
    close_requested: WindowId,
    /// Render the window now: acquire a buffer and present it.
    frame: Frame,
    keyboard_enter: Focus,
    keyboard_leave: Focus,
    key: Key,
    modifiers: Modifiers,
    pointer_enter: PointerMotion,
    pointer_leave: Focus,
    pointer_motion: PointerMotion,
    pointer_button: Button,
    scroll: Scroll,
    touch_down: Touch,
    touch_motion: Touch,
    touch_up: Touch,
    /// Ends a group of touch events that happened together.
    touch_frame: SeatId,
    /// The compositor took over the touch sequence; forget every point.
    touch_cancel: SeatId,
    /// The seat's text input (input method) focuses the window, or leaves.
    text_input_enter: Focus,
    text_input_leave: Focus,
    /// Input method changes (text-input-v3).
    text_input: TextInput,
    selection: Selection,
    selection_send: SelectionSend,
    selection_cancelled: SelectionCancelled,
    /// The platform failed: events were lost (OutOfMemory) or the
    /// connection is gone (ConnectionLost, ProtocolError).
    failed: Error,

    pub fn window(ev: *const Event) ?WindowId {
        return switch (ev.*) {
            .close_requested => |w| w,
            inline else => |payload| if (comptime hasWindow(@TypeOf(payload))) payload.window else null,
        };
    }

    fn hasWindow(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and @hasField(T, "window");
    }
};

pub const Sink = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, event: *const Event) void,

    pub fn send(s: Sink, event: *const Event) void {
        s.func(s.ctx, event);
    }
};

/// Events queued by listeners and delivered to the sink in the dispatch
/// phase.
pub const EventQueue = struct {
    loop: *Loop,
    allocator: Allocator,
    sink: Sink,
    items: std.ArrayList(Event) = .empty,
    /// Index of the event being delivered.
    cursor: usize = 0,
    delivering: bool = false,
    failure: ?Error = null,
    task: Loop.Task = .{ .func = deliver },

    pub fn deinit(q: *EventQueue) void {
        q.loop.unschedule(&q.task);
        q.items.deinit(q.allocator);
    }

    pub fn push(q: *EventQueue, event: Event) void {
        q.items.append(q.allocator, event) catch {
            q.failure = error.OutOfMemory;
        };
        q.loop.schedule(&q.task, .dispatch);
    }

    /// Reports `err` after the queued events.
    pub fn fail(q: *EventQueue, err: Error) void {
        if (q.failure == null or err != error.OutOfMemory) q.failure = err;
        q.loop.schedule(&q.task, .dispatch);
    }

    /// Drops undelivered events for a destroyed window, so that its index
    /// can be reused.
    pub fn purge(q: *EventQueue, id: WindowId) void {
        var keep = if (q.delivering) q.cursor + 1 else 0;
        for (q.items.items[keep..]) |ev| {
            if (ev.window() == id) continue;
            q.items.items[keep] = ev;
            keep += 1;
        }
        q.items.shrinkRetainingCapacity(keep);
    }

    fn deliver(task: *Loop.Task) void {
        const q: *EventQueue = @fieldParentPtr("task", task);
        q.cursor = 0;
        q.delivering = true;
        // The sink may call back into the backend, which may queue or purge.
        while (q.cursor < q.items.items.len) : (q.cursor += 1) {
            const ev = q.items.items[q.cursor];
            q.sink.send(&ev);
        }
        q.items.clearRetainingCapacity();
        q.cursor = 0;
        q.delivering = false;
        if (q.failure) |err| {
            q.failure = null;
            q.sink.send(&.{ .failed = err });
        }
    }
};

test {
    if (comptime @import("integration").enabled) {
        // `zig build test-integration`: the tests against sway.
        _ = @import("integration_tests.zig");
    } else {
        std.testing.refAllDecls(@This());
        // Instantiates every forwarding call for both backends.
        std.testing.refAllDecls(Platform);
    }
}

test "text input commits split at character boundaries" {
    const Rec = struct {
        events: [8]TextInput = undefined,
        n: usize = 0,
        fn add(r: *@This(), ev: TextInput) void {
            r.events[r.n] = ev;
            r.n += 1;
        }
    };
    var r: Rec = .{};
    var long: [200]u8 = undefined;
    for (&long, 0..) |*c, i| c.* = if (i % 2 == 0) 0xc3 else 0xa9; // é repeated
    TextInput.split(1, 0, 5, 2, 0, &long, "ab", 1, 1, &r, Rec.add);
    try std.testing.expectEqual(@as(usize, 2), r.n);
    try std.testing.expectEqual(@as(usize, 128), r.events[0].commit().len);
    try std.testing.expect(r.events[0].more and !r.events[1].more);
    try std.testing.expectEqual(@as(u32, 2), r.events[0].delete_before);
    try std.testing.expectEqual(@as(u32, 0), r.events[1].delete_before);
    try std.testing.expectEqualStrings("ab", r.events[1].preedit());
    try std.testing.expectEqual(@as(usize, 200), r.events[0].commit().len + r.events[1].commit().len);
}

test "fractional scale rounds half away from zero" {
    const s: Scale = .{ .v120 = 150 }; // 1.25
    try std.testing.expectEqual(@as(u32, 800), s.apply(640));
    try std.testing.expectEqual(@as(u32, 4), s.apply(3)); // 3.75
    try std.testing.expectEqual(@as(u32, 3), (Scale{ .v120 = 180 }).apply(2)); // 1.5 * 2 = 3
    try std.testing.expectEqual(@as(u32, 2), (Scale{ .v120 = 180 }).apply(1)); // 1.5 rounds up
}

test "bounded strings truncate at UTF-8 boundaries" {
    var s: BoundedString(4) = .{};
    s.set("abé!"); // é is two bytes: "ab" + 2 bytes fits exactly
    try std.testing.expectEqualStrings("abé", s.slice());
    s.set("abcé");
    try std.testing.expectEqualStrings("abc", s.slice());
}

test "event queue purges a destroyed window's pending events" {
    var loop = try Loop.init(std.testing.allocator);
    defer loop.deinit();
    const Rec = struct {
        seen: std.ArrayList(Event) = .empty,
        queue: *EventQueue = undefined,
        fn onEvent(ctx: ?*anyopaque, ev: *const Event) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.seen.append(std.testing.allocator, ev.*) catch unreachable;
            // Destroying window 1 while its events are still queued.
            if (ev.* == .close_requested and ev.close_requested == 1) r.queue.purge(1);
        }
    };
    var rec: Rec = .{};
    defer rec.seen.deinit(std.testing.allocator);
    var q: EventQueue = .{ .loop = &loop, .allocator = std.testing.allocator, .sink = .{ .ctx = &rec, .func = Rec.onEvent } };
    defer q.deinit();
    rec.queue = &q;

    q.push(.{ .close_requested = 1 });
    q.push(.{ .output_added = 7 });
    q.push(.{ .pointer_leave = .{ .window = 1, .seat = 0, .serial = 3 } });
    q.push(.{ .keyboard_leave = .{ .window = 2, .seat = 0, .serial = 4 } });
    q.fail(error.OutOfMemory);
    try loop.dispatch(0);

    try std.testing.expectEqual(@as(usize, 4), rec.seen.items.len);
    try std.testing.expectEqual(@as(OutputId, 7), rec.seen.items[1].output_added);
    try std.testing.expectEqual(@as(WindowId, 2), rec.seen.items[2].keyboard_leave.window);
    try std.testing.expectEqual(error.OutOfMemory, rec.seen.items[3].failed);
}
