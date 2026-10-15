//! Table layout (CSS 2.1 17, CSS Tables 3): the cell grid with column and
//! row spans, column widths from the cells' intrinsic widths (automatic
//! layout) or the first row (fixed layout), border-spacing, row heights,
//! vertical-align in cells, captions, and collapsed borders (the wider of
//! two adjoining borders, CSS 2.1 17.6.2).

const std = @import("std");
const css = @import("css");
const layout_mod = @import("layout.zig");
const box_mod = @import("box.zig");

const Engine = layout_mod.Engine;
const Error = layout_mod.Error;
const BoxId = box_mod.BoxId;
const none = box_mod.none;

const Cell = struct { id: BoxId, row: u32, col: u32, rows: u32, cols: u32 };

const Grid = struct {
    rows: std.ArrayList(BoxId) = .empty,
    /// The row group of each row.
    groups: std.ArrayList(BoxId) = .empty,
    cells: std.ArrayList(Cell) = .empty,
    ncols: u32 = 0,
    captions: std.ArrayList(BoxId) = .empty,
};

fn build(e: *Engine, table: BoxId) Error!Grid {
    var g: Grid = .{};
    // The first header group first, then bodies, then the first footer
    // group (CSS 2.1 17.2; later ones stay among the bodies).
    var groups: [3]std.ArrayList(BoxId) = .{ .empty, .empty, .empty };
    var it = e.tree.children(table);
    while (it.next()) |c| {
        const b = e.tree.get(c);
        if (b.out_of_flow) continue;
        switch (b.kind) {
            .table_caption => try g.captions.append(e.scratch, c),
            .table_row_group => {
                const inner = e.style(c).box.display.inner;
                const k: usize = if (inner == .table_header_group and groups[0].items.len == 0) 0 else if (inner == .table_footer_group and groups[2].items.len == 0) 2 else 1;
                try groups[k].append(e.scratch, c);
            },
            else => {},
        }
    }
    // The cell (an index into `cells`) at each row and column.
    var occupied: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    for (groups) |list| for (list.items) |grp| {
        var rit = e.tree.children(grp);
        while (rit.next()) |row| {
            if (e.tree.get(row).kind != .table_row) continue;
            const r: u32 = @intCast(g.rows.items.len);
            try g.rows.append(e.scratch, row);
            try g.groups.append(e.scratch, grp);
            var col: u32 = 0;
            var cit = e.tree.children(row);
            while (cit.next()) |cell| {
                const cb = e.tree.get(cell);
                if (cb.kind != .table_cell) continue;
                while (occupied.contains(@as(u64, r) << 32 | col)) col += 1;
                const cs: u32 = cb.colspan;
                const rs: u32 = cb.rowspan;
                for (0..rs) |dr| for (0..cs) |dc| try occupied.put(e.scratch, @as(u64, r + @as(u32, @intCast(dr))) << 32 | (col + @as(u32, @intCast(dc))), @intCast(g.cells.items.len));
                try g.cells.append(e.scratch, .{ .id = cell, .row = r, .col = col, .rows = rs, .cols = cs });
                col += cs;
                g.ncols = @max(g.ncols, col);
            }
        }
    };
    // Spans past the last row end there.
    const nrows: u32 = @intCast(g.rows.items.len);
    for (g.cells.items) |*c| c.rows = @max(1, @min(c.rows, nrows - c.row));
    if (e.style(table).inh.border_collapse == .collapse) try collapse(e, table, &g, &occupied);
    return g;
}

/// A border competing in the collapsing border model.
const Candidate = struct {
    width: f32,
    style: css.style.BorderStyle,
    color: css.Color,

    fn of(e: *Engine, id: BoxId, side: usize) Candidate {
        const st = e.style(id);
        const c = st.box.border_color[side];
        return .{
            .width = st.borderWidth(side),
            .style = st.box.border_style[side],
            .color = if (c.kind == .current) st.inh.color else c,
        };
    }

    /// CSS 2.1 17.6.2.1: hidden wins, then the wider border, then the
    /// style in this order; `a` (the nearer box) wins ties.
    fn beats(b: Candidate, a: Candidate) bool {
        if (a.style == .hidden) return false;
        if (b.style == .hidden) return true;
        if (b.style == .none or b.width == 0) return false;
        if (a.style == .none or a.width == 0) return true;
        if (b.width != a.width) return b.width > a.width;
        return rank(b.style) > rank(a.style);
    }

    fn rank(s: css.style.BorderStyle) u8 {
        return switch (s) {
            .double => 8,
            .solid => 7,
            .dashed => 6,
            .dotted => 5,
            .ridge => 4,
            .outset => 3,
            .groove => 2,
            .inset => 1,
            .none, .hidden => 0,
        };
    }
};

/// The table's share of its own border in the collapsing model: the
/// lower half of each edge's border on the left and top, the larger
/// half on the right and bottom, so that whole-pixel borders stay on
/// whole pixels. The cells take the rest of each collapsed border.
pub fn tablePart(st: *const css.Style, side: usize) f32 {
    const w = st.borderWidth(side);
    const lo = @floor(w / 2);
    return if (side == 0 or side == 3) lo else w - lo;
}

/// Resolves every cell's collapsed borders (CSS 2.1 17.6.2) against its
/// neighbors, rows, row groups, and the table, into `Tree.collapsed`.
/// Columns have no boxes and take no part.
fn collapse(e: *Engine, table: BoxId, g: *const Grid, occupied: *const std.AutoHashMapUnmanaged(u64, u32)) Error!void {
    const nrows: u32 = @intCast(g.rows.items.len);
    const tst = e.style(table);
    for (g.cells.items) |c| {
        const b = e.tree.get(c.id);
        if (b.data == none) {
            b.data = @intCast(e.tree.collapsed.items.len);
            try e.tree.collapsed.append(e.gpa, undefined);
        }
        const last_row = c.row + c.rows - 1;
        var sides: [4]box_mod.CollapsedSide = undefined;
        for (0..4) |side| {
            // Candidates nearest first: the cell, the neighbor across the
            // edge, the rows, the row groups, the table.
            var best = Candidate.of(e, c.id, side);
            const opposite = (side + 2) % 4;
            const at: ?[2]u32 = switch (side) {
                0 => if (c.row > 0) .{ c.row - 1, c.col } else null,
                1 => if (c.col + c.cols < g.ncols) .{ c.row, c.col + c.cols } else null,
                2 => if (last_row + 1 < nrows) .{ last_row + 1, c.col } else null,
                else => if (c.col > 0) .{ c.row, c.col - 1 } else null,
            };
            const edge = at == null;
            if (at) |rc| if (occupied.get(@as(u64, rc[0]) << 32 | rc[1])) |k| {
                // Between two cells, ties go to the one above or left.
                const n = Candidate.of(e, g.cells.items[k].id, opposite);
                if (if (side == 0 or side == 3) !best.beats(n) else n.beats(best)) best = n;
            };
            const row = g.rows.items[if (side == 2) last_row else c.row];
            const grp = g.groups.items[if (side == 2) last_row else c.row];
            const vertical = side == 1 or side == 3;
            if (!vertical or edge) {
                const own = Candidate.of(e, row, side);
                if (own.beats(best)) best = own;
            }
            if (!vertical) if (at) |rc| {
                const n = Candidate.of(e, g.rows.items[rc[0]], opposite);
                if (n.beats(best)) best = n;
            };
            // Row groups at their first and last rows.
            const group_edge = vertical or at == null or g.groups.items[at.?[0]] != grp;
            if (group_edge and (!vertical or edge)) {
                const own = Candidate.of(e, grp, side);
                if (own.beats(best)) best = own;
                if (!vertical) if (at) |rc| {
                    const n = Candidate.of(e, g.groups.items[rc[0]], opposite);
                    if (n.beats(best)) best = n;
                };
            }
            if (edge) {
                const t = Candidate.of(e, table, side);
                if (t.beats(best)) best = t;
            }
            const w = if (best.style == .hidden or best.style == .none) 0 else best.width;
            // The cell's share: what the table keeps at its edges, else
            // the upper or left half of a line, which goes to the cell
            // after it (left and top sides take the larger half).
            const outer: f32 = if (edge) @min(w, tablePart(tst, side)) else if (side == 0 or side == 3) 0 else @floor(w / 2);
            const lo = @floor(w / 2);
            const part = if (edge) w - outer else if (side == 0 or side == 3) w - lo else lo;
            sides[side] = .{ .part = part, .ext = if (edge) outer else 0, .style = best.style, .color = best.color };
        }
        e.tree.collapsed.items[b.data] = sides;
    }
}

fn spacing(e: *Engine, table: BoxId) [2]f32 {
    const st = e.style(table);
    if (st.inh.border_collapse == .collapse) return .{ 0, 0 };
    return st.inh.border_spacing;
}

fn edges(e: *Engine, id: BoxId, cb_w: f32) void {
    const b = e.tree.get(id);
    for (0..4) |i| {
        b.padding[i] = e.paddingOf(id, i, cb_w);
        b.border[i] = e.borderOf(id, i);
        b.margin[i] = 0;
    }
}

/// The columns' widths from the cells: minimum and maximum, the largest
/// percentage width (as a fraction), and whether a fixed width
/// constrains them (CSS Tables 3, "Computing column measures").
const Cols = struct { min: []f32, max: []f32, pct: []f32, fixed: []bool };

fn columns(e: *Engine, table: BoxId, g: *const Grid, avail: ?f32) Error!Cols {
    const n_ = g.ncols;
    const cols: Cols = .{
        .min = try e.scratch.alloc(f32, n_),
        .max = try e.scratch.alloc(f32, n_),
        .pct = try e.scratch.alloc(f32, n_),
        .fixed = try e.scratch.alloc(bool, n_),
    };
    @memset(cols.min, 0);
    @memset(cols.max, 0);
    @memset(cols.pct, 0);
    @memset(cols.fixed, false);
    const sp = spacing(e, table)[0];
    const fixed = e.style(table).box.table_layout == .fixed and !e.style(table).box.width.isAuto();
    for ([_]bool{ false, true }) |multi| for (g.cells.items) |c| {
        if ((c.cols > 1) != multi) continue;
        if (fixed and c.row != 0) continue;
        edges(e, c.id, avail orelse 0);
        var mn = try e.intrinsic(c.id, false, false);
        var mx = try e.intrinsic(c.id, true, false);
        const st = e.style(c.id);
        const width = st.box.width;
        // A fixed width on a cell is its column's width.
        if (width.tag == .length and !width.hasPercent()) {
            const b = e.tree.get(c.id);
            const w = width.resolve(0) + (if (st.box.box_sizing == .border_box) 0 else b.padding[1] + b.padding[3] + b.border[1] + b.border[3]);
            mx = @max(mn, w);
            if (fixed) mn = w;
        } else if (fixed) mn = 0; // Content does not widen fixed layout.
        if (c.cols == 1) {
            cols.min[c.col] = @max(cols.min[c.col], mn);
            cols.max[c.col] = @max(cols.max[c.col], mx);
            if (width.tag == .length and width.nl == null and width.px == 0 and width.pct > 0) {
                cols.pct[c.col] = @max(cols.pct[c.col], width.pct);
            } else if (width.tag == .length and !width.hasPercent()) cols.fixed[c.col] = true;
        } else {
            // A spanning cell widens its columns in proportion to their
            // maximums (equally while they have none).
            const span_sp = sp * @as(f32, @floatFromInt(c.cols - 1));
            var cur_min: f32 = span_sp;
            var cur_max: f32 = span_sp;
            for (c.col..c.col + c.cols) |k| {
                cur_min += cols.min[k];
                cur_max += cols.max[k];
            }
            const n: f32 = @floatFromInt(c.cols);
            const weight = cur_max - span_sp;
            for ([_]bool{ false, true }) |is_max| {
                const want = if (is_max) mx else mn;
                const cur = if (is_max) cur_max else cur_min;
                if (want <= cur) continue;
                for (c.col..c.col + c.cols) |k| {
                    const share = if (weight > 0) cols.max[k] / weight else 1 / n;
                    (if (is_max) cols.max else cols.min)[k] += (want - cur) * share;
                }
            }
        }
    };
    for (cols.min, cols.max) |mn, *mx| mx.* = @max(mx.*, mn);
    return cols;
}

const Excess = enum {
    auto_max,
    auto,
    fixed_max,
    pct,
    all,

    fn weight(class: Excess, cols: Cols, i: usize) f32 {
        const auto = cols.pct[i] == 0 and !cols.fixed[i];
        return switch (class) {
            .auto_max => if (auto) cols.max[i] else 0,
            .auto => if (auto) 1 else 0,
            .fixed_max => if (cols.pct[i] == 0 and cols.fixed[i]) cols.max[i] else 0,
            .pct => cols.pct[i],
            .all => 1,
        };
    }
};

/// The columns' widths for `avail`: the CSS Tables 3 sizing guesses
/// (minimum; percentage columns at their share; fixed columns at their
/// width; every column at its maximum), interpolating between the two
/// that bracket `avail`, and space beyond the last one to the auto
/// columns first, then fixed ones, then percentage ones.
fn distribute(cols: Cols, avail: f32, widths: []f32) void {
    const n = widths.len;
    if (n == 0) return;
    var guesses: [4]f32 = .{ 0, 0, 0, 0 };
    var pct_left: f32 = 1;
    for (0..n) |i| {
        const p = @min(cols.pct[i], pct_left);
        pct_left -= p;
        const at_pct = if (p > 0) @max(cols.min[i], p * avail) else cols.min[i];
        guesses[0] += cols.min[i];
        guesses[1] += at_pct;
        guesses[2] += if (p > 0) at_pct else if (cols.fixed[i]) cols.max[i] else cols.min[i];
        guesses[3] += if (p > 0) at_pct else cols.max[i];
    }
    const Guess = struct {
        fn at(c: Cols, k: usize, i: usize, w: f32, pct: f32) f32 {
            const at_pct = if (pct > 0) @max(c.min[i], pct * w) else c.min[i];
            return switch (k) {
                0 => c.min[i],
                1 => at_pct,
                2 => if (pct > 0) at_pct else if (c.fixed[i]) c.max[i] else c.min[i],
                else => if (pct > 0) at_pct else c.max[i],
            };
        }
    };
    if (avail <= guesses[3]) {
        var k: usize = 0;
        while (k < 3 and avail > guesses[k + 1]) k += 1;
        const t = if (k == 3 or avail <= guesses[0]) 0 else (avail - guesses[k]) / @max(guesses[k + 1] - guesses[k], 0.001);
        pct_left = 1;
        for (0..n) |i| {
            const p = @min(cols.pct[i], pct_left);
            pct_left -= p;
            const a = Guess.at(cols, k, i, avail, p);
            const b = Guess.at(cols, @min(k + 1, 3), i, avail, p);
            widths[i] = a + (b - a) * t;
        }
        return;
    }
    pct_left = 1;
    for (0..n) |i| {
        const p = @min(cols.pct[i], pct_left);
        pct_left -= p;
        widths[i] = Guess.at(cols, 3, i, avail, p);
    }
    // The excess: to auto columns by their maximums (equally if none has
    // one), else fixed ones by their maximums, else percentage ones by
    // their percentages, else to every column equally.
    const excess = avail - guesses[3];
    for ([_]Excess{ .auto_max, .auto, .fixed_max, .pct, .all }) |class| {
        var total: f32 = 0;
        for (0..n) |i| total += class.weight(cols, i);
        if (total <= 0) continue;
        for (0..n) |i| widths[i] += excess * class.weight(cols, i) / total;
        return;
    }
}

fn tableExtras(e: *Engine, table: BoxId, g: *const Grid) f32 {
    const b = e.tree.get(table);
    const sp = spacing(e, table)[0];
    return b.padding[1] + b.padding[3] + b.border[1] + b.border[3] + sp * @as(f32, @floatFromInt(g.ncols + 1));
}

pub fn intrinsic(e: *Engine, id: BoxId, max: bool) Error!f32 {
    const g = try build(e, id);
    // Its padding and borders, keeping the margins its parent resolved.
    const margin = e.tree.get(id).margin;
    edges(e, id, 0);
    e.tree.get(id).margin = margin;
    const cols = try columns(e, id, &g, null);
    var s: f32 = tableExtras(e, id, &g);
    if (max) {
        // Wide enough for each percentage column to get its share of
        // its maximum, and for the rest to fit in what is left.
        var sum: f32 = 0;
        var rest: f32 = 0;
        var pct: f32 = 0;
        var w: f32 = 0;
        for (cols.max, cols.pct) |mx, p| {
            sum += mx;
            if (p > 0) w = @max(w, mx / p) else rest += mx;
            pct += p;
        }
        if (pct < 1) w = @max(w, rest / (1 - pct));
        s += @max(sum, w);
    } else for (cols.min) |w| s += w;
    for (g.captions.items) |cap| s = @max(s, try e.intrinsic(cap, max, true));
    return s;
}

/// The table's used border-box width for `avail` when its width is auto.
pub fn usedWidth(e: *Engine, id: BoxId, avail: f32) Error!f32 {
    const mn = try intrinsic(e, id, false);
    const mx = try intrinsic(e, id, true);
    return @max(mn, @min(mx, avail));
}

pub fn layout(e: *Engine, id: BoxId, content_w_: f32, content_h: ?f32) Error!f32 {
    const g = try build(e, id);
    const tb = e.tree.get(id);
    const sp = spacing(e, id);
    const cols = try columns(e, id, &g, content_w_);
    // The table's width (`layoutAt` gave it) less spacing and edges.
    const avail = @max(0, tb.w - tableExtras(e, id, &g));
    const widths = try e.scratch.alloc(f32, g.ncols);
    const fixed = e.style(id).box.table_layout == .fixed and !e.style(id).box.width.isAuto();
    if (fixed) {
        // CSS 2.1 17.5.2.1: widths the first row's cells set, and the rest
        // shared equally; content does not matter.
        const set = try e.scratch.alloc(bool, g.ncols);
        @memset(set, false);
        @memset(widths, 0);
        for (g.cells.items) |c| {
            if (c.row != 0) continue;
            const st = e.style(c.id);
            // Widths mixing lengths and percentages count as auto in
            // tables, as browsers do.
            const width = st.box.width;
            if (width.tag != .length or (width.hasPercent() and (width.px != 0 or width.nl != null))) continue;
            const b = e.tree.get(c.id);
            const w = width.resolve(avail) + (if (st.box.box_sizing == .border_box) 0 else b.padding[1] + b.padding[3] + b.border[1] + b.border[3]);
            const n: f32 = @floatFromInt(c.cols);
            for (c.col..c.col + c.cols) |k| {
                widths[k] = w / n - sp[0] * (n - 1) / n;
                set[k] = true;
            }
        }
        var used: f32 = 0;
        var free_cols: f32 = 0;
        for (widths, set) |w, st| {
            used += w;
            if (!st) free_cols += 1;
        }
        const share = if (free_cols > 0) @max(0, avail - used) / free_cols else 0;
        for (widths, set) |*w, st| {
            if (!st) w.* = share;
        }
        // Space left with every column set widens them in proportion.
        if (free_cols == 0 and used > 0 and avail > used) for (widths) |*w| {
            w.* += (avail - used) * w.* / used;
        };
    } else distribute(cols, avail, widths);
    // Column positions.
    const xs = try e.scratch.alloc(f32, g.ncols + 1);
    const left = tb.border[3] + tb.padding[3] + sp[0];
    xs[0] = left;
    for (widths, 0..) |w, i| xs[i + 1] = xs[i] + w + sp[0];
    // Captions on top, outside the table's border (the table wrapper
    // box holds them; paint keeps the table's decorations off them).
    var y: f32 = 0;
    for (g.captions.items) |cap| if (e.style(cap).inh.caption_side == .top) {
        try e.layoutBlock(cap, tb.w, null);
        const cb = e.tree.get(cap);
        cb.x = cb.margin[3];
        cb.y = y + cb.margin[0];
        y += cb.margin[0] + cb.h + cb.margin[2];
    };
    y += tb.border[0] + tb.padding[0];
    const grid_top = y;
    // Lay out cells at their widths; rows take the tallest.
    const nrows = g.rows.items.len;
    const heights = try e.scratch.alloc(f32, nrows);
    @memset(heights, 0);
    for (g.rows.items, 0..) |row, r| {
        const st = e.style(row);
        if (st.box.height.tag == .length and !st.box.height.hasPercent()) heights[r] = st.box.height.resolve(0);
    }
    for ([_]bool{ false, true }) |multi| for (g.cells.items) |c| {
        if ((c.rows > 1) != multi) continue;
        const w = xs[c.col + c.cols] - xs[c.col] - sp[0];
        edges(e, c.id, content_w_);
        try e.layoutAt(c.id, w, content_w_, null, null);
        const h = e.tree.get(c.id).h;
        if (c.rows == 1) {
            heights[c.row] = @max(heights[c.row], h);
        } else {
            var cur: f32 = sp[1] * @as(f32, @floatFromInt(c.rows - 1));
            for (c.row..c.row + c.rows) |k| cur += heights[k];
            if (h > cur) heights[c.row + c.rows - 1] += h - cur;
        }
    };
    // Cells aligned on their first baselines (vertical-align: baseline,
    // the default): a row is as tall as its tallest such content above
    // and below the shared baseline.
    const bases = try e.scratch.alloc(f32, nrows);
    @memset(bases, 0);
    {
        const below = try e.scratch.alloc(f32, nrows);
        @memset(below, 0);
        for (g.cells.items) |c| {
            if (c.rows != 1 or e.style(c.id).box.vertical_align != .baseline) continue;
            const cb = e.tree.get(c.id);
            if (std.math.isNan(cb.baseline)) continue;
            bases[c.row] = @max(bases[c.row], cb.baseline);
            below[c.row] = @max(below[c.row], cb.h - cb.baseline);
        }
        for (heights, bases, below) |*h, base, bl| h.* = @max(h.*, base + bl);
    }
    // A taller table stretches its rows: in proportion to their
    // heights, or equally while they have none.
    if (content_h) |want| {
        var sum: f32 = sp[1] * @as(f32, @floatFromInt(nrows + 1));
        for (heights) |h| sum += h;
        if (want > sum and nrows > 0) {
            const rows_sum = sum - sp[1] * @as(f32, @floatFromInt(nrows + 1));
            for (heights) |*h| h.* += (want - sum) * (if (rows_sum > 0) h.* / rows_sum else 1 / @as(f32, @floatFromInt(nrows)));
        }
    }
    // Rows and groups positions. Groups and rows are laid out as boxes
    // spanning the table's content width.
    const row_y = try e.scratch.alloc(f32, nrows + 1);
    y += sp[1];
    var group_start_y = y;
    var current_group: BoxId = none;
    for (g.rows.items, 0..) |row, r| {
        const grp = g.groups.items[r];
        if (grp != current_group) {
            if (current_group != none) finishGroup(e, current_group, group_start_y, y - sp[1], xs[0], xs[g.ncols] - sp[0]);
            current_group = grp;
            group_start_y = y;
        }
        row_y[r] = y;
        const rb = e.tree.get(row);
        rb.x = 0;
        rb.y = y - group_start_y;
        rb.w = @max(0, xs[g.ncols] - sp[0] - xs[0]);
        rb.h = heights[r];
        rb.laid_w = -1;
        y += heights[r] + sp[1];
    }
    if (current_group != none) finishGroup(e, current_group, group_start_y, y - sp[1], xs[0], xs[g.ncols] - sp[0]);
    row_y[nrows] = y;
    // Cells: stretch to their rows and align their content.
    for (g.cells.items) |c| {
        const cb = e.tree.get(c.id);
        const h = row_y[c.row + c.rows] - row_y[c.row] - sp[1];
        const content_height = cb.h;
        const st = e.style(c.id);
        // Row-relative position (the cell's parent is its row).
        const row = g.rows.items[c.row];
        const rb = e.tree.get(row);
        const grp = e.tree.get(g.groups.items[c.row]);
        _ = grp;
        cb.x = xs[c.col] - xs[0] - rb.x;
        cb.y = 0;
        const shift = switch (st.box.vertical_align) {
            .middle => (h - content_height) / 2,
            .bottom => h - content_height,
            .baseline => if (c.rows == 1 and !std.math.isNan(cb.baseline)) bases[c.row] - cb.baseline else 0,
            else => 0,
        };
        if (shift > 0) shiftChildren(e, c.id, shift);
        cb.h = h;
        if (!std.math.isNan(cb.baseline) and c.row == 0) {
            const tbb = e.tree.get(id);
            if (std.math.isNan(tbb.baseline)) tbb.baseline = row_y[0] + cb.baseline;
        }
    }
    if (content_h) |want| y = @max(y, grid_top + want);
    // Captions at the bottom, below the border.
    y += tb.padding[2] + tb.border[2];
    for (g.captions.items) |cap| if (e.style(cap).inh.caption_side == .bottom) {
        try e.layoutBlock(cap, tb.w, null);
        const cb = e.tree.get(cap);
        cb.x = cb.margin[3];
        cb.y = y + cb.margin[0];
        y += cb.margin[0] + cb.h + cb.margin[2];
    };
    return y;
}

/// Rows and their groups span the columns, between the outer spacing.
fn finishGroup(e: *Engine, grp: BoxId, y0: f32, y1: f32, x0: f32, x1: f32) void {
    const gb = e.tree.get(grp);
    gb.x = x0;
    gb.y = y0;
    gb.w = @max(0, x1 - x0);
    gb.h = @max(0, y1 - y0);
    gb.laid_w = -1;
}

/// Moves a cell's content down (vertical-align: middle or bottom).
fn shiftChildren(e: *Engine, id: BoxId, dy: f32) void {
    var it = e.tree.children(id);
    while (it.next()) |c| e.tree.get(c).y += dy;
    const b = e.tree.get(id);
    // A cell holding its own IFC shifts its lines at paint time.
    if (b.kind == .inline_root) b.padding[0] += dy;
    if (!std.math.isNan(b.baseline)) b.baseline += dy;
}
