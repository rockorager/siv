//! SVG for icons (D19): the subset that freedesktop icon themes use
//! (Adwaita, Breeze, and the themes drawn like them), parsed by siv and
//! lowered to display lists (D9), so the CPU renderer, Vulkan, and PDF
//! all draw it. Paths and basic shapes, transforms, groups and `use`,
//! opacity and blend modes, fills and strokes, linear and radial
//! gradients, clip paths, luminance and alpha masks, `<style>` sheets and
//! `style` attributes, and the filters icons use (one feColorMatrix, or
//! one feGaussianBlur). Colors can stand for roles (GTK's symbolic
//! convention, KDE's color scheme classes) that take the theme's colors
//! when drawn.
//!
//! Imports: scene, raster.

const std = @import("std");
const scene = @import("scene");
const xml = @import("xml.zig");
const lower_mod = @import("lower.zig");

pub const Document = @import("Document.zig");
pub const Role = Document.Role;
pub const Colors = Document.Colors;
pub const Options = lower_mod.Options;

pub const Error = error{ OutOfMemory, InvalidSvg };

/// Files larger than this are not icons.
pub const max_bytes = 16 << 20;

/// Parses an SVG file into a document that owns its memory (`deinit`).
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, options: Options) Error!*Document {
    if (bytes.len > max_bytes) return error.InvalidSvg;
    var tmp: std.heap.ArenaAllocator = .init(gpa);
    defer tmp.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const tree = try xml.parse(tmp.allocator(), bytes, .{});
    const l = try lower_mod.lower(arena.allocator(), tmp.allocator(), &tree, options);
    const doc = try arena.allocator().create(Document);
    doc.* = .{
        .arena = undefined,
        .width = l.width,
        .height = l.height,
        .view_box = l.view_box,
        .aspect = l.aspect,
        .ops = l.ops,
        .paints = l.paints,
        .recolors = l.recolors,
    };
    doc.arena = arena;
    return doc;
}

test {
    std.testing.refAllDecls(@This());
    _ = xml;
    _ = @import("css.zig");
    _ = @import("color.zig");
    _ = @import("pathdata.zig");
    _ = lower_mod;
    _ = @import("tests.zig");
}
