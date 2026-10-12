//! Themed pointer cursors for the Wayland backend (D16, D19), for
//! compositors without cursor-shape-v1: each shape's XCursor names, and a
//! cache of loaded cursors as wl_shm buffers by shape and pixel size.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const wl = @import("wayland").client.wl;
const platform = @import("platform.zig");
const xcursor = @import("xcursor.zig");

const Shape = platform.CursorShape;

/// XCursor names for a shape: the CSS name first (freedesktop themes
/// have them), then older names themes still use.
pub fn names(shape: Shape) []const []const u8 {
    return switch (shape) {
        .hidden => &.{},
        .default => &.{ "default", "left_ptr" },
        .context_menu => &.{ "context-menu", "left_ptr" },
        .help => &.{ "help", "question_arrow", "whats_this" },
        .pointer => &.{ "pointer", "hand2", "pointing_hand", "hand1" },
        .progress => &.{ "progress", "left_ptr_watch", "half-busy" },
        .wait => &.{ "wait", "watch" },
        .cell => &.{ "cell", "plus" },
        .crosshair => &.{ "crosshair", "cross", "tcross" },
        .text => &.{ "text", "xterm", "ibeam" },
        .vertical_text => &.{ "vertical-text", "xterm" },
        .alias => &.{ "alias", "dnd-link" },
        .copy => &.{ "copy", "dnd-copy" },
        .move => &.{ "move", "dnd-move", "fleur" },
        .no_drop => &.{ "no-drop", "dnd-none", "forbidden", "circle" },
        .not_allowed => &.{ "not-allowed", "crossed_circle", "forbidden", "circle" },
        .grab => &.{ "grab", "openhand", "hand1" },
        .grabbing => &.{ "grabbing", "closedhand", "fleur" },
        .e_resize => &.{ "e-resize", "right_side" },
        .n_resize => &.{ "n-resize", "top_side" },
        .ne_resize => &.{ "ne-resize", "top_right_corner" },
        .nw_resize => &.{ "nw-resize", "top_left_corner" },
        .s_resize => &.{ "s-resize", "bottom_side" },
        .se_resize => &.{ "se-resize", "bottom_right_corner" },
        .sw_resize => &.{ "sw-resize", "bottom_left_corner" },
        .w_resize => &.{ "w-resize", "left_side" },
        .ew_resize => &.{ "ew-resize", "sb_h_double_arrow", "h_double_arrow" },
        .ns_resize => &.{ "ns-resize", "sb_v_double_arrow", "v_double_arrow" },
        .nesw_resize => &.{ "nesw-resize", "fd_double_arrow", "size_bdiag" },
        .nwse_resize => &.{ "nwse-resize", "bd_double_arrow", "size_fdiag" },
        .col_resize => &.{ "col-resize", "sb_h_double_arrow", "split_h" },
        .row_resize => &.{ "row-resize", "sb_v_double_arrow", "split_v" },
        .all_scroll => &.{ "all-scroll", "fleur" },
        .zoom_in => &.{ "zoom-in", "zoom_in" },
        .zoom_out => &.{ "zoom-out", "zoom_out" },
        .dnd_ask => &.{ "dnd-ask", "copy", "dnd-copy" },
        .all_resize => &.{ "all-resize", "move", "fleur" },
    };
}

/// A shape for compositors with cursor-shape-v1 version 1, which lacks
/// the version 2 shapes.
pub fn v1Shape(shape: Shape) Shape {
    return switch (shape) {
        .dnd_ask => .copy,
        .all_resize => .move,
        else => shape,
    };
}

pub const Frame = struct {
    buffer: *wl.Buffer,
    width: u32,
    height: u32,
    xhot: u32,
    yhot: u32,
    delay: u32,
};

/// One shape at one pixel size; no frames if the theme lacks it.
pub const Loaded = struct {
    shape: Shape,
    px: u32,
    /// The image size in the file the frames come from.
    nominal: u32,
    frames: []Frame,
};

/// The cursor theme and its loaded cursors.
pub const Theme = struct {
    gpa: Allocator,
    name: platform.BoundedString(64) = .{},
    /// Logical size in pixels.
    size: u32 = 24,
    path: xcursor.SearchPath,
    loaded: std.ArrayList(*Loaded) = .empty,

    pub fn init(gpa: Allocator) Theme {
        var t: Theme = .{ .gpa = gpa, .path = .fromEnv() };
        t.name.set("default");
        return t;
    }

    pub fn deinit(t: *Theme) void {
        t.clear();
        t.loaded.deinit(t.gpa);
    }

    /// Forgets every loaded cursor (the theme or size changed).
    pub fn clear(t: *Theme) void {
        for (t.loaded.items) |l| {
            for (l.frames) |f| f.buffer.destroy();
            t.gpa.free(l.frames);
            t.gpa.destroy(l);
        }
        t.loaded.clearRetainingCapacity();
    }

    /// Whether `set` changes anything.
    pub fn set(t: *Theme, name: []const u8, size: u32) bool {
        if (std.mem.eql(u8, t.name.slice(), name) and t.size == size) return false;
        t.clear();
        t.name.set(name);
        t.size = size;
        return true;
    }

    /// `shape` with images of about `px` pixels, loading it the first
    /// time. Reads the theme's file on the calling thread.
    pub fn get(t: *Theme, shm: *wl.Shm, shape: Shape, px: u32) ?*Loaded {
        for (t.loaded.items) |l| if (l.shape == shape and l.px == px) return if (l.frames.len != 0) l else null;
        const l = t.gpa.create(Loaded) catch return null;
        l.* = .{ .shape = shape, .px = px, .nominal = 0, .frames = &.{} };
        t.loaded.append(t.gpa, l) catch {
            t.gpa.destroy(l);
            return null;
        };
        for (names(shape)) |name| {
            const file = xcursor.find(&t.path, t.name.slice(), name) orelse continue;
            defer file.unmap();
            const c = xcursor.parse(t.gpa, file.bytes, px) catch continue;
            defer c.deinit(t.gpa);
            l.frames = buffers(t.gpa, shm, c.frames) catch continue;
            l.nominal = c.nominal;
            break;
        }
        return if (l.frames.len != 0) l else null;
    }
};

/// Copies the frames into one shared memory pool, a buffer each.
fn buffers(gpa: Allocator, shm: *wl.Shm, images: []const xcursor.Image) ![]Frame {
    var size: usize = 0;
    for (images) |img| size += img.pixels.len;
    if (size == 0 or size > std.math.maxInt(i32)) return error.InvalidCursor;
    const fd_rc = linux.memfd_create("siv-cursor", linux.MFD.CLOEXEC);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.SystemResources;
    const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(addr) != .SUCCESS) return error.SystemResources;
    const mem: [*]u8 = @ptrFromInt(addr);
    defer _ = linux.munmap(mem, size);
    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    const frames = try gpa.alloc(Frame, images.len);
    var made: usize = 0;
    errdefer {
        for (frames[0..made]) |f| f.buffer.destroy();
        gpa.free(frames);
    }
    var offset: usize = 0;
    for (images, frames) |img, *f| {
        // XCursor pixels are little-endian premultiplied ARGB, as wl_shm's
        // ARGB8888 is.
        @memcpy(mem[offset..][0..img.pixels.len], img.pixels);
        const buffer = try pool.createBuffer(@intCast(offset), @intCast(img.width), @intCast(img.height), @intCast(img.width * 4), .argb8888);
        f.* = .{ .buffer = buffer, .width = img.width, .height = img.height, .xhot = img.xhot, .yhot = img.yhot, .delay = img.delay };
        made += 1;
        offset += img.pixels.len;
    }
    return frames;
}

test "every shape has names, and version 1 compositors get stand-ins" {
    for (std.enums.values(Shape)) |s| {
        if (s != .hidden) try std.testing.expect(names(s).len != 0);
        try std.testing.expect(@intFromEnum(v1Shape(s)) <= @intFromEnum(Shape.zoom_out));
    }
}
