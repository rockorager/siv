//! The box tree (CSS Display 3, CSS 2.1 9.2): boxes made from the styled
//! tree, with anonymous block boxes around inline content among blocks,
//! inline formatting contexts that hold their text after white space
//! processing (CSS Text 3, 4.1), list markers, ::before and ::after
//! content with counters, and replaced elements.

const std = @import("std");
const html = @import("html");
const css = @import("css");
const cascade = @import("cascade.zig");

const Dom = html.Dom;
const NodeId = html.NodeId;
const Style = css.Style;
const StyleId = Style.Id;
const Allocator = std.mem.Allocator;
const Error = error{OutOfMemory};

pub const BoxId = u32;
pub const none: BoxId = std.math.maxInt(u32);

pub const Kind = enum(u8) {
    /// A block container with block-level children (or none).
    block,
    /// A block container whose content is an inline formatting context.
    inline_root,
    /// An image, an SVG, a form control: content drawn into a box.
    replaced,
    flex,
    grid,
    table,
    table_row_group,
    table_row,
    table_cell,
    table_caption,
};

pub const Box = struct {
    kind: Kind,
    node: NodeId = .none,
    style: StyleId,
    parent: BoxId = none,
    first: BoxId = none,
    last: BoxId = none,
    next: BoxId = none,
    /// inline_root: the IFC; replaced: the replaced content; table cells
    /// in collapsing borders: their borders (`collapsed`); list items:
    /// their marker (`markers`) in `marker`.
    data: u32 = none,
    marker: u32 = none,
    /// Inline-level (an atomic inline in its parent's IFC).
    atomic: bool = false,
    /// Out of flow (absolutely positioned or fixed).
    out_of_flow: bool = false,
    /// A float in inline content, placed at the line where it occurs.
    inline_float: bool = false,

    // Layout results: the border box relative to the parent's border box.
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    margin: [4]f32 = .{ 0, 0, 0, 0 },
    border: [4]f32 = .{ 0, 0, 0, 0 },
    padding: [4]f32 = .{ 0, 0, 0, 0 },
    /// The first and last baselines from the border-box top (NaN: none).
    baseline: f32 = std.math.nan(f32),
    last_baseline: f32 = std.math.nan(f32),
    /// The content height laid out at `laid_w` (layout reuse).
    laid_w: f32 = -1,
    laid_h: f32 = -1,
    /// The containing block height it was laid out against (-1: none).
    laid_cb_h: f32 = -1,
    /// Intrinsic inline sizes of the border box (-1: not measured).
    min_content: f32 = -1,
    max_content: f32 = -1,
    /// The static position of an out-of-flow box (relative to its parent).
    static_x: f32 = 0,
    static_y: f32 = 0,
    /// Flex and grid containers align an out-of-flow child's static
    /// position in an area this large from (static_x, static_y): 0 start,
    /// 1 center, 2 end, per axis.
    static_area: [2]f32 = .{ 0, 0 },
    static_align: [2]u8 = .{ 0, 0 },
    /// Table cells: spans.
    colspan: u16 = 1,
    rowspan: u16 = 1,
};

/// An inline box (`<span>`, `<a>`, ...) inside an IFC.
pub const InlineBox = struct {
    style: StyleId,
    node: NodeId,
    /// Range of the IFC's text it covers.
    start: u32,
    end: u32,
    /// The enclosing inline box, or none (the root inline box).
    parent: u32,
};

pub const Item = struct {
    kind: enum(u8) { atomic, open, close },
    /// Text offset: an atomic inline's U+FFFC, or an inline box edge.
    offset: u32,
    /// atomic: the box; open/close: the inline box.
    index: u32,
};

/// A run of text with one style, and where it came from.
pub const Run = struct {
    end: u32,
    style: StyleId,
    /// The DOM text node (or element, for generated content).
    node: NodeId,
    /// The innermost inline box containing it, or none.
    inline_box: u32,
};

/// An inline formatting context's content (width-independent).
pub const Ifc = struct {
    text: []const u8,
    runs: []const Run,
    items: []const Item,
    inline_boxes: []const InlineBox,
    /// The block container's style (the root inline box).
    style: StyleId,
};

pub const Replaced = struct {
    kind: enum(u8) { image, svg, checkbox, radio, input, other },
    /// Image source (resolved by the document) or input text.
    src: []const u8 = "",
    alt: []const u8 = "",
    checked: bool = false,
    /// Natural size in CSS pixels once known (0: unknown).
    natural_w: f32 = 0,
    natural_h: f32 = 0,
    /// The document's handle for loaded content (image or SVG).
    resource: u32 = none,
};

pub const Marker = struct {
    text: []const u8,
    style: StyleId,
    outside: bool,
};

/// One side of a table cell's border in the collapsing border model
/// (CSS 2.1 17.6.2): the cell's share of the winning border's width (its
/// layout border), how far the border reaches past the cell (into the
/// table's own border, at the table's edges), and the winner's style and
/// color (currentColor resolved against its owner).
pub const CollapsedSide = struct {
    part: f32 = 0,
    ext: f32 = 0,
    style: css.style.BorderStyle = .none,
    color: css.Color = css.Color.current,
};

pub const Tree = struct {
    boxes: std.ArrayList(Box) = .empty,
    ifcs: std.ArrayList(Ifc) = .empty,
    replaced: std.ArrayList(Replaced) = .empty,
    markers: std.ArrayList(Marker) = .empty,
    /// Collapsed borders of table cells (`Box.data`), set by layout.
    collapsed: std.ArrayList([4]CollapsedSide) = .empty,
    root: BoxId = none,

    pub fn deinit(t: *Tree, gpa: Allocator) void {
        t.boxes.deinit(gpa);
        t.ifcs.deinit(gpa);
        t.replaced.deinit(gpa);
        t.markers.deinit(gpa);
        t.collapsed.deinit(gpa);
    }

    pub fn get(t: *const Tree, id: BoxId) *Box {
        return &t.boxes.items[id];
    }

    pub fn children(t: *const Tree, id: BoxId) ChildIterator {
        return .{ .t = t, .cur = t.boxes.items[id].first };
    }

    pub const ChildIterator = struct {
        t: *const Tree,
        cur: BoxId,

        pub fn next(it: *ChildIterator) ?BoxId {
            if (it.cur == none) return null;
            const r = it.cur;
            it.cur = it.t.boxes.items[r].next;
            return r;
        }
    };

    pub fn childCount(t: *const Tree, id: BoxId) usize {
        var n: usize = 0;
        var it = t.children(id);
        while (it.next()) |_| n += 1;
        return n;
    }
};

/// Builds the box tree of a styled document. Strings live in `arena`.
pub const Builder = struct {
    /// Anonymous blocks' styles by their parent's.
    anonymous: std.AutoHashMapUnmanaged(StyleId, StyleId) = .empty,
    /// Synthesized small capitals' styles by their text's.
    small_caps: std.AutoHashMapUnmanaged(StyleId, StyleId) = .empty,
    /// Elements left out with their content (collapsed quoted replies).
    skip: []const NodeId = &.{},
    gpa: Allocator,
    arena: Allocator,
    dom: *const Dom,
    styles: *const cascade.Result,
    store: *css.style.Store,
    tree: *Tree,
    /// The IFC being collected, if any.
    ifc: ?IfcBuilder = null,
    /// Inline elements open around the content being collected, outermost
    /// first: re-opened in the IFC after a block splits them.
    open_inlines: std.ArrayList(OpenInline) = .empty,
    counters: std.ArrayList(Counter) = .empty,
    quote_depth: u32 = 0,

    const OpenInline = struct { node: NodeId, style: StyleId };
    const Counter = struct { name: []const u8, value: i32, depth: u32 };

    const IfcBuilder = struct {
        text: std.ArrayList(u8) = .empty,
        runs: std.ArrayList(Run) = .empty,
        items: std.ArrayList(Item) = .empty,
        boxes: std.ArrayList(InlineBox) = .empty,
        stack: std.ArrayList(u32) = .empty,
        /// The last character was collapsible white space (or the start).
        space_before: bool = true,
        /// Anything that makes line boxes: text, atomics, inline edges.
        visible: bool = false,
        atomics: std.ArrayList(BoxId) = .empty,
        style: StyleId,
    };

    pub fn deinit(b: *Builder) void {
        b.anonymous.deinit(b.gpa);
        b.small_caps.deinit(b.gpa);
        b.open_inlines.deinit(b.gpa);
        b.counters.deinit(b.gpa);
    }

    fn style(b: *const Builder, id: StyleId) *const Style {
        return b.store.get(id);
    }

    fn styleOf(b: *const Builder, node: NodeId) StyleId {
        return b.styles.styles[node.index()];
    }

    fn add(b: *Builder, box: Box) Error!BoxId {
        const id: BoxId = @intCast(b.tree.boxes.items.len);
        try b.tree.boxes.append(b.gpa, box);
        return id;
    }

    fn appendChild(b: *Builder, parent: BoxId, child: BoxId) void {
        const t = b.tree;
        t.boxes.items[child].parent = parent;
        const last = t.boxes.items[parent].last;
        if (last == none) t.boxes.items[parent].first = child else t.boxes.items[last].next = child;
        t.boxes.items[parent].last = child;
    }

    /// Builds the tree from the document element.
    pub fn build(b: *Builder) Error!void {
        const root = b.dom.documentElement();
        if (root == .none) return;
        const st = b.styleOf(root);
        if (b.style(st).box.display.isNone()) return;
        // The initial containing block holds the root box.
        b.tree.root = try b.add(.{ .kind = .block, .node = .none, .style = 0 });
        try b.element(b.tree.root, root);
        try b.finishIfc(b.tree.root, true);
    }

    fn kindOf(d: css.style.Display) Kind {
        return switch (d.inner) {
            .flex => .flex,
            .grid => .grid,
            .table => .table,
            .table_row_group, .table_header_group, .table_footer_group => .table_row_group,
            .table_row => .table_row,
            .table_cell => .table_cell,
            .table_caption => .table_caption,
            else => .block,
        };
    }

    fn isReplaced(b: *const Builder, node: NodeId) bool {
        const n = b.dom.node(node);
        if (n.ns == .svg) return n.name == .svg;
        if (n.ns != .html) return false;
        return switch (n.name) {
            .img, .video, .canvas, .iframe, .embed, .object, .input, .textarea, .select, .meter, .progress, .audio => true,
            else => false,
        };
    }

    /// Adds the boxes of `node` (an element) to `parent`.
    fn element(b: *Builder, parent: BoxId, node: NodeId) Error!void {
        const sid = b.styleOf(node);
        const st = b.style(sid);
        const d = st.box.display;
        if (d.isNone()) return;
        if (b.skip.len > 0 and std.mem.indexOfScalar(NodeId, b.skip, node) != null) return;
        // Columns style cells; they have no boxes of their own.
        if (d.inner == .table_column or d.inner == .table_column_group) return;
        const n = b.dom.node(node);
        // Ignore content that never renders.
        if (n.ns == .html and (n.name == .template or n.name == .head)) return;
        if (d.outer == .contents) {
            try b.childrenOf(parent, node, sid);
            return;
        }
        if (n.ns == .html and n.name == .br) {
            try b.text(parent, "\u{2028}", sid, node, true);
            return;
        }
        if (n.ns == .html and n.name == .wbr) {
            try b.text(parent, "\u{200B}", sid, node, true);
            return;
        }
        const counters_depth = b.counters.items.len;
        defer b.popCounters(counters_depth);
        try b.applyCounters(node, st);

        const replaced = b.isReplaced(node);
        if (st.floats() and b.ifc != null) {
            // A float among text: a place in the IFC, beside its line.
            const id = try b.blockBox(node, sid, replaced);
            b.tree.boxes.items[id].inline_float = true;
            try b.atomicInIfc(parent, id, true);
            return;
        }
        if (st.isOutOfFlow()) {
            const id = try b.blockBox(node, sid, replaced);
            b.tree.boxes.items[id].out_of_flow = true;
            // Keep its place in inline content: an empty atomic item.
            if (b.ifc != null) {
                try b.atomicInIfc(parent, id, true);
            } else {
                try b.finishIfc(parent, false);
                b.appendChild(parent, id);
            }
            return;
        }
        if (d.isInlineLevel() and !replaced and d.inner == .flow) {
            // An inline box: its content joins the IFC.
            try b.openInline(parent, node, sid);
            try b.pseudo(parent, node, sid, .before);
            try b.childrenOf(parent, node, sid);
            try b.pseudo(parent, node, sid, .after);
            try b.closeInline(parent);
            return;
        }
        const id = try b.blockBox(node, sid, replaced);
        if (d.isInlineLevel() or (replaced and d.outer == .@"inline")) {
            b.tree.boxes.items[id].atomic = true;
            try b.atomicInIfc(parent, id, false);
        } else {
            try b.finishIfc(parent, false);
            b.appendChild(parent, id);
        }
    }

    /// A box with its own contents: block containers, flex and grid
    /// containers, tables, replaced elements.
    fn blockBox(b: *Builder, node: NodeId, sid: StyleId, replaced: bool) Error!BoxId {
        const st = b.style(sid);
        if (replaced) return b.replacedBox(node, sid);
        const id = try b.add(.{ .kind = kindOf(st.box.display), .node = node, .style = sid });
        if (b.tree.boxes.items[id].kind == .table_cell) {
            const span = struct {
                fn f(d: *const Dom, n: NodeId, a: html.Atom) u16 {
                    const v = d.attr(n, a) orelse return 1;
                    const x = std.fmt.parseInt(u16, std.mem.trim(u8, v, " "), 10) catch return 1;
                    return std.math.clamp(x, 1, 1000);
                }
            }.f;
            b.tree.boxes.items[id].colspan = span(b.dom, node, .colspan);
            b.tree.boxes.items[id].rowspan = span(b.dom, node, .rowspan);
        }
        // A fresh context for its content.
        const saved_ifc = b.ifc;
        b.ifc = null;
        const saved_open = b.open_inlines.items.len;
        const saved_open_items = try b.gpa.dupe(OpenInline, b.open_inlines.items);
        defer b.gpa.free(saved_open_items);
        b.open_inlines.clearRetainingCapacity();
        if (st.box.display.list_item) try b.marker(id, node, sid);
        try b.pseudo(id, node, sid, .before);
        try b.childrenOf(id, node, sid);
        try b.pseudo(id, node, sid, .after);
        try b.finishIfc(id, true);
        b.ifc = saved_ifc;
        b.open_inlines.clearRetainingCapacity();
        try b.open_inlines.appendSlice(b.gpa, saved_open_items);
        _ = saved_open;
        try b.fixTable(id);
        return id;
    }

    fn replacedBox(b: *Builder, node: NodeId, sid: StyleId) Error!BoxId {
        const d = b.dom;
        const n = d.node(node);
        var r: Replaced = .{ .kind = .other };
        if (n.ns == .svg) {
            r.kind = .svg;
        } else switch (n.name) {
            .img => {
                r.kind = .image;
                r.src = try b.arena.dupe(u8, std.mem.trim(u8, d.attr(node, .src) orelse "", " \t\n\r"));
                r.alt = try b.arena.dupe(u8, d.attr(node, .alt) orelse "");
            },
            .input => {
                const t = d.attr(node, .type) orelse "text";
                r.checked = d.hasAttr(node, .checked);
                if (std.ascii.eqlIgnoreCase(t, "checkbox")) {
                    r.kind = .checkbox;
                } else if (std.ascii.eqlIgnoreCase(t, "radio")) {
                    r.kind = .radio;
                } else if (std.ascii.eqlIgnoreCase(t, "hidden")) {
                    r.kind = .other;
                } else {
                    r.kind = .input;
                    r.src = try b.arena.dupe(u8, d.attr(node, .value) orelse d.attr(node, .placeholder) orelse "");
                }
            },
            .video => {
                r.kind = .image;
                r.src = try b.arena.dupe(u8, d.attr(node, .poster) orelse "");
            },
            else => {},
        }
        // Natural size from attributes until the content says otherwise.
        const num = struct {
            fn f(dd: *const Dom, nn: NodeId, a: html.Atom) f32 {
                const v = dd.attr(nn, a) orelse return 0;
                return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " px")) catch 0;
            }
        }.f;
        r.natural_w = num(d, node, .width);
        r.natural_h = num(d, node, .height);
        switch (r.kind) {
            .checkbox, .radio => {
                r.natural_w = 13;
                r.natural_h = 13;
            },
            .input => if (r.natural_w == 0) {
                r.natural_w = 150;
                r.natural_h = 0;
            },
            .other => if (n.ns == .html and (n.name == .iframe or n.name == .embed or n.name == .object or n.name == .canvas)) {
                if (r.natural_w == 0) r.natural_w = 300;
                if (r.natural_h == 0) r.natural_h = 150;
            },
            else => {},
        }
        const index: u32 = @intCast(b.tree.replaced.items.len);
        try b.tree.replaced.append(b.gpa, r);
        return b.add(.{ .kind = .replaced, .node = node, .style = sid, .data = index });
    }

    fn childrenOf(b: *Builder, parent: BoxId, node: NodeId, sid: StyleId) Error!void {
        var it = b.dom.children(node);
        while (it.next()) |c| {
            const n = b.dom.node(c);
            switch (n.kind) {
                .element => try b.element(parent, c),
                .text => try b.text(parent, b.dom.text(c), sid, c, false),
                else => {},
            }
        }
    }

    // Inline content.

    fn ensureIfc(b: *Builder, parent: BoxId) Error!*IfcBuilder {
        if (b.ifc == null) {
            const pst = b.tree.boxes.items[parent].style;
            b.ifc = .{ .style = pst };
            // Re-open inline boxes split by a block.
            const opened = try b.gpa.dupe(OpenInline, b.open_inlines.items);
            defer b.gpa.free(opened);
            b.open_inlines.clearRetainingCapacity();
            for (opened) |o| try b.openInline(parent, o.node, o.style);
        }
        return &b.ifc.?;
    }

    fn openInline(b: *Builder, parent: BoxId, node: NodeId, sid: StyleId) Error!void {
        const f = try b.ensureIfc(parent);
        const at: u32 = @intCast(f.text.items.len);
        const index: u32 = @intCast(f.boxes.items.len);
        try f.boxes.append(b.gpa, .{ .style = sid, .node = node, .start = at, .end = at, .parent = if (f.stack.items.len > 0) f.stack.items[f.stack.items.len - 1] else none });
        try f.stack.append(b.gpa, index);
        try f.items.append(b.gpa, .{ .kind = .open, .offset = at, .index = index });
        try b.open_inlines.append(b.gpa, .{ .node = node, .style = sid });
        const st = b.style(sid);
        // Edges with size make line boxes.
        if (st.box.padding[3].px > 0 or st.box.padding[1].px > 0 or st.borderWidth(1) > 0 or st.borderWidth(3) > 0 or st.box.margin[1].px != 0 or st.box.margin[3].px != 0) f.visible = true;
    }

    fn closeInline(b: *Builder, parent: BoxId) Error!void {
        _ = b.open_inlines.pop();
        if (b.ifc) |*f| {
            const index = f.stack.pop() orelse return;
            const at: u32 = @intCast(f.text.items.len);
            f.boxes.items[index].end = at;
            try f.items.append(b.gpa, .{ .kind = .close, .offset = at, .index = index });
        }
        _ = parent;
    }

    fn currentInline(f: *const IfcBuilder) u32 {
        return if (f.stack.items.len > 0) f.stack.items[f.stack.items.len - 1] else none;
    }

    fn addRun(b: *Builder, f: *IfcBuilder, s: []const u8, sid: StyleId, node: NodeId) Error!void {
        if (s.len == 0) return;
        switch (b.style(sid).inh.font_variant_caps) {
            .small_caps, .all_small_caps, .petite_caps, .all_petite_caps => return b.smallCaps(f, s, sid, node),
            else => {},
        }
        return b.addPlainRun(f, s, sid, node);
    }

    /// Synthesized small capitals (CSS Fonts 4, 6.4, without the font's
    /// own): lowercase letters as capitals at 70% of the size, and with
    /// `all-` the capitals too. Case changes keep the bytes' length.
    fn smallCaps(b: *Builder, f: *IfcBuilder, s: []const u8, sid: StyleId, node: NodeId) Error!void {
        const all = switch (b.style(sid).inh.font_variant_caps) {
            .all_small_caps, .all_petite_caps => true,
            else => false,
        };
        const small = try b.smallStyle(sid);
        const up = try b.arena.dupe(u8, s);
        var i: usize = 0;
        while (i < up.len) {
            const lower = isLowerAt(up, i);
            const shrink = lower or (all and isUpperAt(up, i));
            var j = i;
            while (j < up.len and (if (shrink) (isLowerAt(up, j) or (all and isUpperAt(up, j))) else !(isLowerAt(up, j) or (all and isUpperAt(up, j))))) {
                const n = std.unicode.utf8ByteSequenceLength(up[j]) catch 1;
                if (isLowerAt(up, j)) {
                    if (n == 1) up[j] = std.ascii.toUpper(up[j]) else up[j + 1] -= 0x20;
                }
                j += @min(n, up.len - j);
            }
            try b.addPlainRun(f, up[i..j], if (shrink) small else sid, node);
            i = j;
        }
    }

    fn smallStyle(b: *Builder, sid: StyleId) Error!StyleId {
        if (b.small_caps.get(sid)) |id| return id;
        var st = b.style(sid).*;
        st.inh.font_variant_caps = .normal;
        st.inh.font_size *= 0.7;
        const id = try b.store.intern(b.gpa, &st);
        try b.small_caps.put(b.gpa, sid, id);
        return id;
    }

    /// Lowercase ASCII and Latin-1 letters (whose capitals keep their
    /// length in UTF-8).
    fn isLowerAt(s: []const u8, i: usize) bool {
        const c = s[i];
        if (c >= 'a' and c <= 'z') return true;
        if (c == 0xc3 and i + 1 < s.len) return s[i + 1] >= 0xa0 and s[i + 1] <= 0xbe and s[i + 1] != 0xb7;
        return false;
    }

    fn isUpperAt(s: []const u8, i: usize) bool {
        const c = s[i];
        if (c >= 'A' and c <= 'Z') return true;
        if (c == 0xc3 and i + 1 < s.len) return s[i + 1] >= 0x80 and s[i + 1] <= 0x9e and s[i + 1] != 0x97;
        return false;
    }

    fn addPlainRun(b: *Builder, f: *IfcBuilder, s: []const u8, sid: StyleId, node: NodeId) Error!void {
        if (s.len == 0) return;
        try f.text.appendSlice(b.gpa, s);
        const end: u32 = @intCast(f.text.items.len);
        const ib = currentInline(f);
        if (f.runs.items.len > 0) {
            const last = &f.runs.items[f.runs.items.len - 1];
            if (last.style == sid and last.node == node and last.inline_box == ib and last.end == end - s.len) {
                last.end = end;
                return;
            }
        }
        try f.runs.append(b.gpa, .{ .end = end, .style = sid, .node = node, .inline_box = ib });
    }

    /// Adds text with white space processed by its style.
    fn text(b: *Builder, parent: BoxId, s: []const u8, sid: StyleId, node: NodeId, forced: bool) Error!void {
        const st = b.style(sid);
        const ws = st.inh.white_space_collapse;
        // Text with only collapsible white space and no IFC yet adds
        // nothing (white space between blocks).
        if (b.ifc == null and ws == .collapse and isAllSpace(s) and !forced) return;
        // In a flex or grid container, text of white space alone makes no
        // anonymous item whatever white-space says (CSS Flexbox 4, Grid 6).
        if (b.ifc == null and isAllSpace(s) and !forced) switch (b.tree.boxes.items[parent].kind) {
            .flex, .grid => return,
            else => {},
        };
        const f = try b.ensureIfc(parent);
        if (forced) {
            try b.addRun(f, s, sid, node);
            f.space_before = true;
            f.visible = true;
            return;
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(b.gpa);
        switch (ws) {
            .collapse, .preserve_breaks => {
                var i: usize = 0;
                while (i < s.len) {
                    const ch = s[i];
                    if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0C) {
                        if (ws == .preserve_breaks and ch == '\n') {
                            // Spaces before a preserved break are removed.
                            while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                            try out.append(b.gpa, '\n');
                            f.space_before = true;
                        } else if (!f.space_before) {
                            try out.append(b.gpa, ' ');
                            f.space_before = true;
                        }
                        i += 1;
                    } else {
                        const l = std.unicode.utf8ByteSequenceLength(ch) catch 1;
                        try out.appendSlice(b.gpa, s[i..@min(s.len, i + l)]);
                        f.space_before = false;
                        f.visible = true;
                        i += l;
                    }
                }
            },
            else => {
                // Preserved: tabs to spaces (to tab stops counted from the
                // last break), CR dropped.
                var col: usize = 0;
                var k = f.text.items.len;
                while (k > 0 and f.text.items[k - 1] != '\n') : (k -= 1) col += 1;
                const tab: usize = @intFromFloat(@max(1, @round(st.inh.tab_size)));
                for (s) |ch| switch (ch) {
                    '\r' => {},
                    '\t' => {
                        const nsp = tab - (col % tab);
                        for (0..nsp) |_| try out.append(b.gpa, ' ');
                        col += nsp;
                    },
                    '\n' => {
                        try out.append(b.gpa, '\n');
                        col = 0;
                    },
                    else => {
                        try out.append(b.gpa, ch);
                        if (ch & 0xC0 != 0x80) col += 1;
                    },
                };
                if (out.items.len > 0) f.visible = true;
                f.space_before = false;
            },
        }
        if (st.inh.text_transform != .none) transform(out.items, st.inh.text_transform, f.text.items);
        try b.addRun(f, out.items, sid, node);
    }

    fn atomicInIfc(b: *Builder, parent: BoxId, id: BoxId, empty: bool) Error!void {
        const f = try b.ensureIfc(parent);
        const at: u32 = @intCast(f.text.items.len);
        if (!empty) {
            try b.addRun(f, "\u{FFFC}", b.styleOf(b.tree.boxes.items[id].node), b.tree.boxes.items[id].node);
            f.space_before = false;
            f.visible = true;
        }
        try f.items.append(b.gpa, .{ .kind = .atomic, .offset = at, .index = id });
        try f.atomics.append(b.gpa, id);
    }

    /// Ends the IFC being collected: an anonymous block of it, or the
    /// parent's own content when the parent has no block children
    /// (`final`: none follow).
    fn finishIfc(b: *Builder, parent: BoxId, final: bool) Error!void {
        var f = b.ifc orelse return;
        b.ifc = null;
        defer {
            f.text.deinit(b.gpa);
            f.runs.deinit(b.gpa);
            f.items.deinit(b.gpa);
            f.boxes.deinit(b.gpa);
            f.stack.deinit(b.gpa);
            f.atomics.deinit(b.gpa);
        }
        // Close inline boxes still open (they continue after the block).
        const at: u32 = @intCast(f.text.items.len);
        while (f.stack.pop()) |index| {
            f.boxes.items[index].end = at;
            try f.items.append(b.gpa, .{ .kind = .close, .offset = at, .index = index });
        }
        if (!f.visible) {
            // Only out-of-flow boxes, if anything: they join the parent.
            for (f.atomics.items) |a| b.appendChild(parent, a);
            return;
        }
        // Trailing collapsible space is removed.
        if (f.text.items.len > 0 and f.text.items[f.text.items.len - 1] == ' ' and f.runs.items.len > 0) {
            const last_run = f.runs.items[f.runs.items.len - 1];
            if (b.style(last_run.style).inh.white_space_collapse == .collapse) {
                f.text.items.len -= 1;
                f.runs.items[f.runs.items.len - 1].end -= 1;
                if (f.runs.items[f.runs.items.len - 1].end == if (f.runs.items.len > 1) f.runs.items[f.runs.items.len - 2].end else 0) _ = f.runs.pop();
                const n: u32 = @intCast(f.text.items.len);
                for (f.items.items) |*it| it.offset = @min(it.offset, n);
                for (f.boxes.items) |*ib| {
                    ib.start = @min(ib.start, n);
                    ib.end = @min(ib.end, n);
                }
            }
        }
        const index: u32 = @intCast(b.tree.ifcs.items.len);
        try b.tree.ifcs.append(b.gpa, .{
            .text = try b.arena.dupe(u8, f.text.items),
            .runs = try b.arena.dupe(Run, f.runs.items),
            .items = try b.arena.dupe(Item, f.items.items),
            .inline_boxes = try b.arena.dupe(InlineBox, f.boxes.items),
            .style = f.style,
        });
        // The parent holds the IFC itself if it has no other children
        // and is a plain block container; otherwise an anonymous block.
        const p = &b.tree.boxes.items[parent];
        var holder: BoxId = parent;
        if (!final or p.kind != .block or p.first != none or p.data != none or p.node == .none) {
            holder = try b.add(.{ .kind = .inline_root, .node = .none, .style = try b.anonymousStyle(p.style) });
            b.appendChild(parent, holder);
        } else p.kind = .inline_root;
        b.tree.boxes.items[holder].kind = .inline_root;
        b.tree.boxes.items[holder].data = index;
        for (f.atomics.items) |a| b.appendChild(holder, a);
    }

    /// An anonymous block's style: the parent's inherited values, initial
    /// box values, displayed as a block.
    fn anonymousStyle(b: *Builder, parent: StyleId) Error!StyleId {
        // Every cell of a table makes one: hash the style once per parent.
        if (b.anonymous.get(parent)) |id| return id;
        const p = b.style(parent);
        var s: Style = .{ .inh = p.inh, .custom = p.custom };
        s.box.display = css.style.Display.block;
        const id = try b.store.intern(b.gpa, &s);
        try b.anonymous.put(b.gpa, parent, id);
        return id;
    }

    // Generated content.

    fn pseudo(b: *Builder, parent: BoxId, node: NodeId, owner: StyleId, which: css.selector.PseudoElement) Error!void {
        _ = owner;
        const sid = b.styles.pseudoStyle(node, which) orelse return;
        const st = b.style(sid);
        const content = st.box.content orelse return;
        if (st.box.content_none or st.box.display.isNone()) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(b.gpa);
        for (content.items) |item| switch (item) {
            .string => |s| try out.appendSlice(b.gpa, s),
            .attr => |name| if (b.dom.lookup(name)) |a| {
                if (b.dom.attr(node, a)) |v| try out.appendSlice(b.gpa, v);
            },
            .counter => |c| try formatCounter(b.gpa, &out, b.counterValue(c.name), c.style),
            .counters => |c| {
                var first = true;
                for (b.counters.items) |ctr| if (std.mem.eql(u8, ctr.name, c.name)) {
                    if (!first) try out.appendSlice(b.gpa, c.sep);
                    first = false;
                    try formatCounter(b.gpa, &out, ctr.value, c.style);
                };
            },
            .open_quote => {
                try out.appendSlice(b.gpa, if (b.quote_depth % 2 == 0) "\u{201C}" else "\u{2018}");
                b.quote_depth += 1;
            },
            .close_quote => {
                b.quote_depth -|= 1;
                try out.appendSlice(b.gpa, if (b.quote_depth % 2 == 0) "\u{201D}" else "\u{2019}");
            },
            .no_open_quote => b.quote_depth += 1,
            .no_close_quote => b.quote_depth -|= 1,
            .url => {},
        };
        if (out.items.len == 0 and !st.box.display.isBlockLevel()) return;
        if (st.box.display.isBlockLevel()) {
            const id = try b.add(.{ .kind = .block, .node = node, .style = sid });
            try b.finishIfc(parent, false);
            b.appendChild(parent, id);
            const saved = b.ifc;
            b.ifc = null;
            try b.text(id, out.items, sid, node, false);
            try b.finishIfc(id, true);
            b.ifc = saved;
            return;
        }
        try b.openInline(parent, node, sid);
        try b.text(parent, out.items, sid, node, false);
        try b.closeInline(parent);
    }

    fn marker(b: *Builder, box: BoxId, node: NodeId, sid: StyleId) Error!void {
        const st = b.style(sid);
        const msid = b.styles.pseudoStyle(node, .marker) orelse sid;
        const mst = b.style(msid);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(b.gpa);
        if (mst.box.content) |content| {
            for (content.items) |item| switch (item) {
                .string => |s| try out.appendSlice(b.gpa, s),
                else => {},
            };
        } else switch (st.inh.list_style_type) {
            .none => return,
            .disc => try out.appendSlice(b.gpa, "\u{2022} "),
            .circle => try out.appendSlice(b.gpa, "\u{25E6} "),
            .square => try out.appendSlice(b.gpa, "\u{25AA} "),
            .disclosure_open => try out.appendSlice(b.gpa, "\u{25BE} "),
            .disclosure_closed => try out.appendSlice(b.gpa, "\u{25B8} "),
            .string => try out.appendSlice(b.gpa, st.inh.list_style_string),
            else => |t| {
                try formatCounter(b.gpa, &out, b.counterValue("list-item"), t);
                try out.appendSlice(b.gpa, ". ");
            },
        }
        const outside = st.inh.list_style_position == .outside;
        const index: u32 = @intCast(b.tree.markers.items.len);
        try b.tree.markers.append(b.gpa, .{ .text = try b.arena.dupe(u8, out.items), .style = msid, .outside = outside });
        b.tree.boxes.items[box].marker = index;
        if (!outside) {
            try b.openInline(box, node, msid);
            try b.text(box, out.items, msid, node, false);
            try b.closeInline(box);
        }
    }

    // Counters (CSS Lists 3: list-item and named counters).

    fn counterValue(b: *const Builder, name: []const u8) i32 {
        var i = b.counters.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, b.counters.items[i].name, name)) return b.counters.items[i].value;
        }
        return 0;
    }

    fn findCounter(b: *Builder, name: []const u8) ?*Counter {
        var i = b.counters.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, b.counters.items[i].name, name)) return &b.counters.items[i];
        }
        return null;
    }

    fn applyCounters(b: *Builder, node: NodeId, st: *const Style) Error!void {
        const d = b.dom;
        const n = d.node(node);
        // ol and ul reset list-item; ol[start] and reversed.
        if (n.ns == .html and (n.name == .ol or n.name == .ul or n.name == .menu or n.name == .dir)) {
            var start: i32 = 1;
            var step: i32 = 1;
            if (n.name == .ol) {
                if (d.hasAttr(node, .reversed)) {
                    // Counts its items.
                    var count: i32 = 0;
                    var it = d.children(node);
                    while (it.next()) |c| if (d.isHtml(c, .li)) {
                        count += 1;
                    };
                    start = count;
                    step = -1;
                }
                if (d.attr(node, .start)) |v| start = std.fmt.parseInt(i32, std.mem.trim(u8, v, " "), 10) catch start;
            }
            try b.counters.append(b.gpa, .{ .name = "list-item", .value = start - step, .depth = 0 });
            try b.counters.append(b.gpa, .{ .name = "\x00step", .value = step, .depth = 0 });
        }
        if (st.box.counter_reset) |r| for (r.items) |c| try b.counters.append(b.gpa, .{ .name = c.name, .value = c.value, .depth = 0 });
        if (st.box.counter_set) |r| for (r.items) |c| {
            if (b.findCounter(c.name)) |ctr| ctr.value = c.value else try b.counters.append(b.gpa, .{ .name = c.name, .value = c.value, .depth = 0 });
        };
        if (st.box.display.list_item) {
            const step = b.counterValue("\x00step");
            var incremented = false;
            if (st.box.counter_increment) |inc| for (inc.items) |c| if (std.mem.eql(u8, c.name, "list-item")) {
                incremented = true;
            };
            if (b.findCounter("list-item")) |ctr| {
                if (n.ns == .html and n.name == .li) if (d.attr(node, .value)) |v| {
                    ctr.value = (std.fmt.parseInt(i32, std.mem.trim(u8, v, " "), 10) catch ctr.value + step) - step;
                };
                if (!incremented) ctr.value += if (step == 0) 1 else step;
            } else try b.counters.append(b.gpa, .{ .name = "list-item", .value = 1, .depth = 0 });
        }
        if (st.box.counter_increment) |inc| for (inc.items) |c| {
            if (b.findCounter(c.name)) |ctr| ctr.value += c.value else try b.counters.append(b.gpa, .{ .name = c.name, .value = c.value, .depth = 0 });
        };
    }

    fn popCounters(b: *Builder, depth: usize) void {
        // Counters reset by an element go out of scope after its
        // siblings too; keeping them until the parent ends is CSS's
        // rule, approximated by the element's own extent for lists.
        b.counters.shrinkRetainingCapacity(@min(depth, b.counters.items.len));
    }

    // Tables: anonymous rows and cells (CSS 2.1 17.2.1, the common cases).

    /// Table boxes outside a table (CSS 2.1 17.2.1, 3): each run of
    /// consecutive cells, rows, row groups, and captions in another box
    /// goes into an anonymous table, which `fixTable` completes.
    fn wrapOrphans(b: *Builder, id: BoxId) Error!void {
        const t = b.tree;
        const internal = struct {
            fn f(k: Kind) bool {
                return k == .table_cell or k == .table_row or k == .table_row_group or k == .table_caption;
            }
        }.f;
        var any = false;
        var it = t.children(id);
        while (it.next()) |c| any = any or (internal(t.boxes.items[c].kind) and !t.boxes.items[c].out_of_flow);
        if (!any) return;
        var cur = t.boxes.items[id].first;
        t.boxes.items[id].first = none;
        t.boxes.items[id].last = none;
        var table: BoxId = none;
        while (cur != none) {
            const next = t.boxes.items[cur].next;
            t.boxes.items[cur].next = none;
            if (internal(t.boxes.items[cur].kind) and !t.boxes.items[cur].out_of_flow) {
                if (table == none) {
                    var st: Style = .{ .inh = b.style(t.boxes.items[id].style).inh };
                    st.box.display = .{ .outer = .block, .inner = .table };
                    table = try b.add(.{ .kind = .table, .node = .none, .style = try b.store.intern(b.gpa, &st) });
                    b.appendChild(id, table);
                }
                b.appendChild(table, cur);
            } else {
                if (table != none) try b.fixTable(table);
                table = none;
                b.appendChild(id, cur);
            }
            cur = next;
        }
        if (table != none) try b.fixTable(table);
    }

    fn fixTable(b: *Builder, id: BoxId) Error!void {
        const t = b.tree;
        const kind = t.boxes.items[id].kind;
        if (kind != .table and kind != .table_row_group and kind != .table_row) return b.wrapOrphans(id);
        // Wrap children that do not belong in anonymous ones.
        const want: Kind = switch (kind) {
            .table => .table_row_group,
            .table_row_group => .table_row,
            .table_row => .table_cell,
            else => unreachable,
        };
        var cur = t.boxes.items[id].first;
        t.boxes.items[id].first = none;
        t.boxes.items[id].last = none;
        var wrapper: BoxId = none;
        while (cur != none) {
            const next = t.boxes.items[cur].next;
            t.boxes.items[cur].next = none;
            const ck = t.boxes.items[cur].kind;
            const fits = ck == want or (kind == .table and (ck == .table_caption or ck == .table_row_group)) or (kind == .table and ck == .table_row);
            if (fits or t.boxes.items[cur].out_of_flow) {
                if (kind == .table and ck == .table_row) {
                    // Rows directly in a table get an anonymous group.
                    if (wrapper == none or t.boxes.items[wrapper].kind != .table_row_group) {
                        wrapper = try b.add(.{ .kind = .table_row_group, .node = .none, .style = try b.anonymousStyle(t.boxes.items[id].style) });
                        b.appendChild(id, wrapper);
                    }
                    b.appendChild(wrapper, cur);
                } else {
                    wrapper = none;
                    b.appendChild(id, cur);
                }
            } else {
                if (wrapper == none or t.boxes.items[wrapper].kind != want) {
                    var s: Style = .{ .inh = b.style(t.boxes.items[id].style).inh };
                    s.box.display = .{ .outer = .block, .inner = switch (want) {
                        .table_row_group => .table_row_group,
                        .table_row => .table_row,
                        else => .table_cell,
                    } };
                    wrapper = try b.add(.{ .kind = want, .node = .none, .style = try b.store.intern(b.gpa, &s) });
                    b.appendChild(id, wrapper);
                }
                b.appendChild(wrapper, cur);
                if (want != .table_cell) try b.fixTable(wrapper);
            }
            cur = next;
        }
    }
};

fn isAllSpace(s: []const u8) bool {
    for (s) |c| switch (c) {
        ' ', '\t', '\n', '\r', 0x0C => {},
        else => return false,
    };
    return true;
}

/// text-transform for ASCII and Latin-1 letters (in place; lengths do not
/// change). `before` is the text so far, for capitalize.
fn transform(s: []u8, t: css.style.TextTransform, before: []const u8) void {
    var word_start = before.len == 0 or !std.ascii.isAlphanumeric(before[before.len - 1]);
    for (s) |*ch| {
        switch (t) {
            .uppercase => ch.* = std.ascii.toUpper(ch.*),
            .lowercase => ch.* = std.ascii.toLower(ch.*),
            .capitalize => if (word_start and std.ascii.isAlphabetic(ch.*)) {
                ch.* = std.ascii.toUpper(ch.*);
            },
            else => {},
        }
        word_start = !(std.ascii.isAlphanumeric(ch.*) or ch.* >= 0x80 or ch.* == '\'');
    }
}

pub fn formatCounter(gpa: Allocator, out: *std.ArrayList(u8), value: i32, t: css.style.ListStyleType) Error!void {
    switch (t) {
        .lower_roman, .upper_roman => {
            if (value <= 0 or value >= 4000) return formatCounter(gpa, out, value, .decimal);
            const syms = [_]struct { u32, []const u8 }{ .{ 1000, "m" }, .{ 900, "cm" }, .{ 500, "d" }, .{ 400, "cd" }, .{ 100, "c" }, .{ 90, "xc" }, .{ 50, "l" }, .{ 40, "xl" }, .{ 10, "x" }, .{ 9, "ix" }, .{ 5, "v" }, .{ 4, "iv" }, .{ 1, "i" } };
            var v: u32 = @intCast(value);
            for (syms) |sym| while (v >= sym[0]) {
                for (sym[1]) |ch| try out.append(gpa, if (t == .upper_roman) std.ascii.toUpper(ch) else ch);
                v -= sym[0];
            };
        },
        .lower_alpha, .upper_alpha => {
            if (value <= 0) return formatCounter(gpa, out, value, .decimal);
            var buf: [16]u8 = undefined;
            var n: usize = 0;
            var v: u32 = @intCast(value);
            while (v > 0 and n < buf.len) {
                v -= 1;
                buf[n] = @intCast((if (t == .upper_alpha) @as(u32, 'A') else 'a') + v % 26);
                n += 1;
                v /= 26;
            }
            var i = n;
            while (i > 0) {
                i -= 1;
                try out.append(gpa, buf[i]);
            }
        },
        .lower_greek => {
            if (value <= 0 or value > 24) return formatCounter(gpa, out, value, .decimal);
            var buf: [4]u8 = undefined;
            const cp: u21 = @intCast(0x3B1 + (value - 1) + @as(i32, if (value > 17) 1 else 0));
            const l = std.unicode.utf8Encode(cp, &buf) catch 0;
            try out.appendSlice(gpa, buf[0..l]);
        },
        .decimal_leading_zero => {
            var buf: [16]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d:0>2}", .{@as(u32, @intCast(@max(0, value)))}) catch "");
        },
        else => {
            var buf: [16]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{value}) catch "");
        },
    }
}
