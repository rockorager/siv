//! Layer updates (D8): what the UI thread sends the compositor thread, and
//! the events it gets back.
//!
//! Each window has a tree of layers. The UI thread owns the structure and
//! the content; the compositor thread owns presentation, scroll offsets,
//! and running animations. The UI describes changes as a list of `Op`s and
//! commits them as one batch, which the compositor applies atomically
//! between frames. It never sends whole frames: unchanged layers cost
//! nothing to resend, and transforms, opacity, and scrolling animate on
//! the compositor thread without UI involvement.
//!
//! Coordinates are logical (surface) pixels, y-down. A layer's transform
//! maps its coordinates into its parent's; the root layer's coordinates
//! are the window's. The compositor applies the buffer scale.
//!
//! Layer ids are chosen by the UI. They are plain indices (D20) scoped to
//! one window: the compositor stores layers in an array indexed by id, so
//! keep them small and reuse freed ones. Zero means "no layer".
//!
//! Content is an immutable `scene.DisplayList` in layer coordinates. Its
//! builder moves to the compositor with it and comes back in
//! `Event.released` once no frame can read the list any more; until then
//! the UI must not reset the builder or free the fonts and images the list
//! refers to. Layers inside a content list may use ids for the UI's own
//! bookkeeping, but the compositor treats them as part of the layer's
//! content: damage comes from `SetContent.damage`.

const std = @import("std");
const raster = @import("raster");
const scene = @import("scene");
const platform = @import("platform");

pub const Point = raster.Point;
pub const Rect = raster.Rect;
pub const Affine = raster.Affine;
pub const Radii = raster.Radii;
pub const Color = scene.Color;
pub const WindowId = platform.WindowId;

pub const LayerId = u32;

/// How long a size-changing configure waits for the UI's layout (see
/// `Op.ack_configure`); the platform enforces it.
pub const configure_timeout_ns = platform.configure_timeout_ns;

/// Logical size.
pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,
};

/// A layer's transform, in components so that animations interpolate them
/// independently (a matrix has no unique interpolation). Maps layer
/// coordinates p to parent coordinates
/// `translate + origin + rotate(scale * (p - origin))`.
pub const Transform = struct {
    translate: Point = .zero,
    scale: Point = .{ .x = 1, .y = 1 },
    /// Clockwise on screen (y-down), in radians.
    rotate: f32 = 0,
    /// The point, in layer coordinates, that scale and rotation keep fixed.
    origin: Point = .zero,

    pub const identity: Transform = .{};

    pub fn offset(x: f32, y: f32) Transform {
        return .{ .translate = .{ .x = x, .y = y } };
    }

    pub fn affine(t: Transform) Affine {
        var m = Affine.translate(-t.origin.x, -t.origin.y)
            .then(.scale(t.scale.x, t.scale.y));
        if (t.rotate != 0) m = m.then(.rotate(t.rotate));
        return m.then(.translate(t.origin.x + t.translate.x, t.origin.y + t.translate.y));
    }

    /// Componentwise interpolation.
    pub fn lerp(a: Transform, b: Transform, t: f32) Transform {
        return .{
            .translate = a.translate.lerp(b.translate, t),
            .scale = a.scale.lerp(b.scale, t),
            .rotate = a.rotate + (b.rotate - a.rotate) * t,
            .origin = a.origin.lerp(b.origin, t),
        };
    }

    pub fn eql(a: Transform, b: Transform) bool {
        return a.translate.eql(b.translate) and a.scale.eql(b.scale) and a.rotate == b.rotate and a.origin.eql(b.origin);
    }

    fn finite(t: Transform) bool {
        return finitePoint(t.translate) and finitePoint(t.scale) and std.math.isFinite(t.rotate) and finitePoint(t.origin);
    }
};

/// Clips a layer's content and descendants, in layer coordinates.
pub const Clip = struct {
    rect: Rect,
    /// Rounded corners; zero for a plain rectangle.
    radii: Radii = .{},
};

/// Makes a layer a scroll container. Its children (not its own content)
/// are translated by minus the scroll offset and clipped to `viewport`.
/// The offset is owned by the compositor: it changes with pointer scroll
/// input, `scroll_to`, `scroll_by`, flings, and scroll animations, is
/// reported in `Event.scrolled`, and is always clamped to
/// [0, max(0, content - viewport size)] on each axis.
///
/// Pointer scroll routing: the compositor hit-tests the point under the
/// pointer against the layer tree (topmost layer whose content bounds,
/// wheel region, or scroll viewport contain it) and walks from that layer to the root. The
/// first match decides: a layer with a wheel region containing the point
/// sends the event to the UI; a scroll container with `input` whose
/// viewport contains the point and that can still move in the event's
/// direction scrolls in the compositor. Without a match the event goes to
/// the UI. Events with ctrl, alt, or super held always go to the UI (zoom
/// and similar bindings); shift is a plain scroll, with a vertical wheel
/// scrolling horizontally. A touchpad gesture stays with the target its
/// first event chose until the scroll stops.
///
/// Zoom: a container whose `max_zoom` exceeds `min_zoom` also scales its
/// children by a zoom factor about the viewport's top-left corner, so a
/// child point p shows at `viewport.min + zoom * (p - viewport.min) -
/// offset`, and the offset (in zoomed pixels) is clamped to the zoomed
/// content. Touchpad pinches are routed by the rules above, with "can
/// still move" read as "zooms": the first wheel region sends the pinch to
/// the UI, the first input-enabled zoomable container under the pointer
/// zooms in the compositor, keeping the point under the fingers in place
/// and panning with them, and modifiers send it to the UI. A pinch keeps
/// its first target until it ends. The zoom is reported in
/// `Event.scrolled`.
pub const Scroll = struct {
    /// Visible area, in layer coordinates.
    viewport: Rect,
    /// Extent of the scrolled children.
    content: Size,
    /// The compositor scrolls this layer on pointer scroll input over it,
    /// with kinetic scrolling after touchpad gestures, without waiting for
    /// the UI thread. Scroll events it consumes are not forwarded.
    input: bool = true,
    /// Zoom range; equal values (the default) never zoom.
    min_zoom: f32 = 1,
    max_zoom: f32 = 1,

    pub fn zoomable(s: Scroll) bool {
        return s.max_zoom > s.min_zoom;
    }

    pub fn clampZoom(s: Scroll, z: f32) f32 {
        return std.math.clamp(z, s.min_zoom, s.max_zoom);
    }
};

/// Timing curve of an animation.
pub const Easing = union(enum) {
    linear,
    /// CSS cubic-bezier(x1, y1, x2, y2); x1 and x2 in [0, 1].
    cubic_bezier: [4]f32,

    pub const ease: Easing = .{ .cubic_bezier = .{ 0.25, 0.1, 0.25, 1 } };
    pub const ease_in: Easing = .{ .cubic_bezier = .{ 0.42, 0, 1, 1 } };
    pub const ease_out: Easing = .{ .cubic_bezier = .{ 0, 0, 0.58, 1 } };
    pub const ease_in_out: Easing = .{ .cubic_bezier = .{ 0.42, 0, 0.58, 1 } };
};

pub const Property = enum { transform, opacity, scroll };

pub const Value = union(Property) {
    transform: Transform,
    opacity: f32,
    /// Scroll offset.
    scroll: Point,
};

/// An animation of one layer property, run on the compositor thread and
/// sampled at each frame's predicted presentation time (D12). Starting an
/// animation replaces the property's running animation; setting the
/// property directly cancels it. A finished animation leaves the property
/// at its final value and reports `Event.animation_finished`.
pub const Animation = struct {
    /// Reported back in `Event.animation_finished`.
    id: u32 = 0,
    to: Value,
    /// Start value, of the same property as `to`. Null starts from the
    /// value shown when the animation starts, which continues smoothly
    /// from any animation it replaces.
    from: ?Value = null,
    duration_ns: u64,
    /// CLOCK_MONOTONIC start time; 0 starts at the first frame that shows
    /// the animation. A start in the past skips ahead.
    start_ns: u64 = 0,
    easing: Easing = .ease,
    /// Number of iterations; 0 repeats until replaced or cancelled.
    iterations: u32 = 1,
    /// Every other iteration runs backwards.
    alternate: bool = false,
};

/// External content (D17): pixels another component renders, such as
/// video. Ids are per window, from `Compositor.createExternal`.
pub const ExternalId = u32;

/// One frame of external content: opaque XRGB8888 pixels (B, G, R, X
/// bytes) in shared memory the compositor can map, such as a memfd, or a
/// dma-buf. The compositor duplicates the fds; the producer may close its
/// copies, but must not change the pixels until `Event.external_released`
/// reports the frame's key.
pub const ExternalFrame = struct {
    fd: i32,
    offset: u32 = 0,
    width: u32,
    height: u32,
    /// Bytes per row.
    stride: u32,
    /// Changes whenever the pixels change.
    key: u64,
    /// A dma-buf instead of shared memory (D17); its first plane is `fd`,
    /// `offset`, and `stride`. Shown once its implicit fences signal.
    dmabuf: ?scene.Dmabuf = null,
    /// dma-bufs: a sync_file that signals when the frame's writes are
    /// done, waited for instead of the implicit fences.
    fence: ?i32 = null,

    /// Closes every fd the frame holds.
    pub fn close(f: ExternalFrame) void {
        _ = std.os.linux.close(f.fd);
        if (f.fence) |fd| _ = std.os.linux.close(fd);
        if (f.dmabuf) |d| for (d.planes[1..d.plane_count]) |p| {
            _ = std.os.linux.close(p.fd);
        };
    }
};

/// Takes a slot's released frames on the compositor thread, instead of
/// `Event.external_released` on the UI thread, so that a producer gets
/// its memory back however busy the UI is (D8). Both functions run on
/// the compositor thread (or on the thread destroying the compositor)
/// and must return quickly.
pub const ExternalReleaseHook = struct {
    ctx: ?*anyopaque,
    /// No frame reads the frame with this key any more.
    released: *const fn (ctx: ?*anyopaque, key: u64) void,
    /// The slot is gone and its last frame released: nothing calls this
    /// hook again.
    dropped: *const fn (ctx: ?*anyopaque) void,
};

/// Where a layer shows external content: in `rect`, in layer
/// coordinates, above the layer's own content and below its children.
pub const ExternalPlacement = struct {
    id: ExternalId,
    rect: Rect,
    /// A solid color behind the content over `box` (layer coordinates),
    /// such as the bars around letterboxed video; transparent for none.
    /// On a subsurface of its own (single-pixel-buffer-v1) while the
    /// content is on one (D17), painted in the window otherwise.
    background: scene.Color = .transparent,
    box: Rect = Rect.empty,
};

/// Where the compositor blurs what is behind the window (D31): a rounded
/// rectangle in layer coordinates, transformed and clipped like the
/// layer's content.
pub const BlurShape = struct {
    rect: Rect,
    radii: Radii = .{},
};

/// Display-list content of a layer. See the module comment for ownership.
pub const Content = struct {
    list: scene.DisplayList,
    builder: *scene.Builder,
};

/// One change to a window's layer tree. Ops in a commit apply in order.
/// An op that names a missing layer, or would make a cycle, is skipped and
/// logged: it is a bug in the caller.
pub const Op = union(enum) {
    /// Creates a detached, empty layer with default properties.
    create: LayerId,
    /// Destroys a layer and all its descendants and releases their content.
    destroy: LayerId,
    /// Makes a layer the window's root; 0 shows only the background.
    set_root: LayerId,
    /// Attaches a layer under `parent`, or moves it there.
    insert: Insert,
    /// Detaches a layer from its parent. It keeps its content, properties,
    /// and children, but is not drawn until inserted again.
    detach: LayerId,
    set_content: SetContent,
    set_transform: struct { layer: LayerId, transform: Transform },
    /// In [0, 1].
    set_opacity: struct { layer: LayerId, opacity: f32 },
    set_clip: struct { layer: LayerId, clip: ?Clip },
    /// Makes a layer a scroll container (or a plain layer again with null)
    /// or changes its viewport and extent. The offset is kept and clamped.
    set_scroll: struct { layer: LayerId, scroll: ?Scroll },
    /// Sets a scroll container's offset, cancelling flings and scroll
    /// animations.
    scroll_to: struct { layer: LayerId, offset: Point },
    /// Starts kinetic scrolling of a scroll container at `velocity`
    /// (logical pixels per second), decelerating to a stop. For flings the
    /// UI detects itself, such as touch drags.
    fling: struct { layer: LayerId, velocity: Point },
    /// Moves a scroll container's offset by `delta`, relative to wherever
    /// the compositor has it now. For scroll input the UI handled first
    /// and passes on, without racing the compositor's own scrolling.
    scroll_by: struct { layer: LayerId, delta: Point },
    animate: struct { layer: LayerId, animation: Animation },
    /// Sets a zoomable scroll container's zoom (clamped to its range),
    /// keeping `focus` (layer coordinates, inside the viewport) in place.
    zoom_to: struct { layer: LayerId, zoom: f32, focus: Point },
    /// Multiplies the zoom by `factor`, relative to wherever the
    /// compositor has it now, keeping `focus` in place: for pinches and
    /// zoom bindings the UI handled first and passes on.
    zoom_by: struct { layer: LayerId, factor: f32, focus: Point },
    /// Pointer scroll events over `region` (layer coordinates, clipped like
    /// the layer) go to the UI instead of a scroll container below it in
    /// the tree; see `Scroll`. Null removes the region. A region also makes
    /// the layer hit-testable where it has no content.
    set_wheel_region: struct { layer: LayerId, region: ?Rect },
    /// Asks the Wayland compositor to blur what is behind the window under
    /// `shape` (null removes it). Every frame the surface's blur region is
    /// made from the shapes as they are then (transforms, scrolling,
    /// clips, animations) and set in the same commit as the content.
    set_blur: struct { layer: LayerId, shape: ?BlurShape },
    /// What the window shows behind the root layer. Default transparent.
    set_background: Color,
    /// Shows external content in a layer (null removes it). When the
    /// layer is axis-aligned, fully opaque, rectangularly clipped around
    /// the content, and nothing is drawn over it, the frames go to a
    /// subsurface without copying; otherwise they are composited.
    set_external: struct { layer: LayerId, external: ?ExternalPlacement },
    /// This commit's content was laid out for the configure with this
    /// serial (`Event.configure`). A configure that changes the window's
    /// logical size is acknowledged with the first frame that includes
    /// such a commit, so the compositor never sees the new size with the
    /// old layout. If the UI does not answer within `configure_timeout_ns`,
    /// the compositor acknowledges with the old layout at the new size so
    /// that a stalled UI cannot freeze the window. Other configures
    /// (scale, states) are presented at once.
    ack_configure: u64,

    pub const Insert = struct {
        layer: LayerId,
        parent: LayerId,
        /// Paint below this sibling; 0 paints above every sibling.
        before: LayerId = 0,
    };

    pub const SetContent = struct {
        layer: LayerId,
        /// Null removes the content.
        content: ?Content,
        /// What changed compared with the previous content, in layer
        /// coordinates; null for the bounds of both.
        damage: ?Rect = null,
    };

    /// Checks what can be checked without the tree: ids and finite values.
    pub fn validate(op: Op) error{InvalidArgument}!void {
        const ok = switch (op) {
            .create, .destroy, .detach => |id| id != 0,
            .set_root, .set_background, .ack_configure => true,
            .insert => |i| i.layer != 0 and i.parent != 0 and i.layer != i.parent and i.before != i.layer,
            .set_content => |s| s.layer != 0 and (s.damage == null or finiteRect(s.damage.?)),
            .set_transform => |s| s.layer != 0 and s.transform.finite(),
            .set_opacity => |s| s.layer != 0 and std.math.isFinite(s.opacity),
            .set_clip => |s| s.layer != 0 and (s.clip == null or finiteRect(s.clip.?.rect)),
            .set_scroll => |s| s.layer != 0 and (s.scroll == null or validScroll(s.scroll.?)),
            .zoom_to => |s| s.layer != 0 and std.math.isFinite(s.zoom) and s.zoom > 0 and finitePoint(s.focus),
            .zoom_by => |s| s.layer != 0 and std.math.isFinite(s.factor) and s.factor > 0 and finitePoint(s.focus),
            .scroll_to => |s| s.layer != 0 and finitePoint(s.offset),
            .fling => |s| s.layer != 0 and finitePoint(s.velocity),
            .scroll_by => |s| s.layer != 0 and finitePoint(s.delta),
            .set_wheel_region => |s| s.layer != 0 and (s.region == null or finiteRect(s.region.?)),
            .set_blur => |s| s.layer != 0 and (s.shape == null or finiteRect(s.shape.?.rect)),
            .set_external => |s| s.layer != 0 and (s.external == null or (s.external.?.id != 0 and finiteRect(s.external.?.rect) and (s.external.?.background.a == 0 or finiteRect(s.external.?.box)))),
            .animate => |s| s.layer != 0 and validAnimation(s.animation),
        };
        if (!ok) return error.InvalidArgument;
    }
};

/// What the compositor sends the UI thread, delivered on the UI loop in
/// its dispatch phase (D5).
pub const Event = union(enum) {
    /// A platform event: input, close requests, outputs, and failures.
    /// Platform `frame` and `configure` events are the compositor's; the UI
    /// gets `frame` and `configure` below instead. Pointer scroll events the
    /// compositor consumed for a scroll container are not forwarded.
    platform: platform.Event,
    /// The window's size, scale, states, or decoration changed. Lay out for
    /// `state` and commit with `ack_configure = serial`. Serials increase.
    configure: struct { window: WindowId, state: platform.WindowState, serial: u64 },
    /// Answers `requestFrame`: commit now what should be visible at
    /// `time.present_ns`, which is when such a commit will be presented.
    frame: platform.Frame,
    /// The first frame that includes commit `seq` (and every earlier
    /// commit to the window) will be presented at about `present_ns`.
    /// `present_ns` is the predicted presentation time of the frame (D12),
    /// `commit_ns` when it was committed to the display server, both on
    /// CLOCK_MONOTONIC.
    presented: struct { window: WindowId, seq: u64, present_ns: u64, commit_ns: u64 = 0 },
    /// The compositor changed a scroll offset or zoom: by input, a fling,
    /// or an animation. `seq` is the last commit applied at the time, so a
    /// report older than the UI's own `scroll_to` can be told apart.
    scrolled: struct { window: WindowId, layer: LayerId, offset: Point, seq: u64, zoom: f32 = 1 },
    animation_finished: struct { window: WindowId, layer: LayerId, id: u32, property: Property },
    /// No frame reads this builder's list any more; the UI may reset or
    /// free it and the fonts and images it referred to.
    released: *scene.Builder,
    /// No frame reads this external frame any more; its producer may
    /// reuse the memory. Delivered to the producer's sink like the rest.
    external_released: struct { window: WindowId, id: ExternalId, key: u64 },
    /// An embedder's surface (`Compositor.createExternalSurface`) has a new
    /// size: render frames of `buffer_width` × `buffer_height` pixels
    /// from now on (its logical size times the window's scale), and
    /// render one soon even if nothing else changed, since the new size
    /// applies with the surface's next commit.
    external_configure: struct { window: WindowId, id: ExternalId, width: u32, height: u32, buffer_width: u32, buffer_height: u32 },
    /// The compositor owes no frame any more (`Compositor.owesFrames`
    /// asked for this). Carries nothing: it wakes the UI loop.
    idle,

    /// The window an event is about, if any. `released` belongs to no
    /// window: it must be delivered even after the window is gone.
    pub fn window(ev: *const Event) ?WindowId {
        return switch (ev.*) {
            .platform => |*p| p.window(),
            .frame => |f| f.window,
            inline .configure, .presented, .scrolled, .animation_finished, .external_released, .external_configure => |e| e.window,
            .released, .idle => null,
        };
    }
};

fn finitePoint(p: Point) bool {
    return std.math.isFinite(p.x) and std.math.isFinite(p.y);
}

fn finiteRect(r: Rect) bool {
    return std.math.isFinite(r.x0) and std.math.isFinite(r.y0) and std.math.isFinite(r.x1) and std.math.isFinite(r.y1);
}

fn validScroll(s: Scroll) bool {
    return finiteRect(s.viewport) and std.math.isFinite(s.content.width) and std.math.isFinite(s.content.height) and
        std.math.isFinite(s.min_zoom) and std.math.isFinite(s.max_zoom) and s.min_zoom > 0 and s.max_zoom >= s.min_zoom;
}

fn validValue(v: Value) bool {
    return switch (v) {
        .transform => |t| t.finite(),
        .opacity => |o| std.math.isFinite(o),
        .scroll => |p| finitePoint(p),
    };
}

fn validAnimation(a: Animation) bool {
    if (!validValue(a.to)) return false;
    if (a.from) |f| if (std.meta.activeTag(f) != std.meta.activeTag(a.to) or !validValue(f)) return false;
    return switch (a.easing) {
        .linear => true,
        .cubic_bezier => |c| for (c) |v| {
            if (!std.math.isFinite(v)) break false;
        } else c[0] >= 0 and c[0] <= 1 and c[2] >= 0 and c[2] <= 1,
    };
}

const testing = std.testing;

test "transform components compose about the origin" {
    const t: Transform = .{
        .translate = .{ .x = 10, .y = 20 },
        .scale = .{ .x = 2, .y = 2 },
        .rotate = std.math.pi / 2.0,
        .origin = .{ .x = 5, .y = 5 },
    };
    const m = t.affine();
    // The origin stays put apart from the translation.
    const o = m.apply(.{ .x = 5, .y = 5 });
    try testing.expectApproxEqAbs(@as(f32, 15), o.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 25), o.y, 1e-4);
    // One unit right of the origin: scaled to 2, rotated clockwise to down.
    const p = m.apply(.{ .x = 6, .y = 5 });
    try testing.expectApproxEqAbs(@as(f32, 15), p.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 27), p.y, 1e-4);
    try testing.expect(Transform.identity.affine().eql(.identity));
    const half = Transform.lerp(.identity, t, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1.5), half.scale.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), half.rotate, 1e-6);
}

test "ops validate ids and values" {
    try (Op{ .create = 1 }).validate();
    try testing.expectError(error.InvalidArgument, (Op{ .create = 0 }).validate());
    try testing.expectError(error.InvalidArgument, (Op{ .insert = .{ .layer = 2, .parent = 2 } }).validate());
    try testing.expectError(error.InvalidArgument, (Op{ .set_opacity = .{ .layer = 1, .opacity = std.math.nan(f32) } }).validate());
    try testing.expectError(error.InvalidArgument, (Op{ .animate = .{ .layer = 1, .animation = .{
        .to = .{ .opacity = 1 },
        .from = .{ .scroll = .zero },
        .duration_ns = 1,
    } } }).validate());
    try testing.expectError(error.InvalidArgument, (Op{ .animate = .{ .layer = 1, .animation = .{
        .to = .{ .opacity = 1 },
        .duration_ns = 1,
        .easing = .{ .cubic_bezier = .{ 1.5, 0, 0, 1 } },
    } } }).validate());
    try (Op{ .animate = .{ .layer = 1, .animation = .{ .to = .{ .transform = .offset(3, 4) }, .duration_ns = 1 } } }).validate();
}
