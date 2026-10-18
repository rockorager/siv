//! The presentation boundary (D10): a window's backend takes a composed
//! frame (display list, device damage, root transform) and puts it on
//! screen. The layer tree, animation, and damage tracking sit above it and
//! do not know which backend draws.
//!
//! `Cpu` renders with the CPU renderer on the worker pool into the
//! platform's wl_shm buffers. A reused buffer is brought up to date by
//! re-encoding what changed since it was last shown (buffer age) from the
//! renderer's persistent framebuffer, without redrawing; the compositor is
//! told only this frame's damage, in buffer pixels.
//!
//! `Vulkan` renders with the Vulkan renderer and presents through a Vulkan
//! swapchain on the window's wl_surface, with the same damage for
//! incremental present. When the device is lost (or the swapchain fails)
//! the window falls back to `Cpu` at once and presents that frame with it
//! (D10).

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster");
const scene = @import("scene");
const render_cpu = @import("render_cpu");
const render_vulkan = @import("render_vulkan");
const platform = @import("platform");

const log = std.log.scoped(.compositor);

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

/// How a Vulkan backend presents.
pub const VulkanOptions = struct {
    device: *render_vulkan.Device,
    present_mode: render_vulkan.Swapchain.PresentMode = .auto,
};

/// A window's presentation backend.
pub const Surface = union(enum) {
    cpu: *Cpu,
    vulkan: *Vulkan,

    /// A Vulkan backend when `vulkan` is given and its renderer can be
    /// created, else the CPU backend.
    pub fn create(gpa: Allocator, executor: render_cpu.Executor, vulkan: ?VulkanOptions) Allocator.Error!Surface {
        if (vulkan) |o| {
            if (Vulkan.create(gpa, executor, o)) |v| return .{ .vulkan = v } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => log.warn("Vulkan renderer unavailable ({t}); using the CPU renderer", .{err}),
            }
        }
        return .{ .cpu = try Cpu.create(gpa, executor) };
    }

    /// Destroy before the platform window: a swapchain refers to it.
    pub fn destroy(s: Surface) void {
        switch (s) {
            inline else => |b| b.destroy(),
        }
    }

    /// Frees the renderer's caches under memory pressure (D42).
    pub fn trimCaches(s: Surface) void {
        switch (s) {
            .cpu => |c| c.renderer.trimCaches(),
            .vulkan => |v| v.renderer.trimCaches(),
        }
    }

    /// Presents `frame` on window `id`. Returns false when no buffer is
    /// free yet; try again shortly, with full damage.
    pub fn present(s: *Surface, p: platform.Platform, id: platform.WindowId, frame: Frame) Error!bool {
        switch (s.*) {
            .cpu => |c| return c.present(p, id, frame),
            .vulkan => |v| return v.present(p, id, frame) catch |err| {
                // Runtime fallback (D10): this window continues, and
                // presents this frame, with the CPU renderer.
                log.warn("Vulkan presentation failed ({t}); window {d} falls back to the CPU renderer", .{ err, id });
                const gpa = v.gpa;
                const executor = v.executor;
                v.destroy();
                p.setExternalPresenter(id, false);
                s.* = .{ .cpu = try Cpu.create(gpa, executor) };
                return s.cpu.present(p, id, frame);
            },
        }
    }
};

pub const Vulkan = struct {
    gpa: Allocator,
    executor: render_cpu.Executor,
    device: *render_vulkan.Device,
    present_mode: render_vulkan.Swapchain.PresentMode,
    renderer: *render_vulkan.Renderer,
    swapchain: ?*render_vulkan.Swapchain = null,

    pub fn create(gpa: Allocator, executor: render_cpu.Executor, o: VulkanOptions) render_vulkan.Error!*Vulkan {
        if (o.device.lost) return error.DeviceLost;
        const v = try gpa.create(Vulkan);
        errdefer gpa.destroy(v);
        v.* = .{
            .gpa = gpa,
            .executor = executor,
            .device = o.device,
            .present_mode = o.present_mode,
            .renderer = try render_vulkan.Renderer.create(gpa, o.device, executor),
        };
        return v;
    }

    pub fn destroy(v: *Vulkan) void {
        if (v.swapchain) |s| s.destroy();
        v.renderer.destroy();
        v.gpa.destroy(v);
    }

    /// Fails with any error that should end Vulkan presentation for the
    /// window (the caller falls back).
    fn present(v: *Vulkan, p: platform.Platform, id: platform.WindowId, frame: Frame) (render_vulkan.Error || error{Unsupported})!bool {
        if (v.device.lost) return error.DeviceLost;
        if (v.swapchain == null) {
            const target = p.vulkanSurface(id) orelse return error.Unsupported;
            v.swapchain = try render_vulkan.Swapchain.create(v.gpa, v.device, .{
                .display = target.display,
                .surface = target.surface,
                .present_mode = v.present_mode,
            });
            p.setExternalPresenter(id, true);
        }
        const sc = v.swapchain.?;
        // Old Mesa FIFO waits for the previous commit's frame callback
        // inside vkQueuePresentKHR, forever for a hidden window; the
        // platform's own callback for that commit fires at the same time.
        if (sc.blocksOnFrameCallback() and p.frameCallbackPending(id)) return false;

        const state = p.window(id);
        sc.configure(state.bufferWidth(), state.bufferHeight()) catch |err| switch (err) {
            error.OutOfDate => return false,
            else => |e| return e,
        };
        var damage: ?[]const IRect = frame.damage;
        if (sc.width != v.renderer.width or sc.height != v.renderer.height) {
            try v.renderer.resize(sc.width, sc.height);
            damage = null;
        }
        try v.renderer.beginFrame();
        const n = v.renderer.frame;
        const index = try sc.acquire(n) orelse return false;
        try v.renderer.render(frame.list, .{ .root = frame.root, .damage = damage, .background = frame.background }, sc.target(index, n));

        const Commit = struct {
            sc: *render_vulkan.Swapchain,
            index: u32,
            damage: ?[]const IRect,
            fn run(ctx: *anyopaque) anyerror!void {
                const c: *@This() = @ptrCast(@alignCast(ctx));
                return c.sc.present(c.index, c.damage);
            }
        };
        var commit: Commit = .{ .sc = sc, .index = index, .damage = damage };
        p.presentExternal(id, .{ .ctx = &commit, .func = Commit.run }) catch |err| switch (err) {
            // The surface changed; the next frame recreates the swapchain.
            error.OutOfDate => return false,
            error.OutOfMemory, error.DeviceLost, error.SurfaceLost, error.Unavailable, error.Unexpected => |e| return e,
            else => return error.Unexpected,
        };
        return true;
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

        // Few enough for the display server's region to keep apart (the
        // tracker gives at most max_rects).
        var kept: [scene.damage.max_rects]IRect = undefined;
        const n = @min(damage.len, kept.len);
        @memcpy(kept[0..n], damage[0..n]);
        for (damage[n..]) |r| kept[n - 1] = kept[n - 1].unite(r);
        c.rects.clearRetainingCapacity();
        for (kept[0..scene.damage.mergeBands(kept[0..n])]) |r| try c.rects.append(c.gpa, .{ .x = r.x0, .y = r.y0, .width = r.width(), .height = r.height() });
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
