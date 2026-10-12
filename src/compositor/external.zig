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
};

pub const Externals = struct {
    gpa: Allocator,
    items: std.ArrayList(?External) = .empty,
    found: std.ArrayList(tree_mod.Found) = .empty,
    /// Frames replaced or removed since the last frame; released after it.
    retired: std.ArrayList(Retired) = .empty,

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
        return switch (x.mode) {
            .above => .none,
            .below => .hole,
            .composited => if (x.frame) |m| .{ .image = m.image() } else .none,
        };
    }

    /// Decides promotion for this frame and updates the subsurfaces.
    /// Returns whether a subsurface changed (it applies with the window's
    /// next commit). Externals whose drawing changed are touched in `t`.
    pub fn place(e: *Externals, p: platform.Platform, window: platform.WindowId, t: *tree_mod.Tree) Allocator.Error!bool {
        try t.externalPlacements(&e.found);
        for (e.items.items) |*item| if (item.*) |*x| {
            x.seen = false;
        };
        var changed = false;
        for (e.found.items) |f| {
            const x = e.get(f.id) orelse continue;
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
                .source = if (cropped) .{ .x = f.source.x0 * fw, .y = f.source.y0 * fh, .width = f.source.width() * fw, .height = f.source.height() * fh } else null,
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
