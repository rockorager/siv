//! External content of one window (D17) on the compositor thread: frames
//! mapped from their shared memory or held as dma-bufs, and the decision
//! each frame whether a subsurface shows them without copying (promotion)
//! or the frame is composited like an image (the fallback).
//!
//! dma-buf frames become current once their implicit fences signal (the
//! fd polls readable), so neither the compositor nor a renderer waits on a
//! producer's GPU. A subsurface shows one when the compositor's dma-buf
//! feedback lists its format and modifier; a frame it showed is released
//! only once the compositor has let go of its wl_buffers. Composited, the
//! Vulkan renderer imports it; without Vulkan, a linear XRGB8888 one is
//! mapped and read (DMA_BUF_IOCTL_SYNC); any other is not drawn.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const scene = @import("scene");
const raster = @import("raster");
const platform = @import("platform");
const update_mod = @import("update.zig");
const tree_mod = @import("tree.zig");
const Loop = @import("loop").Loop;

const log = std.log.scoped(.compositor);

const ExternalId = update_mod.ExternalId;
const ReleaseHook = update_mod.ExternalReleaseHook;

pub const Mapped = struct {
    frame: update_mod.ExternalFrame,
    /// The mapping, from the frame's offset rounded down to a page. Shared
    /// memory is mapped at once; a dma-buf only when composited, if it is
    /// linear XRGB8888, and null otherwise.
    map: ?[]align(std.heap.page_size_min) u8 = null,
    pixels: ?[*]const u8 = null,
    /// A dma-buf: its description for renderers, at a stable address.
    dmabuf: ?*scene.Dmabuf = null,
    map_tried: bool = false,
    /// A subsurface showed it: its release waits for the compositor's.
    promoted: bool = false,

    /// Takes `frame` (its fds are ours to keep and close) and maps it if
    /// it is in shared memory.
    pub fn init(gpa: Allocator, frame: update_mod.ExternalFrame) !Mapped {
        if (frame.width == 0 or frame.height == 0) return error.InvalidFrame;
        if (frame.dmabuf) |d| {
            if (d.plane_count < 1 or d.plane_count > 4) return error.InvalidFrame;
            const copy = try gpa.create(scene.Dmabuf);
            copy.* = d;
            return .{ .frame = frame, .dmabuf = copy, .map_tried = !mappable(frame) };
        }
        if (frame.stride < frame.width * 4) return error.InvalidFrame;
        var m: Mapped = .{ .frame = frame, .map_tried = true };
        try m.mapPixels();
        return m;
    }

    pub fn deinit(m: Mapped, gpa: Allocator) void {
        if (m.map) |map| {
            if (m.dmabuf != null) dmabufSync(m.frame.fd, dma_buf_sync_end);
            _ = linux.munmap(map.ptr, map.len);
        }
        if (m.dmabuf) |d| gpa.destroy(d);
        m.frame.close();
    }

    /// CPU renderers can read single-plane linear XRGB8888 dma-bufs.
    fn mappable(frame: update_mod.ExternalFrame) bool {
        const d = frame.dmabuf.?;
        return d.format == scene.Dmabuf.xrgb8888 and d.modifier == scene.Dmabuf.modifier_linear and d.plane_count == 1 and frame.stride >= frame.width * 4;
    }

    fn mapPixels(m: *Mapped) !void {
        const frame = m.frame;
        const page = std.heap.page_size_min;
        const start = frame.offset / page * page;
        const len = frame.offset - start + @as(usize, frame.stride) * frame.height;
        const rc = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, frame.fd, @intCast(start));
        if (linux.errno(rc) != .SUCCESS) return error.MapFailed;
        const ptr: [*]align(page) u8 = @ptrFromInt(rc);
        m.map = ptr[0..len];
        m.pixels = ptr + (frame.offset - start);
    }

    fn image(m: *Mapped) scene.ImageRef {
        if (!m.map_tried) {
            m.map_tried = true;
            // CPU access to a dma-buf is bracketed by DMA_BUF_IOCTL_SYNC,
            // which also keeps caches coherent; the end comes at unmap.
            if (m.mapPixels()) dmabufSync(m.frame.fd, dma_buf_sync_start) else |_| {}
        }
        return .{ .pixels = m.pixels, .width = m.frame.width, .height = m.frame.height, .stride = m.frame.stride, .format = .bgrx8_srgb, .key = m.frame.key, .dmabuf = m.dmabuf };
    }
};

// DMA_BUF_IOCTL_SYNC (linux/dma-buf.h): _IOW('b', 0, struct { u64 flags }).
const dma_buf_ioctl_sync: u32 = 0x40086200;
const dma_buf_sync_read: u64 = 1;
const dma_buf_sync_start: u64 = 0 | dma_buf_sync_read;
const dma_buf_sync_end: u64 = 4 | dma_buf_sync_read;

/// Fails harmlessly on fds that are not dma-bufs (memfds in tests).
fn dmabufSync(fd: i32, flags: u64) void {
    var arg: u64 = flags;
    _ = linux.ioctl(fd, dma_buf_ioctl_sync, @intFromPtr(&arg));
}

/// Whether the fd's pending writes are done (a dma-buf polls readable once
/// its implicit write fences signal; other files always do).
fn ready(fd: i32) bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&fds, 1, 0);
    return linux.errno(rc) != .SUCCESS or rc != 0;
}

/// A dma-buf frame waiting for its fences, watched by the loop.
const Pending = struct {
    source: Loop.Source,
    externals: *Externals,
    id: ExternalId,
    mapped: Mapped,
};

const Mode = enum { composited, above, below };

const External = struct {
    frame: ?Mapped = null,
    /// The next frame, until its fences signal.
    pending: ?*Pending = null,
    sub: ?platform.SubsurfaceId = null,
    mode: Mode = .composited,
    /// What the subsurface was last told.
    shown: platform.SubsurfaceState = .{},
    seen: bool = false,
    /// An embedder renders into the subsurface's own wl_surface.
    embed: ?Embed = null,
    /// Receives released frames on this thread instead of the UI.
    hook: ?ReleaseHook = null,
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
    /// Watches pending dma-buf frames; without it they show at once.
    loop: ?*Loop = null,
    /// Told when a pending frame becomes current (the caller redraws).
    on_ready: ?Ready = null,
    items: std.ArrayList(?External) = .empty,
    found: std.ArrayList(tree_mod.Found) = .empty,
    /// Frames replaced or removed since the last frame; released after it.
    retired: std.ArrayList(Retired) = .empty,
    /// New sizes for embedders, sent after the frame.
    configures: std.ArrayList(Configure) = .empty,
    /// Retired frames a subsurface showed, until the compositor releases
    /// them (`subsurfaceReleased`).
    waiting: std.ArrayList(Retired) = .empty,
    /// A composited dma-buf had no pixels to read (logged once).
    unmappable_logged: bool = false,

    pub const Ready = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, id: ExternalId) void };

    pub const Retired = struct {
        id: ExternalId,
        mapped: Mapped,
        hook: ?ReleaseHook = null,
        /// The slot is gone: drop the hook after this release.
        last: bool = false,
    };

    pub fn init(gpa: Allocator) Externals {
        return .{ .gpa = gpa };
    }

    /// Frames still held are released (no frame reads them any more) and
    /// hooks dropped.
    pub fn deinit(e: *Externals) void {
        for (e.items.items) |item| if (item) |x| {
            if (x.pending) |pd| {
                if (x.hook) |h| h.released(h.ctx, pd.mapped.frame.key);
                e.dropPending(pd);
            }
            if (x.frame) |m| {
                if (x.hook) |h| h.released(h.ctx, m.frame.key);
                m.deinit(e.gpa);
            }
            if (x.hook) |h| h.dropped(h.ctx);
        };
        for ([_][]Retired{ e.retired.items, e.waiting.items }) |list| for (list) |r| {
            if (r.hook) |h| {
                h.released(h.ctx, r.mapped.frame.key);
                if (r.last) h.dropped(h.ctx);
            }
            r.mapped.deinit(e.gpa);
        };
        e.items.deinit(e.gpa);
        e.found.deinit(e.gpa);
        e.retired.deinit(e.gpa);
        e.waiting.deinit(e.gpa);
        e.configures.deinit(e.gpa);
    }

    fn dropPending(e: *Externals, pd: *Pending) void {
        if (e.loop) |l| l.removeSource(&pd.source);
        pd.mapped.deinit(e.gpa);
        e.gpa.destroy(pd);
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
        if (x.pending) |pd| {
            if (e.loop) |l| l.removeSource(&pd.source);
            e.retire(id, pd.mapped, x.hook);
            e.gpa.destroy(pd);
            x.pending = null;
        }
        if (x.frame) |m| {
            e.retireLast(id, m, x.hook);
        } else if (x.hook) |h| h.dropped(h.ctx);
        e.items.items[id - 1] = null;
    }

    /// Sets (or with null clears) where a slot's released frames go.
    pub fn setHook(e: *Externals, id: ExternalId, hook: ?ReleaseHook) bool {
        const x = e.get(id) orelse return false;
        x.hook = hook;
        return true;
    }

    fn retire(e: *Externals, id: ExternalId, m: Mapped, hook: ?ReleaseHook) void {
        e.retired.append(e.gpa, .{ .id = id, .mapped = m, .hook = hook }) catch {
            // Released early rather than leaked; nothing has shown it
            // since the frame that replaced it was taken.
            if (hook) |h| h.released(h.ctx, m.frame.key);
            m.deinit(e.gpa);
        };
    }

    fn retireLast(e: *Externals, id: ExternalId, m: Mapped, hook: ?ReleaseHook) void {
        e.retired.append(e.gpa, .{ .id = id, .mapped = m, .hook = hook, .last = true }) catch {
            if (hook) |h| {
                h.released(h.ctx, m.frame.key);
                h.dropped(h.ctx);
            }
            m.deinit(e.gpa);
        };
    }

    /// Takes a new frame (owning its fds). True if it is current now;
    /// false if the id is unknown, the frame cannot be mapped, or it is a
    /// dma-buf still being written (`on_ready` follows once it is done).
    pub fn setFrame(e: *Externals, id: ExternalId, frame: update_mod.ExternalFrame) bool {
        const x = e.get(id) orelse {
            frame.close();
            return false;
        };
        const m = Mapped.init(e.gpa, frame) catch {
            frame.close();
            return false;
        };
        // A newer frame replaces one still pending, which was never shown.
        if (x.pending) |pd| {
            if (e.loop) |l| l.removeSource(&pd.source);
            e.retire(id, pd.mapped, x.hook);
            e.gpa.destroy(pd);
            x.pending = null;
        }
        if (m.dmabuf != null and !ready(frame.fd)) if (e.loop) |l| {
            if (e.gpa.create(Pending)) |pd| {
                pd.* = .{ .source = .{ .fd = frame.fd, .events = linux.EPOLL.IN, .func = onPendingReady }, .externals = e, .id = id, .mapped = m };
                if (l.addSource(&pd.source)) {
                    x.pending = pd;
                    return false;
                } else |_| e.gpa.destroy(pd);
            } else |_| {}
            // Unwatchable: shown now.
        };
        e.makeCurrent(id, x, m);
        return true;
    }

    fn makeCurrent(e: *Externals, id: ExternalId, x: *External, m: Mapped) void {
        if (x.frame) |old| e.retire(id, old, x.hook);
        x.frame = m;
    }

    fn onPendingReady(source: *Loop.Source, _: u32) void {
        const pd: *Pending = @fieldParentPtr("source", source);
        const e = pd.externals;
        const id = pd.id;
        const x = e.get(id).?;
        e.loop.?.removeSource(source);
        x.pending = null;
        e.makeCurrent(id, x, pd.mapped);
        e.gpa.destroy(pd);
        if (e.on_ready) |r| r.func(r.ctx, id);
    }

    /// The compositor let go of a dma-buf frame a subsurface showed
    /// (`platform.Event.subsurface_released`): release it if it was
    /// waiting for that.
    pub fn subsurfaceReleased(e: *Externals, key: u64, release: anytype) void {
        var i: usize = 0;
        while (i < e.waiting.items.len) {
            const r = e.waiting.items[i];
            if (r.mapped.frame.key != key) {
                i += 1;
                continue;
            }
            _ = e.waiting.swapRemove(i);
            releaseRetired(e.gpa, r, release);
        }
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
            .composited => if (x.frame) |*m| blk: {
                const ref = m.image();
                if (ref.pixels == null and !e.unmappable_logged) {
                    e.unmappable_logged = true;
                    log.info("composited dma-buf frames that cannot be mapped draw only where Vulkan imports them", .{});
                }
                break :blk .{ .image = ref };
            } else .none,
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
            // A dma-buf only if the compositor takes its format and modifier.
            const takes = if (x.frame) |m| if (m.frame.dmabuf) |d| p.supportsDmabuf(d.format, d.modifier) else true else false;
            const mode: Mode = if (!f.promotable or !takes or x.seen) .composited else if (f.covered) .below else .above;
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
                    .dmabuf = if (x.frame.?.dmabuf) |d| toPlatform(d.*) else null,
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
            x.frame.?.promoted = true;
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

    /// After a frame: frames retired before it are no longer read by siv;
    /// those a subsurface showed wait until the compositor is done too.
    pub fn endFrame(e: *Externals, p: platform.Platform, window: platform.WindowId, release: anytype) void {
        for (e.retired.items) |r| {
            if (r.mapped.promoted and p.dmabufBusy(window, r.mapped.frame.key)) {
                if (e.waiting.append(e.gpa, r)) continue else |_| {} // released early rather than leaked
            }
            releaseRetired(e.gpa, r, release);
        }
        e.retired.clearRetainingCapacity();
    }

    fn releaseRetired(gpa: Allocator, r: Retired, release: anytype) void {
        if (r.hook) |h| {
            h.released(h.ctx, r.mapped.frame.key);
            if (r.last) h.dropped(h.ctx);
        } else release.external(r.id, r.mapped.frame.key);
        r.mapped.deinit(gpa);
    }
};

fn toPlatform(d: scene.Dmabuf) platform.Dmabuf {
    var out: platform.Dmabuf = .{ .format = d.format, .modifier = d.modifier, .plane_count = d.plane_count };
    for (d.planes[0..d.plane_count], 0..) |pl, i| out.planes[i] = .{ .fd = pl.fd, .offset = pl.offset, .stride = pl.stride };
    return out;
}
