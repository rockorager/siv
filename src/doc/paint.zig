//! Painting (CSS 2.1 Appendix E, simplified): backgrounds with colors,
//! images, and gradients; borders in every style with radii; box shadows;
//! text with decorations; inline box backgrounds and borders per line;
//! list markers; replaced content; opacity and overflow clips as layers;
//! positioned boxes after the normal flow in z-index order; and selection
//! and find highlights. Only boxes that reach the band asked for are
//! painted, so a long document costs what is near the viewport.

const std = @import("std");
const css = @import("css");
const text = @import("text");
const scene = @import("scene");
const raster = @import("raster");
const box_mod = @import("box.zig");
const layout = @import("layout.zig");
const inline_mod = @import("inline.zig");
const url_mod = @import("url.zig");

const Rect = raster.Rect;
const Color = css.Color;
const Style = css.Style;
const BoxId = box_mod.BoxId;
const none = box_mod.none;
pub const Error = scene.Error;

/// System colors (CSS Color 4) from the application's theme (D29), as
/// sRGB colors.
pub const Palette = struct {
    canvas: Color = Color.white,
    canvas_text: Color = Color.black,
    link: Color = Color.rgb8(0, 0, 238),
    visited: Color = Color.rgb8(85, 26, 139),
    active: Color = Color.rgb8(238, 0, 0),
    button_face: Color = Color.rgb8(240, 240, 240),
    button_text: Color = Color.black,
    button_border: Color = Color.rgb8(118, 118, 118),
    field: Color = Color.white,
    field_text: Color = Color.black,
    highlight: Color = Color.rgb8(51, 142, 255),
    highlight_text: Color = Color.white,
    mark: Color = Color.rgb8(255, 255, 0),
    mark_text: Color = Color.black,
    gray: Color = Color.rgb8(128, 128, 128),
    accent: Color = Color.rgb8(53, 132, 228),
    accent_text: Color = Color.white,
    /// Find matches, and the current one.
    find: Color = Color.rgb8(255, 230, 0),
    find_current: Color = Color.rgb8(255, 150, 50),
    selection: Color = .{ .r = 0.2, .g = 0.55, .b = 1, .a = 0.35 },
};

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Draws a replaced element's loaded content into `dst` (document
    /// coordinates); returns false when there is nothing to draw yet.
    drawReplaced: *const fn (ctx: *anyopaque, b: *scene.Builder, resource: u32, dst: Rect, opacity: f32) Error!bool,
    /// A background image's size, if loaded, and drawing it.
    imageSize: *const fn (ctx: *anyopaque, url: []const u8) ?[2]f32,
    drawImage: *const fn (ctx: *anyopaque, b: *scene.Builder, url: []const u8, dst: Rect, clip: Rect) Error!void,
    /// Marker text shaped for a style: glyph runs relative to a baseline
    /// origin, with the total advance.
    marker: *const fn (ctx: *anyopaque, index: u32) ?*const MarkerGlyphs,
};

pub const MarkerGlyphs = struct {
    runs: []const Run,
    width: f32,

    pub const Run = struct { font: text.FontId, size: f32, glyphs: []const scene.Glyph };
};

/// A text range in an IFC, highlighted.
pub const Highlight = struct { ifc: u32, start: u32, end: u32, color: Color };

/// A rectangle with its edges rounded to whole (CSS) pixels.
fn snap(r: Rect) Rect {
    return .{ .x0 = @round(r.x0), .y0 = @round(r.y0), .x1 = @round(r.x1), .y1 = @round(r.y1) };
}

pub const Painter = struct {
    engine: *layout.Engine,
    palette: Palette,
    hooks: Hooks,
    b: *scene.Builder,
    /// Document y range to paint.
    band: [2]f32,
    highlights: []const Highlight = &.{},
    scratch: std.mem.Allocator,
    /// The box whose background the canvas took (the root element's or
    /// the body's, CSS 2.1 14.2): it does not paint it again.
    canvas_src: BoxId = none,
    /// Layers deferred to their stacking context (`stackingZ`).
    positioned: std.ArrayList(Positioned) = .empty,
    /// Overflow clips open, and where the current stacking context's own
    /// begin.
    clips: std.ArrayList(Rect) = .empty,
    ctx_clips: usize = 0,
    glyphs: std.ArrayList(scene.Glyph) = .empty,
    /// Where image URLs of style attributes resolve from (style sheets'
    /// are resolved when parsed).
    base_url: []const u8 = "",

    const Positioned = struct { id: BoxId, x: f32, y: f32, z: i32, order: u32, clip: ?Rect };

    fn tree(p: *const Painter) *box_mod.Tree {
        return p.engine.tree;
    }

    fn style(p: *const Painter, id: BoxId) *const Style {
        return p.engine.style(id);
    }

    pub fn color(p: *const Painter, c: Color, current: Color) scene.Color {
        const r = p.resolve(c, current);
        return scene.Color.srgb(r.r, r.g, r.b, r.a);
    }

    fn resolve(p: *const Painter, c: Color, current: Color) Color {
        return switch (c.kind) {
            .rgba => c,
            .current => if (current.kind == .rgba) current else p.resolve(current, Color.black),
            .system => switch (c.system) {
                .canvas => p.palette.canvas,
                .canvas_text => p.palette.canvas_text,
                .link_text => p.palette.link,
                .visited_text => p.palette.visited,
                .active_text => p.palette.active,
                .button_face => p.palette.button_face,
                .button_text => p.palette.button_text,
                .button_border => p.palette.button_border,
                .field => p.palette.field,
                .field_text => p.palette.field_text,
                .highlight => p.palette.highlight,
                .highlight_text => p.palette.highlight_text,
                .mark => p.palette.mark,
                .mark_text => p.palette.mark_text,
                .gray_text => p.palette.gray,
                .accent_color => p.palette.accent,
                .accent_color_text => p.palette.accent_text,
            },
        };
    }

    fn textColor(p: *const Painter, st: *const Style) Color {
        return p.resolve(st.inh.color, Color.black);
    }

    /// Paints the document's boxes that reach the band.
    pub fn paint(p: *Painter) Error!void {
        const root = p.tree().root;
        if (root == none) return;
        // The canvas: the root element's (or body's) background fills it.
        try p.boxContent(root, 0, 0, 0, true);
    }

    fn visible(p: *const Painter, y0: f32, y1: f32) bool {
        return y1 >= p.band[0] and y0 <= p.band[1];
    }

    /// The z-index of a box painted as a stacking context of its own
    /// (CSS 2.1 Appendix E, CSS Flexbox 5.4, CSS Grid 9.1): positioned
    /// boxes (z-index auto as 0), flex and grid items with a z-index, and
    /// boxes with opacity below 1; null for boxes painted in the flow.
    fn stackingZ(p: *const Painter, id: BoxId) ?i32 {
        const st = p.style(id);
        if (st.isPositioned()) return st.box.z_index orelse 0;
        const b = p.tree().get(id);
        if (st.box.z_index) |z| if (b.parent != none and !b.atomic) switch (p.tree().get(b.parent).kind) {
            .flex, .grid => return z,
            else => {},
        };
        if (st.box.opacity < 1 or st.box.mask_image != null) return 0;
        return null;
    }

    /// A box and its descendants at document offset (x, y) of its parent.
    fn box(p: *Painter, id: BoxId, px: f32, py: f32, depth: u32) Error!void {
        const b = p.tree().get(id);
        const x = px + b.x;
        const y = py + b.y;
        if (depth > 0 and b.parent != none) if (p.stackingZ(id)) |z| {
            // Painted with the stacking context's other layers, inside
            // the clips of the overflow boxes between them unless an
            // absolute box's containing block is outside those.
            var clip: ?Rect = null;
            const pos = p.style(id).box.position;
            if (pos != .absolute and pos != .fixed) for (p.clips.items[p.ctx_clips..]) |c| {
                clip = if (clip) |cl| cl.intersect(c) else c;
            };
            try p.positioned.append(p.scratch, .{ .id = id, .x = x, .y = y, .z = z, .order = @intCast(p.positioned.items.len), .clip = clip });
            return;
        };
        try p.boxContent(id, x, y, depth, false);
    }

    /// Whether a box's overflow went to the viewport (CSS Overflow 3,
    /// 3.3): the root element's, and the body's when the root's is
    /// visible. The viewport is the page, so it clips nothing here.
    fn propagated(p: *const Painter, id: BoxId) bool {
        const html = p.tree().get(p.tree().root).first;
        if (html == none) return false;
        if (id == html) return true;
        const body = p.tree().get(html).first;
        if (id != body or p.tree().get(body).node == .none) return false;
        const hs = p.style(html);
        return hs.box.overflow_x == .visible and hs.box.overflow_y == .visible;
    }

    /// A box's content; `context`: it is the root of a stacking context,
    /// whose deferred layers it paints in z-index order (negative ones
    /// under its flow, CSS 2.1 Appendix E).
    fn boxContent(p: *Painter, id: BoxId, x: f32, y: f32, depth: u32, context: bool) Error!void {
        const b = p.tree().get(id);
        const st = p.style(id);
        if (st.inh.visibility != .visible and b.first == none and b.kind != .inline_root) return;
        // Skip boxes outside the band (content overflowing below is rare
        // enough to accept: overflow: visible content of a short box).
        const overflow_slack: f32 = 200;
        if (!p.visible(y - overflow_slack, y + b.h + overflow_slack) and !st.isPositioned() and b.kind != .table_row_group) {
            // Descendants may still be positioned elsewhere; skip only if
            // the box has none of interest (cheap check: a leaf or flow).
            if (b.kind == .inline_root or b.kind == .replaced or b.first == none) return;
            if (!p.visible(y - 10000, y + b.h + 10000)) return;
        }
        const opacity = st.box.opacity;
        if (opacity < 1) try p.b.pushLayer(.{ .opacity = opacity });
        defer if (opacity < 1) p.b.popLayer() catch {};
        // Box edges on whole pixels, as browsers snap them: no
        // antialiased seams where boxes meet or overlap.
        const r = snap(Rect.xywh(x, y, b.w, b.h));
        // A mask (CSS Masking 1): the box in an isolated layer whose last
        // child is the mask image, composited with dst_in, so that only
        // its alpha shows the box. Until the image loads, nothing shows.
        const mask = st.box.mask_image;
        if (mask) |m| {
            if (m.* == .url and p.hooks.imageSize(p.hooks.ctx, try p.imageUrl(m.url)) == null) return;
            try p.b.pushLayer(.{ .isolate = true });
        }
        defer if (mask) |m| {
            p.drawMask(st, m, r) catch {};
            p.b.popLayer() catch {};
        };
        if (id == p.tree().root) {
            try p.canvas(r);
        } else if (b.node != .none or b.kind != .inline_root) {
            try p.decorations(id, r, id == p.canvas_src or id == p.tree().get(p.tree().root).first);
        }
        // Outside list markers.
        if (b.marker != none and st.inh.visibility == .visible) try p.marker(id, x, y);
        const clip = (st.box.overflow_x != .visible or st.box.overflow_y != .visible) and b.kind != .replaced and !p.propagated(id);
        if (clip) {
            const inner = snap(Rect.xywh(x + b.border[3], y + b.border[0], b.w - b.border[1] - b.border[3], b.h - b.border[0] - b.border[2]));
            try p.b.pushLayer(.{ .clip = .{ .shape = .{ .rect = inner } } });
            try p.clips.append(p.scratch, inner);
        }
        defer if (clip) {
            p.b.popLayer() catch {};
            _ = p.clips.pop();
        };
        const start = p.positioned.items.len;
        const mark = p.b.commands.items.len;
        const saved_clips = p.ctx_clips;
        if (context) p.ctx_clips = p.clips.items.len;
        defer p.ctx_clips = saved_clips;
        switch (b.kind) {
            .inline_root => {
                // Floats among the text, under it (CSS 2.1 E.2).
                var it = p.tree().children(id);
                while (it.next()) |c| if (p.tree().get(c).inline_float) try p.box(c, x, y, depth + 1);
                try p.ifc(id, x, y, depth);
            },
            .replaced => try p.replaced(id, r),
            .flex, .grid => {
                // Order-modified document order (CSS Flexbox 5.4.1).
                var kids: std.ArrayList(BoxId) = .empty;
                var reordered = false;
                var it = p.tree().children(id);
                while (it.next()) |c| {
                    if (p.tree().get(c).atomic) continue;
                    try kids.append(p.scratch, c);
                    reordered = reordered or p.style(c).box.order != 0;
                }
                // Out-of-flow children keep their place.
                if (reordered) std.sort.insertion(BoxId, kids.items, p, struct {
                    fn key(pp: *Painter, c: BoxId) i32 {
                        return if (pp.tree().get(c).out_of_flow) 0 else pp.style(c).box.order;
                    }
                    fn lt(pp: *Painter, a: BoxId, c: BoxId) bool {
                        return key(pp, a) < key(pp, c);
                    }
                }.lt);
                for (kids.items) |c| try p.box(c, x, y, depth + 1);
            },
            else => {
                var it = p.tree().children(id);
                while (it.next()) |c| {
                    if (p.tree().get(c).atomic) continue;
                    try p.box(c, x, y, depth + 1);
                }
            },
        }
        if (context) try p.layers(start, mark);
    }

    /// Paints the layers deferred since `start` in z-index order, those
    /// below zero moved under the commands painted since `mark`.
    fn layers(p: *Painter, start: usize, mark: usize) Error!void {
        defer p.positioned.shrinkRetainingCapacity(start);
        if (p.positioned.items.len == start) return;
        std.sort.insertion(Positioned, p.positioned.items[start..], {}, struct {
            fn lt(_: void, a: Positioned, c: Positioned) bool {
                return if (a.z != c.z) a.z < c.z else a.order < c.order;
            }
        }.lt);
        var i = start;
        const flow_end = p.b.commands.items.len;
        while (i < p.positioned.items.len and p.positioned.items[i].z < 0) : (i += 1) try p.layer(p.positioned.items[i]);
        const end = p.b.commands.items.len;
        if (end > flow_end and flow_end > mark) {
            // Under the flow: the negative layers' commands rotate before
            // it, and the layer ends move with them.
            const cmds = p.b.commands.items[mark..end];
            const flow: u32 = @intCast(flow_end - mark);
            const neg: u32 = @intCast(end - flow_end);
            std.mem.rotate(@TypeOf(cmds[0]), cmds, flow);
            for (cmds, 0..) |*c, k| switch (c.*) {
                .push => |*push| if (k < neg) {
                    push.end -= flow;
                } else {
                    push.end += neg;
                },
                else => {},
            };
        }
        while (i < p.positioned.items.len) : (i += 1) try p.layer(p.positioned.items[i]);
    }

    fn layer(p: *Painter, d: Positioned) Error!void {
        if (d.clip) |c| try p.b.pushLayer(.{ .clip = .{ .shape = .{ .rect = c } } });
        defer if (d.clip != null) p.b.popLayer() catch {};
        try p.boxContent(d.id, d.x, d.y, 1, true);
    }

    /// The canvas background: the root's, else the body's (CSS 2.1 14.2).
    fn canvas(p: *Painter, r: Rect) Error!void {
        const root = p.tree().root;
        var src: BoxId = p.tree().get(root).first;
        if (src == none) return;
        var st = p.style(src);
        if (st.box.background_color.a == 0 and st.box.background_image == null and st.box.background_color.kind == .rgba) {
            // The body's.
            const body = p.tree().get(src).first;
            if (body != none and p.tree().get(body).node != .none) {
                src = body;
                st = p.style(src);
            }
        }
        const band = Rect{ .x0 = r.x0, .y0 = @max(r.y0, p.band[0]), .x1 = @max(r.x1, p.engine.viewport_w), .y1 = @min(@max(r.y1, p.band[1]), p.band[1]) };
        p.canvas_src = src;
        var bg = p.resolve(st.box.background_color, p.textColor(st));
        // Neither has one: the theme's canvas color.
        if (bg.a == 0) bg = p.palette.canvas;
        if (bg.a > 0) try p.b.fillRect(band, .color(p.color(bg, Color.black)));
    }

    fn radii(p: *const Painter, id: BoxId, r: Rect) raster.Radii {
        const st = p.style(id);
        var out: [4]raster.Point = undefined;
        for (0..4) |i| {
            out[i] = .{ .x = st.box.border_radius[i][0].resolve(r.width()), .y = st.box.border_radius[i][1].resolve(r.height()) };
        }
        // Scale down radii that do not fit (CSS Backgrounds 5.5).
        var f: f32 = 1;
        const w = r.width();
        const h = r.height();
        if (out[0].x + out[1].x > w) f = @min(f, w / (out[0].x + out[1].x));
        if (out[3].x + out[2].x > w) f = @min(f, w / (out[3].x + out[2].x));
        if (out[0].y + out[3].y > h) f = @min(f, h / (out[0].y + out[3].y));
        if (out[1].y + out[2].y > h) f = @min(f, h / (out[1].y + out[2].y));
        for (&out) |*pt| {
            pt.x *= f;
            pt.y *= f;
        }
        return .{ .tl = out[0], .tr = out[1], .br = out[2], .bl = out[3] };
    }

    fn isZero(rr: raster.Radii) bool {
        return rr.tl.x == 0 and rr.tl.y == 0 and rr.tr.x == 0 and rr.tr.y == 0 and rr.br.x == 0 and rr.br.y == 0 and rr.bl.x == 0 and rr.bl.y == 0;
    }

    fn shape(r: Rect, rr: raster.Radii) scene.Shape {
        return if (isZero(rr)) .{ .rect = r } else .{ .rounded_rect = .{ .rect = r, .radii = rr } };
    }

    fn shrink(rr: raster.Radii, d: [4]f32) raster.Radii {
        // d: top right bottom left
        return .{
            .tl = .{ .x = @max(0, rr.tl.x - d[3]), .y = @max(0, rr.tl.y - d[0]) },
            .tr = .{ .x = @max(0, rr.tr.x - d[1]), .y = @max(0, rr.tr.y - d[0]) },
            .br = .{ .x = @max(0, rr.br.x - d[1]), .y = @max(0, rr.br.y - d[2]) },
            .bl = .{ .x = @max(0, rr.bl.x - d[3]), .y = @max(0, rr.bl.y - d[2]) },
        };
    }

    /// Shadows, background, and borders of a box.
    fn decorations(p: *Painter, id: BoxId, r_box: Rect, is_root_element: bool) Error!void {
        const st = p.style(id);
        if (st.inh.visibility != .visible) return;
        const b = p.tree().get(id);
        // A table's captions sit in its wrapper box, outside the
        // table's own background and borders.
        var r = r_box;
        if (b.kind == .table) {
            var c = b.first;
            while (c != none) : (c = p.tree().get(c).next) {
                const cb = p.tree().get(c);
                if (cb.kind != .table_caption) continue;
                if (p.style(c).inh.caption_side == .top) {
                    r.y0 = @max(r.y0, r_box.y0 + @round(cb.y + cb.h + cb.margin[2]));
                } else {
                    r.y1 = @min(r.y1, r_box.y0 + @round(cb.y - cb.margin[0]));
                }
            }
        }
        if (r.isEmpty()) return;
        const rr = p.radii(id, r);
        const current = p.textColor(st);
        if (st.box.box_shadow) |shadows| {
            var i = shadows.items.len;
            while (i > 0) {
                i -= 1;
                const s = shadows.items[i];
                try p.b.shadow(.{
                    .shape = .{ .rect = r, .radii = rr },
                    .offset = .{ .x = s.x, .y = s.y },
                    .sigma = s.blur / 2,
                    .spread = s.spread,
                    .color = p.color(s.color, current),
                    .inset = s.inset,
                });
            }
        }
        // The root element's background went to the canvas. A row's or
        // row group's shows only under its cells, not in the spacing.
        if (b.kind == .table_row or b.kind == .table_row_group) {
            try p.rowBackground(id, r, r.x0, r.y0, rr, current);
        } else if (!is_root_element) try p.background(id, r, rr, current);
        if (st.inh.border_collapse == .collapse and (b.kind == .table or b.kind == .table_cell)) {
            // Collapsed borders: each cell draws its share of the winning
            // borders, and at the table's edges the table's share too.
            if (b.kind == .table_cell and b.data != none) {
                const cs = p.tree().collapsed.items[b.data];
                var widths: [4]f32 = undefined;
                var styles: [4]css.style.BorderStyle = undefined;
                var colors: [4]Color = undefined;
                for (cs, 0..) |sd, i| {
                    widths[i] = sd.part + sd.ext;
                    styles[i] = sd.style;
                    colors[i] = sd.color;
                }
                const outer: Rect = .{ .x0 = r.x0 - cs[3].ext, .y0 = r.y0 - cs[0].ext, .x1 = r.x1 + cs[1].ext, .y1 = r.y1 + cs[2].ext };
                try p.borders(id, outer, .{ .tl = .{ .x = 0, .y = 0 }, .tr = .{ .x = 0, .y = 0 }, .br = .{ .x = 0, .y = 0 }, .bl = .{ .x = 0, .y = 0 } }, current, widths, styles, colors);
            }
        } else try p.borders(id, r, rr, current, b.border, st.box.border_style, st.box.border_color);
        if (st.box.outline_style != .none and st.box.outline_width > 0) {
            const o = st.box.outline_width;
            const off = st.box.outline_offset;
            const orr = Rect{ .x0 = r.x0 - off - o, .y0 = r.y0 - off - o, .x1 = r.x1 + off + o, .y1 = r.y1 + off + o };
            try p.borders(id, orr, .{ .tl = .{ .x = 0, .y = 0 }, .tr = .{ .x = 0, .y = 0 }, .br = .{ .x = 0, .y = 0 }, .bl = .{ .x = 0, .y = 0 } }, current, .{ o, o, o, o }, @splat(st.box.outline_style), @splat(st.box.outline_color));
        }
    }

    /// A row's or row group's background over `r` (its border box, at
    /// `x`, `y`), clipped to each of its cells.
    fn rowBackground(p: *Painter, id: BoxId, r: Rect, x: f32, y: f32, rr: raster.Radii, current: Color) Error!void {
        const st = p.style(id);
        if (st.box.background_image == null and p.resolve(st.box.background_color, current).a == 0) return;
        if (p.tree().get(id).kind == .table_row) return p.rowCells(id, id, r, x, y, rr, current);
        var c = p.tree().get(id).first;
        while (c != none) : (c = p.tree().get(c).next) {
            const cb = p.tree().get(c);
            if (cb.kind == .table_row) try p.rowCells(id, c, r, x + cb.x, y + cb.y, rr, current);
        }
    }

    fn rowCells(p: *Painter, id: BoxId, row: BoxId, r: Rect, x: f32, y: f32, rr: raster.Radii, current: Color) Error!void {
        var c = p.tree().get(row).first;
        while (c != none) : (c = p.tree().get(c).next) {
            const cb = p.tree().get(c);
            if (cb.kind != .table_cell) continue;
            try p.b.pushLayer(.{ .clip = .{ .shape = .{ .rect = snap(Rect.xywh(x + cb.x, y + cb.y, cb.w, cb.h)) } } });
            defer p.b.popLayer() catch {};
            try p.background(id, r, rr, current);
        }
    }

    fn background(p: *Painter, id: BoxId, r: Rect, rr: raster.Radii, current: Color) Error!void {
        const st = p.style(id);
        const b = p.tree().get(id);
        const clip_box: Rect = switch (st.box.background_clip) {
            .border_box, .text => r,
            .padding_box => .{ .x0 = r.x0 + b.border[3], .y0 = r.y0 + b.border[0], .x1 = r.x1 - b.border[1], .y1 = r.y1 - b.border[2] },
            .content_box => .{ .x0 = r.x0 + b.border[3] + b.padding[3], .y0 = r.y0 + b.border[0] + b.padding[0], .x1 = r.x1 - b.border[1] - b.padding[1], .y1 = r.y1 - b.border[2] - b.padding[2] },
        };
        const clip_rr = if (st.box.background_clip == .border_box) rr else shrink(rr, b.border);
        const bg = p.resolve(st.box.background_color, current);
        if (bg.a > 0) try p.b.fill(shape(clip_box, clip_rr), .nonzero, .color(p.color(bg, current)));
        const img = st.box.background_image orelse return;
        const origin: Rect = switch (st.box.background_origin) {
            .border_box => r,
            .content_box => .{ .x0 = r.x0 + b.border[3] + b.padding[3], .y0 = r.y0 + b.border[0] + b.padding[0], .x1 = r.x1 - b.border[1] - b.padding[1], .y1 = r.y1 - b.border[2] - b.padding[2] },
            else => .{ .x0 = r.x0 + b.border[3], .y0 = r.y0 + b.border[0], .x1 = r.x1 - b.border[1], .y1 = r.y1 - b.border[2] },
        };
        switch (img.*) {
            .gradient => |g| if (st.box.background_size.kind == .explicit and st.box.background_size.w.isAuto() and st.box.background_size.h.isAuto() and st.box.background_repeat == .repeat) {
                // The common case: one gradient over the box.
                try p.gradient(g, origin, shape(clip_box, clip_rr), current);
            } else try p.tiles(.{ .gradient = .{ .g = g, .current = current } }, st.box.background_size, st.box.background_position, st.box.background_repeat, origin, clip_box),
            .url => |u| try p.imageTiles(u, st.box.background_size, st.box.background_position, st.box.background_repeat, origin, clip_box),
        }
    }

    fn drawMask(p: *Painter, st: *const Style, m: *const css.style.Image, r: Rect) Error!void {
        try p.b.pushLayer(.{ .blend = .dst_in });
        defer p.b.popLayer() catch {};
        switch (m.*) {
            .gradient => |g| try p.gradient(g, r, .{ .rect = r }, p.textColor(st)),
            .url => |u| try p.imageTiles(u, st.box.mask_size, st.box.mask_position, st.box.mask_repeat, r, r),
        }
    }

    /// An image's tiles in `origin` (sized, positioned, and repeated as
    /// backgrounds and masks are, CSS Backgrounds 3), clipped to `clip`;
    /// only those in the band.
    fn imageUrl(p: *Painter, raw: []const u8) Error![]const u8 {
        return url_mod.resolve(p.scratch, p.base_url, raw);
    }

    /// What a background or mask layer tiles: an image by URL, or a
    /// gradient (which has no natural size).
    const Tile = union(enum) {
        url: []const u8,
        gradient: struct { g: css.style.Gradient, current: Color },
    };

    fn imageTiles(p: *Painter, raw: []const u8, bs: css.style.BackgroundSize, position: [2]css.Len, rep: css.style.Repeat, origin: Rect, clip_box: Rect) Error!void {
        return p.tiles(.{ .url = raw }, bs, position, rep, origin, clip_box);
    }

    fn tiles(p: *Painter, tile: Tile, bs: css.style.BackgroundSize, position: [2]css.Len, rep: css.style.Repeat, origin: Rect, clip_box: Rect) Error!void {
        var u: []const u8 = "";
        var w: f32 = origin.width();
        var h: f32 = origin.height();
        var natural = false;
        switch (tile) {
            .url => |raw| {
                u = try p.imageUrl(raw);
                const size = p.hooks.imageSize(p.hooks.ctx, u) orelse return;
                w = size[0];
                h = size[1];
                natural = true;
            },
            .gradient => {},
        }
        switch (bs.kind) {
            .cover, .contain => if (natural) {
                const sx = origin.width() / @max(w, 1);
                const sy = origin.height() / @max(h, 1);
                const sc = if (bs.kind == .cover) @max(sx, sy) else @min(sx, sy);
                w *= sc;
                h *= sc;
            },
            .explicit => {
                const ew: ?f32 = if (bs.w.tag == .length) bs.w.resolve(origin.width()) else null;
                const eh: ?f32 = if (bs.h.tag == .length) bs.h.resolve(origin.height()) else null;
                if (ew != null and eh != null) {
                    w = ew.?;
                    h = eh.?;
                } else if (ew) |v| {
                    if (natural) h = h * v / @max(w, 1);
                    w = v;
                } else if (eh) |v| {
                    if (natural) w = w * v / @max(h, 1);
                    h = v;
                }
            },
        }
        if (w <= 0 or h <= 0) return;
        // A gradient in tiles too small to draw one by one: its colors
        // spread over the area.
        if (tile == .gradient and (w * h < 4) and rep != .no_repeat) {
            return p.gradient(tile.gradient.g, clip_box, .{ .rect = clip_box }, tile.gradient.current);
        }
        // round: as many whole tiles as come nearest, scaled to fit.
        if (rep == .round) {
            const nx = @max(1, @round(origin.width() / w));
            const ny = @max(1, @round(origin.height() / h));
            w = origin.width() / nx;
            h = origin.height() / ny;
        }
        var px0 = origin.x0 + position[0].resolve(origin.width() - w);
        var py0 = origin.y0 + position[1].resolve(origin.height() - h);
        const rx = rep == .repeat or rep == .repeat_x or rep == .space or rep == .round;
        const ry = rep == .repeat or rep == .repeat_y or rep == .space or rep == .round;
        // space: as many whole tiles as fit, the space between them.
        var step_x = w;
        var step_y = h;
        if (rep == .space) {
            const nx = @floor(origin.width() / w);
            const ny = @floor(origin.height() / h);
            if (nx >= 2) {
                step_x = w + (origin.width() - nx * w) / (nx - 1);
                px0 = origin.x0;
            }
            if (ny >= 2) {
                step_y = h + (origin.height() - ny * h) / (ny - 1);
                py0 = origin.y0;
            }
        }
        const repeat_x = rx and !(rep == .space and @floor(origin.width() / w) < 2);
        const repeat_y = ry and !(rep == .space and @floor(origin.height() / h) < 2);
        var x0 = px0;
        var y0 = py0;
        if (repeat_x and rep != .space) x0 = px0 - @ceil((px0 - clip_box.x0) / step_x) * step_x;
        if (repeat_y and rep != .space) y0 = py0 - @ceil((py0 - clip_box.y0) / step_y) * step_y;
        // Only the tiles in the band.
        if (repeat_y and y0 + h < p.band[0]) y0 += @floor((p.band[0] - y0) / step_y) * step_y;
        var ty = y0;
        var count: usize = 0;
        while (ty < clip_box.y1 and count < 4096) : (ty += step_y) {
            if (ty > p.band[1]) break;
            if (rep == .space and ty + h > origin.y1 + 0.5) break;
            var tx = x0;
            while (tx < clip_box.x1 and count < 4096) : (tx += step_x) {
                if (rep == .space and tx + w > origin.x1 + 0.5) break;
                count += 1;
                const dst = Rect.xywh(tx, ty, w, h);
                switch (tile) {
                    .url => try p.hooks.drawImage(p.hooks.ctx, p.b, u, dst, clip_box),
                    .gradient => |gr| {
                        const shown = dst.intersect(clip_box);
                        if (!shown.isEmpty()) try p.gradient(gr.g, dst, .{ .rect = shown }, gr.current);
                    },
                }
                if (!repeat_x) break;
            }
            if (!repeat_y) break;
        }
    }

    fn gradient(p: *Painter, g: css.style.Gradient, r: Rect, clip: scene.Shape, current: Color) Error!void {
        if (g.stops.len == 0) return;
        const w = r.width();
        const h = r.height();
        var stops: std.ArrayList(scene.Stop) = .empty;
        // Positions: given or evenly spread (CSS Images 3, 3.5.3).
        const length: f32 = switch (g.kind) {
            .linear => blk: {
                const a = (if (g.corner) |cn| cornerAngle(cn, w, h) else g.angle) * std.math.pi / 180;
                break :blk @abs(w * @sin(a)) + @abs(h * @cos(a));
            },
            .radial => @max(w, h),
            .conic => 1,
        };
        const n = g.stops.len;
        var prev: f32 = 0;
        for (g.stops, 0..) |s, i| {
            var pos: f32 = if (s.pos) |l| l.resolve(length) / @max(length, 0.001) else if (i == 0) 0 else if (i == n - 1) 1 else std.math.nan(f32);
            if (std.math.isNan(pos)) {
                // Spread between neighbors with positions.
                var j = i + 1;
                while (j < n and g.stops[j].pos == null) j += 1;
                const next: f32 = if (j < n) (if (g.stops[j].pos) |l| l.resolve(length) / @max(length, 0.001) else 1) else 1;
                pos = prev + (next - prev) / @as(f32, @floatFromInt(j - i + 1));
            }
            pos = @max(pos, prev);
            prev = pos;
            try stops.append(p.scratch, .{ .offset = pos, .color = p.color(s.color, current) });
        }
        const cx = r.x0 + w / 2;
        const cy = r.y0 + h / 2;
        const geometry: scene.Gradient.Geometry = switch (g.kind) {
            .linear => blk: {
                const a = (if (g.corner) |cn| cornerAngle(cn, w, h) else g.angle) * std.math.pi / 180;
                const dx = @sin(a) * length / 2;
                const dy = -@cos(a) * length / 2;
                break :blk .{ .linear = .{ .p0 = .{ .x = cx - dx, .y = cy - dy }, .p1 = .{ .x = cx + dx, .y = cy + dy } } };
            },
            .radial => blk: {
                const ccx = r.x0 + g.cx.resolve(w);
                const ccy = r.y0 + g.cy.resolve(h);
                const dx = @max(ccx - r.x0, r.x1 - ccx);
                const dy = @max(ccy - r.y0, r.y1 - ccy);
                var radius: f32 = switch (g.extent) {
                    .farthest_corner => @sqrt(dx * dx + dy * dy),
                    .closest_side => @min(@min(ccx - r.x0, r.x1 - ccx), @min(ccy - r.y0, r.y1 - ccy)),
                    .farthest_side => @max(dx, dy),
                    .closest_corner => @sqrt(@min(ccx - r.x0, r.x1 - ccx) * @min(ccx - r.x0, r.x1 - ccx) + @min(ccy - r.y0, r.y1 - ccy) * @min(ccy - r.y0, r.y1 - ccy)),
                    .explicit => g.rx.resolve(w),
                };
                radius = @max(radius, 0.01);
                break :blk .{ .radial = .{ .c0 = .{ .x = ccx, .y = ccy }, .r0 = 0, .c1 = .{ .x = ccx, .y = ccy }, .r1 = radius } };
            },
            .conic => .{ .sweep = .{ .center = .{ .x = r.x0 + g.cx.resolve(w), .y = r.y0 + g.cy.resolve(h) }, .start_angle = (g.angle - 90) * std.math.pi / 180, .end_angle = (g.angle + 270) * std.math.pi / 180 } },
        };
        try p.b.fill(clip, .nonzero, .{ .gradient = .{ .geometry = geometry, .stops = stops.items, .extend = if (g.repeating) .repeat else .pad } });
    }

    fn cornerAngle(c: [2]i8, w: f32, h: f32) f32 {
        // The angle whose gradient line makes the corners' colors meet
        // the perpendicular through the other corners.
        const a = std.math.atan2(w, h) * 180 / std.math.pi;
        if (c[0] > 0 and c[1] < 0) return a; // to top right
        if (c[0] > 0 and c[1] > 0) return 180 - a; // to bottom right
        if (c[0] < 0 and c[1] > 0) return 180 + a; // to bottom left
        return 360 - a; // to top left
    }

    /// Borders: each side as a quad (trapezoid at the corners) or, with
    /// radii and one style and color, as a stroked rounded rectangle.
    fn borders(p: *Painter, id: BoxId, r: Rect, rr: raster.Radii, current: Color, widths: [4]f32, styles: [4]css.style.BorderStyle, colors: [4]Color) Error!void {
        _ = id;
        var any = false;
        for (widths, styles) |w, s| any = any or (w > 0 and s != .none and s != .hidden);
        if (!any) return;
        const same = widths[0] == widths[1] and widths[1] == widths[2] and widths[2] == widths[3] and styles[0] == styles[1] and styles[1] == styles[2] and styles[2] == styles[3] and colors[0].eql(colors[1]) and colors[1].eql(colors[2]) and colors[2].eql(colors[3]);
        if (same and (styles[0] == .solid or styles[0] == .dashed or styles[0] == .dotted or styles[0] == .inset or styles[0] == .outset or styles[0] == .groove or styles[0] == .ridge)) {
            const w = widths[0];
            const hw = w / 2;
            const inset = Rect{ .x0 = r.x0 + hw, .y0 = r.y0 + hw, .x1 = r.x1 - hw, .y1 = r.y1 - hw };
            if (inset.isEmpty()) return;
            var stroke: raster.StrokeStyle = .{ .width = w };
            var dash: [2]f32 = undefined;
            if (styles[0] == .dashed or styles[0] == .dotted) {
                dash = if (styles[0] == .dashed) .{ w * 3, w * 3 } else .{ w, w };
                if (styles[0] == .dotted) {
                    stroke.cap = .round;
                    dash = .{ 0.001, w * 2 };
                }
                stroke.dashes = &dash;
            }
            const c = p.color(shade(colors[0], styles[0], 0), current);
            if (styles[0] == .inset or styles[0] == .outset or styles[0] == .groove or styles[0] == .ridge) {
                // Two-tone: top-left and bottom-right sides.
                return p.sides(r, widths, styles, colors, current);
            }
            try p.b.stroke(shape(inset, shrink(rr, .{ hw, hw, hw, hw })), stroke, .color(c));
            return;
        }
        if (!isZero(rr) and same) {
            // double with radii: two thin strokes.
            const w = widths[0] / 3;
            const c = p.color(colors[0], current);
            for ([_]f32{ w / 2, widths[0] - w / 2 }) |d| {
                const inset = Rect{ .x0 = r.x0 + d, .y0 = r.y0 + d, .x1 = r.x1 - d, .y1 = r.y1 - d };
                if (!inset.isEmpty()) try p.b.stroke(shape(inset, shrink(rr, .{ d, d, d, d })), .{ .width = w }, .color(c));
            }
            return;
        }
        try p.sides(r, widths, styles, colors, current);
    }

    fn shade(c: Color, s: css.style.BorderStyle, side: usize) Color {
        // inset/outset/groove/ridge: darker on two sides.
        const dark = switch (s) {
            .inset, .groove => side == 0 or side == 3,
            .outset, .ridge => side == 1 or side == 2,
            else => false,
        };
        if (!dark or c.kind != .rgba) return c;
        return .{ .r = c.r * 0.5, .g = c.g * 0.5, .b = c.b * 0.5, .a = c.a };
    }

    fn sides(p: *Painter, r: Rect, w: [4]f32, styles: [4]css.style.BorderStyle, colors: [4]Color, current: Color) Error!void {
        const outer = [4]raster.Point{ .{ .x = r.x0, .y = r.y0 }, .{ .x = r.x1, .y = r.y0 }, .{ .x = r.x1, .y = r.y1 }, .{ .x = r.x0, .y = r.y1 } };
        const inner = [4]raster.Point{ .{ .x = r.x0 + w[3], .y = r.y0 + w[0] }, .{ .x = r.x1 - w[1], .y = r.y0 + w[0] }, .{ .x = r.x1 - w[1], .y = r.y1 - w[2] }, .{ .x = r.x0 + w[3], .y = r.y1 - w[2] } };
        for (0..4) |side| {
            if (w[side] <= 0 or styles[side] == .none or styles[side] == .hidden) continue;
            const c = p.color(shade(colors[side], styles[side], side), current);
            const a = side;
            const bi = (side + 1) % 4;
            if (styles[side] == .dashed or styles[side] == .dotted or styles[side] == .double) {
                // A line along the side's middle.
                const m0: raster.Point = .{ .x = (outer[a].x + inner[a].x) / 2, .y = (outer[a].y + inner[a].y) / 2 };
                const m1: raster.Point = .{ .x = (outer[bi].x + inner[bi].x) / 2, .y = (outer[bi].y + inner[bi].y) / 2 };
                var pb = raster.PathBuilder.init(p.scratch);
                try pb.moveTo(m0.x, m0.y);
                try pb.lineTo(m1.x, m1.y);
                const path = pb.path();
                var stroke: raster.StrokeStyle = .{ .width = if (styles[side] == .double) w[side] / 3 else w[side] };
                var dash: [2]f32 = if (styles[side] == .dashed) .{ w[side] * 3, w[side] * 3 } else .{ 0.001, w[side] * 2 };
                if (styles[side] == .dotted) stroke.cap = .round;
                if (styles[side] != .double) {
                    stroke.dashes = &dash;
                    try p.b.stroke(.{ .path = path }, stroke, .color(c));
                } else {
                    // Two lines.
                    for ([_]f32{ -1, 1 }) |k| {
                        const dx = (inner[a].x - outer[a].x) / 3 * k;
                        const dy = (inner[a].y - outer[a].y) / 3 * k;
                        _ = dx;
                        _ = dy;
                    }
                    try p.quad(outer[a], outer[bi], lerp(outer[bi], inner[bi], 1.0 / 3.0), lerp(outer[a], inner[a], 1.0 / 3.0), c);
                    try p.quad(lerp(outer[a], inner[a], 2.0 / 3.0), lerp(outer[bi], inner[bi], 2.0 / 3.0), inner[bi], inner[a], c);
                }
                continue;
            }
            try p.quad(outer[a], outer[bi], inner[bi], inner[a], c);
        }
    }

    fn lerp(a: raster.Point, b: raster.Point, t: f32) raster.Point {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }

    fn quad(p: *Painter, a: raster.Point, b: raster.Point, c: raster.Point, d: raster.Point, col: scene.Color) Error!void {
        // Axis-aligned quads stay rectangles (exact coverage).
        const xs = [4]f32{ a.x, b.x, c.x, d.x };
        const ys = [4]f32{ a.y, b.y, c.y, d.y };
        var rect = true;
        for (xs) |x| rect = rect and (x == std.mem.min(f32, &xs) or x == std.mem.max(f32, &xs));
        for (ys) |y| rect = rect and (y == std.mem.min(f32, &ys) or y == std.mem.max(f32, &ys));
        if (rect) {
            const r = Rect{ .x0 = std.mem.min(f32, &xs), .y0 = std.mem.min(f32, &ys), .x1 = std.mem.max(f32, &xs), .y1 = std.mem.max(f32, &ys) };
            if (!r.isEmpty()) try p.b.fillRect(r, .color(col));
            return;
        }
        var pb = raster.PathBuilder.init(p.scratch);
        try pb.moveTo(a.x, a.y);
        try pb.lineTo(b.x, b.y);
        try pb.lineTo(c.x, c.y);
        try pb.lineTo(d.x, d.y);
        try pb.close();
        const path = pb.path();
        try p.b.fillPath(path, .nonzero, .color(col));
    }

    fn marker(p: *Painter, id: BoxId, x: f32, y: f32) Error!void {
        const b = p.tree().get(id);
        const m = p.tree().markers.items[b.marker];
        if (!m.outside) return;
        if (std.math.isNan(b.baseline)) return;
        const g = p.hooks.marker(p.hooks.ctx, b.marker) orelse return;
        const st = p.engine.store.get(m.style);
        const c = p.color(st.inh.color, Color.black);
        const content_left = x + b.border[3] + b.padding[3];
        const rtl = st.inh.direction == .rtl;
        var pen = if (rtl) x + b.w - b.border[1] - b.padding[1] else content_left - g.width;
        const baseline = @round(y + b.baseline);
        for (g.runs) |run| {
            const face = p.engine.fonts.cache.face(run.font) orelse continue;
            p.glyphs.clearRetainingCapacity();
            var adv: f32 = 0;
            for (run.glyphs) |gl| {
                try p.glyphs.append(p.scratch, .{ .id = gl.id, .x = pen + gl.x, .y = baseline + gl.y });
                adv = @max(adv, gl.x);
            }
            const size = run.size;
            try p.b.glyphs(.{
                .font = .{ .handle = face.font, .key = face.key },
                .size = size,
                .glyphs = p.glyphs.items,
                .paint = .color(c),
                .bounds = Rect{ .x0 = pen - size, .y0 = baseline - size * 1.5, .x1 = pen + g.width + size, .y1 = baseline + size },
            });
            pen += 0;
        }
    }

    fn replaced(p: *Painter, id: BoxId, r: Rect) Error!void {
        const b = p.tree().get(id);
        const st = p.style(id);
        const rep = p.tree().replaced.items[b.data];
        const content = Rect{ .x0 = r.x0 + b.border[3] + b.padding[3], .y0 = r.y0 + b.border[0] + b.padding[0], .x1 = r.x1 - b.border[1] - b.padding[1], .y1 = r.y1 - b.border[2] - b.padding[2] };
        if (content.isEmpty()) return;
        switch (rep.kind) {
            .checkbox, .radio => {
                const c = p.color(p.palette.accent, Color.black);
                const border = p.color(p.palette.button_border, Color.black);
                const k = @min(content.width(), content.height());
                const sq = Rect.xywh(content.x0 + (content.width() - k) / 2, content.y0 + (content.height() - k) / 2, k, k);
                const rad: f32 = if (rep.kind == .radio) k / 2 else 2;
                const rr: raster.Radii = .{ .tl = .{ .x = rad, .y = rad }, .tr = .{ .x = rad, .y = rad }, .br = .{ .x = rad, .y = rad }, .bl = .{ .x = rad, .y = rad } };
                if (rep.checked) {
                    try p.b.fillRoundedRect(sq, rr, .color(c));
                    if (rep.kind == .checkbox) {
                        var pb = raster.PathBuilder.init(p.scratch);
                        try pb.moveTo(sq.x0 + k * 0.22, sq.y0 + k * 0.52);
                        try pb.lineTo(sq.x0 + k * 0.42, sq.y0 + k * 0.72);
                        try pb.lineTo(sq.x0 + k * 0.78, sq.y0 + k * 0.3);
                        const path = pb.path();
                        try p.b.stroke(.{ .path = path }, .{ .width = @max(1.5, k / 7), .join = .round, .cap = .round }, .color(p.color(p.palette.accent_text, Color.black)));
                    } else try p.b.fillRoundedRect(sq.outset(-k * 0.3), .{ .tl = .{ .x = k, .y = k }, .tr = .{ .x = k, .y = k }, .br = .{ .x = k, .y = k }, .bl = .{ .x = k, .y = k } }, .color(p.color(p.palette.accent_text, Color.black)));
                } else {
                    try p.b.fillRoundedRect(sq, rr, .color(p.color(p.palette.field, Color.black)));
                    try p.b.stroke(.{ .rounded_rect = .{ .rect = sq.outset(-0.5), .radii = rr } }, .{ .width = 1 }, .color(border));
                }
            },
            else => {
                if (rep.resource != none) {
                    // object-fit and object-position within the content box.
                    const nat_w = rep.natural_w;
                    const nat_h = rep.natural_h;
                    var dst = content;
                    if (nat_w > 0 and nat_h > 0 and st.box.object_fit != .fill) {
                        const sx = content.width() / nat_w;
                        const sy = content.height() / nat_h;
                        const s = switch (st.box.object_fit) {
                            .contain => @min(sx, sy),
                            .cover => @max(sx, sy),
                            .none => 1,
                            .scale_down => @min(1, @min(sx, sy)),
                            .fill => 1,
                        };
                        const w = nat_w * s;
                        const h = nat_h * s;
                        dst = Rect.xywh(content.x0 + st.box.object_position[0].resolve(content.width() - w), content.y0 + st.box.object_position[1].resolve(content.height() - h), w, h);
                    }
                    const clipped = dst.x0 < content.x0 or dst.y0 < content.y0 or dst.x1 > content.x1 or dst.y1 > content.y1;
                    if (clipped) try p.b.pushLayer(.{ .clip = .{ .shape = .{ .rect = content } } });
                    defer if (clipped) p.b.popLayer() catch {};
                    if (try p.hooks.drawReplaced(p.hooks.ctx, p.b, rep.resource, dst, 1)) return;
                }
            },
        }
    }

    // Inline content.

    fn ifc(p: *Painter, id: BoxId, x: f32, y: f32, depth: u32) Error!void {
        const b = p.tree().get(id);
        const content_x = x + b.border[3] + b.padding[3];
        const content_y = y + b.border[0] + b.padding[0];
        const content_w = @max(0, b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3]);
        const l = p.engine.laid(b.data, content_w) catch return error.OutOfMemory;
        const data = &p.tree().ifcs.items[b.data];
        // Lines in the band.
        var first: usize = 0;
        {
            var lo: usize = 0;
            var hi: usize = l.lines.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (content_y + l.lines[mid].top + l.lines[mid].height < p.band[0]) lo = mid + 1 else hi = mid;
            }
            first = lo;
        }
        for (l.lines[first..]) |line| {
            if (content_y + line.top > p.band[1]) break;
            try p.inlineBoxes(data, l, line, content_x, content_y);
            try p.highlightLine(b.data, l, line, content_x, content_y);
            try p.textLine(data, l, line, content_x, content_y);
            // Atomic inlines on this line.
            for (l.lineFrags(line)) |f| if (f.kind == .atomic) {
                try p.box(f.box, x, y, depth + 1);
            };
        }
    }

    fn inlineBoxes(p: *Painter, data: *const box_mod.Ifc, l: *const inline_mod.Laid, line: inline_mod.Line, cx: f32, cy: f32) Error!void {
        if (data.inline_boxes.len == 0) return;
        const frags = l.lineFrags(line);
        for (data.inline_boxes, 0..) |ib, i| {
            if (ib.end < line.start or ib.start > line.end) continue;
            const st = p.engine.store.get(ib.style);
            const has_bg = st.box.background_color.a > 0 or st.box.background_color.kind != .rgba or st.box.background_image != null;
            var has_border = false;
            for (0..4) |s| has_border = has_border or st.borderWidth(s) > 0;
            if (!has_bg and !has_border and st.box.box_shadow == null) continue;
            if (st.inh.visibility != .visible) continue;
            // Horizontal extent: this box's fragments and its descendants'.
            var x0: f32 = std.math.inf(f32);
            var x1: f32 = -std.math.inf(f32);
            var open_here = false;
            var close_here = false;
            for (frags) |f| {
                if (!within(data, f.inline_box, @intCast(i))) continue;
                var fx0 = f.x;
                var fx1 = f.x + f.w;
                if (f.inline_box == i and f.kind == .open) {
                    open_here = true;
                    fx0 += st.box.margin[3].resolve(0);
                }
                if (f.inline_box == i and f.kind == .close) {
                    close_here = true;
                    fx1 -= st.box.margin[1].resolve(0);
                }
                x0 = @min(x0, fx0);
                x1 = @max(x1, fx1);
            }
            if (!(x1 > x0)) continue;
            const fi = p.engine.fonts.info(ib.style);
            const shift = shiftOf(frags, i);
            const baseline = @round(cy + line.baseline + shift);
            const top = baseline - fi.ascent - st.box.padding[0].resolve(0) - st.borderWidth(0);
            const bottom = baseline + fi.descent + st.box.padding[2].resolve(0) + st.borderWidth(2);
            const r = snap(.{ .x0 = cx + x0, .y0 = top, .x1 = cx + x1, .y1 = bottom });
            const current = p.textColor(st);
            const bg = p.resolve(st.box.background_color, current);
            const rr = p.inlineRadii(st, r, open_here, close_here);
            if (bg.a > 0) try p.b.fill(shape(r, rr), .nonzero, .color(p.color(bg, current)));
            if (has_border) {
                var w = [4]f32{ st.borderWidth(0), st.borderWidth(1), st.borderWidth(2), st.borderWidth(3) };
                if (!open_here) w[3] = 0;
                if (!close_here) w[1] = 0;
                try p.borders(none, r, rr, current, w, st.box.border_style, st.box.border_color);
            }
        }
    }

    fn inlineRadii(p: *const Painter, st: *const Style, r: Rect, open: bool, close: bool) raster.Radii {
        _ = p;
        var out: [4]raster.Point = undefined;
        for (0..4) |i| out[i] = .{ .x = st.box.border_radius[i][0].resolve(r.width()), .y = st.box.border_radius[i][1].resolve(r.height()) };
        if (!open) {
            out[0] = .{ .x = 0, .y = 0 };
            out[3] = .{ .x = 0, .y = 0 };
        }
        if (!close) {
            out[1] = .{ .x = 0, .y = 0 };
            out[2] = .{ .x = 0, .y = 0 };
        }
        const h = r.height();
        const w = r.width();
        for (&out) |*pt| {
            pt.x = @min(pt.x, w / 2);
            pt.y = @min(pt.y, h / 2);
        }
        return .{ .tl = out[0], .tr = out[1], .br = out[2], .bl = out[3] };
    }

    fn shiftOf(frags: []const inline_mod.Frag, ib: usize) f32 {
        for (frags) |f| if (f.inline_box == ib) return f.shift;
        return 0;
    }

    /// Whether inline box `inner` is `outer` or inside it.
    fn within(data: *const box_mod.Ifc, inner_: u32, outer: u32) bool {
        var inner = inner_;
        while (inner != none) : (inner = data.inline_boxes[inner].parent) if (inner == outer) return true;
        return false;
    }

    fn highlightLine(p: *Painter, ifc_index: u32, l: *const inline_mod.Laid, line: inline_mod.Line, cx: f32, cy: f32) Error!void {
        for (p.highlights) |h| {
            if (h.ifc != ifc_index or h.end <= line.start or h.start >= line.end + 1) continue;
            var rects: std.ArrayList([2]f32) = .empty;
            try inline_mod.rangeRects(l, line, h.start, h.end, &rects, p.scratch);
            // A selection running past the line covers its end.
            if (h.end > line.end and h.start <= line.end) try rects.append(p.scratch, .{ line.left + line.width, line.left + line.width + 4 });
            for (rects.items) |xr| {
                const r = Rect{ .x0 = cx + xr[0], .y0 = cy + line.top, .x1 = cx + xr[1], .y1 = cy + line.top + line.height };
                try p.b.fillRect(r, .color(p.color(h.color, Color.black)));
            }
        }
    }

    fn textLine(p: *Painter, data: *const box_mod.Ifc, l: *const inline_mod.Laid, line: inline_mod.Line, cx: f32, cy: f32) Error!void {
        _ = data;
        for (l.lineFrags(line)) |f| {
            if (f.kind != .glyphs) continue;
            const st = p.engine.store.get(f.style);
            if (st.inh.visibility != .visible) continue;
            const face = p.engine.fonts.cache.face(f.font) orelse continue;
            const c = p.textColor(st);
            const paint_color = p.color(c, Color.black);
            const baseline = @round(cy + line.baseline + f.shift);
            const x = cx + f.x;
            p.glyphs.clearRetainingCapacity();
            for (l.fragGlyphs(f)) |g| try p.glyphs.append(p.scratch, .{ .id = g.id, .x = x + g.x, .y = baseline + g.y });
            const size = f.size;
            if (p.glyphs.items.len > 0 and f.w > 0 and size > 0) {
                try p.b.glyphs(.{
                    .font = .{ .handle = face.font, .key = face.key },
                    .size = size,
                    .glyphs = p.glyphs.items,
                    .paint = .color(paint_color),
                    .bounds = Rect{ .x0 = x - size * 0.5, .y0 = baseline - size * 1.3, .x1 = x + f.w + size * 0.5, .y1 = baseline + size * 0.6 },
                });
            }
            // Decorations: the element's own and those propagated to it.
            var deco = st.inh.decorations;
            var deco_color = st.inh.decoration_color;
            var deco_style = st.inh.decoration_style;
            if (st.box.text_decoration_line.any()) {
                const own = st.box.text_decoration_line;
                deco = .{ .underline = deco.underline or own.underline, .overline = deco.overline or own.overline, .line_through = deco.line_through or own.line_through };
                deco_color = if (st.box.text_decoration_color.kind == .current) c else st.box.text_decoration_color;
                deco_style = st.box.text_decoration_style;
            }
            if (!deco.any() or f.w <= 0) continue;
            const dc = p.color(deco_color, c);
            const thick: f32 = if (st.box.text_decoration_thickness.tag == .length) st.box.text_decoration_thickness.resolve(size) else @max(1, @round(size / 16));
            const under_off: f32 = if (st.box.text_underline_offset.tag == .length) st.box.text_underline_offset.resolve(size) else size / 10;
            for ([_]struct { bool, f32 }{ .{ deco.underline, baseline + under_off + thick / 2 }, .{ deco.overline, baseline - size * 0.8 }, .{ deco.line_through, baseline - size * 0.28 } }) |d| {
                if (!d[0]) continue;
                const ly = @round(d[1] - thick / 2);
                switch (deco_style) {
                    .dotted, .dashed, .wavy => {
                        var pb = raster.PathBuilder.init(p.scratch);
                        try pb.moveTo(x, ly + thick / 2);
                        try pb.lineTo(x + f.w, ly + thick / 2);
                        const path = pb.path();
                        var dash: [2]f32 = if (deco_style == .dashed) .{ thick * 3, thick * 2 } else .{ thick, thick };
                        try p.b.stroke(.{ .path = path }, .{ .width = thick, .dashes = &dash }, .color(dc));
                    },
                    .double => {
                        try p.b.fillRect(Rect.xywh(x, ly, f.w, thick), .color(dc));
                        try p.b.fillRect(Rect.xywh(x, ly + thick * 2, f.w, thick), .color(dc));
                    },
                    .solid => try p.b.fillRect(Rect.xywh(x, ly, f.w, thick), .color(dc)),
                }
            }
        }
    }
};
