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
    // Header groups first, then bodies, then footers (CSS 2.1 17.2).
    var groups: [3]std.ArrayList(BoxId) = .{ .empty, .empty, .empty };
    var it = e.tree.children(table);
    while (it.next()) |c| {
        const b = e.tree.get(c);
        if (b.out_of_flow) continue;
        switch (b.kind) {
            .table_caption => try g.captions.append(e.scratch, c),
            .table_row_group => {
                const inner = e.style(c).box.display.inner;
                const k: usize = if (inner == .table_header_group) 0 else if (inner == .table_footer_group) 2 else 1;
                try groups[k].append(e.scratch, c);
            },
            else => {},
        }
    }
    var occupied: std.AutoHashMapUnmanaged(u64, void) = .empty;
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
                for (0..rs) |dr| for (0..cs) |dc| try occupied.put(e.scratch, @as(u64, r + @as(u32, @intCast(dr))) << 32 | (col + @as(u32, @intCast(dc))), {});
                try g.cells.append(e.scratch, .{ .id = cell, .row = r, .col = col, .rows = rs, .cols = cs });
                col += cs;
                g.ncols = @max(g.ncols, col);
            }
        }
    };
    // Spans past the last row end there.
    const nrows: u32 = @intCast(g.rows.items.len);
    for (g.cells.items) |*c| c.rows = @max(1, @min(c.rows, nrows - c.row));
    return g;
}

fn spacing(e: *Engine, table: BoxId) [2]f32 {
    const st = e.style(table);
    if (st.inh.border_collapse == .collapse) return .{ 0, 0 };
    return st.inh.border_spacing;
}

fn edges(e: *Engine, id: BoxId, cb_w: f32) void {
    const b = e.tree.get(id);
    const st = e.style(id);
    for (0..4) |i| {
        b.padding[i] = st.box.padding[i].resolve(cb_w);
        b.border[i] = st.borderWidth(i);
        b.margin[i] = 0;
    }
}

/// Column minimum and maximum widths from the cells.
fn columns(e: *Engine, table: BoxId, g: *const Grid, avail: ?f32) Error![2][]f32 {
    const mins = try e.scratch.alloc(f32, g.ncols);
    const maxs = try e.scratch.alloc(f32, g.ncols);
    @memset(mins, 0);
    @memset(maxs, 0);
    const sp = spacing(e, table)[0];
    const fixed = e.style(table).box.table_layout == .fixed and !e.style(table).box.width.isAuto();
    for ([_]bool{ false, true }) |multi| for (g.cells.items) |c| {
        if ((c.cols > 1) != multi) continue;
        if (fixed and c.row != 0) continue;
        edges(e, c.id, avail orelse 0);
        var mn = try e.intrinsic(c.id, false, false);
        var mx = try e.intrinsic(c.id, true, false);
        const st = e.style(c.id);
        // A fixed width on a cell is its column's width.
        if (st.box.width.tag == .length and !st.box.width.hasPercent()) {
            const b = e.tree.get(c.id);
            const w = st.box.width.resolve(0) + (if (st.box.box_sizing == .border_box) 0 else b.padding[1] + b.padding[3] + b.border[1] + b.border[3]);
            mx = @max(mn, w);
            if (fixed) mn = w;
        }
        if (c.cols == 1) {
            mins[c.col] = @max(mins[c.col], mn);
            maxs[c.col] = @max(maxs[c.col], mx);
        } else {
            const span_sp = sp * @as(f32, @floatFromInt(c.cols - 1));
            var cur_min: f32 = span_sp;
            var cur_max: f32 = span_sp;
            for (c.col..c.col + c.cols) |k| {
                cur_min += mins[k];
                cur_max += maxs[k];
            }
            const n: f32 = @floatFromInt(c.cols);
            if (mn > cur_min) for (c.col..c.col + c.cols) |k| {
                mins[k] += (mn - cur_min) / n;
            };
            if (mx > cur_max) for (c.col..c.col + c.cols) |k| {
                maxs[k] += (mx - cur_max) / n;
            };
        }
    };
    for (mins, maxs) |mn, *mx| mx.* = @max(mx.*, mn);
    return .{ mins, maxs };
}

fn tableExtras(e: *Engine, table: BoxId, g: *const Grid) f32 {
    const b = e.tree.get(table);
    const sp = spacing(e, table)[0];
    return b.padding[1] + b.padding[3] + b.border[1] + b.border[3] + sp * @as(f32, @floatFromInt(g.ncols + 1));
}

pub fn intrinsic(e: *Engine, id: BoxId, max: bool) Error!f32 {
    const g = try build(e, id);
    edges(e, id, 0);
    const cols = try columns(e, id, &g, null);
    var s: f32 = tableExtras(e, id, &g);
    for (if (max) cols[1] else cols[0]) |w| s += w;
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
    _ = content_h;
    const g = try build(e, id);
    const tb = e.tree.get(id);
    const sp = spacing(e, id);
    const cols = try columns(e, id, &g, content_w_);
    // The table's width (`layoutAt` gave it) less spacing and edges.
    const avail = @max(0, tb.w - tableExtras(e, id, &g));
    var sum_min: f32 = 0;
    var sum_max: f32 = 0;
    for (cols[0], cols[1]) |mn, mx| {
        sum_min += mn;
        sum_max += mx;
    }
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
            if (st.box.width.tag != .length or st.box.width.hasPercent()) continue;
            const b = e.tree.get(c.id);
            const w = st.box.width.resolve(0) + (if (st.box.box_sizing == .border_box) 0 else b.padding[1] + b.padding[3] + b.border[1] + b.border[3]);
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
    } else if (avail >= sum_max) {
        // Extra space goes to the columns in proportion to their widths.
        for (widths, cols[1]) |*w, mx| w.* = if (sum_max > 0) mx + (avail - sum_max) * mx / sum_max else avail / @as(f32, @floatFromInt(@max(1, g.ncols)));
    } else if (avail > sum_min) {
        const t = (avail - sum_min) / @max(sum_max - sum_min, 0.001);
        for (widths, cols[0], cols[1]) |*w, mn, mx| w.* = mn + (mx - mn) * t;
    } else for (widths, cols[0]) |*w, mn| {
        w.* = mn;
    }
    // Column positions.
    const xs = try e.scratch.alloc(f32, g.ncols + 1);
    const left = tb.border[3] + tb.padding[3] + sp[0];
    xs[0] = left;
    for (widths, 0..) |w, i| xs[i + 1] = xs[i] + w + sp[0];
    // Captions on top.
    var y: f32 = tb.border[0] + tb.padding[0];
    const inner_w = tb.w - tb.border[1] - tb.border[3] - tb.padding[1] - tb.padding[3];
    for (g.captions.items) |cap| if (e.style(cap).inh.caption_side == .top) {
        try e.layoutBlock(cap, inner_w, null);
        const cb = e.tree.get(cap);
        cb.x = tb.border[3] + tb.padding[3] + cb.margin[3];
        cb.y = y + cb.margin[0];
        y += cb.margin[0] + cb.h + cb.margin[2];
    };
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
    // Rows and groups positions. Groups and rows are laid out as boxes
    // spanning the table's content width.
    const row_y = try e.scratch.alloc(f32, nrows + 1);
    y += sp[1];
    var group_start_y = y;
    var current_group: BoxId = none;
    for (g.rows.items, 0..) |row, r| {
        const grp = g.groups.items[r];
        if (grp != current_group) {
            if (current_group != none) finishGroup(e, current_group, group_start_y, y - sp[1], tb);
            current_group = grp;
            group_start_y = y;
        }
        row_y[r] = y;
        const rb = e.tree.get(row);
        rb.x = 0;
        rb.y = y - group_start_y;
        rb.w = tb.w - tb.border[1] - tb.border[3] - tb.padding[1] - tb.padding[3];
        rb.h = heights[r];
        rb.laid_w = -1;
        y += heights[r] + sp[1];
    }
    if (current_group != none) finishGroup(e, current_group, group_start_y, y - sp[1], tb);
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
        cb.x = xs[c.col] - (tb.border[3] + tb.padding[3]) - rb.x;
        cb.y = 0;
        const shift = switch (st.box.vertical_align) {
            .middle => (h - content_height) / 2,
            .bottom => h - content_height,
            else => 0,
        };
        if (shift > 0) shiftChildren(e, c.id, shift);
        cb.h = h;
        if (!std.math.isNan(cb.baseline) and c.row == 0) {
            const tbb = e.tree.get(id);
            if (std.math.isNan(tbb.baseline)) tbb.baseline = row_y[0] + cb.baseline;
        }
    }
    // Captions at the bottom.
    for (g.captions.items) |cap| if (e.style(cap).inh.caption_side == .bottom) {
        try e.layoutBlock(cap, inner_w, null);
        const cb = e.tree.get(cap);
        cb.x = tb.border[3] + tb.padding[3] + cb.margin[3];
        cb.y = y + cb.margin[0];
        y += cb.margin[0] + cb.h + cb.margin[2];
    };
    return y + tb.padding[2] + tb.border[2];
}

fn finishGroup(e: *Engine, grp: BoxId, y0: f32, y1: f32, tb: *const box_mod.Box) void {
    const gb = e.tree.get(grp);
    gb.x = tb.border[3] + tb.padding[3];
    gb.y = y0;
    gb.w = tb.w - tb.border[1] - tb.border[3] - tb.padding[1] - tb.padding[3];
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
