//! Flex layout (CSS Flexible Box Layout 1, section 9): flex base sizes
//! and automatic minimum sizes, line collection with wrapping and gaps,
//! resolving flexible lengths by freezing, cross sizes with stretch, main
//! axis alignment with auto margins and justify-content, cross alignment
//! with align-self and align-content, `order`, and reversed directions.

const std = @import("std");
const css = @import("css");
const layout_mod = @import("layout.zig");
const box_mod = @import("box.zig");

const Engine = layout_mod.Engine;
const Error = layout_mod.Error;
const BoxId = box_mod.BoxId;
const none = box_mod.none;
const Align = css.style.Align;

const Item = struct {
    id: BoxId,
    order: i32,
    /// Main-axis sizes are border-box sizes; margins apart.
    base: f32 = 0,
    hypo: f32 = 0,
    min: f32 = 0,
    max: f32 = std.math.inf(f32),
    target: f32 = 0,
    frozen: bool = false,
    grow: f32,
    shrink: f32,
    margin_main: f32 = 0,
    margin_cross: f32 = 0,
    cross: f32 = 0,
    auto_margins_main: u8 = 0,
    baseline: f32 = 0,
};

fn isRow(st: *const css.Style) bool {
    return st.box.flex_direction == .row or st.box.flex_direction == .row_reverse;
}

fn items(e: *Engine, id: BoxId) Error![]Item {
    var list: std.ArrayList(Item) = .empty;
    var it = e.tree.children(id);
    while (it.next()) |c| {
        if (e.tree.get(c).out_of_flow) continue;
        const st = e.style(c);
        try list.append(e.scratch, .{ .id = c, .order = st.box.order, .grow = st.box.flex_grow, .shrink = st.box.flex_shrink });
    }
    std.mem.sort(Item, list.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return a.order < b.order;
        }
    }.lt);
    return list.items;
}

pub fn intrinsic(e: *Engine, id: BoxId, max: bool) Error!f32 {
    const st = e.style(id);
    const its = try items(e, id);
    const gap = if (st.box.column_gap.tag == .length) st.box.column_gap.resolve(0) else 0;
    var sum: f32 = 0;
    var mx: f32 = 0;
    for (its, 0..) |item, i| {
        const w = try e.intrinsic(item.id, max, true);
        sum += w + if (i > 0) gap else 0;
        mx = @max(mx, w);
    }
    if (!isRow(st)) return mx;
    if (!max and st.box.flex_wrap != .nowrap) return mx;
    return sum;
}

fn edgesOf(e: *Engine, id: BoxId, cb_w: f32) void {
    const b = e.tree.get(id);
    const st = e.style(id);
    for (0..4) |i| {
        b.padding[i] = st.box.padding[i].resolve(cb_w);
        b.border[i] = st.borderWidth(i);
        b.margin[i] = if (st.box.margin[i].isAuto()) 0 else st.box.margin[i].resolve(cb_w);
    }
}

fn hx(b: *const box_mod.Box) f32 {
    return b.padding[1] + b.padding[3] + b.border[1] + b.border[3];
}

fn vx(b: *const box_mod.Box) f32 {
    return b.padding[0] + b.padding[2] + b.border[0] + b.border[2];
}

fn sizeLen(e: *Engine, id: BoxId, l: css.Len, basis: ?f32, horizontal: bool) ?f32 {
    const v = l.definite(basis) orelse return null;
    const b = e.tree.get(id);
    const extra = if (horizontal) hx(b) else vx(b);
    return if (e.style(id).box.box_sizing == .border_box) @max(v, extra) else v + extra;
}

/// The item's height when laid out at border-box width `w`.
fn heightAt(e: *Engine, id: BoxId, w: f32, cb_w: f32, cb_h: ?f32) Error!f32 {
    const b = e.tree.get(id);
    if (b.kind == .replaced) {
        const st = e.style(id);
        if (sizeLen(e, id, st.box.height, cb_h, false)) |h| return h;
        const r = e.tree.replaced.items[b.data];
        if (r.natural_w > 0 and r.natural_h > 0) return (w - hx(b)) * r.natural_h / r.natural_w + vx(b);
        return r.natural_h + vx(b);
    }
    try e.layoutAt(id, w, cb_w, cb_h, null);
    return e.tree.get(id).h;
}

/// Lays out a flex container's content; returns its content height.
pub fn layout(e: *Engine, id: BoxId, content_w: f32, content_h: ?f32) Error!f32 {
    const st = e.style(id);
    const row = isRow(st);
    const its = try items(e, id);
    const cb = e.tree.get(id);
    const left = cb.border[3] + cb.padding[3];
    const top = cb.border[0] + cb.padding[0];
    const main_gap: f32 = blk: {
        const g = if (row) st.box.column_gap else st.box.row_gap;
        break :blk if (g.tag == .length) g.resolve(if (row) content_w else (content_h orelse 0)) else 0;
    };
    const cross_gap: f32 = blk: {
        const g = if (row) st.box.row_gap else st.box.column_gap;
        break :blk if (g.tag == .length) g.resolve(if (row) (content_h orelse 0) else content_w) else 0;
    };
    const main_size: ?f32 = if (row) content_w else content_h;
    // Base sizes.
    for (its) |*item| {
        edgesOf(e, item.id, content_w);
        const ist = e.style(item.id);
        const b = e.tree.get(item.id);
        item.margin_main = if (row) b.margin[1] + b.margin[3] else b.margin[0] + b.margin[2];
        item.margin_cross = if (row) b.margin[0] + b.margin[2] else b.margin[1] + b.margin[3];
        const ml = if (row) ist.box.margin[3] else ist.box.margin[0];
        const mr = if (row) ist.box.margin[1] else ist.box.margin[2];
        item.auto_margins_main = @as(u8, @intFromBool(ml.isAuto())) + @intFromBool(mr.isAuto());
        const basis = ist.box.flex_basis;
        const main_prop = if (row) ist.box.width else ist.box.height;
        var base: ?f32 = null;
        if (basis.tag == .length) base = sizeLen(e, item.id, basis, main_size, row);
        if (base == null and basis.tag == .auto) base = sizeLen(e, item.id, main_prop, main_size, row);
        if (base == null) {
            if (row) {
                base = try e.intrinsic(item.id, true, false);
                if (b.kind == .replaced and !ist.box.height.isAuto()) {
                    // A replaced item sized by height keeps its ratio.
                    const r = e.tree.replaced.items[b.data];
                    if (sizeLen(e, item.id, ist.box.height, content_h, false)) |h| if (r.natural_h > 0) {
                        base = (h - vx(b)) * r.natural_w / r.natural_h + hx(b);
                    };
                }
            } else {
                const w = try crossWidthForColumn(e, item.id, content_w);
                base = try heightAt(e, item.id, w, content_w, content_h);
            }
        }
        item.base = base.?;
        // Min and max main sizes; the automatic minimum is the content
        // size (min-content) unless overflow is not visible.
        const min_prop = if (row) ist.box.min_width else ist.box.min_height;
        const max_prop = if (row) ist.box.max_width else ist.box.max_height;
        if (min_prop.tag == .length) {
            item.min = sizeLen(e, item.id, min_prop, main_size, row) orelse 0;
        } else if (min_prop.isAuto() and ist.box.overflow_x == .visible) {
            var auto_min: f32 = if (row) try e.intrinsic(item.id, false, false) else blk: {
                break :blk if (sizeLen(e, item.id, main_prop, main_size, row)) |v| v else item.base;
            };
            if (sizeLen(e, item.id, main_prop, main_size, row)) |spec| auto_min = @min(auto_min, spec);
            item.min = auto_min;
        } else item.min = if (row) hx(b) else vx(b);
        if (max_prop.tag == .length) item.max = sizeLen(e, item.id, max_prop, main_size, row) orelse std.math.inf(f32);
        item.hypo = std.math.clamp(item.base, item.min, @max(item.min, item.max));
    }
    // Lines.
    var lines: std.ArrayList([2]usize) = .empty;
    {
        var start: usize = 0;
        var used: f32 = 0;
        for (its, 0..) |item, i| {
            const outer = item.hypo + item.margin_main;
            if (st.box.flex_wrap != .nowrap and main_size != null and i > start and used + main_gap + outer > main_size.? + 0.01) {
                try lines.append(e.scratch, .{ start, i });
                start = i;
                used = 0;
            }
            used += outer + if (i > start) main_gap else 0;
        }
        try lines.append(e.scratch, .{ start, its.len });
    }
    // Resolve flexible lengths per line.
    var used_main: f32 = 0;
    for (lines.items) |ln| {
        const line = its[ln[0]..ln[1]];
        const gaps = main_gap * @as(f32, @floatFromInt(@max(1, line.len) - 1));
        var sum_hypo: f32 = gaps;
        for (line) |item| sum_hypo += item.hypo + item.margin_main;
        const container = main_size orelse sum_hypo;
        const growing = sum_hypo < container;
        for (line) |*item| {
            item.target = item.hypo;
            item.frozen = (if (growing) item.grow == 0 else item.shrink == 0) or (growing and item.base > item.hypo) or (!growing and item.base < item.hypo);
        }
        var guard: usize = 0;
        while (guard < line.len + 1) : (guard += 1) {
            var free = container - gaps;
            var sum_flex: f32 = 0;
            var sum_scaled: f32 = 0;
            var any = false;
            for (line) |item| {
                free -= item.margin_main;
                if (item.frozen) {
                    free -= item.target;
                } else {
                    free -= item.base;
                    any = true;
                    sum_flex += if (growing) item.grow else item.shrink;
                    sum_scaled += item.shrink * item.base;
                }
            }
            if (!any) break;
            if (sum_flex < 1 and sum_flex > 0) {
                // Flex factors below one take only that share.
                const initial = container - gaps - blk: {
                    var s: f32 = 0;
                    for (line) |item| s += item.base + item.margin_main;
                    break :blk s;
                };
                if (@abs(initial * sum_flex) < @abs(free)) free = initial * sum_flex;
            }
            var total_violation: f32 = 0;
            for (line) |*item| {
                if (item.frozen) continue;
                var t = item.base;
                if (growing) {
                    if (sum_flex > 0) t += free * item.grow / sum_flex;
                } else if (sum_scaled > 0) t += free * item.shrink * item.base / sum_scaled;
                const clamped = std.math.clamp(t, item.min, @max(item.min, item.max));
                total_violation += clamped - t;
                item.target = clamped;
            }
            // Freeze violators.
            var changed = false;
            for (line) |*item| {
                if (item.frozen) continue;
                const unclamped_less = item.target <= item.min + 0.001 and total_violation > 0;
                const unclamped_more = item.target >= item.max - 0.001 and total_violation < 0;
                if (total_violation == 0 or unclamped_less or unclamped_more) {
                    item.frozen = true;
                    changed = true;
                }
            }
            if (!changed) {
                for (line) |*item| item.frozen = true;
            }
        }
        var lm: f32 = gaps;
        for (line) |item| lm += item.target + item.margin_main;
        used_main = @max(used_main, lm);
    }
    // Cross sizes: lay out each item at its main size.
    const align_items = st.box.align_items;
    for (its) |*item| {
        const b = e.tree.get(item.id);
        if (row) {
            item.cross = try heightAt(e, item.id, item.target, content_w, content_h);
            item.baseline = if (!std.math.isNan(e.tree.get(item.id).baseline)) e.tree.get(item.id).baseline else item.cross;
        } else {
            item.cross = try crossWidthForColumn(e, item.id, content_w);
            try e.layoutAt(item.id, item.cross, content_w, content_h, item.target);
        }
        _ = b;
    }
    var line_cross: std.ArrayList(f32) = .empty;
    var line_baseline: std.ArrayList(f32) = .empty;
    var sum_cross: f32 = 0;
    for (lines.items, 0..) |ln, li| {
        var m: f32 = 0;
        var bl: f32 = 0;
        for (its[ln[0]..ln[1]]) |item| {
            m = @max(m, item.cross + item.margin_cross);
            if (selfAlign(e, item.id, align_items) == .baseline) bl = @max(bl, item.baseline + (if (row) e.tree.get(item.id).margin[0] else 0));
        }
        // A single line fills a definite cross size.
        const definite_cross: ?f32 = if (row) content_h else content_w;
        if (lines.items.len == 1 and st.box.flex_wrap == .nowrap) if (definite_cross) |dc| {
            m = dc;
        };
        try line_cross.append(e.scratch, m);
        try line_baseline.append(e.scratch, bl);
        sum_cross += m + if (li > 0) cross_gap else 0;
    }
    // align-content: distribute free cross space between lines.
    const cross_size: ?f32 = if (row) content_h else content_w;
    var cross_offset: f32 = 0;
    var cross_between: f32 = cross_gap;
    if (cross_size) |cs| if (lines.items.len > 1 or st.box.flex_wrap != .nowrap) {
        const free = cs - sum_cross;
        const n: f32 = @floatFromInt(lines.items.len);
        switch (st.box.align_content) {
            .normal, .stretch => if (free > 0) {
                for (line_cross.items) |*lc| lc.* += free / n;
            },
            .center => cross_offset = free / 2,
            .end, .flex_end => cross_offset = free,
            .space_between => if (n > 1 and free > 0) {
                cross_between += free / (n - 1);
            },
            .space_around => if (free > 0) {
                cross_offset = free / n / 2;
                cross_between += free / n;
            },
            .space_evenly => if (free > 0) {
                cross_offset = free / (n + 1);
                cross_between += free / (n + 1);
            },
            else => {},
        }
    };
    // Place.
    const reverse_main = st.box.flex_direction == .row_reverse or st.box.flex_direction == .column_reverse;
    const wrap_reverse = st.box.flex_wrap == .wrap_reverse;
    var cross_pos = cross_offset;
    const total_cross = blk: {
        var t: f32 = cross_offset;
        for (line_cross.items, 0..) |lc, i| t += lc + if (i > 0) cross_between else 0;
        break :blk t;
    };
    for (lines.items, 0..) |ln, li| {
        const line = its[ln[0]..ln[1]];
        const lc = line_cross.items[li];
        const gaps = main_gap * @as(f32, @floatFromInt(@max(1, line.len) - 1));
        var sum: f32 = gaps;
        var autos: f32 = 0;
        for (line) |item| {
            sum += item.target + item.margin_main;
            autos += @floatFromInt(item.auto_margins_main);
        }
        const container = main_size orelse sum;
        var free = container - sum;
        var pos: f32 = 0;
        var between: f32 = main_gap;
        var per_auto: f32 = 0;
        if (autos > 0 and free > 0) {
            per_auto = free / autos;
            free = 0;
        }
        const n: f32 = @floatFromInt(line.len);
        switch (st.box.justify_content) {
            .center => pos = free / 2,
            .end, .flex_end, .right => pos = free,
            .space_between => if (n > 1 and free > 0) {
                between += free / (n - 1);
            } else if (free < 0) {},
            .space_around => if (free > 0) {
                pos = free / n / 2;
                between += free / n;
            },
            .space_evenly => if (free > 0) {
                pos = free / (n + 1);
                between += free / (n + 1);
            },
            else => {},
        }
        for (line, 0..) |*item, i| {
            const b = e.tree.get(item.id);
            const ist = e.style(item.id);
            // Auto margins take free space.
            const ml_auto = if (row) ist.box.margin[3].isAuto() else ist.box.margin[0].isAuto();
            const mr_auto = if (row) ist.box.margin[1].isAuto() else ist.box.margin[2].isAuto();
            const m_start = (if (row) b.margin[3] else b.margin[0]) + if (ml_auto) per_auto else 0;
            const m_end = (if (row) b.margin[1] else b.margin[2]) + if (mr_auto) per_auto else 0;
            const main_start = pos + m_start;
            // Cross alignment.
            const sa = selfAlign(e, item.id, align_items);
            const mc_start = if (row) b.margin[0] else b.margin[3];
            const mc_end = if (row) b.margin[2] else b.margin[1];
            const cross_auto = if (row) ist.box.height.isAuto() else ist.box.width.isAuto();
            var cross_item = item.cross;
            if ((sa == .stretch or sa == .normal) and cross_auto and !(if (row) ist.box.margin[0].isAuto() or ist.box.margin[2].isAuto() else ist.box.margin[1].isAuto() or ist.box.margin[3].isAuto())) {
                const stretched = @max(lc - mc_start - mc_end, if (row) vx(b) else hx(b));
                if (stretched != cross_item) {
                    cross_item = stretched;
                    if (row) {
                        try e.layoutAt(item.id, item.target, content_w, content_h, stretched);
                    } else try e.layoutAt(item.id, stretched, content_w, content_h, item.target);
                }
            }
            var cpos: f32 = mc_start;
            switch (sa) {
                .center => cpos = mc_start + (lc - mc_start - mc_end - cross_item) / 2,
                .end, .flex_end, .self_end => cpos = lc - mc_end - cross_item,
                .baseline, .last_baseline => cpos = line_baseline.items[li] - item.baseline,
                else => {},
            }
            if (wrap_reverse) cpos = lc - cpos - cross_item;
            var main_pos = main_start;
            if (reverse_main) main_pos = container - main_start - item.target;
            var line_pos = cross_pos;
            if (wrap_reverse) line_pos = total_cross - cross_pos - lc;
            if (row) {
                b.x = left + main_pos;
                b.y = top + line_pos + cpos;
                b.w = item.target;
            } else {
                b.x = left + line_pos + cpos;
                b.y = top + main_pos;
            }
            pos = main_start + item.target + m_end + if (i + 1 < line.len) between else 0;
            relative(e, item.id, content_w);
            // The container's baseline: its first item's.
            const cbb = e.tree.get(id);
            if (li == 0 and std.math.isNan(cbb.baseline) and !std.math.isNan(b.baseline)) cbb.baseline = b.y + b.baseline;
            if (!std.math.isNan(b.last_baseline)) cbb.last_baseline = b.y + b.last_baseline;
        }
        cross_pos += lc + cross_between;
    }
    // Out-of-flow children: static position at the content box corner.
    var it = e.tree.children(id);
    while (it.next()) |c| if (e.tree.get(c).out_of_flow) {
        e.tree.get(c).static_x = left;
        e.tree.get(c).static_y = top;
        try e.absolutes.append(e.gpa, c);
    };
    if (row) return content_h orelse total_cross;
    return content_h orelse used_main;
}

fn relative(e: *Engine, id: BoxId, cb_w: f32) void {
    const st = e.style(id);
    if (st.box.position != .relative) return;
    const b = e.tree.get(id);
    if (!st.box.inset[3].isAuto()) b.x += st.box.inset[3].resolve(cb_w) else if (!st.box.inset[1].isAuto()) b.x -= st.box.inset[1].resolve(cb_w);
    if (!st.box.inset[0].isAuto()) b.y += st.box.inset[0].resolve(cb_w) else if (!st.box.inset[2].isAuto()) b.y -= st.box.inset[2].resolve(cb_w);
}

fn selfAlign(e: *Engine, id: BoxId, container: Align) Align {
    const s = e.style(id).box.align_self;
    return if (s == .auto) container else s;
}

/// A column flex item's width: stretched, specified, or shrink-to-fit.
fn crossWidthForColumn(e: *Engine, id: BoxId, content_w: f32) Error!f32 {
    const st = e.style(id);
    const b = e.tree.get(id);
    const margins = b.margin[1] + b.margin[3];
    if (sizeLen(e, id, st.box.width, content_w, true)) |w| return w;
    if (b.kind == .replaced) return try e.intrinsic(id, true, false);
    const parent = e.style(b.parent);
    const sa = if (st.box.align_self == .auto) parent.box.align_items else st.box.align_self;
    if ((sa == .stretch or sa == .normal) and !st.box.margin[1].isAuto() and !st.box.margin[3].isAuto()) return @max(0, content_w - margins);
    return e.shrinkToFit(id, @max(0, content_w - margins));
}
