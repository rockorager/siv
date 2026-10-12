//! HarfBuzz shaping of one font run with full paragraph context.

const std = @import("std");
const hb = @import("harfbuzz");
const Face = @import("font.zig").Face;
const Script = @import("script.zig").Script;

/// A shaped glyph in pixels, y down. Glyphs of a run are in HarfBuzz output
/// order: visual order for the run's direction (decreasing clusters for
/// right-to-left runs).
pub const Glyph = struct {
    id: u32,
    /// Absolute byte offset of the first character of the glyph's cluster.
    cluster: u32,
    advance: f32,
    x_offset: f32,
    y_offset: f32,
    /// HB_GLYPH_FLAG_UNSAFE_TO_BREAK: breaking the line before this glyph's
    /// cluster and shaping each side separately can change the result.
    unsafe_to_break: bool,
};

pub const Request = struct {
    face: *const Face,
    size: f32,
    /// The whole text and the paragraph that provides shaping context.
    text: []const u8,
    paragraph_start: u32,
    paragraph_end: u32,
    /// The range to shape, inside the paragraph.
    start: u32,
    end: u32,
    rtl: bool,
    script: Script,
    language: hb.hb_language_t,
};

/// Owns a reusable HarfBuzz buffer. One per thread.
pub const Shaper = struct {
    buffer: *hb.hb_buffer_t,

    pub fn init() !Shaper {
        const buffer = hb.hb_buffer_create() orelse return error.OutOfMemory;
        if (hb.hb_buffer_allocation_successful(buffer) == 0) {
            hb.hb_buffer_destroy(buffer);
            return error.OutOfMemory;
        }
        return .{ .buffer = buffer };
    }

    pub fn deinit(self: *Shaper) void {
        hb.hb_buffer_destroy(self.buffer);
    }

    /// Shapes `request.start..request.end` and appends its glyphs to `out`.
    pub fn shape(self: *Shaper, allocator: std.mem.Allocator, request: Request, out: *std.ArrayList(Glyph)) !void {
        std.debug.assert(request.paragraph_start <= request.start and request.start <= request.end and request.end <= request.paragraph_end);
        const buffer = self.buffer;
        hb.hb_buffer_clear_contents(buffer);
        hb.hb_buffer_set_direction(buffer, if (request.rtl) hb.HB_DIRECTION_RTL else hb.HB_DIRECTION_LTR);
        hb.hb_buffer_set_script(buffer, request.script);
        hb.hb_buffer_set_language(buffer, request.language);
        // Character-level clusters let carets stop between combining marks
        // that did not ligate; the editor groups them into graphemes.
        hb.hb_buffer_set_cluster_level(buffer, hb.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
        var flags: hb.hb_buffer_flags_t = hb.HB_BUFFER_FLAG_DEFAULT;
        if (request.start == request.paragraph_start) flags |= hb.HB_BUFFER_FLAG_BOT;
        if (request.end == request.paragraph_end) flags |= hb.HB_BUFFER_FLAG_EOT;
        hb.hb_buffer_set_flags(buffer, flags);
        const paragraph = request.text[request.paragraph_start..request.paragraph_end];
        hb.hb_buffer_add_utf8(buffer, paragraph.ptr, @intCast(paragraph.len), request.start - request.paragraph_start, @intCast(request.end - request.start));
        hb.hb_shape(request.face.font, buffer, null, 0);
        if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;

        var count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(buffer, &count);
        const positions = hb.hb_buffer_get_glyph_positions(buffer, null);
        const scale = request.face.scale(request.size);
        const glyphs = try out.addManyAsSlice(allocator, count);
        for (glyphs, infos[0..count], positions[0..count]) |*glyph, *info, position| {
            glyph.* = .{
                .id = info.codepoint,
                .cluster = info.cluster + request.paragraph_start,
                .advance = @as(f32, @floatFromInt(position.x_advance)) * scale,
                .x_offset = @as(f32, @floatFromInt(position.x_offset)) * scale,
                .y_offset = @as(f32, @floatFromInt(-position.y_offset)) * scale,
                .unsafe_to_break = hb.hb_glyph_info_get_glyph_flags(info) & hb.HB_GLYPH_FLAG_UNSAFE_TO_BREAK != 0,
            };
        }
    }
};

test "shaping keeps paragraph context and absolute clusters" {
    const font = @import("font.zig");
    var cache: font.FontCache = .init(std.testing.allocator);
    defer cache.deinit();
    const arabic = cache.face(try cache.add(font.test_fonts.arabic, 0, .borrowed)).?;
    var shaper: Shaper = try .init();
    defer shaper.deinit();
    var glyphs: std.ArrayList(Glyph) = .empty;
    defer glyphs.deinit(std.testing.allocator);

    // "x\nسلام": shape the first two letters of the second paragraph alone
    // and with the rest of the word as context. With context, the second
    // letter (lam) takes its medial form, so the glyphs differ.
    const text = "x\nسلام";
    const base: Request = .{
        .face = arabic,
        .size = 16,
        .text = text,
        .paragraph_start = 2,
        .paragraph_end = @intCast(text.len),
        .start = 2,
        .end = 6,
        .rtl = true,
        .script = @import("script.zig").tag("Arab"),
        .language = hb.hb_language_from_string("ar", -1),
    };
    try shaper.shape(std.testing.allocator, base, &glyphs);
    try std.testing.expectEqual(2, glyphs.items.len);
    // Right-to-left output: the last character comes first.
    try std.testing.expectEqual(4, glyphs.items[0].cluster);
    try std.testing.expectEqual(2, glyphs.items[1].cluster);
    const in_context = glyphs.items[0].id;

    glyphs.clearRetainingCapacity();
    var alone = base;
    alone.paragraph_end = 6;
    try shaper.shape(std.testing.allocator, alone, &glyphs);
    try std.testing.expect(glyphs.items[0].id != in_context);
}
