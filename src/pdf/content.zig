//! Lowering display lists to PDF content streams (D9). The list's stack
//! form maps directly: a layer is q/Q with its transform (cm) and clip
//! (W n); a layer with opacity, a blend mode, or isolation is a
//! transparency group (a form XObject drawn through an ExtGState). Fills
//! and strokes are paths painted with colors or shadings, glyph runs are
//! text in embedded font subsets, images are image XObjects, and box
//! shadows are images of their alpha. Backdrop blurs have no PDF
//! equivalent and are left out.
//!
//! Coordinates stay those of the list (the page's content stream starts
//! with a y flip), so nothing is transformed on the way except text and
//! images, which are drawn upright with a local flip.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scene = @import("scene");
const raster = @import("raster");
const Writer = @import("Writer.zig");
const shading = @import("shading.zig");
const image = @import("image.zig");

const Rect = raster.Rect;
const Point = raster.Point;
const Affine = raster.Affine;

/// A number as PDF writes it: decimal, no exponent, at most four
/// fractional digits.
pub const Num = struct {
    v: f32,

    pub fn format(n: Num, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var v: f64 = n.v;
        if (!std.math.isFinite(v)) v = 0;
        v = std.math.clamp(v, -3e7, 3e7);
        var buf: [48]u8 = undefined;
        var s: []const u8 = std.fmt.bufPrint(&buf, "{d:.4}", .{v}) catch unreachable;
        if (std.mem.indexOfScalar(u8, s, '.')) |_| {
            s = std.mem.trimEnd(u8, s, "0");
            s = std.mem.trimEnd(u8, s, ".");
        }
        if (std.mem.eql(u8, s, "-0") or s.len == 0) s = "0";
        try w.writeAll(s);
    }
};

pub fn num(v: f32) Num {
    return .{ .v = v };
}

/// A PDF text string: literal when printable ASCII, else UTF-16BE hex.
pub fn textString(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const ascii = for (s) |c| {
        if (c < 0x20 or c > 0x7e) break false;
    } else true;
    if (ascii) {
        try out.append(gpa, '(');
        for (s) |c| {
            if (c == '(' or c == ')' or c == '\\') try out.append(gpa, '\\');
            try out.append(gpa, c);
        }
        try out.append(gpa, ')');
        return;
    }
    try out.appendSlice(gpa, "<FEFF");
    try utf16Hex(gpa, out, s);
    try out.append(gpa, '>');
}

/// UTF-8 as UTF-16BE hex digits; invalid sequences become U+FFFD.
pub fn utf16Hex(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    if (!std.unicode.utf8ValidateSlice(s)) {
        try out.appendSlice(gpa, "FFFD");
        return;
    }
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try out.print(gpa, "{X:0>4}{X:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3ff) });
        } else try out.print(gpa, "{X:0>4}", .{cp});
    }
}

/// Resources a content stream uses, named after their object numbers.
pub const Resources = struct {
    gpa: Allocator,
    states: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    xobjects: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    shadings: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    fonts: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(r: *Resources) void {
        r.states.deinit(r.gpa);
        r.xobjects.deinit(r.gpa);
        r.shadings.deinit(r.gpa);
        r.fonts.deinit(r.gpa);
    }

    pub fn write(r: *const Resources, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        try out.appendSlice(gpa, "<<");
        const kinds = [_]struct { []const u8, []const u8, *const std.AutoArrayHashMapUnmanaged(u32, void) }{
            .{ "ExtGState", "G", &r.states },
            .{ "XObject", "X", &r.xobjects },
            .{ "Shading", "S", &r.shadings },
            .{ "Font", "F", &r.fonts },
        };
        for (kinds) |k| {
            if (k[2].count() == 0) continue;
            try out.print(gpa, " /{s} <<", .{k[0]});
            for (k[2].keys()) |n| try out.print(gpa, " /{s}{d} {d} 0 R", .{ k[1], n, n });
            try out.appendSlice(gpa, " >>");
        }
        try out.appendSlice(gpa, " >>");
    }
};

pub const Error = Writer.Error;

pub const Content = struct {
    w: *Writer,
    out: std.ArrayList(u8) = .empty,
    res: Resources,

    pub fn init(w: *Writer) Content {
        return .{ .w = w, .res = .{ .gpa = w.gpa } };
    }

    pub fn deinit(c: *Content) void {
        c.out.deinit(c.w.gpa);
        c.res.deinit();
    }

    pub fn print(c: *Content, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try c.out.print(c.w.gpa, fmt, args);
    }

    pub fn useState(c: *Content, body: []const u8) Allocator.Error!void {
        const n = try c.w.state(body);
        try c.res.states.put(c.w.gpa, n, {});
        try c.print("/G{d} gs\n", .{n});
    }

    pub fn useXObject(c: *Content, n: u32) Allocator.Error!void {
        try c.res.xobjects.put(c.w.gpa, n, {});
        try c.print("/X{d} Do\n", .{n});
    }

    pub fn useShading(c: *Content, n: u32) Allocator.Error!void {
        try c.res.shadings.put(c.w.gpa, n, {});
        try c.print("/S{d} sh\n", .{n});
    }

    pub fn matrix(c: *Content, m: Affine) Allocator.Error!void {
        if (m.a == 1 and m.b == 0 and m.c == 0 and m.d == 1 and m.e == 0 and m.f == 0) return;
        try c.print("{f} {f} {f} {f} {f} {f} cm\n", .{ num(m.a), num(m.b), num(m.c), num(m.d), num(m.e), num(m.f) });
    }

    /// Lowers commands. `box` bounds what is visible, in the current
    /// coordinates, for layers whose bounds are unbounded.
    pub fn lower(c: *Content, cmds: []const scene.Command, box: Rect) Error!void {
        var i: usize = 0;
        while (i < cmds.len) {
            switch (cmds[i]) {
                .push => |p| {
                    const inner = cmds[i + 1 .. p.end];
                    try c.layer(p, inner, box);
                    i = p.end + 1;
                    continue;
                },
                .pop => {},
                .fill => |f| try c.fill(f.shape, f.rule, f.paint),
                .stroke => |s| try c.stroke(s),
                .glyphs => |g| try c.w.fonts.lowerRun(c, g),
                .image => |im| try image.draw(c, im),
                .shadow => |s| try image.shadow(c, s),
                // A screen effect with no PDF equivalent (D9).
                .backdrop_blur => {},
            }
            i += 1;
        }
    }

    fn layer(c: *Content, p: scene.Push, inner: []const scene.Command, box: Rect) Error!void {
        const l = p.layer;
        // A layer composited with dst shows nothing of itself.
        if (l.blend == .dst) return;
        try c.print("q\n", .{});
        try c.matrix(l.transform);
        // What is visible, in the layer's coordinates.
        var visible = if (l.transform.invert()) |inv| transformRect(box, inv) else box;
        if (l.clip) |clip| {
            try c.path(clip.shape);
            try c.print("{s} n\n", .{if (clip.rule == .even_odd) "W*" else "W"});
            visible = visible.intersect(clip.shape.bounds());
        }
        if (!l.isIsolated()) {
            try c.lower(inner, visible);
            try c.print("Q\n", .{});
            return;
        }
        // A transparency group: drawn as a whole with the layer's opacity
        // and blend mode, isolated from what is below it.
        var bbox = p.bounds;
        if (!std.math.isFinite(bbox.x0) or !std.math.isFinite(bbox.x1) or !std.math.isFinite(bbox.y0) or !std.math.isFinite(bbox.y1)) bbox = visible;
        bbox = bbox.intersect(visible);
        if (bbox.isEmpty()) {
            try c.print("Q\n", .{});
            return;
        }
        const group = try c.form(inner, bbox, true);
        var gs: [64]u8 = undefined;
        try c.useState(std.fmt.bufPrint(&gs, "/ca {f} /CA {f} /BM /{s}", .{ num(l.opacity), num(l.opacity), blendName(l.blend) }) catch unreachable);
        try c.useXObject(group);
        try c.print("Q\n", .{});
    }

    /// A form XObject drawing `cmds` in the current coordinates, as a
    /// transparency group (isolated) when `group`.
    pub fn form(c: *Content, cmds: []const scene.Command, bbox: Rect, group: bool) Error!u32 {
        var sub: Content = .init(c.w);
        defer sub.deinit();
        try sub.lower(cmds, bbox);
        return sub.finishForm(bbox, if (group) "/Group << /S /Transparency /CS /DeviceRGB /I true >>" else "");
    }

    /// Writes this content as a form XObject with `extra` dict entries.
    pub fn finishForm(c: *Content, bbox: Rect, extra: []const u8) Error!u32 {
        const gpa = c.w.gpa;
        var dict: std.ArrayList(u8) = .empty;
        defer dict.deinit(gpa);
        try dict.print(gpa, "/Type /XObject /Subtype /Form /BBox [{f} {f} {f} {f}] {s} /Resources ", .{ num(bbox.x0), num(bbox.y0), num(bbox.x1), num(bbox.y1), extra });
        try c.res.write(gpa, &dict);
        return c.w.addStream(dict.items, c.out.items);
    }

    /// Writes a shape as a path.
    pub fn path(c: *Content, shape: scene.Shape) Allocator.Error!void {
        switch (shape) {
            .rect => |r| try c.print("{f} {f} {f} {f} re\n", .{ num(r.x0), num(r.y0), num(r.x1 - r.x0), num(r.y1 - r.y0) }),
            else => {
                var b: raster.PathBuilder = .init(c.w.gpa);
                defer b.deinit();
                try shape.toPath(&b);
                try c.rawPath(b.path());
            },
        }
    }

    pub fn rawPath(c: *Content, p: raster.Path) Allocator.Error!void {
        var pi: usize = 0;
        var cur: Point = .zero;
        for (p.verbs) |v| {
            const pts = p.points[pi..][0..v.pointCount()];
            pi += pts.len;
            switch (v) {
                .move => try c.print("{f} {f} m\n", .{ num(pts[0].x), num(pts[0].y) }),
                .line => try c.print("{f} {f} l\n", .{ num(pts[0].x), num(pts[0].y) }),
                .quad => {
                    // Elevated to a cubic.
                    const c1: Point = .{ .x = cur.x + 2.0 / 3.0 * (pts[0].x - cur.x), .y = cur.y + 2.0 / 3.0 * (pts[0].y - cur.y) };
                    const c2: Point = .{ .x = pts[1].x + 2.0 / 3.0 * (pts[0].x - pts[1].x), .y = pts[1].y + 2.0 / 3.0 * (pts[0].y - pts[1].y) };
                    try c.print("{f} {f} {f} {f} {f} {f} c\n", .{ num(c1.x), num(c1.y), num(c2.x), num(c2.y), num(pts[1].x), num(pts[1].y) });
                },
                .cubic => try c.print("{f} {f} {f} {f} {f} {f} c\n", .{ num(pts[0].x), num(pts[0].y), num(pts[1].x), num(pts[1].y), num(pts[2].x), num(pts[2].y) }),
                .close => try c.print("h\n", .{}),
            }
            if (pts.len > 0) cur = pts[pts.len - 1];
        }
    }

    /// Sets the fill (or stroke) color and alpha for a solid color.
    pub fn color(c: *Content, col: scene.Color, comptime stroking: bool) Allocator.Error!void {
        const r = scene.linearToSrgb(std.math.clamp(col.r, 0, 1));
        const g = scene.linearToSrgb(std.math.clamp(col.g, 0, 1));
        const b = scene.linearToSrgb(std.math.clamp(col.b, 0, 1));
        try c.print("{f} {f} {f} {s}\n", .{ num(r), num(g), num(b), if (stroking) "RG" else "rg" });
        if (col.a < 1) {
            var gs: [32]u8 = undefined;
            try c.useState(std.fmt.bufPrint(&gs, "/{s} {f}", .{ if (stroking) "CA" else "ca", num(std.math.clamp(col.a, 0, 1)) }) catch unreachable);
        }
    }

    pub fn fill(c: *Content, shape: scene.Shape, rule: scene.FillRule, paint: scene.Paint) Error!void {
        if (paint.isInvisible()) return;
        switch (paint) {
            .solid => |col| {
                try c.print("q\n", .{});
                try c.color(col, false);
                try c.path(shape);
                try c.print("{s}\nQ\n", .{if (rule == .even_odd) "f*" else "f"});
            },
            .gradient => |g| {
                try c.print("q\n", .{});
                try c.path(shape);
                try c.print("{s} n\n", .{if (rule == .even_odd) "W*" else "W"});
                try shading.paint(c, g, shape.bounds());
                try c.print("Q\n", .{});
            },
        }
    }

    fn stroke(c: *Content, s: scene.Stroke) Error!void {
        if (s.paint.isInvisible() or !(s.style.width > 0)) return;
        switch (s.paint) {
            .solid => |col| {
                try c.print("q\n", .{});
                try c.color(col, true);
                try c.strokeStyle(s.style);
                try c.path(s.shape);
                try c.print("S\nQ\n", .{});
            },
            .gradient => |g| {
                // The outline as a clip, then the shading.
                var outline: raster.PathBuilder = .init(c.w.gpa);
                defer outline.deinit();
                var src: raster.PathBuilder = .init(c.w.gpa);
                defer src.deinit();
                try s.shape.toPath(&src);
                var stroker: raster.Stroker = .init(c.w.gpa);
                defer stroker.deinit();
                try stroker.stroke(src.path(), s.style, 0.05, &outline);
                if (outline.path().isEmpty()) return;
                try c.print("q\n", .{});
                try c.rawPath(outline.path());
                try c.print("W n\n", .{});
                try shading.paint(c, g, s.shape.bounds().outset(s.style.outset()));
                try c.print("Q\n", .{});
            },
        }
    }

    fn strokeStyle(c: *Content, st: scene.StrokeStyle) Allocator.Error!void {
        try c.print("{f} w {d} J {d} j {f} M\n", .{
            num(st.width),
            @as(u8, switch (st.cap) {
                .butt => 0,
                .round => 1,
                .square => 2,
            }),
            @as(u8, switch (st.join) {
                .miter => 0,
                .round => 1,
                .bevel => 2,
            }),
            num(@max(st.miter_limit, 1)),
        });
        if (solidDashes(st.dashes)) return;
        try c.print("[", .{});
        // An odd count repeats once (SVG), which PDF does by itself.
        for (st.dashes, 0..) |d, i| try c.print("{s}{f}", .{ if (i == 0) "" else " ", num(d) });
        try c.print("] {f} d\n", .{num(st.dash_offset)});
    }
};

fn solidDashes(dashes: []const f32) bool {
    if (dashes.len == 0) return true;
    var sum: f32 = 0;
    for (dashes) |d| {
        if (d < 0) return true;
        sum += d;
    }
    return sum == 0;
}

/// The PDF blend mode for a layer. PDF has no Porter-Duff operators
/// besides source-over, so those composite as source-over.
fn blendName(m: scene.BlendMode) []const u8 {
    return switch (m) {
        .multiply => "Multiply",
        .screen => "Screen",
        .overlay => "Overlay",
        .darken => "Darken",
        .lighten => "Lighten",
        .color_dodge => "ColorDodge",
        .color_burn => "ColorBurn",
        .hard_light => "HardLight",
        .soft_light => "SoftLight",
        .difference => "Difference",
        .exclusion => "Exclusion",
        .hue => "Hue",
        .saturation => "Saturation",
        .color => "Color",
        .luminosity => "Luminosity",
        else => "Normal",
    };
}

pub fn transformRect(r: Rect, m: Affine) Rect {
    var out = Rect.empty;
    for ([_]Point{ .{ .x = r.x0, .y = r.y0 }, .{ .x = r.x1, .y = r.y0 }, .{ .x = r.x0, .y = r.y1 }, .{ .x = r.x1, .y = r.y1 } }) |p| out = out.includePoint(m.apply(p));
    return out;
}

test "numbers have no exponent and no trailing zeros" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1.5 0 -2 -0.0625 0", std.fmt.bufPrint(&buf, "{f} {f} {f} {f} {f}", .{ num(1.5), num(0), num(-2), num(-0.0625), num(-1e-9) }) catch unreachable);
    var big: [64]u8 = undefined;
    try std.testing.expectEqualStrings("30000000", std.fmt.bufPrint(&big, "{f}", .{num(1e20)}) catch unreachable);
}

test "text strings escape or switch to UTF-16" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try textString(gpa, &out, "a(b)\\");
    try out.append(gpa, ' ');
    try textString(gpa, &out, "é😀");
    try std.testing.expectEqualStrings("(a\\(b\\)\\\\) <FEFF00E9D83DDE00>", out.items);
}
