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
    /// A user stylesheet the application adds (its own document style).
    user_css: []const u8 = "",
    /// The user's default font size (CSS `medium`).
    font_size: f32 = 16,
    /// Remote images (http, https) are listed as resources only when
    /// allowed; blocked ones count in `blocked_images`.
    remote_images: bool = true,
    /// Author styles (<style>, style attributes, linked sheets) apply.
    author_styles: bool = true,
};

pub const Resource = struct {
    url: []const u8,
    kind: enum(u8) { stylesheet, image, font },
    state: enum(u8) { wanted, loading, ready, failed } = .wanted,
    /// Images: natural size once known; the owner's handle for drawing.
    width: f32 = 0,
    height: f32 = 0,
    handle: u64 = 0,
    /// An SVG image, parsed by the document.
    svg_doc: ?*svg.Document = null,
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
/// The width layout ran at, and whether it finished.
width: f32 = 0,
complete: bool = false,

const SheetRef = struct { sheet: *const css.Sheet, origin: cascade_mod.Origin, owned: bool };

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
    };
    errdefer d.store.deinit(gpa);
    const a = d.arena.allocator();
    d.options.user_css = try a.dupe(u8, options.user_css);
    d.base_url = try a.dupe(u8, options.base_url);
    d.dom = switch (options.kind) {
        .html => try html.parse(gpa, bytes, .{ .charset = options.charset }),
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
    try d.sheets.append(gpa, .{ .sheet = ua_sheet, .origin = .user_agent, .owned = false });
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
        @constCast(s.sheet).deinit();
        gpa.destroy(@constCast(s.sheet));
    };
    d.sheets.deinit(gpa);
    for (d.resources.items) |r| {
        if (r.svg_doc) |s| s.deinit();
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

fn addResource(d: *Document, kind: @TypeOf(@as(Resource, undefined).kind), raw: []const u8) Error!?u32 {
    if (raw.len == 0) return null;
    const u = try d.resolve(raw);
    if (kind == .image and isRemote(u) and !d.options.remote_images) {
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
                const media = dom.attr(cur, .media);
                const s = try d.gpa.create(css.Sheet);
                errdefer d.gpa.destroy(s);
                if (media) |m| {
                    const wrapped = try std.fmt.allocPrint(d.gpa, "@media {s} {{ {s} }}", .{ m, t.items });
                    defer d.gpa.free(wrapped);
                    s.* = try css.sheet.parse(d.gpa, wrapped, .{});
                } else s.* = try css.sheet.parse(d.gpa, t.items, .{});
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
                    _ = try d.addResource(.stylesheet, h);
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
    r.sheet = s;
    r.state = .ready;
    for (s.imports) |imp| {
        // Relative to the sheet's URL.
        const u = try url_mod.resolve(d.arena.allocator(), r.url, imp.url);
        _ = try d.addResource(.stylesheet, u);
    }
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
    d.applyImageSizes();
}

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
    c.env = .{ .media = media, .font_size = d.options.font_size };
    try c.prepare();
    for (d.sheets.items) |s| try c.addSheet(s.sheet, s.origin);
    // Linked and imported sheets, in the order they were listed.
    for (d.resources.items) |r| if (r.kind == .stylesheet) if (r.sheet) |s| try c.addSheet(s, .author);
    d.styles = try c.run();
    var b: box_mod.Builder = .{ .gpa = d.gpa, .arena = a, .dom = &d.dom, .styles = &d.styles.?, .store = &d.store, .tree = &d.tree };
    defer b.deinit();
    try b.build();
    for (d.tree.boxes.items, 0..) |bx, i| {
        if (bx.node == .none) continue;
        const gop = try d.node_boxes.getOrPut(d.gpa, bx.node.index());
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }
    try d.linkResources();
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
    for (d.store.styles.items) |st| if (st.box.background_image) |img| switch (img.*) {
        .url => |u| _ = try d.addResource(.image, u),
        else => {},
    };
    // @font-face sources: the first that is a URL, for families used.
    for (d.sheets.items) |s| for (s.sheet.font_faces) |*ff| {
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
        var fi: inline_mod.FontInfo = .{ .chain = chain.items, .size = st.inh.font_size, .language = if (lang.len > 0) try a.dupe(u8, lang) else "und" };
        cache.lockShared();
        defer cache.unlockShared();
        for (chain.items) |id| if (cache.face(id)) |face| {
            const m = face.metrics(fi.size);
            fi.ascent = m.ascent;
            fi.descent = m.descent;
            fi.primary = id;
            fi.x_height = if (face.glyphBounds(face.nominalGlyph('x') orelse 0, fi.size)) |bb| -bb.y else fi.size * 0.5;
            break;
        } else if (cache.last_resort) |lr| if (cache.face(lr)) |face| {
            const m = face.metrics(fi.size);
            fi.ascent = m.ascent;
            fi.descent = m.descent;
        };
        try memo.put(d.gpa, try a.dupe(u8, key.items), fi);
        try d.font_table.append(d.gpa, fi);
    }
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
    d.complete = try e.run();
    d.generation += 1;
    e.trim(e.clock);
    return d.complete;
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
