//! The presentation boundary (D10): a window's backend takes a composed
//! frame (display list, device damage, root transform) and puts it on
//! screen. The layer tree, animation, and damage tracking sit above it and
//! do not know which backend draws.
//!
//! `Cpu` renders with the CPU renderer on the worker pool into the
//! platform's wl_shm buffers. A reused buffer is brought up to date by
//! re-encoding what changed since it was last shown (buffer age) from the
//! renderer's persistent framebuffer, without redrawing; the compositor is
//! told only this frame's damage, in buffer pixels. A Vulkan backend would
//! present through its own swapchain on the same surface and use the same
//! damage for incremental present.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster");
const scene = @import("scene");
const render_cpu = @import("render_cpu");
const platform = @import("platform");

const IRect = raster.IRect;
const Affine = raster.Affine;

/// What a backend presents.
pub const Frame = struct {
    list: scene.DisplayList,
    /// Device rectangles that differ from the previous frame. Ignored (all
    /// is redrawn) after a size change.
    damage: []const IRect,
    /// Window coordinates to buffer pixels.
    root: Affine,
    background: scene.Color,
};

pub const Error = error{OutOfMemory} || platform.Error;

/// A window's presentation backend.
pub const Surface = union(enum) {
    cpu: *Cpu,

    pub fn create(gpa: Allocator, executor: render_cpu.Executor) Allocator.Error!Surface {
        return .{ .cpu = try Cpu.create(gpa, executor) };
    }

    pub fn destroy(s: Surface) void {
        switch (s) {
            inline else => |b| b.destroy(),
        }
    }

    /// Presents `frame` on window `id`. Returns false when no buffer is
    /// free yet; try again shortly, with full damage.
    pub fn present(s: Surface, p: platform.Platform, id: platform.WindowId, frame: Frame) Error!bool {
        return switch (s) {
            inline else => |b| b.present(p, id, frame),
        };
    }
};

pub const Cpu = struct {
    gpa: Allocator,
    renderer: *render_cpu.Renderer,
    /// Frames presented so far; numbers frames in `slots` and `history`.
    frame: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    slots: [4]Slot = @splat(.{}),
    history: [max_age]History = @splat(.{}),
    encode: std.ArrayList(IRect) = .empty,
    rects: std.ArrayList(platform.Rect) = .empty,

    /// Older buffers are redrawn in full.
    const max_age = 4;

    const Slot = struct {
        /// Frame last presented from the buffer; 0 for none.
        frame: u64 = 0,
        pixels: usize = 0,
    };

    const History = struct {
        rects: [scene.damage.max_rects]IRect = undefined,
        len: u8 = 0,
        all: bool = true,
    };

    pub fn create(gpa: Allocator, executor: render_cpu.Executor) Allocator.Error!*Cpu {
        const c = try gpa.create(Cpu);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .renderer = try render_cpu.Renderer.create(gpa, executor) };
        return c;
    }

    pub fn destroy(c: *Cpu) void {
        c.renderer.destroy();
        c.encode.deinit(c.gpa);
        c.rects.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    pub fn present(c: *Cpu, p: platform.Platform, id: platform.WindowId, frame: Frame) Error!bool {
        const buf = p.acquireBuffer(id) catch |err| switch (err) {
            error.NoBufferAvailable => return false,
            else => |e| return e,
        };
        const vp = IRect.xywh(0, 0, @intCast(buf.width), @intCast(buf.height));
        var damage = frame.damage;
        if (buf.width != c.width or buf.height != c.height) {
            try c.renderer.resize(buf.width, buf.height);
            c.width = buf.width;
            c.height = buf.height;
            c.slots = @splat(.{});
            damage = &.{vp};
        }
        c.frame += 1;

        // What the reused buffer lacks: the damage of every frame since
        // it was last presented.
        c.encode.clearRetainingCapacity();
        const slot = c.slots[buf.slot];
        const age = c.frame - slot.frame;
        const known = slot.frame != 0 and slot.pixels == @intFromPtr(buf.pixels.ptr) and age <= max_age;
        if (!known) {
            try c.encode.append(c.gpa, vp);
        } else {
            var f = slot.frame + 1;
            while (f < c.frame) : (f += 1) {
                const h = &c.history[f % max_age];
                if (h.all) {
                    c.encode.clearRetainingCapacity();
                    try c.encode.append(c.gpa, vp);
                    break;
                }
                try c.encode.appendSlice(c.gpa, h.rects[0..h.len]);
            }
        }

        if (damage.len > 0 or c.encode.items.len > 0) {
            try c.renderer.render(frame.list, .{
                .root = frame.root,
                .damage = damage,
                .background = frame.background,
                .target = .{ .pixels = buf.pixels.ptr, .stride = buf.stride, .format = .argb8888 },
                .encode = c.encode.items,
            });
        }

        c.rects.clearRetainingCapacity();
        for (damage) |r| try c.rects.append(c.gpa, .{ .x = r.x0, .y = r.y0, .width = r.width(), .height = r.height() });
        p.present(id, buf, c.rects.items);

        const h = &c.history[c.frame % max_age];
        h.all = damage.len > h.rects.len;
        if (!h.all) {
            @memcpy(h.rects[0..damage.len], damage);
            h.len = @intCast(damage.len);
        }
        c.slots[buf.slot] = .{ .frame = c.frame, .pixels = @intFromPtr(buf.pixels.ptr) };
        return true;
    }
};
