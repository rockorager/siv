//! External content of one window (D17) on the compositor thread: frames
//! mapped from their shared memory, and the decision each frame whether a
//! subsurface shows them without copying (promotion) or the frame is
//! composited like an image (the fallback).

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const scene = @import("scene");
const raster = @import("raster");
const platform = @import("platform");
const update_mod = @import("update.zig");
const tree_mod = @import("tree.zig");

const ExternalId = update_mod.ExternalId;

pub const Mapped = struct {
    frame: update_mod.ExternalFrame,
    /// The mapping, from the frame's offset rounded down to a page.
    map: []align(std.heap.page_size_min) u8,
    pixels: [*]const u8,

    /// Maps `frame` (its fd is ours to keep and close).
    pub fn init(frame: update_mod.ExternalFrame) !Mapped {
        const page = std.heap.page_size_min;
        const start = frame.offset / page * page;
        const len = frame.offset - start + @as(usize, frame.stride) * frame.height;
        if (frame.width == 0 or frame.height == 0 or frame.stride < frame.width * 4) return error.InvalidFrame;
        const rc = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, frame.fd, @intCast(start));
        if (linux.errno(rc) != .SUCCESS) return error.MapFailed;
        const ptr: [*]align(page) u8 = @ptrFromInt(rc);
        return .{ .frame = frame, .map = ptr[0..len], .pixels = ptr + (frame.offset - start) };
    }

    pub fn deinit(m: Mapped) void {
        _ = linux.munmap(m.map.ptr, m.map.len);
        _ = linux.close(m.frame.fd);
    }

    fn image(m: Mapped) scene.ImageRef {
        return .{ .pixels = m.pixels, .width = m.frame.width, .height = m.frame.height, .stride = m.frame.stride, .format = .bgrx8_srgb, .key = m.frame.key };
    }
};

const Mode = enum { composited, above, below };

const External = struct {
    frame: ?Mapped = null,
    sub: ?platform.SubsurfaceId = null,
    mode: Mode = .composited,
    /// What the subsurface was last told.
    shown: platform.SubsurfaceState = .{},
    seen: bool = false,
    /// An embedder renders into the subsurface's own wl_surface.
    embed: ?Embed = null,
};

/// An embedder's surface: the size it was told to render at, and what it
/// says it committed.
const Embed = struct {
    told: Size = .{},
    /// The buffer size of its last committed frame.
    buffer: Size = .{},
    /// A frame was committed since the window's last commit.
    committed: bool = false,
};

const Size = struct { width: u32 = 0, height: u32 = 0 };

pub const Configure = struct { id: ExternalId, width: u32, height: u32, buffer_width: u32, buffer_height: u32 };

pub const Externals = struct {
    gpa: Allocator,
    items: std.ArrayList(?External) = .empty,
    found: std.ArrayList(tree_mod.Found) = .empty,
    /// Frames replaced or removed since the last frame; released after it.
    retired: std.ArrayList(Retired) = .empty,
    /// New sizes for embedders, sent after the frame.
    configures: std.ArrayList(Configure) = .empty,

    pub const Retired = struct { id: ExternalId, mapped: Mapped };

    pub fn init(gpa: Allocator) Externals {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *Externals) void {
        for (e.items.items) |item| if (item) |x| if (x.frame) |m| m.deinit();
        for (e.retired.items) |r| r.mapped.deinit();
        e.items.deinit(e.gpa);
        e.found.deinit(e.gpa);
        e.retired.deinit(e.gpa);
        e.configures.deinit(e.gpa);
    }

    fn get(e: *Externals, id: ExternalId) ?*External {
        if (id == 0 or id > e.items.items.len) return null;
        return if (e.items.items[id - 1]) |*x| x else null;
    }

    pub fn create(e: *Externals) Allocator.Error!ExternalId {
        for (e.items.items, 0..) |item, i| if (item == null) {
            e.items.items[i] = .{};
            return @intCast(i + 1);
        };
        try e.items.append(e.gpa, .{});
        return @intCast(e.items.items.len);
    }

    /// An external whose content an embedder renders into a wl_surface of
    /// its own (`Platform.createEmbedSurface`); hidden until placed.
    pub fn createSurface(e: *Externals, p: platform.Platform, window: platform.WindowId) !struct { ExternalId, platform.EmbedSurface } {
        const id = try e.create();
        errdefer e.items.items[id - 1] = null;
        const es = try p.createEmbedSurface(window);
        const x = e.get(id).?;
        x.sub = es.sub;
        x.embed = .{};
        x.mode = .above;
        x.shown = .{ .embed = true };
        return .{ id, es };
    }

    /// The embedder committed a frame of this size; the window's next
    /// commit shows it.
    pub fn surfaceCommitted(e: *Externals, id: ExternalId, width: u32, height: u32) bool {
        const x = e.get(id) orelse return false;
        const em = &(x.embed orelse return false);
        em.buffer = .{ .width = width, .height = height };
        em.committed = true;
        return true;
    }

    pub fn destroy(e: *Externals, p: platform.Platform, window: platform.WindowId, id: ExternalId) void {
        const x = e.get(id) orelse return;
        if (x.sub) |sub| p.destroySubsurface(window, sub);
        if (x.frame) |m| e.retire(id, m);
        e.items.items[id - 1] = null;
    }

    fn retire(e: *Externals, id: ExternalId, m: Mapped) void {
        e.retired.append(e.gpa, .{ .id = id, .mapped = m }) catch m.deinit();
    }

    /// Takes a new frame (owning its fd). False if the id is unknown or
    /// the frame cannot be mapped.
    pub fn setFrame(e: *Externals, id: ExternalId, frame: update_mod.ExternalFrame) bool {
        const x = e.get(id) orelse {
            _ = linux.close(frame.fd);
            return false;
        };
        const m = Mapped.init(frame) catch {
            _ = linux.close(frame.fd);
            return false;
        };
        if (x.frame) |old| e.retire(id, old);
        x.frame = m;
        return true;
    }

    /// Composition draws frames that are not on a subsurface, and holes
    /// for those below the window.
    pub fn resolver(e: *Externals) tree_mod.Externals {
        return .{ .ctx = e, .draw = draw };
    }

    fn draw(ctx: *anyopaque, id: ExternalId) tree_mod.Draw {
        const e: *Externals = @ptrCast(@alignCast(ctx));
        const x = e.get(id) orelse return .none;
        if (x.embed != null and !x.shown.visible) return .none;
        return switch (x.mode) {
            .above => .none,
            .below => .hole,
            .composited => if (x.frame) |m| .{ .image = m.image() } else .none,
        };
    }

    /// Decides promotion for this frame and updates the subsurfaces.
    /// Returns whether a subsurface changed (it applies with the window's
    /// next commit). Externals whose drawing changed are touched in `t`.
    pub fn place(e: *Externals, p: platform.Platform, window: platform.WindowId, t: *tree_mod.Tree, bounds: raster.Rect, scale: f64) Allocator.Error!bool {
        try t.externalPlacements(&e.found, bounds);
        var changed = false;
        for (e.items.items) |*item| if (item.*) |*x| {
            x.seen = false;
            if (x.embed) |*em| if (em.committed) {
                em.committed = false;
                changed = true;
            };
        };
        for (e.found.items) |f| {
            const x = e.get(f.id) orelse continue;
            if (x.embed != null) {
                if (x.seen) continue; // shown once
                changed = (try e.placeSurface(p, window, t, x, f, scale)) or changed;
                continue;
            }
            // Above the window when nothing covers it; below with a hole
            // when something does (the frames are opaque). One external
            // shown twice is composited.
            const mode: Mode = if (!f.promotable or x.frame == null or x.seen) .composited else if (f.covered) .below else .above;
            x.seen = true;
            if (mode != x.mode) t.touchExternal(f.id);
            x.mode = mode;
            if (mode == .composited) continue;
            const fw: f32 = @floatFromInt(x.frame.?.frame.width);
            const fh: f32 = @floatFromInt(x.frame.?.frame.height);
            const cropped = !f.visible.eql(f.rect);
            const state: platform.SubsurfaceState = .{
                .visible = true,
                .rect = round(f.visible),
                .below = mode == .below,
                .source = if (cropped) sourceRect(f.source, fw, fh) else null,
                .frame = .{
                    .fd = x.frame.?.frame.fd,
                    .offset = x.frame.?.frame.offset,
                    .width = x.frame.?.frame.width,
                    .height = x.frame.?.frame.height,
                    .stride = x.frame.?.frame.stride,
                    .key = x.frame.?.frame.key,
                },
            };
            if (x.sub == null) x.sub = p.createSubsurface(window) catch {
                // Without a subsurface, composite it.
                x.mode = .composited;
                t.touchExternal(f.id);
                continue;
            };
            if (!std.meta.eql(state, x.shown)) {
                p.setSubsurface(window, x.sub.?, &state) catch {};
                x.shown = state;
                changed = true;
            }
        }
        for (e.items.items, 0..) |*item, i| if (item.*) |*x| {
            if (x.embed != null) {
                if (!x.seen and x.shown.visible) {
                    x.shown.visible = false;
                    p.setSubsurface(window, x.sub.?, &x.shown) catch {};
                    t.touchExternal(@intCast(i + 1));
                    changed = true;
                }
                continue;
            }
            const keep = x.seen and x.mode != .composited;
            if (!keep) {
                if (x.mode != .composited) t.touchExternal(@intCast(i + 1));
                x.mode = .composited;
                if (x.sub != null and x.shown.visible) {
                    x.shown = .{};
                    p.setSubsurface(window, x.sub.?, &x.shown) catch {};
                    changed = true;
                }
            }
        };
        return changed;
    }

    /// Places an embedder's surface. Nothing can composite its pixels, so
    /// it stays on its subsurface: above the window when it is unobstructed,
    /// and otherwise below with a hole, so that content painted over it
    /// shows. The window and clips crop it through the viewport's source
    /// rectangle (rotated and translucent placements on their bounding box,
    /// below the window), which needs a frame of the size the embedder was
    /// told: a source outside its buffer would be a protocol error. A
    /// placement that needs cropping stays hidden until such a frame
    /// arrives, so that nothing ever shows outside the window or its clips.
    fn placeSurface(e: *Externals, p: platform.Platform, window: platform.WindowId, t: *tree_mod.Tree, x: *External, f: tree_mod.Found, scale: f64) Allocator.Error!bool {
        const id = f.id;
        const em = &x.embed.?;
        const full = round(f.rect);
        if (f.visible.isEmpty() or full.width <= 0 or full.height <= 0) return false; // hidden after the loop
        x.seen = true;
        const size: Size = .{ .width = @intCast(full.width), .height = @intCast(full.height) };
        const buffer: Size = .{
            .width = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(size.width)) * scale))),
            .height = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(size.height)) * scale))),
        };
        if (!std.meta.eql(buffer, em.told)) {
            try e.configures.append(e.gpa, .{ .id = id, .width = size.width, .height = size.height, .buffer_width = buffer.width, .buffer_height = buffer.height });
            em.told = buffer;
        }
        const cropped = !f.visible.eql(f.rect);
        const fits = std.meta.eql(em.buffer, em.told);
        var state: platform.SubsurfaceState = .{ .embed = true };
        if (!cropped or fits) {
            state.visible = true;
            state.rect = full;
            if (cropped) {
                state.rect = round(f.visible);
                state.source = sourceRect(f.source, @floatFromInt(em.buffer.width), @floatFromInt(em.buffer.height));
            }
            state.below = !f.promotable or f.covered;
        }
        const mode: Mode = if (state.below) .below else .above;
        if (mode != x.mode or state.visible != x.shown.visible) t.touchExternal(id);
        x.mode = mode;
        if (std.meta.eql(state, x.shown)) return false;
        p.setSubsurface(window, x.sub.?, &state) catch {};
        x.shown = state;
        return true;
    }

    /// The part `frac` (0..1 on each axis) of a `w` × `h` buffer, snapped
    /// inward to wl_fixed's 1/256 grid so that rounding can never put it
    /// outside the buffer (a protocol error).
    fn sourceRect(frac: raster.Rect, w: f32, h: f32) @FieldType(platform.SubsurfaceState, "source") {
        const x0 = @ceil(std.math.clamp(frac.x0 * w, 0, w) * 256) / 256;
        const y0 = @ceil(std.math.clamp(frac.y0 * h, 0, h) * 256) / 256;
        const x1 = @floor(std.math.clamp(frac.x1 * w, 0, w) * 256) / 256;
        const y1 = @floor(std.math.clamp(frac.y1 * h, 0, h) * 256) / 256;
        return .{ .x = x0, .y = y0, .width = @max(x1 - x0, 1.0 / 256.0), .height = @max(y1 - y0, 1.0 / 256.0) };
    }

    fn round(r: raster.Rect) platform.Rect {
        const x0: i32 = @intFromFloat(@round(r.x0));
        const y0: i32 = @intFromFloat(@round(r.y0));
        return .{ .x = x0, .y = y0, .width = @as(i32, @intFromFloat(@round(r.x1))) - x0, .height = @as(i32, @intFromFloat(@round(r.y1))) - y0 };
    }

    /// After a frame: frames retired before it are no longer read.
    pub fn endFrame(e: *Externals, release: anytype) void {
        for (e.retired.items) |r| {
            release.external(r.id, r.mapped.frame.key);
            r.mapped.deinit();
        }
        e.retired.clearRetainingCapacity();
    }
};
