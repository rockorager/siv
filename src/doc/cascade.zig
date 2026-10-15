//! Selector matching and the cascade over a document (CSS Cascade 5):
//! rules indexed by their rightmost id, class, or type, an ancestor Bloom
//! filter that rejects most descendant selectors without walking up,
//! origins, importance, layers, specificity, and order, presentational
//! hints from HTML attributes, inline styles, var() substitution, and
//! computed styles interned in a `Store` so that elements share them.

const std = @import("std");
const html = @import("html");
const css = @import("css");

const Dom = html.Dom;
const NodeId = html.NodeId;
const Atom = html.Atom;
const sel = css.selector;
const props = css.properties;
const Style = css.Style;
const Allocator = std.mem.Allocator;
const Error = error{OutOfMemory};

pub const Origin = enum(u8) { user_agent, user, author };

pub const unbound: u32 = std.math.maxInt(u32);

/// A sheet taking part in the cascade, with its names bound to the
/// document's atoms.
pub const Source = struct {
    sheet: *const css.Sheet,
    origin: Origin,
    /// Per `sheet.store.names`: the atom, or `unbound` when the document
    /// has no such name (selectors needing it cannot match).
    bound: []u32 = &.{},
    /// Lowercased names bound (type and attribute selectors).
    bound_lower: []u32 = &.{},
};

const Entry = struct {
    source: u16,
    rule: u32,
    /// Index into the source's `store.selectors`.
    selector: u32,
    specificity: u32,
    order: u32,
    layer: u16,
    pseudo: sel.PseudoElement,
    /// Atoms an ancestor must have (descendant or child combinators to
    /// the left), checked against the Bloom filter.
    hashes: [4]u32,
};

const Index = struct {
    ids: std.AutoHashMapUnmanaged(u32, std.ArrayList(Entry)) = .empty,
    classes: std.AutoHashMapUnmanaged(u32, std.ArrayList(Entry)) = .empty,
    tags: std.AutoHashMapUnmanaged(u32, std.ArrayList(Entry)) = .empty,
    /// By an attribute the element must have.
    attrs: std.AutoHashMapUnmanaged(u32, std.ArrayList(Entry)) = .empty,
    /// :root's, for the document element.
    root: std.ArrayList(Entry) = .empty,
    universal: std.ArrayList(Entry) = .empty,
};

/// What styling needs to know about each element, precomputed in one
/// pass: classes as atoms, position among siblings.
const Info = struct {
    id: u32 = unbound,
    class_start: u32 = 0,
    class_len: u32 = 0,
    index: u32 = 0,
    count: u32 = 0,
    type_index: u32 = 0,
    type_count: u32 = 0,
};

/// A counting Bloom filter of the atoms of the current element's
/// ancestors (tags, ids, classes).
const Bloom = struct {
    counts: [4096]u8 = @splat(0),

    fn slots(h: u32) [2]u12 {
        const x = h *% 0x9E3779B1;
        return .{ @truncate(x), @truncate(x >> 12) };
    }

    fn add(b: *Bloom, h: u32) void {
        for (slots(h)) |s| b.counts[s] +|= 1;
    }

    fn remove(b: *Bloom, h: u32) void {
        for (slots(h)) |s| {
            if (b.counts[s] != 255) b.counts[s] -|= 1;
        }
    }

    fn mayContain(b: *const Bloom, h: u32) bool {
        for (slots(h)) |s| if (b.counts[s] == 0) return false;
        return true;
    }
};

pub const Env = struct {
    media: css.media.Env = .{},
    /// The user's default font size (`medium`).
    font_size: f32 = 16,
    /// Untrusted HTML (email): nothing is positioned over the page.
    untrusted: bool = false,
};

/// The styles of a document's elements.
pub const Result = struct {
    /// Per DOM node: its computed style (text nodes take their parent's).
    styles: []Style.Id,
    /// ::before, ::after, ::marker styles of elements that have them.
    pseudo: std.AutoHashMapUnmanaged(u64, Style.Id) = .empty,

    pub fn pseudoStyle(r: *const Result, node: NodeId, p: sel.PseudoElement) ?Style.Id {
        return r.pseudo.get(@as(u64, node.index()) << 8 | @intFromEnum(p));
    }
};

pub const Cascade = struct {
    gpa: Allocator,
    /// Computed values with lifetimes of the document (var() results,
    /// nonlinear calc, merged custom properties).
    arena: Allocator,
    dom: *Dom,
    sources: std.ArrayList(Source) = .empty,
    index: Index = .{},
    /// Rules for pseudo-elements, apart: an element looks for each
    /// pseudo-element's rules, and most sheets have few.
    pseudo_index: Index = .{},
    pseudo_rules: [@typeInfo(sel.PseudoElement).@"enum".field_names.len]u32 = @splat(0),
    info: []Info = &.{},
    classes: std.ArrayList(u32) = .empty,
    env: Env = .{},
    bloom: Bloom = .{},
    store: *css.style.Store,
    order: u32 = 0,
    /// Styles shared between elements with the same parent style, rules,
    /// and inline style.
    share: std.AutoHashMapUnmanaged(ShareKey, Style.Id) = .empty,
    /// var() results by declaration text and custom property set.
    substituted: std.AutoHashMapUnmanaged([2]usize, ?props.Value) = .empty,
    /// Languages (from `lang`), index 0 unknown.
    languages: std.StringArrayHashMapUnmanaged(void) = .empty,
    root_font_size: f32 = 16,
    root_line_height: f32 = 19.2,
    matched: std.ArrayList(Matched) = .empty,
    winners: [props.count]?Winner = @splat(null),
    /// The properties with a winner, in the order first set (cleared
    /// after each element, rather than every property).
    winner_ids: [props.count]u8 = undefined,
    winner_len: usize = 0,
    customs_scratch: std.ArrayList(css.sheet.Custom) = .empty,
    /// Grown in `arena`, like what they point to.
    inline_decls: std.ArrayList(props.Declaration) = .empty,
    inline_customs: std.ArrayList(css.sheet.Custom) = .empty,
    hint_decls: std.ArrayList(props.Declaration) = .empty,
    /// The parent's style while `hints` runs.
    hint_parent: Style.Id = 0,
    /// Parsed hints by property name and attribute value.
    hint_memo: std.StringHashMapUnmanaged([]const props.Declaration) = .empty,
    /// Per element: whether a quirks-mode or hint rule applies (unused
    /// in matching, kept for sharing keys).
    pub const ShareKey = struct { parent: Style.Id, rules: u64, extra: u64 };

    const Matched = struct { key: u64, source: u16, rule: u32, important: bool };
    const Winner = struct { value: props.Value };

    pub fn init(gpa: Allocator, arena: Allocator, dom: *Dom, store: *css.style.Store) Cascade {
        return .{ .gpa = gpa, .arena = arena, .dom = dom, .store = store };
    }

    pub fn deinit(c: *Cascade) void {
        c.hint_memo.deinit(c.gpa);
        for (c.sources.items) |s| {
            c.gpa.free(s.bound);
            c.gpa.free(s.bound_lower);
        }
        c.sources.deinit(c.gpa);
        inline for (.{ &c.index, &c.pseudo_index }) |index| {
            inline for (.{ &index.ids, &index.classes, &index.tags, &index.attrs }) |m| {
                var it = m.valueIterator();
                while (it.next()) |l| l.deinit(c.gpa);
                m.deinit(c.gpa);
            }
            index.universal.deinit(c.gpa);
            index.root.deinit(c.gpa);
        }
        c.gpa.free(c.info);
        c.classes.deinit(c.gpa);
        c.share.deinit(c.gpa);
        c.substituted.deinit(c.gpa);
        for (c.languages.keys()) |k| c.gpa.free(k);
        c.languages.deinit(c.gpa);
        c.matched.deinit(c.gpa);
        c.customs_scratch.deinit(c.gpa);
    }

    pub fn language(c: *const Cascade, id: u32) []const u8 {
        if (id == 0 or id > c.languages.count()) return "";
        return c.languages.keys()[id - 1];
    }

    /// Prepares element information (class atoms, sibling positions).
    pub fn prepare(c: *Cascade) Error!void {
        const d = c.dom;
        c.info = try c.gpa.alloc(Info, d.len());
        @memset(c.info, .{});
        for (d.nodes.items, 0..) |n, i| {
            if (n.kind != .element) continue;
            const id: NodeId = @enumFromInt(i);
            var info = &c.info[i];
            if (d.attr(id, .id)) |v| if (v.len > 0) {
                info.id = @intFromEnum(try d.atom(v));
            };
            if (d.attr(id, .class)) |v| {
                // `d.atom` may move the attribute bytes: copy first.
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(c.gpa);
                try buf.appendSlice(c.gpa, v);
                info.class_start = @intCast(c.classes.items.len);
                var it = std.mem.tokenizeAny(u8, buf.items, " \t\n\r\x0C");
                while (it.next()) |cls| try c.classes.append(c.gpa, @intFromEnum(try d.atom(cls)));
                info.class_len = @intCast(c.classes.items.len - info.class_start);
            }
        }
        // Sibling positions.
        var types: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer types.deinit(c.gpa);
        for (d.nodes.items) |n| {
            if (n.first == .none) continue;
            types.clearRetainingCapacity();
            var count: u32 = 0;
            var cur = n.first;
            while (cur != .none) : (cur = d.node(cur).next) {
                const ch = d.node(cur);
                if (ch.kind != .element) continue;
                count += 1;
                c.info[cur.index()].index = count;
                const gop = try types.getOrPut(c.gpa, @intFromEnum(ch.name));
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
                c.info[cur.index()].type_index = gop.value_ptr.*;
            }
            cur = n.first;
            while (cur != .none) : (cur = d.node(cur).next) {
                const ch = d.node(cur);
                if (ch.kind != .element) continue;
                c.info[cur.index()].count = count;
                c.info[cur.index()].type_count = types.get(@intFromEnum(ch.name)).?;
            }
        }
    }

    /// Adds a sheet (after `prepare`, so that its names find the
    /// document's atoms, and with `env` set: rules whose media do not
    /// match are left out) and indexes its rules.
    pub fn addSheet(c: *Cascade, sheet: *const css.Sheet, origin: Origin) Error!void {
        const names = sheet.store.names.items;
        const bound = try c.gpa.alloc(u32, names.len);
        errdefer c.gpa.free(bound);
        const lower = try c.gpa.alloc(u32, names.len);
        errdefer c.gpa.free(lower);
        for (names, bound, lower) |n, *b, *l| {
            b.* = if (c.dom.lookup(n)) |a| @intFromEnum(a) else unbound;
            var buf: [128]u8 = undefined;
            l.* = if (n.len <= buf.len) (if (c.dom.lookup(std.ascii.lowerString(&buf, n))) |a| @intFromEnum(a) else unbound) else b.*;
        }
        const si: u16 = @intCast(c.sources.items.len);
        try c.sources.append(c.gpa, .{ .sheet = sheet, .origin = origin, .bound = bound, .bound_lower = lower });
        const src = &c.sources.items[si];
        for (sheet.rules, 0..) |r, ri| {
            // The environment is fixed for the cascade's life.
            if (!sheet.mediaMatches(r.media, &c.env.media)) {
                c.order += r.selectors[1];
                continue;
            }
            for (r.selectors[0]..r.selectors[0] + r.selectors[1]) |s_index| {
                const s = sheet.store.selectors.items[s_index];
                c.order += 1;
                var e: Entry = .{
                    .source = si,
                    .rule = @intCast(ri),
                    .selector = @intCast(s_index),
                    .specificity = s.specificity,
                    .order = c.order,
                    .layer = r.layer,
                    .pseudo = s.pseudo,
                    .hashes = @splat(unbound),
                };
                const compounds = sheet.store.compoundsOf(s);
                // Unmatchable when a needed name is absent.
                if (!c.possible(src, s)) continue;
                // Ancestor atoms for the Bloom filter.
                var nh: usize = 0;
                var ancestor = false;
                for (compounds, 0..) |cp, k| {
                    if (k > 0 and ancestor) {
                        for (sheet.store.simplesOf(cp)) |simple| {
                            if (nh >= 4) break;
                            const atom = switch (simple.kind) {
                                .id, .class => src.bound[simple.name],
                                .type => src.bound_lower[simple.name],
                                else => unbound,
                            };
                            if (atom != unbound) {
                                e.hashes[nh] = atom;
                                nh += 1;
                            }
                        }
                    }
                    ancestor = cp.combinator == .descendant or cp.combinator == .child or (ancestor and (cp.combinator == .next_sibling or cp.combinator == .subsequent_sibling) and false);
                    if (cp.combinator == .next_sibling or cp.combinator == .subsequent_sibling) ancestor = false;
                }
                // Bucket by the rightmost compound: its id, else a class,
                // else its type, else an attribute it needs; :root for
                // the root alone, and :is() of types and :link under
                // each of their types.
                var kind: u8 = 0;
                var key: u32 = 0;
                for (sheet.store.simplesOf(compounds[0])) |simple| switch (simple.kind) {
                    .id => if (kind < 4) {
                        kind = 4;
                        key = src.bound[simple.name];
                    },
                    .class => if (kind < 3) {
                        kind = 3;
                        key = src.bound[simple.name];
                    },
                    .type => if (kind < 2) {
                        kind = 2;
                        key = src.bound_lower[simple.name];
                    },
                    .attr => if (kind < 1) {
                        kind = 1;
                        key = src.bound_lower[simple.name];
                    },
                    else => {},
                };
                const index = if (s.pseudo == .none) &c.index else &c.pseudo_index;
                c.pseudo_rules[@intFromEnum(s.pseudo)] += 1;
                const map = switch (kind) {
                    4 => &index.ids,
                    3 => &index.classes,
                    2 => &index.tags,
                    1 => &index.attrs,
                    else => null,
                };
                if (map) |m| {
                    if (key == unbound) continue;
                    const gop = try m.getOrPut(c.gpa, key);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(c.gpa, e);
                    continue;
                }
                var tags: std.ArrayList(u32) = .empty;
                defer tags.deinit(c.gpa);
                const special: enum { root, tags, universal } = for (sheet.store.simplesOf(compounds[0])) |simple| switch (simple.kind) {
                    .pseudo => switch (simple.pseudo) {
                        .root => break .root,
                        .link, .any_link => {
                            try tags.appendSlice(c.gpa, &.{ @intFromEnum(Atom.a), @intFromEnum(Atom.area) });
                            break .tags;
                        },
                        else => {},
                    },
                    .is, .where => if (try c.typeList(src, simple, &tags)) break .tags,
                    else => {},
                } else .universal;
                switch (special) {
                    .root => try index.root.append(c.gpa, e),
                    .universal => try index.universal.append(c.gpa, e),
                    .tags => for (tags.items) |t| {
                        const gop = try index.tags.getOrPut(c.gpa, t);
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        try gop.value_ptr.append(c.gpa, e);
                    },
                }
            }
        }
    }

    /// The types an :is() or :where() whose selectors are each a type
    /// alone matches, into `out` (those the document has); false for
    /// other lists.
    fn typeList(c: *Cascade, src: *const Source, simple: sel.Simple, out: *std.ArrayList(u32)) Error!bool {
        const store = &src.sheet.store;
        for (store.selectors.items[simple.list_start..][0..simple.list_len]) |alt| {
            const cps = store.compoundsOf(alt);
            if (cps.len != 1) return false;
            const simples = store.simplesOf(cps[0]);
            if (simples.len != 1 or simples[0].kind != .type) return false;
        }
        out.clearRetainingCapacity();
        for (store.selectors.items[simple.list_start..][0..simple.list_len]) |alt| {
            const t = src.bound_lower[store.simplesOf(store.compoundsOf(alt)[0])[0].name];
            if (t != unbound and std.mem.indexOfScalar(u32, out.items, t) == null) try out.append(c.gpa, t);
        }
        return true;
    }

    /// Whether every id, class, and type the selector needs exists in the
    /// document (outside :not and other lists), and it needs no state a
    /// document never has (:hover and the other user actions).
    fn possible(c: *const Cascade, src: *const Source, s: sel.Selector) bool {
        _ = c;
        const store = &src.sheet.store;
        for (store.compoundsOf(s)) |cp| for (store.simplesOf(cp)) |simple| switch (simple.kind) {
            .id, .class => if (src.bound[simple.name] == unbound) return false,
            .type => if (src.bound_lower[simple.name] == unbound) return false,
            .pseudo => switch (simple.pseudo) {
                .visited, .hover, .active, .focus, .focus_visible, .focus_within, .target, .never, .placeholder_shown => return false,
                else => {},
            },
            else => {},
        };
        return true;
    }

    // Matching.

    fn element(c: *const Cascade, id: NodeId) *const Dom.Node {
        return c.dom.node(id);
    }

    fn parentElement(c: *const Cascade, id: NodeId) NodeId {
        const p = c.dom.node(id).parent;
        if (p == .none or c.dom.node(p).kind != .element) return .none;
        return p;
    }

    fn prevElement(c: *const Cascade, id: NodeId) NodeId {
        var cur = c.dom.node(id).prev;
        while (cur != .none and c.dom.node(cur).kind != .element) cur = c.dom.node(cur).prev;
        return cur;
    }

    fn hasClass(c: *const Cascade, id: NodeId, atom: u32) bool {
        const info = c.info[id.index()];
        for (c.classes.items[info.class_start..][0..info.class_len]) |a| if (a == atom) return true;
        return false;
    }

    fn matchSimple(c: *Cascade, src: *const Source, s: sel.Simple, id: NodeId) bool {
        const d = c.dom;
        const n = d.node(id);
        const store = &src.sheet.store;
        switch (s.kind) {
            .universal => return true,
            .type => {
                const want = src.bound_lower[s.name];
                if (@intFromEnum(n.name) == want) return true;
                // Foreign elements keep their case (foreignObject).
                return n.ns != .html and src.bound[s.name] == @intFromEnum(n.name);
            },
            .id => return c.info[id.index()].id == src.bound[s.name],
            .class => return c.hasClass(id, src.bound[s.name]),
            .attr => {
                const name = src.bound_lower[s.name];
                if (name == unbound) return false;
                const value = for (d.attributes(id)) |at| {
                    if (@intFromEnum(at.name) == name and at.prefix == .none) break d.str(at.value);
                } else return false;
                if (s.op == .exists) return true;
                const want = store.names.items[s.value];
                // Some attributes compare case-insensitively in HTML.
                const ci = s.case_insensitive or (n.ns == .html and isCaseInsensitiveAttr(@enumFromInt(name)));
                const eq = struct {
                    fn f(a: []const u8, b: []const u8, insensitive: bool) bool {
                        return if (insensitive) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
                    }
                }.f;
                return switch (s.op) {
                    .exists => true,
                    .eq => eq(value, want, ci),
                    .includes => blk: {
                        if (want.len == 0) break :blk false;
                        var it = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");
                        while (it.next()) |w| if (eq(w, want, ci)) break :blk true;
                        break :blk false;
                    },
                    .dash => eq(value, want, ci) or (value.len > want.len and value[want.len] == '-' and eq(value[0..want.len], want, ci)),
                    .prefix => want.len > 0 and value.len >= want.len and eq(value[0..want.len], want, ci),
                    .suffix => want.len > 0 and value.len >= want.len and eq(value[value.len - want.len ..], want, ci),
                    .substring => want.len > 0 and (if (ci) std.ascii.findIgnoreCase(value, want) != null else std.mem.indexOf(u8, value, want) != null),
                };
            },
            .pseudo => return c.matchPseudo(s.pseudo, id),
            .nth_child, .nth_last_child => {
                const info = c.info[id.index()];
                var pos: u32 = if (s.kind == .nth_child) info.index else info.count + 1 - info.index;
                if (s.list_len > 0) {
                    // :nth-child(An+B of S): count siblings matching S.
                    if (!c.matchList(src, store.listOf(s), id)) return false;
                    pos = 0;
                    var cur = id;
                    while (cur != .none) {
                        if (c.matchList(src, store.listOf(s), cur)) pos += 1;
                        cur = if (s.kind == .nth_child) c.prevElement(cur) else c.nextElement(cur);
                    }
                }
                return nth(s.a, s.b, pos);
            },
            .nth_of_type, .nth_last_of_type => {
                const info = c.info[id.index()];
                const pos = if (s.kind == .nth_of_type) info.type_index else info.type_count + 1 - info.type_index;
                return nth(s.a, s.b, pos);
            },
            .not => return !c.matchList(src, store.listOf(s), id),
            .is, .where => return c.matchList(src, store.listOf(s), id),
            .has => {
                for (store.listOf(s)) |rel| if (c.matchRelative(src, rel, id)) return true;
                return false;
            },
            .lang => {
                const want = store.names.items[s.name];
                var cur = id;
                while (cur != .none) : (cur = c.parentElement(cur)) {
                    const v = d.attr(cur, .lang) orelse continue;
                    if (std.ascii.eqlIgnoreCase(v, want)) return true;
                    return v.len > want.len and v[want.len] == '-' and std.ascii.eqlIgnoreCase(v[0..want.len], want);
                }
                return false;
            },
            .dir => {
                const want = store.names.items[s.name];
                var cur = id;
                while (cur != .none) : (cur = c.parentElement(cur)) {
                    const v = d.attr(cur, .dir) orelse continue;
                    return std.ascii.eqlIgnoreCase(v, want);
                }
                return std.ascii.eqlIgnoreCase(want, "ltr");
            },
        }
    }

    fn nextElement(c: *const Cascade, id: NodeId) NodeId {
        var cur = c.dom.node(id).next;
        while (cur != .none and c.dom.node(cur).kind != .element) cur = c.dom.node(cur).next;
        return cur;
    }

    fn matchPseudo(c: *Cascade, p: sel.Pseudo, id: NodeId) bool {
        const d = c.dom;
        const n = d.node(id);
        const info = c.info[id.index()];
        return switch (p) {
            .root => id == d.documentElement(),
            .empty => blk: {
                var cur = n.first;
                while (cur != .none) : (cur = d.node(cur).next) {
                    const k = d.node(cur).kind;
                    if (k == .element or (k == .text and d.text(cur).len > 0)) break :blk false;
                }
                break :blk true;
            },
            .first_child => info.index == 1,
            .last_child => info.index == info.count,
            .only_child => info.count == 1,
            .first_of_type => info.type_index == 1,
            .last_of_type => info.type_index == info.type_count,
            .only_of_type => info.type_count == 1,
            .link, .any_link => n.ns == .html and (n.name == .a or n.name == .area) and d.hasAttr(id, .href),
            .checked => n.ns == .html and ((n.name == .input and d.hasAttr(id, .checked)) or (n.name == .option and d.hasAttr(id, .selected))),
            .disabled => n.ns == .html and isFormControl(n.name) and d.hasAttr(id, .disabled),
            .enabled => n.ns == .html and isFormControl(n.name) and !d.hasAttr(id, .disabled),
            .required => d.hasAttr(id, .required),
            .optional => n.ns == .html and isFormControl(n.name) and !d.hasAttr(id, .required),
            .read_only => !(n.ns == .html and (n.name == .input or n.name == .textarea) and !d.hasAttr(id, .readonly)),
            .read_write => n.ns == .html and (n.name == .input or n.name == .textarea) and !d.hasAttr(id, .readonly),
            .placeholder_shown => false,
            .defined => true,
            .scope => id == d.documentElement(),
            .visited, .hover, .active, .focus, .focus_visible, .focus_within, .target, .never => false,
        };
    }

    fn matchList(c: *Cascade, src: *const Source, list: []const sel.Selector, id: NodeId) bool {
        for (list) |s| if (c.matchComplex(src, s, id)) return true;
        return false;
    }

    fn matchCompound(c: *Cascade, src: *const Source, cp: sel.Compound, id: NodeId) bool {
        if (c.dom.node(id).kind != .element) return false;
        for (src.sheet.store.simplesOf(cp)) |s| if (!c.matchSimple(src, s, id)) return false;
        return true;
    }

    pub fn matchComplex(c: *Cascade, src: *const Source, s: sel.Selector, id: NodeId) bool {
        return c.matchFrom(src, src.sheet.store.compoundsOf(s), 0, id);
    }

    /// Matches compounds[k..] with compounds[k] at `id`.
    fn matchFrom(c: *Cascade, src: *const Source, compounds: []const sel.Compound, k: usize, id: NodeId) bool {
        if (!c.matchCompound(src, compounds[k], id)) return false;
        if (k + 1 == compounds.len) return true;
        switch (compounds[k].combinator) {
            .child => {
                const p = c.parentElement(id);
                return p != .none and c.matchFrom(src, compounds, k + 1, p);
            },
            .descendant => {
                var p = c.parentElement(id);
                while (p != .none) : (p = c.parentElement(p)) if (c.matchFrom(src, compounds, k + 1, p)) return true;
                return false;
            },
            .next_sibling => {
                const p = c.prevElement(id);
                return p != .none and c.matchFrom(src, compounds, k + 1, p);
            },
            .subsequent_sibling => {
                var p = c.prevElement(id);
                while (p != .none) : (p = c.prevElement(p)) if (c.matchFrom(src, compounds, k + 1, p)) return true;
                return false;
            },
            .none => return true,
        }
    }

    /// :has(rel): a descendant, child, or following sibling of `id`
    /// matches `rel`, whose leftmost compound relates to `id`.
    fn matchRelative(c: *Cascade, src: *const Source, rel: sel.Selector, id: NodeId) bool {
        const d = c.dom;
        switch (rel.relative) {
            .child, .descendant => {
                var cur = d.node(id).first;
                while (cur != .none) {
                    if (d.node(cur).kind == .element and c.matchComplex(src, rel, cur) and c.anchored(src, rel, cur, id)) return true;
                    cur = if (rel.relative == .child) d.node(cur).next else d.following(cur, id);
                }
            },
            .next_sibling, .subsequent_sibling => {
                var cur = c.nextElement(id);
                while (cur != .none) : (cur = c.nextElement(cur)) {
                    if (c.matchComplex(src, rel, cur)) return true;
                    if (rel.relative == .next_sibling) break;
                }
            },
            .none => {},
        }
        return false;
    }

    /// Whether the leftmost compound of a :has() argument that matched at
    /// `found` is within `anchor` as the argument's combinator says.
    fn anchored(c: *Cascade, src: *const Source, rel: sel.Selector, found: NodeId, anchor: NodeId) bool {
        _ = src;
        if (rel.len > 1) return true; // checked loosely for longer arguments
        return rel.relative == .descendant or c.parentElement(found) == anchor;
    }

    // The cascade.

    fn collect(c: *Cascade, list: []const Entry, id: NodeId, pseudo: sel.PseudoElement) Error!void {
        for (list) |e| {
            if (e.pseudo != pseudo) continue;
            var ok = true;
            for (e.hashes) |h| {
                if (h == unbound) break;
                if (!c.bloom.mayContain(h)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            const src = &c.sources.items[e.source];
            const s = src.sheet.store.selectors.items[e.selector];
            if (!c.matchComplex(src, s, id)) continue;
            const r = src.sheet.rules[e.rule];
            const origin_rank: u64 = @intFromEnum(src.origin);
            const key = origin_rank << 60 | @as(u64, r.layer) << 44 | @as(u64, @min(e.specificity, 0xffffff)) << 20 | @min(e.order, 0xfffff);
            try c.matched.append(c.gpa, .{ .key = key, .source = e.source, .rule = e.rule, .important = false });
        }
    }

    /// The matched rules of an element (or one of its pseudo-elements),
    /// sorted by cascade priority, in `c.matched`.
    fn match(c: *Cascade, id: NodeId, pseudo: sel.PseudoElement) Error!void {
        c.matched.clearRetainingCapacity();
        if (c.pseudo_rules[@intFromEnum(pseudo)] == 0) return;
        const index = if (pseudo == .none) &c.index else &c.pseudo_index;
        const n = c.dom.node(id);
        const info = c.info[id.index()];
        try c.collect(index.universal.items, id, pseudo);
        if (index.root.items.len > 0 and id == c.dom.documentElement()) try c.collect(index.root.items, id, pseudo);
        if (index.tags.get(@intFromEnum(n.name))) |l| try c.collect(l.items, id, pseudo);
        if (index.attrs.count() > 0) for (c.dom.attributes(id)) |at| if (at.prefix == .none) {
            if (index.attrs.get(@intFromEnum(at.name))) |l| try c.collect(l.items, id, pseudo);
        };
        if (info.id != unbound) if (index.ids.get(info.id)) |l| try c.collect(l.items, id, pseudo);
        for (c.classes.items[info.class_start..][0..info.class_len], 0..) |cls, k| {
            // A class listed twice matches once.
            if (std.mem.indexOfScalar(u32, c.classes.items[info.class_start..][0..k], cls) != null) continue;
            if (index.classes.get(cls)) |l| try c.collect(l.items, id, pseudo);
        }
        std.mem.sort(Matched, c.matched.items, {}, struct {
            fn lt(_: void, a: Matched, b: Matched) bool {
                return a.key < b.key;
            }
        }.lt);
    }

    fn pushBloom(c: *Cascade, id: NodeId) void {
        const info = c.info[id.index()];
        c.bloom.add(@intFromEnum(c.dom.node(id).name));
        if (info.id != unbound) c.bloom.add(info.id);
        for (c.classes.items[info.class_start..][0..info.class_len]) |a| c.bloom.add(a);
    }

    fn popBloom(c: *Cascade, id: NodeId) void {
        const info = c.info[id.index()];
        c.bloom.remove(@intFromEnum(c.dom.node(id).name));
        if (info.id != unbound) c.bloom.remove(info.id);
        for (c.classes.items[info.class_start..][0..info.class_len]) |a| c.bloom.remove(a);
    }

    /// Styles every element. Restyling (another media environment) calls
    /// this again; unchanged styles keep their ids.
    pub fn run(c: *Cascade) Error!Result {
        const d = c.dom;
        var result: Result = .{ .styles = try c.gpa.alloc(Style.Id, d.len()) };
        errdefer c.gpa.free(result.styles);
        @memset(result.styles, 0);
        c.bloom = .{};
        c.share.clearRetainingCapacity();
        const root = d.documentElement();
        if (root == .none) return result;
        // Depth-first with an explicit stack of entered elements.
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(c.gpa);
        var cur = root;
        while (cur != .none) {
            const n = d.node(cur);
            if (n.kind == .element) {
                const parent_style = if (cur == root) @as(Style.Id, 0) else result.styles[n.parent.index()];
                result.styles[cur.index()] = try c.styleElement(cur, parent_style, &result, cur == root);
                if (n.first != .none) {
                    c.pushBloom(cur);
                    try stack.append(c.gpa, cur);
                    cur = n.first;
                    continue;
                }
            } else if (n.parent != .none) result.styles[cur.index()] = result.styles[n.parent.index()];
            // Next: sibling, else pop up.
            while (true) {
                const x = d.node(cur);
                if (x.next != .none) {
                    cur = x.next;
                    break;
                }
                const p = stack.pop() orelse {
                    cur = .none;
                    break;
                };
                c.popBloom(p);
                cur = p;
                if (cur == root) {
                    cur = .none;
                    break;
                }
            }
        }
        return result;
    }

    fn styleElement(c: *Cascade, id: NodeId, parent_id: Style.Id, result: *Result, is_root: bool) Error!Style.Id {
        try c.match(id, .none);
        const s = try c.computeMatched(id, parent_id, true, is_root);
        if (is_root) {
            const st = c.store.get(s);
            c.root_font_size = st.inh.font_size;
            c.root_line_height = st.lineHeightPx(st.inh.font_size * 1.2);
        }
        // Pseudo-elements that some rule targets. (Copies: computing
        // their styles may grow the store, which `get` points into.)
        const display = c.store.get(s).box.display;
        if (!display.isNone()) {
            inline for (.{ sel.PseudoElement.before, sel.PseudoElement.after, sel.PseudoElement.marker, sel.PseudoElement.first_letter }) |p| {
                if ((p != .marker or display.list_item) and (p != .first_letter or display.inner == .flow or display.inner == .flow_root)) {
                    try c.match(id, p);
                    if (c.matched.items.len > 0) {
                        const ps = try c.computeMatched(id, s, false, false);
                        try result.pseudo.put(c.gpa, @as(u64, id.index()) << 8 | @intFromEnum(p), ps);
                    }
                }
            }
        }
        return s;
    }

    fn computeMatched(c: *Cascade, id: NodeId, parent_id: Style.Id, element_decls: bool, is_root: bool) Error!Style.Id {
        const d = c.dom;
        // Inline style and hints.
        c.inline_decls.clearRetainingCapacity();
        c.inline_customs.clearRetainingCapacity();
        c.hint_decls.clearRetainingCapacity();
        var inline_text: []const u8 = "";
        if (element_decls) {
            if (d.attr(id, .style)) |v| inline_text = v;
            c.hint_parent = parent_id;
            try c.hints(id);
            if (inline_text.len > 0) try css.sheet.parseInline(c.arena, inline_text, &c.inline_decls, &c.inline_customs);
        }
        // Share with another element with the same inputs.
        var h: std.hash.Wyhash = .init(0);
        for (c.matched.items) |m| h.update(std.mem.asBytes(&[2]u32{ m.source, m.rule }));
        const rules_hash = h.final();
        var hx: std.hash.Wyhash = .init(1);
        hx.update(inline_text);
        for (c.hint_decls.items) |hd| {
            hx.update(std.mem.asBytes(&hd.id));
            hashValue(&hx, hd.value);
        }
        if (element_decls) {
            if (d.attr(id, .lang)) |l| hx.update(l);
            if (d.node(id).ns == .html and d.node(id).name == .html) hx.update("root");
        }
        if (is_root) hx.update("root");
        const key: ShareKey = .{ .parent = parent_id, .rules = rules_hash, .extra = hx.final() };
        if (c.share.get(key)) |s| return s;

        // Winners per property, in priority order: hints (author, zero
        // specificity), matched rules, inline; then important ones.
        for (c.winner_ids[0..c.winner_len]) |pi| c.winners[pi] = null;
        c.winner_len = 0;
        c.customs_scratch.clearRetainingCapacity();
        const P = struct {
            fn set(cc: *Cascade, decls: []const props.Declaration, important: bool) void {
                for (decls) |dd| if (dd.important == important) {
                    const pi = @intFromEnum(dd.id);
                    if (cc.winners[pi] == null) {
                        cc.winner_ids[cc.winner_len] = pi;
                        cc.winner_len += 1;
                    }
                    cc.winners[pi] = .{ .value = dd.value };
                };
            }
        };
        // Normal declarations: UA, user, hints, author, inline.
        var first_author: usize = c.matched.items.len;
        for (c.matched.items, 0..) |m, i| if (c.sources.items[m.source].origin == .author) {
            first_author = i;
            break;
        };
        for (c.matched.items[0..first_author]) |m| {
            const src = &c.sources.items[m.source];
            const r = src.sheet.rules[m.rule];
            P.set(c, src.sheet.ruleDecls(r), false);
            try c.customs_scratch.appendSlice(c.gpa, src.sheet.ruleCustoms(r));
        }
        P.set(c, c.hint_decls.items, false);
        for (c.matched.items[first_author..]) |m| {
            const src = &c.sources.items[m.source];
            const r = src.sheet.rules[m.rule];
            P.set(c, src.sheet.ruleDecls(r), false);
            try c.customs_scratch.appendSlice(c.gpa, src.sheet.ruleCustoms(r));
        }
        P.set(c, c.inline_decls.items, false);
        try c.customs_scratch.appendSlice(c.gpa, c.inline_customs.items);
        // Important: author (layers reversed), inline, then user and UA
        // in reverse order so that the user agent's win.
        var imp: std.ArrayList(Matched) = .empty;
        defer imp.deinit(c.gpa);
        for (c.matched.items[first_author..]) |m| {
            var mm = m;
            const layer: u64 = (m.key >> 44) & 0xffff;
            mm.key = (m.key & ~(@as(u64, 0xffff) << 44)) | ((0xffff - layer) << 44);
            try imp.append(c.gpa, mm);
        }
        std.mem.sort(Matched, imp.items, {}, struct {
            fn lt(_: void, a: Matched, b: Matched) bool {
                return a.key < b.key;
            }
        }.lt);
        for (imp.items) |m| {
            const src = &c.sources.items[m.source];
            P.set(c, src.sheet.ruleDecls(src.sheet.rules[m.rule]), true);
        }
        P.set(c, c.inline_decls.items, true);
        var i = first_author;
        while (i > 0) {
            i -= 1;
            const m = c.matched.items[i];
            const src = &c.sources.items[m.source];
            P.set(c, src.sheet.ruleDecls(src.sheet.rules[m.rule]), true);
        }

        // Compute.
        const parent = c.store.get(parent_id);
        var s: Style = .{ .inh = parent.inh, .custom = parent.custom };
        if (parent_id == 0) s.inh.font_size = c.env.font_size;
        // Decorations propagate to descendants' text.
        if (parent.box.text_decoration_line.any()) {
            const pd = parent.box.text_decoration_line;
            s.inh.decorations = .{ .underline = s.inh.decorations.underline or pd.underline, .overline = s.inh.decorations.overline or pd.overline, .line_through = s.inh.decorations.line_through or pd.line_through };
            s.inh.decoration_color = if (parent.box.text_decoration_color.kind == .current) parent.inh.color else parent.box.text_decoration_color;
            s.inh.decoration_style = parent.box.text_decoration_style;
        }
        if (c.customs_scratch.items.len > 0) s.custom = try c.mergeCustoms(parent.custom, c.customs_scratch.items);
        var cx: props.Ctx = .{
            .a = c.arena,
            .parent = parent,
            .root_font_size = if (is_root) c.env.font_size else c.root_font_size,
            .root_line_height = c.root_line_height,
            .viewport_width = c.env.media.width,
            .viewport_height = c.env.media.height,
            .medium = c.env.font_size,
        };
        // var() substitution, in property order.
        std.mem.sort(u8, c.winner_ids[0..c.winner_len], {}, std.sort.asc(u8));
        for (c.winner_ids[0..c.winner_len]) |pi| if (c.winners[pi]) |win| if (win.value == .unparsed) {
            const w = &c.winners[pi];
            w.* = if (try c.substitute(win.value.unparsed, @enumFromInt(pi), s.custom)) |v| .{ .value = v } else .{ .value = .{ .wide = .unset } };
        };
        const fs = c.winners[@intFromEnum(props.Id.font_size)];
        s.inh.font_size = try props.computeFontSize(if (fs) |f| f.value else null, &cx);
        if (is_root) {
            cx.root_font_size = s.inh.font_size;
        }
        // Color first: currentcolor in other properties reads it.
        if (c.winners[@intFromEnum(props.Id.color)]) |w| try props.apply(&s, .color, w.value, &cx);
        if (c.winners[@intFromEnum(props.Id.line_height)]) |w| try props.apply(&s, .line_height, w.value, &cx);
        for (c.winner_ids[0..c.winner_len]) |pi| {
            const pid: props.Id = @enumFromInt(pi);
            if (pid == .font_size or pid == .color or pid == .line_height) continue;
            try props.apply(&s, pid, c.winners[pi].?.value, &cx);
        }
        // Language.
        if (element_decls) if (d.attr(id, .lang)) |l| {
            s.inh.lang = try c.internLanguage(l);
        };
        if (c.env.untrusted and (s.box.position == .fixed or s.box.position == .absolute)) s.box.position = .static;
        fixup(&s, parent, is_root);
        const out = try c.store.intern(c.gpa, &s);
        try c.share.put(c.gpa, key, out);
        return out;
    }

    fn internLanguage(c: *Cascade, l: []const u8) Error!u32 {
        if (c.languages.getIndex(l)) |i| return @intCast(i + 1);
        const owned = try c.gpa.dupe(u8, l);
        errdefer c.gpa.free(owned);
        try c.languages.put(c.gpa, owned, {});
        return @intCast(c.languages.count());
    }

    fn mergeCustoms(c: *Cascade, parent: ?*const css.style.Custom, decls: []const css.sheet.Custom) Error!*const css.style.Custom {
        // Last declaration wins; important ones over normal ones.
        var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer map.deinit(c.gpa);
        if (parent) |p| for (p.names, p.values) |n, v| try map.put(c.gpa, n, v);
        for ([_]bool{ false, true }) |important| for (decls) |dd| if (dd.important == important) try map.put(c.gpa, dd.name, dd.value);
        const Ctx = struct {
            keys: [][]const u8,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, ctx.keys[a], ctx.keys[b]) == .lt;
            }
        };
        map.sort(Ctx{ .keys = map.keys() });
        const out = try c.arena.create(css.style.Custom);
        out.* = .{ .names = try c.arena.dupe([]const u8, map.keys()), .values = try c.arena.dupe([]const u8, map.values()) };
        return out;
    }

    /// Substitutes var() in an unparsed value and parses the result for
    /// one longhand.
    fn substitute(c: *Cascade, u: *const props.Unparsed, id: props.Id, custom: ?*const css.style.Custom) Error!?props.Value {
        const key: [2]usize = .{ @intFromPtr(u) ^ (@as(usize, @intFromEnum(id)) << 56), @intFromPtr(custom) };
        if (c.substituted.get(key)) |v| return v;
        var out: std.ArrayList(u8) = .empty;
        const ok = try c.expand(u.text, custom, &out, 0);
        var result: ?props.Value = null;
        if (ok) {
            var decls: std.ArrayList(props.Declaration) = .empty;
            const prop: props.Prop = if (u.shorthand) |sh| .{ .shorthand = sh } else .{ .longhand = id };
            // Values outlive this call: tokens and text in the arena.
            const text = try c.arena.dupe(u8, out.items);
            var scratch: std.heap.ArenaAllocator = .init(c.gpa);
            defer scratch.deinit();
            const toks2 = try css.tokenizer.tokenizeInto(c.arena, scratch.allocator(), text);
            try props.parse(c.arena, prop, toks2[0 .. toks2.len - 1], false, &decls);
            for (decls.items) |dd| if (dd.id == id) {
                result = dd.value;
            };
        }
        out.deinit(c.gpa);
        try c.substituted.put(c.gpa, key, result);
        return result;
    }

    /// Writes `text` with var(--x[, fallback]) replaced; false when a
    /// variable is missing without a fallback (the declaration is then
    /// invalid at computed-value time).
    fn expand(c: *Cascade, text: []const u8, custom: ?*const css.style.Custom, out: *std.ArrayList(u8), depth: u32) Error!bool {
        if (depth > 16) return false;
        var i: usize = 0;
        while (i < text.len) {
            const k = std.ascii.findIgnoreCasePos(text, i, "var(") orelse {
                try out.appendSlice(c.gpa, text[i..]);
                break;
            };
            // Not part of a longer identifier.
            if (k > 0 and (std.ascii.isAlphanumeric(text[k - 1]) or text[k - 1] == '-')) {
                try out.appendSlice(c.gpa, text[i .. k + 4]);
                i = k + 4;
                continue;
            }
            try out.appendSlice(c.gpa, text[i..k]);
            // The matching paren.
            var depth_p: usize = 1;
            var j = k + 4;
            while (j < text.len and depth_p > 0) : (j += 1) switch (text[j]) {
                '(' => depth_p += 1,
                ')' => depth_p -= 1,
                '"', '\'' => {
                    const q = text[j];
                    j += 1;
                    while (j < text.len and text[j] != q) : (j += 1) if (text[j] == '\\') {
                        j += 1;
                    };
                },
                else => {},
            };
            const inner = text[k + 4 .. if (depth_p == 0) j - 1 else j];
            i = j;
            const comma = blk: {
                var dp: usize = 0;
                for (inner, 0..) |ch, x| switch (ch) {
                    '(' => dp += 1,
                    ')' => dp -|= 1,
                    ',' => if (dp == 0) break :blk x,
                    else => {},
                };
                break :blk null;
            };
            const name = std.mem.trim(u8, if (comma) |x| inner[0..x] else inner, " \t\n");
            const value = if (custom) |cu| cu.get(name) else null;
            if (value) |v| {
                if (v.len == 0 or std.mem.eql(u8, std.mem.trim(u8, v, " "), "initial")) {
                    if (comma) |x| {
                        if (!try c.expand(inner[x + 1 ..], custom, out, depth + 1)) return false;
                        continue;
                    }
                    return false;
                }
                if (!try c.expand(v, custom, out, depth + 1)) return false;
            } else if (comma) |x| {
                if (!try c.expand(inner[x + 1 ..], custom, out, depth + 1)) return false;
            } else return false;
        }
        return true;
    }

    // Presentational hints (HTML 15.3, the attributes documents and mail
    // still use).

    fn hint(c: *Cascade, name: []const u8, value: []const u8) Error!void {
        const prop = props.lookup(name) orelse return;
        // Mail repeats the same few attributes on thousands of cells: parse
        // each name and value once.
        var kb: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}\x00{s}", .{ name, value }) catch null;
        if (key) |k| if (c.hint_memo.get(k)) |decls| {
            try c.hint_decls.appendSlice(c.arena, decls);
            return;
        };
        const text = try c.arena.dupe(u8, value);
        const toks = try css.tokenizer.tokenizeInto(c.arena, c.arena, text);
        const start = c.hint_decls.items.len;
        try props.parse(c.arena, prop, toks[0 .. toks.len - 1], false, &c.hint_decls);
        if (key) |k| try c.hint_memo.put(c.gpa, try c.arena.dupe(u8, k), try c.arena.dupe(props.Declaration, c.hint_decls.items[start..]));
    }

    fn hintLength(c: *Cascade, name: []const u8, value: []const u8, allow_percent: bool) Error!void {
        // "50", "50px", "50%" (digits, optional fraction, optional %).
        const v = std.mem.trim(u8, value, " \t\n\r");
        var e: usize = 0;
        while (e < v.len and (std.ascii.isDigit(v[e]) or v[e] == '.')) e += 1;
        if (e == 0) return;
        var buf: [32]u8 = undefined;
        const pct = e < v.len and v[e] == '%';
        if (pct and !allow_percent) return;
        const unit = if (pct) "%" else "px";
        // Digits alone are CSS as they are (mail repeats them on every
        // cell); a fraction is normalized ("1." is not CSS).
        const s = if (e <= 16 and std.mem.indexOfScalar(u8, v[0..e], '.') == null)
            std.fmt.bufPrint(&buf, "{s}{s}", .{ v[0..e], unit }) catch return
        else
            std.fmt.bufPrint(&buf, "{d}{s}", .{ std.fmt.parseFloat(f32, v[0..e]) catch return, unit }) catch return;
        try c.hint(name, s);
    }

    fn hintColor(c: *Cascade, name: []const u8, value_: []const u8) Error!void {
        // The legacy color value parser: names, #rgb, and bare hex.
        const value = std.mem.trim(u8, value_, " \t\n\r");
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "transparent")) return;
        if (css.color.named(value) != null) return c.hint(name, value);
        var hex = value;
        if (hex[0] == '#') hex = hex[1..];
        var buf: [16]u8 = undefined;
        var n: usize = 0;
        buf[0] = '#';
        n = 1;
        for (hex) |ch| {
            if (n >= 13) break;
            buf[n] = if (std.ascii.isHex(ch)) ch else '0';
            n += 1;
        }
        const digits = n - 1;
        if (digits == 3 or digits == 6) return c.hint(name, buf[0..n]);
        if (digits > 0) {
            // Pad or cut to six digits, the way browsers read odd values.
            var six: [7]u8 = .{ '#', '0', '0', '0', '0', '0', '0' };
            if (digits < 6) {
                @memcpy(six[1 .. 1 + digits], buf[1..n]);
            } else {
                // Three components, each the first two digits of its third.
                const third = (digits + 2) / 3;
                for (0..3) |k| {
                    const start = 1 + k * third;
                    six[1 + k * 2] = if (start < n) buf[start] else '0';
                    six[2 + k * 2] = if (start + 1 < n) buf[start + 1] else '0';
                }
            }
            return c.hint(name, &six);
        }
    }

    fn hints(c: *Cascade, id: NodeId) Error!void {
        const d = c.dom;
        const n = d.node(id);
        if (n.ns == .svg and n.name == .svg and (n.parent == .none or d.node(n.parent).ns != .svg)) {
            // An outer <svg>'s width and height are presentation
            // attributes (SVG 2, 8.2): `width="100%" height="225"`.
            if (d.attr(id, .width)) |v| try c.hintLength("width", v, true);
            if (d.attr(id, .height)) |v| try c.hintLength("height", v, true);
            return;
        }
        if (n.ns != .html) return;
        const A = struct {
            fn get(dd: *Dom, i: NodeId, a: Atom) ?[]const u8 {
                return dd.attr(i, a);
            }
        };
        // Copy attribute values first (hint parsing may grow the DOM's
        // interner, never its bytes; values stay valid).
        switch (n.name) {
            .body => {
                if (A.get(d, id, .bgcolor)) |v| try c.hintColor("background-color", v);
                if (A.get(d, id, .text)) |v| try c.hintColor("color", v);
                if (A.get(d, id, .background)) |v| try c.hint("background-image", try std.fmt.allocPrint(c.arena, "url(\"{s}\")", .{v}));
                if (A.get(d, id, .marginwidth) orelse A.get(d, id, .leftmargin)) |v| {
                    try c.hintLength("margin-left", v, false);
                    try c.hintLength("margin-right", v, false);
                }
                if (A.get(d, id, .marginheight) orelse A.get(d, id, .topmargin)) |v| {
                    try c.hintLength("margin-top", v, false);
                    try c.hintLength("margin-bottom", v, false);
                }
            },
            .table => {
                if (A.get(d, id, .bgcolor)) |v| try c.hintColor("background-color", v);
                if (A.get(d, id, .background)) |v| try c.hint("background-image", try std.fmt.allocPrint(c.arena, "url(\"{s}\")", .{v}));
                if (A.get(d, id, .width)) |v| try c.hintLength("width", v, true);
                if (A.get(d, id, .height)) |v| try c.hintLength("height", v, true);
                if (A.get(d, id, .cellspacing)) |v| try c.hintLength("border-spacing", v, false);
                if (A.get(d, id, .@"align")) |v| {
                    if (std.ascii.eqlIgnoreCase(v, "center")) {
                        try c.hint("margin-left", "auto");
                        try c.hint("margin-right", "auto");
                    } else if (std.ascii.eqlIgnoreCase(v, "left")) try c.hint("float", "left") else if (std.ascii.eqlIgnoreCase(v, "right")) try c.hint("float", "right");
                }
                if (A.get(d, id, .border)) |v| {
                    const w = std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch 1;
                    if (w > 0) {
                        try c.hint("border", try std.fmt.allocPrint(c.arena, "{d}px outset gray", .{w}));
                    }
                }
            },
            .td, .th, .tr, .thead, .tbody, .tfoot => {
                if (A.get(d, id, .bgcolor)) |v| try c.hintColor("background-color", v);
                if (A.get(d, id, .background)) |v| try c.hint("background-image", try std.fmt.allocPrint(c.arena, "url(\"{s}\")", .{v}));
                if (A.get(d, id, .@"align")) |v| try c.alignHint(v);
                if (A.get(d, id, .valign)) |v| try c.hint("vertical-align", v);
                // HTML's th centers unless its parent aligns otherwise.
                if (n.name == .th and A.get(d, id, .@"align") == null and c.store.get(c.hint_parent).inh.text_align == .start) try c.hint("text-align", "center");
                if (n.name == .td or n.name == .th) {
                    if (A.get(d, id, .width)) |v| try c.hintLength("width", v, true);
                    if (A.get(d, id, .height)) |v| try c.hintLength("height", v, true);
                    if (d.hasAttr(id, .nowrap)) try c.hint("white-space", "nowrap");
                    // cellpadding and border of the table.
                    var t = n.parent;
                    while (t != .none and !d.isHtml(t, .table)) t = d.node(t).parent;
                    if (t != .none) {
                        if (A.get(d, t, .cellpadding)) |v| {
                            try c.hintLength("padding-top", v, true);
                            try c.hintLength("padding-right", v, true);
                            try c.hintLength("padding-bottom", v, true);
                            try c.hintLength("padding-left", v, true);
                        }
                        if (A.get(d, t, .border)) |v| {
                            const w = std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch 1;
                            if (w > 0) try c.hint("border", "1px inset gray");
                        }
                    }
                }
            },
            .col, .colgroup => if (A.get(d, id, .width)) |v| try c.hintLength("width", v, true),
            .img, .video, .canvas, .iframe, .embed, .object, .input => {
                if (A.get(d, id, .width)) |v| try c.hintLength("width", v, true);
                if (A.get(d, id, .height)) |v| try c.hintLength("height", v, true);
                if (A.get(d, id, .border)) |v| if (n.name == .img) {
                    const w = std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch 0;
                    if (w > 0) try c.hint("border", try std.fmt.allocPrint(c.arena, "{d}px solid", .{w}));
                    if (w == 0) try c.hint("border-width", "0");
                };
                if (A.get(d, id, .hspace)) |v| {
                    try c.hintLength("margin-left", v, false);
                    try c.hintLength("margin-right", v, false);
                }
                if (A.get(d, id, .vspace)) |v| {
                    try c.hintLength("margin-top", v, false);
                    try c.hintLength("margin-bottom", v, false);
                }
                if (A.get(d, id, .@"align")) |v| {
                    if (std.ascii.eqlIgnoreCase(v, "left") or std.ascii.eqlIgnoreCase(v, "right")) {
                        try c.hint("float", v);
                    } else if (std.ascii.eqlIgnoreCase(v, "middle") or std.ascii.eqlIgnoreCase(v, "absmiddle")) {
                        try c.hint("vertical-align", "middle");
                    } else if (std.ascii.eqlIgnoreCase(v, "top") or std.ascii.eqlIgnoreCase(v, "bottom")) try c.hint("vertical-align", v);
                }
            },
            .div, .p, .h1, .h2, .h3, .h4, .h5, .h6, .caption, .legend => if (A.get(d, id, .@"align")) |v| try c.alignHint(v),
            .font => {
                if (A.get(d, id, .color)) |v| try c.hintColor("color", v);
                if (A.get(d, id, .face)) |v| try c.hint("font-family", v);
                if (A.get(d, id, .size)) |v| {
                    // Legacy font sizes 1 to 7, absolute or relative to 3.
                    const t = std.mem.trim(u8, v, " ");
                    if (t.len > 0) {
                        const rel = t[0] == '+' or t[0] == '-';
                        const num = std.fmt.parseInt(i32, if (t[0] == '+') t[1..] else t, 10) catch 3;
                        const size = std.math.clamp(if (rel) 3 + num else num, 1, 7);
                        const names = [_][]const u8{ "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large" };
                        try c.hint("font-size", names[@intCast(size - 1)]);
                    }
                }
            },
            .br => if (A.get(d, id, .clear)) |v| {
                // HTML's <br clear>: all and both clear both sides.
                const t = std.mem.trim(u8, v, " ");
                if (std.ascii.eqlIgnoreCase(t, "all") or std.ascii.eqlIgnoreCase(t, "both")) {
                    try c.hint("clear", "both");
                } else if (std.ascii.eqlIgnoreCase(t, "left")) try c.hint("clear", "left") else if (std.ascii.eqlIgnoreCase(t, "right")) try c.hint("clear", "right");
            },
            .hr => {
                if (A.get(d, id, .width)) |v| try c.hintLength("width", v, true);
                if (A.get(d, id, .size)) |v| try c.hintLength("height", v, false);
                if (A.get(d, id, .color)) |v| {
                    try c.hintColor("color", v);
                    try c.hintColor("background-color", v);
                    try c.hint("border-style", "none");
                }
                if (d.hasAttr(id, .noshade)) try c.hint("border-style", "solid");
                if (A.get(d, id, .@"align")) |v| {
                    if (std.ascii.eqlIgnoreCase(v, "left")) {
                        try c.hint("margin-left", "0");
                    } else if (std.ascii.eqlIgnoreCase(v, "right")) try c.hint("margin-right", "0");
                }
            },
            .ol, .ul, .li => if (A.get(d, id, .type)) |v| {
                _ = v;
            },
            .pre => if (A.get(d, id, .width)) |v| {
                _ = v;
            },
            else => {},
        }
    }

    fn alignHint(c: *Cascade, v: []const u8) Error!void {
        const map = [_]struct { []const u8, []const u8 }{ .{ "left", "-webkit-left" }, .{ "right", "-webkit-right" }, .{ "center", "-webkit-center" }, .{ "middle", "-webkit-center" }, .{ "justify", "justify" } };
        for (map) |m| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " "), m[0])) return c.hint("text-align", m[1]);
    }
};

/// Fixes values CSS defines in terms of others (CSS 2.1 9.7: floats and
/// absolute positioning blockify; the root is a block).
fn fixup(s: *Style, parent: *const Style, is_root: bool) void {
    var d = s.box.display;
    if (d.isNone() or d.outer == .contents) {
        if (is_root and d.outer == .contents) s.box.display = Display.block;
        return;
    }
    if (is_root or s.isOutOfFlow() or s.floats() or isFlexOrGridItem(parent)) {
        // Blockify.
        if (d.outer == .@"inline") {
            d.outer = .block;
            if (d.inner == .flow_root and !s.isOutOfFlow() and !s.floats() and !isFlexOrGridItem(parent)) d.inner = .flow;
            if (d.inner == .table_row_group or d.inner == .table_row or d.inner == .table_cell or d.inner == .table_header_group or d.inner == .table_footer_group or d.inner == .table_caption or d.inner == .table_column or d.inner == .table_column_group) d.inner = .flow;
        }
        s.box.display = d;
    }
    if (s.isOutOfFlow()) s.box.float = .none;
    // `match-parent` and `start` resolve at layout from direction.
}

const Display = css.style.Display;

fn isFlexOrGridItem(parent: *const Style) bool {
    const i = parent.box.display.inner;
    return (i == .flex or i == .grid) and !parent.box.display.isNone();
}

fn nth(a: i32, b: i32, pos_: u32) bool {
    const pos: i32 = @intCast(pos_);
    if (a == 0) return pos == b;
    const diff = pos - b;
    if (@rem(diff, a) != 0) return false;
    return @divTrunc(diff, a) >= 0;
}

fn isFormControl(name: Atom) bool {
    return switch (name) {
        .input, .button, .select, .textarea, .optgroup, .option, .fieldset => true,
        else => false,
    };
}

fn isCaseInsensitiveAttr(name: Atom) bool {
    return switch (name) {
        .accept, .@"accept-charset", .@"align", .alink, .axis, .bgcolor, .charset, .checked, .clear, .codetype, .color, .compact, .declare, .@"defer", .dir, .disabled, .enctype, .face, .frame, .hreflang, .@"http-equiv", .lang, .language, .link, .media, .method, .multiple, .nohref, .noresize, .noshade, .nowrap, .readonly, .rel, .rev, .rules, .scope, .scrolling, .selected, .shape, .target, .text, .valign, .valuetype, .vlink => true,
        else => false,
    };
}

fn hashValue(h: *std.hash.Wyhash, v: props.Value) void {
    h.update(std.mem.asBytes(&@intFromEnum(std.meta.activeTag(v))));
    switch (v) {
        .keyword => |k| h.update(&.{k}),
        .number => |n| h.update(std.mem.asBytes(&n)),
        .len => |l| {
            h.update(std.mem.asBytes(&l.v));
            h.update(std.mem.asBytes(&@intFromEnum(l.unit)));
            h.update(std.mem.asBytes(&@intFromEnum(l.tag)));
        },
        .color => |c| h.update(std.mem.asBytes(&[4]f32{ c.r, c.g, c.b, c.a })),
        else => {},
    }
}

test "matching and the cascade" {
    const gpa = std.testing.allocator;
    var dom = try html.parse(gpa,
        \\<!doctype html><html lang=en><body><div id=main class="a b"><p class=x>one</p><p style="color: #0f0">two</p>
        \\<ul><li>1<li>2<li>3</ul><font color=red size=5>f</font><a href=x>link</a></div></body></html>
    , .{});
    defer dom.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var store = try css.style.Store.init(gpa);
    defer store.deinit(gpa);
    var c = Cascade.init(gpa, arena.allocator(), &dom, &store);
    defer c.deinit();
    try c.prepare();
    var ua = try css.sheet.parse(gpa, @import("ua.zig").css, .{});
    defer ua.deinit();
    var author = try css.sheet.parse(gpa,
        \\:root { --gap: 12px }
        \\#main p { margin: var(--gap) 0 }
        \\.a.b > .x { color: blue !important }
        \\p.x { color: red }
        \\li:nth-child(2n+1) { color: purple }
        \\@media (min-width: 1000px) { p { font-size: 40px } }
        \\li::marker { color: orange }
    , .{});
    defer author.deinit();
    c.env.media.width = 800;
    try c.addSheet(&ua, .user_agent);
    try c.addSheet(&author, .author);
    var r = try c.run();
    defer {
        gpa.free(r.styles);
        r.pseudo.deinit(gpa);
    }
    const F = struct {
        fn nth(d: *const Dom, tag: Atom, k: usize) NodeId {
            var n: usize = 0;
            for (d.nodes.items, 0..) |x, i| if (x.kind == .element and x.name == tag) {
                if (n == k) return @enumFromInt(i);
                n += 1;
            };
            unreachable;
        }
    };
    const p1 = F.nth(&dom, .p, 0);
    const s1 = store.get(r.styles[p1.index()]);
    try std.testing.expectEqual(@as(f32, 1), s1.inh.color.b);
    try std.testing.expectEqual(@as(f32, 12), s1.box.margin[0].px);
    try std.testing.expectEqual(@as(f32, 16), s1.inh.font_size);
    try std.testing.expect(s1.box.display.outer == .block);
    const p2 = F.nth(&dom, .p, 1);
    try std.testing.expectEqual(@as(f32, 1), store.get(r.styles[p2.index()]).inh.color.g);
    const li1 = F.nth(&dom, .li, 0);
    const s_li1 = store.get(r.styles[li1.index()]);
    try std.testing.expect(s_li1.box.display.list_item);
    try std.testing.expect(s_li1.inh.color.r > 0.4 and s_li1.inh.color.b > 0.4);
    try std.testing.expect(r.pseudoStyle(li1, .marker) != null);
    const li2 = F.nth(&dom, .li, 1);
    try std.testing.expect(store.get(r.styles[li2.index()]).inh.color.kind == .system);
    // li 1 and 3 share a style.
    try std.testing.expectEqual(r.styles[li1.index()], r.styles[F.nth(&dom, .li, 2).index()]);
    const sf = store.get(r.styles[F.nth(&dom, .font, 0).index()]);
    try std.testing.expectEqual(@as(f32, 1), sf.inh.color.r);
    try std.testing.expectEqual(@as(f32, 24), sf.inh.font_size);
    const sa = store.get(r.styles[F.nth(&dom, .a, 0).index()]);
    try std.testing.expect(sa.box.text_decoration_line.underline);
    try std.testing.expectEqual(css.color.System.link_text, sa.inh.color.system);
    try std.testing.expect(store.count() < 20);
}
