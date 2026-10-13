//! Lowers an XML tree to a `Document`: styles cascade (presentation
//! attributes, `<style>` rules by specificity, `style` attributes,
//! `!important`, inheritance), shapes become paths in the root's user
//! space with their transforms applied, paints resolve to colors and
//! gradients, and group effects (opacity, blend modes, isolation, clip
//! paths, masks, and the filters icons use) become layers.
//!
//! What is left out: text, embedded images, patterns, markers, and filter
//! chains other than one feColorMatrix or one feGaussianBlur (an element
//! with another filter draws without it).

const std = @import("std");
const scene = @import("scene");
const raster = @import("raster");
const xml = @import("xml.zig");
const css = @import("css.zig");
const colors_mod = @import("color.zig");
const pathdata = @import("pathdata.zig");
const Document = @import("Document.zig");

const Affine = raster.Affine;
const Rect = raster.Rect;
const Point = raster.Point;
const Tint = Document.Tint;
const Role = Document.Role;
const Op = Document.Op;
const Paint = Document.Paint;
const ColorStep = Document.ColorStep;

pub const Error = error{ OutOfMemory, InvalidSvg };

pub const Options = struct {
    /// GTK's symbolic convention (an icon named `*-symbolic`): every
    /// painted fill and stroke of a shape takes the foreground color, or
    /// the success, warning, or error color for shapes of those classes.
    /// Colors that already stand for a role (KDE's classes) keep it.
    symbolic: bool = false,
    /// Larger documents fail rather than cost unbounded memory.
    max_ops: u32 = 200_000,
    max_points: u32 = 4_000_000,
};

const Length = struct {
    v: f32 = 0,
    /// A percentage of the viewport's width, height, or diagonal.
    pct: bool = false,
};

const PaintSpec = union(enum) {
    none,
    color: Tint,
    current,
    url: struct { id: []const u8, fallback: Fallback },

    const Fallback = union(enum) { none, color: Tint, current };
};

const StopColor = union(enum) { color: Tint, current };

const Style = struct {
    // Inherited.
    fill: PaintSpec = .{ .color = .{} },
    fill_opacity: f32 = 1,
    fill_rule: scene.FillRule = .nonzero,
    stroke: PaintSpec = .none,
    stroke_width: Length = .{ .v = 1 },
    stroke_opacity: f32 = 1,
    cap: raster.Cap = .butt,
    join: raster.Join = .miter,
    miter_limit: f32 = 4,
    dashes: []const Length = &.{},
    dash_offset: Length = .{},
    color: Tint = .{},
    visible: bool = true,
    clip_rule: scene.FillRule = .nonzero,
    filters_linear: bool = true,
    stroke_first: bool = false,
    // Not inherited.
    opacity: f32 = 1,
    display: bool = true,
    clip_path: ?[]const u8 = null,
    mask: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    stop_color: StopColor = .{ .color = .{} },
    stop_opacity: f32 = 1,
    blend: scene.BlendMode = .src_over,
    isolate: bool = false,
    mask_alpha: bool = false,

    fn inherit(p: *const Style) Style {
        var s = p.*;
        const d: Style = .{};
        s.opacity = d.opacity;
        s.display = d.display;
        s.clip_path = null;
        s.mask = null;
        s.filter = null;
        s.stop_color = d.stop_color;
        s.stop_opacity = d.stop_opacity;
        s.blend = d.blend;
        s.isolate = d.isolate;
        s.mask_alpha = d.mask_alpha;
        return s;
    }
};

const Prop = enum {
    fill,
    @"fill-opacity",
    @"fill-rule",
    stroke,
    @"stroke-width",
    @"stroke-opacity",
    @"stroke-linecap",
    @"stroke-linejoin",
    @"stroke-miterlimit",
    @"stroke-dasharray",
    @"stroke-dashoffset",
    color,
    visibility,
    @"clip-rule",
    @"color-interpolation-filters",
    @"paint-order",
    opacity,
    display,
    @"clip-path",
    mask,
    filter,
    @"stop-color",
    @"stop-opacity",
    @"mix-blend-mode",
    isolation,
    @"mask-type",
};

const props: std.StaticStringMap(Prop) = blk: {
    const fields = @typeInfo(Prop).@"enum".field_names;
    var kvs: [fields.len]struct { []const u8, Prop } = undefined;
    for (fields, 0..) |f, i| kvs[i] = .{ f, @field(Prop, f) };
    break :blk .initComptime(kvs);
};

const Kind = enum { svg, g, a, @"switch", use, path, rect, circle, ellipse, line, polyline, polygon };

const kinds: std.StaticStringMap(Kind) = blk: {
    const fields = @typeInfo(Kind).@"enum".field_names;
    var kvs: [fields.len]struct { []const u8, Kind } = undefined;
    for (fields, 0..) |f, i| kvs[i] = .{ f, @field(Kind, f) };
    break :blk .initComptime(kvs);
};

fn isShape(k: Kind) bool {
    return switch (k) {
        .path, .rect, .circle, .ellipse, .line, .polyline, .polygon => true,
        else => false,
    };
}

/// Lowers `doc` into a document allocated from `out` (its arena);
/// `tmp` holds scratch memory that the caller frees afterwards.
pub fn lower(out: std.mem.Allocator, tmp: std.mem.Allocator, doc: *const xml.Document, options: Options) Error!Lowered {
    var l: Lower = .{ .out = out, .tmp = tmp, .doc = doc, .options = options, .pb = .init(tmp), .styles = .init(tmp), .ids = .init(tmp) };
    return l.run();
}

pub const Lowered = struct {
    width: f32,
    height: f32,
    view_box: Rect,
    aspect: Document.Aspect,
    ops: []const Op,
    paints: []const Paint,
    recolors: bool,
};

const Lower = struct {
    out: std.mem.Allocator,
    tmp: std.mem.Allocator,
    doc: *const xml.Document,
    options: Options,
    pb: raster.PathBuilder,
    rules: std.ArrayList(css.Rule) = .empty,
    /// The role a rule's `color` stands for (KDE's color scheme classes).
    rule_roles: std.ArrayList(Role) = .empty,
    ids: std.StringHashMap(u32),
    styles: std.AutoHashMap(u32, Style),
    ops: std.ArrayList(Op) = .empty,
    paints: std.ArrayList(Paint) = .empty,
    points: usize = 0,
    vw: f32 = 100,
    vh: f32 = 100,
    /// The color filter every paint gets, innermost step first.
    chain: []const ColorStep = &.{},
    /// Nesting of references (use, masks), against cycles.
    depth: u32 = 0,
    recolors: bool = false,

    fn run(l: *Lower) Error!Lowered {
        const root = &l.doc.nodes[0];
        if (!std.mem.eql(u8, root.name, "svg")) return error.InvalidSvg;
        for (l.doc.nodes, 0..) |*n, i| {
            if (n.attr("id")) |id| {
                const gop = try l.ids.getOrPut(id);
                if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
            }
            if (std.mem.eql(u8, n.name, "style")) {
                const ty = n.attr("type") orelse "text/css";
                if (std.mem.eql(u8, ty, "text/css") or ty.len == 0) {
                    const before = l.rules.items.len;
                    try css.parseSheet(l.tmp, n.text, &l.rules);
                    for (l.rules.items[before..]) |r| try l.rule_roles.append(l.tmp, ruleRole(r.selector));
                }
            }
        }

        // The viewport.
        var vb: ?Rect = null;
        if (root.attr("viewBox")) |s| {
            var lx: pathdata.Lexer = .{ .s = s };
            const x = lx.number();
            const y = lx.number();
            const w = lx.number();
            const h = lx.number();
            if (x != null and y != null and w != null and h != null and w.? > 0 and h.? > 0)
                vb = .xywh(x.?, y.?, w.?, h.?);
        }
        const wl = parseLength(root.attr("width") orelse "");
        const hl = parseLength(root.attr("height") orelse "");
        var width: f32 = if (wl) |x| (if (x.pct) 0 else x.v) else 0;
        var height: f32 = if (hl) |x| (if (x.pct) 0 else x.v) else 0;
        if (vb) |v| {
            if (!(width > 0) and !(height > 0)) {
                width = v.width();
                height = v.height();
            } else if (!(width > 0)) {
                width = height * v.width() / v.height();
            } else if (!(height > 0)) {
                height = width * v.height() / v.width();
            }
        }
        if (!(width > 0)) width = 100;
        if (!(height > 0)) height = 100;
        const view = vb orelse Rect.xywh(0, 0, width, height);
        l.vw = view.width();
        l.vh = view.height();

        const base: Style = .{};
        const st = try l.cascade(0, &base);
        try l.styles.put(0, st);
        var m: Affine = .identity;
        if (root.attr("transform")) |t| if (pathdata.parseTransform(t)) |tm| {
            m = tm;
        };
        if (st.display) try l.group(0, &st, m, .children);
        return .{
            .width = width,
            .height = height,
            .view_box = view,
            .aspect = parseAspect(root.attr("preserveAspectRatio") orelse ""),
            .ops = l.ops.items,
            .paints = l.paints.items,
            .recolors = l.recolors,
        };
    }

    // Styles ---------------------------------------------------------------

    /// The computed style of `node` in the document tree (for elements
    /// drawn by reference: gradient stops, clip paths, masks).
    fn computed(l: *Lower, node: u32) Error!Style {
        if (l.styles.get(node)) |s| return s;
        const parent = l.doc.nodes[node].parent;
        const ps = if (parent == xml.none) Style{} else try l.computed(parent);
        const s = try l.cascade(node, &ps);
        try l.styles.put(node, s);
        return s;
    }

    fn cascade(l: *Lower, node: u32, parent: *const Style) Error!Style {
        var s = Style.inherit(parent);
        const n = &l.doc.nodes[node];
        for (n.attrs) |a| {
            if (props.get(a.name)) |p| l.apply(&s, parent, p, css.trim(a.value), .none);
        }
        // Matching rules by specificity, then source order.
        var matched: std.ArrayList(u32) = .empty;
        defer matched.deinit(l.tmp);
        for (l.rules.items, 0..) |r, i| {
            if (css.matches(r.selector, l.doc, node)) try matched.append(l.tmp, @intCast(i));
        }
        std.sort.insertion(u32, matched.items, l, struct {
            fn lt(ctx: *Lower, a: u32, b: u32) bool {
                const sa = ctx.rules.items[a].selector.specificity;
                const sb = ctx.rules.items[b].selector.specificity;
                return sa < sb or (sa == sb and a < b);
            }
        }.lt);
        const inline_decls = if (n.attr("style")) |st| try css.parseDecls(l.tmp, st) else &.{};
        for ([_]bool{ false, true }) |important| {
            for (matched.items) |i| {
                for (l.rules.items[i].decls) |d| if (d.important == important) {
                    if (props.get(d.name)) |p| l.apply(&s, parent, p, d.value, l.rule_roles.items[i]);
                };
            }
            for (inline_decls) |d| if (d.important == important) {
                if (props.get(d.name)) |p| l.apply(&s, parent, p, d.value, .none);
            };
        }
        return s;
    }

    fn apply(l: *Lower, s: *Style, parent: *const Style, p: Prop, value: []const u8, role: Role) void {
        if (std.mem.eql(u8, value, "inherit")) {
            inline for (@typeInfo(Prop).@"enum".field_names) |name| {
                if (p == @field(Prop, name)) {
                    const field = comptime fieldOf(@field(Prop, name));
                    @field(s, field) = @field(parent, field);
                }
            }
            return;
        }
        switch (p) {
            .fill => if (parsePaint(value, role)) |v| {
                s.fill = v;
            },
            .stroke => if (parsePaint(value, role)) |v| {
                s.stroke = v;
            },
            .@"fill-opacity" => if (parseOpacity(value)) |v| {
                s.fill_opacity = v;
            },
            .@"stroke-opacity" => if (parseOpacity(value)) |v| {
                s.stroke_opacity = v;
            },
            .opacity => if (parseOpacity(value)) |v| {
                s.opacity = v;
            },
            .@"stop-opacity" => if (parseOpacity(value)) |v| {
                s.stop_opacity = v;
            },
            .@"fill-rule" => if (parseRule(value)) |v| {
                s.fill_rule = v;
            },
            .@"clip-rule" => if (parseRule(value)) |v| {
                s.clip_rule = v;
            },
            .@"stroke-width" => if (parseLength(value)) |v| {
                if (v.v >= 0) s.stroke_width = v;
            },
            .@"stroke-linecap" => {
                if (std.mem.eql(u8, value, "butt")) s.cap = .butt;
                if (std.mem.eql(u8, value, "round")) s.cap = .round;
                if (std.mem.eql(u8, value, "square")) s.cap = .square;
            },
            .@"stroke-linejoin" => {
                if (std.mem.startsWith(u8, value, "miter") or std.mem.eql(u8, value, "arcs")) s.join = .miter;
                if (std.mem.eql(u8, value, "round")) s.join = .round;
                if (std.mem.eql(u8, value, "bevel")) s.join = .bevel;
            },
            .@"stroke-miterlimit" => if (parseNumber(value)) |v| {
                if (v >= 1) s.miter_limit = v;
            },
            .@"stroke-dasharray" => s.dashes = parseDashes(l.tmp, value) orelse s.dashes,
            .@"stroke-dashoffset" => if (parseLength(value)) |v| {
                s.dash_offset = v;
            },
            .color => {
                if (std.mem.eql(u8, value, "currentColor")) {
                    s.color = parent.color;
                } else if (colors_mod.parse(value)) |c| s.color = .{ .rgba = c, .role = role };
            },
            .visibility => s.visible = std.mem.eql(u8, value, "visible") or !(std.mem.eql(u8, value, "hidden") or std.mem.eql(u8, value, "collapse")),
            .display => s.display = !std.mem.eql(u8, value, "none"),
            .@"color-interpolation-filters" => s.filters_linear = !std.ascii.eqlIgnoreCase(value, "srgb"),
            .@"paint-order" => {
                if (std.mem.eql(u8, value, "normal")) {
                    s.stroke_first = false;
                } else {
                    var fill_at: ?usize = null;
                    var stroke_at: ?usize = null;
                    var it = std.mem.tokenizeAny(u8, value, " \t\r\n");
                    var i: usize = 0;
                    while (it.next()) |tok| : (i += 1) {
                        if (std.mem.eql(u8, tok, "fill")) fill_at = i;
                        if (std.mem.eql(u8, tok, "stroke")) stroke_at = i;
                    }
                    s.stroke_first = if (stroke_at) |st| (fill_at == null or st < fill_at.?) else false;
                }
            },
            .@"clip-path" => s.clip_path = parseUrl(value),
            .mask => s.mask = parseUrl(value),
            .filter => s.filter = parseUrl(value),
            .@"stop-color" => {
                if (std.mem.eql(u8, value, "currentColor")) {
                    s.stop_color = .current;
                } else if (colors_mod.parse(value)) |c| s.stop_color = .{ .color = .{ .rgba = c, .role = role } };
            },
            .@"mix-blend-mode" => s.blend = blendMode(value) orelse s.blend,
            .isolation => s.isolate = std.mem.eql(u8, value, "isolate"),
            .@"mask-type" => s.mask_alpha = std.mem.eql(u8, value, "alpha"),
        }
    }

    // Lengths ----------------------------------------------------------------

    const Axis = enum { x, y, diagonal };

    fn len(l: *const Lower, v: Length, axis: Axis) f32 {
        if (!v.pct) return v.v;
        const base = switch (axis) {
            .x => l.vw,
            .y => l.vh,
            .diagonal => @sqrt((l.vw * l.vw + l.vh * l.vh) / 2),
        };
        return v.v / 100 * base;
    }

    fn attrLen(l: *const Lower, node: u32, name: []const u8, axis: Axis, default: f32) f32 {
        const v = parseLength(l.doc.nodes[node].attr(name) orelse return default) orelse return default;
        return l.len(v, axis);
    }

    // Rendering ------------------------------------------------------------

    const Children = enum { children, first_child };

    fn render(l: *Lower, node: u32, parent: *const Style, ctm: Affine) Error!void {
        const n = &l.doc.nodes[node];
        const kind = kinds.get(n.name) orelse return;
        if (n.attr("requiredExtensions")) |r| if (css.trim(r).len != 0) return;
        const st = try l.cascade(node, parent);
        if (!st.display) return;
        var m = ctm;
        if (kind != .svg) if (n.attr("transform")) |t| if (pathdata.parseTransform(t)) |tm| {
            m = tm.then(ctm);
        };
        switch (kind) {
            .g, .a => try l.group(node, &st, m, .children),
            .@"switch" => try l.group(node, &st, m, .first_child),
            .svg => {
                // A nested viewport: placed at x, y, mapping its view box.
                const x = l.attrLen(node, "x", .x, 0);
                const y = l.attrLen(node, "y", .y, 0);
                var inner = Affine.translate(x, y).then(m);
                if (viewBoxOf(n)) |vb| {
                    const w = l.attrLen(node, "width", .x, l.vw);
                    const h = l.attrLen(node, "height", .y, l.vh);
                    inner = mapBox(vb, .xywh(0, 0, w, h), parseAspect(n.attr("preserveAspectRatio") orelse "")).then(inner);
                }
                try l.group(node, &st, inner, .children);
            },
            .use => try l.use(node, &st, m),
            else => try l.shape(node, kind, &st, m),
        }
    }

    fn group(l: *Lower, node: u32, st: *const Style, m: Affine, which: Children) Error!void {
        const fx = (try l.beginEffects(node, st, m, null, false)) orelse return;
        var it = l.doc.children(node);
        while (it.next()) |c| {
            if (which == .first_child) {
                if (kinds.get(l.doc.nodes[c].name) == null) continue;
                try l.render(c, st, m);
                break;
            }
            try l.render(c, st, m);
        }
        try l.endEffects(fx, node, m, null);
    }

    fn use(l: *Lower, node: u32, st: *const Style, m: Affine) Error!void {
        const target = l.ref(l.doc.nodes[node].attr("href") orelse l.doc.nodes[node].attr("xlink:href") orelse return) orelse return;
        // No cycles: the target must not contain the use.
        var a = node;
        while (a != xml.none) : (a = l.doc.nodes[a].parent) if (a == target) return;
        if (l.depth >= 16) return;
        l.depth += 1;
        defer l.depth -= 1;
        const x = l.attrLen(node, "x", .x, 0);
        const y = l.attrLen(node, "y", .y, 0);
        const inner = Affine.translate(x, y).then(m);
        const fx = (try l.beginEffects(node, st, m, null, false)) orelse return;
        const tn = &l.doc.nodes[target];
        if (std.mem.eql(u8, tn.name, "symbol")) {
            const ts = try l.cascade(target, st);
            if (ts.display) {
                var sm = inner;
                if (tn.attr("transform")) |t| if (pathdata.parseTransform(t)) |tm| {
                    sm = tm.then(sm);
                };
                if (viewBoxOf(tn)) |vb| {
                    const w = l.attrLen(node, "width", .x, l.vw);
                    const h = l.attrLen(node, "height", .y, l.vh);
                    sm = mapBox(vb, .xywh(0, 0, w, h), parseAspect(tn.attr("preserveAspectRatio") orelse "")).then(sm);
                }
                try l.group(target, &ts, sm, .children);
            }
        } else try l.render(target, st, inner);
        try l.endEffects(fx, node, m, null);
    }

    fn shape(l: *Lower, node: u32, kind: Kind, st: *const Style, m: Affine) Error!void {
        if (!st.visible) return;
        l.pb.reset();
        try l.buildShape(node, kind, &l.pb);
        const local = l.pb.path();
        if (local.isEmpty()) return;
        const bbox = tightBounds(local, .identity);
        const fill = try l.paintOf(node, st.fill, st, st.fill_opacity, bbox, m);
        const stroke_w = l.len(st.stroke_width, .diagonal);
        const stroke = if (stroke_w > 0) try l.paintOf(node, st.stroke, st, st.stroke_opacity, bbox, m) else null;
        const no_fill = fill == null or kind == .line;
        if (no_fill and stroke == null) return;
        const draws: u32 = @as(u32, @intFromBool(!no_fill)) + @intFromBool(stroke != null);
        // One draw at reduced opacity needs no group.
        const fold = st.opacity < 1 and draws == 1 and st.clip_path == null and st.mask == null and st.filter == null and st.blend == .src_over and !st.isolate;
        if (fold) {
            if (!no_fill) l.paints.items[fill.?].opacity *= st.opacity;
            if (stroke) |s| l.paints.items[s].opacity *= st.opacity;
        }
        const fx = (try l.beginEffects(node, st, m, bbox, fold)) orelse return;
        const similar = isSimilarity(m);
        var baked: ?raster.Path = null;
        if (!no_fill or similar) baked = try l.copyPath(local, m);
        for (0..2) |pass| {
            const do_stroke = (pass == 0) == st.stroke_first;
            if (!do_stroke and !no_fill) {
                try l.emit(.{ .fill = .{ .path = baked.?, .rule = st.fill_rule, .paint = fill.? } });
            } else if (do_stroke and stroke != null) {
                const k: f32 = if (similar) @sqrt(@abs(m.determinant())) else 1;
                var style: raster.StrokeStyle = .{
                    .width = stroke_w * k,
                    .cap = st.cap,
                    .join = st.join,
                    .miter_limit = st.miter_limit,
                    .dash_offset = l.len(st.dash_offset, .diagonal) * k,
                };
                if (st.dashes.len != 0) {
                    const d = try l.out.alloc(f32, st.dashes.len);
                    var sum: f32 = 0;
                    for (d, st.dashes) |*o, x| {
                        o.* = l.len(x, .diagonal) * k;
                        sum += o.*;
                    }
                    if (sum > 0) style.dashes = d;
                }
                if (similar) {
                    try l.emit(.{ .stroke = .{ .path = baked.?, .style = style, .paint = stroke.? } });
                } else {
                    // The stroke's shape follows the transform: stroke in
                    // local coordinates inside a transformed layer.
                    const p = &l.paints.items[stroke.?];
                    if (m.invert()) |inv| p.transform = p.transform.then(inv);
                    try l.emit(.{ .push = .{ .transform = m } });
                    try l.emit(.{ .stroke = .{ .path = try l.copyPath(local, .identity), .style = style, .paint = stroke.? } });
                    try l.emit(.pop);
                }
            }
        }
        try l.endEffects(fx, node, m, bbox);
    }

    fn buildShape(l: *Lower, node: u32, kind: Kind, b: *raster.PathBuilder) Error!void {
        const n = &l.doc.nodes[node];
        switch (kind) {
            .path => try pathdata.parsePath(b, n.attr("d") orelse return),
            .rect => {
                const x = l.attrLen(node, "x", .x, 0);
                const y = l.attrLen(node, "y", .y, 0);
                const w = l.attrLen(node, "width", .x, 0);
                const h = l.attrLen(node, "height", .y, 0);
                if (!(w > 0) or !(h > 0)) return;
                var rx = l.attrLen(node, "rx", .x, -1);
                var ry = l.attrLen(node, "ry", .y, -1);
                if (rx < 0) rx = ry;
                if (ry < 0) ry = rx;
                rx = std.math.clamp(rx, 0, w / 2);
                ry = std.math.clamp(ry, 0, h / 2);
                const r = Rect.xywh(x, y, w, h);
                if (rx > 0 and ry > 0) try b.roundedRect(r, .uniform(rx, ry)) else try b.rect(r);
            },
            .circle => {
                const r = l.attrLen(node, "r", .diagonal, 0);
                if (!(r > 0)) return;
                const cx = l.attrLen(node, "cx", .x, 0);
                const cy = l.attrLen(node, "cy", .y, 0);
                try b.ellipse(.xywh(cx - r, cy - r, 2 * r, 2 * r));
            },
            .ellipse => {
                var rx = l.attrLen(node, "rx", .x, -1);
                var ry = l.attrLen(node, "ry", .y, -1);
                if (rx < 0) rx = ry;
                if (ry < 0) ry = rx;
                if (!(rx > 0) or !(ry > 0)) return;
                const cx = l.attrLen(node, "cx", .x, 0);
                const cy = l.attrLen(node, "cy", .y, 0);
                try b.ellipse(.xywh(cx - rx, cy - ry, 2 * rx, 2 * ry));
            },
            .line => {
                try b.moveTo(l.attrLen(node, "x1", .x, 0), l.attrLen(node, "y1", .y, 0));
                try b.lineTo(l.attrLen(node, "x2", .x, 0), l.attrLen(node, "y2", .y, 0));
            },
            .polyline, .polygon => try pathdata.parsePoints(b, n.attr("points") orelse return, kind == .polygon),
            else => {},
        }
    }

    // Effects --------------------------------------------------------------

    const Effects = struct {
        pushes: u32 = 0,
        mask: ?u32 = null,
        mask_alpha: bool = false,
        blur: ?struct { region: raster.Path, sigma: f32 } = null,
        saved_chain: []const ColorStep,
    };

    /// Opens the layers for an element's effects. Null when the element
    /// draws nothing (an empty clip path).
    fn beginEffects(l: *Lower, node: u32, st: *const Style, m: Affine, known_bbox: ?Rect, folded: bool) Error!?Effects {
        var fx: Effects = .{ .saved_chain = l.chain };
        const needs_bbox = st.clip_path != null or st.mask != null or st.filter != null;
        const bbox = if (!needs_bbox) Rect.empty else known_bbox orelse try l.bboxOf(node, .identity, 0);

        var clip: ?Clip = null;
        if (st.clip_path) |id| if (l.ref(id)) |cp| if (std.mem.eql(u8, l.doc.nodes[cp].name, "clipPath")) {
            clip = try l.clipPath(cp, bbox, m);
            if (clip.?.path.isEmpty()) return null;
        };
        if (st.mask) |id| if (l.ref(id)) |mk| if (std.mem.eql(u8, l.doc.nodes[mk].name, "mask")) {
            fx.mask = mk;
        };
        var blur: ?Filter = null;
        if (st.filter) |id| if (l.ref(id)) |f| if (std.mem.eql(u8, l.doc.nodes[f].name, "filter")) {
            blur = try l.filterOf(f, bbox, m);
        };

        const group_opacity = if (folded) 1 else st.opacity;
        if (group_opacity < 1 or st.blend != .src_over or st.isolate or clip != null) {
            try l.emit(.{ .push = .{
                .opacity = group_opacity,
                .blend = st.blend,
                .isolate = st.isolate,
                .clip = if (clip) |c| .{ .path = c.path, .rule = c.rule } else null,
            } });
            fx.pushes += 1;
        }
        if (fx.mask) |mk| {
            const mn = &l.doc.nodes[mk];
            const ms = try l.computed(mk);
            fx.mask_alpha = ms.mask_alpha;
            const user = std.mem.eql(u8, mn.attr("maskUnits") orelse "", "userSpaceOnUse");
            const area = try l.region(mk, user, bbox, m, -0.1, 1.2);
            if (area.isEmpty()) {
                // An empty mask region hides the element.
                try l.unwind(&fx);
                return null;
            }
            // An isolated layer whose last child is the mask, composited
            // with dst_in: PDF writes that pattern as a soft mask.
            try l.emit(.{ .push = .{ .isolate = true, .clip = .{ .path = area, .rule = .nonzero } } });
            fx.pushes += 1;
        }
        if (blur) |b| switch (b) {
            .matrix => |step| {
                const chain = try l.out.alloc(ColorStep, l.chain.len + 1);
                chain[0] = step;
                @memcpy(chain[1..], l.chain);
                l.chain = chain;
            },
            .blur => |bl| {
                try l.emit(.{ .push = .{ .isolate = true, .clip = .{ .path = bl.region, .rule = .nonzero } } });
                fx.pushes += 1;
                fx.blur = .{ .region = bl.region, .sigma = bl.sigma };
            },
        };
        return fx;
    }

    fn unwind(l: *Lower, fx: *Effects) Error!void {
        for (0..fx.pushes) |_| try l.emit(.pop);
        fx.pushes = 0;
        l.chain = fx.saved_chain;
    }

    fn endEffects(l: *Lower, fx: Effects, node: u32, m: Affine, known_bbox: ?Rect) Error!void {
        var pushes = fx.pushes;
        if (fx.blur) |b| {
            try l.emit(.{ .blur = .{ .region = b.region, .sigma = b.sigma } });
            try l.emit(.pop);
            pushes -= 1;
        }
        l.chain = fx.saved_chain;
        if (fx.mask) |mk| {
            if (l.depth < 16) {
                l.depth += 1;
                defer l.depth -= 1;
                const bbox = known_bbox orelse try l.bboxOf(node, .identity, 0);
                const mn = &l.doc.nodes[mk];
                var cm = m;
                if (std.mem.eql(u8, mn.attr("maskContentUnits") orelse "", "objectBoundingBox")) cm = bboxMap(bbox).then(m);
                const step: ColorStep = if (fx.mask_alpha)
                    .{ .matrix = .{ .m = .{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0 }, .linear = false } }
                else
                    .luminance;
                const saved = l.chain;
                const chain = try l.out.alloc(ColorStep, 1);
                chain[0] = step;
                l.chain = chain;
                defer l.chain = saved;
                try l.emit(.{ .push = .{ .blend = .dst_in } });
                const ms = try l.computed(mk);
                var it = l.doc.children(mk);
                while (it.next()) |c| try l.render(c, &ms, cm);
                try l.emit(.pop);
            }
        }
        for (0..pushes) |_| try l.emit(.pop);
    }

    /// A clip, mask, or filter region as a path in root coordinates.
    fn region(l: *Lower, node: u32, user: bool, bbox: Rect, m: Affine, d_pos: f32, d_size: f32) Error!raster.Path {
        var r: Rect = undefined;
        if (user) {
            r = .xywh(
                l.attrLen(node, "x", .x, l.len(.{ .v = d_pos * 100, .pct = true }, .x)),
                l.attrLen(node, "y", .y, l.len(.{ .v = d_pos * 100, .pct = true }, .y)),
                l.attrLen(node, "width", .x, l.len(.{ .v = d_size * 100, .pct = true }, .x)),
                l.attrLen(node, "height", .y, l.len(.{ .v = d_size * 100, .pct = true }, .y)),
            );
        } else {
            if (!(bbox.width() > 0) or !(bbox.height() > 0)) return .empty;
            const n = &l.doc.nodes[node];
            const fx = fraction(n.attr("x")) orelse d_pos;
            const fy = fraction(n.attr("y")) orelse d_pos;
            const fw = fraction(n.attr("width")) orelse d_size;
            const fh = fraction(n.attr("height")) orelse d_size;
            r = .xywh(bbox.x0 + fx * bbox.width(), bbox.y0 + fy * bbox.height(), fw * bbox.width(), fh * bbox.height());
        }
        if (!(r.width() > 0) or !(r.height() > 0)) return .empty;
        var b: raster.PathBuilder = .init(l.tmp);
        defer b.deinit();
        try b.rect(r);
        return l.copyPath(b.path(), m);
    }

    const Clip = struct { path: raster.Path, rule: scene.FillRule };

    /// The union of a clip path's shapes in root coordinates. Several
    /// shapes combine into one path filled nonzero (exact unless their
    /// windings cancel); one shape keeps its clip-rule.
    fn clipPath(l: *Lower, cp: u32, bbox: Rect, m: Affine) Error!Clip {
        const cn = &l.doc.nodes[cp];
        var cm = m;
        if (std.mem.eql(u8, cn.attr("clipPathUnits") orelse "", "objectBoundingBox")) {
            if (!(bbox.width() > 0) or !(bbox.height() > 0)) return .{ .path = .empty, .rule = .nonzero };
            cm = bboxMap(bbox).then(m);
        }
        if (cn.attr("transform")) |t| if (pathdata.parseTransform(t)) |tm| {
            cm = tm.then(cm);
        };
        var b: raster.PathBuilder = .init(l.tmp);
        defer b.deinit();
        var rule: scene.FillRule = .nonzero;
        var shapes: u32 = 0;
        const cs = try l.computed(cp);
        try l.clipChildren(cp, &cs, cm, &b, &rule, &shapes, 0);
        if (shapes != 1) rule = .nonzero;
        return .{ .path = try l.copyPath(b.path(), .identity), .rule = rule };
    }

    fn clipChildren(l: *Lower, parent: u32, ps: *const Style, m: Affine, b: *raster.PathBuilder, rule: *scene.FillRule, shapes: *u32, depth: u32) Error!void {
        if (depth > 8) return;
        var it = l.doc.children(parent);
        while (it.next()) |c| {
            const n = &l.doc.nodes[c];
            const kind = kinds.get(n.name) orelse continue;
            const st = try l.cascade(c, ps);
            if (!st.display) continue;
            var cm = m;
            if (n.attr("transform")) |t| if (pathdata.parseTransform(t)) |tm| {
                cm = tm.then(m);
            };
            if (kind == .use) {
                const target = l.ref(n.attr("href") orelse n.attr("xlink:href") orelse continue) orelse continue;
                const um = Affine.translate(l.attrLen(c, "x", .x, 0), l.attrLen(c, "y", .y, 0)).then(cm);
                const tn = &l.doc.nodes[target];
                const tk = kinds.get(tn.name) orelse continue;
                if (!isShape(tk)) continue;
                const ts = try l.cascade(target, &st);
                if (!ts.display or !ts.visible) continue;
                var tm2 = um;
                if (tn.attr("transform")) |t| if (pathdata.parseTransform(t)) |tm| {
                    tm2 = tm.then(um);
                };
                try l.clipShape(target, tk, tm2, b);
                rule.* = ts.clip_rule;
                shapes.* += 1;
            } else if (isShape(kind)) {
                if (!st.visible) continue;
                try l.clipShape(c, kind, cm, b);
                rule.* = st.clip_rule;
                shapes.* += 1;
            } else if (kind == .g) {
                try l.clipChildren(c, &st, cm, b, rule, shapes, depth + 1);
            }
        }
    }

    /// Appends a shape of a clip path. Not through `l.pb`, which holds the
    /// shape being clipped.
    fn clipShape(l: *Lower, node: u32, kind: Kind, m: Affine, b: *raster.PathBuilder) Error!void {
        var local: raster.PathBuilder = .init(l.tmp);
        defer local.deinit();
        try l.buildShape(node, kind, &local);
        try b.append(local.path(), m);
    }

    const Filter = union(enum) {
        matrix: ColorStep,
        blur: struct { region: raster.Path, sigma: f32 },
    };

    /// The filter as a color step or a blur, or null when it is one this
    /// renderer does not draw (the element then draws without it).
    fn filterOf(l: *Lower, f: u32, bbox: Rect, m: Affine) Error!?Filter {
        var it = l.doc.children(f);
        var prim: ?u32 = null;
        while (it.next()) |c| {
            if (!std.mem.startsWith(u8, l.doc.nodes[c].name, "fe")) continue;
            if (prim != null) return null;
            prim = c;
        }
        const p = prim orelse return null;
        const pn = &l.doc.nodes[p];
        if (pn.attr("in")) |in| if (!std.mem.eql(u8, in, "SourceGraphic")) return null;
        const ps = try l.computed(p);
        if (std.mem.eql(u8, pn.name, "feColorMatrix")) {
            return .{ .matrix = .{ .matrix = .{ .m = colorMatrix(pn) orelse return null, .linear = ps.filters_linear } } };
        }
        if (std.mem.eql(u8, pn.name, "feGaussianBlur")) {
            var lx: pathdata.Lexer = .{ .s = pn.attr("stdDeviation") orelse "0" };
            const sx = lx.number() orelse 0;
            const sy = lx.number() orelse sx;
            if (sx < 0 or sy < 0) return null;
            var sigma = (sx + sy) / 2;
            const fn_ = &l.doc.nodes[f];
            if (std.mem.eql(u8, fn_.attr("primitiveUnits") orelse "", "objectBoundingBox")) sigma *= (bbox.width() + bbox.height()) / 2;
            const user = std.mem.eql(u8, fn_.attr("filterUnits") orelse "", "userSpaceOnUse");
            const r = try l.region(f, user, bbox, m, -0.1, 1.2);
            if (r.isEmpty()) return null;
            return .{ .blur = .{ .region = r, .sigma = sigma * @sqrt(@abs(m.determinant())) } };
        }
        return null;
    }

    // Paints -----------------------------------------------------------------

    /// Adds the paint `spec` resolves to, or null for none.
    fn paintOf(l: *Lower, node: u32, spec: PaintSpec, st: *const Style, opacity: f32, bbox: Rect, space: Affine) Error!?u32 {
        var p: Paint = switch (spec) {
            .none => return null,
            .color => |t| .{ .kind = .{ .solid = t } },
            .current => .{ .kind = .{ .solid = st.color } },
            .url => |u| blk: {
                if (l.ref(u.id)) |g| {
                    if (try l.gradient(g, bbox, space)) |gp| break :blk gp;
                    // A gradient that cannot paint (no stops, empty box)
                    // paints nothing.
                    const gn = l.doc.nodes[g].name;
                    if (std.mem.eql(u8, gn, "linearGradient") or std.mem.eql(u8, gn, "radialGradient")) return null;
                }
                break :blk switch (u.fallback) {
                    .none => return null,
                    .color => |t| .{ .kind = .{ .solid = t } },
                    .current => .{ .kind = .{ .solid = st.color } },
                };
            },
        };
        if (l.options.symbolic) {
            const prev: Role = switch (p.kind) {
                .solid => |t| t.role,
                else => .none,
            };
            const role = classRole(l.doc.nodes[node].attr("class") orelse "") orelse if (prev != .none) prev else .foreground;
            p = .{ .kind = .{ .solid = .{ .role = role } } };
        }
        p.opacity = opacity;
        p.filter = l.chain;
        switch (p.kind) {
            .solid => |t| if (t.role != .none) {
                l.recolors = true;
            },
            else => for (p.stops) |s| if (s.tint.role != .none) {
                l.recolors = true;
            },
        }
        const index: u32 = @intCast(l.paints.items.len);
        try l.paints.append(l.out, p);
        return index;
    }

    fn gradient(l: *Lower, start: u32, bbox: Rect, space: Affine) Error!?Paint {
        const first = &l.doc.nodes[start];
        const radial = std.mem.eql(u8, first.name, "radialGradient");
        if (!radial and !std.mem.eql(u8, first.name, "linearGradient")) return null;
        // Attributes and stops come from the first gradient in the href
        // chain that has them.
        var chain: [16]u32 = undefined;
        var n: usize = 0;
        var g = start;
        while (n < chain.len) {
            chain[n] = g;
            n += 1;
            const gn = &l.doc.nodes[g];
            const next = l.ref(gn.attr("href") orelse gn.attr("xlink:href") orelse break) orelse break;
            if (std.mem.indexOfScalar(u32, chain[0..n], next) != null) break;
            const nn = l.doc.nodes[next].name;
            if (!std.mem.eql(u8, nn, "linearGradient") and !std.mem.eql(u8, nn, "radialGradient")) break;
            g = next;
        }
        const nodes = chain[0..n];
        const attr = struct {
            fn get(lw: *Lower, ns: []const u32, name: []const u8) ?[]const u8 {
                for (ns) |x| if (lw.doc.nodes[x].attr(name)) |v| return v;
                return null;
            }
        }.get;
        var stops: std.ArrayList(Document.TintStop) = .empty;
        for (nodes) |x| {
            var it = l.doc.children(x);
            var gs: ?Style = null;
            while (it.next()) |c| {
                if (!std.mem.eql(u8, l.doc.nodes[c].name, "stop")) continue;
                if (gs == null) gs = try l.computed(x);
                const ss = try l.cascade(c, &gs.?);
                var off = fraction(l.doc.nodes[c].attr("offset")) orelse 0;
                off = std.math.clamp(off, 0, 1);
                if (stops.items.len > 0) off = @max(off, stops.items[stops.items.len - 1].offset);
                const tint: Tint = switch (ss.stop_color) {
                    .color => |t| t,
                    .current => ss.color,
                };
                try stops.append(l.out, .{ .offset = off, .tint = tint, .opacity = ss.stop_opacity });
            }
            if (stops.items.len != 0) break;
        }
        if (stops.items.len == 0) return null;
        if (stops.items.len == 1) return .{ .kind = .{ .solid = stops.items[0].tint }, .opacity = stops.items[0].opacity };

        const user = std.mem.eql(u8, attr(l, nodes, "gradientUnits") orelse "", "userSpaceOnUse");
        var t: Affine = .identity;
        if (attr(l, nodes, "gradientTransform")) |s| t = pathdata.parseTransform(s) orelse .identity;
        if (!user) {
            if (!(bbox.width() > 0) or !(bbox.height() > 0)) return null;
            t = t.then(bboxMap(bbox));
        }
        const coord = struct {
            fn get(lw: *Lower, ns: []const u32, name: []const u8, is_user: bool, axis: Axis, default: f32) f32 {
                const s = attrOf(lw, ns, name) orelse return default;
                const v = parseLength(s) orelse return default;
                if (!is_user) return if (v.pct) v.v / 100 else v.v;
                return lw.len(v, axis);
            }
            fn attrOf(lw: *Lower, ns: []const u32, name: []const u8) ?[]const u8 {
                for (ns) |x| if (lw.doc.nodes[x].attr(name)) |v| return v;
                return null;
            }
        }.get;
        const half_x: f32 = if (user) l.vw / 2 else 0.5;
        const half_y: f32 = if (user) l.vh / 2 else 0.5;
        const half_d: f32 = if (user) l.len(.{ .v = 50, .pct = true }, .diagonal) else 0.5;
        var p: Paint = .{ .kind = undefined, .stops = stops.items, .transform = t.then(space) };
        if (radial) {
            const cx = coord(l, nodes, "cx", user, .x, half_x);
            const cy = coord(l, nodes, "cy", user, .y, half_y);
            const r = coord(l, nodes, "r", user, .diagonal, half_d);
            var fx = coord(l, nodes, "fx", user, .x, cx);
            var fy = coord(l, nodes, "fy", user, .y, cy);
            const fr = @max(0, coord(l, nodes, "fr", user, .diagonal, 0));
            if (!(r > 0)) return .{ .kind = .{ .solid = stops.items[stops.items.len - 1].tint }, .opacity = stops.items[stops.items.len - 1].opacity };
            // SVG 1.1 moves a focal point outside the circle onto it.
            const dx = fx - cx;
            const dy = fy - cy;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > r * 0.999) {
                fx = cx + dx / d * r * 0.999;
                fy = cy + dy / d * r * 0.999;
            }
            p.kind = .{ .radial = .{ .c0 = .{ .x = fx, .y = fy }, .r0 = fr, .c1 = .{ .x = cx, .y = cy }, .r1 = r } };
        } else {
            const x1 = coord(l, nodes, "x1", user, .x, 0);
            const y1 = coord(l, nodes, "y1", user, .y, 0);
            const x2 = coord(l, nodes, "x2", user, .x, if (user) l.vw else 1);
            const y2 = coord(l, nodes, "y2", user, .y, 0);
            if (x1 == x2 and y1 == y2) return .{ .kind = .{ .solid = stops.items[stops.items.len - 1].tint }, .opacity = stops.items[stops.items.len - 1].opacity };
            p.kind = .{ .linear = .{ .p0 = .{ .x = x1, .y = y1 }, .p1 = .{ .x = x2, .y = y2 } } };
        }
        const spread = attr(l, nodes, "spreadMethod") orelse "pad";
        p.extend = if (std.mem.eql(u8, spread, "reflect")) .reflect else if (std.mem.eql(u8, spread, "repeat")) .repeat else .pad;
        return p;
    }

    // Geometry ---------------------------------------------------------------

    /// An element's bounding box in its user space (`m` maps it there),
    /// for objectBoundingBox units.
    fn bboxOf(l: *Lower, node: u32, m: Affine, depth: u32) Error!Rect {
        if (depth > 16) return Rect.empty;
        const n = &l.doc.nodes[node];
        const kind = kinds.get(n.name) orelse return Rect.empty;
        if (isShape(kind)) {
            var b: raster.PathBuilder = .init(l.tmp);
            defer b.deinit();
            try l.buildShape(node, kind, &b);
            return tightBounds(b.path(), m);
        }
        var r = Rect.empty;
        switch (kind) {
            .use => {
                const target = l.ref(n.attr("href") orelse n.attr("xlink:href") orelse return r) orelse return r;
                const um = Affine.translate(l.attrLen(node, "x", .x, 0), l.attrLen(node, "y", .y, 0)).then(m);
                return l.childBBox(target, um, depth + 1);
            },
            else => {
                var it = l.doc.children(node);
                while (it.next()) |c| r = r.unite(try l.childBBox(c, m, depth + 1));
            },
        }
        return r;
    }

    fn childBBox(l: *Lower, node: u32, m: Affine, depth: u32) Error!Rect {
        const n = &l.doc.nodes[node];
        if (kinds.get(n.name) == null) return Rect.empty;
        if (n.attr("display")) |d| if (std.mem.eql(u8, css.trim(d), "none")) return Rect.empty;
        var cm = m;
        if (n.attr("transform")) |t| if (pathdata.parseTransform(t)) |tm| {
            cm = tm.then(m);
        };
        return l.bboxOf(node, cm, depth);
    }

    fn copyPath(l: *Lower, p: raster.Path, m: Affine) Error!raster.Path {
        l.points += p.points.len;
        if (l.points > l.options.max_points) return error.InvalidSvg;
        const verbs = try l.out.dupe(raster.Verb, p.verbs);
        const pts = try l.out.alloc(Point, p.points.len);
        for (pts, p.points) |*o, q| {
            o.* = m.apply(q);
            if (!std.math.isFinite(o.x) or !std.math.isFinite(o.y)) return .empty;
        }
        return .{ .verbs = verbs, .points = pts };
    }

    fn emit(l: *Lower, op: Op) Error!void {
        if (l.ops.items.len >= l.options.max_ops) return error.InvalidSvg;
        try l.ops.append(l.out, op);
    }

    fn ref(l: *Lower, iri: []const u8) ?u32 {
        const s = css.trim(iri);
        if (s.len < 2 or s[0] != '#') return null;
        return l.ids.get(s[1..]);
    }
};

// Value parsing ---------------------------------------------------------------

fn fieldOf(p: Prop) []const u8 {
    return switch (p) {
        .fill => "fill",
        .@"fill-opacity" => "fill_opacity",
        .@"fill-rule" => "fill_rule",
        .stroke => "stroke",
        .@"stroke-width" => "stroke_width",
        .@"stroke-opacity" => "stroke_opacity",
        .@"stroke-linecap" => "cap",
        .@"stroke-linejoin" => "join",
        .@"stroke-miterlimit" => "miter_limit",
        .@"stroke-dasharray" => "dashes",
        .@"stroke-dashoffset" => "dash_offset",
        .color => "color",
        .visibility => "visible",
        .@"clip-rule" => "clip_rule",
        .@"color-interpolation-filters" => "filters_linear",
        .@"paint-order" => "stroke_first",
        .opacity => "opacity",
        .display => "display",
        .@"clip-path" => "clip_path",
        .mask => "mask",
        .filter => "filter",
        .@"stop-color" => "stop_color",
        .@"stop-opacity" => "stop_opacity",
        .@"mix-blend-mode" => "blend",
        .isolation => "isolate",
        .@"mask-type" => "mask_alpha",
    };
}

fn parsePaint(value: []const u8, role: Role) ?PaintSpec {
    const v = css.trim(value);
    if (std.mem.eql(u8, v, "none")) return .none;
    if (std.mem.eql(u8, v, "currentColor")) return .current;
    if (std.mem.startsWith(u8, v, "url(")) {
        const close = std.mem.indexOfScalar(u8, v, ')') orelse return null;
        var id = css.trim(v[4..close]);
        if (id.len >= 2 and (id[0] == '"' or id[0] == '\'') and id[id.len - 1] == id[0]) id = id[1 .. id.len - 1];
        const rest = css.trim(v[close + 1 ..]);
        var fallback: PaintSpec.Fallback = .none;
        if (std.mem.eql(u8, rest, "currentColor")) {
            fallback = .current;
        } else if (colors_mod.parse(rest)) |c| fallback = .{ .color = .{ .rgba = c, .role = role } };
        return .{ .url = .{ .id = id, .fallback = fallback } };
    }
    const c = colors_mod.parse(v) orelse return null;
    return .{ .color = .{ .rgba = c, .role = role } };
}

fn parseUrl(value: []const u8) ?[]const u8 {
    const v = css.trim(value);
    if (!std.mem.startsWith(u8, v, "url(")) return null;
    const close = std.mem.indexOfScalar(u8, v, ')') orelse return null;
    var id = css.trim(v[4..close]);
    if (id.len >= 2 and (id[0] == '"' or id[0] == '\'') and id[id.len - 1] == id[0]) id = id[1 .. id.len - 1];
    return id;
}

fn parseNumber(s: []const u8) ?f32 {
    var lx: pathdata.Lexer = .{ .s = s };
    const v = lx.number() orelse return null;
    if (!lx.atEnd()) return null;
    return v;
}

fn parseOpacity(s: []const u8) ?f32 {
    const t = css.trim(s);
    if (t.len > 0 and t[t.len - 1] == '%') return std.math.clamp((parseNumber(t[0 .. t.len - 1]) orelse return null) / 100, 0, 1);
    return std.math.clamp(parseNumber(t) orelse return null, 0, 1);
}

fn parseRule(s: []const u8) ?scene.FillRule {
    if (std.mem.eql(u8, s, "nonzero")) return .nonzero;
    if (std.mem.eql(u8, s, "evenodd")) return .even_odd;
    return null;
}

/// A length in user units, or a percentage left for the viewport.
pub fn parseLength(s: []const u8) ?Length {
    var lx: pathdata.Lexer = .{ .s = s };
    const v = lx.number() orelse return null;
    const unit = css.trim(lx.s[lx.i..]);
    const k: f32 = if (unit.len == 0 or std.mem.eql(u8, unit, "px"))
        1
    else if (std.mem.eql(u8, unit, "%"))
        return .{ .v = v, .pct = true }
    else if (std.mem.eql(u8, unit, "pt"))
        4.0 / 3.0
    else if (std.mem.eql(u8, unit, "pc"))
        16
    else if (std.mem.eql(u8, unit, "mm"))
        96.0 / 25.4
    else if (std.mem.eql(u8, unit, "cm"))
        96.0 / 2.54
    else if (std.mem.eql(u8, unit, "in"))
        96
    else if (std.mem.eql(u8, unit, "em"))
        16
    else if (std.mem.eql(u8, unit, "ex"))
        8
    else
        return null;
    return .{ .v = v * k };
}

/// A number or percentage as a fraction ("50%" and "0.5" are 0.5).
fn fraction(s: ?[]const u8) ?f32 {
    const v = parseLength(s orelse return null) orelse return null;
    return if (v.pct) v.v / 100 else v.v;
}

fn parseDashes(a: std.mem.Allocator, s: []const u8) ?[]const Length {
    const t = css.trim(s);
    if (std.mem.eql(u8, t, "none")) return &.{};
    var buf: [32]Length = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, t, " ,\t\r\n");
    while (it.next()) |tok| {
        if (n == buf.len / 2) return null;
        const v = parseLength(tok) orelse return null;
        if (v.v < 0) return null;
        buf[n] = v;
        n += 1;
    }
    if (n == 0) return &.{};
    // An odd list repeats to make an even one.
    if (n % 2 == 1) {
        @memcpy(buf[n .. 2 * n], buf[0..n]);
        n *= 2;
    }
    return a.dupe(Length, buf[0..n]) catch null;
}

fn parseAspect(s: []const u8) Document.Aspect {
    var a: Document.Aspect = .{};
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n,");
    var tok = it.next() orelse return a;
    if (std.mem.eql(u8, tok, "defer")) tok = it.next() orelse return a;
    if (std.mem.eql(u8, tok, "none")) {
        a.none = true;
    } else if (tok.len == 8 and tok[0] == 'x' and tok[4] == 'Y') {
        a.align_x = alignOf(tok[1..4]) orelse return .{};
        a.align_y = alignOf(tok[5..8]) orelse return .{};
    } else return a;
    if (it.next()) |ms| a.slice = std.mem.eql(u8, ms, "slice");
    return a;
}

fn alignOf(s: []const u8) ?Document.Aspect.Align {
    if (std.mem.eql(u8, s, "Min")) return .min;
    if (std.mem.eql(u8, s, "Mid")) return .mid;
    if (std.mem.eql(u8, s, "Max")) return .max;
    return null;
}

fn viewBoxOf(n: *const xml.Node) ?Rect {
    var lx: pathdata.Lexer = .{ .s = n.attr("viewBox") orelse return null };
    const x = lx.number() orelse return null;
    const y = lx.number() orelse return null;
    const w = lx.number() orelse return null;
    const h = lx.number() orelse return null;
    if (!(w > 0) or !(h > 0)) return null;
    return .xywh(x, y, w, h);
}

fn mapBox(vb: Rect, dst: Rect, aspect: Document.Aspect) Affine {
    var sx = dst.width() / vb.width();
    var sy = dst.height() / vb.height();
    if (!aspect.none) {
        const s = if (aspect.slice) @max(sx, sy) else @min(sx, sy);
        sx = s;
        sy = s;
    }
    const fx = dst.width() - vb.width() * sx;
    const fy = dst.height() - vb.height() * sy;
    const ox: f32 = if (aspect.none) 0 else switch (aspect.align_x) {
        .min => 0,
        .mid => fx / 2,
        .max => fx,
    };
    const oy: f32 = if (aspect.none) 0 else switch (aspect.align_y) {
        .min => 0,
        .mid => fy / 2,
        .max => fy,
    };
    return Affine.translate(-vb.x0, -vb.y0).then(.scale(sx, sy)).then(.translate(dst.x0 + ox, dst.y0 + oy));
}

fn bboxMap(b: Rect) Affine {
    return .{ .a = b.width(), .d = b.height(), .e = b.x0, .f = b.y0 };
}

fn blendMode(s: []const u8) ?scene.BlendMode {
    const map: std.StaticStringMap(scene.BlendMode) = .initComptime(.{
        .{ "normal", .src_over },          .{ "multiply", .multiply },     .{ "screen", .screen },
        .{ "overlay", .overlay },          .{ "darken", .darken },         .{ "lighten", .lighten },
        .{ "color-dodge", .color_dodge },  .{ "color-burn", .color_burn }, .{ "hard-light", .hard_light },
        .{ "soft-light", .soft_light },    .{ "difference", .difference }, .{ "exclusion", .exclusion },
        .{ "hue", .hue },                  .{ "saturation", .saturation }, .{ "color", .color },
        .{ "luminosity", .luminosity },    .{ "plus-lighter", .plus },
    });
    return map.get(s);
}

/// The role of a GTK symbolic class on an element.
fn classRole(classes: []const u8) ?Role {
    if (css.hasClass(classes, "success")) return .success;
    if (css.hasClass(classes, "warning")) return .warning;
    if (css.hasClass(classes, "error")) return .@"error";
    return null;
}

/// KDE's color scheme classes (KIconLoader replaces the colors of the
/// rules for them with the palette's).
fn ruleRole(sel: css.Selector) Role {
    if (sel.compounds.len != 1) return .none;
    const c = sel.compounds[0];
    if (c.tag != null or c.id != null or c.classes.len != 1) return .none;
    const name = c.classes[0];
    const prefix = "ColorScheme-";
    if (!std.mem.startsWith(u8, name, prefix)) return .none;
    const k = name[prefix.len..];
    const map: std.StaticStringMap(Role) = .initComptime(.{
        .{ "Text", .foreground },                   .{ "ViewText", .foreground },
        .{ "ButtonText", .foreground },             .{ "WindowText", .foreground },
        .{ "HeaderText", .foreground },             .{ "Background", .background },
        .{ "ViewBackground", .background },         .{ "ButtonBackground", .background },
        .{ "WindowBackground", .background },       .{ "HeaderBackground", .background },
        .{ "Highlight", .accent },                  .{ "ViewHover", .accent },
        .{ "ViewFocus", .accent },                  .{ "ButtonHover", .accent },
        .{ "ButtonFocus", .accent },                .{ "DecorationFocus", .accent },
        .{ "DecorationHover", .accent },            .{ "ActiveText", .accent },
        .{ "LinkText", .accent },                   .{ "HighlightedText", .accent_foreground },
        .{ "PositiveText", .success },              .{ "NeutralText", .warning },
        .{ "NegativeText", .@"error" },
    });
    return map.get(k) orelse .none;
}

fn colorMatrix(n: *const xml.Node) ?[20]f32 {
    const ty = n.attr("type") orelse "matrix";
    const values = n.attr("values");
    var m: [20]f32 = .{ 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    if (std.mem.eql(u8, ty, "matrix")) {
        const v = values orelse return m;
        var lx: pathdata.Lexer = .{ .s = v };
        for (&m) |*x| x.* = lx.number() orelse return null;
        return m;
    }
    if (std.mem.eql(u8, ty, "saturate")) {
        var lx: pathdata.Lexer = .{ .s = values orelse "1" };
        const s = lx.number() orelse return null;
        return .{
            0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0,
            0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
            0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
            0,                 0,                 0,                 1, 0,
        };
    }
    if (std.mem.eql(u8, ty, "hueRotate")) {
        var lx: pathdata.Lexer = .{ .s = values orelse "0" };
        const a = (lx.number() orelse return null) * std.math.pi / 180;
        const c = @cos(a);
        const s = @sin(a);
        return .{
            0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
            0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
            0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
            0,                             0,                             0,                             1, 0,
        };
    }
    if (std.mem.eql(u8, ty, "luminanceToAlpha")) {
        return .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.2125, 0.7154, 0.0721, 0, 0 };
    }
    return null;
}

fn isSimilarity(m: Affine) bool {
    const eps = 1e-4 * @max(@abs(m.a) + @abs(m.b), @abs(m.c) + @abs(m.d));
    return (@abs(m.a - m.d) <= eps and @abs(m.b + m.c) <= eps) or (@abs(m.a + m.d) <= eps and @abs(m.b - m.c) <= eps);
}

/// The tight bounds of a path after `m`: end points and the extrema of
/// curves, not their control points (objectBoundingBox needs the shape's
/// geometric box).
pub fn tightBounds(p: raster.Path, m: Affine) Rect {
    var r = Rect.empty;
    var cur: Point = .zero;
    var it = p.iterator();
    while (it.next()) |seg| switch (seg) {
        .move, .line => |q| {
            cur = m.apply(q);
            r = r.includePoint(cur);
        },
        .quad => |q| {
            const c = m.apply(q[0]);
            const e = m.apply(q[1]);
            r = r.includePoint(e);
            inline for (.{ "x", "y" }) |ax| {
                const den = @field(cur, ax) - 2 * @field(c, ax) + @field(e, ax);
                if (den != 0) {
                    const t = (@field(cur, ax) - @field(c, ax)) / den;
                    if (t > 0 and t < 1) r = r.includePoint(quadAt(cur, c, e, t));
                }
            }
            cur = e;
        },
        .cubic => |q| {
            const c1 = m.apply(q[0]);
            const c2 = m.apply(q[1]);
            const e = m.apply(q[2]);
            r = r.includePoint(e);
            inline for (.{ "x", "y" }) |ax| {
                const p0 = @field(cur, ax);
                const p1 = @field(c1, ax);
                const p2 = @field(c2, ax);
                const p3 = @field(e, ax);
                // Roots of the derivative a t² + b t + c.
                const a = -p0 + 3 * p1 - 3 * p2 + p3;
                const b = 2 * (p0 - 2 * p1 + p2);
                const c = p1 - p0;
                var ts: [2]f32 = undefined;
                var nt: usize = 0;
                if (@abs(a) < 1e-9) {
                    if (b != 0) {
                        ts[0] = -c / b;
                        nt = 1;
                    }
                } else {
                    const disc = b * b - 4 * a * c;
                    if (disc >= 0) {
                        const sq = @sqrt(disc);
                        ts = .{ (-b + sq) / (2 * a), (-b - sq) / (2 * a) };
                        nt = 2;
                    }
                }
                for (ts[0..nt]) |t| if (t > 0 and t < 1) {
                    r = r.includePoint(cubicAt(cur, c1, c2, e, t));
                };
            }
            cur = e;
        },
        .close => {},
    };
    return r;
}

fn quadAt(a: Point, b: Point, c: Point, t: f32) Point {
    return a.lerp(b, t).lerp(b.lerp(c, t), t);
}

fn cubicAt(a: Point, b: Point, c: Point, d: Point, t: f32) Point {
    const ab = a.lerp(b, t);
    const bc = b.lerp(c, t);
    const cd = c.lerp(d, t);
    return ab.lerp(bc, t).lerp(bc.lerp(cd, t), t);
}
