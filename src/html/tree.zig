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

/// The deepest the parser nests elements. With more open elements than
/// this, a node goes in beside the current node rather than under it (as
/// Blink does), so the code that walks the tree by recursion has a bound.
pub const max_depth = 512;

/// The most active formatting elements after a marker. One more takes
/// the earliest off the list, as a fourth equal one does (Noah's Ark):
/// that one stays open, and is no longer made again where a block ended
/// it. Every text after such a block gets a clone of each element in the
/// list, so without a limit n unclosed `<b id=...>`s and n paragraphs
/// make n squared elements.
pub const max_formatting = 32;

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
        /// The stack of open elements. Read it freely; change it only
        /// with `push`, `pop`, `popUntil`, `truncate`, `removeAt`,
        /// `insertOpen`, and `replaceAt`, which keep `marks` and `is_open`
        /// true.
        open: std.ArrayList(NodeId) = .empty,
        /// `marks.items[i]` says what `open.items[i]` and the entries below
        /// it are, so that a question about the stack ("is a `p` in button
        /// scope?") reads the top mark and walks nothing: one walk per tag
        /// made a document of nested elements cost its depth squared. The
        /// list may be shorter than the stack after a change to it; `sync`
        /// marks the rest when a question comes.
        marks: std.ArrayList(Mark) = .empty,
        /// The height (index + 1; 0 is none) of the topmost marked element
        /// of each name, by atom: HTML elements, and foreign ones.
        tops: [2]std.ArrayList(u32) = .{ .empty, .empty },
        /// By node: on the stack of open elements.
        is_open: std.DynamicBitSetUnmanaged = .{},
        /// Active formatting elements; `.none` is a marker. Changed only
        /// with `listAppend`, `listInsert`, `listRemove`, and `listReplace`,
        /// which keep `is_listed` true.
        formatting: std.ArrayList(NodeId) = .empty,
        /// By node: in the list of active formatting elements.
        is_listed: std.DynamicBitSetUnmanaged = .{},
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
            b.marks.deinit(b.gpa);
            for (&b.tops) |*t| t.deinit(b.gpa);
            b.is_open.deinit(b.gpa);
            b.formatting.deinit(b.gpa);
            b.is_listed.deinit(b.gpa);
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

        /// Kinds of open element that a question about the stack stops
        /// at: the boundaries of the five scopes, the special elements,
        /// those that end the search for an open `li`, `dd`, or `dt`,
        /// those that "reset the insertion mode" reads, and the HTML
        /// elements (where an end tag in foreign content stops).
        const Kind = enum { default, list_item, button, table, select, special, item_end, reset, html };

        const Scope = enum { default, list_item, button, table, select };

        const Mark = struct {
            name: Atom,
            foreign: bool,
            /// Height of the next element down with the same name and
            /// `foreign`.
            below: u32,
            /// Height of the topmost element of each kind at or below
            /// this one.
            last: std.EnumArray(Kind, u32),
        };

        fn isKind(ns: Namespace, name: Atom, kind: Kind) bool {
            return switch (kind) {
                .default => isScopeBoundary(ns, name, .default),
                .list_item => isScopeBoundary(ns, name, .list_item),
                .button => isScopeBoundary(ns, name, .button),
                .table => isScopeBoundary(ns, name, .table),
                .select => isScopeBoundary(ns, name, .select),
                .special => isSpecialName(ns, name),
                .item_end => isSpecialName(ns, name) and !(ns == .html and (name == .address or name == .div or name == .p)),
                .reset => ns == .html and switch (name) {
                    .select, .td, .th, .tr, .tbody, .thead, .tfoot, .caption, .colgroup, .table, .template, .head, .body, .frameset, .html => true,
                    else => false,
                },
                .html => ns == .html,
            };
        }

        /// The kinds of the elements with static names. Entry 0, no name,
        /// serves every other name: no kind lists one.
        const kinds: [std.enums.values(Namespace).len][atoms.first_dynamic]std.EnumSet(Kind) = blk: {
            @setEvalBranchQuota(1_000_000);
            var table: [std.enums.values(Namespace).len][atoms.first_dynamic]std.EnumSet(Kind) = undefined;
            for (std.enums.values(Namespace)) |ns| for (0..atoms.first_dynamic) |name| {
                var set: std.EnumSet(Kind) = .empty;
                for (std.enums.values(Kind)) |kind| if (isKind(ns, @enumFromInt(name), kind)) set.insert(kind);
                table[@intFromEnum(ns)][name] = set;
            };
            break :blk table;
        };

        /// Room for the marks of a stack with `id` on it too, so that
        /// `sync` allocates nothing.
        fn reserve(b: *B, id: NodeId) Error!void {
            try b.marks.ensureTotalCapacity(b.gpa, b.open.items.len + 1);
            const x = b.nd(id);
            const tops = &b.tops[@intFromBool(x.ns != .html)];
            const name = @intFromEnum(x.name);
            if (name >= tops.items.len) try tops.appendNTimes(b.gpa, 0, name + 1 - tops.items.len);
            const node = @intFromEnum(id);
            if (node >= b.is_open.bit_length) try b.is_open.resize(b.gpa, @max(node + 1, b.is_open.bit_length * 2), false);
        }

        fn sync(b: *B) void {
            while (b.marks.items.len < b.open.items.len) {
                const i = b.marks.items.len;
                const id = b.open.items[i];
                const x = b.nd(id);
                const height: u32 = @intCast(i + 1);
                const top = &b.tops[@intFromBool(x.ns != .html)].items[@intFromEnum(x.name)];
                var m: Mark = .{
                    .name = x.name,
                    .foreign = x.ns != .html,
                    .below = top.*,
                    .last = if (i == 0) .initFill(0) else b.marks.items[i - 1].last,
                };
                const set = kinds[@intFromEnum(x.ns)][if (x.name.isStatic()) @intFromEnum(x.name) else 0];
                inline for (comptime std.enums.values(Kind)) |kind| if (set.contains(kind)) m.last.set(kind, height);
                top.* = height;
                b.marks.appendAssumeCapacity(m);
            }
        }

        /// Forgets the marks of the entries from `len` up, which change.
        fn unmark(b: *B, len: usize) void {
            while (b.marks.items.len > len) {
                const m = b.marks.pop().?;
                b.tops[@intFromBool(m.foreign)].items[@intFromEnum(m.name)] = m.below;
            }
        }

        /// Height of the topmost open element of a name, 0 without one.
        fn topOf(b: *B, name: Atom, foreign_: bool) u32 {
            b.sync();
            const tops = b.tops[@intFromBool(foreign_)].items;
            return if (@intFromEnum(name) < tops.len) tops[@intFromEnum(name)] else 0;
        }

        /// Height of the topmost open element of a kind, 0 without one.
        fn lastOf(b: *B, kind: Kind) u32 {
            b.sync();
            return if (b.marks.items.len == 0) 0 else b.marks.items[b.marks.items.len - 1].last.get(kind);
        }

        pub fn push(b: *B, id: NodeId) Error!void {
            try b.reserve(id);
            try b.open.append(b.gpa, id);
            b.is_open.set(@intFromEnum(id));
        }

        fn pop(b: *B) void {
            b.is_open.unset(@intFromEnum(b.open.pop().?));
            b.unmark(b.open.items.len);
        }

        fn popUntil(b: *B, name: Atom) void {
            while (b.open.items.len > 0) {
                const c = b.current();
                b.pop();
                if (b.isH(c, name)) return;
            }
        }

        fn popUntilAny(b: *B, names: []const Atom) void {
            while (b.open.items.len > 0) {
                const c = b.current();
                b.pop();
                if (b.nd(c).ns == .html and std.mem.indexOfScalar(Atom, names, b.nd(c).name) != null) return;
            }
        }

        /// Pops down to `len` open elements.
        fn truncate(b: *B, len: usize) void {
            for (b.open.items[len..]) |id| b.is_open.unset(@intFromEnum(id));
            b.open.shrinkRetainingCapacity(len);
            b.unmark(len);
        }

        fn removeAt(b: *B, i: usize) void {
            b.is_open.unset(@intFromEnum(b.open.orderedRemove(i)));
            b.unmark(i);
        }

        fn insertOpen(b: *B, i: usize, id: NodeId) Error!void {
            try b.reserve(id);
            try b.open.insert(b.gpa, i, id);
            b.is_open.set(@intFromEnum(id));
            b.unmark(i);
        }

        fn replaceAt(b: *B, i: usize, id: NodeId) Error!void {
            try b.reserve(id);
            b.is_open.unset(@intFromEnum(b.open.items[i]));
            b.open.items[i] = id;
            b.is_open.set(@intFromEnum(id));
            b.unmark(i);
        }

        fn isOpen(b: *const B, id: NodeId) bool {
            return @intFromEnum(id) < b.is_open.bit_length and b.is_open.isSet(@intFromEnum(id));
        }

        /// Looks at the open elements of the node's name only, from the
        /// top.
        fn indexInStack(b: *B, id: NodeId) ?usize {
            if (!b.isOpen(id)) return null;
            const x = b.nd(id);
            var h = b.topOf(x.name, x.ns != .html);
            while (h != 0) : (h = b.marks.items[h - 1].below) if (b.open.items[h - 1] == id) return h - 1;
            unreachable;
        }

        /// The index of an open node, or null when more than `limit` open
        /// elements are above it. Looks no further down than that.
        fn indexNear(b: *B, id: NodeId, limit: usize) ?usize {
            const x = b.nd(id);
            var h = b.topOf(x.name, x.ns != .html);
            while (h != 0 and b.open.items.len - h <= limit) : (h = b.marks.items[h - 1].below) {
                if (b.open.items[h - 1] == id) return h - 1;
            }
            return null;
        }

        fn removeFromStack(b: *B, id: NodeId) void {
            if (b.indexInStack(id)) |i| b.removeAt(i);
        }

        fn stackHas(b: *B, name: Atom) bool {
            return b.topOf(name, false) != 0;
        }

        fn isScopeBoundary(ns: Namespace, name: Atom, scope: Scope) bool {
            switch (scope) {
                .select => return !(ns == .html and (name == .optgroup or name == .option)),
                .table => return ns == .html and (name == .html or name == .table or name == .template),
                else => {},
            }
            const base = switch (ns) {
                .html => switch (name) {
                    .applet, .caption, .html, .table, .td, .th, .marquee, .object, .template => true,
                    else => false,
                },
                .mathml => switch (name) {
                    .mi, .mo, .mn, .ms, .mtext, .@"annotation-xml" => true,
                    else => false,
                },
                .svg => switch (name) {
                    .foreignObject, .desc, .title => true,
                    else => false,
                },
            };
            if (base) return true;
            if (ns != .html) return false;
            return switch (scope) {
                .list_item => name == .ol or name == .ul,
                .button => name == .button,
                else => false,
            };
        }

        fn scopeKind(scope: Scope) Kind {
            return switch (scope) {
                inline else => |s| @field(Kind, @tagName(s)),
            };
        }

        /// An element of the name is open with no boundary of the scope
        /// above it.
        fn inScope(b: *B, name: Atom, scope: Scope) bool {
            const h = b.topOf(name, false);
            return h != 0 and h >= b.lastOf(scopeKind(scope));
        }

        fn inScopeAny(b: *B, names: []const Atom, scope: Scope) bool {
            for (names) |name| if (b.inScope(name, scope)) return true;
            return false;
        }

        fn nodeInScope(b: *B, target: NodeId) bool {
            const i = b.indexInStack(target) orelse return false;
            return i + 1 >= b.lastOf(.default);
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
            return isSpecialName(x.ns, x.name);
        }

        fn isSpecialName(ns: Namespace, name: Atom) bool {
            return switch (ns) {
                .html => switch (name) {
                    .address, .applet, .area, .article, .aside, .base, .basefont, .bgsound, .blockquote, .body, .br, .button, .caption, .center, .col, .colgroup, .dd, .details, .dir, .div, .dl, .dt, .embed, .fieldset, .figcaption, .figure, .footer, .form, .frame, .frameset, .h1, .h2, .h3, .h4, .h5, .h6, .head, .header, .hgroup, .hr, .html, .iframe, .img, .input, .keygen, .li, .link, .listing, .main, .marquee, .menu, .meta, .nav, .noembed, .noframes, .noscript, .object, .ol, .p, .param, .plaintext, .pre, .script, .search, .section, .select, .source, .style, .summary, .table, .tbody, .td, .template, .textarea, .tfoot, .th, .thead, .title, .tr, .track, .ul, .wbr, .xmp => true,
                    else => false,
                },
                .mathml => switch (name) {
                    .mi, .mo, .mn, .ms, .mtext, .@"annotation-xml" => true,
                    else => false,
                },
                .svg => switch (name) {
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
                const template = b.topOf(.template, false);
                const table_ = b.topOf(.table, false);
                const last_template: ?usize = if (template == 0) null else template - 1;
                const last_table: ?usize = if (table_ == 0) null else table_ - 1;
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
            } else if (override == .none and b.open.items.len > max_depth and b.nd(target).parent != .none) {
                place.parent = b.nd(target).parent;
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
            try b.push(id);
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

        fn setListed(b: *B, id: NodeId, listed: bool) Error!void {
            if (id == .none) return;
            const node = @intFromEnum(id);
            if (node >= b.is_listed.bit_length) {
                if (!listed) return;
                try b.is_listed.resize(b.gpa, @max(node + 1, b.is_listed.bit_length * 2), false);
            }
            b.is_listed.setValue(node, listed);
        }

        fn isListed(b: *const B, id: NodeId) bool {
            return @intFromEnum(id) < b.is_listed.bit_length and b.is_listed.isSet(@intFromEnum(id));
        }

        fn listAppend(b: *B, id: NodeId) Error!void {
            try b.setListed(id, true);
            try b.formatting.append(b.gpa, id);
        }

        fn listInsert(b: *B, i: usize, id: NodeId) Error!void {
            try b.setListed(id, true);
            try b.formatting.insert(b.gpa, i, id);
        }

        fn listRemove(b: *B, i: usize) void {
            b.setListed(b.formatting.orderedRemove(i), false) catch unreachable;
        }

        fn listReplace(b: *B, i: usize, id: NodeId) Error!void {
            try b.setListed(id, true);
            b.setListed(b.formatting.items[i], false) catch unreachable;
            b.formatting.items[i] = id;
        }

        fn pushFormatting(b: *B, id: NodeId) Error!void {
            // Noah's Ark: at most three equal entries after the last marker.
            var count: usize = 0;
            var earliest: ?usize = null;
            var first = b.formatting.items.len;
            while (first > 0) {
                const e = b.formatting.items[first - 1];
                if (e == .none) break;
                first -= 1;
                if (b.sameElement(e, id)) {
                    count += 1;
                    earliest = first;
                }
            }
            if (count >= 3) {
                b.listRemove(earliest.?);
            } else if (b.formatting.items.len - first >= max_formatting) {
                b.listRemove(first);
            }
            try b.listAppend(id);
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
            if (last == .none or b.isOpen(last)) return;
            var i = list.len - 1;
            while (i > 0) {
                const e = b.formatting.items[i - 1];
                if (e == .none or b.isOpen(e)) break;
                i -= 1;
            }
            while (i < b.formatting.items.len) : (i += 1) {
                const c = try b.cloneElement(b.formatting.items[i]);
                b.insertAt(b.appropriatePlace(.none), c);
                try b.push(c);
                try b.listReplace(i, c);
            }
        }

        fn clearFormattingToMarker(b: *B) void {
            while (b.formatting.pop()) |e| {
                if (e == .none) return;
                b.setListed(e, false) catch unreachable;
            }
        }

        /// Where an element is in the list. An element that is not in it
        /// costs no look through it, and the others asked for are near
        /// its end.
        fn formattingIndex(b: *const B, id: NodeId) ?usize {
            if (!b.isListed(id)) return null;
            var i = b.formatting.items.len;
            while (i > 0) {
                i -= 1;
                if (b.formatting.items[i] == id) return i;
            }
            unreachable;
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
                if (!b.isOpen(fe)) {
                    b.listRemove(fi);
                    return true;
                }
                // The steps below cost the open elements above the
                // formatting element, and the element stays under them
                // for the next end tag. With more of them than the parser
                // nests (`max_depth`), the tag is ignored, as it is for a
                // formatting element that is not in scope.
                const si = b.indexNear(fe, max_depth) orelse return true;
                if (si + 1 < b.lastOf(.default)) return true;
                // The furthest block: the topmost special element below.
                var furthest: ?usize = null;
                for (b.open.items[si + 1 ..], si + 1..) |id, k| if (b.isSpecial(id)) {
                    furthest = k;
                    break;
                };
                var fb_i = furthest orelse {
                    b.truncate(si);
                    b.listRemove(fi);
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
                        b.listRemove(nfi.?);
                        if (nfi.? < bookmark) bookmark -= 1;
                        nfi = null;
                    }
                    if (nfi == null) {
                        b.removeAt(node_i);
                        fb_i -= 1;
                        continue;
                    }
                    const clone = try b.cloneElement(node);
                    try b.listReplace(nfi.?, clone);
                    try b.replaceAt(node_i, clone);
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
                b.listRemove(old_fi);
                if (old_fi < bookmark) bookmark -= 1;
                try b.listInsert(@min(bookmark, b.formatting.items.len), clone);
                // The formatting element leaves the stack, and its clone
                // goes in above the furthest block.
                b.removeAt(si);
                try b.insertOpen(fb_i, clone);
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
                    // A fragment's root alone: the tag is ignored.
                    if (b.open.items.len < 2) return;
                    // The foreign elements above the topmost HTML one (the
                    // root is one), whose names are the tag's but for
                    // letter case: a tag's name is in lower case, and only
                    // SVG's element names (`svg_tag_fix`) are not.
                    const html_top = b.lastOf(.html);
                    var found = b.topOf(name, true);
                    if (svg_tag_fix.get(b.dom.nameOf(name))) |f| if (b.dom.lookup(f)) |fixed| {
                        found = @max(found, b.topOf(fixed, true));
                    };
                    if (found > html_top) return b.truncate(found - 1);
                    // The rest goes to the insertion mode.
                    return b.process(b.mode, t);
                },
                .eof => unreachable,
            }
        }

        pub fn resetMode(b: *B) void {
            // Only these elements say anything, so start at the topmost.
            var i: usize = @max(b.lastOf(.reset), 1);
            while (i > 0) {
                i -= 1;
                var node = b.open.items[i];
                const last = i == 0;
                if (last and b.context != .none) node = b.context;
                const x = b.nd(node);
                if (x.ns == .html) switch (x.name) {
                    .select => {
                        // A table below it with no template between: both
                        // are elements this walk stops at, so the topmost
                        // of each is below the select.
                        if (!last and b.topOf(.table, false) > b.topOf(.template, false)) {
                            b.mode = .in_select_in_table;
                            return;
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
                        try b.push(id);
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
                            try b.push(b.head);
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
            try b.push(id);
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
                        try b.listAppend(.none);
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
                    b.truncate(1);
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
                    // The topmost open item, unless a special element
                    // other than address, div, and p is above it.
                    const item = if (s.name == .li) b.topOf(.li, false) else @max(b.topOf(.dd, false), b.topOf(.dt, false));
                    if (item != 0 and item >= b.lastOf(.item_end)) {
                        const name = b.nd(b.open.items[item - 1]).name;
                        b.generateImpliedEndTags(name);
                        b.popUntil(name);
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
                        if (b.formattingIndex(el)) |j| b.listRemove(j);
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
                    try b.listAppend(.none);
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
            // The topmost open element of the name, unless a special
            // element is above it.
            const h = b.topOf(name, false);
            if (h == 0 or h < b.lastOf(.special)) return;
            b.generateImpliedEndTags(name);
            b.truncate(h - 1);
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
                        try b.listAppend(.none);
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
                        try b.listAppend(.none);
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
