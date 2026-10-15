//! Layout (CSS 2.1 9 and 10, CSS Sizing 3): block flow with margin
//! collapsing, widths and heights with min and max constraints and
//! box-sizing, replaced elements, intrinsic sizes, relative, absolute,
//! and fixed positioning, and the dispatch to inline, flex, grid, and
//! table layout.
//!
//! Layout is incremental in two ways. Each box remembers the width it was
//! laid out at and reuses its layout when asked again at that width
//! (`laid_w`), so a restyle or resize redoes only what changed. And the
//! document's block flow can stop part way, once laid-out content passes
//! a given y, and resume later (`Resume`): the first screen of a long
//! document shows before the rest is laid out, which continues on the
//! worker pool in slices. Inline layout results are caches (`IfcCache`)
//! evicted beyond a memory budget and rebuilt when painted again.

const std = @import("std");
const css = @import("css");
const text = @import("text");
const box_mod = @import("box.zig");
const inline_mod = @import("inline.zig");
const flex_mod = @import("flex.zig");
const grid_mod = @import("grid.zig");
const table_mod = @import("table.zig");

const Allocator = std.mem.Allocator;
const Style = css.Style;
const StyleId = Style.Id;
const Len = css.Len;
const BoxId = box_mod.BoxId;
const Box = box_mod.Box;
const none = box_mod.none;
pub const Error = error{OutOfMemory};

pub const IfcCache = struct {
    shaped: ?*inline_mod.Shaped = null,
    laid: ?*inline_mod.Laid = null,
    /// Last use, for eviction.
    used: u64 = 0,
};

/// Pending absolutely positioned boxes of a containing block.
const Frame = struct {
    box: BoxId,
    start: usize,
};

/// Where an interrupted block flow continues.
pub const Resume = struct {
    /// The next child to lay out (none: done).
    next: BoxId,
    y: f32,
    pos: f32,
    neg: f32,
    first: bool,
    content_top: f32,
    /// The parent's top margin collapsed with its first child's.
    top_collapsed: bool,
};

pub const Engine = struct {
    gpa: Allocator,
    /// Reset by the caller between layout passes.
    scratch: Allocator,
    tree: *box_mod.Tree,
    store: *const css.style.Store,
    fonts: inline_mod.Fonts,
    ifc_cache: []IfcCache,
    /// The initial containing block (the viewport's size).
    viewport_w: f32,
    viewport_h: f32,
    clock: u64 = 0,
    /// Bytes held by the IFC caches, and the budget beyond which the
    /// least recently used are dropped.
    cache_bytes: usize = 0,
    cache_budget: usize = 24 << 20,
    absolutes: std.ArrayList(BoxId) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    /// Resumable flows by box.
    resume_map: std.AutoHashMapUnmanaged(BoxId, Resume) = .empty,
    /// Stop block flow once content passes this y (document
    /// coordinates); infinity lays out everything.
    stop_y: f32 = std.math.inf(f32),
    stopped: bool = false,
    /// Set when shaping used fonts still loading (reshape later).
    incomplete: bool = false,
    /// Height per text byte measured so far, for estimates.
    bytes_laid: usize = 0,
    height_laid: f32 = 0,
    /// Per box: text bytes in its subtree (estimates).
    subtree_bytes: []u32 = &.{},

    pub fn deinit(e: *Engine) void {
        for (e.ifc_cache) |*c| e.drop(c);
        e.gpa.free(e.ifc_cache);
        e.absolutes.deinit(e.gpa);
        e.frames.deinit(e.gpa);
        e.resume_map.deinit(e.gpa);
        e.gpa.free(e.subtree_bytes);
    }

    pub fn style(e: *const Engine, id: BoxId) *const Style {
        return e.store.get(e.tree.get(id).style);
    }

    fn get(e: *const Engine, id: BoxId) *Box {
        return e.tree.get(id);
    }

    // Caches.

    pub fn drop(e: *Engine, c: *IfcCache) void {
        if (c.laid) |l| {
            e.cache_bytes -|= l.bytes();
            l.deinit(e.gpa);
            e.gpa.destroy(l);
            c.laid = null;
        }
        if (c.shaped) |s| {
            e.cache_bytes -|= s.bytes();
            s.deinit();
            e.gpa.destroy(s);
            c.shaped = null;
        }
    }

    /// Drops the least recently used IFC layouts beyond the budget,
    /// sparing those used since `keep_since`.
    pub fn trim(e: *Engine, keep_since: u64) void {
        if (e.cache_bytes <= e.cache_budget) return;
        // Oldest first: collect and sort.
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(e.gpa);
        for (e.ifc_cache, 0..) |c, i| if (c.shaped != null and c.used < keep_since) order.append(e.gpa, @intCast(i)) catch return;
        const S = struct {
            fn lt(cache: []const IfcCache, a: u32, b: u32) bool {
                return cache[a].used < cache[b].used;
            }
        };
        std.mem.sort(u32, order.items, @as([]const IfcCache, e.ifc_cache), S.lt);
        for (order.items) |i| {
            if (e.cache_bytes <= e.cache_budget) break;
            e.drop(&e.ifc_cache[i]);
        }
    }

    pub fn shaped(e: *Engine, ifc: u32) Error!*inline_mod.Shaped {
        const c = &e.ifc_cache[ifc];
        c.used = e.clock;
        if (c.shaped) |s| return s;
        const s = try e.gpa.create(inline_mod.Shaped);
        errdefer e.gpa.destroy(s);
        e.fonts.cache.lockShared();
        defer e.fonts.cache.unlockShared();
        s.* = try inline_mod.shape(e.gpa, e.scratch, &e.tree.ifcs.items[ifc], e.fonts, e.store);
        if (!s.complete) e.incomplete = true;
        c.shaped = s;
        e.cache_bytes += s.bytes();
        return s;
    }

    fn ifcContext(e: *Engine, ifc: u32, s: *const inline_mod.Shaped) inline_mod.Context {
        return .{
            .gpa = e.gpa,
            .scratch = e.scratch,
            .ifc = &e.tree.ifcs.items[ifc],
            .shaped = s,
            .fonts = e.fonts,
            .store = e.store,
            .atomics = .{ .ctx = e, .sizeFn = atomicSize, .intrinsicFn = atomicIntrinsic },
            .tree = e.tree,
        };
    }

    /// An IFC's lines at `width`, laid out if needed.
    pub fn laid(e: *Engine, ifc: u32, width: f32) Error!*inline_mod.Laid {
        const c = &e.ifc_cache[ifc];
        c.used = e.clock;
        if (c.laid) |l| if (l.width == width) return l;
        const s = try e.shaped(ifc);
        const cx = e.ifcContext(ifc, s);
        e.fonts.cache.lockShared();
        const result = inline_mod.layout(&cx, width);
        e.fonts.cache.unlockShared();
        const l = try result;
        if (c.laid) |old| {
            e.cache_bytes -|= old.bytes();
            old.deinit(e.gpa);
        } else c.laid = try e.gpa.create(inline_mod.Laid);
        c.laid.?.* = l;
        e.cache_bytes += l.bytes();
        return c.laid.?;
    }

    fn atomicSize(ctx: *anyopaque, id: BoxId, avail: f32) Error!inline_mod.AtomicSize {
        const e: *Engine = @ptrCast(@alignCast(ctx));
        try e.layoutShrink(id, avail);
        const b = e.get(id);
        const mh = b.margin[0] + b.h + b.margin[2];
        // Inline-blocks align their last line's baseline; others (and
        // overflow other than visible) their bottom margin edge.
        const st = e.style(id);
        const base = if (!std.math.isNan(b.last_baseline) and b.kind != .replaced and st.box.overflow_y == .visible) b.margin[0] + b.last_baseline else mh;
        return .{ .w = b.margin[3] + b.w + b.margin[1], .h = mh, .baseline = base };
    }

    fn atomicIntrinsic(ctx: *anyopaque, id: BoxId, max: bool) Error!f32 {
        const e: *Engine = @ptrCast(@alignCast(ctx));
        return e.intrinsic(id, max, true);
    }

    // Sizes.

    fn resolveEdges(e: *Engine, id: BoxId, cb_w: f32) void {
        const b = e.get(id);
        const st = e.style(id);
        for (0..4) |i| {
            b.padding[i] = st.box.padding[i].resolve(cb_w);
            b.border[i] = st.borderWidth(i);
            b.margin[i] = if (st.box.margin[i].isAuto()) 0 else st.box.margin[i].resolve(cb_w);
        }
    }

    fn horizontalExtras(b: *const Box) f32 {
        return b.padding[1] + b.padding[3] + b.border[1] + b.border[3];
    }

    fn verticalExtras(b: *const Box) f32 {
        return b.padding[0] + b.padding[2] + b.border[0] + b.border[2];
    }

    /// A length as a border-box size (box-sizing applied), or null.
    fn borderBoxLen(e: *const Engine, id: BoxId, l: Len, basis: ?f32, horizontal: bool) ?f32 {
        const v = l.definite(basis) orelse return null;
        const b = e.get(id);
        const extra = if (horizontal) horizontalExtras(b) else verticalExtras(b);
        if (e.style(id).box.box_sizing == .border_box) return @max(v, extra);
        return v + extra;
    }

    fn clampWidth(e: *const Engine, id: BoxId, w: f32, cb_w: f32) f32 {
        const st = e.style(id);
        var r = w;
        if (st.box.max_width.tag == .length) if (e.borderBoxLen(id, st.box.max_width, cb_w, true)) |m| {
            r = @min(r, m);
        };
        if (st.box.min_width.tag == .length) if (e.borderBoxLen(id, st.box.min_width, cb_w, true)) |m| {
            r = @max(r, m);
        };
        return @max(r, horizontalExtras(e.get(id)));
    }

    fn clampHeight(e: *const Engine, id: BoxId, h: f32, cb_h: ?f32) f32 {
        const st = e.style(id);
        var r = h;
        if (st.box.max_height.tag == .length) if (e.borderBoxLen(id, st.box.max_height, cb_h, false)) |m| {
            r = @min(r, m);
        };
        if (st.box.min_height.tag == .length) if (e.borderBoxLen(id, st.box.min_height, cb_h, false)) |m| {
            r = @max(r, m);
        };
        return @max(r, verticalExtras(e.get(id)));
    }

    /// The box's natural size and ratio (replaced elements).
    fn natural(e: *const Engine, id: BoxId) struct { w: f32, h: f32, ratio: f32 } {
        const b = e.get(id);
        const r = e.tree.replaced.items[b.data];
        const st = e.style(id);
        var ratio: f32 = if (r.natural_w > 0 and r.natural_h > 0) r.natural_w / r.natural_h else 0;
        if (st.box.aspect_ratio > 0 and (!st.box.aspect_ratio_auto or ratio == 0)) ratio = st.box.aspect_ratio;
        return .{ .w = r.natural_w, .h = r.natural_h, .ratio = ratio };
    }

    /// CSS 2.1 10.3.2 and 10.6.2: a replaced element's used size.
    fn replacedSize(e: *Engine, id: BoxId, cb_w: f32, cb_h: ?f32) [2]f32 {
        const st = e.style(id);
        const b = e.get(id);
        const nat = e.natural(id);
        const hx = horizontalExtras(b);
        const vx = verticalExtras(b);
        var w: ?f32 = if (e.borderBoxLen(id, st.box.width, cb_w, true)) |v| v - hx else null;
        var h: ?f32 = if (e.borderBoxLen(id, st.box.height, cb_h, false)) |v| v - vx else null;
        if (w == null and h == null) {
            if (nat.w > 0) w = nat.w;
            if (nat.h > 0) h = nat.h;
            if (w != null and h == null and nat.ratio > 0) h = w.? / nat.ratio;
            if (h != null and w == null and nat.ratio > 0) w = h.? * nat.ratio;
        } else if (w == null) {
            w = if (nat.ratio > 0) h.? * nat.ratio else if (nat.w > 0) nat.w else 300;
        } else if (h == null) {
            h = if (nat.ratio > 0) w.? / nat.ratio else if (nat.h > 0) nat.h else 150;
        }
        var ww = w orelse if (nat.ratio > 0 and h != null) h.? * nat.ratio else 0;
        var hh = h orelse if (nat.ratio > 0) ww / nat.ratio else 0;
        // Min and max, keeping the ratio when only one side was given.
        const keep = nat.ratio > 0 and (st.box.width.isAuto() or st.box.height.isAuto());
        const cw = e.clampWidth(id, ww + hx, cb_w) - hx;
        if (cw != ww) {
            if (keep and st.box.height.isAuto()) hh = cw / nat.ratio;
            ww = cw;
        }
        const ch = e.clampHeight(id, hh + vx, cb_h) - vx;
        if (ch != hh) {
            if (keep and st.box.width.isAuto()) ww = ch * nat.ratio;
            hh = ch;
        }
        return .{ ww + hx, hh + vx };
    }

    /// Intrinsic width (min-content or max-content) of a box's margin box
    /// (`margins`) or border box.
    pub fn intrinsic(e: *Engine, id: BoxId, max: bool, margins: bool) Error!f32 {
        const b = e.get(id);
        const st = e.style(id);
        const cached = if (max) b.max_content else b.min_content;
        var w: f32 = 0;
        if (cached >= 0) {
            w = cached;
        } else {
            e.resolveEdges(id, 0);
            const hx = horizontalExtras(e.get(id));
            if (e.borderBoxLen(id, st.box.width, null, true)) |fixed| {
                w = fixed;
            } else switch (e.get(id).kind) {
                .replaced => {
                    const sz = e.replacedSize(id, 0, null);
                    w = sz[0];
                    // A percentage width makes the min-content zero.
                    if (!max and st.box.width.hasPercent()) w = hx;
                },
                .inline_root => {
                    const ifc = e.get(id).data;
                    const s = try e.shaped(ifc);
                    const cx = e.ifcContext(ifc, s);
                    e.fonts.cache.lockShared();
                    const r = inline_mod.intrinsic(&cx);
                    e.fonts.cache.unlockShared();
                    const v = try r;
                    w = (if (max) v[1] else v[0]) + hx;
                },
                .flex => w = try flex_mod.intrinsic(e, id, max) + hx,
                .grid => w = try grid_mod.intrinsic(e, id, max) + hx,
                .table => w = try table_mod.intrinsic(e, id, max),
                else => {
                    var m: f32 = 0;
                    var it = e.tree.children(id);
                    while (it.next()) |c| {
                        if (e.get(c).out_of_flow) continue;
                        m = @max(m, try e.intrinsic(c, max, true));
                    }
                    w = m + hx;
                    if (e.get(id).marker != none and !max) {}
                },
            }
            if (st.box.min_width.tag == .length) if (e.borderBoxLen(id, st.box.min_width, null, true)) |mn| {
                w = @max(w, mn);
            };
            if (st.box.max_width.tag == .length) if (e.borderBoxLen(id, st.box.max_width, null, true)) |mx| {
                w = @min(w, mx);
            };
            const bb = e.get(id);
            if (max) bb.max_content = w else bb.min_content = w;
        }
        if (!margins) return w;
        const bb = e.get(id);
        const ml = if (st.box.margin[3].isAuto()) 0 else st.box.margin[3].resolve(0);
        const mr = if (st.box.margin[1].isAuto()) 0 else st.box.margin[1].resolve(0);
        _ = bb;
        return w + ml + mr;
    }

    /// Shrink-to-fit width (CSS 2.1 10.3.5) of a border box in `avail`.
    pub fn shrinkToFit(e: *Engine, id: BoxId, avail: f32) Error!f32 {
        const mn = try e.intrinsic(id, false, false);
        const mx = try e.intrinsic(id, true, false);
        return @min(@max(mn, avail), mx);
    }

    // Layout.

    /// Lays out an atomic inline or other shrink-to-fit box in `avail`.
    pub fn layoutShrink(e: *Engine, id: BoxId, avail: f32) Error!void {
        const st = e.style(id);
        e.resolveEdges(id, avail);
        const b = e.get(id);
        const margins = b.margin[1] + b.margin[3];
        var w: f32 = undefined;
        if (b.kind == .replaced) {
            const sz = e.replacedSize(id, avail, null);
            return e.layoutAt(id, sz[0], avail, null, sz[1]);
        }
        if (e.borderBoxLen(id, st.box.width, avail, true)) |fixed| {
            w = fixed;
        } else w = try e.shrinkToFit(id, @max(0, avail - margins));
        try e.layoutAt(id, e.clampWidth(id, w, avail), avail, null, null);
    }

    /// Lays out a block-level box in normal flow at its used width for a
    /// containing block of width `cb_w`.
    pub fn layoutBlock(e: *Engine, id: BoxId, cb_w: f32, cb_h: ?f32) Error!void {
        const st = e.style(id);
        e.resolveEdges(id, cb_w);
        const b = e.get(id);
        if (b.kind == .replaced) {
            const sz = e.replacedSize(id, cb_w, cb_h);
            e.autoMargins(id, sz[0], cb_w);
            return e.layoutAt(id, sz[0], cb_w, cb_h, sz[1]);
        }
        var w: f32 = undefined;
        if (e.borderBoxLen(id, st.box.width, cb_w, true)) |fixed| {
            w = fixed;
        } else if (b.kind == .table or st.floats() or st.box.width.tag == .fit_content or st.box.width.tag == .max_content or st.box.width.tag == .min_content) {
            const avail = cb_w - b.margin[1] - b.margin[3];
            w = switch (st.box.width.tag) {
                .min_content => try e.intrinsic(id, false, false),
                .max_content => try e.intrinsic(id, true, false),
                else => if (b.kind == .table) try table_mod.usedWidth(e, id, avail) else try e.shrinkToFit(id, avail),
            };
        } else {
            w = cb_w - b.margin[1] - b.margin[3];
        }
        w = e.clampWidth(id, w, cb_w);
        e.autoMargins(id, w, cb_w);
        try e.layoutAt(id, w, cb_w, cb_h, null);
    }

    /// Auto horizontal margins center a block (CSS 2.1 10.3.3).
    fn autoMargins(e: *Engine, id: BoxId, w: f32, cb_w: f32) void {
        const st = e.style(id);
        const b = e.get(id);
        const ml_auto = st.box.margin[3].isAuto();
        const mr_auto = st.box.margin[1].isAuto();
        const free = cb_w - w - b.margin[1] - b.margin[3];
        if (ml_auto and mr_auto) {
            b.margin[3] = @max(0, free / 2);
            b.margin[1] = @max(0, free / 2);
        } else if (ml_auto) {
            b.margin[3] = @max(0, free);
        } else if (mr_auto) {
            b.margin[1] = free;
        } else if (st.inh.direction == .ltr) {
            // Over-constrained: the right margin gives way.
            b.margin[1] = free + b.margin[1];
        }
    }

    /// Lays out a box's content at border-box width `w`.
    pub fn layoutAt(e: *Engine, id: BoxId, w: f32, cb_w: f32, cb_h: ?f32, fixed_h: ?f32) Error!void {
        const b = e.get(id);
        const st = e.style(id);
        b.w = w;
        if (b.laid_w == w and b.laid_h >= 0 and fixed_h == null and !e.resume_map.contains(id)) {
            b.h = b.laid_h;
            return;
        }
        const content_w = @max(0, w - horizontalExtras(b));
        const own_h: ?f32 = if (fixed_h) |fh| fh else if (e.borderBoxLen(id, st.box.height, cb_h, false)) |h| h else null;
        const content_h: ?f32 = if (own_h) |h| @max(0, h - verticalExtras(b)) else null;
        const positioned = st.isPositioned();
        if (positioned) try e.frames.append(e.gpa, .{ .box = id, .start = e.absolutes.items.len });
        var h: f32 = 0;
        switch (b.kind) {
            .replaced => h = fixed_h orelse e.replacedSize(id, cb_w, cb_h)[1],
            .inline_root => {
                try e.layoutInline(id, content_w);
                h = e.get(id).laid_h + verticalExtras(e.get(id));
            },
            .flex => h = try flex_mod.layout(e, id, content_w, content_h) + verticalExtras(e.get(id)),
            .grid => h = try grid_mod.layout(e, id, content_w, content_h) + verticalExtras(e.get(id)),
            .table => h = try table_mod.layout(e, id, content_w, content_h),
            .table_row_group, .table_row, .table_cell, .table_caption, .block => {
                const ch = try e.blockFlow(id, content_w, content_h);
                h = ch + verticalExtras(e.get(id));
            },
        }
        const bb = e.get(id);
        if (own_h) |oh| h = oh;
        h = e.clampHeight(id, h, cb_h);
        bb.h = h;
        if (!e.resume_map.contains(id)) {
            bb.laid_w = w;
            bb.laid_h = h;
        }
        if (positioned) {
            const f = e.frames.pop().?;
            try e.layoutAbsolutes(f);
        }
    }

    fn layoutInline(e: *Engine, id: BoxId, content_w: f32) Error!void {
        const b = e.get(id);
        const l = try e.laid(b.data, content_w);
        const bb = e.get(id);
        bb.laid_h = l.height;
        const top = bb.border[0] + bb.padding[0];
        const left = bb.border[3] + bb.padding[3];
        bb.baseline = if (l.firstBaseline()) |v| top + v else std.math.nan(f32);
        bb.last_baseline = if (l.lastBaseline()) |v| top + v else std.math.nan(f32);
        e.bytes_laid += e.tree.ifcs.items[bb.data].text.len;
        e.height_laid += l.height;
        // Place atomic inlines from their fragments.
        for (l.lines) |line| for (l.lineFrags(line)) |f| {
            if (f.kind != .atomic) continue;
            const ab = e.get(f.box);
            const sz = try atomicSize(e, f.box, content_w);
            ab.x = left + f.x + ab.margin[3];
            ab.y = top + line.baseline + f.shift - sz.baseline + ab.margin[0];
            e.relativeOffset(f.box, content_w);
        };
        // Out-of-flow boxes in the IFC: static position at their place.
        const ifc = &e.tree.ifcs.items[bb.data];
        for (ifc.items) |it| {
            if (it.kind != .atomic or !e.get(it.index).out_of_flow) continue;
            var y: f32 = top;
            var x: f32 = left;
            for (l.lines) |line| if (it.offset >= line.start and it.offset <= line.end) {
                y = top + line.top;
                x = left + line.left;
                break;
            };
            try e.outOfFlow(it.index, x, y);
        }
    }

    /// Records an out-of-flow box's static position and queues it for its
    /// containing block.
    fn outOfFlow(e: *Engine, id: BoxId, x: f32, y: f32) Error!void {
        const b = e.get(id);
        b.static_x = x;
        b.static_y = y;
        try e.absolutes.append(e.gpa, id);
    }

    const Collapse = struct {
        pos: f32 = 0,
        neg: f32 = 0,

        fn add(c: *Collapse, m: f32) void {
            if (m > 0) c.pos = @max(c.pos, m) else c.neg = @min(c.neg, m);
        }

        fn value(c: Collapse) f32 {
            return c.pos + c.neg;
        }
    };

    /// Lays out block-level children; returns the content height.
    fn blockFlow(e: *Engine, id: BoxId, content_w: f32, content_h: ?f32) Error!f32 {
        const b = e.get(id);
        const st = e.style(id);
        const top = b.border[0] + b.padding[0];
        const left = b.border[3] + b.padding[3];
        const bfc = st.establishesBfc() or b.parent == none or e.get(b.parent).kind != .block;
        const top_open = !bfc and b.border[0] == 0 and b.padding[0] == 0;
        var state: Resume = if (e.resume_map.get(id)) |r| r else .{ .next = b.first, .y = top, .pos = 0, .neg = 0, .first = true, .content_top = top, .top_collapsed = false };
        var pending: Collapse = .{ .pos = state.pos, .neg = state.neg };
        var cur = state.next;
        var laid_any = false;
        while (cur != none) {
            const c = e.get(cur);
            if (c.out_of_flow) {
                try e.outOfFlow(cur, left, state.y + pending.value());
                cur = c.next;
                continue;
            }
            const resuming = e.resume_map.contains(cur);
            // Stop before this child, to continue later, once the flow
            // has passed the stopping point (after at least one child).
            if (!resuming and laid_any and e.stop_y < std.math.inf(f32) and e.absoluteY(id) + state.y + pending.value() > e.stop_y and e.resumable(id)) {
                e.stopped = true;
                state.next = cur;
                state.pos = pending.pos;
                state.neg = pending.neg;
                try e.resume_map.put(e.gpa, id, state);
                return state.y + pending.value() - top + e.estimateFrom(cur);
            }
            if (!resuming) c.y = state.y + pending.value();
            try e.layoutBlock(cur, content_w, content_h);
            const cc = e.get(cur);
            cc.x = left + cc.margin[3];
            if (resuming) {
                // Its margins and place were settled when it started.
                cc.y = state.y;
            } else {
                const empty = cc.h == 0 and isCollapseThrough(e, cur) and !e.resume_map.contains(cur);
                if (empty) {
                    pending.add(cc.margin[0]);
                    pending.add(cc.margin[2]);
                    cc.y = state.y + pending.value();
                    cur = cc.next;
                    continue;
                }
                pending.add(cc.margin[0]);
                if (state.first and top_open) {
                    // The first child's top margin collapses with ours.
                    state.top_collapsed = true;
                    b.margin[0] = mergeMargins(b.margin[0], pending.value());
                    pending = .{};
                }
                cc.y = state.y + pending.value();
            }
            state.first = false;
            const unshifted_y = cc.y;
            e.relativeOffset(cur, content_w);
            const parent = e.get(id);
            if (std.math.isNan(parent.baseline) and !std.math.isNan(cc.baseline)) parent.baseline = unshifted_y + cc.baseline;
            if (!std.math.isNan(cc.last_baseline)) parent.last_baseline = unshifted_y + cc.last_baseline;
            if (e.stopped) {
                // The child stopped part way: so do we, resuming it.
                state.next = cur;
                state.y = unshifted_y;
                state.pos = 0;
                state.neg = 0;
                try e.resume_map.put(e.gpa, id, state);
                return unshifted_y + cc.h - top + e.estimateFrom(cc.next);
            }
            state.y = unshifted_y + cc.h;
            pending = .{};
            pending.add(cc.margin[2]);
            laid_any = true;
            cur = cc.next;
        }
        _ = e.resume_map.remove(id);
        const bottom_open = !bfc and b.border[2] == 0 and b.padding[2] == 0 and content_h == null;
        if (bottom_open) {
            b.margin[2] = mergeMargins(b.margin[2], pending.value());
        } else state.y += pending.value();
        // Absolutely positioned descendants of the root or a BFC root
        // that is positioned are laid out by `layoutAt`'s frame.
        return state.y - top;
    }

    fn isCollapseThrough(e: *const Engine, id: BoxId) bool {
        const b = e.get(id);
        return b.kind == .block and b.first == none and b.border[0] == 0 and b.border[2] == 0 and b.padding[0] == 0 and b.padding[2] == 0;
    }

    fn mergeMargins(a: f32, b: f32) f32 {
        var c: Collapse = .{};
        c.add(a);
        c.add(b);
        return c.value();
    }

    /// Whether a box's flow may stop part way: a plain block with auto
    /// height whose ancestors are plain blocks too.
    fn resumable(e: *const Engine, id: BoxId) bool {
        var cur = id;
        while (cur != none) : (cur = e.get(cur).parent) {
            const b = e.get(cur);
            if (b.kind != .block) return false;
            const st = e.style(cur);
            if (!st.box.height.isAuto() or st.isOutOfFlow() or st.box.overflow_y != .visible) return false;
        }
        return true;
    }

    /// The y of a box's border box in document coordinates (from its
    /// ancestors' positions laid out so far).
    pub fn absoluteY(e: *const Engine, id: BoxId) f32 {
        var y: f32 = 0;
        var cur = id;
        while (cur != none) : (cur = e.get(cur).parent) y += e.get(cur).y;
        return y;
    }

    pub fn absoluteX(e: *const Engine, id: BoxId) f32 {
        var x: f32 = 0;
        var cur = id;
        while (cur != none) : (cur = e.get(cur).parent) x += e.get(cur).x;
        return x;
    }

    /// The estimated height of siblings from `from` on, by text size.
    fn estimateFrom(e: *const Engine, from: BoxId) f32 {
        var bytes: u64 = 0;
        var n: u32 = 0;
        var cur = from;
        while (cur != none) : (cur = e.get(cur).next) {
            bytes += if (cur < e.subtree_bytes.len) e.subtree_bytes[cur] else 0;
            n += 1;
        }
        const per: f32 = if (e.bytes_laid > 1000) e.height_laid / @as(f32, @floatFromInt(e.bytes_laid)) else 0.25;
        return @as(f32, @floatFromInt(bytes)) * per + @as(f32, @floatFromInt(n)) * 8;
    }

    fn relativeDy(e: *const Engine, id: BoxId, cb_w: f32) f32 {
        const st = e.style(id);
        if (st.box.position != .relative) return 0;
        if (!st.box.inset[0].isAuto()) return st.box.inset[0].resolve(cb_w);
        if (!st.box.inset[2].isAuto()) return -st.box.inset[2].resolve(cb_w);
        return 0;
    }

    /// Moves a relatively positioned box by its insets.
    fn relativeOffset(e: *Engine, id: BoxId, cb_w: f32) void {
        const st = e.style(id);
        if (st.box.position != .relative) return;
        const b = e.get(id);
        if (!st.box.inset[3].isAuto()) {
            b.x += st.box.inset[3].resolve(cb_w);
        } else if (!st.box.inset[1].isAuto()) b.x -= st.box.inset[1].resolve(cb_w);
        b.y += e.relativeDy(id, cb_w);
    }

    /// Lays out the out-of-flow boxes queued since `f.start` whose
    /// containing block is `f.box`.
    fn layoutAbsolutes(e: *Engine, f: Frame) Error!void {
        var i = f.start;
        while (i < e.absolutes.items.len) {
            const id = e.absolutes.items[i];
            // Fixed boxes wait for the root.
            if (e.style(id).box.position == .fixed and e.get(f.box).parent != none) {
                i += 1;
                continue;
            }
            _ = e.absolutes.orderedRemove(i);
            try e.layoutAbsolute(id, f.box);
        }
    }

    /// CSS 2.1 10.3.7 and 10.6.4 in the common cases.
    fn layoutAbsolute(e: *Engine, id: BoxId, cb: BoxId) Error!void {
        const cbb = e.get(cb);
        const cb_w = if (cbb.parent == none) e.viewport_w else cbb.w - cbb.border[1] - cbb.border[3];
        const cb_h = if (cbb.parent == none) e.viewport_h else cbb.h - cbb.border[0] - cbb.border[2];
        const st = e.style(id);
        e.resolveEdges(id, cb_w);
        const b = e.get(id);
        const left = st.box.inset[3];
        const right = st.box.inset[1];
        const top = st.box.inset[0];
        const bottom = st.box.inset[2];
        var w: f32 = undefined;
        if (b.kind == .replaced) {
            w = e.replacedSize(id, cb_w, cb_h)[0];
        } else if (e.borderBoxLen(id, st.box.width, cb_w, true)) |fixed| {
            w = fixed;
        } else if (!left.isAuto() and !right.isAuto()) {
            w = cb_w - left.resolve(cb_w) - right.resolve(cb_w) - b.margin[1] - b.margin[3];
        } else w = try e.shrinkToFit(id, cb_w - b.margin[1] - b.margin[3] - (if (left.isAuto()) 0 else left.resolve(cb_w)) - (if (right.isAuto()) 0 else right.resolve(cb_w)));
        w = e.clampWidth(id, w, cb_w);
        var fixed_h: ?f32 = null;
        if (st.box.height.isAuto() and !top.isAuto() and !bottom.isAuto() and b.kind != .replaced) {
            fixed_h = e.clampHeight(id, cb_h - top.resolve(cb_h) - bottom.resolve(cb_h) - b.margin[0] - b.margin[2], cb_h);
        }
        try e.layoutAt(id, w, cb_w, cb_h, fixed_h);
        const bb = e.get(id);
        // Position in the containing block's padding box.
        const pad_x = cbb.border[3];
        const pad_y = cbb.border[0];
        // The static position is relative to the box's parent.
        const parent_in_cb = e.offsetIn(bb.parent, cb);
        var x: f32 = undefined;
        if (!left.isAuto()) {
            x = pad_x + left.resolve(cb_w) + bb.margin[3];
        } else if (!right.isAuto()) {
            x = pad_x + cb_w - right.resolve(cb_w) - bb.w - bb.margin[1];
        } else x = parent_in_cb[0] + bb.static_x + bb.margin[3];
        var y: f32 = undefined;
        if (!top.isAuto()) {
            y = pad_y + top.resolve(cb_h) + bb.margin[0];
        } else if (!bottom.isAuto()) {
            y = pad_y + cb_h - bottom.resolve(cb_h) - bb.h - bb.margin[2];
        } else y = parent_in_cb[1] + bb.static_y + bb.margin[0];
        bb.x = x - parent_in_cb[0];
        bb.y = y - parent_in_cb[1];
    }

    /// The offset of box `id`'s border box within `ancestor`'s.
    fn offsetIn(e: *const Engine, id: BoxId, ancestor: BoxId) [2]f32 {
        var x: f32 = 0;
        var y: f32 = 0;
        var cur = id;
        while (cur != none and cur != ancestor) : (cur = e.get(cur).parent) {
            x += e.get(cur).x;
            y += e.get(cur).y;
        }
        return .{ x, y };
    }

    /// Lays out the whole tree from the root, or continues an interrupted
    /// layout. Returns whether layout finished.
    pub fn run(e: *Engine) Error!bool {
        e.stopped = false;
        e.clock += 1;
        const root = e.tree.root;
        if (root == none) return true;
        const r = e.get(root);
        r.x = 0;
        r.y = 0;
        try e.frames.append(e.gpa, .{ .box = root, .start = 0 });
        if (!e.resume_map.contains(root)) {
            e.absolutes.clearRetainingCapacity();
            e.frames.items[0].start = 0;
        }
        try e.layoutAt(root, e.viewport_w, e.viewport_w, e.viewport_h, null);
        const f = e.frames.pop().?;
        if (!e.stopped) {
            // Fixed boxes too, against the viewport.
            const i = f.start;
            while (i < e.absolutes.items.len) {
                const id = e.absolutes.items[i];
                _ = e.absolutes.orderedRemove(i);
                try e.layoutAbsolute(id, root);
            }
        }
        // The canvas is at least the viewport tall.
        return !e.stopped;
    }

    /// Forgets layouts so that the next run lays out every box again
    /// (a new width, new styles). Shaping stays cached.
    pub fn invalidate(e: *Engine, intrinsic_too: bool) void {
        for (e.tree.boxes.items) |*b| {
            b.laid_w = -1;
            b.laid_h = -1;
            b.baseline = std.math.nan(f32);
            b.last_baseline = std.math.nan(f32);
            if (intrinsic_too) {
                b.min_content = -1;
                b.max_content = -1;
            }
        }
        e.resume_map.clearRetainingCapacity();
        e.absolutes.clearRetainingCapacity();
        e.bytes_laid = 0;
        e.height_laid = 0;
    }

    /// Drops all shaping (fonts changed).
    pub fn reshapeAll(e: *Engine) void {
        for (e.ifc_cache) |*c| e.drop(c);
        e.invalidate(true);
    }

    /// Computes `subtree_bytes` for estimates.
    pub fn measureTree(e: *Engine) Error!void {
        e.gpa.free(e.subtree_bytes);
        e.subtree_bytes = try e.gpa.alloc(u32, e.tree.boxes.items.len);
        @memset(e.subtree_bytes, 0);
        // Children always come after their parents in the box array
        // except for anonymous wrappers, so sum in reverse twice.
        var i = e.tree.boxes.items.len;
        while (i > 0) {
            i -= 1;
            const b = e.tree.boxes.items[i];
            if (b.kind == .inline_root) e.subtree_bytes[i] +|= @intCast(@min(std.math.maxInt(u32), e.tree.ifcs.items[b.data].text.len));
        }
        // Propagate up by walking each box's ancestors (depth is small).
        const own = try e.gpa.dupe(u32, e.subtree_bytes);
        defer e.gpa.free(own);
        for (own, 0..) |v, idx| {
            if (v == 0) continue;
            var p = e.tree.boxes.items[idx].parent;
            while (p != none) : (p = e.tree.boxes.items[p].parent) e.subtree_bytes[p] +|= v;
        }
    }

    /// The height of the document laid out so far, with the rest
    /// estimated.
    pub fn documentHeight(e: *const Engine) f32 {
        const root = e.tree.root;
        if (root == none) return 0;
        var h = e.get(root).h;
        // Descendants that overflow the root (absolute boxes) extend it.
        h = @max(h, e.overflowBottom(root, 0, 0));
        return h;
    }

    fn overflowBottom(e: *const Engine, id: BoxId, y0: f32, depth: u32) f32 {
        if (depth > 3) return 0;
        var m: f32 = 0;
        var it = e.tree.children(id);
        while (it.next()) |c| {
            const b = e.get(c);
            if (b.out_of_flow) m = @max(m, y0 + b.y + b.h);
            if (depth < 3) m = @max(m, e.overflowBottom(c, y0 + b.y, depth + 1));
        }
        return m;
    }
};
