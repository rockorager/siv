//! Flex layout (CSS Flexible Box Layout 1, section 9): flex base sizes
//! from definite bases, main sizes, aspect ratios, or content; automatic
//! minimum sizes (4.5); lines; resolving flexible lengths by freezing
//! (9.7); hypothetical and stretched cross sizes; baselines; auto
//! margins, justify-content, align-self, and align-content with
//! `wrap-reverse` and reversed directions; `order`; `visibility:
//! collapse` items as struts; out-of-flow children's static positions
//! (4.1); and the container's intrinsic sizes (9.9) and baselines (8.5).

const std = @import("std");
const css = @import("css");
const layout_mod = @import("layout.zig");
const box_mod = @import("box.zig");

const Engine = layout_mod.Engine;
const Error = layout_mod.Error;
const BoxId = box_mod.BoxId;
const Box = box_mod.Box;
const Align = css.style.Align;
const Len = css.Len;
const inf = std.math.inf(f32);

const Item = struct {
    id: BoxId,
    grow: f32,
    shrink: f32,
    /// Margins with auto as 0, and which are auto (top right bottom left).
    m: [4]f32 = .{ 0, 0, 0, 0 },
    auto: [4]bool = .{ false, false, false, false },
    /// Border-box sizes in the main axis.
    base: f32 = 0,
    hypo: f32 = 0,
    min: f32 = 0,
    max: f32 = inf,
    target: f32 = 0,
    frozen: bool = false,
    violation: f32 = 0,
    collapsed: bool = false,
    strut: f32 = 0,
    /// Margins in the main axis, and padding and borders there.
    mm: f32 = 0,
    extras: f32 = 0,
    /// The border-box cross size: hypothetical, then used.
    cross: f32 = 0,
    stretch: bool = false,
    /// align-self, resolved, and whether it is `safe`.
    al: Align = .normal,
    safe: bool = false,
    /// Baseline alignment (rows): the distance from the margin box's
    /// top to the first (or last) baseline.
    baseline: f32 = 0,
    /// Offsets of the margin box in the line: main from the line's
    /// start, cross from the line's top (or left).
    main_pos: f32 = 0,
    cross_pos: f32 = 0,
};

const Line = struct {
    start: usize,
    end: usize,
    cross: f32 = 0,
    /// Physical offset of the line's top (rows) or left (columns).
    pos: f32 = 0,
    baseline: f32 = 0,
    last_below: f32 = 0,
};

/// The direction-dependent view of a container.
const Axes = struct {
    row: bool,
    reverse: bool,
    wrap: bool,
    wrap_reverse: bool,

    fn of(st: *const css.Style) Axes {
        const d = st.box.flex_direction;
        return .{
            .row = d == .row or d == .row_reverse,
            .reverse = d == .row_reverse or d == .column_reverse,
            .wrap = st.box.flex_wrap != .nowrap,
            .wrap_reverse = st.box.flex_wrap == .wrap_reverse,
        };
    }

    /// The margin on the main-start side (the right in row-reverse).
    fn mainStart(a: Axes) usize {
        return if (a.row) (if (a.reverse) 1 else 3) else (if (a.reverse) 2 else 0);
    }
    fn mainEnd(a: Axes) usize {
        return if (a.row) (if (a.reverse) 3 else 1) else (if (a.reverse) 0 else 2);
    }
    /// The physical top (rows) or left (columns) margin: cross positions
    /// are physical.
    fn crossStart(a: Axes) usize {
        return if (a.row) 0 else 3;
    }
    fn crossEnd(a: Axes) usize {
        return if (a.row) 2 else 1;
    }
};

fn outerMain(it: *const Item, size: f32) f32 {
    return size + it.mm;
}

fn crossMargins(a: Axes, it: *const Item) f32 {
    return it.m[a.crossStart()] + it.m[a.crossEnd()];
}

/// The in-flow children in order-modified document order.
fn collect(e: *Engine, id: BoxId) Error![]Item {
    var list: std.ArrayList(Item) = .empty;
    var reordered = false;
    var it = e.tree.children(id);
    while (it.next()) |c| {
        if (e.tree.get(c).out_of_flow) continue;
        const st = e.style(c);
        reordered = reordered or st.box.order != 0;
        try list.append(e.scratch, .{ .id = c, .grow = @min(st.box.flex_grow, 1e30), .shrink = @min(st.box.flex_shrink, 1e30) });
    }
    if (reordered) std.sort.insertion(Item, list.items, e, struct {
        fn lt(en: *Engine, x: Item, y: Item) bool {
            return en.style(x.id).box.order < en.style(y.id).box.order;
        }
    }.lt);
    return list.items;
}

fn gapOf(l: Len, basis: ?f32) f32 {
    return if (l.tag == .length) l.resolve(basis orelse 0) else 0;
}

/// The intrinsic inline size of a flex container's content (9.9.1, as
/// browsers compute it): items' contributions summed along a row (the
/// largest min-content one when it wraps), or the largest across a
/// column.
pub fn intrinsic(e: *Engine, id: BoxId, max: bool, inner_h: ?f32) Error!f32 {
    const st = e.style(id);
    const a = Axes.of(st);
    const its = try collect(e, id);
    const gap = gapOf(st.box.column_gap, null);
    var sum: f32 = 0;
    var mx: f32 = 0;
    for (its, 0..) |item, i| {
        // A collapsed item is a strut: no size along the main axis.
        if (a.row and e.style(item.id).inh.visibility == .collapse) continue;
        var w = try e.intrinsic(item.id, max, true);
        if (a.row and !a.wrap) if (inner_h) |h| {
            // An item with a ratio stretched to a definite height.
            const ist = e.style(item.id);
            const al = if (ist.box.align_self == .auto) st.box.align_items else ist.box.align_self;
            if ((al == .stretch or al == .normal) and ist.box.height.isAuto() and ist.box.width.isAuto() and !ist.box.margin[0].isAuto() and !ist.box.margin[2].isAuto() and ratioOf(e, item.id) > 0) {
                const mt = ist.box.margin[0].resolve(0) + ist.box.margin[2].resolve(0);
                const ml = ist.box.margin[1].resolve(0) + ist.box.margin[3].resolve(0);
                var cross = @max(0, h - mt);
                if (e.borderBoxLen0(item.id, ist.box.max_height, false)) |v| cross = @min(cross, v);
                if (e.borderBoxLen0(item.id, ist.box.min_height, false)) |v| cross = @max(cross, v);
                var tw = transferWith(e, item.id, cross, true, e.extras0(item.id, true), e.extras0(item.id, false));
                if (e.borderBoxLen0(item.id, ist.box.max_width, true)) |v| tw = @min(tw, v);
                if (e.borderBoxLen0(item.id, ist.box.min_width, true)) |v| tw = @max(tw, v);
                w = tw + ml;
            }
        };
        sum += w + if (i > 0) gap else 0;
        mx = @max(mx, w);
    }
    if (!a.row) return mx;
    if (!max and a.wrap) return mx;
    return sum;
}

/// The preferred aspect ratio of an item (width / height), or 0.
fn ratioOf(e: *Engine, id: BoxId) f32 {
    const b = e.tree.get(id);
    if (b.kind == .replaced) return e.natural(id).ratio;
    return e.style(id).box.aspect_ratio;
}

/// Converts a border-box size on one axis to the other through the
/// item's ratio (the content box's for replaced elements and
/// `box-sizing: content-box`).
fn transfer(e: *Engine, id: BoxId, size: f32, to_width: bool) f32 {
    const b = e.tree.get(id);
    return transferWith(e, id, size, to_width, Engine.horizontalExtras(b), Engine.verticalExtras(b));
}

fn transferWith(e: *Engine, id: BoxId, size: f32, to_width: bool, hx: f32, vx: f32) f32 {
    const b = e.tree.get(id);
    const r = ratioOf(e, id);
    const border_box = b.kind != .replaced and e.style(id).box.box_sizing == .border_box;
    if (border_box) return if (to_width) @max(size * r, hx) else @max(size / r, vx);
    return if (to_width) @max(0, size - vx) * r + hx else @max(0, size - hx) / r + vx;
}

/// A definite border-box size of an item on one axis from its property
/// (width or height), or null.
fn definiteSize(e: *Engine, id: BoxId, horizontal: bool, basis: ?f32) ?f32 {
    const st = e.style(id);
    return e.borderBoxLen(id, if (horizontal) st.box.width else st.box.height, basis, horizontal);
}

fn clampAxis(e: *Engine, id: BoxId, horizontal: bool, v: f32, basis: ?f32) f32 {
    return if (horizontal) e.clampWidth(id, v, basis orelse 0) else e.clampHeight(id, v, basis);
}

/// The height of an item's content at border-box width `w` (its height
/// property and limits apart): its min-content and max-content height.
fn contentHeight(e: *Engine, id: BoxId, w: f32, cb_w: f32, cb_h: ?f32) Error!f32 {
    const b = e.tree.get(id);
    if (b.kind == .replaced) {
        const r = ratioOf(e, id);
        if (r > 0) return transfer(e, id, w, false);
        return e.natural(id).h + Engine.verticalExtras(b);
    }
    try e.layoutSized(id, w, cb_w, cb_h, .{ .content = true });
    return e.tree.get(id).h;
}

/// A replaced item's border-box height at border-box width `w`.
fn replacedHeight(e: *Engine, id: BoxId, w: f32, cb_h: ?f32) f32 {
    if (definiteSize(e, id, false, cb_h)) |h| return e.clampHeight(id, h, cb_h);
    const r = ratioOf(e, id);
    const h = if (r > 0) transfer(e, id, w, false) else e.natural(id).h + Engine.verticalExtras(e.tree.get(id));
    return e.clampHeight(id, h, cb_h);
}

/// Lays out a flex container's content; returns its content height.
/// `content_h` is the inner height it has (null when its content sizes
/// it), `pct_h` that height when definite, `cb_h` its containing block's
/// height (for its own min-height and max-height).
pub fn layout(e: *Engine, id: BoxId, content_w: f32, content_h: ?f32, pct_h: ?f32, cb_h: ?f32) Error!f32 {
    const st = e.style(id);
    const a = Axes.of(st);
    const its = try collect(e, id);
    const cb = e.tree.get(id);
    const left = cb.border[3] + cb.padding[3];
    const top = cb.border[0] + cb.padding[0];
    const vx = Engine.verticalExtras(cb);
    const main_gap = if (a.row) gapOf(st.box.column_gap, content_w) else gapOf(st.box.row_gap, pct_h);
    const cross_gap = if (a.row) gapOf(st.box.row_gap, pct_h) else gapOf(st.box.column_gap, content_w);
    // The container's inner height limits (min-height, max-height).
    const min_h: f32 = if (e.borderBoxLen(id, st.box.min_height, cb_h, false)) |v| @max(0, v - vx) else 0;
    const max_h: f32 = if (e.borderBoxLen(id, st.box.max_height, cb_h, false)) |v| @max(0, v - vx) else inf;
    const inner_main: ?f32 = if (a.row) content_w else content_h;
    const inner_cross: ?f32 = if (a.row) content_h else content_w;
    // Percentages of items' sizes: against the container's definite
    // inner sizes.
    const main_basis: ?f32 = if (a.row) content_w else pct_h;
    const cross_basis: ?f32 = if (a.row) pct_h else content_w;
    const single = !a.wrap;
    const mark = e.absolutes.items.len;

    // Margins, alignment, and which items stretch.
    for (its) |*it| {
        const ist = e.style(it.id);
        e.resolveEdges(it.id, content_w);
        const b = e.tree.get(it.id);
        it.m = b.margin;
        for (0..4) |k| it.auto[k] = ist.box.margin[k].isAuto();
        it.al = if (ist.box.align_self == .auto) st.box.align_items else ist.box.align_self;
        it.safe = if (ist.box.align_self == .auto) st.box.align_safe.align_items else ist.box.align_safe.align_self;
        if (!a.row and (it.al == .baseline or it.al == .last_baseline)) it.al = .flex_start;
        const cross_auto = if (a.row) ist.box.height.isAuto() else ist.box.width.isAuto();
        it.stretch = (it.al == .stretch or it.al == .normal) and cross_auto and !it.auto[a.crossStart()] and !it.auto[a.crossEnd()];
        it.collapsed = ist.inh.visibility == .collapse;
        it.mm = it.m[a.mainStart()] + it.m[a.mainEnd()];
        it.extras = if (a.row) Engine.horizontalExtras(b) else Engine.verticalExtras(b);
    }

    // Flex base sizes and hypothetical main sizes (9.2.3), and the
    // automatic minimum sizes (4.5).
    for (its) |*it| {
        try baseSize(e, a, it, content_w, inner_cross, main_basis, cross_basis, single);
        if (it.collapsed) {
            // A strut (4.4): its cross size from its own main size, and
            // nothing along the main axis.
            it.strut = it.hypo;
            it.base = 0;
            it.hypo = 0;
            it.min = 0;
            it.mm = 0;
        }
    }

    // The container's main size, when its content sizes it (a column
    // without a definite height): its items' hypothetical sizes.
    var avail_main: f32 = inner_main orelse @min(max_h, inf);
    if (inner_main == null) {
        var sum: f32 = 0;
        for (its, 0..) |*it, i| sum += outerMain(it, it.hypo) + if (i > 0) main_gap else 0;
        if (!a.wrap or max_h == inf) avail_main = std.math.clamp(sum, min_h, @max(min_h, max_h));
    }

    // Lines (9.3).
    var lines: std.ArrayList(Line) = .empty;
    {
        var start: usize = 0;
        var used: f32 = 0;
        for (its, 0..) |*it, i| {
            const outer = outerMain(it, it.hypo);
            if (a.wrap and i > start and used + main_gap + outer > avail_main + 0.01) {
                try lines.append(e.scratch, .{ .start = start, .end = i });
                start = i;
                used = 0;
            }
            used += outer + if (i > start) main_gap else 0;
        }
        try lines.append(e.scratch, .{ .start = start, .end = its.len });
    }
    if (inner_main == null and a.wrap and max_h != inf) {
        // Wrapped at the max-height: as tall as the longest line.
        var longest: f32 = 0;
        for (lines.items) |ln| {
            var sum: f32 = 0;
            for (its[ln.start..ln.end], 0..) |*it, i| sum += outerMain(it, it.hypo) + if (i > 0) main_gap else 0;
            longest = @max(longest, sum);
        }
        avail_main = std.math.clamp(longest, min_h, @max(min_h, max_h));
    }
    const container_main = avail_main;

    // Flexible lengths (9.7).
    for (lines.items) |ln| resolveLine(its[ln.start..ln.end], container_main, main_gap);
    // Hypothetical cross sizes (9.4, 7).
    for (its) |*it| try hypotheticalCross(e, a, it, content_w, cross_basis, inner_cross, single, pct_h != null);

    // Line cross sizes and baselines (9.4, 8).
    for (lines.items) |*ln| {
        var m: f32 = 0;
        var above: f32 = -inf;
        var below: f32 = -inf;
        var last_above: f32 = -inf;
        var last_below: f32 = -inf;
        for (its[ln.start..ln.end]) |*it| {
            const outer = it.cross + crossMargins(a, it);
            if (a.row and (it.al == .baseline or it.al == .last_baseline) and !it.auto[0] and !it.auto[2]) {
                const b = e.tree.get(it.id);
                if (it.al == .baseline) {
                    const bl = if (!std.math.isNan(b.baseline)) b.baseline else it.cross;
                    it.baseline = it.m[0] + bl;
                    above = @max(above, it.baseline);
                    below = @max(below, outer - it.baseline);
                } else {
                    const bl = if (!std.math.isNan(b.last_baseline)) b.last_baseline else it.cross;
                    it.baseline = it.m[0] + bl;
                    last_above = @max(last_above, it.baseline);
                    last_below = @max(last_below, outer - it.baseline);
                }
            } else m = @max(m, outer);
        }
        ln.cross = @max(m, @max(above + below, last_above + last_below));
        ln.baseline = @max(0, above);
        ln.last_below = @max(0, last_below);
    }
    if (single) {
        if (inner_cross) |c| {
            lines.items[0].cross = c;
        } else if (a.row) {
            lines.items[0].cross = std.math.clamp(lines.items[0].cross, min_h, @max(min_h, max_h));
        }
    }

    // The container's cross size, and align-content (9.4, 9 and 15).
    var sum_cross: f32 = 0;
    for (lines.items, 0..) |ln, i| sum_cross += ln.cross + if (i > 0) cross_gap else 0;
    const container_cross: f32 = inner_cross orelse if (a.row) std.math.clamp(sum_cross, min_h, @max(min_h, max_h)) else sum_cross;
    {
        const n: f32 = @floatFromInt(lines.items.len);
        var free = container_cross - sum_cross;
        var offset: f32 = 0;
        var between: f32 = cross_gap;
        if (!single) {
            // In cross-start terms (the bottom of a wrap-reverse row).
            var ac = st.box.align_content;
            if (a.wrap_reverse) ac = switch (ac) {
                .start => .end,
                .end => .start,
                else => ac,
            };
            switch (ac) {
                .normal, .stretch => if (free > 0) {
                    for (lines.items) |*ln| ln.cross += free / n;
                    free = 0;
                },
                .center => offset = free / 2,
                .end, .flex_end => offset = free,
                .space_between => if (n > 1 and free > 0) {
                    between += free / (n - 1);
                },
                .space_around => if (free > 0) {
                    offset = free / n / 2;
                    between += free / n;
                } else {
                    offset = free / 2;
                },
                .space_evenly => if (free > 0) {
                    offset = free / (n + 1);
                    between += free / (n + 1);
                } else {
                    offset = free / 2;
                },
                else => {},
            }
        }
        if (st.box.align_safe.align_content and free < 0) offset = if (a.wrap_reverse) free else 0;
        var pos = offset;
        for (lines.items) |*ln| {
            ln.pos = if (a.wrap_reverse) container_cross - pos - ln.cross else pos;
            pos += ln.cross + between;
        }
    }

    // Stretched cross sizes (9.4, 11), then cross alignment (9.6).
    for (lines.items) |ln| for (its[ln.start..ln.end]) |*it| {
        if (it.stretch and !it.collapsed) {
            const want = clampAxis(e, it.id, !a.row, @max(0, ln.cross - crossMargins(a, it)), cross_basis);
            // Laid out again even at the same size: the stretched size is
            // definite (9.8), for percentages inside.
            {
                it.cross = want;
                if (a.row) {
                    try e.layoutSized(it.id, it.target, content_w, pct_h, .{ .h = want });
                } else try e.layoutSized(it.id, want, content_w, pct_h, .{ .h = it.target, .definite = pct_h != null });
            }
        }
        crossAlign(e, a, it, ln);
    };

    // Main axis alignment (9.5), and the boxes' places.
    for (lines.items, 0..) |ln, li| {
        const line = its[ln.start..ln.end];
        mainAlign(a, st.box.justify_content, st.box.align_safe.justify_content, line, container_main, main_gap);
        for (line) |*it| {
            const b = e.tree.get(it.id);
            const main_size = it.target;
            var main = it.main_pos + it.m[a.mainStart()];
            if (a.reverse) main = container_main - main - main_size;
            const cross = ln.pos + it.cross_pos + it.m[a.crossStart()];
            if (a.row) {
                b.x = left + main;
                b.y = top + cross;
                b.w = main_size;
                b.h = it.cross;
            } else {
                b.x = left + cross;
                b.y = top + main;
                b.w = it.cross;
                b.h = main_size;
            }
            b.margin = it.m;
            e.relativeOffset(it.id, content_w);
            _ = li;
        }
    }

    try baselines(e, id, a, its, lines.items);

    // Out-of-flow children: static positions as if each were the only
    // item (4.1). Their own measuring left none behind.
    e.absolutes.shrinkRetainingCapacity(mark);
    try staticPositions(e, id, st, a, left, top, content_w, if (a.row) container_cross else container_main);
    // Layouts done while measuring queued out-of-flow descendants once
    // each; the last layout of each item queued them again.
    for (its) |*it| try requeue(e, it.id);

    return if (a.row) container_cross else container_main;
}

/// Queues the out-of-flow descendants of an item that its containing
/// block lays out (the item laid out several times dropped them).
fn requeue(e: *Engine, id: BoxId) Error!void {
    if (e.style(id).isPositioned()) return;
    var it = e.tree.children(id);
    while (it.next()) |c| {
        if (e.tree.get(c).out_of_flow) {
            try e.absolutes.append(e.gpa, c);
        } else if (e.tree.get(c).kind != .replaced) try requeue(e, c);
    }
}

fn baseSize(e: *Engine, a: Axes, it: *Item, content_w: f32, inner_cross: ?f32, main_basis: ?f32, cross_basis: ?f32, single: bool) Error!void {
    const ist = e.style(it.id);
    const b = e.tree.get(it.id);
    const replaced = b.kind == .replaced;
    const ratio = ratioOf(e, it.id);
    const main_prop = if (a.row) ist.box.width else ist.box.height;
    const extras = if (a.row) Engine.horizontalExtras(b) else Engine.verticalExtras(b);
    // A definite cross size: the property's, or a stretched one in a
    // single-line container of definite cross size (9.8, 1).
    var cross_def: ?f32 = definiteSize(e, it.id, !a.row, cross_basis);
    if (cross_def == null and it.stretch and single) if (inner_cross) |c| {
        cross_def = clampAxis(e, it.id, !a.row, @max(0, c - crossMargins(a, it)), cross_basis);
    };
    if (cross_def) |c| cross_def = clampAxis(e, it.id, !a.row, c, cross_basis);

    const basis = ist.box.flex_basis;
    var base: ?f32 = null;
    if (basis.tag == .length) base = e.borderBoxLen(it.id, basis, main_basis, a.row);
    if (base == null and basis.tag == .auto) {
        base = e.borderBoxLen(it.id, main_prop, main_basis, a.row);
        if (base == null and a.row) base = try e.keywordWidth(it.id, main_prop, true);
    }
    if (base == null and ratio > 0 and cross_def != null) base = transfer(e, it.id, cross_def.?, a.row);
    if (base == null) {
        // Content: max-content (9.2.3, E).
        if (a.row) {
            base = try e.contentWidth(it.id, true);
        } else {
            const w = cross_def orelse try fitWidth(e, it, content_w);
            base = if (replaced) replacedHeight(e, it.id, w, null) else try contentHeight(e, it.id, w, content_w, null);
        }
    }
    it.base = @max(base.?, extras);

    // Min and max main sizes.
    const min_prop = if (a.row) ist.box.min_width else ist.box.min_height;
    const max_prop = if (a.row) ist.box.max_width else ist.box.max_height;
    it.max = inf;
    if (e.borderBoxLen(it.id, max_prop, main_basis, a.row)) |v| {
        it.max = v;
    } else if (a.row) if (try e.keywordWidth(it.id, max_prop, true)) |v| {
        it.max = v;
    };
    it.min = extras;
    if (e.borderBoxLen(it.id, min_prop, main_basis, a.row)) |v| {
        it.min = v;
    } else if ((min_prop.isAuto() or (!a.row and (min_prop.tag == .min_content or min_prop.tag == .max_content or min_prop.tag == .fit_content))) and (ist.box.overflow_x == .visible or ist.box.overflow_x == .clip) and (ist.box.overflow_y == .visible or ist.box.overflow_y == .clip)) {
        // The content-based minimum size (4.5).
        var content: f32 = undefined;
        if (a.row) {
            content = try e.contentWidth(it.id, false);
            // A replaced item's content width follows a definite (or
            // stretched) height through its ratio.
            if (replaced and ratio > 0) if (cross_def) |c| {
                content = transfer(e, it.id, c, true);
            };
        } else {
            const w = cross_def orelse try fitWidth(e, it, content_w);
            content = if (replaced) replacedHeight(e, it.id, w, null) else try contentHeight(e, it.id, w, content_w, null);
        }
        if (ratio > 0) {
            // The cross size's limits, transferred.
            const cmin = if (a.row) ist.box.min_height else ist.box.min_width;
            const cmax = if (a.row) ist.box.max_height else ist.box.max_width;
            if (e.borderBoxLen(it.id, cmax, cross_basis, !a.row)) |v| content = @min(content, transfer(e, it.id, v, a.row));
            if (e.borderBoxLen(it.id, cmin, cross_basis, !a.row)) |v| content = @max(content, transfer(e, it.id, v, a.row));
        }
        var auto_min = content;
        if (e.borderBoxLen(it.id, main_prop, main_basis, a.row)) |spec| {
            auto_min = @min(auto_min, spec);
        } else if (replaced and ratio > 0) if (cross_def) |c| {
            auto_min = @min(auto_min, transfer(e, it.id, c, a.row));
        };
        it.min = @max(extras, @min(auto_min, it.max));
    } else if (a.row) if (try e.keywordWidth(it.id, min_prop, false)) |v| {
        it.min = v;
    };
    it.hypo = std.math.clamp(it.base, it.min, @max(it.min, it.max));
}

/// A column item's fit-content width: its contribution clamped to the
/// container's inner width less its margins.
fn fitWidth(e: *Engine, it: *Item, content_w: f32) Error!f32 {
    const avail = @max(0, content_w - it.m[1] - it.m[3]);
    if (definiteSize(e, it.id, true, content_w)) |w| return e.clampWidth(it.id, w, content_w);
    if (try e.keywordWidth(it.id, e.style(it.id).box.width, true)) |w| return e.clampWidth(it.id, w, content_w);
    const b = e.tree.get(it.id);
    if (b.kind == .replaced) return e.clampWidth(it.id, try e.contentWidth(it.id, true), content_w);
    const mn = try e.contentWidth(it.id, false);
    const mx = try e.contentWidth(it.id, true);
    return e.clampWidth(it.id, @min(@max(mn, avail), mx), content_w);
}

/// Resolves the flexible lengths of a line's items (9.7).
fn resolveLine(line: []Item, container: f32, gap: f32) void {
    const gaps = gap * @as(f32, @floatFromInt(@max(1, line.len) - 1));
    var sum_hypo: f32 = gaps;
    for (line) |*it| sum_hypo += it.hypo + it.mm;
    const growing = sum_hypo < container;
    for (line) |*it| {
        it.target = it.hypo;
        const factor = if (growing) it.grow else it.shrink;
        it.frozen = it.collapsed or factor == 0 or (growing and it.base > it.hypo) or (!growing and it.base < it.hypo);
    }
    var initial = container - gaps;
    for (line) |*it| initial -= it.mm + if (it.frozen) it.target else it.base;
    var guard: usize = 0;
    while (guard <= line.len) : (guard += 1) {
        var free = container - gaps;
        var sum_flex: f32 = 0;
        var sum_scaled: f32 = 0;
        var any = false;
        for (line) |*it| {
            free -= it.mm;
            if (it.frozen) {
                free -= it.target;
            } else {
                free -= it.base;
                any = true;
                sum_flex += if (growing) it.grow else it.shrink;
                sum_scaled += it.shrink * @max(0, it.base - it.extras);
            }
        }
        if (!any) break;
        if (sum_flex < 1 and @abs(initial * sum_flex) < @abs(free)) free = initial * sum_flex;
        var total: f32 = 0;
        for (line) |*it| {
            if (it.frozen) continue;
            var t = it.base;
            if (free != 0) {
                if (growing) {
                    if (sum_flex > 0) t += free * it.grow / sum_flex;
                } else if (sum_scaled > 0) {
                    t += free * it.shrink * @max(0, it.base - it.extras) / sum_scaled;
                }
            }
            const clamped = std.math.clamp(t, it.min, @max(it.min, it.max));
            it.violation = clamped - t;
            total += it.violation;
            it.target = clamped;
        }
        // Freeze all (no violation), the min violations, or the max ones.
        for (line) |*it| {
            if (it.frozen) continue;
            if (@abs(total) < 0.001 or (total > 0 and it.violation > 0) or (total < 0 and it.violation < 0)) it.frozen = true;
        }
    }
}

fn hypotheticalCross(e: *Engine, a: Axes, it: *Item, content_w: f32, cross_basis: ?f32, inner_cross: ?f32, single: bool, main_definite: bool) Error!void {
    const b = e.tree.get(it.id);
    if (it.collapsed) {
        it.target = it.strut;
        defer it.target = 0;
        return hypotheticalCross2(e, a, it, b, content_w, cross_basis, inner_cross, single, main_definite);
    }
    return hypotheticalCross2(e, a, it, b, content_w, cross_basis, inner_cross, single, main_definite);
}

fn hypotheticalCross2(e: *Engine, a: Axes, it: *Item, b: *Box, content_w: f32, cross_basis: ?f32, inner_cross: ?f32, single: bool, main_definite: bool) Error!void {
    if (a.row) {
        if (b.kind == .replaced) {
            const h = replacedHeight(e, it.id, it.target, cross_basis);
            try e.layoutSized(it.id, it.target, content_w, cross_basis, .{ .h = h });
        } else try e.layoutSized(it.id, it.target, content_w, cross_basis, .{});
        it.cross = e.tree.get(it.id).h;
    } else {
        var w: f32 = undefined;
        if (it.stretch and single and inner_cross != null) {
            w = clampAxis(e, it.id, true, @max(0, inner_cross.? - it.m[1] - it.m[3]), content_w);
        } else if (b.kind == .replaced and definiteSize(e, it.id, true, content_w) == null and ratioOf(e, it.id) > 0) {
            w = e.clampWidth(it.id, transfer(e, it.id, it.target, true), content_w);
        } else w = try fitWidth(e, it, content_w);
        try e.layoutSized(it.id, w, content_w, cross_basis, .{ .h = it.target, .definite = main_definite });
        it.cross = w;
    }
}

fn crossAlign(e: *Engine, a: Axes, it: *Item, ln: Line) void {
    _ = e;
    const cs = a.crossStart();
    const ce = a.crossEnd();
    const free = ln.cross - it.cross - it.m[cs] - it.m[ce];
    // Auto margins take the free space first (9.6, 13).
    if (it.auto[cs] or it.auto[ce]) {
        if (free > 0) {
            if (it.auto[cs] and it.auto[ce]) {
                it.m[cs] += free / 2;
                it.m[ce] += free / 2;
            } else if (it.auto[cs]) it.m[cs] += free else it.m[ce] += free;
        } else if (it.auto[cs]) {
            it.m[ce] += free;
        } else it.m[ce] += free;
        it.cross_pos = 0;
        return;
    }
    if (it.stretch) {
        it.cross_pos = 0;
        return;
    }
    const physical_end = switch (it.al) {
        .end, .self_end => true,
        .flex_end => !a.wrap_reverse,
        .flex_start => a.wrap_reverse,
        else => false,
    };
    const physical_start = switch (it.al) {
        .start, .self_start, .left => true,
        .flex_start => !a.wrap_reverse,
        .flex_end => a.wrap_reverse,
        // Not stretched (a definite cross size): flush with the line's
        // cross-start, the bottom of a wrap-reverse row.
        .stretch, .normal => !a.wrap_reverse,
        else => false,
    };
    it.cross_pos = 0;
    switch (it.al) {
        .center => it.cross_pos = free / 2,
        .baseline => if (a.row) {
            it.cross_pos = ln.baseline - it.baseline;
        },
        .last_baseline => if (a.row) {
            it.cross_pos = ln.cross - ln.last_below - it.baseline;
        },
        else => if (physical_end or !physical_start) {
            it.cross_pos = free;
        },
    }
    // `safe`: overflowing, it aligns to the line's start.
    if (it.safe and free < 0) it.cross_pos = 0;
}

/// Auto margins and justify-content on a line (9.5): each item's
/// margin-box offset from the line's main-start.
fn mainAlign(a: Axes, jc: Align, safe: bool, line: []Item, container: f32, gap: f32) void {
    const n: f32 = @floatFromInt(line.len);
    var free = container - gap * @max(0, n - 1);
    var autos: f32 = 0;
    for (line) |*it| {
 free -= it.target + it.mm;
        if (it.collapsed) continue;
        autos += @as(f32, @floatFromInt(@intFromBool(it.auto[a.mainStart()]))) + @as(f32, @floatFromInt(@intFromBool(it.auto[a.mainEnd()])));
    }
    var offset: f32 = 0;
    var between = gap;
    if (autos > 0) {
        if (free > 0) {
            const per = free / autos;
            for (line) |*it| {
                if (it.auto[a.mainStart()]) it.m[a.mainStart()] += per;
                if (it.auto[a.mainEnd()]) it.m[a.mainEnd()] += per;
            }
        }
    } else {
        // In main-start terms: `start`, `left`, and the like are physical.
        const Pos = enum { start, center, end, between, around, evenly };
        const p: Pos = switch (jc) {
            .flex_end => .end,
            .start, .self_start => if (a.reverse) .end else .start,
            .end, .self_end => if (a.reverse) .start else .end,
            .left => if (a.row and a.reverse) .end else .start,
            .right => if (!a.row) .start else if (a.reverse) .start else .end,
            .center => .center,
            .space_between => .between,
            .space_around => .around,
            .space_evenly => .evenly,
            else => .start,
        };
        switch (p) {
            .start => {},
            .end => offset = free,
            .center => offset = free / 2,
            .between => if (free > 0 and n > 1) {
                between += free / (n - 1);
            },
            .around => if (free > 0) {
                offset = free / n / 2;
                between += free / n;
            } else {
                offset = free / 2;
            },
            .evenly => if (free > 0) {
                offset = free / (n + 1);
                between += free / (n + 1);
            } else {
                offset = free / 2;
            },
        }
    }
    // `safe`: an overflowing line starts at the main-start.
    // (the physical start: the right of row-reverse is its main-start).
    if (safe and free < 0) offset = if (a.reverse) free else 0;
    var pos = offset;
    for (line) |*it| {
        it.main_pos = pos;
        it.mm = if (it.collapsed) 0 else it.m[a.mainStart()] + it.m[a.mainEnd()];
        pos += it.target + it.mm + between;
    }
}

/// The container's first and last baselines (8.5): the first line's
/// shared baseline when its items align by baseline, else its first
/// item's (synthesized from the border box's bottom without one); the
/// last line's last item likewise.
fn baselines(e: *Engine, id: BoxId, a: Axes, its: []Item, lines: []const Line) Error!void {
    const cb = e.tree.get(id);
    if (its.len == 0) return;
    const first = lines[0];
    var first_bl: ?f32 = null;
    if (a.row) for (its[first.start..first.end]) |*it| if (it.al == .baseline and !it.auto[0] and !it.auto[2]) {
        const b = e.tree.get(it.id);
        first_bl = b.y - it.m[0] + it.baseline;
        break;
    };
    if (first_bl == null and first.end > first.start) {
        const b = e.tree.get(its[first.start].id);
        first_bl = b.y + if (!std.math.isNan(b.baseline)) b.baseline else b.h;
    }
    cb.baseline = first_bl orelse std.math.nan(f32);
    const last = lines[lines.len - 1];
    if (last.end > last.start) {
        const b = e.tree.get(its[last.end - 1].id);
        cb.last_baseline = b.y + if (!std.math.isNan(b.last_baseline)) b.last_baseline else b.h;
    }
}

/// Static positions of out-of-flow children (4.1): aligned in the
/// content box by justify-content and align-self as if each were the
/// only item.
fn staticPositions(e: *Engine, id: BoxId, st: *const css.Style, a: Axes, left: f32, top: f32, w: f32, h: f32) Error!void {
    var it = e.tree.children(id);
    while (it.next()) |c| {
        const b = e.tree.get(c);
        if (!b.out_of_flow) continue;
        const ist = e.style(c);
        // Main axis, as 0 start, 1 center, 2 end of the physical axis.
        const main_end: u8 = if (a.reverse) 0 else 2;
        const main_start: u8 = if (a.reverse) 2 else 0;
        const jm: u8 = switch (st.box.justify_content) {
            .center, .space_around, .space_evenly => 1,
            .flex_end => main_end,
            .end, .self_end => 2,
            .right => if (a.row) 2 else 0,
            .start, .self_start, .left => 0,
            else => main_start,
        };
        const al = if (ist.box.align_self == .auto) st.box.align_items else ist.box.align_self;
        const cm: u8 = switch (al) {
            .center => 1,
            .flex_end => if (a.wrap_reverse) 0 else 2,
            .end, .self_end => 2,
            .flex_start, .normal, .stretch, .baseline, .last_baseline => if (a.wrap_reverse) 2 else 0,
            else => 0,
        };
        b.static_x = left;
        b.static_y = top;
        b.static_area = .{ w, h };
        b.static_align = if (a.row) .{ jm, cm } else .{ cm, jm };
        try e.absolutes.append(e.gpa, c);
    }
}
