//! A document: parsed, styled, laid out, and painted. One thread at a
//! time works on it (the application's thread between worker jobs, a
//! worker during one, D32); nothing here fetches: the document lists the
//! resources it wants (`resources`), and the owner supplies their bytes.

const std = @import("std");
const html = @import("html");
const css = @import("css");
const text = @import("text");
const scene = @import("scene");
const raster = @import("raster");
const svg = @import("svg");
const cascade_mod = @import("cascade.zig");
const box_mod = @import("box.zig");
const layout_mod = @import("layout.zig");
const inline_mod = @import("inline.zig");
const paint_mod = @import("paint.zig");
const ua = @import("ua.zig");
const url_mod = @import("url.zig");
const email = @import("email.zig");
pub const markdown = @import("markdown");

const Document = @This();
const Allocator = std.mem.Allocator;
const NodeId = html.NodeId;
const BoxId = box_mod.BoxId;
const none = box_mod.none;
pub const Error = error{OutOfMemory};

pub const Kind = enum { html, markdown, text };

pub const Options = struct {
    kind: Kind = .html,
    /// Where relative URLs resolve from.
    base_url: []const u8 = "",
    /// A charset from outside (an email part's Content-Type).
    charset: []const u8 = "",
    /// XHTML (self-closing tags end their elements); null: when the
    /// source starts with an XML declaration.
    xml: ?bool = null,
    /// A user stylesheet the application adds (its own document style).
    user_css: []const u8 = "",
    /// The user's default font size (CSS `medium`).
    font_size: f32 = 16,
    /// Remote images, style sheets, and fonts (http, https) are listed as
    /// resources only when allowed; blocked ones count in
    /// `blocked_images`.
    remote_images: bool = true,
    /// Author styles (<style>, style attributes, linked sheets) apply.
    author_styles: bool = true,
    /// Untrusted HTML (email): scripts, embedded content, active link
    /// schemes, and `<base>` are dropped, and nothing is positioned.
    untrusted: bool = false,
    /// Quoted replies are collapsed behind a toggle link (`siv:quote/N`).
    collapse_quotes: bool = false,
};

pub const Resource = struct {
    url: []const u8,
    kind: enum(u8) { stylesheet, image, font },
    state: enum(u8) { wanted, loading, ready, failed } = .wanted,
    /// Images: natural size once known; the owner's handle for drawing.
    width: f32 = 0,
    height: f32 = 0,
    handle: u64 = 0,
    /// An SVG image, parsed by the document, and a font for each of its
    /// text ops (`resolveSvgFonts`).
    svg_doc: ?*svg.Document = null,
    svg_fonts: []?text.FontId = &.{},
    /// Stylesheets: the parsed sheet (and which origin).
    sheet: ?*css.Sheet = null,
    /// Fonts: the faces added to the font cache, and their @font-face.
    face: ?text.FontId = null,
    font_face: ?*const css.sheet.FontFace = null,
};

/// Resolves font families to fallback chains (the application's font
/// configuration) on the thread that owns it.
pub const FontResolver = struct {
    ctx: *anyopaque,
    cache: *text.FontCache,
    /// A chain for one family name ("serif", "Georgia", ...).
    chainFn: *const fn (ctx: *anyopaque, family: []const u8, language: []const u8, weight: u16, italic: bool, stretch: f32, size: f32) Error![]const text.FontId,
};

gpa: Allocator,
arena: std.heap.ArenaAllocator,
options: Options,
base_url: []const u8,
dom: html.Dom,
store: css.style.Store,
/// The user agent's and the user's sheets, then author sheets in order.
sheets: std.ArrayList(SheetRef) = .empty,
ua_sheet: *const css.Sheet,
styles: ?cascade_mod.Result = null,
cascade: ?cascade_mod.Cascade = null,
tree: box_mod.Tree = .{},
engine: ?layout_mod.Engine = null,
/// Per style: its fonts, resolved before layout.
font_table: std.ArrayList(inline_mod.FontInfo) = .empty,
/// The resolver `resolveFonts` last had, for SVG text that arrives later.
resolver: ?FontResolver = null,
hyphenation: text.hyphen.Hyphenation,
resources: std.ArrayList(Resource) = .empty,
/// Remote images not listed because of the policy.
blocked_images: u32 = 0,
/// Per element: its first box, for hit testing and accessibility.
node_boxes: std.AutoHashMapUnmanaged(u32, BoxId) = .empty,
media: css.media.Env = .{},
title: []const u8 = "",
/// Inline SVG elements parsed into documents, by replaced index.
markers: std.AutoHashMapUnmanaged(u32, *paint_mod.MarkerGlyphs) = .empty,
scratch: std.heap.ArenaAllocator,
/// Bumped when layout changes (positions of anything may move).
generation: u64 = 0,
/// Workers that shape text ahead of layout (D32); null shapes as layout
/// goes, on the calling thread.
executor: ?@import("pool").Executor = null,
/// Quoted replies' wrappers (`email.wrapQuotes`), and which are open.
quotes: []html.NodeId = &.{},
quote_open: std.DynamicBitSetUnmanaged = .{},
/// XHTML: self-closing tags end their elements, and comments in style
/// sheets are comments.
xml: bool = false,
/// The width layout ran at, and whether it finished.
width: f32 = 0,
complete: bool = false,

/// A style sheet in document order: parsed, or a linked one by resource.
const SheetRef = struct { sheet: ?*const css.Sheet, origin: cascade_mod.Origin, owned: bool, link: u32 = none };

/// Parses a document. `ua_sheet` is the shared user-agent sheet
/// (`parseUserAgentSheet`).
pub fn create(gpa: Allocator, bytes: []const u8, options: Options, ua_sheet: *const css.Sheet) Error!*Document {
    const d = try gpa.create(Document);
    errdefer gpa.destroy(d);
    d.* = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .options = options,
        .base_url = "",
        .dom = undefined,
        .store = try css.style.Store.init(gpa),
        .ua_sheet = ua_sheet,
        .hyphenation = .init(gpa),
        .scratch = .init(gpa),
        .xml = options.kind == .html and (options.xml orelse isXml(bytes)),
    };
    errdefer d.store.deinit(gpa);
    const a = d.arena.allocator();
    d.options.user_css = try a.dupe(u8, options.user_css);
    d.base_url = try a.dupe(u8, options.base_url);
    d.dom = switch (options.kind) {
        .html => try html.parse(gpa, bytes, .{ .charset = options.charset, .xml = d.xml }),
        .markdown => try markdown.parse(gpa, bytes, .{}),
        .text => blk: {
            var dom = try html.parse(gpa, "<pre>", .{});
            const pre = dom.childElement(dom.body(), .pre);
            const t = try dom.createText(bytes);
            dom.append(pre, t);
            break :blk dom;
        },
    };
    errdefer d.dom.deinit();
    if (options.untrusted) email.sanitize(&d.dom);
    if (options.collapse_quotes) {
        d.quotes = try email.wrapQuotes(gpa, &d.dom);
        d.quote_open = try .initEmpty(gpa, d.quotes.len);
        if (d.quotes.len > 0) {
            const s = try gpa.create(css.Sheet);
            s.* = try css.sheet.parse(gpa, ua.email_css, .{});
            try d.sheets.append(gpa, .{ .sheet = s, .origin = .user_agent, .owned = true });
        }
    }
    try d.sheets.append(gpa, .{ .sheet = ua_sheet, .origin = .user_agent, .owned = false });
    if (options.kind == .html and d.dom.quirks == .quirks and !d.xml) {
        // Quirks mode (no doctype, as most email has): tables do not
        // inherit text styles (HTML, rendering 15.3.6). XHTML, such as
        // an EPUB chapter, is never in quirks mode, doctype or not.
        const s = try gpa.create(css.Sheet);
        s.* = try css.sheet.parse(gpa, ua.quirks_css, .{});
        try d.sheets.append(gpa, .{ .sheet = s, .origin = .user_agent, .owned = true });
    }
    if (options.kind == .markdown) {
        const s = try gpa.create(css.Sheet);
        s.* = try css.sheet.parse(gpa, ua.markdown_css, .{});
        try d.sheets.append(gpa, .{ .sheet = s, .origin = .user_agent, .owned = true });
    }
    if (d.options.user_css.len > 0) {
        const s = try gpa.create(css.Sheet);
        s.* = try css.sheet.parse(gpa, d.options.user_css, .{});
        try d.sheets.append(gpa, .{ .sheet = s, .origin = .user, .owned = true });
    }
    try d.collect();
    return d;
}

pub fn destroy(d: *Document) void {
    const gpa = d.gpa;
    if (d.engine) |*e| e.deinit();
    if (d.cascade) |*c| c.deinit();
    if (d.styles) |*s| {
        gpa.free(s.styles);
        s.pseudo.deinit(gpa);
    }
    for (d.sheets.items) |s| if (s.owned) {
        @constCast(s.sheet.?).deinit();
        gpa.destroy(@constCast(s.sheet.?));
    };
    d.sheets.deinit(gpa);
    for (d.resources.items) |r| {
        if (r.svg_doc) |s| s.deinit();
        gpa.free(r.svg_fonts);
        if (r.sheet) |s| {
            s.deinit();
            gpa.destroy(s);
        }
    }
    d.resources.deinit(gpa);
    var mit = d.markers.valueIterator();
    while (mit.next()) |m| {
        for (m.*.runs) |r| gpa.free(r.glyphs);
        gpa.free(m.*.runs);
        gpa.destroy(m.*);
    }
    d.markers.deinit(gpa);
    d.node_boxes.deinit(gpa);
    gpa.free(d.quotes);
    d.quote_open.deinit(gpa);
    d.font_table.deinit(gpa);
    d.tree.deinit(gpa);
    d.hyphenation.deinit();
    d.store.deinit(gpa);
    d.dom.deinit();
    d.scratch.deinit();
    d.arena.deinit();
    gpa.destroy(d);
}

/// Parses the user-agent stylesheet (once per application).
pub fn parseUserAgentSheet(gpa: Allocator) Error!css.Sheet {
    return css.sheet.parse(gpa, ua.css, .{});
}

/// Memory the document holds (for budgets and reports).
pub fn memory(d: *const Document) usize {
    var m = d.dom.memory() + d.arena.queryCapacity() + d.store.styles.capacity * @sizeOf(css.Style);
    m += d.tree.boxes.capacity * @sizeOf(box_mod.Box);
    if (d.engine) |e| m += e.cache_bytes;
    return m;
}

fn resolve(d: *Document, ref: []const u8) Error![]const u8 {
    return url_mod.resolve(d.arena.allocator(), d.base_url, ref);
}

fn isRemote(u: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(u, "http:") or std.ascii.startsWithIgnoreCase(u, "https:") or std.mem.startsWith(u8, u, "//");
}

/// Whether a source is an XML document (an XML declaration first).
fn isXml(bytes: []const u8) bool {
    var b = bytes;
    if (std.mem.startsWith(u8, b, "\xef\xbb\xbf")) b = b[3..];
    return std.mem.startsWith(u8, std.mem.trimStart(u8, b, " \t\r\n"), "<?xml");
}

fn addResource(d: *Document, kind: @TypeOf(@as(Resource, undefined).kind), raw: []const u8) Error!?u32 {
    if (raw.len == 0) return null;
    const u = try d.resolve(raw);
    // Remote style sheets and fonts tell a sender as much as images do.
    if (isRemote(u) and !d.options.remote_images) {
        d.blocked_images += 1;
        return null;
    }
    for (d.resources.items, 0..) |r, i| if (r.kind == kind and std.mem.eql(u8, r.url, u)) return @intCast(i);
    try d.resources.append(d.gpa, .{ .url = u, .kind = kind });
    return @intCast(d.resources.items.len - 1);
}

/// Finds `<base>`, `<title>`, `<style>`, linked stylesheets.
fn collect(d: *Document) Error!void {
    const dom = &d.dom;
    var cur = dom.documentElement();
    const root = cur;
    var have_base = false;
    while (cur != .none) : (cur = dom.following(cur, root)) {
        const n = dom.node(cur);
        if (n.kind != .element or n.ns != .html) continue;
        switch (n.name) {
            .base => if (!have_base) if (dom.attr(cur, .href)) |h| {
                d.base_url = try url_mod.resolve(d.arena.allocator(), d.base_url, h);
                have_base = true;
            },
            .title => if (d.title.len == 0) {
                var t: std.ArrayList(u8) = .empty;
                try dom.textContent(d.arena.allocator(), cur, &t);
                d.title = std.mem.trim(u8, t.items, " \t\n\r");
            },
            .style => if (d.options.author_styles) {
                var t: std.ArrayList(u8) = .empty;
                defer t.deinit(d.gpa);
                try dom.textContent(d.gpa, cur, &t);
                // XHTML (e-books, test suites) wraps style sheets in CDATA
                // sections, which an HTML parser keeps as text.
                const trimmed = std.mem.trim(u8, t.items, " \t\r\n");
                if (std.mem.startsWith(u8, trimmed, "<![CDATA[") and std.mem.endsWith(u8, trimmed, "]]>")) {
                    const inner = try d.gpa.dupe(u8, trimmed[9 .. trimmed.len - 3]);
                    t.deinit(d.gpa);
                    t = .fromOwnedSlice(inner);
                }
                // In XML, comments in a style element are comments, not
                // style sheet text (where `<!--` swallows the next rule).
                if (d.xml) while (std.mem.indexOf(u8, t.items, "<!--")) |at| {
                    const end = if (std.mem.indexOfPos(u8, t.items, at + 4, "-->")) |k| k + 3 else t.items.len;
                    t.replaceRangeAssumeCapacity(at, end - at, "");
                };
                const media = dom.attr(cur, .media);
                const s = try d.gpa.create(css.Sheet);
                errdefer d.gpa.destroy(s);
                if (media) |m| {
                    const wrapped = try std.fmt.allocPrint(d.gpa, "@media {s} {{ {s} }}", .{ m, t.items });
                    defer d.gpa.free(wrapped);
                    s.* = try css.sheet.parse(d.gpa, wrapped, .{});
                } else s.* = try css.sheet.parse(d.gpa, t.items, .{});
                try absolutize(s, d.base_url);
                try d.sheets.append(d.gpa, .{ .sheet = s, .origin = .author, .owned = true });
                for (s.imports) |imp| _ = try d.addResource(.stylesheet, imp.url);
            },
            .link => if (d.options.author_styles) {
                const rel = dom.attr(cur, .rel) orelse continue;
                var it = std.mem.tokenizeAny(u8, rel, " \t\n");
                var is_sheet = false;
                var alternate = false;
                while (it.next()) |w| {
                    if (std.ascii.eqlIgnoreCase(w, "stylesheet")) is_sheet = true;
                    if (std.ascii.eqlIgnoreCase(w, "alternate")) alternate = true;
                }
                if (is_sheet and !alternate) if (dom.attr(cur, .href)) |h| {
                    // Its place among the style elements, for the cascade.
                    if (try d.addResource(.stylesheet, h)) |idx| try d.sheets.append(d.gpa, .{ .sheet = null, .origin = .author, .owned = false, .link = idx });
                };
            },
            else => {},
        }
    }
}

/// Supplies a stylesheet's text. Styles must run again afterwards.
pub fn supplyStylesheet(d: *Document, index: u32, bytes: []const u8) Error!void {
    const r = &d.resources.items[index];
    const s = try d.gpa.create(css.Sheet);
    errdefer d.gpa.destroy(s);
    s.* = try css.sheet.parse(d.gpa, bytes, .{});
    try absolutize(s, r.url);
    r.sheet = s;
    r.state = .ready;
    for (s.imports) |imp| {
        // Relative to the sheet's URL.
        const u = try url_mod.resolve(d.arena.allocator(), r.url, imp.url);
        _ = try d.addResource(.stylesheet, u);
    }
}

/// Resolves a sheet's image URLs against the sheet's own URL (CSS Values
/// 4, 4.5.1), so that its relative URLs name the same resources wherever
/// the sheet is used. Style attributes' resolve against the document's
/// base when painted.
fn absolutize(s: *css.Sheet, base: []const u8) Error!void {
    const a = s.arena.allocator();
    for (@constCast(s.decls)) |*decl| switch (decl.value) {
        .image => |maybe| if (maybe) |img| switch (img.*) {
            .url => |u| {
                const abs = try url_mod.resolve(a, base, u);
                if (std.mem.eql(u8, abs, u)) continue;
                const copy = try a.create(css.style.Image);
                copy.* = .{ .url = abs };
                decl.value = .{ .image = copy };
            },
            else => {},
        },
        else => {},
    };
}

pub fn failResource(d: *Document, index: u32) void {
    d.resources.items[index].state = .failed;
}

/// Supplies an image's natural size (decoded by the owner) and its handle.
pub fn supplyImage(d: *Document, index: u32, w: f32, h: f32, handle: u64) void {
    const r = &d.resources.items[index];
    r.width = w;
    r.height = h;
    r.handle = handle;
    r.state = .ready;
    d.applyImageSizes();
}

/// Supplies an SVG image's bytes; the document parses and draws it.
pub fn supplySvg(d: *Document, index: u32, bytes: []const u8) Error!void {
    const r = &d.resources.items[index];
    const doc = svg.parse(d.gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            r.state = .failed;
            return;
        },
    };
    r.svg_doc = doc;
    r.width = doc.width;
    r.height = doc.height;
    r.state = .ready;
    try d.resolveSvgFonts(index);
    d.applyImageSizes();
}

/// Picks a font for each text op of SVG resource `index`: the first face
/// of its family list that has every character, else the first found.
fn resolveSvgFonts(d: *Document, index: u32) Error!void {
    const resolver = d.resolver orelse return;
    const r = &d.resources.items[index];
    const doc = r.svg_doc orelse return;
    var ops: std.ArrayList(*const svg.Document.Text) = .empty;
    defer ops.deinit(d.gpa);
    try doc.texts(&ops, d.gpa);
    if (ops.items.len == 0) return;
    const fonts = try d.gpa.alloc(?text.FontId, ops.items.len);
    errdefer d.gpa.free(fonts);
    var chain: std.ArrayList(text.FontId) = .empty;
    defer chain.deinit(d.gpa);
    for (ops.items, fonts) |t, *font| {
        chain.clearRetainingCapacity();
        var it = std.mem.tokenizeScalar(u8, t.family, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r\n\"'");
            if (name.len == 0) continue;
            const generic = for ([_][]const u8{ "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui" }) |g| {
                if (std.ascii.eqlIgnoreCase(name, g)) break true;
            } else false;
            const found = try resolver.chainFn(resolver.ctx, if (std.ascii.eqlIgnoreCase(name, "system-ui")) "sans-serif" else name, "und", t.weight, t.italic, 100, t.size);
            for (found) |id| if (std.mem.indexOfScalar(text.FontId, chain.items, id) == null) try chain.append(d.gpa, id);
            if (generic) break;
        }
        if (chain.items.len == 0) try chain.appendSlice(d.gpa, try resolver.chainFn(resolver.ctx, "serif", "und", t.weight, t.italic, 100, t.size));
        const cache = resolver.cache;
        cache.lockShared();
        defer cache.unlockShared();
        font.* = if (chain.items.len > 0) chain.items[0] else null;
        for (chain.items) |id| {
            const face = cache.face(id) orelse continue;
            const view = std.unicode.Utf8View.init(t.content) catch break;
            var cps = view.iterator();
            const all = while (cps.nextCodepoint()) |cp| {
                if (cp != ' ' and !face.hasCodepoint(cp)) break false;
            } else true;
            if (all) {
                font.* = id;
                break;
            }
        }
    }
    d.gpa.free(r.svg_fonts);
    r.svg_fonts = fonts;
}

/// Draws SVG resource `index` into `dst`, its text shaped with the fonts
/// `resolveSvgFonts` picked. False if it is not an SVG ready to draw.
pub fn drawSvg(d: *const Document, b: *scene.Builder, index: u32, dst: raster.Rect, cache: *text.FontCache) scene.Error!bool {
    if (index >= d.resources.items.len) return false;
    const r = &d.resources.items[index];
    const doc = r.svg_doc orelse return false;
    if (r.state != .ready) return false;
    var ctx: SvgText = .{ .fonts = r.svg_fonts, .cache = cache };
    try doc.drawWithText(b, dst, null, .{ .ctx = &ctx, .drawFn = SvgText.draw });
    return true;
}

const SvgText = struct {
    fonts: []const ?text.FontId,
    cache: *text.FontCache,

    fn draw(ptr: *anyopaque, b: *scene.Builder, t: *const svg.Document.Text, index: u32, fill: scene.Paint) scene.Error!void {
        const ctx: *SvgText = @ptrCast(@alignCast(ptr));
        if (index >= ctx.fonts.len or !(t.size > 0)) return;
        const face = ctx.cache.face(ctx.fonts[index] orelse return) orelse return;
        const a = std.heap.smp_allocator;
        var shaper = text.shape.Shaper.init() catch return error.OutOfMemory;
        defer shaper.deinit();
        var shaped: std.ArrayList(text.shape.Glyph) = .empty;
        defer shaped.deinit(a);
        const n: u32 = @intCast(@min(t.content.len, 4096));
        shaper.shape(a, .{
            .face = face,
            .size = t.size,
            .text = t.content[0..n],
            .paragraph_start = 0,
            .paragraph_end = n,
            .start = 0,
            .end = n,
            .rtl = false,
            .script = text.script.tag("Latn"),
            .language = null,
        }, &shaped) catch return error.OutOfMemory;
        if (shaped.items.len == 0) return;
        var width: f32 = 0;
        for (shaped.items) |g| width += g.advance;
        // textLength: extra space between glyphs, or the glyphs scaled.
        var gap: f32 = 0;
        var scale: f32 = 1;
        if (t.length > 0 and width > 0) {
            if (t.stretch) scale = t.length / width else if (shaped.items.len > 1) gap = (t.length - width) / @as(f32, @floatFromInt(shaped.items.len - 1));
        }
        const total = if (t.length > 0) t.length else width;
        const x0 = t.x - switch (t.anchor) {
            .start => 0,
            .middle => total / 2,
            .end => total,
        };
        const glyphs = try a.alloc(scene.Glyph, shaped.items.len);
        defer a.free(glyphs);
        var x: f32 = 0;
        for (shaped.items, glyphs) |g, *out| {
            out.* = .{ .id = g.id, .x = x + g.x_offset, .y = g.y_offset };
            x += g.advance + gap;
        }
        try b.pushLayer(.{ .transform = raster.Affine.scale(scale, 1).then(.translate(x0, t.y)) });
        defer b.popLayer() catch {};
        try b.glyphs(.{
            .font = .{ .handle = face.font, .key = face.key },
            .size = t.size,
            .glyphs = glyphs,
            .paint = fill,
            .bounds = .{ .x0 = -t.size, .y0 = -t.size * 1.5, .x1 = x + t.size, .y1 = t.size },
        });
    }
};

/// Supplies a font's bytes for an @font-face source.
pub fn supplyFont(d: *Document, index: u32, cache: *text.FontCache, bytes: []const u8) Error!void {
    const r = &d.resources.items[index];
    const owned = try d.arena.allocator().dupe(u8, bytes);
    const id = cache.add(owned, 0, .borrowed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            r.state = .failed;
            return;
        },
    };
    r.face = id;
    r.state = .ready;
}

fn applyImageSizes(d: *Document) void {
    for (d.tree.replaced.items) |*rep| {
        if (rep.resource == none) continue;
        const r = d.resources.items[rep.resource];
        if (r.state != .ready) continue;
        if (rep.natural_w == 0 and rep.natural_h == 0 or rep.kind == .image) {
            // Attributes set the size; the image sets the ratio.
            const attr_w = rep.natural_w;
            const attr_h = rep.natural_h;
            if (attr_w > 0 and attr_h == 0 and r.width > 0) {
                rep.natural_h = attr_w * r.height / r.width;
            } else if (attr_h > 0 and attr_w == 0 and r.height > 0) {
                rep.natural_w = attr_h * r.width / r.height;
            } else if (attr_w == 0 and attr_h == 0) {
                rep.natural_w = r.width;
                rep.natural_h = r.height;
            }
        }
    }
    if (d.engine) |*e| e.invalidate(true);
    d.complete = false;
}

/// Runs the cascade and builds the box tree (sheets as supplied so far).
pub fn styleAndBuild(d: *Document, media: css.media.Env) Error!void {
    d.media = media;
    if (d.engine) |*e| {
        e.deinit();
        d.engine = null;
    }
    if (d.cascade) |*c| c.deinit();
    if (d.styles) |*s| {
        d.gpa.free(s.styles);
        s.pseudo.deinit(d.gpa);
        d.styles = null;
    }
    d.tree.deinit(d.gpa);
    d.tree = .{};
    d.node_boxes.clearRetainingCapacity();
    const a = d.arena.allocator();
    d.cascade = cascade_mod.Cascade.init(d.gpa, a, &d.dom, &d.store);
    const c = &d.cascade.?;
    c.env = .{ .media = media, .font_size = d.options.font_size, .untrusted = d.options.untrusted };
    try c.prepare();
    // Sheets in document order, each after the sheets it imports (CSS
    // Cascade 4, 6.4); imports found only later go last.
    var added = try std.DynamicBitSetUnmanaged.initEmpty(d.gpa, d.resources.items.len);
    defer added.deinit(d.gpa);
    for (d.sheets.items) |s| {
        if (s.sheet) |sh| {
            try d.addSheetTree(c, sh, d.base_url, s.origin, &added);
        } else if (s.link != none and !added.isSet(s.link)) {
            const r = d.resources.items[s.link];
            added.set(s.link);
            if (r.sheet) |sh| try d.addSheetTree(c, sh, r.url, .author, &added);
        }
    }
    for (d.resources.items, 0..) |r, i| if (r.kind == .stylesheet and !added.isSet(i)) if (r.sheet) |sh| try c.addSheet(sh, .author);
    d.styles = try c.run();
    var closed: std.ArrayList(html.NodeId) = .empty;
    defer closed.deinit(d.gpa);
    for (d.quotes, 0..) |q, k| if (!d.quote_open.isSet(k)) try closed.append(d.gpa, q);
    var b: box_mod.Builder = .{ .gpa = d.gpa, .arena = a, .dom = &d.dom, .styles = &d.styles.?, .store = &d.store, .tree = &d.tree, .skip = closed.items };
    defer b.deinit();
    try b.build();
    for (d.tree.boxes.items, 0..) |bx, i| {
        if (bx.node == .none) continue;
        const gop = try d.node_boxes.getOrPut(d.gpa, bx.node.index());
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }
    try d.linkResources();
}

fn addSheetTree(d: *Document, c: *cascade_mod.Cascade, sheet: *const css.Sheet, base: []const u8, origin: cascade_mod.Origin, added: *std.DynamicBitSetUnmanaged) Error!void {
    for (sheet.imports) |imp| {
        const u = try url_mod.resolve(d.scratch.allocator(), base, imp.url);
        for (d.resources.items, 0..) |r, i| if (r.kind == .stylesheet and !added.isSet(i) and std.mem.eql(u8, r.url, u)) {
            added.set(i);
            if (r.sheet) |sh| try d.addSheetTree(c, sh, r.url, origin, added);
            break;
        };
    }
    try c.addSheet(sheet, origin);
}

/// Lists images and fonts the styled document needs.
fn linkResources(d: *Document) Error!void {
    for (d.tree.replaced.items, 0..) |*rep, i| {
        _ = i;
        if (rep.kind == .image and rep.src.len > 0) {
            if (try d.addResource(.image, rep.src)) |idx| rep.resource = idx;
        }
    }
    // Inline SVG: the element's markup parsed as an SVG document.
    for (d.tree.boxes.items) |bx| {
        if (bx.kind != .replaced) continue;
        const rep = &d.tree.replaced.items[bx.data];
        if (rep.kind != .svg or rep.resource != none) continue;
        var w: std.Io.Writer.Allocating = .init(d.gpa);
        defer w.deinit();
        html.serialize.outer(&d.dom, &w.writer, bx.node) catch return error.OutOfMemory;
        // The parser wants the namespace declared.
        const markup = w.written();
        const fixed = if (std.mem.indexOf(u8, markup, "xmlns=") == null) try std.fmt.allocPrint(d.gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\"{s}", .{markup[4..]}) else try d.gpa.dupe(u8, markup);
        defer d.gpa.free(fixed);
        const doc = svg.parse(d.gpa, fixed, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try d.resources.append(d.gpa, .{ .url = "", .kind = .image, .state = .ready, .svg_doc = doc, .width = doc.width, .height = doc.height });
        rep.resource = @intCast(d.resources.items.len - 1);
        if (rep.natural_w == 0) rep.natural_w = if (doc.width > 0) doc.width else 300;
        if (rep.natural_h == 0) rep.natural_h = if (doc.height > 0) doc.height else 150;
    }
    // Background images.
    for (d.store.styles.items) |st| for ([_]?*const css.style.Image{ st.box.background_image, st.box.mask_image }) |image| if (image) |img| switch (img.*) {
        .url => |u| _ = try d.addResource(.image, u),
        else => {},
    };
    // @font-face sources: the first that is a URL, for families used.
    for (d.sheets.items) |s| for (if (s.sheet) |sh| sh.font_faces else &.{}) |*ff| {
        for (ff.sources) |src| if (!src.local) {
            if (std.mem.indexOf(u8, src.format, "woff2") != null) continue;
            if (try d.addResource(.font, src.url)) |idx| {
                d.resources.items[idx].font_face = ff;
                break;
            }
        };
    };
    d.applyImageSizes();
}

/// The fonts each style needs, for the owner to resolve on its thread.
pub fn resolveFonts(d: *Document, resolver: FontResolver) Error!void {
    d.resolver = resolver;
    for (d.resources.items, 0..) |r, i| if (r.svg_doc != null) try d.resolveSvgFonts(@intCast(i));
    d.font_table.clearRetainingCapacity();
    try d.font_table.ensureTotalCapacity(d.gpa, d.store.count());
    const a = d.arena.allocator();
    // Memo by query.
    var memo: std.StringHashMapUnmanaged(inline_mod.FontInfo) = .empty;
    defer memo.deinit(d.gpa);
    const cache = resolver.cache;
    for (d.store.styles.items) |*st| {
        const lang = d.cascade.?.language(st.inh.lang);
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(d.gpa);
        try key.print(d.gpa, "{x}|{d}|{d}|{d}|{d}|{s}", .{ @intFromPtr(st.inh.font_family), st.inh.font_weight, @intFromEnum(st.inh.font_style), st.inh.font_stretch, st.inh.font_size, lang });
        if (memo.get(key.items)) |fi| {
            try d.font_table.append(d.gpa, fi);
            continue;
        }
        var chain: std.ArrayList(text.FontId) = .empty;
        const italic = st.inh.font_style != .normal;
        const families: []const css.style.Families.Family = if (st.inh.font_family) |f| f.items else &.{.{ .name = "", .generic = .serif }};
        for (families) |fam| {
            // @font-face faces first.
            if (fam.name.len > 0) {
                var faces: std.ArrayList(text.FontId) = .empty;
                defer faces.deinit(d.gpa);
                for (d.resources.items) |r| if (r.kind == .font and r.state == .ready) if (r.font_face) |ff| {
                    if (std.ascii.eqlIgnoreCase(ff.family, fam.name)) if (r.face) |id| try faces.append(d.gpa, id);
                };
                if (faces.items.len > 0) {
                    try d.rankFaces(cache, faces.items, st, &chain);
                    continue;
                }
            }
            const name: []const u8 = if (fam.name.len > 0) fam.name else switch (fam.generic) {
                .serif, .ui_serif, .fangsong => "serif",
                .sans_serif, .system_ui, .ui_sans_serif, .ui_rounded => "sans-serif",
                .monospace, .ui_monospace => "monospace",
                .cursive => "cursive",
                .fantasy => "fantasy",
                .math => "math",
                .emoji => "emoji",
                .none => "serif",
            };
            const found = try resolver.chainFn(resolver.ctx, name, lang, st.inh.font_weight, italic, st.inh.font_stretch, st.inh.font_size);
            for (found) |id| if (std.mem.indexOfScalar(text.FontId, chain.items, id) == null) try chain.append(a, id);
            // A named family the system lacks returns its default chain:
            // the next family decides then; keep scanning only for
            // generic fallbacks when the name matched nothing specific.
            if (fam.generic != .none) break;
        }
        // Default fallback.
        if (chain.items.len == 0) {
            const found = try resolver.chainFn(resolver.ctx, "serif", lang, st.inh.font_weight, italic, st.inh.font_stretch, st.inh.font_size);
            try chain.appendSlice(a, found);
        }
        // Text at font-size 0 (mail's spacer cells) is shaped at a size the
        // text engine takes, too small to show.
        var fi: inline_mod.FontInfo = .{ .chain = chain.items, .size = @max(st.inh.font_size, 0.01), .language = if (lang.len > 0) try a.dupe(u8, lang) else "und" };
        fontMetrics(cache, &fi);
        try memo.put(d.gpa, try a.dupe(u8, key.items), fi);
        try d.font_table.append(d.gpa, fi);
    }
}

/// A font's metrics from the first loaded face of its chain (the last
/// resort's while none is; fontsLoaded tries again).
fn fontMetrics(cache: *const text.FontCache, fi: *inline_mod.FontInfo) void {
    cache.lockShared();
    defer cache.unlockShared();
    for (fi.chain) |id| if (cache.face(id)) |face| {
        const m = face.metrics(fi.size);
        fi.ascent = m.ascent;
        fi.descent = m.descent;
        fi.primary = id;
        fi.x_height = if (face.glyphBounds(face.nominalGlyph('x') orelse 0, fi.size)) |bb| -bb.y else fi.size * 0.5;
        return;
    };
    if (cache.last_resort) |lr| if (cache.face(lr)) |face| {
        const m = face.metrics(fi.size);
        fi.ascent = m.ascent;
        fi.descent = m.descent;
    };
}

fn rankFaces(d: *Document, cache: *text.FontCache, faces: []const text.FontId, st: *const css.Style, out: *std.ArrayList(text.FontId)) Error!void {
    const a = d.arena.allocator();
    const descriptions = try d.gpa.alloc(text.font.Description, faces.len);
    defer d.gpa.free(descriptions);
    for (faces, descriptions) |id, *desc| desc.* = if (cache.face(id)) |face| face.description else .{ .weight = .point(400), .width = .point(100), .italic = .point(0), .slant = .point(0), .opsz = null };
    const order = try d.gpa.alloc(u32, faces.len);
    defer d.gpa.free(order);
    const wanted: text.family.Request = .{ .weight = @floatFromInt(st.inh.font_weight), .width = st.inh.font_stretch, .slant = if (st.inh.font_style == .normal) .roman else .italic };
    text.family.rank(descriptions, wanted, order);
    for (order) |i| {
        const inst = cache.instance(faces[i], text.family.instanceFor(descriptions[i], wanted)) catch faces[i];
        if (std.mem.indexOfScalar(text.FontId, out.items, inst) == null) try out.append(a, inst);
    }
}

fn fontInfo(ctx: *const anyopaque, s: css.Style.Id) *const inline_mod.FontInfo {
    const d: *const Document = @ptrCast(@alignCast(ctx));
    if (s < d.font_table.items.len) return &d.font_table.items[s];
    return &default_font;
}

const default_font: inline_mod.FontInfo = .{};

/// Lays out at `width` (the viewport's) until content passes `stop_y`
/// (infinity: everything). Returns whether layout is complete. Styles
/// created since fonts were resolved use defaults until they are.
pub fn layout(d: *Document, cache: *text.FontCache, width: f32, viewport_h: f32, stop_y: f32) Error!bool {
    _ = d.scratch.reset(.retain_capacity);
    if (d.engine == null) {
        d.engine = .{
            .gpa = d.gpa,
            .scratch = d.scratch.allocator(),
            .tree = &d.tree,
            .store = &d.store,
            .fonts = .{ .cache = cache, .hyphenation = &d.hyphenation, .ctx = d, .infoFn = fontInfo },
            .ifc_cache = try d.gpa.alloc(layout_mod.IfcCache, d.tree.ifcs.items.len),
            .viewport_w = width,
            .viewport_h = viewport_h,
        };
        @memset(d.engine.?.ifc_cache, .{});
        try d.engine.?.measureTree();
    }
    const e = &d.engine.?;
    e.scratch = d.scratch.allocator();
    if (width != d.width or viewport_h != e.viewport_h) {
        e.viewport_w = width;
        e.viewport_h = viewport_h;
        e.invalidate(false);
        d.complete = false;
    }
    d.width = width;
    if (d.complete) return true;
    e.stop_y = stop_y;
    if (d.executor) |exec| if (exec.workers > 1) try d.preshape(e, exec, stop_y);
    d.complete = try e.run();
    d.generation += 1;
    e.trim(e.clock);
    return d.complete;
}

/// Shapes ahead, on the executor, the IFCs layout to `stop_y` will want:
/// the first unshaped ones in tree order, as many text bytes as the
/// height from what is laid out to `stop_y` holds (by the bytes per pixel
/// measured so far, else four, a 16 px text's), with a margin.
fn preshape(d: *Document, e: *layout_mod.Engine, exec: @import("pool").Executor, stop_y: f32) Error!void {
    const per_px: f32 = if (e.bytes_laid > 4096 and e.height_laid > 0) @as(f32, @floatFromInt(e.bytes_laid)) / e.height_laid else 4;
    const budget: f32 = if (std.math.isInf(stop_y)) std.math.inf(f32) else @max(0, stop_y - e.height_laid) * per_px * 1.5 + 2048;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(d.gpa);
    var bytes: usize = 0;
    for (d.tree.ifcs.items[e.frontier..], e.frontier..) |ifc, i| {
        if (e.ifc_cache[i].shaped != null) continue;
        if (@as(f32, @floatFromInt(bytes)) >= budget) break;
        try list.append(d.gpa, @intCast(i));
        bytes += ifc.text.len;
    }
    // Not worth waking workers for a few lines.
    if (bytes < 2048) return;
    try e.preshape(exec, list.items);
}

/// Opens or closes quoted reply `k` (a `siv:quote/k` link); styles and
/// layout must run again. False for no such quote.
pub fn toggleQuote(d: *Document, k: usize) bool {
    if (k >= d.quotes.len) return false;
    d.quote_open.toggle(k);
    return true;
}

/// The document's height (estimated below what is laid out).
pub fn height(d: *const Document) f32 {
    const e = d.engine orelse return 0;
    return e.documentHeight();
}

/// Paints the band `y0..y1` (document coordinates).
pub fn paint(d: *Document, b: *scene.Builder, y0: f32, y1: f32, palette: paint_mod.Palette, hooks: paint_mod.Hooks, highlights: []const paint_mod.Highlight) Error!void {
    const e = &(d.engine orelse return);
    e.clock += 1;
    var p: paint_mod.Painter = .{
        .engine = e,
        .palette = palette,
        .hooks = hooks,
        .b = b,
        .band = .{ y0, y1 },
        .highlights = highlights,
        .scratch = d.scratch.allocator(),
        .base_url = d.base_url,
    };
    p.paint() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    e.trim(e.clock);
}

/// Shapes a marker's text (outside list markers are painted on their
/// own); cached per marker.
pub fn markerGlyphs(d: *Document, index: u32) ?*const paint_mod.MarkerGlyphs {
    if (d.markers.get(index)) |m| return m;
    const e = &(d.engine orelse return null);
    const m = d.tree.markers.items[index];
    const fi = e.fonts.info(m.style);
    const gpa = d.gpa;
    e.fonts.cache.lockShared();
    defer e.fonts.cache.unlockShared();
    var para = text.ShapedParagraph.init(gpa, d.scratch.allocator(), e.fonts.cache, m.text, &.{.{ .end = @intCast(m.text.len), .style = .{ .fonts = fi.chain, .size = fi.size, .language = fi.language } }}, .auto_ltr) catch return null;
    defer para.deinit();
    var runs: std.ArrayList(paint_mod.MarkerGlyphs.Run) = .empty;
    var pen: f32 = 0;
    for (para.runs) |r| {
        const gs = para.runGlyphs(r);
        const out = gpa.alloc(scene.Glyph, gs.len) catch return null;
        for (gs, out) |g, *o| {
            o.* = .{ .id = g.id, .x = pen + g.x_offset, .y = g.y_offset };
            pen += g.advance;
        }
        runs.append(gpa, .{ .font = r.font, .size = fi.size, .glyphs = out }) catch return null;
    }
    const mg = gpa.create(paint_mod.MarkerGlyphs) catch return null;
    mg.* = .{ .runs = runs.toOwnedSlice(gpa) catch return null, .width = pen };
    d.markers.put(gpa, index, mg) catch return null;
    return mg;
}

// Queries.

pub const Hit = struct {
    box: BoxId = none,
    /// The IFC and text offset under the point, if any.
    ifc: u32 = none,
    offset: u32 = 0,
    /// The innermost element under the point (a text's parent).
    node: NodeId = .none,
};

/// What is at a document point.
pub fn hitTest(d: *Document, x: f32, y: f32) Error!Hit {
    const e = &(d.engine orelse return .{});
    var hit: Hit = .{};
    try d.hitBox(e, d.tree.root, x, y, 0, 0, &hit);
    return hit;
}

fn hitBox(d: *Document, e: *layout_mod.Engine, id: BoxId, x: f32, y: f32, px: f32, py: f32, hit: *Hit) Error!void {
    const b = d.tree.get(id);
    const bx = px + b.x;
    const by = py + b.y;
    const inside = x >= bx and x < bx + b.w and y >= by and y < by + b.h;
    if (!inside and !b.out_of_flow and b.kind != .block) {
        if (y < by or y >= by + b.h) return;
    }
    if (inside) {
        hit.box = id;
        if (b.node != .none) hit.node = b.node;
    }
    switch (b.kind) {
        .inline_root => if (inside) {
            const cx = bx + b.border[3] + b.padding[3];
            const cy = by + b.border[0] + b.padding[0];
            const cw = @max(0, b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3]);
            const l = try e.laid(b.data, cw);
            for (l.lines) |line| {
                if (y < cy + line.top or y >= cy + line.top + line.height) continue;
                hit.ifc = b.data;
                hit.offset = inline_mod.offsetAt(l, &d.tree.ifcs.items[b.data], line, x - cx);
                // The element under it: the text run's inline box.
                const ifc = &d.tree.ifcs.items[b.data];
                for (l.lineFrags(line)) |f| if (x - cx >= f.x and x - cx < f.x + f.w) {
                    if (f.kind == .atomic) {
                        try d.hitBox(e, f.box, x, y, bx, by, hit);
                        return;
                    }
                    if (f.inline_box != none) hit.node = ifc.inline_boxes[f.inline_box].node;
                    break;
                };
                break;
            }
        },
        else => {
            var it = d.tree.children(id);
            while (it.next()) |c| try d.hitBox(e, c, x, y, bx, by, hit);
        },
    }
}

/// The link (`<a href>`) at or around an element, and its URL resolved.
pub fn linkAt(d: *Document, node: NodeId) ?struct { node: NodeId, href: []const u8 } {
    var cur = node;
    while (cur != .none) : (cur = d.dom.node(cur).parent) {
        const n = d.dom.node(cur);
        if (n.kind == .element and n.ns == .html and (n.name == .a or n.name == .area)) if (d.dom.attr(cur, .href)) |h| {
            const u = url_mod.resolve(d.arena.allocator(), d.base_url, std.mem.trim(u8, h, " \t\n")) catch return null;
            return .{ .node = cur, .href = u };
        };
    }
    return null;
}

/// The document y of an element's first box (for fragment links), or
/// null when it has none laid out.
pub fn elementY(d: *Document, node: NodeId) ?f32 {
    const e = &(d.engine orelse return null);
    const b = d.node_boxes.get(node.index()) orelse return null;
    return e.absoluteY(b);
}

/// The element with an id (or a name, for `<a name>`).
pub fn elementById(d: *const Document, id: []const u8) NodeId {
    for (d.dom.nodes.items, 0..) |n, i| {
        if (n.kind != .element) continue;
        const nid: NodeId = @enumFromInt(i);
        if (d.dom.attr(nid, .id)) |v| if (std.mem.eql(u8, v, id)) return nid;
        if (n.name == .a) if (d.dom.attr(nid, .name)) |v| if (std.mem.eql(u8, v, id)) return nid;
    }
    return .none;
}

/// The document position of an IFC's content box.
pub fn ifcOrigin(d: *Document, ifc: u32) ?[2]f32 {
    const e = &(d.engine orelse return null);
    for (d.tree.boxes.items, 0..) |b, i| if (b.kind == .inline_root and b.data == ifc) {
        const id: BoxId = @intCast(i);
        return .{ e.absoluteX(id) + b.border[3] + b.padding[3], e.absoluteY(id) + b.border[0] + b.padding[0] };
    };
    return null;
}

pub fn ifcBox(d: *const Document, ifc: u32) BoxId {
    for (d.tree.boxes.items, 0..) |b, i| if (b.kind == .inline_root and b.data == ifc) return @intCast(i);
    return none;
}

/// Fonts that shaping wanted but were still loading; load them, then call
/// `fontsLoaded`.
pub fn wantedFonts(d: *Document, out: *std.ArrayList(text.FontId)) Error!void {
    const e = &(d.engine orelse return);
    for (e.ifc_cache) |c| if (c.shaped) |s| for (s.para.wanted) |id| {
        if (std.mem.indexOfScalar(text.FontId, out.items, id) == null) try out.append(d.gpa, id);
    };
}

/// Fonts finished loading: shape and lay out everything again.
pub fn fontsLoaded(d: *Document) void {
    if (d.engine) |*e| {
        // Metrics (and the primary face, which hyphens and small caps
        // measure with) come from the faces that have loaded since.
        for (d.font_table.items) |*fi| if (fi.primary == null) fontMetrics(e.fonts.cache, fi);
        e.reshapeAll();
        e.incomplete = false;
    }
    var mit = d.markers.valueIterator();
    while (mit.next()) |m| {
        for (m.*.runs) |r| d.gpa.free(r.glyphs);
        d.gpa.free(m.*.runs);
        d.gpa.destroy(m.*);
    }
    d.markers.clearRetainingCapacity();
    d.complete = false;
}

/// A text position: an IFC and a byte offset in its text.
pub const Pos = struct { ifc: u32, offset: u32 };

fn before(a: Pos, b: Pos) bool {
    return a.ifc < b.ifc or (a.ifc == b.ifc and a.offset < b.offset);
}

/// The line holding a text offset, in document coordinates: x, top,
/// and height. Null when its IFC is not laid out.
pub fn offsetRect(d: *Document, p: Pos) Error!?[4]f32 {
    const e = &(d.engine orelse return null);
    const id = d.ifcBox(p.ifc);
    if (id == none) return null;
    const b = d.tree.get(id);
    const o = (d.ifcOrigin(p.ifc)) orelse return null;
    const cw = @max(0, b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3]);
    const l = try e.laid(p.ifc, cw);
    for (l.lines) |line| {
        if (p.offset >= line.end and line.end != line.start) continue;
        var xs: std.ArrayList([2]f32) = .empty;
        defer xs.deinit(d.gpa);
        try inline_mod.rangeRects(l, line, p.offset, p.offset + 1, &xs, d.gpa);
        const x = if (xs.items.len > 0) xs.items[0][0] else line.left;
        return .{ o[0] + x, o[1] + line.top, if (xs.items.len > 0) xs.items[0][1] - xs.items[0][0] else 0, line.height };
    }
    return .{ o[0], o[1], 0, b.h };
}

/// Highlights for the text between two positions (in either order).
pub fn rangeHighlights(d: *const Document, a: Pos, b: Pos, color: css.Color, out: *std.ArrayList(paint_mod.Highlight), gpa: Allocator) Error!void {
    const lo = if (before(b, a)) b else a;
    const hi = if (before(b, a)) a else b;
    var i = lo.ifc;
    while (i <= hi.ifc and i < d.tree.ifcs.items.len) : (i += 1) {
        const len: u32 = @intCast(d.tree.ifcs.items[i].text.len);
        const s = if (i == lo.ifc) lo.offset else 0;
        const e = if (i == hi.ifc) hi.offset else len;
        if (e > s) try out.append(gpa, .{ .ifc = i, .start = s, .end = e, .color = color });
    }
}

/// The text between two positions, a line break between blocks, without
/// the object replacement characters atomic inlines take.
pub fn textBetween(d: *const Document, gpa: Allocator, a: Pos, b: Pos) Error![]u8 {
    const lo = if (before(b, a)) b else a;
    const hi = if (before(b, a)) a else b;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i = lo.ifc;
    while (i <= hi.ifc and i < d.tree.ifcs.items.len) : (i += 1) {
        const t = d.tree.ifcs.items[i].text;
        const s = @min(t.len, if (i == lo.ifc) lo.offset else 0);
        const e = @min(t.len, if (i == hi.ifc) hi.offset else t.len);
        if (i != lo.ifc) try out.append(gpa, '\n');
        var k = s;
        while (k < e) {
            if (std.mem.startsWith(u8, t[k..e], "\u{FFFC}")) {
                k += 3;
                continue;
            }
            try out.append(gpa, t[k]);
            k += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Where a text occurs, ignoring ASCII case, from a position on (or
/// before it, searching backwards); wraps around. Matches do not span
/// IFCs.
pub fn find(d: *const Document, needle: []const u8, from: Pos, backwards: bool) ?Pos {
    const n = d.tree.ifcs.items.len;
    if (n == 0 or needle.len == 0) return null;
    var step: usize = 0;
    var i: usize = from.ifc;
    while (step <= n) : (step += 1) {
        const t = d.tree.ifcs.items[i].text;
        if (backwards) {
            var end: usize = if (step == 0) @min(t.len, from.offset) else t.len;
            while (end >= needle.len) : (end -= 1) {
                if (std.ascii.eqlIgnoreCase(t[end - needle.len .. end], needle)) return .{ .ifc = @intCast(i), .offset = @intCast(end - needle.len) };
            }
            i = if (i == 0) n - 1 else i - 1;
        } else {
            const start: usize = if (step == 0) @min(t.len, from.offset) else 0;
            if (std.ascii.findIgnoreCasePos(t, start, needle)) |k| return .{ .ifc = @intCast(i), .offset = @intCast(k) };
            i = (i + 1) % n;
        }
    }
    return null;
}

/// Every match of a text, ignoring ASCII case, up to `limit`.
pub fn findAll(d: *const Document, needle: []const u8, out: *std.ArrayList(Pos), gpa: Allocator, limit: usize) Error!void {
    if (needle.len == 0) return;
    for (d.tree.ifcs.items, 0..) |ifc, i| {
        var k: usize = 0;
        while (std.ascii.findIgnoreCasePos(ifc.text, k, needle)) |m| {
            if (out.items.len >= limit) return;
            try out.append(gpa, .{ .ifc = @intCast(i), .offset = @intCast(m) });
            k = m + needle.len;
        }
    }
}

/// A node of the accessibility tree (D32): headings, links, lists,
/// tables, images with alternative text, and paragraphs, in tree order.
pub const AccessNode = struct {
    role: enum(u8) { heading, link, list, list_item, table, row, cell, column_header, image, paragraph, group },
    /// Heading level; for links, the element (for activation).
    level: u8 = 0,
    node: NodeId,
    /// Index of the parent in the list, or `none` for the document.
    parent: u32,
    /// Descendants follow up to (not including) `end`.
    end: u32 = 0,
    name: []const u8,
    /// Document coordinates: x, y, width, height.
    bounds: [4]f32,
    /// List items' and rows' position, 1-based.
    position: u32 = 0,
    set_size: u32 = 0,
};

/// The accessibility tree, names allocated with `gpa`'s arena `a`.
pub fn accessibility(d: *Document, a: Allocator, out: *std.ArrayList(AccessNode)) Error!void {
    // Inline elements' text ranges, for their bounds.
    var inlines: InlineRanges = .empty;
    defer inlines.deinit(d.gpa);
    for (d.tree.ifcs.items, 0..) |ifc, i| for (ifc.inline_boxes) |ib| {
        try inlines.put(d.gpa, ib.node.index(), .{ .ifc = @intCast(i), .offset = ib.start, .end = ib.end });
    };
    try d.accessVisit(a, &inlines, d.dom.body(), none, out);
}

const InlineRanges = std.AutoHashMapUnmanaged(u32, struct { ifc: u32, offset: u32, end: u32 });

/// The bounds of an inline element's text: from its first character's
/// line to its last's.
fn inlineBounds(d: *Document, inlines: *const InlineRanges, node: NodeId) Error!?[4]f32 {
    const r = inlines.get(node.index()) orelse return null;
    if (r.end <= r.offset) return null;
    const first = (try d.offsetRect(.{ .ifc = r.ifc, .offset = r.offset })) orelse return null;
    const last = (try d.offsetRect(.{ .ifc = r.ifc, .offset = r.end - 1 })) orelse return null;
    if (last[1] > first[1]) {
        // Several lines: the first line's part.
        const o = d.ifcOrigin(r.ifc) orelse return null;
        const b = d.tree.get(d.ifcBox(r.ifc));
        return .{ first[0], first[1], @max(1, o[0] + b.w - first[0]), first[3] };
    }
    return .{ first[0], first[1], @max(1, last[0] + last[2] - first[0]), first[3] };
}

fn accessVisit(d: *Document, a: Allocator, inlines: *const InlineRanges, id: NodeId, parent: u32, out: *std.ArrayList(AccessNode)) Error!void {
    var it = d.dom.children(id);
    var position: u32 = 0;
    while (it.next()) |c| {
        const n = d.dom.node(c);
        if (n.kind != .element) continue;
        // Inline elements have no box of their own (links' bounds are
        // their parent's then); hidden elements have none at all.
        const bx = d.node_boxes.get(c.index()) orelse none;
        const role: ?@FieldType(AccessNode, "role") = if (n.ns != .html) null else switch (n.name) {
            .h1, .h2, .h3, .h4, .h5, .h6 => .heading,
            .a => if (d.dom.attr(c, .href) != null) .link else null,
            .ul, .ol, .menu => .list,
            .li => .list_item,
            .table => .table,
            .tr => .row,
            .td => .cell,
            .th => .column_header,
            .img => .image,
            .p => .paragraph,
            .blockquote, .figure, .aside, .details => .group,
            else => null,
        };
        if (bx == none and role != .link) {
            if (role == null) try d.accessVisit(a, inlines, c, parent, out);
            continue;
        }
        if (role) |r| {
            var name: std.ArrayList(u8) = .empty;
            switch (r) {
                .image => try name.appendSlice(a, d.dom.attr(c, .alt) orelse ""),
                .heading, .link, .paragraph, .list_item, .cell, .column_header => {
                    var raw: std.ArrayList(u8) = .empty;
                    defer raw.deinit(d.gpa);
                    try d.dom.textContent(d.gpa, c, &raw);
                    // Collapse white space.
                    var space = false;
                    for (std.mem.trim(u8, raw.items, " \t\r\n")) |ch| {
                        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                            space = true;
                            continue;
                        }
                        if (space) try name.append(a, ' ');
                        space = false;
                        try name.append(a, ch);
                    }
                },
                else => {},
            }
            if (r == .list_item or r == .row) position += 1;
            const me: u32 = @intCast(out.items.len);
            const e = &(d.engine orelse return);
            const bounds: [4]f32 = if (bx != none) .{ e.absoluteX(bx), e.absoluteY(bx), d.tree.get(bx).w, d.tree.get(bx).h } else if (try d.inlineBounds(inlines, c)) |ib| ib else if (parent != none) out.items[parent].bounds else @splat(0);
            try out.append(d.gpa, .{
                .role = r,
                .level = if (r == .heading) @intCast(@intFromEnum(n.name) - @intFromEnum(html.Atom.h1) + 1) else 0,
                .node = c,
                .parent = parent,
                .name = name.items,
                .bounds = bounds,
                .position = if (r == .list_item or r == .row) position else 0,
            });
            // Headings, links, paragraphs, and images are leaves (their
            // text is their name), apart from links inside paragraphs.
            if (r == .paragraph or r == .list_item or r == .cell or r == .column_header or r == .group or r == .list or r == .table or r == .row) try d.accessVisit(a, inlines, c, me, out);
            out.items[me].end = @intCast(out.items.len);
            // Set sizes once the siblings are counted.
            if (r == .list or r == .table) {
                var count: u32 = 0;
                var k = me + 1;
                while (k < out.items.len) : (k = out.items[k].end) {
                    if (out.items[k].parent == me) count += 1;
                }
                k = me + 1;
                while (k < out.items.len) : (k = out.items[k].end) {
                    if (out.items[k].parent == me) out.items[k].set_size = count;
                }
            }
        } else try d.accessVisit(a, inlines, c, parent, out);
    }
}

/// The element indices from the body down to the innermost element whose
/// box reaches past document y (the first such at each level): a reading
/// position that survives other widths and fonts.
pub fn locatorPath(d: *Document, y: f32, out: *std.ArrayList(u32), gpa: Allocator) Error!void {
    const e = &(d.engine orelse return);
    var cur = d.dom.body();
    outer: while (true) {
        var i: u32 = 0;
        var c = d.dom.node(cur).first;
        while (c != .none) : (c = d.dom.node(c).next) {
            if (d.dom.node(c).kind != .element) continue;
            defer i += 1;
            const bx = d.node_boxes.get(c.index()) orelse continue;
            if (y < e.absoluteY(bx) + d.tree.get(bx).h) {
                try out.append(gpa, i);
                cur = c;
                continue :outer;
            }
        }
        return;
    }
}

/// Where a laid out document breaks into pages of content height
/// `page_h` (CSS Fragmentation 3, simplified): the y of each page's top
/// after the first, in document coordinates. Breaks fall between blocks,
/// table rows, and lines (keeping `orphans` lines before a break and
/// `widows` after it), never inside a line or a replaced element;
/// `break-before` and `break-after: page` (and their legacy aliases)
/// force one, `avoid` and `break-inside: avoid` avoid one where another
/// fits. Content taller than a page is cut. Lay out to the end first.
pub fn pageBreaks(d: *Document, page_h: f32, out: *std.ArrayList(f32), gpa: Allocator) Error!void {
    out.clearRetainingCapacity();
    const e = &(d.engine orelse return);
    if (d.tree.root == none or !(page_h > 1)) return;
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(gpa);
    try d.breakCands(e, d.tree.root, 0, false, &cands, gpa);
    std.mem.sort(Cand, cands.items, {}, struct {
        fn lt(_: void, a: Cand, b: Cand) bool {
            return a.y < b.y;
        }
    }.lt);
    const end = d.height();
    var start: f32 = 0;
    var i: usize = 0;
    while (start < end - 0.5) {
        const limit = start + page_h;
        // The rest fits: only a forced break makes another page.
        const fits = limit >= end - 0.5;
        var best: ?f32 = null;
        var best_avoid: ?f32 = null;
        var forced: ?f32 = null;
        while (i < cands.items.len and cands.items[i].y <= start + 0.5) i += 1;
        var k = i;
        while (k < cands.items.len and cands.items[k].y <= limit) : (k += 1) {
            const c = cands.items[k];
            if (c.forced) {
                forced = c.y;
                break;
            }
            if (c.avoid) best_avoid = c.y else best = c.y;
        }
        if (fits and forced == null) break;
        const y = forced orelse best orelse best_avoid orelse limit;
        try out.append(gpa, y);
        start = y;
    }
}

const Cand = struct { y: f32, forced: bool = false, avoid: bool = false };

fn forcesBreak(b: css.style.Break) bool {
    return switch (b) {
        .page, .left, .right, .recto, .verso, .always => true,
        else => false,
    };
}

fn avoidsBreak(b: css.style.Break) bool {
    return b == .avoid or b == .avoid_page;
}

fn breakCands(d: *Document, e: *layout_mod.Engine, id: BoxId, py: f32, avoid_inside: bool, out: *std.ArrayList(Cand), gpa: Allocator) Error!void {
    const b = d.tree.get(id);
    const y = py + b.y;
    const st = d.store.get(b.style);
    const avoid = avoid_inside or avoidsBreak(st.box.break_inside);
    switch (b.kind) {
        .inline_root => {
            const cw = @max(0, b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3]);
            const l = try e.laid(b.data, cw);
            const top = y + b.border[0] + b.padding[0];
            const n = l.lines.len;
            for (l.lines, 0..) |line, k| {
                if (k == 0) continue;
                const keeps = k >= st.inh.orphans and n - k >= st.inh.widows;
                try out.append(gpa, .{ .y = top + line.top, .avoid = avoid or !keeps });
            }
        },
        .block, .table_row_group, .table, .table_caption => {
            var it = d.tree.children(id);
            var prev: BoxId = none;
            while (it.next()) |c| {
                const cb = d.tree.get(c);
                if (cb.out_of_flow or cb.inline_float) continue;
                const cs = d.store.get(cb.style);
                if (prev != none) {
                    const ps = d.store.get(d.tree.get(prev).style);
                    const at = y + cb.y - cb.margin[0];
                    try out.append(gpa, .{
                        .y = at,
                        .forced = forcesBreak(cs.box.break_before) or forcesBreak(ps.box.break_after),
                        .avoid = avoid or avoidsBreak(cs.box.break_before) or avoidsBreak(ps.box.break_after),
                    });
                }
                prev = c;
                try d.breakCands(e, c, y, avoid, out, gpa);
            }
        },
        .table_row => {
            // Rows break between them (their group lists them), not inside.
        },
        else => {},
    }
}

/// A link's role: its `epub:type` (an e-book's "noteref") or `rel`.
pub fn linkRel(d: *const Document, node: NodeId) []const u8 {
    if (d.dom.lookup("epub:type")) |a| if (d.dom.attr(node, a)) |v| return v;
    return d.dom.attr(node, .rel) orelse "";
}

/// The markup of the element with an id (a footnote, to show in a
/// popup), into `out`; false when there is none.
pub fn elementHtml(d: *const Document, id: []const u8, out: *std.ArrayList(u8), gpa: Allocator) Error!bool {
    const el = d.elementById(id);
    if (el == .none) return false;
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    html.serialize.outer(&d.dom, &w.writer, el) catch return error.OutOfMemory;
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, w.written());
    return true;
}
