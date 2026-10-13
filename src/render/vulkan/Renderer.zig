//! The Vulkan renderer (D10, D11): draws display lists into a persistent
//! linear FP16 image with instanced quads and encodes it for output. One
//! per window (glyph atlases are per renderer, like the CPU renderer's
//! glyph cache).
//!
//! A frame:
//!
//! 1. Prepare (calling thread): walk the list as the CPU renderer does
//!    (device transforms, clip bounds, culling) into instances, paint and
//!    clip records, and ops. Rectangles and rounded rectangles under
//!    axis-aligned transforms are analytic; every other shape becomes a
//!    path job. Glyphs are placed through the CPU glyph cache, and new
//!    entries are queued for the glyph atlases (D14).
//! 2. Regions: damage, widened like the CPU renderer's where a backdrop
//!    blur's backdrop changed, then each region grown until it holds the
//!    backdrop of every blur it touches, so a blur reads only pixels drawn
//!    in the same pass. Pixels outside the damage are redrawn identically.
//! 3. Path jobs are flattened, stroked, and rasterized on the worker pool
//!    with the shared coverage rasterizer (exact area coverage, 8 bits)
//!    into mask pages, only where the regions need them.
//! 4. Record: for each region, the ops run in order into the working
//!    image. Isolated layers render into per-depth layer images and are
//!    composited back with fixed-function source-over or, for other blend
//!    modes, against a copy of their backdrop. Backdrop blurs copy their
//!    backdrop, run the CPU renderer's separable passes (an exact Gaussian
//!    up to sigma 2, three box passes above) in FP32, and mix the result
//!    in by coverage. Finally the whole working image is encoded (sRGB,
//!    premultiplied in encoded space, ordered dither) into the target.
//!
//! Each shader evaluates the CPU renderer's formulas at pixel centers, so
//! output matches the CPU golden images within their tolerance.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster");
const scene = @import("scene");
const render_cpu = @import("render_cpu");
const pool = @import("pool");
const vk = @import("vk.zig");
const c = vk.c;
const Device = @import("Device.zig");
const dmabuf = @import("dmabuf.zig");
const Image = Device.Image;
const Buffer = Device.Buffer;

const glyph = render_cpu.glyph;
const Point = raster.Point;
const Rect = raster.Rect;
const IRect = raster.IRect;
const Affine = raster.Affine;
const Radii = raster.Radii;
const FillRule = raster.FillRule;
const Executor = pool.Executor;

const Renderer = @This();
const log = std.log.scoped(.vulkan);

pub const Error = vk.Error;

pub const frames_in_flight = 2;

pub const Options = struct {
    /// Root coordinates to device pixels.
    root: Affine = .identity,
    /// Device rectangles to redraw; null redraws everything.
    damage: ?[]const IRect = null,
    background: scene.Color = .transparent,
};

/// Where a frame's encoded output goes.
pub const Target = union(enum) {
    /// Copied back as R, G, B, A bytes (wl_shm abgr8888) and waited for.
    readback: struct { pixels: [*]u8, stride: usize },
    /// A swapchain image, rendered after `wait` and signaling `signal`, left
    /// in the present layout.
    swapchain: struct {
        image: c.VkImage,
        view: c.VkImageView,
        output: Device.Output,
        has_alpha: bool,
        wait: c.VkSemaphore,
        signal: c.VkSemaphore,
    },
};

// GPU records, matching common.glsl -------------------------------------------

const Inst = extern struct {
    quad: [4]i32,
    cov: u32 = cov_full,
    paint: u32 = paint_solid,
    clip: u32 = 0,
    aux: u32 = 0,
    color: [4]f32 = .{ 0, 0, 0, 0 },
    g0: [4]f32 = .{ 0, 0, 0, 0 },
    g1: [4]f32 = .{ 0, 0, 0, 0 },
    g2: [4]f32 = .{ 0, 0, 0, 0 },
    tex: [4]i32 = .{ 0, 0, 0, 0 },
    ptex: [4]i32 = .{ 0, 0, 0, 0 },
    btex: [4]i32 = .{ 0, 0, 0, 0 },
    /// Part of `quad` not drawn (x0 >= x1: none): covered by a later
    /// opaque draw (`occlude`).
    hole: [4]i32 = .{ 0, 0, 0, 0 },
};

const PaintRec = extern struct {
    inv0: [4]f32,
    inv1: [4]f32,
    geo0: [4]f32 = .{ 0, 0, 0, 0 },
    geo1: [4]f32 = .{ 0, 0, 0, 0 },
    meta: [4]u32 = .{ 0, 0, 0, 0 },
    range: [4]i32 = .{ 0, 0, 0, 0 },
};

const Stop = extern struct {
    color: [4]f32,
    offset: [4]f32,
};

const ClipRec = extern struct {
    kind: u32,
    parent: u32,
    pad: [2]u32 = .{ 0, 0 },
    g0: [4]f32 = .{ 0, 0, 0, 0 },
    g1: [4]f32 = .{ 0, 0, 0, 0 },
    g2: [4]f32 = .{ 0, 0, 0, 0 },
    tex: [4]i32 = .{ 0, 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(Inst) == 160);
    std.debug.assert(@sizeOf(PaintRec) == 96);
    std.debug.assert(@sizeOf(ClipRec) == 80);
    std.debug.assert(@sizeOf(Device.Push) == 80);
}

const cov_full = 0;
const cov_rect = 1;
const cov_rrect = 2;
const cov_mask = 3;
const cov_glyph = 4;
const cov_shadow = 5;

const paint_solid = 0;
const paint_linear = 1;
const paint_radial = 2;
const paint_sweep = 3;
const paint_image = 4;
const paint_texel = 5;
const paint_blend = 6;
const paint_blur = 7;
const paint_glyph = 8;

const max_layer_depth = 64;

// CPU-side frame state ---------------------------------------------------------

const Op = union(enum) {
    /// Consecutive instances, drawn with the blending pipeline, with the
    /// image (texture key) their image paints sample.
    draws: struct { first: u32, count: u32, image: ?u64 = null },
    push: u32,
    pop: u32,
    blur: u32,
};

const LayerInfo = struct {
    bbox: IRect,
    /// Where its content draws and where it composites.
    scissor: IRect,
    /// Its image: the scissor plus the backdrop reach of blurs inside it.
    image: IRect,
    blend: scene.BlendMode,
    opacity: f32,
    /// Its clip chain, for unbounded blend modes.
    clip: u32,
    /// Index of the matching pop op.
    end: u32 = 0,
    depth: u32,
};

const BlurInfo = struct {
    bbox: IRect,
    scissor: IRect,
    radius: i32,
    boxes: ?[3]u32,
    /// Exact kernel: offset in `kernels` and radius.
    kernel: u32 = 0,
    kernel_radius: u32 = 0,
    /// The mixing instance (coverage and clip; textures set when recorded).
    inst: Inst,
};

const PathJob = struct {
    shape: scene.Shape,
    m: Affine,
    stroke: ?raster.StrokeStyle,
    rule: FillRule,
    /// Device pixels where coverage may be read.
    bounds: IRect,
    target: union(enum) { inst: u32, clip: u32 },
    /// For transformed glyph runs: the outline in `outline_paths`, which
    /// becomes `shape` once prepare is done.
    outline: ?u32 = null,
    /// Planned: the rasterized region, its page and position, and its
    /// offset in the frame's staging data.
    region: IRect = .empty,
    page: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    offset: usize = 0,
};

const State = struct {
    m: Affine,
    clip: Rect,
    scissor: IRect,
    chain: u32,
    /// Innermost isolated layer, or none.
    layer: ?u32,
    depth: u32,
};

const Upload = struct {
    image: *Image,
    layer: u32 = 0,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    offset: usize,
};

/// A shelf packer over a square-ish page.
const Shelves = struct {
    width: u32,
    height: u32,
    x: u32 = 0,
    y: u32 = 0,
    row: u32 = 0,

    fn place(s: *Shelves, w: u32, h: u32) ?[2]u32 {
        if (w > s.width or h > s.height) return null;
        if (s.x + w > s.width) {
            s.y += s.row;
            s.x = 0;
            s.row = 0;
        }
        if (s.y + h > s.height) return null;
        const at: [2]u32 = .{ s.x, s.y };
        s.x += w;
        s.row = @max(s.row, h);
        return at;
    }

    fn reset(s: *Shelves) void {
        s.* = .{ .width = s.width, .height = s.height };
    }
};

/// A glyph atlas: an image and the packer that fills it.
const Atlas = struct {
    image: Image = .{},
    shelves: Shelves,
    format: c.VkFormat,
    bytes_per_pixel: u32,
};

const AtlasPos = struct { x: i32 = -1, y: i32 = -1 };

const Texture = struct {
    image: Image,
    last_frame: u64,
    format: u32,
};

const Worker = struct {
    raster: raster.Rasterizer,
    path: raster.PathBuilder,
    outline: raster.PathBuilder,
    stroker: raster.Stroker,
    failed: bool = false,

    fn deinit(w: *Worker) void {
        w.raster.deinit();
        w.path.deinit();
        w.outline.deinit();
        w.stroker.deinit();
    }
};

const Frame = struct {
    pool: c.VkCommandPool = null,
    cmd: c.VkCommandBuffer = null,
    fence: c.VkFence = null,
    descriptor_pool: c.VkDescriptorPool = null,
    set: c.VkDescriptorSet = null,
    /// Texture sets (set 1), allocated while recording.
    texture_pool: c.VkDescriptorPool = null,
    texture_sets: u32 = 0,
    data: Buffer = .{},
    readback: Buffer = .{},
    /// Path mask pages, as layers.
    masks: Image = .{},
    /// Images to destroy once this frame's work is done.
    garbage: std.ArrayList(Image) = .empty,
};

gpa: Allocator,
device: *Device,
executor: Executor,
glyphs: glyph.Cache,
workers: []Worker,

width: u32 = 0,
height: u32 = 0,
working: Image = .{},
/// The working image's contents are undefined: redraw everything.
stale: bool = true,
readback_image: Image = .{},
frames: [frames_in_flight]Frame = @splat(.{}),
frame: u64 = 0,

layer_images: [max_layer_depth]Image = @splat(.{}),
backdrop: Image = .{},
blur_images: [2]Image = .{ .{}, .{} },
glyph_masks: Atlas,
glyph_colors: Atlas,
glyph_pos: std.ArrayList(AtlasPos) = .empty,
textures: std.AutoHashMapUnmanaged(u64, Texture) = .empty,
/// Bytes of all textures.
texture_bytes: u64 = 0,
/// Copies dma-bufs into textures.
importer: dmabuf.Importer = .{},
/// A dma-buf was skipped (logged once).
dmabuf_skipped: bool = false,
/// Bound where a texture binding is unused.
dummy: Image = .{},

// Per-frame storage, retained.
insts: std.ArrayList(Inst) = .empty,
paints: std.ArrayList(PaintRec) = .empty,
stops: std.ArrayList(Stop) = .empty,
clips: std.ArrayList(ClipRec) = .empty,
kernels: std.ArrayList(f32) = .empty,
ops: std.ArrayList(Op) = .empty,
layers: std.ArrayList(LayerInfo) = .empty,
blurs: std.ArrayList(BlurInfo) = .empty,
paths: std.ArrayList(PathJob) = .empty,
placements: std.ArrayList(glyph.Placement) = .empty,
outline_paths: std.ArrayList(raster.PathBuilder) = .empty,
outlines_used: usize = 0,
stack: std.ArrayList(State) = .empty,
regions: std.ArrayList(IRect) = .empty,
changed: std.ArrayList(IRect) = .empty,
/// For `occlude`: each instance's target, and the opaque instances.
inst_targets: std.ArrayList(u32) = .empty,
occluders: std.ArrayList(struct { index: u32, box: IRect }) = .empty,
uploads: std.ArrayList(Upload) = .empty,
glyph_uploads: std.ArrayList(u32) = .empty,
image_uploads: std.ArrayList(scene.ImageRef) = .empty,
/// Mask pages this frame and their size.
pages: u32 = 0,
page_size: [2]u32 = .{ 0, 0 },
image_ops: u32 = 0,
/// Set when an atlas ran out of room during prepare.
atlas_full: bool = false,
dynamic_insts: u32 = 0,
inst_capacity: u32 = 0,
inst_next: u32 = 0,
inst_base: ?[*]Inst = null,

pub fn create(gpa: Allocator, device: *Device, executor: Executor) Error!*Renderer {
    const r = try gpa.create(Renderer);
    errdefer gpa.destroy(r);
    const workers = try gpa.alloc(Worker, @max(1, executor.workers));
    errdefer gpa.free(workers);
    for (workers) |*w| w.* = .{ .raster = .init(gpa), .path = .init(gpa), .outline = .init(gpa), .stroker = .init(gpa) };
    r.* = .{
        .gpa = gpa,
        .device = device,
        .executor = executor,
        .glyphs = .init(gpa),
        .workers = workers,
        .glyph_masks = .{ .shelves = .{ .width = 2048, .height = 2048 }, .format = c.VK_FORMAT_R8_UNORM, .bytes_per_pixel = 1 },
        .glyph_colors = .{ .shelves = .{ .width = 1024, .height = 1024 }, .format = c.VK_FORMAT_R16G16B16A16_UNORM, .bytes_per_pixel = 8 },
    };
    errdefer r.destroy();
    const d = device;
    for (&r.frames) |*f| {
        const pool_info: c.VkCommandPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
            .queueFamilyIndex = d.queue_family,
        };
        try vk.call(d.vkd.vkCreateCommandPool, .{ d.device, &pool_info, null, &f.pool });
        const alloc_info: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = f.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try vk.call(d.vkd.vkAllocateCommandBuffers, .{ d.device, &alloc_info, &f.cmd });
        const fence_info: c.VkFenceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = c.VK_FENCE_CREATE_SIGNALED_BIT };
        try vk.call(d.vkd.vkCreateFence, .{ d.device, &fence_info, null, &f.fence });
        const sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 6 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 3 },
        };
        const dp_info: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 1,
            .poolSizeCount = sizes.len,
            .pPoolSizes = &sizes,
        };
        try vk.call(d.vkd.vkCreateDescriptorPool, .{ d.device, &dp_info, null, &f.descriptor_pool });
        const set_info: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = f.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &d.set_layout,
        };
        try vk.call(d.vkd.vkAllocateDescriptorSets, .{ d.device, &set_info, &f.set });
    }
    r.dummy = try Image.init(d, 1, 1, Device.fp16, c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    return r;
}

pub fn destroy(r: *Renderer) void {
    const d = r.device;
    const gpa = r.gpa;
    if (d.device != null) _ = d.vkd.vkDeviceWaitIdle.?(d.device);
    for (&r.frames) |*f| {
        if (f.pool != null) d.vkd.vkDestroyCommandPool.?(d.device, f.pool, null);
        if (f.fence != null) d.vkd.vkDestroyFence.?(d.device, f.fence, null);
        if (f.descriptor_pool != null) d.vkd.vkDestroyDescriptorPool.?(d.device, f.descriptor_pool, null);
        if (f.texture_pool != null) d.vkd.vkDestroyDescriptorPool.?(d.device, f.texture_pool, null);
        f.data.deinit(d);
        f.readback.deinit(d);
        f.masks.deinit(d);
        for (f.garbage.items) |*m| m.deinit(d);
        f.garbage.deinit(gpa);
    }
    r.working.deinit(d);
    r.readback_image.deinit(d);
    r.dummy.deinit(d);
    for (&r.layer_images) |*img| img.deinit(d);
    r.backdrop.deinit(d);
    for (&r.blur_images) |*img| img.deinit(d);
    r.glyph_masks.image.deinit(d);
    r.glyph_colors.image.deinit(d);
    var it = r.textures.valueIterator();
    while (it.next()) |t| t.image.deinit(d);
    r.importer.deinit(d);
    r.textures.deinit(gpa);
    r.glyph_pos.deinit(gpa);
    r.glyphs.deinit();
    for (r.workers) |*w| w.deinit();
    gpa.free(r.workers);
    for (r.outline_paths.items) |*p| p.deinit();
    r.outline_paths.deinit(gpa);
    inline for (.{ "insts", "paints", "stops", "clips", "kernels", "ops", "layers", "blurs", "paths", "placements", "stack", "regions", "changed", "uploads", "glyph_uploads", "image_uploads", "inst_targets", "occluders" }) |name| {
        @field(r, name).deinit(gpa);
    }
    gpa.destroy(r);
}

/// Sets the viewport size; the next frame redraws everything.
pub fn resize(r: *Renderer, width: u32, height: u32) Error!void {
    if (width == r.width and height == r.height) return;
    const d = r.device;
    try r.idle();
    r.working.deinit(d);
    r.readback_image.deinit(d);
    r.width = width;
    r.height = height;
    r.stale = true;
    if (width == 0 or height == 0) return;
    r.working = try Image.init(d, width, height, Device.fp16, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
}

/// Drops cached glyphs of a font that is going away.
pub fn evictFont(r: *Renderer, key: u64) void {
    r.glyphs.evictFont(key);
}

pub fn viewport(r: *const Renderer) IRect {
    return .xywh(0, 0, @intCast(r.width), @intCast(r.height));
}

/// Drops everything whose contents or layout recording may have left
/// unknown: the working image, glyph atlases, and textures.
fn forget(r: *Renderer) void {
    r.stale = true;
    r.working.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    r.glyph_masks.image.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    r.glyph_colors.image.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    r.glyphs.clear();
    r.resetAtlases();
    const f = &r.frames[r.frame % frames_in_flight];
    var it = r.textures.valueIterator();
    while (it.next()) |t| f.garbage.append(r.gpa, t.image) catch {
        var img = t.image;
        r.idle() catch {};
        img.deinit(r.device);
    };
    r.textures.clearRetainingCapacity();
    r.texture_bytes = 0;
}

/// Waits for all submitted frames.
pub fn idle(r: *Renderer) Error!void {
    const d = r.device;
    var fences: [frames_in_flight]c.VkFence = undefined;
    for (r.frames, 0..) |f, i| fences[i] = f.fence;
    vk.check(d.vkd.vkWaitForFences.?(d.device, frames_in_flight, &fences, c.VK_TRUE, std.math.maxInt(u64))) catch |e| return d.note(e);
}

/// Waits until the next frame's resources are free. Call before acquiring
/// a swapchain image for `render`.
pub fn beginFrame(r: *Renderer) Error!void {
    const d = r.device;
    const f = &r.frames[r.frame % frames_in_flight];
    vk.check(d.vkd.vkWaitForFences.?(d.device, 1, &f.fence, c.VK_TRUE, std.math.maxInt(u64))) catch |e| return d.note(e);
    for (f.garbage.items) |*img| img.deinit(d);
    f.garbage.clearRetainingCapacity();
}

/// Renders `list` and encodes it into `target`. Call `beginFrame` first.
pub fn render(r: *Renderer, list: scene.DisplayList, opts: Options, target: Target) Error!void {
    if (r.width == 0 or r.height == 0) return;
    const d = r.device;
    if (d.lost) return error.DeviceLost;
    const f = &r.frames[r.frame % frames_in_flight];

    try r.prepareWithAtlas(list, opts.root);
    try r.occlude();
    try r.planRegions(if (r.stale) null else opts.damage);
    try r.planPaths();
    try r.planPools();

    // Lay out the frame's data: storage ranges, then uploads.
    const align_ssbo: usize = @max(16, d.limits.minStorageBufferOffsetAlignment);
    var layout: DataLayout = .{};
    var at: usize = 0;
    inline for (.{ .{ "insts", Inst }, .{ "paints", PaintRec }, .{ "stops", Stop }, .{ "clips", ClipRec }, .{ "kernels", f32 } }, 0..) |entry, i| {
        const count = if (i == 0) r.insts.items.len + r.dynamic_insts else @field(r, entry[0]).items.len;
        at = std.mem.alignForward(usize, at, align_ssbo);
        layout.ranges[i] = .{ at, @max(@sizeOf(entry[1]) * count, 16) };
        at += layout.ranges[i][1];
    }
    at = std.mem.alignForward(usize, at, 16);
    const uploads_start = at;
    at = try r.planUploads(at);
    try f.data.reserve(d, at, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    const base = f.data.mapped.?;

    inline for (.{ "insts", "paints", "stops", "clips", "kernels" }, 0..) |name, i| {
        const items = @field(r, name).items;
        @memcpy(base[layout.ranges[i][0]..][0 .. items.len * @sizeOf(@TypeOf(items[0]))], std.mem.sliceAsBytes(items));
    }
    r.inst_base = @ptrCast(@alignCast(base + layout.ranges[0][0]));
    r.inst_capacity = @intCast(r.insts.items.len + r.dynamic_insts);
    r.inst_next = @intCast(r.insts.items.len);
    try r.rasterizePaths(base);
    r.copyUploads(base, uploads_start);

    try r.ensureMaskPages(f);
    if (target == .readback) {
        if (r.readback_image.handle == null) r.readback_image = try Image.init(d, r.width, r.height, c.VK_FORMAT_R8G8B8A8_UNORM, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        try f.readback.reserve(d, @as(usize, r.width) * r.height * 4, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    }
    r.writeDescriptors(f, layout);
    r.record(f, opts, target) catch |e| {
        // Image layouts tracked during recording no longer match the
        // device: start over from undefined contents.
        r.forget();
        return d.note(e);
    };

    const cmd_info: c.VkCommandBufferSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = f.cmd };
    var wait: c.VkSemaphoreSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT };
    var signal: c.VkSemaphoreSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT };
    var submit: c.VkSubmitInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmd_info,
    };
    if (target == .swapchain) {
        wait.semaphore = target.swapchain.wait;
        signal.semaphore = target.swapchain.signal;
        submit.waitSemaphoreInfoCount = 1;
        submit.pWaitSemaphoreInfos = &wait;
        submit.signalSemaphoreInfoCount = 1;
        submit.pSignalSemaphoreInfos = &signal;
    }
    vk.check(d.vkd.vkResetFences.?(d.device, 1, &f.fence)) catch |e| return d.note(e);
    vk.check(d.vkd.vkQueueSubmit2.?(d.queue, 1, &submit, f.fence)) catch |e| return d.note(e);
    r.frame += 1;
    r.stale = false;

    if (target == .readback) {
        vk.check(d.vkd.vkWaitForFences.?(d.device, 1, &f.fence, c.VK_TRUE, std.math.maxInt(u64))) catch |e| return d.note(e);
        const rb = target.readback;
        const row = @as(usize, r.width) * 4;
        for (0..r.height) |y| @memcpy(rb.pixels[y * rb.stride ..][0..row], f.readback.mapped.?[y * row ..][0..row]);
    }
}

const DataLayout = struct {
    /// Offset and size of each storage binding (insts, paints, stops, clips,
    /// kernels).
    ranges: [5][2]usize = undefined,
};

// Prepare -----------------------------------------------------------------------

/// Prepares, and when an atlas fills up, starts the atlases over and
/// prepares again (growing them if one frame's glyphs do not fit).
fn prepareWithAtlas(r: *Renderer, list: scene.DisplayList, root: Affine) Error!void {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        r.atlas_full = false;
        try r.prepare(list, root);
        if (!r.atlas_full) return;
        if (attempt >= 4) {
            log.warn("glyph atlas too small for one frame; glyphs dropped", .{});
            return;
        }
        try r.idle();
        if (attempt >= 1) {
            const max = r.device.limits.maxImageDimension2D;
            for ([_]*Atlas{ &r.glyph_masks, &r.glyph_colors }) |a| {
                a.shelves.width = @min(a.shelves.width * 2, max);
                a.shelves.height = @min(a.shelves.height * 2, max);
                a.image.deinit(r.device);
            }
        }
        r.glyphs.clear();
        r.resetAtlases();
    }
}

fn resetAtlases(r: *Renderer) void {
    r.glyph_masks.shelves.reset();
    r.glyph_colors.shelves.reset();
    r.glyph_pos.clearRetainingCapacity();
}

fn prepare(r: *Renderer, list: scene.DisplayList, root: Affine) Error!void {
    const gpa = r.gpa;
    r.insts.clearRetainingCapacity();
    r.paints.clearRetainingCapacity();
    r.stops.clearRetainingCapacity();
    r.clips.clearRetainingCapacity();
    r.kernels.clearRetainingCapacity();
    r.ops.clearRetainingCapacity();
    r.layers.clearRetainingCapacity();
    r.blurs.clearRetainingCapacity();
    r.paths.clearRetainingCapacity();
    r.placements.clearRetainingCapacity();
    r.stack.clearRetainingCapacity();
    r.glyph_uploads.clearRetainingCapacity();
    r.image_uploads.clearRetainingCapacity();
    r.outlines_used = 0;
    r.glyphs.beginFrame();
    // The cache dropped its entries (budget): atlas positions are stale.
    if (r.glyphs.entries.items.len < r.glyph_pos.items.len) r.resetAtlases();

    const vp = r.viewport();
    try r.stack.append(gpa, .{ .m = root, .clip = vp.toRect(), .scissor = vp, .chain = 0, .layer = null, .depth = 0 });
    var i: usize = 0;
    const cmds = list.commands;
    // A layer that composites as its one draw (scene.foldedOpacity) is
    // pushed without isolation, and that draw replaces the next command.
    var folded: ?scene.Command = null;
    while (i < cmds.len) : (i += 1) {
        const top = r.stack.items[r.stack.items.len - 1];
        const m = top.m;
        const cmd = if (folded) |f| f else cmds[i];
        folded = null;
        switch (cmd) {
            .push => |p| {
                var l = p.layer;
                const lm = l.transform.then(m);
                const invisible = l.opacity <= 0 and !l.blend.isUnbounded();
                const unbounded = std.math.isInf(p.bounds.x0) or std.math.isInf(p.bounds.x1);
                const bf = if (unbounded) top.clip else lm.applyRect(p.bounds).intersect(top.clip);
                const bbox = bf.roundOut().intersect(vp);
                var scissor = top.scissor.intersect(bbox);
                if (invisible or bbox.isEmpty() or lm.invert() == null) {
                    i = p.end;
                    continue;
                }
                var clip_bounds = top.clip;
                var chain = top.chain;
                if (l.clip) |cl| {
                    const cb = lm.applyRect(cl.shape.bounds());
                    clip_bounds = clip_bounds.intersect(cb);
                    const clip_scissor = cb.roundOut().intersect(vp);
                    scissor = scissor.intersect(clip_scissor);
                    chain = try r.addClip(cl.shape, cl.rule, lm, top.chain, clip_scissor.intersect(scissor));
                }
                if (scissor.isEmpty()) {
                    i = p.end;
                    continue;
                }
                var state: State = .{ .m = lm, .clip = clip_bounds, .scissor = scissor, .chain = chain, .layer = top.layer, .depth = top.depth };
                if (scene.foldedOpacity(cmds, i)) |f| {
                    folded = f;
                    l.opacity = 1;
                }
                if (l.isIsolated()) {
                    if (top.depth >= max_layer_depth) {
                        log.warn("isolated layers nested deeper than {d}; skipped", .{max_layer_depth});
                        i = p.end;
                        continue;
                    }
                    try r.layers.append(gpa, .{
                        .bbox = bbox,
                        .scissor = scissor,
                        .image = scissor,
                        .blend = l.blend,
                        .opacity = l.opacity,
                        .clip = chain,
                        .depth = top.depth,
                    });
                    const index: u32 = @intCast(r.layers.items.len - 1);
                    try r.ops.append(gpa, .{ .push = index });
                    state.layer = index;
                    state.depth = top.depth + 1;
                }
                try r.stack.append(gpa, state);
            },
            .pop => {
                const st = r.stack.pop().?;
                // The layer was isolated if it opened a depth.
                if (st.depth > r.stack.items[r.stack.items.len - 1].depth) {
                    const index = st.layer.?;
                    try r.ops.append(gpa, .{ .pop = index });
                    r.layers.items[index].end = @intCast(r.ops.items.len - 1);
                }
            },
            .fill => |fl| {
                if (fl.paint.isInvisible()) continue;
                const bbox = m.applyRect(fl.shape.bounds()).intersect(top.clip).roundOut().intersect(vp);
                const quad = bbox.intersect(top.scissor);
                if (quad.isEmpty()) continue;
                var inst = try r.paintInst(fl.paint, m, quad, top.chain);
                try r.coverage(&inst, fl.shape, fl.rule, m, null);
                try r.pushInst(inst);
            },
            .stroke => |s| {
                if (s.paint.isInvisible()) continue;
                const bbox = m.applyRect(s.shape.bounds().outset(s.style.outset())).intersect(top.clip).roundOut().intersect(vp);
                const quad = bbox.intersect(top.scissor);
                if (quad.isEmpty()) continue;
                // A rectangle's or rounded rectangle's stroke (a view's
                // border) is drawn as the bands around its empty inside,
                // each rasterized on its own: one mask over the whole
                // bounds took half the CPU of a scrolling list's frames.
                const inside = strokeInterior(s.shape, s.style.width, m).intersect(quad);
                const pieces: [4]IRect = if (inside.isEmpty()) .{ quad, .empty, .empty, .empty } else .{
                    .{ .x0 = quad.x0, .y0 = quad.y0, .x1 = quad.x1, .y1 = inside.y0 },
                    .{ .x0 = quad.x0, .y0 = inside.y1, .x1 = quad.x1, .y1 = quad.y1 },
                    .{ .x0 = quad.x0, .y0 = inside.y0, .x1 = inside.x0, .y1 = inside.y1 },
                    .{ .x0 = inside.x1, .y0 = inside.y0, .x1 = quad.x1, .y1 = inside.y1 },
                };
                for (pieces) |piece| {
                    if (piece.isEmpty()) continue;
                    var inst = try r.paintInst(s.paint, m, piece, top.chain);
                    try r.coverage(&inst, s.shape, .nonzero, m, s.style);
                    try r.pushInst(inst);
                }
            },
            .glyphs => |g| try r.prepareGlyphs(g, top),
            .shadow => |sh| try r.prepareShadow(sh, top),
            .image => |img| try r.prepareImage(img, top),
            .backdrop_blur => |b| {
                const bbox = m.applyRect(b.shape.bounds()).intersect(top.clip).roundOut().intersect(vp);
                if (bbox.isEmpty()) continue;
                const sigma = @min(b.sigma * @sqrt(@abs(m.determinant())), scene.max_blur_sigma);
                if (!(sigma > 0)) continue;
                const boxes = render_cpu.boxRadii(sigma);
                var info: BlurInfo = .{
                    .bbox = bbox,
                    .scissor = top.scissor,
                    .radius = if (boxes) |bx| @intCast(bx[0] + bx[1] + bx[2]) else @intFromFloat(@ceil(3 * sigma)),
                    .boxes = if (boxes) |bx| .{ @intCast(bx[0]), @intCast(bx[1]), @intCast(bx[2]) } else null,
                    .inst = .{ .quad = irect(bbox.intersect(top.scissor)), .paint = paint_blur, .clip = top.chain },
                };
                if (boxes == null) {
                    // The CPU renderer's normalized kernel.
                    const kr: u32 = @intCast(info.radius);
                    info.kernel = @intCast(r.kernels.items.len);
                    info.kernel_radius = kr;
                    const start = r.kernels.items.len;
                    var sum: f32 = 0;
                    for (0..2 * kr + 1) |k| {
                        const x = @as(f32, @floatFromInt(k)) - @as(f32, @floatFromInt(kr));
                        const w = @exp(-x * x / (2 * sigma * sigma));
                        try r.kernels.append(gpa, w);
                        sum += w;
                    }
                    for (r.kernels.items[start..]) |*w| w.* /= sum;
                }
                try r.blurs.append(gpa, info);
                const index: u32 = @intCast(r.blurs.items.len - 1);
                try r.blurCoverage(index, b.shape, m);
                try r.ops.append(gpa, .{ .blur = index });
                // The innermost isolated layer must hold the backdrop.
                if (top.layer) |li| {
                    const layer = &r.layers.items[li];
                    layer.image = layer.image.unite(bbox.intersect(top.scissor).outset(info.radius).intersect(vp));
                }
            },
        }
    }
    // Outline paths are final now; point their jobs at them.
    for (r.paths.items) |*job| {
        if (job.outline) |o| job.shape = .{ .path = r.outline_paths.items[o].path() };
    }
}

/// Appends an instance, batching it with the previous ones unless it
/// samples a different image.
fn pushInst(r: *Renderer, inst: Inst) Error!void {
    return r.pushInstImage(inst, null);
}

fn pushInstImage(r: *Renderer, inst: Inst, image: ?u64) Error!void {
    try r.insts.append(r.gpa, inst);
    const index: u32 = @intCast(r.insts.items.len - 1);
    if (r.ops.items.len > 0) {
        const last = &r.ops.items[r.ops.items.len - 1];
        if (last.* == .draws and last.draws.first + last.draws.count == index) {
            const batch = &last.draws;
            if (image == null or batch.image == null or batch.image.? == image.?) {
                batch.count += 1;
                if (image != null) batch.image = image;
                return;
            }
        }
    }
    try r.ops.append(r.gpa, .{ .draws = .{ .first = index, .count = 1, .image = image } });
}

fn toU16f(v: f32) f32 {
    return @floor(std.math.clamp(v, 0, 1) * 65535 + 0.5) / 65535;
}

/// Premultiplied, quantized like the CPU renderer's paint.solid.
fn solid(cl: scene.Color) [4]f32 {
    const a = std.math.clamp(cl.a, 0, 1);
    return .{ toU16f(cl.r * a), toU16f(cl.g * a), toU16f(cl.b * a), toU16f(a) };
}

/// An instance with `paint` (solid or gradient) over `quad`.
fn paintInst(r: *Renderer, paint: scene.Paint, m: Affine, quad: IRect, chain: u32) Error!Inst {
    var inst: Inst = .{ .quad = irect(quad), .clip = chain };
    switch (paint) {
        .solid => |cl| inst.color = solid(cl),
        .gradient => |g| {
            const inv = g.transform.then(m).invert() orelse {
                inst.color = .{ 0, 0, 0, 0 };
                return inst;
            };
            const first: u32 = @intCast(r.stops.items.len);
            for (g.stops) |s| {
                const a = std.math.clamp(s.color.a, 0, 1);
                try r.stops.append(r.gpa, .{ .color = .{ s.color.r * a, s.color.g * a, s.color.b * a, a }, .offset = .{ s.offset, 0, 0, 0 } });
            }
            var rec: PaintRec = .{
                .inv0 = .{ inv.a, inv.b, inv.c, inv.d },
                .inv1 = .{ inv.e, inv.f, 0, 0 },
                .meta = .{ first, @intCast(g.stops.len), @backingInt(g.extend), 0 },
            };
            switch (g.geometry) {
                .linear => |l| {
                    inst.paint = paint_linear;
                    rec.geo0 = .{ l.p0.x, l.p0.y, l.p1.x, l.p1.y };
                },
                .radial => |rd| {
                    inst.paint = paint_radial;
                    rec.geo0 = .{ rd.c0.x, rd.c0.y, rd.r0, rd.c1.x };
                    rec.geo1 = .{ rd.c1.y, rd.r1, 0, 0 };
                },
                .sweep => |s| {
                    inst.paint = paint_sweep;
                    rec.geo0 = .{ s.center.x, s.center.y, s.start_angle, s.end_angle };
                },
            }
            try r.paints.append(r.gpa, rec);
            inst.aux = @intCast(r.paints.items.len - 1);
        },
    }
    return inst;
}

fn irect(rc: IRect) [4]i32 {
    return .{ rc.x0, rc.y0, rc.x1, rc.y1 };
}

const Analytic = union(enum) {
    rect: Rect,
    rounded_rect: struct { rect: Rect, radii: Radii },
};

/// Device-space analytic coverage for a shape drawn through `m`, as the CPU
/// renderer's coverageFor decides it; null when it is a path.
fn analytic(shape: scene.Shape, m: Affine) ?Analytic {
    if (!m.isAxisAligned()) return null;
    switch (shape) {
        .rect => |rc| return .{ .rect = m.applyRect(rc) },
        .rounded_rect => |rr| {
            const ax = @abs(m.a);
            const ay = @abs(m.d);
            var radii: Radii = .{
                .tl = .{ .x = rr.radii.tl.x * ax, .y = rr.radii.tl.y * ay },
                .tr = .{ .x = rr.radii.tr.x * ax, .y = rr.radii.tr.y * ay },
                .br = .{ .x = rr.radii.br.x * ax, .y = rr.radii.br.y * ay },
                .bl = .{ .x = rr.radii.bl.x * ax, .y = rr.radii.bl.y * ay },
            };
            if (m.a < 0) radii = .{ .tl = radii.tr, .tr = radii.tl, .br = radii.bl, .bl = radii.br };
            if (m.d < 0) radii = .{ .tl = radii.bl, .tr = radii.br, .br = radii.tr, .bl = radii.tl };
            const dr = m.applyRect(rr.rect);
            return .{ .rounded_rect = .{ .rect = dr, .radii = radii.fit(dr) } };
        },
        .path => return null,
    }
}

fn setAnalytic(kind: *u32, g0: *[4]f32, g1: *[4]f32, g2: *[4]f32, a: Analytic) void {
    switch (a) {
        .rect => |rc| {
            kind.* = cov_rect;
            g0.* = .{ rc.x0, rc.y0, rc.x1, rc.y1 };
        },
        .rounded_rect => |rr| {
            kind.* = cov_rrect;
            g0.* = .{ rr.rect.x0, rr.rect.y0, rr.rect.x1, rr.rect.y1 };
            g1.* = .{ rr.radii.tl.x, rr.radii.tl.y, rr.radii.tr.x, rr.radii.tr.y };
            g2.* = .{ rr.radii.br.x, rr.radii.br.y, rr.radii.bl.x, rr.radii.bl.y };
        },
    }
}

/// Sets the instance's coverage: analytic, or a path job for the next
/// instance pushed.
fn coverage(r: *Renderer, inst: *Inst, shape: scene.Shape, rule: FillRule, m: Affine, stroke: ?raster.StrokeStyle) Error!void {
    if (stroke == null) if (analytic(shape, m)) |a| return setAnalytic(&inst.cov, &inst.g0, &inst.g1, &inst.g2, a);
    inst.cov = cov_mask;
    try r.paths.append(r.gpa, .{
        .shape = shape,
        .m = m,
        .stroke = stroke,
        .rule = rule,
        .bounds = quadRect(inst.quad),
        .target = .{ .inst = @intCast(r.insts.items.len) },
    });
}

fn quadRect(q: [4]i32) IRect {
    return .{ .x0 = q[0], .y0 = q[1], .x1 = q[2], .y1 = q[3] };
}

fn blurCoverage(r: *Renderer, index: u32, shape: scene.Shape, m: Affine) Error!void {
    const b = &r.blurs.items[index];
    if (analytic(shape, m)) |a| return setAnalytic(&b.inst.cov, &b.inst.g0, &b.inst.g1, &b.inst.g2, a);
    b.inst.cov = cov_mask;
    // Blur instances live outside `insts` until recorded; their mask job
    // targets the blur through a clip-less instance index past the end.
    try r.paths.append(r.gpa, .{
        .shape = shape,
        .m = m,
        .stroke = null,
        .rule = .nonzero,
        .bounds = quadRect(b.inst.quad),
        .target = .{ .inst = blur_target | index },
    });
}

const blur_target: u32 = 1 << 31;

/// Path coverage up to this many pixels a frame is rasterized on the
/// compositor thread rather than on the worker pool.
const inline_raster_pixels = 256 * 256 * 4;

fn addClip(r: *Renderer, shape: scene.Shape, rule: FillRule, m: Affine, parent: u32, scissor: IRect) Error!u32 {
    var rec: ClipRec = .{ .kind = cov_mask, .parent = parent };
    if (analytic(shape, m)) |a| {
        setAnalytic(&rec.kind, &rec.g0, &rec.g1, &rec.g2, a);
    } else {
        try r.paths.append(r.gpa, .{
            .shape = shape,
            .m = m,
            .stroke = null,
            .rule = rule,
            .bounds = scissor,
            .target = .{ .clip = @intCast(r.clips.items.len) },
        });
    }
    try r.clips.append(r.gpa, rec);
    return @intCast(r.clips.items.len);
}

fn prepareGlyphs(r: *Renderer, g: scene.GlyphRun, top: State) Error!void {
    if (g.paint.isInvisible() or g.glyphs.len == 0) return;
    const m = top.m;
    const vp = r.viewport();
    const bbox = m.applyRect(g.bounds).intersect(top.clip).roundOut().intersect(vp);
    const region = bbox.intersect(top.scissor);
    if (region.isEmpty()) return;
    const fg = switch (g.paint) {
        .solid => |cl| cl,
        .gradient => |gr| gr.stops[gr.stops.len / 2].color,
    };
    const start = r.placements.items.len;
    if (try r.glyphs.place(g, m, fg, &r.placements)) {
        const template = try r.paintInst(g.paint, m, region, top.chain);
        const contrast = glyph.ContrastLuts.index(fg);
        try r.glyph_pos.ensureTotalCapacity(r.gpa, r.glyphs.entries.items.len);
        while (r.glyph_pos.items.len < r.glyphs.entries.items.len) r.glyph_pos.appendAssumeCapacity(.{});
        for (r.placements.items[start..]) |pl| {
            const e = r.glyphs.entry(pl.entry);
            const gr = IRect.xywh(pl.x + e.left, pl.y + e.top, @intCast(e.width), @intCast(e.height));
            const quad = gr.intersect(region);
            if (quad.isEmpty()) continue;
            const pos = try r.atlasPos(pl.entry, e) orelse continue;
            var inst = template;
            inst.quad = irect(quad);
            switch (e.kind) {
                .mask => {
                    inst.cov = cov_glyph;
                    inst.tex = .{ 0, gr.x0 - pos.x, gr.y0 - pos.y, contrast };
                },
                .color => {
                    inst.cov = cov_full;
                    inst.paint = paint_glyph;
                    inst.ptex = .{ 0, gr.x0 - pos.x, gr.y0 - pos.y, 0 };
                },
                .redirect => unreachable,
            }
            try r.pushInst(inst);
        }
    } else {
        // Transformed or very large text: outlines as a path.
        if (r.outlines_used == r.outline_paths.items.len) try r.outline_paths.append(r.gpa, .init(r.gpa));
        const pb = &r.outline_paths.items[r.outlines_used];
        r.outlines_used += 1;
        pb.reset();
        try r.glyphs.outlines(g, pb);
        var inst = try r.paintInst(g.paint, m, region, top.chain);
        inst.cov = cov_mask;
        try r.paths.append(r.gpa, .{
            .shape = .{ .path = .empty },
            .outline = @intCast(r.outlines_used - 1),
            .m = m,
            .stroke = null,
            .rule = .nonzero,
            .bounds = region,
            .target = .{ .inst = @intCast(r.insts.items.len) },
        });
        try r.pushInst(inst);
    }
}

/// The glyph entry's position in its atlas, uploading it on first use.
/// Null (and `atlas_full` set) when the atlas has no room.
fn atlasPos(r: *Renderer, index: u32, e: glyph.Entry) Error!?AtlasPos {
    const pos = &r.glyph_pos.items[index];
    if (pos.x >= 0) return pos.*;
    const a = if (e.kind == .mask) &r.glyph_masks else &r.glyph_colors;
    const at = a.shelves.place(e.width, e.height) orelse {
        r.atlas_full = true;
        return null;
    };
    pos.* = .{ .x = @intCast(at[0]), .y = @intCast(at[1]) };
    try r.glyph_uploads.append(r.gpa, index);
    return pos.*;
}

fn prepareShadow(r: *Renderer, sh: scene.Shadow, top: State) Error!void {
    if (sh.color.a <= 0) return;
    const bbox = top.m.applyRect(sh.bounds()).intersect(top.clip).roundOut().intersect(r.viewport());
    const quad = bbox.intersect(top.scissor);
    if (quad.isEmpty()) return;
    const p = render_cpu.shadow.prepare(sh, top.m) orelse return;
    const empty = p.shape.isEmpty();
    const shape: Rect = if (empty) .xywh(0, 0, 0, 0) else p.shape;
    const cr = p.cast_radii;
    const sr = p.radii;
    try r.paints.appendSlice(r.gpa, &.{
        .{
            .inv0 = .{ p.inv.a, p.inv.b, p.inv.c, p.inv.d },
            .inv1 = .{ p.inv.e, p.inv.f, p.scale, p.sigma },
            .geo0 = .{ p.cast.x0, p.cast.y0, p.cast.x1, p.cast.y1 },
            .geo1 = .{ shape.x0, shape.y0, shape.x1, shape.y1 },
            .meta = .{ @intFromBool(p.inset), @intFromBool(empty), 0, 0 },
        },
        .{
            .inv0 = .{ cr.tl.x, cr.tl.y, cr.tr.x, cr.tr.y },
            .inv1 = .{ cr.br.x, cr.br.y, cr.bl.x, cr.bl.y },
            .geo0 = .{ sr.tl.x, sr.tl.y, sr.tr.x, sr.tr.y },
            .geo1 = .{ sr.br.x, sr.br.y, sr.bl.x, sr.bl.y },
        },
    });
    try r.pushInst(.{
        .quad = irect(quad),
        .cov = cov_shadow,
        .aux = @intCast(r.paints.items.len - 2),
        .clip = top.chain,
        .color = solid(sh.color),
    });
}

fn prepareImage(r: *Renderer, img: scene.Image, top: State) Error!void {
    if (img.opacity <= 0) return;
    const m = top.m;
    const bbox = m.applyRect(img.dst).intersect(top.clip).roundOut().intersect(r.viewport());
    const quad = bbox.intersect(top.scissor);
    if (quad.isEmpty() or img.src.isEmpty() or img.dst.isEmpty()) return;
    const inv = m.invert() orelse return;
    const sx = img.src.width() / img.dst.width();
    const sy = img.src.height() / img.dst.height();
    const to_img: Affine = .{ .a = sx, .d = sy, .e = img.src.x0 - img.dst.x0 * sx, .f = img.src.y0 - img.dst.y0 * sy };
    const ref = img.image;
    const sr = img.src.roundOut().intersect(.xywh(0, 0, @intCast(ref.width), @intCast(ref.height)));
    if (sr.isEmpty()) return;
    const tex = try r.texture(ref) orelse return;
    const t = inv.then(to_img);
    try r.paints.append(r.gpa, .{
        .inv0 = .{ t.a, t.b, t.c, t.d },
        .inv1 = .{ t.e, t.f, 0, 0 },
        .meta = .{ tex.format, @backingInt(img.filter), @intFromFloat(std.math.clamp(img.opacity, 0, 1) * 65535 + 0.5), 0 },
        .range = .{ sr.x0, sr.y0, sr.x1, sr.y1 },
    });
    var inst: Inst = .{ .quad = irect(quad), .clip = top.chain, .paint = paint_image, .aux = @intCast(r.paints.items.len - 1) };
    try r.coverage(&inst, .{ .rect = img.dst }, .nonzero, m, null);
    try r.pushInstImage(inst, ref.key);
}

/// The cached texture for an image, uploading it if new. A dma-buf is
/// imported and copied when the device can; otherwise its pixels are
/// uploaded, and without pixels it is not drawn (D17).
fn texture(r: *Renderer, ref: scene.ImageRef) Error!?*Texture {
    const gop = try r.textures.getOrPut(r.gpa, ref.key);
    if (!gop.found_existing) {
        if (ref.pixels == null and (ref.dmabuf == null or !r.device.dmabuf_import)) {
            r.textures.removeByPtr(gop.key_ptr);
            r.skipDmabuf(error.Unsupported);
            return null;
        }
        const format: c.VkFormat = switch (ref.format) {
            .rgba8_srgb => c.VK_FORMAT_R8G8B8A8_UNORM,
            .bgra8_srgb, .bgrx8_srgb => c.VK_FORMAT_B8G8R8A8_UNORM,
            .rgba16_linear_premul => c.VK_FORMAT_R16G16B16A16_UNORM,
        };
        const image = Image.init(r.device, ref.width, ref.height, format, c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT) catch |e| {
            r.textures.removeByPtr(gop.key_ptr);
            return e;
        };
        gop.value_ptr.* = .{ .image = image, .last_frame = r.frame, .format = switch (ref.format) {
            .rgba8_srgb, .bgra8_srgb => 0,
            .rgba16_linear_premul => 1,
            .bgrx8_srgb => 2,
        } };
        r.texture_bytes += textureBytes(ref);
        const imported = if (ref.dmabuf) |buf| if (r.importer.copy(r.device, buf, ref.width, ref.height, &gop.value_ptr.image)) true else |err| switch (err) {
            error.Unsupported => false,
            else => |e| {
                r.dropTexture(gop.key_ptr, gop.value_ptr);
                return e;
            },
        } else false;
        if (!imported) {
            if (ref.pixels == null) {
                r.dropTexture(gop.key_ptr, gop.value_ptr);
                r.skipDmabuf(error.Unsupported);
                return null;
            }
            try r.image_uploads.append(r.gpa, ref);
        }
    } else if (gop.value_ptr.image.width != ref.width or gop.value_ptr.image.height != ref.height) {
        log.warn("image key {d} reused for different pixels", .{ref.key});
    }
    const t = gop.value_ptr;
    t.last_frame = r.frame;
    return t;
}

fn textureBytes(ref: scene.ImageRef) u64 {
    return @as(u64, ref.width) * ref.height * ref.format.bytesPerPixel();
}

/// Forgets a texture no frame has used yet.
fn dropTexture(r: *Renderer, key: *u64, t: *Texture) void {
    r.texture_bytes -= @as(u64, t.image.width) * t.image.height * (if (t.format == 1) @as(u64, 8) else 4);
    t.image.deinit(r.device);
    r.textures.removeByPtr(key);
}

fn skipDmabuf(r: *Renderer, err: anyerror) void {
    if (r.dmabuf_skipped) return;
    r.dmabuf_skipped = true;
    log.warn("a dma-buf frame is not drawn: {s} cannot import it ({t}) and it has no mappable pixels", .{ r.device.deviceName(), err });
}

// Regions ---------------------------------------------------------------------

/// Gives instances holes where a later opaque draw into the same target
/// covers them, so those pixels are not shaded twice: a window's
/// background under a view's, under its rows (D10). The hole is the
/// largest such area, if at least 16 by 16 pixels; an instance covered
/// whole draws nothing. Opaque means a solid paint of alpha 1 with
/// analytic coverage, inside the full-coverage part of its shape and of
/// every clip. Frames with a backdrop blur are left as they are: a blur
/// reads pixels around its own, which a hole could leave unpainted.
fn occlude(r: *Renderer) Error!void {
    if (r.blurs.items.len != 0 or r.insts.items.len < 2) return;
    const gpa = r.gpa;
    // Each instance's target: 0 for the working image, else its layer + 1.
    try r.inst_targets.resize(gpa, r.insts.items.len);
    var stack: [max_layer_depth + 1]u32 = undefined;
    var depth: usize = 0;
    stack[0] = 0;
    for (r.ops.items) |op| switch (op) {
        .draws => |dr| @memset(r.inst_targets.items[dr.first..][0..dr.count], stack[depth]),
        .push => |li| {
            depth += 1;
            stack[depth] = li + 1;
        },
        .pop => depth -= 1,
        .blur => {},
    };
    r.occluders.clearRetainingCapacity();
    for (r.insts.items, 0..) |inst, i| {
        const box = r.opaqueBox(inst) orelse continue;
        if (area(box) >= 32 * 32) try r.occluders.append(gpa, .{ .index = @intCast(i), .box = box });
    }
    if (r.occluders.items.len == 0) return;
    for (r.insts.items, r.inst_targets.items, 0..) |*inst, target, j| {
        const q = quadRect(inst.quad);
        if (q.isEmpty()) continue;
        var best = IRect.empty;
        var best_area: i64 = 16 * 16 - 1;
        for (r.occluders.items) |o| {
            if (o.index <= j or r.inst_targets.items[o.index] != target) continue;
            const x = q.intersect(o.box);
            const a = area(x);
            if (a > best_area) {
                best = x;
                best_area = a;
            }
        }
        if (best.isEmpty()) continue;
        if (best.contains(q)) inst.quad = .{ 0, 0, 0, 0 } else inst.hole = irect(best);
    }
}

/// The device pixels inside a rectangle's or rounded rectangle's stroke
/// that it leaves empty (a view's border), less a pixel for antialiasing;
/// empty for other shapes or transforms, or when small.
fn strokeInterior(shape: scene.Shape, width: f32, m: Affine) IRect {
    if (!m.isAxisAligned()) return .empty;
    const rect, const radius = switch (shape) {
        .rect => |rc| .{ rc, 0 },
        .rounded_rect => |rr| .{ rr.rect, @max(@max(rr.radii.tl.x, rr.radii.tl.y), @max(rr.radii.tr.x, rr.radii.tr.y), @max(rr.radii.br.x, rr.radii.br.y), @max(rr.radii.bl.x, rr.radii.bl.y)) },
        .path => return .empty,
    };
    const inner = rect.outset(-(width / 2 + radius));
    if (!(inner.x1 > inner.x0 and inner.y1 > inner.y0)) return .empty;
    const d = m.applyRect(inner);
    const b: IRect = .{ .x0 = @as(i32, @intFromFloat(@ceil(d.x0))) + 1, .y0 = @as(i32, @intFromFloat(@ceil(d.y0))) + 1, .x1 = @as(i32, @intFromFloat(@floor(d.x1))) - 1, .y1 = @as(i32, @intFromFloat(@floor(d.y1))) - 1 };
    return if (b.isEmpty() or area(b) < 16 * 16) .empty else b;
}

/// The device pixels an instance surely covers fully and opaquely, or
/// null when it is not opaque.
fn opaqueBox(r: *const Renderer, inst: Inst) ?IRect {
    if (inst.paint != paint_solid or inst.color[3] < 1) return null;
    var box = quadRect(inst.quad);
    switch (inst.cov) {
        cov_full => {},
        cov_rect, cov_rrect => box = box.intersect(analyticInterior(inst.cov, inst.g0, inst.g1, inst.g2)),
        else => return null,
    }
    var clip = inst.clip;
    while (clip != 0) {
        const rec = r.clips.items[clip - 1];
        switch (rec.kind) {
            cov_full => {},
            cov_rect, cov_rrect => box = box.intersect(analyticInterior(rec.kind, rec.g0, rec.g1, rec.g2)),
            else => return null,
        }
        clip = rec.parent;
    }
    return if (box.isEmpty()) null else box;
}

/// The whole pixels where analytic rectangle or rounded rectangle
/// coverage is full: inside the rectangle, and for rounded ones the
/// larger of its bands between the corners.
fn analyticInterior(kind: u32, g0: [4]f32, g1: [4]f32, g2: [4]f32) IRect {
    const inner = struct {
        fn of(x0: f32, y0: f32, x1: f32, y1: f32) IRect {
            if (!(x1 > x0 and y1 > y0)) return .empty;
            const b: IRect = .{ .x0 = @intFromFloat(@ceil(x0)), .y0 = @intFromFloat(@ceil(y0)), .x1 = @intFromFloat(@floor(x1)), .y1 = @intFromFloat(@floor(y1)) };
            return if (b.isEmpty()) .empty else b;
        }
    }.of;
    if (kind == cov_rect) return inner(g0[0], g0[1], g0[2], g0[3]);
    // Radii: g1 = top left (x, y), top right; g2 = bottom right, bottom left.
    const top = @max(g1[1], g1[3]);
    const bottom = @max(g2[1], g2[3]);
    const left = @max(g1[0], g2[2]);
    const right = @max(g1[2], g2[0]);
    const wide = inner(g0[0], g0[1] + top, g0[2], g0[3] - bottom);
    const tall = inner(g0[0] + left, g0[1], g0[2] - right, g0[3]);
    return if (area(wide) >= area(tall)) wide else tall;
}

fn planRegions(r: *Renderer, damage: ?[]const IRect) Error!void {
    const gpa = r.gpa;
    const vp = r.viewport();
    r.changed.clearRetainingCapacity();
    if (damage) |rects| {
        for (rects) |d| {
            const cd = d.intersect(vp);
            if (!cd.isEmpty()) try r.changed.append(gpa, cd);
        }
    } else try r.changed.append(gpa, vp);
    // A blur whose backdrop changed changes everywhere it is drawn.
    if (r.changed.items.len > 0) for (r.blurs.items) |b| {
        const reach = b.bbox.outset(b.radius);
        for (r.changed.items) |d| if (d.intersects(reach)) {
            try r.changed.append(gpa, b.bbox);
            break;
        };
    };
    r.regions.clearRetainingCapacity();
    if (r.changed.items.len == 0) return;
    // One region for the union unless the rectangles cover little of it.
    var bounds = IRect.empty;
    var total: i64 = 0;
    for (r.changed.items) |d| {
        bounds = if (bounds.isEmpty()) d else bounds.unite(d);
        total += area(d);
    }
    if (r.changed.items.len == 1 or total * 2 >= area(bounds)) {
        try r.regions.append(gpa, bounds);
    } else {
        try r.regions.appendSlice(gpa, r.changed.items);
    }
    // Grow each region until it holds the backdrop of every blur it meets.
    for (r.regions.items) |*reg| {
        var grown = true;
        while (grown) {
            grown = false;
            for (r.blurs.items) |b| {
                const need = b.bbox.intersect(b.scissor).intersect(reg.*);
                if (need.isEmpty()) continue;
                const src = need.outset(b.radius).intersect(vp);
                if (!reg.contains(src)) {
                    reg.* = reg.unite(src);
                    grown = true;
                }
            }
        }
    }
}

fn area(rc: IRect) i64 {
    if (rc.isEmpty()) return 0;
    return @as(i64, rc.width()) * rc.height();
}

fn regionBounds(r: *const Renderer) IRect {
    var b = IRect.empty;
    for (r.regions.items) |reg| b = if (b.isEmpty()) reg else b.unite(reg);
    return b;
}

// Paths -------------------------------------------------------------------------

/// Decides where each path's coverage is needed and packs the masks into
/// layers of one array image (all layers the size of the largest mask, at
/// least 2048 square).
fn planPaths(r: *Renderer) Error!void {
    const bounds = r.regionBounds();
    const limits = r.device.limits;
    var size: [2]u32 = .{ 2048, 2048 };
    for (r.paths.items) |*job| {
        job.region = if (bounds.isEmpty()) .empty else job.bounds.intersect(bounds);
        if (job.region.isEmpty()) job.region = .empty else grow(&size, job.region);
    }
    size = .{ @min(size[0], limits.maxImageDimension2D), @min(size[1], limits.maxImageDimension2D) };
    r.page_size = size;
    r.pages = 0;
    var shelves: Shelves = .{ .width = size[0], .height = size[1] };
    for (r.paths.items) |*job| {
        if (job.region.isEmpty()) {
            r.setMask(job, .{ 0, 0, 0, 0 });
            continue;
        }
        const w: u32 = @intCast(job.region.width());
        const h: u32 = @intCast(job.region.height());
        const at = (if (r.pages == 0) null else shelves.place(w, h)) orelse blk: {
            shelves.reset();
            r.pages += 1;
            break :blk shelves.place(w, h);
        };
        if (at == null or r.pages > limits.maxImageArrayLayers) {
            log.warn("path mask does not fit; dropped", .{});
            job.region = .empty;
            r.setMask(job, .{ 0, 0, 0, 0 });
            continue;
        }
        job.page = r.pages - 1;
        job.x = at.?[0];
        job.y = at.?[1];
        r.setMask(job, .{
            @intCast(job.page),
            job.region.x0 - @as(i32, @intCast(job.x)),
            job.region.y0 - @as(i32, @intCast(job.y)),
            @intCast(size[0] | size[1] << 16),
        });
    }
}

fn setMask(r: *Renderer, job: *const PathJob, tex: [4]i32) void {
    switch (job.target) {
        .inst => |i| if (i & blur_target != 0) {
            r.blurs.items[i & ~blur_target].inst.tex = tex;
        } else {
            r.insts.items[i].tex = tex;
        },
        .clip => |i| r.clips.items[i].tex = tex,
    }
}

const PathPass = struct {
    r: *Renderer,
    base: [*]u8,
    counter: pool.Counter,

    fn run(ctx: *anyopaque, worker: u32) void {
        const pass: *PathPass = @ptrCast(@alignCast(ctx));
        const r = pass.r;
        const w = &r.workers[worker];
        while (pass.counter.take()) |i| {
            const job = &r.paths.items[i];
            if (job.region.isEmpty()) continue;
            rasterize(w, job, pass.base) catch {
                w.failed = true;
            };
        }
    }

    fn rasterize(w: *Worker, job: *const PathJob, base: [*]u8) Error!void {
        const width: usize = @intCast(job.region.width());
        const out = base[job.offset..][0 .. width * @as(usize, @intCast(job.region.height()))];
        try w.raster.begin(job.region);
        const tol = raster.default_tolerance;
        if (job.stroke) |style| {
            w.path.reset();
            try job.shape.toPath(&w.path);
            w.outline.reset();
            const scale = @max(job.m.maxScale(), 1e-6);
            try w.stroker.stroke(w.path.path(), style, tol / scale, &w.outline);
            w.raster.addPath(w.outline.path(), job.m, tol);
        } else switch (job.shape) {
            .path => |p| w.raster.addPath(p, job.m, tol),
            else => {
                w.path.reset();
                try job.shape.toPath(&w.path);
                w.raster.addPath(w.path.path(), job.m, tol);
            },
        }
        w.raster.finish(job.rule, out, width);
    }
};

fn rasterizePaths(r: *Renderer, base: [*]u8) Error!void {
    if (r.paths.items.len == 0) return;
    for (r.workers) |*w| w.failed = false;
    var pass: PathPass = .{ .r = r, .base = base, .counter = .{ .count = @intCast(r.paths.items.len) } };
    // A little coverage (a scrolling view's border, about 60,000 pixels)
    // costs less than waking the pool: a third of a scrolling list's CPU
    // time went to a dozen workers waking each frame.
    var pixels: i64 = 0;
    for (r.paths.items) |job| pixels += area(job.region);
    if (pixels <= inline_raster_pixels) {
        PathPass.run(&pass, 0);
    } else r.executor.run(r.executor.ctx, .{ .ctx = &pass, .func = PathPass.run });
    for (r.workers) |w| if (w.failed) return error.OutOfMemory;
}

// Pools and uploads ----------------------------------------------------------------

/// Sizes the layer, backdrop, and blur images for every region, and counts
/// the instances recording adds.
fn planPools(r: *Renderer) Error!void {
    var layer_size: [max_layer_depth][2]u32 = @splat(.{ 0, 0 });
    var backdrop: [2]u32 = .{ 0, 0 };
    var blur: [2]u32 = .{ 0, 0 };
    var count: u32 = 0;
    const vp = r.viewport();
    for (r.regions.items) |reg| {
        for (r.layers.items) |l| {
            const img = l.image.intersect(reg);
            if (img.isEmpty()) continue;
            const s = &layer_size[l.depth];
            s.* = .{ @max(s[0], @as(u32, @intCast(img.width()))), @max(s[1], @as(u32, @intCast(img.height()))) };
            if (l.blend != .src_over) grow(&backdrop, img);
            count += 1;
        }
        for (r.blurs.items) |b| {
            const need = b.bbox.intersect(b.scissor).intersect(reg);
            if (need.isEmpty()) continue;
            const src = need.outset(b.radius).intersect(vp);
            grow(&backdrop, src);
            grow(&blur, src);
            count += 1;
        }
    }
    r.dynamic_insts = count;
    r.image_ops = 0;
    for (r.ops.items) |op| {
        if (op == .draws and op.draws.image != null) r.image_ops += 1;
    }
    const d = r.device;
    const attach = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    var waited = false;
    for (&r.layer_images, layer_size) |*img, s| try r.ensureImage(img, s, Device.fp16, attach | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &waited);
    try r.ensureImage(&r.backdrop, backdrop, Device.fp16, c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT, &waited);
    for (&r.blur_images) |*img| try r.ensureImage(img, blur, Device.fp32, attach, &waited);
    for ([_]*Atlas{ &r.glyph_masks, &r.glyph_colors }) |a| {
        if (a.image.handle == null) a.image = try Image.init(d, a.shelves.width, a.shelves.height, a.format, c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    }
    // Textures unused for a while go once no frame reads them, and so do
    // the least recently used ones beyond the budget: every external
    // video frame is a new texture.
    var it = r.textures.iterator();
    while (it.next()) |e| {
        if (r.frame - e.value_ptr.last_frame > 120) {
            try r.retireTexture(e.key_ptr, e.value_ptr);
            it = r.textures.iterator();
        }
    }
    while (r.texture_bytes > texture_budget) {
        var oldest: ?std.AutoHashMapUnmanaged(u64, Texture).Entry = null;
        var all = r.textures.iterator();
        while (all.next()) |e| {
            if (e.value_ptr.last_frame == r.frame) continue;
            if (oldest == null or e.value_ptr.last_frame < oldest.?.value_ptr.last_frame) oldest = e;
        }
        const e = oldest orelse break;
        try r.retireTexture(e.key_ptr, e.value_ptr);
    }
}

/// Texture memory kept for images not drawn in the current frame.
const texture_budget = 256 << 20;

fn retireTexture(r: *Renderer, key: *u64, t: *Texture) Error!void {
    try r.frames[r.frame % frames_in_flight].garbage.append(r.gpa, t.image);
    r.texture_bytes -= @as(u64, t.image.width) * t.image.height * (if (t.format == 1) @as(u64, 8) else 4);
    r.textures.removeByPtr(key);
}

fn grow(s: *[2]u32, rc: IRect) void {
    if (rc.isEmpty()) return;
    s.* = .{ @max(s[0], @as(u32, @intCast(rc.width()))), @max(s[1], @as(u32, @intCast(rc.height()))) };
}

/// Makes `img` at least `size` (rounded up to 256 px), waiting for the GPU
/// once before replacing any image.
fn ensureImage(r: *Renderer, img: *Image, size: [2]u32, format: c.VkFormat, usage: c.VkImageUsageFlags, waited: *bool) Error!void {
    if (size[0] == 0 or size[1] == 0) return;
    if (img.handle != null and img.width >= size[0] and img.height >= size[1]) return;
    const w = std.mem.alignForward(u32, @max(size[0], img.width), 256);
    const h = std.mem.alignForward(u32, @max(size[1], img.height), 256);
    if (img.handle != null and !waited.*) {
        try r.idle();
        waited.* = true;
    }
    img.deinit(r.device);
    img.* = try Image.init(r.device, w, h, format, usage);
}

/// Assigns staging offsets to masks and uploads after `start`; returns the
/// end.
fn planUploads(r: *Renderer, start: usize) Error!usize {
    var at = start;
    r.uploads.clearRetainingCapacity();
    for (r.paths.items) |*job| {
        if (job.region.isEmpty()) continue;
        job.offset = at;
        at = std.mem.alignForward(usize, at + @as(usize, @intCast(area(job.region))), 16);
    }
    for (r.glyph_uploads.items) |index| {
        const e = r.glyphs.entry(index);
        const pos = r.glyph_pos.items[index];
        const a = if (e.kind == .mask) &r.glyph_masks else &r.glyph_colors;
        try r.uploads.append(r.gpa, .{ .image = &a.image, .x = @intCast(pos.x), .y = @intCast(pos.y), .width = e.width, .height = e.height, .offset = at });
        at = std.mem.alignForward(usize, at + @as(usize, e.width) * e.height * a.bytes_per_pixel, 16);
    }
    for (r.image_uploads.items) |ref| {
        try r.uploads.append(r.gpa, .{ .image = &r.textures.getPtr(ref.key).?.image, .x = 0, .y = 0, .width = ref.width, .height = ref.height, .offset = at });
        at = std.mem.alignForward(usize, at + @as(usize, ref.width) * ref.height * ref.format.bytesPerPixel(), 16);
    }
    return at;
}

fn copyUploads(r: *Renderer, base: [*]u8, start: usize) void {
    _ = start;
    var k: usize = 0;
    for (r.glyph_uploads.items) |index| {
        const e = r.glyphs.entry(index);
        const u = r.uploads.items[k];
        k += 1;
        switch (e.kind) {
            .mask => for (0..e.height) |y| @memcpy(base[u.offset + y * e.width ..][0..e.width], r.glyphs.maskRow(e, y)),
            .color => for (0..e.height) |y| {
                const row = std.mem.sliceAsBytes(r.glyphs.colorRow(e, y));
                @memcpy(base[u.offset + y * row.len ..][0..row.len], row);
            },
            .redirect => unreachable,
        }
    }
    for (r.image_uploads.items) |ref| {
        const u = r.uploads.items[k];
        k += 1;
        const row = @as(usize, ref.width) * ref.format.bytesPerPixel();
        for (0..ref.height) |y| @memcpy(base[u.offset + y * row ..][0..row], ref.pixels.?[y * ref.stride ..][0..row]);
    }
}

fn ensureMaskPages(r: *Renderer, f: *Frame) Error!void {
    const d = r.device;
    const layers = @max(r.pages, 1);
    const size: [2]u32 = if (r.pages == 0) .{ 16, 16 } else r.page_size;
    if (f.masks.handle == null or f.masks.width < size[0] or f.masks.height < size[1] or f.masks.layers < layers) {
        // This frame's fence has passed: nothing reads it.
        const w = @max(size[0], f.masks.width);
        const h = @max(size[1], f.masks.height);
        f.masks.deinit(d);
        f.masks = try Image.initArray(d, w, h, @max(layers, 2), c.VK_FORMAT_R8_UNORM, c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    }
    // The packing assumed the page size; a larger image only adds room.
    for (r.paths.items) |job| {
        if (job.region.isEmpty()) continue;
        try r.uploads.append(r.gpa, .{
            .image = &f.masks,
            .layer = job.page,
            .x = job.x,
            .y = job.y,
            .width = @intCast(job.region.width()),
            .height = @intCast(job.region.height()),
            .offset = job.offset,
        });
    }
    // Texture sets for this frame's recording.
    const needed = 2 + r.image_ops * @as(u32, @intCast(@max(r.regions.items.len, 1))) + r.dynamic_insts * 8;
    if (f.texture_pool == null or f.texture_sets < needed) {
        if (f.texture_pool != null) d.vkd.vkDestroyDescriptorPool.?(d.device, f.texture_pool, null);
        f.texture_pool = null;
        const n = @max(needed * 2, 64);
        const sizes = [_]c.VkDescriptorPoolSize{.{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = n * 2 }};
        try vk.call(d.vkd.vkCreateDescriptorPool, .{ d.device, &c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = n,
            .poolSizeCount = sizes.len,
            .pPoolSizes = &sizes,
        }, null, &f.texture_pool });
        f.texture_sets = n;
    }
}

fn writeDescriptors(r: *Renderer, f: *Frame, layout: DataLayout) void {
    const d = r.device;
    var buffers: [6]c.VkDescriptorBufferInfo = undefined;
    for (buffers[0..4], layout.ranges[0..4]) |*b, range| b.* = .{ .buffer = f.data.handle, .offset = range[0], .range = range[1] };
    buffers[4] = .{ .buffer = d.luts.handle, .offset = 0, .range = c.VK_WHOLE_SIZE };
    buffers[5] = .{ .buffer = f.data.handle, .offset = layout.ranges[4][0], .range = layout.ranges[4][1] };
    const read = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    const images = [3]c.VkDescriptorImageInfo{
        .{ .sampler = d.sampler, .imageView = r.glyph_masks.image.view, .imageLayout = read },
        .{ .sampler = d.sampler, .imageView = r.glyph_colors.image.view, .imageLayout = read },
        .{ .sampler = d.sampler, .imageView = f.masks.view, .imageLayout = read },
    };
    var writes: [9]c.VkWriteDescriptorSet = undefined;
    for (&writes, 0..) |*w, b| w.* = .{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = f.set,
        .dstBinding = @intCast(b),
        .descriptorCount = 1,
        .descriptorType = if (b < 6) c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER else c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pBufferInfo = if (b < 6) &buffers[b] else null,
        .pImageInfo = if (b < 6) null else &images[b - 6],
    };
    d.vkd.vkUpdateDescriptorSets.?(d.device, writes.len, &writes, 0, null);
}

// Recording ------------------------------------------------------------------------

const Recorder = struct {
    r: *Renderer,
    cmd: c.VkCommandBuffer,
    frame: *Frame,
    targets: [max_layer_depth + 1]Pass = undefined,
    depth: usize = 0,
    pipeline: c.VkPipeline = null,
    rendering: bool = false,
    /// The `pieces` push constant last set.
    pieces: bool = false,
    region: IRect = .empty,
    dummy_set: c.VkDescriptorSet = null,

    const Pass = struct {
        image: *Image,
        /// Device coordinates of texel (0, 0) and the area it holds.
        origin: [2]i32,
        area: IRect,
    };

    fn k(rec: *Recorder) *const vk.Device {
        return &rec.r.device.vkd;
    }

    fn top(rec: *Recorder) *Pass {
        return &rec.targets[rec.depth];
    }

    fn begin(rec: *Recorder, clear: ?[4]f32) void {
        const t = rec.top();
        rec.transition(t.image, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
        const local = t.area.intersect(rec.region);
        const ra: c.VkRect2D = .{
            .offset = .{ .x = local.x0 - t.origin[0], .y = local.y0 - t.origin[1] },
            .extent = .{ .width = @intCast(local.width()), .height = @intCast(local.height()) },
        };
        const attachment: c.VkRenderingAttachmentInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = t.image.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = if (clear != null) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = .{ .color = .{ .float32 = clear orelse .{ 0, 0, 0, 0 } } },
        };
        const info: c.VkRenderingInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = ra,
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &attachment,
        };
        rec.k().vkCmdBeginRendering.?(rec.cmd, &info);
        rec.rendering = true;
        const vpt: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(t.image.width), .height = @floatFromInt(t.image.height), .minDepth = 0, .maxDepth = 1 };
        rec.k().vkCmdSetViewport.?(rec.cmd, 0, 1, &vpt);
        rec.k().vkCmdSetScissor.?(rec.cmd, 0, 1, &ra);
        rec.pipeline = null;
    }

    fn end(rec: *Recorder) void {
        if (!rec.rendering) return;
        rec.k().vkCmdEndRendering.?(rec.cmd);
        rec.rendering = false;
    }

    fn bind(rec: *Recorder, p: c.VkPipeline) void {
        if (rec.pipeline == p) return;
        rec.k().vkCmdBindPipeline.?(rec.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, p);
        rec.pipeline = p;
        const t = rec.top();
        const push: Device.Push = .{
            .origin = .{ @floatFromInt(t.origin[0]), @floatFromInt(t.origin[1]) },
            .size = .{ @floatFromInt(t.image.width), @floatFromInt(t.image.height) },
            .region = .{ 0, 0, 0, 0 },
        };
        rec.pushConstants(push);
    }

    /// Sets whether instance draws expand each instance around its hole.
    fn setPieces(rec: *Recorder, on: bool) void {
        if (rec.pieces == on) return;
        rec.pieces = on;
        const v: u32 = @intFromBool(on);
        rec.k().vkCmdPushConstants.?(rec.cmd, rec.r.device.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, @offsetOf(Device.Push, "pieces"), 4, &v);
    }

    fn pushConstants(rec: *Recorder, push: Device.Push) void {
        rec.pieces = push.pieces != 0;
        rec.k().vkCmdPushConstants.?(rec.cmd, rec.r.device.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Device.Push), &push);
    }

    fn draw(rec: *Recorder, first: u32, count: u32, image: ?u64) Error!void {
        if (image) |key| try rec.bindTextures(&rec.r.textures.getPtr(key).?.image, null);
        rec.bind(rec.r.device.draw_pipeline);
        // An instance with a hole is drawn as the four quads around it
        // (quad.vert): runs of those go four times, the rest once.
        const insts = rec.r.insts.items;
        var i = first;
        const last = first + count;
        while (i < last) {
            const holed = !quadRect(insts[i].hole).isEmpty();
            var j = i + 1;
            while (j < last and !quadRect(insts[j].hole).isEmpty() == holed) j += 1;
            rec.setPieces(holed);
            if (holed) rec.k().vkCmdDraw.?(rec.cmd, 4, (j - i) * 4, 0, i * 4) else rec.k().vkCmdDraw.?(rec.cmd, 4, j - i, 0, i);
            i = j;
        }
    }

    /// Binds the dummy images as set 1. Every image a bound set names
    /// must be in its declared layout at each draw, used or not, so sets
    /// naming scratch images are replaced right after their draw.
    fn bindDummy(rec: *Recorder) Error!void {
        if (rec.dummy_set == null) rec.dummy_set = try rec.textureSet(&rec.r.dummy, null);
        const d = rec.r.device;
        d.vkd.vkCmdBindDescriptorSets.?(rec.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, d.pipeline_layout, 1, 1, &rec.dummy_set, 0, null);
    }

    /// Binds `a` and `b` (or the dummy image) as set 1.
    fn bindTextures(rec: *Recorder, a: *const Image, b: ?*const Image) Error!void {
        const set = try rec.textureSet(a, b);
        const d = rec.r.device;
        d.vkd.vkCmdBindDescriptorSets.?(rec.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, d.pipeline_layout, 1, 1, &set, 0, null);
    }

    fn textureSet(rec: *Recorder, a: *const Image, b: ?*const Image) Error!c.VkDescriptorSet {
        const r = rec.r;
        const d = r.device;
        var set: c.VkDescriptorSet = null;
        try vk.call(d.vkd.vkAllocateDescriptorSets, .{ d.device, &c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = rec.frame.texture_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &d.texture_layout,
        }, &set });
        const read = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        const infos = [2]c.VkDescriptorImageInfo{
            .{ .sampler = d.sampler, .imageView = a.view, .imageLayout = read },
            .{ .sampler = d.sampler, .imageView = (b orelse &r.dummy).view, .imageLayout = read },
        };
        var writes: [2]c.VkWriteDescriptorSet = undefined;
        for (&writes, 0..) |*w, i| w.* = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = @intCast(i),
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &infos[i],
        };
        d.vkd.vkUpdateDescriptorSets.?(d.device, 2, &writes, 0, null);
        return set;
    }

    /// Appends a recording-time instance and draws it with `pipeline`.
    fn drawOne(rec: *Recorder, inst: Inst, p: c.VkPipeline) void {
        const r = rec.r;
        const index = r.inst_next;
        std.debug.assert(index < r.inst_capacity); // reserved in planPools
        r.inst_base.?[index] = inst;
        r.inst_next += 1;
        rec.bind(p);
        rec.setPieces(false);
        rec.k().vkCmdDraw.?(rec.cmd, 4, 1, 0, index);
    }

    fn transition(rec: *Recorder, img: *Image, layout: c.VkImageLayout) void {
        if (img.layout == layout) return;
        const b: c.VkImageMemoryBarrier2 = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
            .srcAccessMask = c.VK_ACCESS_2_MEMORY_WRITE_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
            .dstAccessMask = c.VK_ACCESS_2_MEMORY_READ_BIT | c.VK_ACCESS_2_MEMORY_WRITE_BIT,
            .oldLayout = img.layout,
            .newLayout = layout,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = img.handle,
            .subresourceRange = Device.color_range,
        };
        const dep: c.VkDependencyInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &b };
        rec.k().vkCmdPipelineBarrier2.?(rec.cmd, &dep);
        img.layout = layout;
    }

    /// Copies device rectangle `rc` of the current target into the backdrop
    /// image, whose texel (0, 0) becomes device (rc.x0, rc.y0).
    fn copyBackdrop(rec: *Recorder, rc: IRect) void {
        const t = rec.top();
        const r = rec.r;
        rec.end();
        rec.transition(t.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
        rec.transition(&r.backdrop, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        const region: c.VkImageCopy = .{
            .srcSubresource = Device.color_layers,
            .srcOffset = .{ .x = rc.x0 - t.origin[0], .y = rc.y0 - t.origin[1], .z = 0 },
            .dstSubresource = Device.color_layers,
            .dstOffset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = @intCast(rc.width()), .height = @intCast(rc.height()), .depth = 1 },
        };
        rec.k().vkCmdCopyImage.?(rec.cmd, t.image.handle, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, r.backdrop.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        rec.transition(&r.backdrop, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    }

    fn pushLayer(rec: *Recorder, l: *const LayerInfo) bool {
        const img_area = l.image.intersect(rec.region);
        if (img_area.isEmpty()) return false;
        rec.end();
        rec.depth += 1;
        const img = &rec.r.layer_images[l.depth];
        img.layout = c.VK_IMAGE_LAYOUT_UNDEFINED; // contents are discarded
        rec.targets[rec.depth] = .{ .image = img, .origin = .{ img_area.x0, img_area.y0 }, .area = img_area };
        rec.begin(.{ 0, 0, 0, 0 });
        return true;
    }

    fn popLayer(rec: *Recorder, l: *const LayerInfo) Error!void {
        const r = rec.r;
        const layer = rec.top().*;
        rec.end();
        rec.transition(layer.image, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        rec.depth -= 1;
        const parent = rec.top();
        const region = l.scissor.intersect(rec.region).intersect(layer.area).intersect(parent.area);
        if (region.isEmpty()) return rec.begin(null);
        var inst: Inst = .{
            .quad = irect(region),
            .color = .{ 0, 0, 0, l.opacity },
            .ptex = .{ 0, layer.origin[0], layer.origin[1], 0 },
        };
        if (l.blend == .src_over) {
            inst.paint = paint_texel;
            rec.begin(null);
            try rec.bindTextures(layer.image, null);
            rec.drawOne(inst, r.device.draw_pipeline);
            return rec.bindDummy();
        }
        rec.copyBackdrop(region);
        inst.paint = paint_blend;
        inst.aux = @backingInt(l.blend);
        inst.clip = if (l.blend.isUnbounded()) l.clip else 0;
        inst.btex = .{ 0, region.x0, region.y0, 0 };
        rec.begin(null);
        try rec.bindTextures(layer.image, &r.backdrop);
        rec.drawOne(inst, r.device.replace_pipeline);
        try rec.bindDummy();
    }

    fn blur(rec: *Recorder, b: *const BlurInfo) Error!void {
        const r = rec.r;
        const t = rec.top();
        const need = b.bbox.intersect(b.scissor).intersect(rec.region).intersect(t.area);
        if (need.isEmpty()) return;
        const src = need.outset(b.radius).intersect(r.viewport()).intersect(t.area);
        rec.copyBackdrop(src);
        const so: [2]i32 = .{ src.x0, src.y0 };
        // Passes ping-pong through the blur images, from the backdrop.
        var input: *Image = &r.backdrop;
        var which: usize = 0;
        const BlurPass = struct { dir: [2]i32, radius: u32, mode: u32, kernel: u32 };
        var passes: [6]BlurPass = undefined;
        var n: usize = 0;
        if (b.boxes) |bx| {
            for (bx) |rad| {
                passes[n] = .{ .dir = .{ 1, 0 }, .radius = rad, .mode = 0, .kernel = 0 };
                n += 1;
            }
            for (bx) |rad| {
                passes[n] = .{ .dir = .{ 0, 1 }, .radius = rad, .mode = 0, .kernel = 0 };
                n += 1;
            }
        } else {
            passes[0] = .{ .dir = .{ 1, 0 }, .radius = b.kernel_radius, .mode = 1, .kernel = b.kernel };
            passes[1] = .{ .dir = .{ 0, 1 }, .radius = b.kernel_radius, .mode = 1, .kernel = b.kernel };
            n = 2;
        }
        for (passes[0..n]) |p| {
            const out = &r.blur_images[which];
            if (input == &r.backdrop) out.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            // Horizontal passes cover the whole backdrop; vertical ones
            // only the needed columns.
            const area_ = if (p.dir[0] != 0) src else IRect{ .x0 = need.x0, .y0 = src.y0, .x1 = need.x1, .y1 = src.y1 };
            rec.transition(out, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
            const ra: c.VkRect2D = .{
                .offset = .{ .x = area_.x0 - so[0], .y = area_.y0 - so[1] },
                .extent = .{ .width = @intCast(area_.width()), .height = @intCast(area_.height()) },
            };
            const attachment: c.VkRenderingAttachmentInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                .imageView = out.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            };
            const info: c.VkRenderingInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
                .renderArea = ra,
                .layerCount = 1,
                .colorAttachmentCount = 1,
                .pColorAttachments = &attachment,
            };
            const kd = rec.k();
            kd.vkCmdBeginRendering.?(rec.cmd, &info);
            const vpt: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(out.width), .height = @floatFromInt(out.height), .minDepth = 0, .maxDepth = 1 };
            kd.vkCmdSetViewport.?(rec.cmd, 0, 1, &vpt);
            kd.vkCmdSetScissor.?(rec.cmd, 0, 1, &ra);
            kd.vkCmdBindPipeline.?(rec.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.device.blur_pipeline);
            try rec.bindTextures(input, null);
            rec.pushConstants(.{
                .origin = .{ @floatFromInt(so[0]), @floatFromInt(so[1]) },
                .size = .{ @floatFromInt(out.width), @floatFromInt(out.height) },
                .region = irect(area_),
                .clamp = irect(src),
                .mode = p.mode,
                .radius = p.radius,
                .kernel = p.kernel,
                .src_origin = .{ @floatFromInt(so[0]), @floatFromInt(so[1]) },
                .dir = p.dir,
            });
            kd.vkCmdDraw.?(rec.cmd, 4, 1, 0, 0);
            kd.vkCmdEndRendering.?(rec.cmd);
            rec.transition(out, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
            input = out;
            which ^= 1;
        }
        var inst = b.inst;
        inst.quad = irect(need);
        inst.ptex = .{ 0, so[0], so[1], 0 };
        inst.btex = .{ 0, so[0], so[1], 0 };
        rec.begin(null);
        try rec.bindTextures(input, &r.backdrop);
        rec.drawOne(inst, r.device.replace_pipeline);
        try rec.bindDummy();
    }
};

fn record(r: *Renderer, f: *Frame, opts: Options, target: Target) Error!void {
    const d = r.device;
    const kd = &d.vkd;
    vk.check(kd.vkResetCommandPool.?(d.device, f.pool, 0)) catch |e| return d.note(e);
    const begin_info: c.VkCommandBufferBeginInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    try vk.call(kd.vkBeginCommandBuffer, .{ f.cmd, &begin_info });
    const cmd = f.cmd;

    // Everything below waits for earlier frames' work on the same images.
    const mb: c.VkMemoryBarrier2 = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
        .srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .srcAccessMask = c.VK_ACCESS_2_MEMORY_WRITE_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .dstAccessMask = c.VK_ACCESS_2_MEMORY_READ_BIT | c.VK_ACCESS_2_MEMORY_WRITE_BIT,
    };
    kd.vkCmdPipelineBarrier2.?(cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &mb });

    var rec: Recorder = .{ .r = r, .cmd = cmd, .frame = f };
    vk.check(kd.vkResetDescriptorPool.?(d.device, f.texture_pool, 0)) catch |e| return d.note(e);
    // Scratch images hold nothing across frames.
    for (&r.layer_images) |*img| img.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    r.backdrop.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    for (&r.blur_images) |*img| img.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    kd.vkCmdBindDescriptorSets.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, d.pipeline_layout, 0, 1, &f.set, 0, null);

    // Uploads.
    f.masks.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    rec.transition(&f.masks, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    rec.transition(&r.dummy, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    for (r.uploads.items) |u| {
        rec.transition(u.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        var layers = Device.color_layers;
        layers.baseArrayLayer = u.layer;
        const copy: c.VkBufferImageCopy = .{
            .bufferOffset = u.offset,
            .imageSubresource = layers,
            .imageOffset = .{ .x = @intCast(u.x), .y = @intCast(u.y), .z = 0 },
            .imageExtent = .{ .width = u.width, .height = u.height, .depth = 1 },
        };
        kd.vkCmdCopyBufferToImage.?(cmd, f.data.handle, u.image.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    }
    for (r.uploads.items) |u| rec.transition(u.image, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    for ([_]*Image{ &r.glyph_masks.image, &r.glyph_colors.image }) |img| rec.transition(img, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    // Regions.
    if (r.stale) r.working.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    const bg = solid(opts.background);
    for (r.regions.items) |region| {
        rec.region = region;
        rec.depth = 0;
        rec.targets[0] = .{ .image = &r.working, .origin = .{ 0, 0 }, .area = r.viewport() };
        rec.begin(bg);
        try rec.bindDummy();
        var i: usize = 0;
        while (i < r.ops.items.len) : (i += 1) {
            switch (r.ops.items[i]) {
                .draws => |dr| {
                    if (!rec.rendering) rec.begin(null);
                    try rec.draw(dr.first, dr.count, dr.image);
                },
                .push => |li| {
                    if (!rec.pushLayer(&r.layers.items[li])) i = r.layers.items[li].end;
                },
                .pop => |li| try rec.popLayer(&r.layers.items[li]),
                .blur => |bi| try rec.blur(&r.blurs.items[bi]),
            }
        }
        rec.end();
    }

    // Encode the whole working image into the target.
    rec.transition(&r.working, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    var out_view: c.VkImageView = undefined;
    var output: Device.Output = .rgba8;
    var has_alpha = true;
    var swap_image: Image = undefined;
    switch (target) {
        .readback => {
            r.readback_image.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            rec.transition(&r.readback_image, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
            out_view = r.readback_image.view;
        },
        .swapchain => |s| {
            swap_image = .{ .handle = s.image, .view = s.view, .width = r.width, .height = r.height, .layout = c.VK_IMAGE_LAYOUT_UNDEFINED };
            rec.transition(&swap_image, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
            out_view = s.view;
            output = s.output;
            has_alpha = s.has_alpha;
        },
    }
    const full: c.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = r.width, .height = r.height } };
    const attachment: c.VkRenderingAttachmentInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = out_view,
        .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
    };
    kd.vkCmdBeginRendering.?(cmd, &.{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = full,
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment,
    });
    const vpt: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(r.width), .height = @floatFromInt(r.height), .minDepth = 0, .maxDepth = 1 };
    kd.vkCmdSetViewport.?(cmd, 0, 1, &vpt);
    kd.vkCmdSetScissor.?(cmd, 0, 1, &full);
    kd.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, d.encode_pipelines[@backingInt(output)]);
    try rec.bindTextures(&r.working, null);
    rec.pushConstants(.{
        .size = .{ @floatFromInt(r.width), @floatFromInt(r.height) },
        .region = irect(r.viewport()),
        .mode = @intFromBool(has_alpha),
    });
    kd.vkCmdDraw.?(cmd, 4, 1, 0, 0);
    kd.vkCmdEndRendering.?(cmd);

    switch (target) {
        .readback => {
            rec.transition(&r.readback_image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
            const copy: c.VkBufferImageCopy = .{
                .bufferOffset = 0,
                .imageSubresource = Device.color_layers,
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = r.width, .height = r.height, .depth = 1 },
            };
            kd.vkCmdCopyImageToBuffer.?(cmd, r.readback_image.handle, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, f.readback.handle, 1, &copy);
            const hb: c.VkMemoryBarrier2 = .{
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
                .srcStageMask = c.VK_PIPELINE_STAGE_2_COPY_BIT,
                .srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_2_HOST_BIT,
                .dstAccessMask = c.VK_ACCESS_2_HOST_READ_BIT,
            };
            kd.vkCmdPipelineBarrier2.?(cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &hb });
        },
        .swapchain => rec.transition(&swap_image, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR),
    }
    try vk.call(kd.vkEndCommandBuffer, .{cmd});
}
