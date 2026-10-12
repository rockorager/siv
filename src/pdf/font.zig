//! Text in PDF (D9, D13): each font the document uses is embedded once,
//! as a subset of the glyphs it shows (HarfBuzz's subsetter, with
//! variable fonts instanced at the variation the text engine used), as a
//! Type0 font with Identity-H encoding whose character codes are the
//! original glyph ids. TrueType outlines become a CIDFontType2 with a
//! CIDToGIDMap to the subset's glyph ids; CFF outlines a CIDFontType0
//! with the OpenType subset, which keeps glyph ids. A ToUnicode map from
//! the glyph runs' cluster data makes the text searchable and copyable:
//! each glyph maps to the text of its cluster, the first glyph of a
//! cluster carrying a ligature's or a cluster's whole text.
//!
//! Fonts PDF cannot embed (CFF2 outlines) are drawn as paths. Color
//! glyphs print in their outline (monochrome) where they have one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const hb = @import("harfbuzz_subset");
const scene = @import("scene");
const raster = @import("raster");
const content = @import("content.zig");
const Writer = @import("Writer.zig");
const shading = @import("shading.zig");

const num = content.num;

const Kind = enum { truetype, cff, outlines };

const Entry = struct {
    font: *hb.hb_font_t,
    key: u64,
    /// The Type0 font, reserved at first use and written by `write`.
    obj: u32,
    kind: Kind,
    used: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    /// Text by glyph id, owned.
    text: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
};

pub const Fonts = struct {
    gpa: Allocator,
    entries: std.ArrayList(*Entry) = .empty,

    pub fn init(gpa: Allocator) Fonts {
        return .{ .gpa = gpa };
    }

    pub fn deinit(f: *Fonts) void {
        for (f.entries.items) |e| {
            e.used.deinit(f.gpa);
            var it = e.text.valueIterator();
            while (it.next()) |v| f.gpa.free(v.*);
            e.text.deinit(f.gpa);
            hb.hb_font_destroy(e.font);
            f.gpa.destroy(e);
        }
        f.entries.deinit(f.gpa);
    }

    fn entry(f: *Fonts, w: *Writer, font: scene.Font) Allocator.Error!*Entry {
        for (f.entries.items) |e| if (e.key == font.key) return e;
        const hf: *hb.hb_font_t = @ptrCast(font.handle);
        const face = hb.hb_font_get_face(hf);
        const kind: Kind = if (hasTable(face, "CFF2")) .outlines else if (hasTable(face, "CFF ")) .cff else if (hasTable(face, "glyf")) .truetype else .outlines;
        try f.entries.ensureUnusedCapacity(f.gpa, 1);
        const e = try f.gpa.create(Entry);
        errdefer f.gpa.destroy(e);
        e.* = .{ .font = hb.hb_font_reference(hf).?, .key = font.key, .obj = if (kind == .outlines) 0 else try w.reserve(), .kind = kind };
        f.entries.appendAssumeCapacity(e);
        return e;
    }

    /// Draws a glyph run.
    pub fn lowerRun(f: *Fonts, c: *content.Content, run: scene.GlyphRun) content.Error!void {
        if (run.paint.isInvisible() or run.glyphs.len == 0) return;
        const e = try f.entry(c.w, run.font);
        if (e.kind == .outlines) return outlines(c, e, run);
        try record(f.gpa, e, run);
        try c.res.fonts.put(f.gpa, e.obj, {});
        try c.print("q\n", .{});
        const gradient = run.paint == .gradient;
        if (!gradient) try c.color(run.paint.solid, false);
        try c.print("BT\n/F{d} {f} Tf\n{s}", .{ e.obj, num(run.size), if (gradient) "7 Tr\n" else "" });
        // Each glyph at its own origin, upright in the y-down page.
        for (run.glyphs) |g| try c.print("1 0 0 -1 {f} {f} Tm <{X:0>4}> Tj\n", .{ num(g.x), num(g.y), g.id & 0xffff });
        try c.print("ET\n", .{});
        // Text render mode 7 added the glyphs to the clip.
        if (gradient) try shading.paint(c, run.paint.gradient, run.bounds);
        try c.print("Q\n", .{});
    }

    /// Embeds every font: subsets, descriptors, widths, ToUnicode maps.
    pub fn write(f: *Fonts, w: *Writer) Writer.Error!void {
        for (f.entries.items) |e| {
            if (e.kind == .outlines) continue;
            try embed(f.gpa, w, e);
        }
    }
};

fn hasTable(face: ?*hb.hb_face_t, comptime tag: *const [4]u8) bool {
    const blob = hb.hb_face_reference_table(face, hbTag(tag));
    defer hb.hb_blob_destroy(blob);
    return hb.hb_blob_get_length(blob) > 0;
}

fn hbTag(comptime t: *const [4]u8) hb.hb_tag_t {
    return @as(u32, t[0]) << 24 | @as(u32, t[1]) << 16 | @as(u32, t[2]) << 8 | t[3];
}

/// Notes the glyphs a run uses and the text each shows.
fn record(gpa: Allocator, e: *Entry, run: scene.GlyphRun) Allocator.Error!void {
    for (run.glyphs) |g| try e.used.put(gpa, g.id, {});
    const t = run.text orelse return;
    for (run.glyphs, t.clusters, 0..) |g, cl, i| {
        if (e.text.contains(g.id)) continue;
        // Only the first glyph of a cluster carries its text.
        const first = for (t.clusters[0..i]) |prev| {
            if (prev == cl) break false;
        } else true;
        if (!first) continue;
        var end: u32 = @intCast(t.bytes.len);
        for (t.clusters) |other| if (other > cl and other < end) {
            end = other;
        };
        if (end <= cl) continue;
        try e.text.ensureUnusedCapacity(gpa, 1);
        e.text.putAssumeCapacity(g.id, try gpa.dupe(u8, t.bytes[cl..end]));
    }
}

/// Draws a run's glyphs as filled paths, for fonts PDF cannot embed.
fn outlines(c: *content.Content, e: *Entry, run: scene.GlyphRun) content.Error!void {
    var b: raster.PathBuilder = .init(c.w.gpa);
    defer b.deinit();
    const upem: f32 = @floatFromInt(hb.hb_face_get_upem(hb.hb_font_get_face(e.font)));
    const s = run.size / upem;
    var ctx: DrawCtx = .{ .b = &b };
    const funcs = drawFuncs() orelse return error.OutOfMemory;
    defer hb.hb_draw_funcs_destroy(funcs);
    for (run.glyphs) |g| {
        // Font units, y up, to the run's coordinates.
        ctx.m = .{ .a = s, .b = 0, .c = 0, .d = -s, .e = g.x, .f = g.y };
        hb.hb_font_draw_glyph(e.font, g.id, funcs, &ctx);
        if (ctx.failed) return error.OutOfMemory;
    }
    if (b.path().isEmpty()) return;
    try c.fill(.{ .path = b.path() }, .nonzero, run.paint);
}

const DrawCtx = struct {
    b: *raster.PathBuilder,
    m: raster.Affine = .identity,
    failed: bool = false,

    fn pt(d: *DrawCtx, x: f32, y: f32) raster.Point {
        return d.m.apply(.{ .x = x, .y = y });
    }
};

/// Callbacks drawing glyph outlines into a DrawCtx; the caller destroys
/// them.
fn drawFuncs() ?*hb.hb_draw_funcs_t {
    const S = struct {
        fn ctx(p: ?*anyopaque) *DrawCtx {
            return @ptrCast(@alignCast(p));
        }
        fn moveTo(_: ?*hb.hb_draw_funcs_t, p: ?*anyopaque, _: [*c]hb.hb_draw_state_t, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
            const d = ctx(p);
            const q = d.pt(x, y);
            d.b.moveTo(q.x, q.y) catch {
                d.failed = true;
            };
        }
        fn lineTo(_: ?*hb.hb_draw_funcs_t, p: ?*anyopaque, _: [*c]hb.hb_draw_state_t, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
            const d = ctx(p);
            const q = d.pt(x, y);
            d.b.lineTo(q.x, q.y) catch {
                d.failed = true;
            };
        }
        fn quadTo(_: ?*hb.hb_draw_funcs_t, p: ?*anyopaque, _: [*c]hb.hb_draw_state_t, cx: f32, cy: f32, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
            const d = ctx(p);
            const c1 = d.pt(cx, cy);
            const q = d.pt(x, y);
            d.b.quadTo(c1.x, c1.y, q.x, q.y) catch {
                d.failed = true;
            };
        }
        fn cubicTo(_: ?*hb.hb_draw_funcs_t, p: ?*anyopaque, _: [*c]hb.hb_draw_state_t, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32, _: ?*anyopaque) callconv(.c) void {
            const d = ctx(p);
            const c1 = d.pt(c1x, c1y);
            const c2 = d.pt(c2x, c2y);
            const q = d.pt(x, y);
            d.b.cubicTo(c1.x, c1.y, c2.x, c2.y, q.x, q.y) catch {
                d.failed = true;
            };
        }
        fn closePath(_: ?*hb.hb_draw_funcs_t, p: ?*anyopaque, _: [*c]hb.hb_draw_state_t, _: ?*anyopaque) callconv(.c) void {
            const d = ctx(p);
            d.b.close() catch {
                d.failed = true;
            };
        }
    };
    const f = hb.hb_draw_funcs_create() orelse return null;
    hb.hb_draw_funcs_set_move_to_func(f, S.moveTo, null, null);
    hb.hb_draw_funcs_set_line_to_func(f, S.lineTo, null, null);
    hb.hb_draw_funcs_set_quadratic_to_func(f, S.quadTo, null, null);
    hb.hb_draw_funcs_set_cubic_to_func(f, S.cubicTo, null, null);
    hb.hb_draw_funcs_set_close_path_func(f, S.closePath, null, null);
    hb.hb_draw_funcs_make_immutable(f);
    return f;
}

/// The font's PostScript name, reduced to characters PDF names allow.
fn postscriptName(face: ?*hb.hb_face_t, buf: *[64]u8, key: u64) []const u8 {
    var raw: [64]u8 = undefined;
    var len: c_uint = raw.len;
    _ = hb.hb_ot_name_get_utf8(face, hb.HB_OT_NAME_ID_POSTSCRIPT_NAME, hb.hb_language_get_default(), &len, &raw);
    var n: usize = 0;
    for (raw[0..@min(len, raw.len)]) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '+') {
            buf[n] = ch;
            n += 1;
        }
    }
    if (n == 0) return std.fmt.bufPrint(buf, "Font{x}", .{key}) catch unreachable;
    return buf[0..n];
}

/// Six letters derived from the glyph set, as subset font names carry.
fn subsetTag(gids: []const u32, key: u64) [6]u8 {
    var h = std.hash.Wyhash.init(key);
    h.update(std.mem.sliceAsBytes(gids));
    var v = h.final();
    var out: [6]u8 = undefined;
    for (&out) |*ch| {
        ch.* = 'A' + @as(u8, @intCast(v % 26));
        v /= 26;
    }
    return out;
}

fn embed(gpa: Allocator, w: *Writer, e: *Entry) Writer.Error!void {
    try e.used.put(gpa, 0, {});
    const gids = try gpa.dupe(u32, e.used.keys());
    defer gpa.free(gids);
    std.mem.sort(u32, gids, {}, std.sort.asc(u32));
    const face = hb.hb_font_get_face(e.font);
    const upem: f32 = @floatFromInt(hb.hb_face_get_upem(face));

    // The subset.
    const input = hb.hb_subset_input_create_or_fail() orelse return error.OutOfMemory;
    defer hb.hb_subset_input_destroy(input);
    const set = hb.hb_subset_input_glyph_set(input);
    for (gids) |g| hb.hb_set_add(set, g);
    var flags: c_uint = hb.HB_SUBSET_FLAGS_NO_HINTING;
    // CFF keeps glyph ids, so character codes stay glyph ids there.
    if (e.kind == .cff) flags |= hb.HB_SUBSET_FLAGS_RETAIN_GIDS;
    hb.hb_subset_input_set_flags(input, flags);
    if (hb.hb_ot_var_has_data(face) != 0) {
        // Instanced at the variation the text was shaped with.
        var count: c_uint = 0;
        const coords = hb.hb_font_get_var_coords_design(e.font, &count);
        var axes: [32]hb.hb_ot_var_axis_info_t = undefined;
        var n_axes: c_uint = axes.len;
        _ = hb.hb_ot_var_get_axis_infos(face, 0, &n_axes, &axes);
        for (axes[0..n_axes], 0..) |axis, i| {
            const v = if (coords != null and i < count) coords[i] else axis.default_value;
            _ = hb.hb_subset_input_pin_axis_location(input, face, axis.tag, v);
        }
    }
    const plan = hb.hb_subset_plan_create_or_fail(face, input) orelse return error.InvalidFont;
    defer hb.hb_subset_plan_destroy(plan);
    const mapping = hb.hb_subset_plan_old_to_new_glyph_mapping(plan);
    const sub = hb.hb_subset_plan_execute_or_fail(plan) orelse return error.InvalidFont;
    defer hb.hb_face_destroy(sub);
    const blob = hb.hb_face_reference_blob(sub);
    defer hb.hb_blob_destroy(blob);
    var data_len: c_uint = 0;
    const data_ptr = hb.hb_blob_get_data(blob, &data_len);
    if (data_ptr == null or data_len == 0) return error.InvalidFont;
    const data: []const u8 = @as([*]const u8, @ptrCast(data_ptr))[0..data_len];

    var name_buf: [64]u8 = undefined;
    const ps = postscriptName(face, &name_buf, e.key);
    const tag = subsetTag(gids, e.key);

    // Metrics in thousandths of an em.
    const k = 1000 / upem;
    var asc: hb.hb_position_t = 0;
    var desc: hb.hb_position_t = 0;
    var cap: hb.hb_position_t = 0;
    _ = hb.hb_ot_metrics_get_position(e.font, hb.HB_OT_METRICS_TAG_HORIZONTAL_ASCENDER, &asc);
    _ = hb.hb_ot_metrics_get_position(e.font, hb.HB_OT_METRICS_TAG_HORIZONTAL_DESCENDER, &desc);
    if (hb.hb_ot_metrics_get_position(e.font, hb.HB_OT_METRICS_TAG_CAP_HEIGHT, &cap) == 0) cap = asc;
    var bbox: [4]f32 = .{ 0, @as(f32, @floatFromInt(desc)) * k, 1000, @as(f32, @floatFromInt(asc)) * k };
    for (gids) |g| {
        var ext: hb.hb_glyph_extents_t = undefined;
        if (hb.hb_font_get_glyph_extents(e.font, g, &ext) == 0) continue;
        bbox[0] = @min(bbox[0], @as(f32, @floatFromInt(ext.x_bearing)) * k);
        bbox[1] = @min(bbox[1], @as(f32, @floatFromInt(ext.y_bearing + ext.height)) * k);
        bbox[2] = @max(bbox[2], @as(f32, @floatFromInt(ext.x_bearing + ext.width)) * k);
        bbox[3] = @max(bbox[3], @as(f32, @floatFromInt(ext.y_bearing)) * k);
    }
    const italic = hb.hb_style_get_value(e.font, hb.HB_STYLE_TAG_SLANT_ANGLE);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // The font program.
    buf.clearRetainingCapacity();
    if (e.kind == .truetype) try buf.print(gpa, "/Length1 {d}", .{data.len}) else try buf.appendSlice(gpa, "/Subtype /OpenType");
    const file = try w.addStream(buf.items, data);

    buf.clearRetainingCapacity();
    try buf.print(gpa, "<< /Type /FontDescriptor /FontName /{s}+{s} /Flags 4 /FontBBox [{f} {f} {f} {f}] /ItalicAngle {f} /Ascent {f} /Descent {f} /CapHeight {f} /StemV 80 /{s} {d} 0 R >>", .{
        tag,
        ps,
        num(bbox[0]),
        num(bbox[1]),
        num(bbox[2]),
        num(bbox[3]),
        num(italic),
        num(@as(f32, @floatFromInt(asc)) * k),
        num(@as(f32, @floatFromInt(desc)) * k),
        num(@as(f32, @floatFromInt(cap)) * k),
        if (e.kind == .truetype) "FontFile2" else "FontFile3",
        file,
    });
    const descriptor = try w.add(buf.items);

    // Glyph ids to subset glyph ids (TrueType only; CFF kept them).
    var cid_map: u32 = 0;
    if (e.kind == .truetype) {
        const max = gids[gids.len - 1];
        const map = try gpa.alloc(u8, (@as(usize, max) + 1) * 2);
        defer gpa.free(map);
        @memset(map, 0);
        for (gids) |g| {
            const new = hb.hb_map_get(mapping, g);
            const v: u16 = if (new == hb.HB_MAP_VALUE_INVALID) 0 else @intCast(new);
            std.mem.writeInt(u16, map[@as(usize, g) * 2 ..][0..2], v, .big);
        }
        cid_map = try w.addStream("", map);
    }

    // Advances in font units, as thousandths of an em.
    buf.clearRetainingCapacity();
    try buf.print(gpa, "<< /Type /Font /Subtype /{s} /BaseFont /{s}+{s} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {d} 0 R", .{ if (e.kind == .truetype) "CIDFontType2" else "CIDFontType0", tag, ps, descriptor });
    if (cid_map != 0) try buf.print(gpa, " /CIDToGIDMap {d} 0 R", .{cid_map});
    try buf.appendSlice(gpa, " /W [");
    for (gids) |g| try buf.print(gpa, " {d} [{f}]", .{ g, num(@as(f32, @floatFromInt(hb.hb_font_get_glyph_h_advance(e.font, g))) * k) });
    try buf.appendSlice(gpa, " ] >>");
    const cid_font = try w.add(buf.items);

    const to_unicode = try toUnicode(gpa, w, e, gids);

    buf.clearRetainingCapacity();
    try buf.print(gpa, "<< /Type /Font /Subtype /Type0 /BaseFont /{s}+{s} /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>", .{ tag, ps, cid_font, to_unicode });
    try w.set(e.obj, buf.items);
}

fn toUnicode(gpa: Allocator, w: *Writer, e: *Entry, gids: []const u32) Writer.Error!u32 {
    var cmap: std.ArrayList(u8) = .empty;
    defer cmap.deinit(gpa);
    try cmap.appendSlice(gpa,
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        \\/CMapName /Adobe-Identity-UCS def
        \\/CMapType 2 def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\
    );
    var mapped: std.ArrayList(u32) = .empty;
    defer mapped.deinit(gpa);
    for (gids) |g| if (e.text.contains(g)) try mapped.append(gpa, g);
    var i: usize = 0;
    while (i < mapped.items.len) {
        const n = @min(100, mapped.items.len - i);
        try cmap.print(gpa, "{d} beginbfchar\n", .{n});
        for (mapped.items[i..][0..n]) |g| {
            try cmap.print(gpa, "<{X:0>4}> <", .{g});
            try content.utf16Hex(gpa, &cmap, e.text.get(g).?);
            try cmap.appendSlice(gpa, ">\n");
        }
        try cmap.appendSlice(gpa, "endbfchar\n");
        i += n;
    }
    try cmap.appendSlice(gpa,
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
        \\
    );
    return w.addStream("", cmap.items);
}
