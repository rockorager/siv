//! Tree construction (WHATWG HTML, 13.2.6): insertion modes, the stack of
//! open elements, active formatting elements with the adoption agency
//! algorithm, foster parenting, and foreign content (SVG and MathML).
//! Scripting is disabled (siv runs no scripts), so `<noscript>` parses as
//! markup. The `<select>` rules are those before the 2025 relaxed parser.

const std = @import("std");
const Dom = @import("Dom.zig");
const tk = @import("tokenizer.zig");
const atoms = @import("atoms.zig");

const Atom = atoms.Atom;
const NodeId = Dom.NodeId;
const Namespace = Dom.Namespace;
const Error = error{OutOfMemory};

pub const Mode = enum {
    initial,
    before_html,
    before_head,
    in_head,
    in_head_noscript,
    after_head,
    in_body,
    text,
    in_table,
    in_table_text,
    in_caption,
    in_column_group,
    in_table_body,
    in_row,
    in_cell,
    in_select,
    in_select_in_table,
    in_template,
    after_body,
    in_frameset,
    after_frameset,
    after_after_body,
    after_after_frameset,
};

const StartTag = struct {
    name: Atom,
    attrs: []const tk.Attr,
    self_closing: bool,
};

const Tok = union(enum) {
    doctype: tk.Doctype,
    start: StartTag,
    end: Atom,
    comment: []const u8,
    /// A run of characters of one class (`Builder.classify`).
    chars: []const u8,
    eof,
};

pub const Options = struct {
    /// Fragment parsing (innerHTML): the context element's name and
    /// namespace; null parses a document.
    context: ?struct { name: []const u8, ns: Namespace = .html } = null,
};

pub fn Builder(comptime Tokenizer: type) type {
    return struct {
        const B = @This();

        dom: *Dom,
        gpa: std.mem.Allocator,
        tokenizer: *Tokenizer = undefined,
        mode: Mode = .initial,
        original_mode: Mode = .initial,
        template_modes: std.ArrayList(Mode) = .empty,
        open: std.ArrayList(NodeId) = .empty,
        /// Active formatting elements; `.none` is a marker.
        formatting: std.ArrayList(NodeId) = .empty,
        head: NodeId = .none,
        form: NodeId = .none,
        frameset_ok: bool = true,
        foster: bool = false,
        pending_table_text: std.ArrayList(u8) = .empty,
        pending_table_text_ws: bool = true,
        /// Skip a newline at the start of `<pre>`, `<listing>`, `<textarea>`.
        skip_newline: bool = false,
        context: NodeId = .none,
        attrs_scratch: std.ArrayList(Dom.NewAttr) = .empty,
        stopped: bool = false,
        /// Self-closing start tags end their elements (`Options.xml`).
        xml: bool = false,

        pub fn deinit(b: *B) void {
            b.template_modes.deinit(b.gpa);
            b.open.deinit(b.gpa);
            b.formatting.deinit(b.gpa);
            b.pending_table_text.deinit(b.gpa);
            b.attrs_scratch.deinit(b.gpa);
        }

        // Sink interface for the tokenizer.

        pub fn cdataAllowed(b: *B) bool {
            const n = b.adjustedCurrent();
            return n != .none and b.dom.node(n).ns != .html;
        }

        pub fn token(b: *B, t: tk.Token) Error!void {
            if (b.stopped) return;
            const skip = b.skip_newline;
            b.skip_newline = false;
            switch (t) {
                .doctype => |d| try b.dispatch(.{ .doctype = d }),
                .start_tag => |s| {
                    const name = try b.dom.atom(s.name);
                    try b.dispatch(.{ .start = .{ .name = name, .attrs = s.attrs, .self_closing = s.self_closing } });
                    if (b.xml and s.self_closing and !b.stopped and b.open.items.len > 0 and b.dom.node(b.open.items[b.open.items.len - 1]).name == name and b.dom.node(b.open.items[b.open.items.len - 1]).ns == .html) {
                        // XML: the element ends here; text after it is
                        // not its content (raw text elements included).
                        b.tokenizer.state = .data;
                        try b.dispatch(.{ .end = name });
                    }
                },
                .end_tag => |e| try b.dispatch(.{ .end = try b.dom.atom(e.name) }),
                .comment => |c| try b.dispatch(.{ .comment = c }),
                .eof => try b.dispatch(.eof),
                .chars => |cs| {
                    var s = cs;
                    if (skip and s.len > 0 and s[0] == '\n') s = s[1..];
                    // Split into runs of one class: whitespace, NUL, other.
                    var i: usize = 0;
                    while (i < s.len) {
                        const cls = classify(s[i]);
                        var j = i + 1;
                        while (j < s.len and classify(s[j]) == cls) j += 1;
                        try b.dispatch(.{ .chars = s[i..j] });
                        i = j;
                    }
                },
            }
        }

        const Class = enum { ws, nul, other };

        fn classify(c: u8) Class {
            return switch (c) {
                '\t', '\n', 0x0C, '\r', ' ' => .ws,
                0 => .nul,
                else => .other,
            };
        }

        fn charsClass(s: []const u8) Class {
            return classify(s[0]);
        }

        // The stack and nodes.

        fn current(b: *const B) NodeId {
            return if (b.open.items.len == 0) .none else b.open.items[b.open.items.len - 1];
        }

        fn adjustedCurrent(b: *const B) NodeId {
            if (b.context != .none and b.open.items.len == 1) return b.context;
            return b.current();
        }

        fn nd(b: *const B, id: NodeId) *const Dom.Node {
            return b.dom.node(id);
        }

        fn isH(b: *const B, id: NodeId, name: Atom) bool {
            return b.dom.isHtml(id, name);
        }

        fn currentIs(b: *const B, name: Atom) bool {
            const c = b.current();
            return c != .none and b.isH(c, name);
        }

        fn currentIn(b: *const B, names: []const Atom) bool {
            const c = b.current();
            if (c == .none or b.nd(c).ns != .html) return false;
            return std.mem.indexOfScalar(Atom, names, b.nd(c).name) != null;
        }

        fn pop(b: *B) void {
            _ = b.open.pop();
        }

        fn popUntil(b: *B, name: Atom) void {
            while (b.open.items.len > 0) {
                const c = b.open.pop().?;
                if (b.isH(c, name)) return;
            }
        }

        fn popUntilAny(b: *B, names: []const Atom) void {
            while (b.open.items.len > 0) {
                const c = b.open.pop().?;
                if (b.nd(c).ns == .html and std.mem.indexOfScalar(Atom, names, b.nd(c).name) != null) return;
            }
        }

        fn indexInStack(b: *const B, id: NodeId) ?usize {
            var i = b.open.items.len;
            while (i > 0) {
                i -= 1;
                if (b.open.items[i] == id) return i;
            }
            return null;
        }

        fn removeFromStack(b: *B, id: NodeId) void {
            if (b.indexInStack(id)) |i| _ = b.open.orderedRemove(i);
        }

        fn stackHas(b: *const B, name: Atom) bool {
            for (b.open.items) |id| if (b.isH(id, name)) return true;
            return false;
        }

        const Scope = enum { default, list_item, button, table, select };

        fn isScopeBoundary(b: *const B, id: NodeId, scope: Scope) bool {
            const x = b.nd(id);
            switch (scope) {
                .select => return !(x.ns == .html and (x.name == .optgroup or x.name == .option)),
                .table => return x.ns == .html and (x.name == .html or x.name == .table or x.name == .template),
                else => {},
            }
            const base = switch (x.ns) {
                .html => switch (x.name) {
                    .applet, .caption, .html, .table, .td, .th, .marquee, .object, .template => true,
                    else => false,
                },
                .mathml => switch (x.name) {
                    .mi, .mo, .mn, .ms, .mtext, .@"annotation-xml" => true,
                    else => false,
                },
                .svg => switch (x.name) {
                    .foreignObject, .desc, .title => true,
                    else => false,
                },
            };
            if (base) return true;
            if (x.ns != .html) return false;
            return switch (scope) {
                .list_item => x.name == .ol or x.name == .ul,
                .button => x.name == .button,
                else => false,
            };
        }

        fn inScope(b: *const B, name: Atom, scope: Scope) bool {
            var i = b.open.items.len;
            while (i > 0) {
                i -= 1;
                const id = b.open.items[i];
                if (b.isH(id, name)) return true;
                if (b.isScopeBoundary(id, scope)) return false;
            }
            return false;
        }

        fn inScopeAny(b: *const B, names: []const Atom, scope: Scope) bool {
            var i = b.open.items.len;
            while (i > 0) {
                i -= 1;
                const id = b.open.items[i];
                const x = b.nd(id);
                if (x.ns == .html and std.mem.indexOfScalar(Atom, names, x.name) != null) return true;
                if (b.isScopeBoundary(id, scope)) return false;
            }
            return false;
        }

        fn nodeInScope(b: *const B, target: NodeId) bool {
            var i = b.open.items.len;
            while (i > 0) {
                i -= 1;
                const id = b.open.items[i];
                if (id == target) return true;
                if (b.isScopeBoundary(id, .default)) return false;
            }
            return false;
        }

        const implied = [_]Atom{ .dd, .dt, .li, .optgroup, .option, .p, .rb, .rp, .rt, .rtc };
        const implied_thorough = implied ++ [_]Atom{ .caption, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr };

        fn generateImpliedEndTags(b: *B, except: Atom) void {
            while (b.currentIn(&implied) and !b.currentIs(except)) b.pop();
        }

        fn generateAllImpliedEndTags(b: *B) void {
            while (b.currentIn(&implied_thorough)) b.pop();
        }

        fn isSpecial(b: *const B, id: NodeId) bool {
            const x = b.nd(id);
            return switch (x.ns) {
                .html => switch (x.name) {
                    .address, .applet, .area, .article, .aside, .base, .basefont, .bgsound, .blockquote, .body, .br, .button, .caption, .center, .col, .colgroup, .dd, .details, .dir, .div, .dl, .dt, .embed, .fieldset, .figcaption, .figure, .footer, .form, .frame, .frameset, .h1, .h2, .h3, .h4, .h5, .h6, .head, .header, .hgroup, .hr, .html, .iframe, .img, .input, .keygen, .li, .link, .listing, .main, .marquee, .menu, .meta, .nav, .noembed, .noframes, .noscript, .object, .ol, .p, .param, .plaintext, .pre, .script, .search, .section, .select, .source, .style, .summary, .table, .tbody, .td, .template, .textarea, .tfoot, .th, .thead, .title, .tr, .track, .ul, .wbr, .xmp => true,
                    else => false,
                },
                .mathml => switch (x.name) {
                    .mi, .mo, .mn, .ms, .mtext, .@"annotation-xml" => true,
                    else => false,
                },
                .svg => switch (x.name) {
                    .foreignObject, .desc, .title => true,
                    else => false,
                },
            };
        }

        // Inserting.

        const Place = struct { parent: NodeId, before: NodeId };

        fn appropriatePlace(b: *B, override: NodeId) Place {
            const target = if (override != .none) override else b.current();
            var place: Place = .{ .parent = target, .before = .none };
            if (b.foster and b.nd(target).ns == .html and switch (b.nd(target).name) {
                .table, .tbody, .tfoot, .thead, .tr => true,
                else => false,
            }) {
                // Foster parenting.
                var last_template: ?usize = null;
                var last_table: ?usize = null;
                var i = b.open.items.len;
                while (i > 0) {
                    i -= 1;
                    if (last_template == null and b.isH(b.open.items[i], .template)) last_template = i;
                    if (last_table == null and b.isH(b.open.items[i], .table)) last_table = i;
                }
                if (last_template != null and (last_table == null or last_template.? > last_table.?)) {
                    place = .{ .parent = b.open.items[last_template.?], .before = .none };
                } else if (last_table == null) {
                    place = .{ .parent = b.open.items[0], .before = .none };
                } else {
                    const table = b.open.items[last_table.?];
                    if (b.nd(table).parent != .none) {
                        place = .{ .parent = b.nd(table).parent, .before = table };
                    } else {
                        place = .{ .parent = b.open.items[last_table.? - 1], .before = .none };
                    }
                }
            }
            return place;
        }

        fn insertAt(b: *B, place: Place, id: NodeId) void {
            b.dom.insertBefore(place.parent, id, place.before);
        }

        fn insertComment(b: *B, data: []const u8, parent: ?NodeId) Error!void {
            const id = try b.dom.createComment(data);
            if (parent) |p| b.dom.append(p, id) else b.insertAt(b.appropriatePlace(.none), id);
        }

        fn insertChars(b: *B, s: []const u8) Error!void {
            const place = b.appropriatePlace(.none);
            if (place.parent == .document) return;
            const prev = if (place.before == .none) b.nd(place.parent).last else b.nd(place.before).prev;
            if (prev != .none and b.nd(prev).kind == .text) return b.dom.appendText(prev, s);
            const id = try b.dom.createText(s);
            b.insertAt(place, id);
        }

        const svg_attr_fix = std.StaticStringMap([]const u8).initComptime(.{
            .{ "attributename", "attributeName" },         .{ "attributetype", "attributeType" },             .{ "basefrequency", "baseFrequency" },
            .{ "baseprofile", "baseProfile" },             .{ "calcmode", "calcMode" },                       .{ "clippathunits", "clipPathUnits" },
            .{ "diffuseconstant", "diffuseConstant" },     .{ "edgemode", "edgeMode" },                       .{ "filterunits", "filterUnits" },
            .{ "glyphref", "glyphRef" },                   .{ "gradienttransform", "gradientTransform" },     .{ "gradientunits", "gradientUnits" },
            .{ "kernelmatrix", "kernelMatrix" },           .{ "kernelunitlength", "kernelUnitLength" },       .{ "keypoints", "keyPoints" },
            .{ "keysplines", "keySplines" },               .{ "keytimes", "keyTimes" },                       .{ "lengthadjust", "lengthAdjust" },
            .{ "limitingconeangle", "limitingConeAngle" }, .{ "markerheight", "markerHeight" },               .{ "markerunits", "markerUnits" },
            .{ "markerwidth", "markerWidth" },             .{ "maskcontentunits", "maskContentUnits" },       .{ "maskunits", "maskUnits" },
            .{ "numoctaves", "numOctaves" },               .{ "pathlength", "pathLength" },                   .{ "patterncontentunits", "patternContentUnits" },
            .{ "patterntransform", "patternTransform" },   .{ "patternunits", "patternUnits" },               .{ "pointsatx", "pointsAtX" },
            .{ "pointsaty", "pointsAtY" },                 .{ "pointsatz", "pointsAtZ" },                     .{ "preservealpha", "preserveAlpha" },
            .{ "preserveaspectratio", "preserveAspectRatio" }, .{ "primitiveunits", "primitiveUnits" },       .{ "refx", "refX" },
            .{ "refy", "refY" },                           .{ "repeatcount", "repeatCount" },                 .{ "repeatdur", "repeatDur" },
            .{ "requiredextensions", "requiredExtensions" }, .{ "requiredfeatures", "requiredFeatures" },     .{ "specularconstant", "specularConstant" },
            .{ "specularexponent", "specularExponent" },   .{ "spreadmethod", "spreadMethod" },               .{ "startoffset", "startOffset" },
            .{ "stddeviation", "stdDeviation" },           .{ "stitchtiles", "stitchTiles" },                 .{ "surfacescale", "surfaceScale" },
            .{ "systemlanguage", "systemLanguage" },       .{ "tablevalues", "tableValues" },                 .{ "targetx", "targetX" },
            .{ "targety", "targetY" },                     .{ "textlength", "textLength" },                   .{ "viewbox", "viewBox" },
            .{ "viewtarget", "viewTarget" },               .{ "xchannelselector", "xChannelSelector" },       .{ "ychannelselector", "yChannelSelector" },
            .{ "zoomandpan", "zoomAndPan" },
        });

        const svg_tag_fix = std.StaticStringMap([]const u8).initComptime(.{
            .{ "altglyph", "altGlyph" },                   .{ "altglyphdef", "altGlyphDef" },             .{ "altglyphitem", "altGlyphItem" },
            .{ "animatecolor", "animateColor" },           .{ "animatemotion", "animateMotion" },         .{ "animatetransform", "animateTransform" },
            .{ "clippath", "clipPath" },                   .{ "feblend", "feBlend" },                     .{ "fecolormatrix", "feColorMatrix" },
            .{ "fecomponenttransfer", "feComponentTransfer" }, .{ "fecomposite", "feComposite" },         .{ "feconvolvematrix", "feConvolveMatrix" },
            .{ "fediffuselighting", "feDiffuseLighting" }, .{ "fedisplacementmap", "feDisplacementMap" }, .{ "fedistantlight", "feDistantLight" },
            .{ "fedropshadow", "feDropShadow" },           .{ "feflood", "feFlood" },                     .{ "fefunca", "feFuncA" },
            .{ "fefuncb", "feFuncB" },                     .{ "fefuncg", "feFuncG" },                     .{ "fefuncr", "feFuncR" },
            .{ "fegaussianblur", "feGaussianBlur" },       .{ "feimage", "feImage" },                     .{ "femerge", "feMerge" },
            .{ "femergenode", "feMergeNode" },             .{ "femorphology", "feMorphology" },           .{ "feoffset", "feOffset" },
            .{ "fepointlight", "fePointLight" },           .{ "fespecularlighting", "feSpecularLighting" }, .{ "fespotlight", "feSpotLight" },
            .{ "fetile", "feTile" },                       .{ "feturbulence", "feTurbulence" },           .{ "foreignobject", "foreignObject" },
            .{ "glyphref", "glyphRef" },                   .{ "lineargradient", "linearGradient" },       .{ "radialgradient", "radialGradient" },
            .{ "textpath", "textPath" },
        });

        fn createElement(b: *B, tag: StartTag, ns: Namespace) Error!NodeId {
            b.attrs_scratch.clearRetainingCapacity();
            for (tag.attrs) |at| {
                var name = at.name;
                var prefix: Dom.Attr.Prefix = .none;
                if (ns == .svg) {
                    if (svg_attr_fix.get(name)) |f| name = f;
                } else if (ns == .mathml and std.mem.eql(u8, name, "definitionurl")) name = "definitionURL";
                if (ns != .html) {
                    // Foreign attributes keep their prefix apart.
                    if (std.mem.startsWith(u8, name, "xlink:")) {
                        const local = name[6..];
                        if (isOneOf(local, &.{ "actuate", "arcrole", "href", "role", "show", "title", "type" })) {
                            prefix = .xlink;
                            name = local;
                        }
                    } else if (std.mem.eql(u8, name, "xml:lang") or std.mem.eql(u8, name, "xml:space")) {
                        prefix = .xml;
                        name = name[4..];
                    } else if (std.mem.eql(u8, name, "xmlns:xlink")) {
                        prefix = .xmlns;
                        name = "xlink";
                    }
                }
                try b.attrs_scratch.append(b.gpa, .{ .name = try b.dom.atom(name), .prefix = prefix, .value = at.value });
            }
            var name = tag.name;
            if (ns == .svg) if (svg_tag_fix.get(b.dom.nameOf(name))) |f| {
                name = try b.dom.atom(f);
            };
            const id = try b.dom.createElement(ns, name, b.attrs_scratch.items);
            if (ns == .mathml and name == .@"annotation-xml") {
                for (tag.attrs) |at| if (std.mem.eql(u8, at.name, "encoding") and
                    (std.ascii.eqlIgnoreCase(at.value, "text/html") or std.ascii.eqlIgnoreCase(at.value, "application/xhtml+xml")))
                {
                    b.dom.nodeMut(id).flags.integration_point = true;
                };
            }
            return id;
        }

        fn insertElement(b: *B, tag: StartTag, ns: Namespace) Error!NodeId {
            const id = try b.createElement(tag, ns);
            b.insertAt(b.appropriatePlace(.none), id);
            try b.open.append(b.gpa, id);
            return id;
        }

        fn insertHtml(b: *B, tag: StartTag) Error!NodeId {
            return b.insertElement(tag, .html);
        }

        fn insertVoid(b: *B, tag: StartTag) Error!void {
            _ = try b.insertHtml(tag);
            b.pop();
        }

        fn fakeTag(name: Atom) StartTag {
            return .{ .name = name, .attrs = &.{}, .self_closing = false };
        }

        /// A copy of an element (same name, namespace, attributes).
        fn cloneElement(b: *B, id: NodeId) Error!NodeId {
            const x = b.nd(id).*;
            b.attrs_scratch.clearRetainingCapacity();
            // Values are copied out first: creating the clone may move
            // the byte buffer.
            var values: std.ArrayList(u8) = .empty;
            defer values.deinit(b.gpa);
            const src = b.dom.attributes(id);
            var ends: std.ArrayList(u32) = .empty;
            defer ends.deinit(b.gpa);
            for (src) |at| {
                try values.appendSlice(b.gpa, b.dom.str(at.value));
                try ends.append(b.gpa, @intCast(values.items.len));
            }
            var start: u32 = 0;
            for (src, ends.items) |at, end| {
                try b.attrs_scratch.append(b.gpa, .{ .name = at.name, .prefix = at.prefix, .value = values.items[start..end] });
                start = end;
            }
            const c = try b.dom.createElement(x.ns, x.name, b.attrs_scratch.items);
            b.dom.nodeMut(c).flags.implied = true;
            return c;
        }

        // Active formatting elements.

        fn pushFormatting(b: *B, id: NodeId) Error!void {
            // Noah's Ark: at most three equal entries after the last marker.
            var count: usize = 0;
            var earliest: ?usize = null;
            var i = b.formatting.items.len;
            while (i > 0) {
                i -= 1;
                const e = b.formatting.items[i];
                if (e == .none) break;
                if (b.sameElement(e, id)) {
                    count += 1;
                    earliest = i;
                }
            }
            if (count >= 3) _ = b.formatting.orderedRemove(earliest.?);
            try b.formatting.append(b.gpa, id);
        }

        fn sameElement(b: *const B, x: NodeId, y: NodeId) bool {
            const a = b.nd(x);
            const c = b.nd(y);
            if (a.name != c.name or a.ns != c.ns or a.b != c.b) return false;
            for (b.dom.attributes(x)) |at| {
                const other = for (b.dom.attributes(y)) |bt| {
                    if (bt.name == at.name and bt.prefix == at.prefix) break bt;
                } else return false;
                if (!std.mem.eql(u8, b.dom.str(at.value), b.dom.str(other.value))) return false;
            }
            return true;
        }

        fn reconstructFormatting(b: *B) Error!void {
            const list = b.formatting.items;
            if (list.len == 0) return;
            const last = list[list.len - 1];
            if (last == .none or b.indexInStack(last) != null) return;
            var i = list.len - 1;
            while (i > 0) {
                const e = b.formatting.items[i - 1];
                if (e == .none or b.indexInStack(e) != null) break;
                i -= 1;
            }
            while (i < b.formatting.items.len) : (i += 1) {
                const c = try b.cloneElement(b.formatting.items[i]);
                b.insertAt(b.appropriatePlace(.none), c);
                try b.open.append(b.gpa, c);
                b.formatting.items[i] = c;
            }
        }

        fn clearFormattingToMarker(b: *B) void {
            while (b.formatting.pop()) |e| if (e == .none) return;
        }

        fn formattingIndex(b: *const B, id: NodeId) ?usize {
            var i = b.formatting.items.len;
            while (i > 0) {
                i -= 1;
                if (b.formatting.items[i] == id) return i;
            }
            return null;
        }

        /// The last element with `name` after the last marker.
        fn formattingAfterMarker(b: *const B, name: Atom) ?usize {
            var i = b.formatting.items.len;
            while (i > 0) {
                i -= 1;
                const e = b.formatting.items[i];
                if (e == .none) return null;
                if (b.isH(e, name)) return i;
            }
            return null;
        }

        /// The adoption agency algorithm. Returns false to act as "any
        /// other end tag".
        fn adoptionAgency(b: *B, subject: Atom) Error!bool {
            const cur = b.current();
            if (cur != .none and b.isH(cur, subject) and b.formattingIndex(cur) == null) {
                b.pop();
                return true;
            }
            var outer: usize = 0;
            while (outer < 8) : (outer += 1) {
                const fi = b.formattingAfterMarker(subject) orelse return false;
                const fe = b.formatting.items[fi];
                const si = b.indexInStack(fe) orelse {
                    _ = b.formatting.orderedRemove(fi);
                    return true;
                };
                if (!b.nodeInScope(fe)) return true;
                // The furthest block: the topmost special element below.
                var furthest: ?usize = null;
                for (b.open.items[si + 1 ..], si + 1..) |id, k| if (b.isSpecial(id)) {
                    furthest = k;
                    break;
                };
                const fb_i = furthest orelse {
                    b.open.shrinkRetainingCapacity(si);
                    _ = b.formatting.orderedRemove(fi);
                    return true;
                };
                const common = b.open.items[si - 1];
                var bookmark = fi;
                const fb = b.open.items[fb_i];
                var node_i = fb_i;
                var last = fb;
                var inner: usize = 0;
                while (true) {
                    inner += 1;
                    node_i -= 1;
                    var node = b.open.items[node_i];
                    if (node == fe) break;
                    var nfi = b.formattingIndex(node);
                    if (inner > 3 and nfi != null) {
                        _ = b.formatting.orderedRemove(nfi.?);
                        if (nfi.? < bookmark) bookmark -= 1;
                        nfi = null;
                    }
                    if (nfi == null) {
                        _ = b.open.orderedRemove(node_i);
                        continue;
                    }
                    const clone = try b.cloneElement(node);
                    b.formatting.items[nfi.?] = clone;
                    b.open.items[node_i] = clone;
                    node = clone;
                    if (last == fb) bookmark = nfi.? + 1;
                    b.dom.append(node, last);
                    last = node;
                }
                // Insert `last` at the appropriate place with `common` as
                // the override target.
                b.dom.detach(last);
                b.insertAt(b.appropriatePlace(common), last);
                const clone = try b.cloneElement(fe);
                b.dom.moveChildren(fb, clone);
                b.dom.append(fb, clone);
                // Replace in the formatting list at the bookmark.
                const old_fi = b.formattingIndex(fe).?;
                _ = b.formatting.orderedRemove(old_fi);
                if (old_fi < bookmark) bookmark -= 1;
                try b.formatting.insert(b.gpa, @min(bookmark, b.formatting.items.len), clone);
                b.removeFromStack(fe);
                const fb_pos = b.indexInStack(fb).?;
                try b.open.insert(b.gpa, fb_pos + 1, clone);
            }
            return true;
        }

        // Dispatch.

        fn dispatch(b: *B, t: Tok) Error!void {
            const acn = b.adjustedCurrent();
            if (acn == .none or b.nd(acn).ns == .html or t == .eof or b.htmlContentInForeign(acn, t))
                return b.process(b.mode, t);
            return b.foreign(t);
        }

        fn isMathmlTextIntegration(b: *const B, id: NodeId) bool {
            const x = b.nd(id);
            return x.ns == .mathml and switch (x.name) {
                .mi, .mo, .mn, .ms, .mtext => true,
                else => false,
            };
        }

        fn isHtmlIntegration(b: *const B, id: NodeId) bool {
            const x = b.nd(id);
            if (x.ns == .mathml and x.name == .@"annotation-xml") return x.flags.integration_point;
            return x.ns == .svg and (x.name == .foreignObject or x.name == .desc or x.name == .title);
        }

        /// Whether a token in foreign content goes to the insertion mode.
        fn htmlContentInForeign(b: *const B, acn: NodeId, t: Tok) bool {
            if (b.isMathmlTextIntegration(acn)) {
                switch (t) {
                    .start => |s| if (s.name != .mglyph and s.name != .malignmark) return true,
                    .chars => return true,
                    else => {},
                }
            }
            const x = b.nd(acn);
            if (x.ns == .mathml and x.name == .@"annotation-xml") if (t == .start and t.start.name == .svg) return true;
            if (b.isHtmlIntegration(acn)) switch (t) {
                .start, .chars => return true,
                else => {},
            };
            return false;
        }

        fn foreign(b: *B, t: Tok) Error!void {
            switch (t) {
                .chars => |s| switch (charsClass(s)) {
                    .nul => {
                        var i: usize = 0;
                        while (i < s.len) : (i += 1) try b.insertChars("\u{FFFD}");
                    },
                    .ws => try b.insertChars(s),
                    .other => {
                        try b.insertChars(s);
                        b.frameset_ok = false;
                    },
                },
                .comment => |c| try b.insertComment(c, null),
                .doctype => {},
                .start => |s| {
                    const breakout = switch (s.name) {
                        .b, .big, .blockquote, .body, .br, .center, .code, .dd, .div, .dl, .dt, .em, .embed, .h1, .h2, .h3, .h4, .h5, .h6, .head, .hr, .i, .img, .li, .listing, .menu, .meta, .nobr, .ol, .p, .pre, .ruby, .s, .small, .span, .strong, .strike, .sub, .sup, .table, .tt, .u, .ul, .@"var" => true,
                        .font => blk: {
                            for (s.attrs) |at| if (isOneOf(at.name, &.{ "color", "face", "size" })) break :blk true;
                            break :blk false;
                        },
                        else => false,
                    };
                    if (breakout) {
                        while (true) {
                            const c = b.current();
                            if (c == .none or b.nd(c).ns == .html or b.isMathmlTextIntegration(c) or b.isHtmlIntegration(c)) break;
                            b.pop();
                        }
                        return b.process(b.mode, t);
                    }
                    const ns = b.nd(b.adjustedCurrent()).ns;
                    _ = try b.insertElement(s, ns);
                    if (s.self_closing) b.pop();
                },
                .end => |name| {
                    if (name == .p or name == .br) {
                        while (true) {
                            const c = b.current();
                            if (c == .none or b.nd(c).ns == .html or b.isMathmlTextIntegration(c) or b.isHtmlIntegration(c)) break;
                            b.pop();
                        }
                        return b.process(b.mode, t);
                    }
                    const cur = b.current();
                    if (name == .script and b.nd(cur).ns == .svg and b.nd(cur).name == .script) {
                        b.pop();
                        return;
                    }
                    var i = b.open.items.len;
                    while (i > 0) {
                        i -= 1;
                        const id = b.open.items[i];
                        if (i == 0) return;
                        if (std.ascii.eqlIgnoreCase(b.dom.nameOf(b.nd(id).name), b.dom.nameOf(name))) {
                            b.open.shrinkRetainingCapacity(i);
                            return;
                        }
                        if (b.nd(b.open.items[i - 1]).ns == .html) {
                            // The rest goes to the insertion mode.
                            return b.process(b.mode, t);
                        }
                    }
                },
                .eof => unreachable,
            }
        }

        pub fn resetMode(b: *B) void {
            var i = b.open.items.len;
            while (i > 0) {
                i -= 1;
                var node = b.open.items[i];
                const last = i == 0;
                if (last and b.context != .none) node = b.context;
                const x = b.nd(node);
                if (x.ns == .html) switch (x.name) {
                    .select => {
                        if (!last) {
                            var j = i;
                            while (j > 0) {
                                j -= 1;
                                const anc = b.open.items[j];
                                if (b.isH(anc, .template)) break;
                                if (b.isH(anc, .table)) {
                                    b.mode = .in_select_in_table;
                                    return;
                                }
                            }
                        }
                        b.mode = .in_select;
                        return;
                    },
                    .td, .th => if (!last) {
                        b.mode = .in_cell;
                        return;
                    },
                    .tr => {
                        b.mode = .in_row;
                        return;
                    },
                    .tbody, .thead, .tfoot => {
                        b.mode = .in_table_body;
                        return;
                    },
                    .caption => {
                        b.mode = .in_caption;
                        return;
                    },
                    .colgroup => {
                        b.mode = .in_column_group;
                        return;
                    },
                    .table => {
                        b.mode = .in_table;
                        return;
                    },
                    .template => {
                        b.mode = b.template_modes.getLastOrNull() orelse .in_body;
                        return;
                    },
                    .head => if (!last) {
                        b.mode = .in_head;
                        return;
                    },
                    .body => {
                        b.mode = .in_body;
                        return;
                    },
                    .frameset => {
                        b.mode = .in_frameset;
                        return;
                    },
                    .html => {
                        b.mode = if (b.head == .none) .before_head else .after_head;
                        return;
                    },
                    else => {},
                };
                if (last) {
                    b.mode = .in_body;
                    return;
                }
            }
            b.mode = .in_body;
        }

        fn closeP(b: *B) void {
            b.generateImpliedEndTags(.p);
            b.popUntil(.p);
        }

        fn closePInButtonScope(b: *B) void {
            if (b.inScope(.p, .button)) b.closeP();
        }

        fn genericText(b: *B, t: StartTag, state: tk.State) Error!void {
            _ = try b.insertHtml(t);
            b.tokenizer.state = state;
            b.original_mode = b.mode;
            b.mode = .text;
        }

        fn process(b: *B, mode: Mode, t: Tok) Error!void {
            switch (mode) {
                .initial => switch (t) {
                    .chars => |s| if (charsClass(s) != .ws) {
                        b.dom.quirks = .quirks;
                        b.mode = .before_html;
                        return b.process(.before_html, t);
                    },
                    .comment => |c| try b.insertComment(c, .document),
                    .doctype => |d| {
                        const id = try b.dom.createDoctype(d.name orelse "", d.public_id, d.system_id);
                        b.dom.append(.document, id);
                        b.dom.quirks = quirksOf(d);
                        b.mode = .before_html;
                    },
                    else => {
                        b.dom.quirks = .quirks;
                        b.mode = .before_html;
                        return b.process(.before_html, t);
                    },
                },
                .before_html => switch (t) {
                    .doctype => {},
                    .comment => |c| try b.insertComment(c, .document),
                    .chars => |s| if (charsClass(s) != .ws) return b.beforeHtmlElse(t),
                    .start => |s| if (s.name == .html) {
                        const id = try b.createElement(s, .html);
                        b.dom.append(.document, id);
                        try b.open.append(b.gpa, id);
                        b.mode = .before_head;
                    } else return b.beforeHtmlElse(t),
                    .end => |name| switch (name) {
                        .head, .body, .html, .br => return b.beforeHtmlElse(t),
                        else => {},
                    },
                    .eof => return b.beforeHtmlElse(t),
                },
                .before_head => switch (t) {
                    .chars => |s| if (charsClass(s) != .ws) return b.beforeHeadElse(t),
                    .comment => |c| try b.insertComment(c, null),
                    .doctype => {},
                    .start => |s| switch (s.name) {
                        .html => return b.process(.in_body, t),
                        .head => {
                            b.head = try b.insertHtml(s);
                            b.mode = .in_head;
                        },
                        else => return b.beforeHeadElse(t),
                    },
                    .end => |name| switch (name) {
                        .head, .body, .html, .br => return b.beforeHeadElse(t),
                        else => {},
                    },
                    .eof => return b.beforeHeadElse(t),
                },
                .in_head => try b.inHead(t),
                .in_head_noscript => try b.inHeadNoscript(t),
                .after_head => switch (t) {
                    .chars => |s| if (charsClass(s) == .ws) try b.insertChars(s) else return b.afterHeadElse(t),
                    .comment => |c| try b.insertComment(c, null),
                    .doctype => {},
                    .start => |s| switch (s.name) {
                        .html => return b.process(.in_body, t),
                        .body => {
                            _ = try b.insertHtml(s);
                            b.frameset_ok = false;
                            b.mode = .in_body;
                        },
                        .frameset => {
                            _ = try b.insertHtml(s);
                            b.mode = .in_frameset;
                        },
                        .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => {
                            try b.open.append(b.gpa, b.head);
                            try b.inHead(t);
                            b.removeFromStack(b.head);
                        },
                        .head => {},
                        else => return b.afterHeadElse(t),
                    },
                    .end => |name| switch (name) {
                        .template => try b.inHead(t),
                        .body, .html, .br => return b.afterHeadElse(t),
                        else => {},
                    },
                    .eof => return b.afterHeadElse(t),
                },
                .in_body => try b.inBody(t),
                .text => switch (t) {
                    .chars => |s| try b.insertChars(s),
                    .eof => {
                        b.pop();
                        b.mode = b.original_mode;
                        return b.process(b.mode, t);
                    },
                    .end => {
                        b.pop();
                        b.mode = b.original_mode;
                    },
                    else => {},
                },
                .in_table => try b.inTable(t),
                .in_table_text => switch (t) {
                    .chars => |s| switch (charsClass(s)) {
                        .nul => {},
                        .ws => try b.pending_table_text.appendSlice(b.gpa, s),
                        .other => {
                            try b.pending_table_text.appendSlice(b.gpa, s);
                            b.pending_table_text_ws = false;
                        },
                    },
                    else => {
                        try b.flushTableText();
                        b.mode = b.original_mode;
                        return b.process(b.mode, t);
                    },
                },
                .in_caption => try b.inCaption(t),
                .in_column_group => try b.inColumnGroup(t),
                .in_table_body => try b.inTableBody(t),
                .in_row => try b.inRow(t),
                .in_cell => try b.inCell(t),
                .in_select => try b.inSelect(t),
                .in_select_in_table => switch (t) {
                    .start => |s| switch (s.name) {
                        .caption, .table, .tbody, .tfoot, .thead, .tr, .td, .th => {
                            b.popUntil(.select);
                            b.resetMode();
                            return b.process(b.mode, t);
                        },
                        else => try b.inSelect(t),
                    },
                    .end => |name| switch (name) {
                        .caption, .table, .tbody, .tfoot, .thead, .tr, .td, .th => {
                            if (!b.inScope(name, .table)) return;
                            b.popUntil(.select);
                            b.resetMode();
                            return b.process(b.mode, t);
                        },
                        else => try b.inSelect(t),
                    },
                    else => try b.inSelect(t),
                },
                .in_template => try b.inTemplate(t),
                .after_body => switch (t) {
                    .chars => |s| if (charsClass(s) == .ws) try b.inBody(t) else {
                        b.mode = .in_body;
                        return b.process(.in_body, t);
                    },
                    .comment => |c| try b.insertComment(c, b.open.items[0]),
                    .doctype => {},
                    .start => |s| if (s.name == .html) try b.inBody(t) else {
                        b.mode = .in_body;
                        return b.process(.in_body, t);
                    },
                    .end => |name| if (name == .html) {
                        if (b.context == .none) b.mode = .after_after_body;
                    } else {
                        b.mode = .in_body;
                        return b.process(.in_body, t);
                    },
                    .eof => b.stopped = true,
                },
                .in_frameset => switch (t) {
                    .chars => |s| if (charsClass(s) == .ws) try b.insertChars(s),
                    .comment => |c| try b.insertComment(c, null),
                    .doctype => {},
                    .start => |s| switch (s.name) {
                        .html => try b.inBody(t),
                        .frameset => _ = try b.insertHtml(s),
                        .frame => try b.insertVoid(s),
                        .noframes => try b.inHead(t),
                        else => {},
                    },
                    .end => |name| if (name == .frameset) {
                        if (b.open.items.len == 1) return;
                        b.pop();
                        if (b.context == .none and !b.currentIs(.frameset)) b.mode = .after_frameset;
                    },
                    .eof => b.stopped = true,
                },
                .after_frameset => switch (t) {
                    .chars => |s| if (charsClass(s) == .ws) try b.insertChars(s),
                    .comment => |c| try b.insertComment(c, null),
                    .start => |s| switch (s.name) {
                        .html => try b.inBody(t),
                        .noframes => try b.inHead(t),
                        else => {},
                    },
                    .end => |name| if (name == .html) {
                        b.mode = .after_after_frameset;
                    },
                    .eof => b.stopped = true,
                    else => {},
                },
                .after_after_body => switch (t) {
                    .comment => |c| try b.insertComment(c, .document),
                    .doctype => try b.inBody(t),
                    .chars => |s| if (charsClass(s) == .ws) try b.inBody(t) else {
                        b.mode = .in_body;
                        return b.process(.in_body, t);
                    },
                    .start => |s| if (s.name == .html) try b.inBody(t) else {
                        b.mode = .in_body;
                        return b.process(.in_body, t);
                    },
                    .eof => b.stopped = true,
                    else => {
                        b.mode = .in_body;
                        return b.process(.in_body, t);
                    },
                },
                .after_after_frameset => switch (t) {
                    .comment => |c| try b.insertComment(c, .document),
                    .doctype => try b.inBody(t),
                    .chars => |s| if (charsClass(s) == .ws) try b.inBody(t),
                    .start => |s| switch (s.name) {
                        .html => try b.inBody(t),
                        .noframes => try b.inHead(t),
                        else => {},
                    },
                    .eof => b.stopped = true,
                    else => {},
                },
            }
        }

        fn beforeHtmlElse(b: *B, t: Tok) Error!void {
            const id = try b.dom.createElement(.html, .html, &.{});
            b.dom.append(.document, id);
            try b.open.append(b.gpa, id);
            b.mode = .before_head;
            return b.process(.before_head, t);
        }

        fn beforeHeadElse(b: *B, t: Tok) Error!void {
            b.head = try b.insertHtml(fakeTag(.head));
            b.mode = .in_head;
            return b.process(.in_head, t);
        }

        fn afterHeadElse(b: *B, t: Tok) Error!void {
            _ = try b.insertHtml(fakeTag(.body));
            b.mode = .in_body;
            return b.process(.in_body, t);
        }

        fn inHead(b: *B, t: Tok) Error!void {
            switch (t) {
                .chars => |s| if (charsClass(s) == .ws) return b.insertChars(s),
                .comment => |c| return b.insertComment(c, null),
                .doctype => return,
                .start => |s| switch (s.name) {
                    .html => return b.inBody(t),
                    .base, .basefont, .bgsound, .link, .meta => return b.insertVoid(s),
                    .title => return b.genericText(s, .rcdata),
                    .noscript => {
                        _ = try b.insertHtml(s);
                        b.mode = .in_head_noscript;
                        return;
                    },
                    .noframes, .style => return b.genericText(s, .rawtext),
                    .script => return b.genericText(s, .script_data),
                    .template => {
                        _ = try b.insertHtml(s);
                        try b.formatting.append(b.gpa, .none);
                        b.frameset_ok = false;
                        b.mode = .in_template;
                        try b.template_modes.append(b.gpa, .in_template);
                        return;
                    },
                    .head => return,
                    else => {},
                },
                .end => |name| switch (name) {
                    .head => {
                        b.pop();
                        b.mode = .after_head;
                        return;
                    },
                    .body, .html, .br => {},
                    .template => {
                        if (!b.stackHas(.template)) return;
                        b.generateAllImpliedEndTags();
                        b.popUntil(.template);
                        b.clearFormattingToMarker();
                        _ = b.template_modes.pop();
                        b.resetMode();
                        return;
                    },
                    else => return,
                },
                .eof => {},
            }
            b.pop();
            b.mode = .after_head;
            return b.process(.after_head, t);
        }

        fn inHeadNoscript(b: *B, t: Tok) Error!void {
            switch (t) {
                .doctype => return,
                .start => |s| switch (s.name) {
                    .html => return b.inBody(t),
                    .basefont, .bgsound, .link, .meta, .noframes, .style => return b.inHead(t),
                    .head, .noscript => return,
                    else => {},
                },
                .end => |name| switch (name) {
                    .noscript => {
                        b.pop();
                        b.mode = .in_head;
                        return;
                    },
                    .br => {},
                    else => return,
                },
                .chars => |s| if (charsClass(s) == .ws) return b.inHead(t),
                .comment => return b.inHead(t),
                .eof => {},
            }
            b.pop();
            b.mode = .in_head;
            return b.process(.in_head, t);
        }

        fn inBody(b: *B, t: Tok) Error!void {
            switch (t) {
                .chars => |s| switch (charsClass(s)) {
                    .nul => {},
                    .ws => {
                        try b.reconstructFormatting();
                        try b.insertChars(s);
                    },
                    .other => {
                        try b.reconstructFormatting();
                        try b.insertChars(s);
                        b.frameset_ok = false;
                    },
                },
                .comment => |c| try b.insertComment(c, null),
                .doctype => {},
                .start => |s| try b.inBodyStart(s),
                .end => |name| try b.inBodyEnd(name),
                .eof => {
                    if (b.template_modes.items.len > 0) return b.inTemplate(t);
                    b.stopped = true;
                },
            }
        }

        fn inBodyStart(b: *B, s: StartTag) Error!void {
            switch (s.name) {
                .html => {
                    if (b.stackHas(.template)) return;
                    for (s.attrs) |at| try b.dom.addAttrIfMissing(b.open.items[0], .{ .name = try b.dom.atom(at.name), .value = at.value });
                },
                .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => try b.inHead(.{ .start = s }),
                .body => {
                    if (b.open.items.len < 2 or !b.isH(b.open.items[1], .body) or b.stackHas(.template)) return;
                    b.frameset_ok = false;
                    for (s.attrs) |at| try b.dom.addAttrIfMissing(b.open.items[1], .{ .name = try b.dom.atom(at.name), .value = at.value });
                },
                .frameset => {
                    if (b.open.items.len < 2 or !b.isH(b.open.items[1], .body) or !b.frameset_ok) return;
                    b.dom.detach(b.open.items[1]);
                    b.open.shrinkRetainingCapacity(1);
                    _ = try b.insertHtml(s);
                    b.mode = .in_frameset;
                },
                .address, .article, .aside, .blockquote, .center, .details, .dialog, .dir, .div, .dl, .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .main, .menu, .nav, .ol, .p, .search, .section, .summary, .ul => {
                    b.closePInButtonScope();
                    _ = try b.insertHtml(s);
                },
                .h1, .h2, .h3, .h4, .h5, .h6 => {
                    b.closePInButtonScope();
                    if (b.currentIn(&.{ .h1, .h2, .h3, .h4, .h5, .h6 })) b.pop();
                    _ = try b.insertHtml(s);
                },
                .pre, .listing => {
                    b.closePInButtonScope();
                    _ = try b.insertHtml(s);
                    b.skip_newline = true;
                    b.frameset_ok = false;
                },
                .form => {
                    const has_template = b.stackHas(.template);
                    if (b.form != .none and !has_template) return;
                    b.closePInButtonScope();
                    const id = try b.insertHtml(s);
                    if (!has_template) b.form = id;
                },
                .li, .dd, .dt => {
                    b.frameset_ok = false;
                    var i = b.open.items.len;
                    while (i > 0) {
                        i -= 1;
                        const node = b.open.items[i];
                        const matches = if (s.name == .li) b.isH(node, .li) else (b.isH(node, .dd) or b.isH(node, .dt));
                        if (matches) {
                            const name = b.nd(node).name;
                            b.generateImpliedEndTags(name);
                            b.popUntil(name);
                            break;
                        }
                        if (b.isSpecial(node) and !(b.isH(node, .address) or b.isH(node, .div) or b.isH(node, .p))) break;
                    }
                    b.closePInButtonScope();
                    _ = try b.insertHtml(s);
                },
                .plaintext => {
                    b.closePInButtonScope();
                    _ = try b.insertHtml(s);
                    b.tokenizer.state = .plaintext;
                },
                .button => {
                    if (b.inScope(.button, .default)) {
                        b.generateImpliedEndTags(.none);
                        b.popUntil(.button);
                    }
                    try b.reconstructFormatting();
                    _ = try b.insertHtml(s);
                    b.frameset_ok = false;
                },
                .a => {
                    if (b.formattingAfterMarker(.a)) |i| {
                        const el = b.formatting.items[i];
                        _ = try b.adoptionAgency(.a);
                        if (b.formattingIndex(el)) |j| _ = b.formatting.orderedRemove(j);
                        b.removeFromStack(el);
                    }
                    try b.reconstructFormatting();
                    try b.pushFormatting(try b.insertHtml(s));
                },
                .b, .big, .code, .em, .font, .i, .s, .small, .strike, .strong, .tt, .u => {
                    try b.reconstructFormatting();
                    try b.pushFormatting(try b.insertHtml(s));
                },
                .nobr => {
                    try b.reconstructFormatting();
                    if (b.inScope(.nobr, .default)) {
                        _ = try b.adoptionAgency(.nobr);
                        try b.reconstructFormatting();
                    }
                    try b.pushFormatting(try b.insertHtml(s));
                },
                .applet, .marquee, .object => {
                    try b.reconstructFormatting();
                    _ = try b.insertHtml(s);
                    try b.formatting.append(b.gpa, .none);
                    b.frameset_ok = false;
                },
                .table => {
                    if (b.dom.quirks != .quirks) b.closePInButtonScope();
                    _ = try b.insertHtml(s);
                    b.frameset_ok = false;
                    b.mode = .in_table;
                },
                .area, .br, .embed, .img, .keygen, .wbr => {
                    try b.reconstructFormatting();
                    try b.insertVoid(s);
                    b.frameset_ok = false;
                },
                .image => {
                    var s2 = s;
                    s2.name = .img;
                    return b.inBodyStart(s2);
                },
                .input => {
                    try b.reconstructFormatting();
                    try b.insertVoid(s);
                    var hidden = false;
                    for (s.attrs) |at| if (std.mem.eql(u8, at.name, "type") and std.ascii.eqlIgnoreCase(at.value, "hidden")) {
                        hidden = true;
                    };
                    if (!hidden) b.frameset_ok = false;
                },
                .param, .source, .track => try b.insertVoid(s),
                .hr => {
                    b.closePInButtonScope();
                    try b.insertVoid(s);
                    b.frameset_ok = false;
                },
                .textarea => {
                    _ = try b.insertHtml(s);
                    b.skip_newline = true;
                    b.tokenizer.state = .rcdata;
                    b.original_mode = b.mode;
                    b.frameset_ok = false;
                    b.mode = .text;
                },
                .xmp => {
                    b.closePInButtonScope();
                    try b.reconstructFormatting();
                    b.frameset_ok = false;
                    try b.genericText(s, .rawtext);
                },
                .iframe => {
                    b.frameset_ok = false;
                    try b.genericText(s, .rawtext);
                },
                .noembed => try b.genericText(s, .rawtext),
                .select => {
                    try b.reconstructFormatting();
                    _ = try b.insertHtml(s);
                    b.frameset_ok = false;
                    b.mode = switch (b.mode) {
                        .in_table, .in_caption, .in_table_body, .in_row, .in_cell => .in_select_in_table,
                        else => .in_select,
                    };
                },
                .optgroup, .option => {
                    if (b.currentIs(.option)) b.pop();
                    try b.reconstructFormatting();
                    _ = try b.insertHtml(s);
                },
                .rb, .rtc => {
                    if (b.inScope(.ruby, .default)) b.generateImpliedEndTags(.none);
                    _ = try b.insertHtml(s);
                },
                .rp, .rt => {
                    if (b.inScope(.ruby, .default)) b.generateImpliedEndTags(.rtc);
                    _ = try b.insertHtml(s);
                },
                .math, .svg => {
                    try b.reconstructFormatting();
                    _ = try b.insertElement(s, if (s.name == .math) .mathml else .svg);
                    if (s.self_closing) b.pop();
                },
                .caption, .col, .colgroup, .frame, .head, .tbody, .td, .tfoot, .th, .thead, .tr => {},
                else => {
                    try b.reconstructFormatting();
                    _ = try b.insertHtml(s);
                },
            }
        }

        fn inBodyEnd(b: *B, name: Atom) Error!void {
            switch (name) {
                .template => try b.inHead(.{ .end = name }),
                .body, .html => {
                    if (!b.inScope(.body, .default)) return;
                    b.mode = .after_body;
                    if (name == .html) return b.process(.after_body, .{ .end = name });
                },
                .address, .article, .aside, .blockquote, .button, .center, .details, .dialog, .dir, .div, .dl, .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .listing, .main, .menu, .nav, .ol, .pre, .search, .section, .summary, .ul => {
                    if (!b.inScope(name, .default)) return;
                    b.generateImpliedEndTags(.none);
                    b.popUntil(name);
                },
                .form => {
                    if (!b.stackHas(.template)) {
                        const node = b.form;
                        b.form = .none;
                        if (node == .none or !b.nodeInScope(node)) return;
                        b.generateImpliedEndTags(.none);
                        b.removeFromStack(node);
                    } else {
                        if (!b.inScope(.form, .default)) return;
                        b.generateImpliedEndTags(.none);
                        b.popUntil(.form);
                    }
                },
                .p => {
                    if (!b.inScope(.p, .button)) _ = try b.insertHtml(fakeTag(.p));
                    b.closeP();
                },
                .li => {
                    if (!b.inScope(.li, .list_item)) return;
                    b.generateImpliedEndTags(.li);
                    b.popUntil(.li);
                },
                .dd, .dt => {
                    if (!b.inScope(name, .default)) return;
                    b.generateImpliedEndTags(name);
                    b.popUntil(name);
                },
                .h1, .h2, .h3, .h4, .h5, .h6 => {
                    const hs = [_]Atom{ .h1, .h2, .h3, .h4, .h5, .h6 };
                    if (!b.inScopeAny(&hs, .default)) return;
                    b.generateImpliedEndTags(.none);
                    b.popUntilAny(&hs);
                },
                .a, .b, .big, .code, .em, .font, .i, .nobr, .s, .small, .strike, .strong, .tt, .u => {
                    if (!try b.adoptionAgency(name)) try b.anyOtherEnd(name);
                },
                .applet, .marquee, .object => {
                    if (!b.inScope(name, .default)) return;
                    b.generateImpliedEndTags(.none);
                    b.popUntil(name);
                    b.clearFormattingToMarker();
                },
                .br => {
                    try b.reconstructFormatting();
                    try b.insertVoid(fakeTag(.br));
                    b.frameset_ok = false;
                },
                else => try b.anyOtherEnd(name),
            }
        }

        fn anyOtherEnd(b: *B, name: Atom) Error!void {
            var i = b.open.items.len;
            while (i > 0) {
                i -= 1;
                const node = b.open.items[i];
                if (b.isH(node, name)) {
                    b.generateImpliedEndTags(name);
                    b.open.shrinkRetainingCapacity(i);
                    return;
                }
                if (b.isSpecial(node)) return;
            }
        }

        fn clearToTableContext(b: *B) void {
            while (!b.currentIn(&.{ .table, .template, .html })) b.pop();
        }

        fn clearToTableBodyContext(b: *B) void {
            while (!b.currentIn(&.{ .tbody, .tfoot, .thead, .template, .html })) b.pop();
        }

        fn clearToRowContext(b: *B) void {
            while (!b.currentIn(&.{ .tr, .template, .html })) b.pop();
        }

        fn inTable(b: *B, t: Tok) Error!void {
            switch (t) {
                .chars => if (b.currentIn(&.{ .table, .tbody, .template, .tfoot, .thead, .tr })) {
                    b.pending_table_text.clearRetainingCapacity();
                    b.pending_table_text_ws = true;
                    b.original_mode = b.mode;
                    b.mode = .in_table_text;
                    return b.process(.in_table_text, t);
                },
                .comment => |c| return b.insertComment(c, null),
                .doctype => return,
                .start => |s| switch (s.name) {
                    .caption => {
                        b.clearToTableContext();
                        try b.formatting.append(b.gpa, .none);
                        _ = try b.insertHtml(s);
                        b.mode = .in_caption;
                        return;
                    },
                    .colgroup => {
                        b.clearToTableContext();
                        _ = try b.insertHtml(s);
                        b.mode = .in_column_group;
                        return;
                    },
                    .col => {
                        b.clearToTableContext();
                        _ = try b.insertHtml(fakeTag(.colgroup));
                        b.mode = .in_column_group;
                        return b.process(.in_column_group, t);
                    },
                    .tbody, .tfoot, .thead => {
                        b.clearToTableContext();
                        _ = try b.insertHtml(s);
                        b.mode = .in_table_body;
                        return;
                    },
                    .td, .th, .tr => {
                        b.clearToTableContext();
                        _ = try b.insertHtml(fakeTag(.tbody));
                        b.mode = .in_table_body;
                        return b.process(.in_table_body, t);
                    },
                    .table => {
                        if (!b.inScope(.table, .table)) return;
                        b.popUntil(.table);
                        b.resetMode();
                        return b.process(b.mode, t);
                    },
                    .style, .script, .template => return b.inHead(t),
                    .input => {
                        var hidden = false;
                        for (s.attrs) |at| if (std.mem.eql(u8, at.name, "type") and std.ascii.eqlIgnoreCase(at.value, "hidden")) {
                            hidden = true;
                        };
                        if (hidden) return b.insertVoid(s);
                    },
                    .form => {
                        if (b.stackHas(.template) or b.form != .none) return;
                        b.form = try b.insertHtml(s);
                        b.pop();
                        return;
                    },
                    else => {},
                },
                .end => |name| switch (name) {
                    .table => {
                        if (!b.inScope(.table, .table)) return;
                        b.popUntil(.table);
                        b.resetMode();
                        return;
                    },
                    .body, .caption, .col, .colgroup, .html, .tbody, .td, .tfoot, .th, .thead, .tr => return,
                    .template => return b.inHead(t),
                    else => {},
                },
                .eof => return b.inBody(t),
            }
            // Anything else: in body with foster parenting.
            b.foster = true;
            defer b.foster = false;
            try b.inBody(t);
        }

        fn flushTableText(b: *B) Error!void {
            const s = b.pending_table_text.items;
            if (s.len == 0) return;
            if (!b.pending_table_text_ws) {
                b.foster = true;
                defer b.foster = false;
                try b.reconstructFormatting();
                try b.insertChars(s);
                b.frameset_ok = false;
            } else try b.insertChars(s);
            b.pending_table_text.clearRetainingCapacity();
        }

        fn inCaption(b: *B, t: Tok) Error!void {
            switch (t) {
                .end => |name| switch (name) {
                    .caption => {
                        _ = b.closeCaption();
                        return;
                    },
                    .table => {
                        if (b.closeCaption()) return b.process(b.mode, t);
                        return;
                    },
                    .body, .col, .colgroup, .html, .tbody, .td, .tfoot, .th, .thead, .tr => return,
                    else => {},
                },
                .start => |s| switch (s.name) {
                    .caption, .col, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr => {
                        if (b.closeCaption()) return b.process(b.mode, t);
                        return;
                    },
                    else => {},
                },
                else => {},
            }
            return b.inBody(t);
        }

        fn closeCaption(b: *B) bool {
            if (!b.inScope(.caption, .table)) return false;
            b.generateImpliedEndTags(.none);
            b.popUntil(.caption);
            b.clearFormattingToMarker();
            b.mode = .in_table;
            return true;
        }

        fn inColumnGroup(b: *B, t: Tok) Error!void {
            switch (t) {
                .chars => |s| if (charsClass(s) == .ws) return b.insertChars(s),
                .comment => |c| return b.insertComment(c, null),
                .doctype => return,
                .start => |s| switch (s.name) {
                    .html => return b.inBody(t),
                    .col => return b.insertVoid(s),
                    .template => return b.inHead(t),
                    else => {},
                },
                .end => |name| switch (name) {
                    .colgroup => {
                        if (!b.currentIs(.colgroup)) return;
                        b.pop();
                        b.mode = .in_table;
                        return;
                    },
                    .col => return,
                    .template => return b.inHead(t),
                    else => {},
                },
                .eof => return b.inBody(t),
            }
            if (!b.currentIs(.colgroup)) return;
            b.pop();
            b.mode = .in_table;
            return b.process(.in_table, t);
        }

        fn inTableBody(b: *B, t: Tok) Error!void {
            switch (t) {
                .start => |s| switch (s.name) {
                    .tr => {
                        b.clearToTableBodyContext();
                        _ = try b.insertHtml(s);
                        b.mode = .in_row;
                        return;
                    },
                    .th, .td => {
                        b.clearToTableBodyContext();
                        _ = try b.insertHtml(fakeTag(.tr));
                        b.mode = .in_row;
                        return b.process(.in_row, t);
                    },
                    .caption, .col, .colgroup, .tbody, .tfoot, .thead => {
                        if (!b.inScopeAny(&.{ .tbody, .thead, .tfoot }, .table)) return;
                        b.clearToTableBodyContext();
                        b.pop();
                        b.mode = .in_table;
                        return b.process(.in_table, t);
                    },
                    else => {},
                },
                .end => |name| switch (name) {
                    .tbody, .tfoot, .thead => {
                        if (!b.inScope(name, .table)) return;
                        b.clearToTableBodyContext();
                        b.pop();
                        b.mode = .in_table;
                        return;
                    },
                    .table => {
                        if (!b.inScopeAny(&.{ .tbody, .thead, .tfoot }, .table)) return;
                        b.clearToTableBodyContext();
                        b.pop();
                        b.mode = .in_table;
                        return b.process(.in_table, t);
                    },
                    .body, .caption, .col, .colgroup, .html, .td, .th, .tr => return,
                    else => {},
                },
                else => {},
            }
            return b.inTable(t);
        }

        fn inRow(b: *B, t: Tok) Error!void {
            switch (t) {
                .start => |s| switch (s.name) {
                    .th, .td => {
                        b.clearToRowContext();
                        _ = try b.insertHtml(s);
                        b.mode = .in_cell;
                        try b.formatting.append(b.gpa, .none);
                        return;
                    },
                    .caption, .col, .colgroup, .tbody, .tfoot, .thead, .tr => {
                        if (!b.inScope(.tr, .table)) return;
                        b.clearToRowContext();
                        b.pop();
                        b.mode = .in_table_body;
                        return b.process(.in_table_body, t);
                    },
                    else => {},
                },
                .end => |name| switch (name) {
                    .tr => {
                        if (!b.inScope(.tr, .table)) return;
                        b.clearToRowContext();
                        b.pop();
                        b.mode = .in_table_body;
                        return;
                    },
                    .table => {
                        if (!b.inScope(.tr, .table)) return;
                        b.clearToRowContext();
                        b.pop();
                        b.mode = .in_table_body;
                        return b.process(.in_table_body, t);
                    },
                    .tbody, .tfoot, .thead => {
                        if (!b.inScope(name, .table) or !b.inScope(.tr, .table)) return;
                        b.clearToRowContext();
                        b.pop();
                        b.mode = .in_table_body;
                        return b.process(.in_table_body, t);
                    },
                    .body, .caption, .col, .colgroup, .html, .td, .th => return,
                    else => {},
                },
                else => {},
            }
            return b.inTable(t);
        }

        fn closeCell(b: *B) void {
            b.generateImpliedEndTags(.none);
            b.popUntilAny(&.{ .td, .th });
            b.clearFormattingToMarker();
            b.mode = .in_row;
        }

        fn inCell(b: *B, t: Tok) Error!void {
            switch (t) {
                .end => |name| switch (name) {
                    .td, .th => {
                        if (!b.inScope(name, .table)) return;
                        b.generateImpliedEndTags(.none);
                        b.popUntil(name);
                        b.clearFormattingToMarker();
                        b.mode = .in_row;
                        return;
                    },
                    .body, .caption, .col, .colgroup, .html => return,
                    .table, .tbody, .tfoot, .thead, .tr => {
                        if (!b.inScope(name, .table)) return;
                        b.closeCell();
                        return b.process(b.mode, t);
                    },
                    else => {},
                },
                .start => |s| switch (s.name) {
                    .caption, .col, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr => {
                        if (!b.inScopeAny(&.{ .td, .th }, .table)) return;
                        b.closeCell();
                        return b.process(b.mode, t);
                    },
                    else => {},
                },
                else => {},
            }
            return b.inBody(t);
        }

        fn inSelect(b: *B, t: Tok) Error!void {
            switch (t) {
                .chars => |s| if (charsClass(s) != .nul) try b.insertChars(s),
                .comment => |c| try b.insertComment(c, null),
                .doctype => {},
                .start => |s| switch (s.name) {
                    .html => try b.inBody(t),
                    .option => {
                        if (b.currentIs(.option)) b.pop();
                        _ = try b.insertHtml(s);
                    },
                    .optgroup => {
                        if (b.currentIs(.option)) b.pop();
                        if (b.currentIs(.optgroup)) b.pop();
                        _ = try b.insertHtml(s);
                    },
                    .hr => {
                        if (b.currentIs(.option)) b.pop();
                        if (b.currentIs(.optgroup)) b.pop();
                        try b.insertVoid(s);
                    },
                    .select => {
                        if (!b.inScope(.select, .select)) return;
                        b.popUntil(.select);
                        b.resetMode();
                    },
                    .input, .keygen, .textarea => {
                        if (!b.inScope(.select, .select)) return;
                        b.popUntil(.select);
                        b.resetMode();
                        return b.process(b.mode, t);
                    },
                    .script, .template => try b.inHead(t),
                    else => {},
                },
                .end => |name| switch (name) {
                    .optgroup => {
                        if (b.currentIs(.option) and b.open.items.len >= 2 and b.isH(b.open.items[b.open.items.len - 2], .optgroup)) b.pop();
                        if (b.currentIs(.optgroup)) b.pop();
                    },
                    .option => if (b.currentIs(.option)) b.pop(),
                    .select => {
                        if (!b.inScope(.select, .select)) return;
                        b.popUntil(.select);
                        b.resetMode();
                    },
                    .template => try b.inHead(t),
                    else => {},
                },
                .eof => try b.inBody(t),
            }
        }

        fn inTemplate(b: *B, t: Tok) Error!void {
            switch (t) {
                .chars, .comment, .doctype => return b.inBody(t),
                .start => |s| {
                    const next: Mode = switch (s.name) {
                        .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => return b.inHead(t),
                        .caption, .colgroup, .tbody, .tfoot, .thead => .in_table,
                        .col => .in_column_group,
                        .tr => .in_table_body,
                        .td, .th => .in_row,
                        else => .in_body,
                    };
                    _ = b.template_modes.pop();
                    try b.template_modes.append(b.gpa, next);
                    b.mode = next;
                    return b.process(next, t);
                },
                .end => |name| if (name == .template) return b.inHead(t),
                .eof => {
                    if (!b.stackHas(.template)) {
                        b.stopped = true;
                        return;
                    }
                    b.popUntil(.template);
                    b.clearFormattingToMarker();
                    _ = b.template_modes.pop();
                    b.resetMode();
                    return b.process(b.mode, t);
                },
            }
        }
    };
}

fn isOneOf(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// Quirks mode from a DOCTYPE token (13.2.6.4.1).
fn quirksOf(d: tk.Doctype) Dom.Quirks {
    if (d.force_quirks) return .quirks;
    const name = d.name orelse return .quirks;
    if (!std.mem.eql(u8, name, "html")) return .quirks;
    const public = d.public_id orelse "";
    const system = d.system_id;
    const quirky_exact = [_][]const u8{ "-//W3O//DTD W3 HTML Strict 3.0//EN//", "-/W3C/DTD HTML 4.0 Transitional/EN", "HTML" };
    for (quirky_exact) |q| if (std.ascii.eqlIgnoreCase(public, q)) return .quirks;
    if (system) |s| if (std.ascii.eqlIgnoreCase(s, "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd")) return .quirks;
    const prefixes = [_][]const u8{
        "+//Silmaril//dtd html Pro v0r11 19970101//",                                               "-//AS//DTD HTML 3.0 asWedit + extensions//",
        "-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//",                                      "-//IETF//DTD HTML 2.0 Level 1//",
        "-//IETF//DTD HTML 2.0 Level 2//",                                                            "-//IETF//DTD HTML 2.0 Strict Level 1//",
        "-//IETF//DTD HTML 2.0 Strict Level 2//",                                                     "-//IETF//DTD HTML 2.0 Strict//",
        "-//IETF//DTD HTML 2.0//",                                                                    "-//IETF//DTD HTML 2.1E//",
        "-//IETF//DTD HTML 3.0//",                                                                    "-//IETF//DTD HTML 3.2 Final//",
        "-//IETF//DTD HTML 3.2//",                                                                    "-//IETF//DTD HTML 3//",
        "-//IETF//DTD HTML Level 0//",                                                                "-//IETF//DTD HTML Level 1//",
        "-//IETF//DTD HTML Level 2//",                                                                "-//IETF//DTD HTML Level 3//",
        "-//IETF//DTD HTML Strict Level 0//",                                                         "-//IETF//DTD HTML Strict Level 1//",
        "-//IETF//DTD HTML Strict Level 2//",                                                         "-//IETF//DTD HTML Strict Level 3//",
        "-//IETF//DTD HTML Strict//",                                                                 "-//IETF//DTD HTML//",
        "-//Metrius//DTD Metrius Presentational//",                                                   "-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//",
        "-//Microsoft//DTD Internet Explorer 2.0 HTML//",                                             "-//Microsoft//DTD Internet Explorer 2.0 Tables//",
        "-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//",                                      "-//Microsoft//DTD Internet Explorer 3.0 HTML//",
        "-//Microsoft//DTD Internet Explorer 3.0 Tables//",                                           "-//Netscape Comm. Corp.//DTD HTML//",
        "-//Netscape Comm. Corp.//DTD Strict HTML//",                                                 "-//O'Reilly and Associates//DTD HTML 2.0//",
        "-//O'Reilly and Associates//DTD HTML Extended 1.0//",                                        "-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//",
        "-//SQ//DTD HTML 2.0 HoTMetaL + extensions//",                                                "-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::extensions to HTML 4.0//",
        "-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//",                     "-//Spyglass//DTD HTML 2.0 Extended//",
        "-//Sun Microsystems Corp.//DTD HotJava HTML//",                                              "-//Sun Microsystems Corp.//DTD HotJava Strict HTML//",
        "-//W3C//DTD HTML 3 1995-03-24//",                                                            "-//W3C//DTD HTML 3.2 Draft//",
        "-//W3C//DTD HTML 3.2 Final//",                                                               "-//W3C//DTD HTML 3.2//",
        "-//W3C//DTD HTML 3.2S Draft//",                                                              "-//W3C//DTD HTML 4.0 Frameset//",
        "-//W3C//DTD HTML 4.0 Transitional//",                                                        "-//W3C//DTD HTML Experimental 19960712//",
        "-//W3C//DTD HTML Experimental 970421//",                                                     "-//W3C//DTD W3 HTML//",
        "-//W3O//DTD W3 HTML 3.0//",                                                                  "-//WebTechs//DTD Mozilla HTML 2.0//",
        "-//WebTechs//DTD Mozilla HTML//",
    };
    for (prefixes) |p| if (startsWithIgnoreCase(public, p)) return .quirks;
    if (system == null and (startsWithIgnoreCase(public, "-//W3C//DTD HTML 4.01 Frameset//") or startsWithIgnoreCase(public, "-//W3C//DTD HTML 4.01 Transitional//"))) return .quirks;
    if (startsWithIgnoreCase(public, "-//W3C//DTD XHTML 1.0 Frameset//") or startsWithIgnoreCase(public, "-//W3C//DTD XHTML 1.0 Transitional//")) return .limited_quirks;
    if (system != null and (startsWithIgnoreCase(public, "-//W3C//DTD HTML 4.01 Frameset//") or startsWithIgnoreCase(public, "-//W3C//DTD HTML 4.01 Transitional//"))) return .limited_quirks;
    return .no_quirks;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}
