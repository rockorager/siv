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

    /// A subsurface whose content an embedder renders into its own
    /// `wl_surface`, for example with EGL or Vulkan (D17). The platform
    /// positions it and scales it (`setSubsurface` ignores `frame` and
    /// `source`) but never attaches a buffer or commits it.
    pub fn createEmbedSurface(p: Platform, id: WindowId) Error!EmbedSurface {
        return switch (p) {
            inline else => |b| b.createEmbedSurface(id),
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

    /// What subsurfaces can do besides showing frames (D17).
    pub fn subsurfaceFeatures(p: Platform) SubsurfaceFeatures {
        return switch (p) {
            inline else => |b| b.subsurfaceFeatures(),
        };
    }

    /// Whether subsurfaces can show dma-bufs of this DRM format and
    /// modifier (linux-dmabuf feedback's format table).
    pub fn supportsDmabuf(p: Platform, format: u32, modifier: u64) bool {
        return switch (p) {
            inline else => |b| b.supportsDmabuf(format, modifier),
        };
    }

    /// Whether the compositor may still read the window's dma-buf frame
    /// with this key, which a subsurface showed. When it stops, a
    /// `subsurface_released` event follows.
    pub fn dmabufBusy(p: Platform, id: WindowId, key: u64) bool {
        return switch (p) {
            inline else => |b| b.dmabufBusy(id, key),
        };
    }

    /// The Wayland objects a Vulkan swapchain presents to (D10). Null on
    /// the headless backend.
    pub fn vulkanSurface(p: Platform, id: WindowId) ?VulkanSurface {
        return switch (p) {
            inline else => |b| b.vulkanSurface(id),
        };
    }

    /// The `wl_display*` of the connection, for code that binds protocols
    /// siv does not support itself (D17, D27). Null on the headless
    /// backend.
    pub fn waylandDisplay(p: Platform) ?*anyopaque {
        return switch (p) {
            .wayland => |b| b.display,
            .headless => null,
        };
    }

    /// The window's `wl_surface*` and, for toplevels, `xdg_toplevel*`,
    /// for the same. Null on the headless backend.
    pub fn waylandWindow(p: Platform, id: WindowId) ?WaylandWindow {
        return switch (p) {
            .wayland => |b| .{ .surface = b.get(id).surface, .toplevel = b.get(id).toplevel },
            .headless => null,
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

    // Pointer cursors (D16). Each window has a cursor shape, shown while a
    // pointer is over it: through cursor-shape-v1 when the compositor
    // offers it, otherwise from the cursor theme at the window's scale.

    /// The cursor shown while a pointer is over the window.
    pub fn setCursor(p: Platform, id: WindowId, shape: CursorShape) void {
        switch (p) {
            inline else => |b| b.setCursor(id, shape),
        }
    }

    /// The XCursor theme and size (logical pixels) for themed cursors,
    /// from the desktop settings (D19). `name` is copied.
    pub fn setCursorTheme(p: Platform, name: []const u8, size: u32) void {
        switch (p) {
            inline else => |b| b.setCursorTheme(name, size),
        }
    }

    // Drag and drop (D19). A drag over one of this client's windows is an
    // offer named by a per-seat id in `drag_enter`; the requests below
    // name it and do nothing once it is gone. This client's own drags are
    // sources: their data is requested with `drag_send` events and their
    // outcome reported with `drag_source` events.

    /// Starts a drag from `window` offering `mimes` (copied) with
    /// `actions`, for the button or touch press `serial` that is still
    /// held. Returns the source's id. `icon` follows the pointer.
    pub fn startDrag(p: Platform, id: WindowId, seat: SeatId, serial: u32, mimes: []const []const u8, actions: DragActions, icon: ?*const DragIcon) Error!u32 {
        return switch (p) {
            inline else => |b| b.startDrag(id, seat, serial, mimes, actions, icon),
        };
    }

    /// The mime types of a drag offer, valid until the next platform
    /// event; empty once the offer is gone.
    pub fn dragMimes(p: Platform, seat: SeatId, offer: u32) []const []const u8 {
        return switch (p) {
            inline else => |b| b.dragMimes(seat, offer),
        };
    }

    /// Tells the source whether the drop target under the pointer takes
    /// the offer (in `mime`; null refuses it) and with which actions. The
    /// compositor answers with a `drag_actions` event.
    pub fn acceptDrag(p: Platform, seat: SeatId, offer: u32, mime: ?[]const u8, actions: DragActions, preferred: DragAction) void {
        switch (p) {
            inline else => |b| b.acceptDrag(seat, offer, mime, actions, preferred),
        }
    }

    /// Asks the source to write `mime` data to `fd`, which the platform
    /// closes. False once the offer is gone.
    pub fn receiveDrag(p: Platform, seat: SeatId, offer: u32, mime: []const u8, fd: i32) bool {
        return switch (p) {
            inline else => |b| b.receiveDrag(seat, offer, mime, fd),
        };
    }

    /// Ends a dropped offer: the target performed `action` (copy or move),
    /// or refused the drop (none). Also ends an offer that was not
    /// dropped, refusing it.
    pub fn finishDrag(p: Platform, seat: SeatId, offer: u32, action: DragAction) void {
        switch (p) {
            inline else => |b| b.finishDrag(seat, offer, action),
        }
    }

    /// Replaces the icon of this client's drag `source`, while it lasts:
    /// false once it is over, Unsupported if it started without an icon.
    pub fn setDragIcon(p: Platform, seat: SeatId, source: u32, icon: *const DragIcon) Error!bool {
        return switch (p) {
            inline else => |b| b.setDragIcon(seat, source, icon),
        };
    }

    /// Cancels this client's drag `source`, as if dropped nowhere: a
    /// `drag_source` event reports it cancelled, and the drag leaves the
    /// window under it.
    pub fn cancelDrag(p: Platform, seat: SeatId, source: u32) void {
        switch (p) {
            inline else => |b| b.cancelDrag(seat, source),
        }
    }

    // Desktop integration (D19).

    /// Exports a toplevel with xdg-foreign-v2 so that other clients can
    /// parent their dialogs to it. An `exported` event follows with the
    /// handle (at once if the window was exported before); the export
    /// lasts as long as the window.
    pub fn exportToplevel(p: Platform, id: WindowId) void {
        switch (p) {
            inline else => |b| b.exportToplevel(id),
        }
    }

    /// Asks for an xdg-activation token to hand to another application,
    /// so that it may take focus: tied to the input event `serial` on
    /// `seat`, and to the window, which should have focus. An
    /// `activation_token` event with `request` follows.
    pub fn requestActivationToken(p: Platform, id: WindowId, request: u32, seat: SeatId, serial: u32, app_id: []const u8) void {
        switch (p) {
            inline else => |b| b.requestActivationToken(id, request, seat, serial, app_id),
        }
    }

    /// Activates (focuses) a window with a token another application
    /// passed on (xdg-activation, $XDG_ACTIVATION_TOKEN).
    pub fn activate(p: Platform, id: WindowId, token: []const u8) void {
        switch (p) {
            inline else => |b| b.activate(id, token),
        }
    }

    // Input on request (D16).

    /// Locks or confines every seat's pointer to the window (pointer-
    /// constraints), and asks for relative motion (relative-pointer).
    /// The compositor activates a constraint when it sees fit (usually
    /// while the pointer is over the region): `pointer_constraint` events
    /// report it. Replaces the window's previous request; `.none` ends it.
    pub fn setPointerConstraint(p: Platform, id: WindowId, options: ConstraintOptions) void {
        switch (p) {
            inline else => |b| b.setPointerConstraint(id, options),
        }
    }

    /// Asks the compositor to send the window every key, its own
    /// shortcuts included, while it has keyboard focus
    /// (keyboard-shortcuts-inhibit); `shortcuts_inhibit` events report
    /// whether it does.
    pub fn inhibitShortcuts(p: Platform, id: WindowId, on: bool) void {
        switch (p) {
            inline else => |b| b.inhibitShortcuts(id, on),
        }
    }

    // Window features (D17).

    /// Sets the toplevel's icon (xdg-toplevel-icon-v1): a theme name the
    /// compositor looks up, and square images it uses when it cannot
    /// (copied); null resets the default icon. False when the compositor
    /// offers no toplevel icons.
    pub fn setIcon(p: Platform, id: WindowId, icon: ?*const ToplevelIcon) bool {
        return switch (p) {
            inline else => |b| b.setIcon(id, icon),
        };
    }

    /// The icon sizes (logical pixels) the compositor prefers, valid until
    /// the next platform event; empty without a preference.
    pub fn iconSizes(p: Platform) []const u32 {
        return switch (p) {
            inline else => |b| b.iconSizes(),
        };
    }

    /// Keeps the session from going idle (screen blanking, locking) while
    /// the window is visible (idle-inhibit-unstable-v1). Counted: each
    /// `true` needs a `false`. Returns false, changing nothing, when the
    /// compositor offers no idle inhibition.
    pub fn inhibitIdle(p: Platform, id: WindowId, on: bool) bool {
        return switch (p) {
            inline else => |b| b.inhibitIdle(id, on),
        };
    }

    /// Joins a session (xdg-session-management-v1) so that the compositor
    /// remembers windows that have a session name and restores them: the
    /// one named by `id`, or a new one when it is empty or unknown. A
    /// `session` event follows (`unavailable` without the protocol).
    /// Windows created afterwards with a session name are restored before
    /// they map; earlier ones are added.
    pub fn startSession(p: Platform, reason: SessionReason, id: []const u8) void {
        switch (p) {
            inline else => |b| b.startSession(reason, id),
        }
    }

    /// Leaves the session and asks the compositor to forget it.
    pub fn removeSession(p: Platform) void {
        switch (p) {
            inline else => |b| b.removeSession(),
        }
    }

    // Desktop shell (D31).

    /// Changes a layer window's layer, anchors, margins, exclusive zone,
    /// keyboard mode, and size; applied with its next commit, which this
    /// makes. A configure follows if the size changes.
    pub fn setLayer(p: Platform, id: WindowId, state: LayerState) void {
        switch (p) {
            inline else => |b| b.setLayer(id, state),
        }
    }

    /// Asks the compositor to lock the session (ext-session-lock-v1). A
    /// `lock` event follows: `locked` once every output is blanked, or
    /// `finished` if the compositor refused or ended it. Lock windows
    /// (`Role.lock`) can be created from now until the lock ends.
    /// Unsupported without the protocol.
    pub fn lockSession(p: Platform) Error!void {
        return switch (p) {
            inline else => |b| b.lockSession(),
        };
    }

    /// Ends the lock: unlocks the session if it was locked. Lock windows
    /// get `closed` events. With `abandon`, a locked session stays locked
    /// (the application is going away without having authenticated the
    /// user): the lock object is dropped without a request.
    pub fn unlockSession(p: Platform, abandon: bool) void {
        switch (p) {
            inline else => |b| b.unlockSession(abandon),
        }
    }

    /// Starts receiving the desktop's toplevel windows: `toplevel` events
    /// for each one now and as they change. Unsupported without a
    /// foreign toplevel protocol.
    pub fn startToplevels(p: Platform) Error!void {
        return switch (p) {
            inline else => |b| b.startToplevels(),
        };
    }

    pub fn stopToplevels(p: Platform) void {
        switch (p) {
            inline else => |b| b.stopToplevels(),
        }
    }

    /// A toplevel announced by a `toplevel` event, valid until the next
    /// platform event; null once it is gone.
    pub fn toplevelInfo(p: Platform, id: u32) ?ToplevelInfo {
        return switch (p) {
            inline else => |b| b.toplevelInfo(id),
        };
    }

    /// Asks the compositor to act on a toplevel. False when it is gone or
    /// the compositor does not let this client manage toplevels.
    pub fn toplevelRequest(p: Platform, id: u32, request: ToplevelRequest) bool {
        return switch (p) {
            inline else => |b| b.toplevelRequest(id, request),
        };
    }

    /// Starts receiving the desktop's workspaces (ext-workspace-v1):
    /// `workspace` events for each one now and as they change.
    pub fn startWorkspaces(p: Platform) Error!void {
        return switch (p) {
            inline else => |b| b.startWorkspaces(),
        };
    }

    pub fn stopWorkspaces(p: Platform) void {
        switch (p) {
            inline else => |b| b.stopWorkspaces(),
        }
    }

    /// A workspace announced by a `workspace` event, valid until the next
    /// platform event; null once it is gone.
    pub fn workspaceInfo(p: Platform, id: u32) ?WorkspaceInfo {
        return switch (p) {
            inline else => |b| b.workspaceInfo(id),
        };
    }

    /// Asks the compositor to act on a workspace. False when it is gone
    /// or the compositor does not allow it for this workspace.
    pub fn workspaceRequest(p: Platform, id: u32, request: WorkspaceRequest) bool {
        return switch (p) {
            inline else => |b| b.workspaceRequest(id, request),
        };
    }

    /// Reports `idle` events for the returned watch when the user has
    /// not used the seat for `timeout_ms`, and when they are back
    /// (ext-idle-notify-v1). Idle inhibitors hold it off unless
    /// `ignore_inhibitors`.
    pub fn createIdleWatch(p: Platform, timeout_ms: u32, ignore_inhibitors: bool) Error!u32 {
        return switch (p) {
            inline else => |b| b.createIdleWatch(timeout_ms, ignore_inhibitors),
        };
    }

    pub fn destroyIdleWatch(p: Platform, id: u32) void {
        switch (p) {
            inline else => |b| b.destroyIdleWatch(id),
        }
    }

    /// Which optional desktop shell protocols the compositor offers.
    pub fn shellCapabilities(p: Platform) ShellCapabilities {
        return switch (p) {
            inline else => |b| b.shellCapabilities(),
        };
    }

    // Background effects (D31).

    /// Whether the compositor blurs what is behind a surface's blur
    /// region (ext-background-effect-v1 with the blur capability). It
    /// may change: a `blur_capable` event follows.
    pub fn canBlur(p: Platform) bool {
        return switch (p) {
            inline else => |b| b.canBlur(),
        };
    }

    /// Where the compositor blurs what is behind the window, in surface
    /// coordinates; null or empty for nowhere. Applied with the window's
    /// next commit. Does nothing when the compositor cannot blur.
    pub fn setBlurRegion(p: Platform, id: WindowId, region: []const Rect) void {
        switch (p) {
            inline else => |b| b.setBlurRegion(id, region),
        }
    }
};

// Desktop shell (D31) ----------------------------------------------------------

/// The desktop shell protocols a compositor offers (D31), so that an
/// application can fall back (a more opaque background without blur).
pub const ShellCapabilities = packed struct(u8) {
    layers: bool = false,
    lock: bool = false,
    toplevels: bool = false,
    /// Toplevels accept window management requests.
    toplevel_management: bool = false,
    workspaces: bool = false,
    idle: bool = false,
    blur: bool = false,
    _: u1 = 0,
};

/// The stacking layer of a layer window (wlr-layer-shell), bottom to top.
pub const Layer = enum(u8) { background, bottom, top, overlay };

/// The output edges a layer window is anchored to.
pub const Anchor = packed struct(u8) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _: u4 = 0,
};

/// When a layer window takes keyboard focus.
pub const KeyboardMode = enum(u8) {
    /// Never.
    none,
    /// Always, while it is on a layer above toplevels (a launcher, a
    /// lock-like overlay).
    exclusive,
    /// When the user clicks it, like a toplevel.
    on_demand,
};

pub const Margins = struct { top: i32 = 0, right: i32 = 0, bottom: i32 = 0, left: i32 = 0 };

/// Where a layer window goes on its output and how it behaves; changed
/// with `Platform.setLayer`.
pub const LayerState = struct {
    layer: Layer = .top,
    anchor: Anchor = .{},
    margin: Margins = .{},
    /// Logical pixels along its edge that other windows keep clear of;
    /// 0 keeps clear of other windows' zones without reserving one, -1
    /// ignores them too (a wallpaper under a bar).
    exclusive_zone: i32 = 0,
    /// Reserve the window's own size along the edge it is anchored to,
    /// following resizes, instead of `exclusive_zone`.
    auto_exclusive: bool = false,
    keyboard: KeyboardMode = .none,
    /// Logical size; 0 on an axis anchored to both of its edges spans
    /// the output between them.
    width: u32 = 0,
    height: u32 = 0,

    /// A zero size on an axis needs both of that axis's anchors.
    pub fn valid(s: LayerState) bool {
        if (s.width == 0 and !(s.anchor.left and s.anchor.right)) return false;
        if (s.height == 0 and !(s.anchor.top and s.anchor.bottom)) return false;
        return true;
    }

    /// The exclusive zone to send for a window of this size: with
    /// `auto_exclusive`, its height when anchored to the top or bottom
    /// edge alone (or with both side edges), its width likewise for the
    /// left or right edge; 0 for any other anchoring. Compositors add the
    /// margin on that edge themselves.
    pub fn zone(s: LayerState, width: u32, height: u32) i32 {
        if (!s.auto_exclusive) return s.exclusive_zone;
        const a = s.anchor;
        const horizontal = a.left == a.right; // both or neither side edge
        const vertical = a.top == a.bottom;
        if (a.top != a.bottom and horizontal) return @intCast(@min(height, std.math.maxInt(i32)));
        if (a.left != a.right and vertical) return @intCast(@min(width, std.math.maxInt(i32)));
        return 0;
    }

    /// The window's rectangle on an output of `out_w` by `out_h` logical
    /// pixels, as a compositor arranges it (centered on unanchored axes).
    pub fn place(s: LayerState, out_w: i32, out_h: i32) Rect {
        const m = s.margin;
        const w: i32 = if (s.width == 0) @max(1, out_w - m.left - m.right) else @intCast(s.width);
        const h: i32 = if (s.height == 0) @max(1, out_h - m.top - m.bottom) else @intCast(s.height);
        const x: i32 = if (s.anchor.left) m.left else if (s.anchor.right) out_w - m.right - w else @divTrunc(out_w - w, 2);
        const y: i32 = if (s.anchor.top) m.top else if (s.anchor.bottom) out_h - m.bottom - h else @divTrunc(out_h - h, 2);
        return .{ .x = x, .y = y, .width = w, .height = h };
    }
};

/// What kind of surface a window is.
pub const Role = union(enum) {
    /// An ordinary application window (xdg_toplevel).
    toplevel,
    /// A desktop shell surface (wlr-layer-shell): a bar, dock, wallpaper,
    /// notification, or on-screen display.
    layer: LayerRole,
    /// The surface a session lock shows on an output (ext-session-lock);
    /// needs `Platform.lockSession` first.
    lock: OutputId,
};

pub const LayerRole = struct {
    state: LayerState = .{},
    /// The output it goes on; null lets the compositor choose (usually
    /// the focused one).
    output: ?OutputId = null,
    /// What the surface is ("bar", "notifications"), for compositor rules.
    namespace: []const u8 = "",
};

/// The session lock's progress (`Platform.lockSession`).
pub const LockEvent = enum(u8) {
    /// Every output is locked: the lock windows are all that shows.
    locked,
    /// The lock ended without this client unlocking it: before `locked`,
    /// the compositor refused (another client holds a lock); after, it
    /// ended the lock itself.
    finished,
};

pub const ToplevelStates = packed struct(u8) {
    maximized: bool = false,
    minimized: bool = false,
    activated: bool = false,
    fullscreen: bool = false,
    _: u4 = 0,
};

/// Another client's (or this client's) toplevel window, as the desktop's
/// window list reports it.
pub const ToplevelInfo = struct {
    title: []const u8 = "",
    app_id: []const u8 = "",
    /// A stable identifier that does not change while the window exists
    /// (ext-foreign-toplevel-list); empty when the compositor's list does
    /// not have one.
    identifier: []const u8 = "",
    states: ToplevelStates = .{},
    /// The toplevel it belongs to (a dialog's), or 0.
    parent: u32 = 0,
    outputs: []const OutputId = &.{},
    /// The compositor accepts window management requests for it.
    managed: bool = false,
};

pub const ToplevelRequest = union(enum) {
    activate,
    close,
    minimized: bool,
    maximized: bool,
    fullscreen: struct { on: bool, output: ?OutputId = null },
};

pub const WorkspaceStates = packed struct(u8) {
    active: bool = false,
    urgent: bool = false,
    hidden: bool = false,
    _: u5 = 0,
};

pub const WorkspaceCapabilities = packed struct(u8) {
    activate: bool = false,
    deactivate: bool = false,
    remove: bool = false,
    assign: bool = false,
    _: u4 = 0,
};

pub const WorkspaceInfo = struct {
    name: []const u8 = "",
    /// Stable across sessions where the compositor can keep it.
    identifier: []const u8 = "",
    states: WorkspaceStates = .{},
    capabilities: WorkspaceCapabilities = .{},
    /// The outputs its group is on.
    outputs: []const OutputId = &.{},
};

pub const WorkspaceRequest = enum(u8) { activate, deactivate, remove };

/// A toplevel or workspace appeared, changed, or went away. Ids are never
/// reused, so a late event never names a newer object.
pub const ForeignChange = struct {
    id: u32,
    kind: Kind,

    pub const Kind = enum(u8) { added, changed, removed };
};

/// An idle watch's seat went idle or became active again.
pub const IdleChange = struct { watch: u32, idle: bool };

/// A toplevel icon: a name from the icon theme and images of it.
pub const ToplevelIcon = struct {
    name: []const u8 = "",
    images: []const IconImage = &.{},
};

/// A square icon image: premultiplied ARGB8888 (B, G, R, A bytes), `size`
/// buffer pixels wide and high, for `scale`.
pub const IconImage = struct {
    pixels: []const u8,
    size: u32,
    scale: u32 = 1,
};

/// Why an application joins a session, which may decide how much the
/// compositor restores.
pub const SessionReason = enum(u8) {
    /// Started by the user, from a launcher.
    launch,
    /// Started again after a crash of the application or compositor.
    recover,
    /// Started as part of restoring the user's session.
    restore,
};

pub const SessionEvent = struct {
    kind: Kind,
    /// `created`: the session's id, to pass to `startSession` next time.
    id: Handle = .{},

    pub const Kind = enum(u8) {
        /// A new session: nothing was restored.
        created,
        /// The session was found; windows with known names are restored.
        restored,
        /// Another client took the session over; it is gone here.
        replaced,
        /// The compositor offers no session management.
        unavailable,
    };
};

pub const PointerConstraint = enum(u8) {
    none,
    /// The pointer stays where it is; only relative motion arrives.
    lock,
    /// The pointer moves only inside the region.
    confine,
};

pub const ConstraintOptions = struct {
    kind: PointerConstraint = .none,
    /// Where the constraint applies (surface coordinates); null is the
    /// whole surface.
    region: ?Rect = null,
    /// The constraint comes back whenever the compositor would activate
    /// it again, rather than ending the first time it is deactivated.
    persistent: bool = false,
    /// Relative motion events while the pointer is over the window, with
    /// or without a constraint.
    relative: bool = false,
};

/// A window's pointer constraint was activated or deactivated. `ended`:
/// it will not come back (a one-shot constraint was deactivated).
pub const ConstraintState = struct { window: WindowId, seat: SeatId, active: bool, ended: bool = false };

/// Pointer motion as the device reported it (relative-pointer), also
/// while the pointer is locked or at an edge: accelerated and not, in
/// logical pixels, with a microsecond timestamp.
pub const RelativeMotion = struct {
    window: WindowId,
    seat: SeatId,
    dx: f64,
    dy: f64,
    dx_unaccel: f64 = 0,
    dy_unaccel: f64 = 0,
    time_us: u64 = 0,
};

/// Whether the compositor passes its own shortcuts to the window.
pub const InhibitState = struct { window: WindowId, seat: SeatId, active: bool };

/// Pointer cursor shapes: the CSS cursor names, numbered as in
/// cursor-shape-v1, and a hidden cursor.
pub const CursorShape = enum(u8) {
    hidden = 0,
    default = 1,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    e_resize,
    n_resize,
    ne_resize,
    nw_resize,
    s_resize,
    se_resize,
    sw_resize,
    w_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    col_resize,
    row_resize,
    all_scroll,
    zoom_in,
    zoom_out,
    /// From cursor-shape-v1 version 2.
    dnd_ask,
    all_resize,

    /// The resize cursor for a window edge (client-side decorations).
    pub fn ofEdge(e: Edge) CursorShape {
        return switch (e) {
            .top => .n_resize,
            .bottom => .s_resize,
            .left => .w_resize,
            .right => .e_resize,
            .top_left => .nw_resize,
            .top_right => .ne_resize,
            .bottom_left => .sw_resize,
            .bottom_right => .se_resize,
        };
    }
};

/// Drag-and-drop actions (wl_data_device_manager.dnd_action).
pub const DragActions = packed struct(u8) {
    copy: bool = false,
    move: bool = false,
    /// The target asks the user which action to take after the drop.
    ask: bool = false,
    _: u5 = 0,

    pub fn has(a: DragActions, action: DragAction) bool {
        return switch (action) {
            .none => false,
            .copy => a.copy,
            .move => a.move,
            .ask => a.ask,
        };
    }

    pub fn of(action: DragAction) DragActions {
        return .{ .copy = action == .copy, .move = action == .move, .ask = action == .ask };
    }

    pub fn intersect(a: DragActions, b: DragActions) DragActions {
        return @bitCast(@as(u8, @bitCast(a)) & @as(u8, @bitCast(b)));
    }

    pub fn none(a: DragActions) bool {
        return !a.copy and !a.move and !a.ask;
    }

    /// The action a compositor chooses for a source offering `source` and
    /// a target taking `target` that prefers `preferred`: the preferred
    /// one if both sides allow it, else the first of copy, move, and ask
    /// that both allow.
    pub fn negotiate(source: DragActions, target: DragActions, preferred: DragAction) DragAction {
        const both = source.intersect(target);
        if (both.has(preferred)) return preferred;
        if (both.copy) return .copy;
        if (both.move) return .move;
        if (both.ask) return .ask;
        return .none;
    }
};

pub const DragAction = enum(u8) { none, copy, move, ask };

/// A drag icon: premultiplied ARGB8888 pixels (B, G, R, A bytes), copied
/// by `startDrag`. The hotspot, in buffer pixels, is the point under the
/// pointer; `scale` is the buffer scale.
pub const DragIcon = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    hotspot_x: i32 = 0,
    hotspot_y: i32 = 0,
    scale: u32 = 1,
};

/// A drag entered one of this client's windows. Its mime types are in
/// `Platform.dragMimes`. `own` drags come from this client's own source.
pub const DragEnter = struct {
    window: WindowId,
    seat: SeatId,
    offer: u32,
    x: f64,
    y: f64,
    serial: u32 = 0,
    source_actions: DragActions = .{},
    own: bool = false,
};

pub const DragMotion = struct { window: WindowId, seat: SeatId, x: f64, y: f64, time: u32 = 0 };

/// The drag left the window, or was dropped on it, or (`drag_actions`)
/// the actions changed: the source's, or the one the compositor chose
/// for the drop target's answer.
pub const DragOffer = struct {
    window: WindowId,
    seat: SeatId,
    offer: u32,
    source_actions: DragActions = .{},
    action: DragAction = .none,
};

/// Another client (or this one) wants data of this client's drag: write
/// it in the mime type at index `mime` of `startDrag`'s list to `fd`,
/// then close it.
pub const DragSend = struct { seat: SeatId, source: u32, mime: u8, fd: i32 };

/// The progress of this client's drag.
pub const DragSource = struct {
    seat: SeatId,
    source: u32,
    phase: Phase,
    /// `action`: the action the compositor chose; `finished`: the action
    /// the target performed.
    action: DragAction = .none,
    /// `target`: a drop target takes one of the mime types.
    accepted: bool = false,

    pub const Phase = enum {
        /// The target under the pointer accepted or refused the data.
        target,
        /// The compositor chose an action.
        action,
        /// The user dropped the data on a target that took it.
        dropped,
        /// The target is done; if the action was move, delete the data.
        finished,
        /// The drag ended without a drop, or the target refused it.
        cancelled,
    };
};

pub const SubsurfaceId = u32;

/// A handle string from the compositor: an xdg-foreign export handle or
/// an xdg-activation token.
pub const Handle = BoundedString(256);

/// The window's toplevel was exported (xdg-foreign-v2): other clients,
/// such as a portal's dialogs, can name it with `handle`. Empty when the
/// compositor cannot export.
pub const Exported = struct { window: WindowId, handle: Handle };

/// An xdg-activation token for `request` (`Platform.requestActivationToken`);
/// empty when the compositor offers no activation.
pub const ActivationToken = struct { window: WindowId, request: u32, token: Handle };

pub const EmbedSurface = struct {
    sub: SubsurfaceId,
    /// The `wl_display*` and the subsurface's `wl_surface*`; null on the
    /// headless backend.
    display: ?*anyopaque = null,
    surface: ?*anyopaque = null,
};

/// Opaque XRGB8888 pixels in mappable shared memory (wl_shm), or a
/// dma-buf (D17).
pub const ShmFrame = struct {
    fd: i32,
    offset: u32 = 0,
    width: u32,
    height: u32,
    stride: u32,
    /// Changes when the pixels change.
    key: u64,
    /// Instead of shared memory (then `fd`, `offset`, and `stride` are
    /// ignored): shown as a linux-dmabuf wl_buffer, released with a
    /// `subsurface_released` event once the compositor lets it go.
    dmabuf: ?Dmabuf = null,
    /// What changed since the frame the subsurface showed before; the
    /// commit damages only that (ignored when it showed none).
    damage: FrameDamage = .{},
};

/// What changed in a frame since the one before it, in buffer pixels: the
/// rectangles a commit damages (D17).
pub const FrameDamage = struct {
    pub const max_rects = 4;
    /// Unused entries stay zero, so that equal damage compares equal.
    rects: [max_rects]Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 }),
    len: u8 = 0,
    /// Every pixel changed, or what did is unknown.
    all: bool = true,

    pub const none: FrameDamage = .{ .all = false };

    /// The rectangles, or null for every pixel.
    pub fn slice(d: *const FrameDamage) ?[]const Rect {
        return if (d.all) null else d.rects[0..d.len];
    }

    /// Adds a rectangle; past `max_rects`, it merges into the one whose
    /// area grows least.
    pub fn add(d: *FrameDamage, r: Rect) void {
        if (d.all or r.width <= 0 or r.height <= 0) return;
        if (d.len < max_rects) {
            d.rects[d.len] = r;
            d.len += 1;
            return;
        }
        var best: usize = 0;
        var growth: i64 = std.math.maxInt(i64);
        for (d.rects, 0..) |q, i| {
            const g = area(unite(q, r)) - area(q);
            if (g < growth) {
                best = i;
                growth = g;
            }
        }
        d.rects[best] = unite(d.rects[best], r);
    }

    /// Adds everything `o` damages.
    pub fn merge(d: *FrameDamage, o: FrameDamage) void {
        if (o.all) d.* = .{} else for (o.rects[0..o.len]) |r| d.add(r);
    }

    fn area(r: Rect) i64 {
        return @as(i64, r.width) * r.height;
    }

    fn unite(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .width = @max(a.x + a.width, b.x + b.width) - x0, .height = @max(a.y + a.height, b.y + b.height) - y0 };
    }
};

/// A Linux dma-buf: DRM fourcc format and modifier, one to four planes.
pub const Dmabuf = struct {
    format: u32,
    modifier: u64,
    planes: [4]Plane = undefined,
    plane_count: u8,

    pub const Plane = struct { fd: i32, offset: u32, stride: u32 };
};

/// The compositor no longer reads a dma-buf frame that a subsurface
/// showed: its wl_buffer was released after being replaced.
pub const SubsurfaceReleased = struct { window: WindowId, key: u64 };

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
    /// An embedder renders the content (`createEmbedSurface`).
    embed: bool = false,
    /// Multiplies the content's alpha (alpha-modifier-v1); below 1 only
    /// where `SubsurfaceFeatures.alpha` says so.
    alpha: f32 = 1,
    /// A solid color directly below the content (single-pixel-buffer-v1),
    /// only where `SubsurfaceFeatures.solid` says so; shown with it, at the
    /// same alpha.
    background: ?Background = null,

    pub const Background = struct {
        /// Position and size in the parent surface (logical).
        rect: Rect,
        /// sRGB-encoded and premultiplied, 0 to 0xffffffff, as
        /// wp_single_pixel_buffer_manager_v1 takes them.
        rgba: [4]u32,
    };
};

pub const SubsurfaceFeatures = struct {
    /// `SubsurfaceState.alpha` below 1 (wp_alpha_modifier_v1).
    alpha: bool = false,
    /// `SubsurfaceState.background` (wp_single_pixel_buffer_manager_v1
    /// with wp_viewporter).
    solid: bool = false,
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
    /// The compositor offers no protocol for an optional feature (layer
    /// shell, session lock, toplevels, workspaces, idle notification).
    Unsupported,
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
    /// False lets input through to what is under the popup (a tooltip),
    /// so the pointer reaching it does not leave the parent.
    input: bool = true,
};

pub const WindowOptions = struct {
    title: []const u8 = "",
    app_id: []const u8 = "",
    /// The toplevel this window belongs to (xdg_toplevel.set_parent): the
    /// compositor keeps it above its parent, as for a dialog.
    parent: ?WindowId = null,
    /// Another client's toplevel this window belongs to, by the handle it
    /// exported (xdg-foreign v2, imported with zxdg_importer_v2); ignored
    /// with `parent`. Copied before the call returns.
    foreign_parent: []const u8 = "",
    /// With a parent: a modal dialog (xdg-dialog-v1), which compositors
    /// may show attached to the parent while keeping input from it.
    modal: bool = false,
    /// The window's name in the session (`startSession`), unique among the
    /// application's windows; empty keeps it out of the session.
    session_name: []const u8 = "",
    /// Logical size used when the compositor lets the client choose.
    width: u32 = 640,
    height: u32 = 480,
    /// Preferred decoration mode. The compositor decides; the result is in
    /// `WindowState.decoration`. `.client` opts into client-side decorations
    /// for header-bar layouts.
    decoration: Decoration = .server,
    /// A toplevel, a layer window, or a lock window (D31). Title, app
    /// id, parent, session name, size, and decoration are toplevels'.
    role: Role = .toplevel,
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

pub const WaylandWindow = struct { surface: *anyopaque, toplevel: ?*anyopaque };

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

/// The seat's key-repeat timing (wl_keyboard.repeat_info): the delay
/// before a held key repeats and the repeats per second; rate 0 turns
/// repeating off. Widgets that repeat while held follow it too.
pub const KeyRepeat = struct { seat: SeatId, delay_ms: u32, rate: u32 };

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
    /// The fewest logical pixels a wheel detent scrolls: about three lines
    /// of text, as in Firefox (D16).
    pub const min_detent_px: f64 = 60;
    /// Touchpad distances (axis source finger or continuous) are
    /// multiplied by this, as Firefox does (GTK 4 uses 2.5; D16).
    pub const finger_factor: f64 = 4;

    /// Logical pixels one wheel detent (120 v120 units) scrolls a viewport
    /// `extent` logical pixels long on that axis: GTK 4's extent^(2/3),
    /// at least `min_detent_px`, at most the extent (D16).
    pub fn detentPx(extent: f64) f64 {
        return @min(@max(std.math.pow(f64, extent, 2.0 / 3.0), min_detent_px), extent);
    }

    /// The distance in logical pixels this scrolls a viewport of the
    /// given size (logical pixels): wheel steps by `detentPx`, touchpad
    /// distances by `finger_factor`, other distances as they are. The one
    /// place siv scales scroll input (D16).
    pub fn delta(s: Scroll, width: f64, height: f64) struct { x: f64, y: f64 } {
        return .{ .x = s.axisDelta(s.dx, s.v120_x, width), .y = s.axisDelta(s.dy, s.v120_y, height) };
    }

    fn axisDelta(s: Scroll, d: f64, v120: i32, extent: f64) f64 {
        // Compositors send both for a wheel; the steps carry high-resolution
        // fractions that the distance may not (Hyprland rounds it to whole
        // detents), and both include the compositor's scroll factor.
        if (v120 != 0) return @as(f64, @floatFromInt(v120)) / 120 * detentPx(extent);
        return if (s.source == .finger or s.source == .continuous) d * finger_factor else d;
    }

    /// Vertical wheel detents, for zooming: from the steps, or from the
    /// distance at wl_pointer's legacy 15 pixels a detent.
    pub fn detentsY(s: Scroll) f64 {
        return if (s.v120_y != 0) @as(f64, @floatFromInt(s.v120_y)) / 120 else s.dy / 15;
    }

    /// The same input turned horizontal, for Shift+wheel.
    pub fn shifted(s: Scroll) Scroll {
        var h = s;
        h.dx = s.dy;
        h.v120_x = s.v120_y;
        h.dy = 0;
        h.v120_y = 0;
        return h;
    }

    window: WindowId,
    seat: SeatId,
    time: u32 = 0,
    /// Scroll distance in logical pixels, as the compositor sends it
    /// (`delta` scales it).
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

/// The compositor took the seat's touch sequences on a window (a gesture
/// of its own): every point down on it is gone.
pub const TouchCancel = struct { window: WindowId, seat: SeatId };

pub const GestureKind = enum(u8) {
    /// Three or more fingers moving together (two-finger motion is
    /// scrolling).
    swipe,
    /// Fingers moving apart or together, and rotating.
    pinch,
    /// Fingers resting on the touchpad, which stops kinetic scrolling.
    hold,
};

pub const GesturePhase = enum(u8) { begin, update, end };

/// A touchpad gesture (pointer-gestures). `begin` names the window under
/// the pointer; the gesture's later events go to the same window.
pub const Gesture = struct {
    window: WindowId,
    seat: SeatId,
    kind: GestureKind,
    phase: GesturePhase,
    /// `end`: the gesture was cancelled (a finger was added or lifted
    /// early, or the compositor took it over) rather than finished.
    cancelled: bool = false,
    fingers: u32 = 0,
    /// Swipe and pinch updates: how far the fingers' center moved since
    /// the last event, in logical pixels.
    dx: f64 = 0,
    dy: f64 = 0,
    /// Pinch: the fingers' distance relative to `begin` (2 is twice as
    /// far apart).
    scale: f64 = 1,
    /// Pinch: rotation since the last event, in degrees clockwise.
    rotation: f64 = 0,
    time: u32 = 0,
    serial: u32 = 0,
};

/// A tablet tool's physical type (tablet-v2).
pub const ToolKind = enum(u8) { pen, eraser, brush, pencil, airbrush, finger, mouse, lens };

/// The axes a tablet tool reports besides its position.
pub const ToolAxes = packed struct(u8) {
    pressure: bool = false,
    distance: bool = false,
    tilt: bool = false,
    rotation: bool = false,
    slider: bool = false,
    wheel: bool = false,
    _: u2 = 0,
};

pub const TabletPhase = enum(u8) {
    /// The tool came into proximity of the window.
    proximity_in,
    /// It left, or went out of proximity.
    proximity_out,
    /// The tip touched the tablet.
    down,
    /// The tip left the tablet.
    up,
    /// Axes changed (position, pressure, tilt, ...).
    motion,
    /// A button on the tool was pressed or released.
    button,
};

/// One tablet tool event (tablet-v2). The protocol groups a tool's
/// changes into frames; each frame becomes its events in the order
/// proximity_in, down, motion (when only axes changed), buttons, up,
/// proximity_out, and every event carries the tool's whole state as of
/// the frame, so a drawing program can start a stroke from `down`.
pub const TabletTool = struct {
    window: WindowId,
    seat: SeatId,
    /// The tool, per seat, while it exists.
    tool: u32,
    kind: ToolKind = .pen,
    axes: ToolAxes = .{},
    /// The tool's hardware serial number, the same on every tablet it is
    /// used on; 0 if unknown.
    serial_number: u64 = 0,
    phase: TabletPhase,
    /// Surface-local logical coordinates.
    x: f64 = 0,
    y: f64 = 0,
    /// 0 to 1.
    pressure: f64 = 0,
    /// 0 (touching) to 1 (as far as the tablet senses).
    distance: f64 = 0,
    /// Degrees from the perpendicular, positive to the right and toward
    /// the user.
    tilt_x: f64 = 0,
    tilt_y: f64 = 0,
    /// Degrees clockwise from the tool's logical neutral position.
    rotation: f64 = 0,
    /// -1 to 1.
    slider: f64 = 0,
    /// The wheel turned this frame: degrees and detents.
    wheel: f64 = 0,
    wheel_clicks: i32 = 0,
    /// `button`: a Linux input code (BTN_STYLUS is 0x14b) and its state.
    button: u32 = 0,
    pressed: bool = false,
    /// The tip touches the tablet.
    tip: bool = false,
    time: u32 = 0,
    serial: u32 = 0,
};

pub const PadControl = enum(u8) {
    button,
    /// A touch ring: `value` is the angle in degrees clockwise from the
    /// top, [0, 360).
    ring,
    /// A touch strip: `value` is the position from the top or left, 0
    /// to 1.
    strip,
    /// A dial: `value` is its rotation this frame in detents (positive
    /// clockwise), fractions for high-resolution dials.
    dial,
    /// The group's mode changed to `mode`.
    mode,
};

/// A tablet pad event (tablet-v2): the buttons, rings, strips, and dials
/// on the tablet itself, sent to the window the pad focuses (usually the
/// one with keyboard focus). `group` is the pad group the control is in
/// and `mode` that group's current mode, so an application can map a
/// control to a different action per mode.
pub const TabletPad = struct {
    window: WindowId,
    seat: SeatId,
    /// The pad, per seat, while it exists.
    pad: u32,
    control: PadControl,
    /// The button, ring, strip, or dial: its index on the pad.
    index: u32 = 0,
    group: u32 = 0,
    mode: u32 = 0,
    value: f64 = 0,
    /// `button`: pressed rather than released.
    pressed: bool = false,
    /// Rings and strips: the finger left the control (`value` is then
    /// meaningless), so kinetic behavior can start.
    stop: bool = false,
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
    key_repeat: KeyRepeat,
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
    touch_cancel: TouchCancel,
    /// Touchpad swipe, pinch, and hold gestures.
    gesture: Gesture,
    /// Tablet tools (pens, erasers, ...) over a window, and tablet pads.
    tablet_tool: TabletTool,
    tablet_pad: TabletPad,
    /// Pointer constraints and relative motion, and shortcut inhibition.
    pointer_constraint: ConstraintState,
    relative_motion: RelativeMotion,
    shortcuts_inhibit: InhibitState,
    /// The session joined, was found, or was taken over (`startSession`).
    session: SessionEvent,
    /// The compositor restored the window from the session (its size,
    /// place, and states), before its first configure.
    window_restored: WindowId,
    /// The seat's text input (input method) focuses the window, or leaves.
    text_input_enter: Focus,
    text_input_leave: Focus,
    /// Input method changes (text-input-v3).
    text_input: TextInput,
    selection: Selection,
    selection_send: SelectionSend,
    selection_cancelled: SelectionCancelled,
    subsurface_released: SubsurfaceReleased,
    /// Drag and drop over a window: a drag entered it, moved, left, was
    /// dropped, or its actions changed. After a drop the offer stays until
    /// `finishDrag`, even if the compositor reports the drag leaving.
    drag_enter: DragEnter,
    drag_motion: DragMotion,
    drag_leave: DragOffer,
    drag_drop: DragOffer,
    drag_actions: DragOffer,
    /// This client's drag: data requests and progress.
    drag_send: DragSend,
    drag_source: DragSource,
    exported: Exported,
    activation_token: ActivationToken,
    /// The compositor took the window's role away: a layer window it
    /// closed (its output went away), or a lock window whose output or
    /// lock ended. Destroy the window; it shows nothing more.
    closed: WindowId,
    /// The session lock's progress (D31).
    lock: LockEvent,
    /// Toplevels, workspaces, and idle watches (D31).
    toplevel: ForeignChange,
    workspace: ForeignChange,
    idle: IdleChange,
    /// Whether the compositor can blur behind surfaces changed (D31).
    blur_capable: bool,
    /// The platform failed: events were lost (OutOfMemory) or the
    /// connection is gone (ConnectionLost, ProtocolError).
    failed: Error,

    pub fn window(ev: *const Event) ?WindowId {
        return switch (ev.*) {
            .close_requested, .window_restored, .closed => |w| w,
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
        _ = @import("xcursor.zig");
        _ = @import("cursor.zig");
        _ = @import("syncobj.zig");
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

test "layer windows are placed by their anchors and margins, and reserve their size" {
    // A bar along the top: spans the output between its side margins.
    const bar: LayerState = .{ .anchor = .{ .top = true, .left = true, .right = true }, .margin = .{ .top = 4, .left = 10, .right = 20 }, .height = 30, .auto_exclusive = true };
    try std.testing.expect(bar.valid());
    try std.testing.expectEqual(Rect{ .x = 10, .y = 4, .width = 1250, .height = 30 }, bar.place(1280, 720));
    try std.testing.expectEqual(@as(i32, 30), bar.zone(1250, 30));
    // A dock on the right edge reserves its width, not its height.
    const dock: LayerState = .{ .anchor = .{ .right = true }, .margin = .{ .right = 8 }, .width = 64, .height = 300, .auto_exclusive = true };
    try std.testing.expectEqual(Rect{ .x = 1280 - 8 - 64, .y = 210, .width = 64, .height = 300 }, dock.place(1280, 720));
    try std.testing.expectEqual(@as(i32, 64), dock.zone(64, 300));
    // Anchored to opposite edges on both axes there is no edge to reserve.
    const full: LayerState = .{ .anchor = .{ .top = true, .bottom = true, .left = true, .right = true }, .auto_exclusive = true };
    try std.testing.expectEqual(@as(i32, 0), full.zone(1280, 720));
    // A zero size needs both anchors of its axis.
    try std.testing.expect(!(LayerState{ .anchor = .{ .top = true, .left = true } }).valid());
    // Without auto, the zone is what was asked for, -1 included.
    try std.testing.expectEqual(@as(i32, -1), (LayerState{ .exclusive_zone = -1, .width = 1, .height = 1 }).zone(1, 1));
}
