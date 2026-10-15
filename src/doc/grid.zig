//! Grid layout (CSS Grid Layout 1): explicit tracks with repeat() (also
//! auto-fill and auto-fit), named areas and lines, line-based and span
//! placement, auto placement (row or column, sparse or dense), implicit
//! tracks, the track sizing algorithm (fixed, intrinsic, minmax,
//! fit-content, and flexible tracks; items spanning one track first, then
//! spanning items), gaps, item alignment, and content alignment.

const std = @import("std");
const css = @import("css");
const layout_mod = @import("layout.zig");
const box_mod = @import("box.zig");

const Engine = layout_mod.Engine;
const Error = layout_mod.Error;
const BoxId = box_mod.BoxId;
const S = css.style;

const Track = struct {
    size: S.TrackSize,
    base: f32 = 0,
    limit: f32 = std.math.inf(f32),
    pos: f32 = 0,
};

const Placed = struct {
    id: BoxId,
    col: u32,
    col_span: u32,
    row: u32,
    row_span: u32,
};

const Axis = struct {
    tracks: std.ArrayList(Track) = .empty,
    /// Line names by line number (0-based), from the template.
    names: std.ArrayList([]const []const u8) = .empty,
    /// Lines before the explicit grid (implicit tracks added at the start).
    offset: u32 = 0,
    explicit: u32 = 0,
};

fn expand(e: *Engine, ax: *Axis, tracks: ?*const S.Tracks, avail: ?f32, gap: f32) Error!void {
    const t = tracks orelse return;
    var names: []const []const u8 = &.{};
    for (t.items) |item| switch (item) {
        .names => |n| names = n,
        .size => |s| {
            try ax.names.append(e.scratch, names);
            names = &.{};
            try ax.tracks.append(e.scratch, .{ .size = s });
        },
        .repeat => |r| {
            var count = r.count;
            if (r.auto != .none) {
                // As many as fit: each repetition's fixed size.
                var per: f32 = 0;
                var fixed = true;
                for (r.sizes) |s| {
                    const v = fixedOf(s.max) orelse fixedOf(s.min) orelse blk: {
                        fixed = false;
                        break :blk 0;
                    };
                    per += v;
                }
                per += gap * @as(f32, @floatFromInt(r.sizes.len));
                count = if (avail) |a| (if (per > 0 and fixed) @max(1, @as(u32, @intFromFloat(@floor((a + gap) / per)))) else 1) else 1;
            }
            for (0..@min(count, 1000)) |_| for (r.sizes) |s| {
                try ax.names.append(e.scratch, names);
                names = &.{};
                try ax.tracks.append(e.scratch, .{ .size = s });
            };
        },
    };
    try ax.names.append(e.scratch, names);
    ax.explicit = @intCast(ax.tracks.items.len);
}

fn fixedOf(b: S.Breadth) ?f32 {
    return switch (b) {
        .len => |l| if (l.pct == 0 and l.nl == null) l.px else null,
        else => null,
    };
}

fn autoTrack(tracks: ?*const S.Tracks, i: usize) S.TrackSize {
    const t = tracks orelse return .{ .min = .auto, .max = .auto };
    var sizes: std.ArrayList(S.TrackSize) = .empty;
    _ = &sizes;
    var n: usize = 0;
    for (t.items) |item| if (item == .size) {
        n += 1;
    };
    if (n == 0) return .{ .min = .auto, .max = .auto };
    var k = i % n;
    for (t.items) |item| if (item == .size) {
        if (k == 0) return item.size;
        k -= 1;
    };
    return .{ .min = .auto, .max = .auto };
}

fn findName(ax: *const Axis, name: []const u8, nth: i32) ?u32 {
    var count: i32 = 0;
    for (ax.names.items, 0..) |list, line| for (list) |n| if (std.mem.eql(u8, n, name)) {
        count += 1;
        if (count == nth) return @intCast(line);
    };
    return null;
}

/// Resolves a placement on one axis to a 0-based start line and span.
fn resolveLines(ax: *const Axis, areas: ?*const S.Areas, horizontal: bool, start: S.GridLine, end: S.GridLine) struct { ?u32, u32 } {
    var s: ?i64 = null;
    var e_: ?i64 = null;
    var span: u32 = 1;
    const explicit: i64 = ax.explicit;
    const R = struct {
        fn line(a: *const Axis, ar: ?*const S.Areas, hz: bool, l: S.GridLine, is_start: bool) ?i64 {
            if (l.kind != .line) return null;
            if (l.name.len > 0) {
                // A named area's edge, or a named line.
                if (ar) |grid_areas| {
                    const lim = if (hz) grid_areas.columns else grid_areas.rows;
                    var first: ?u32 = null;
                    var last: u32 = 0;
                    for (grid_areas.cells, 0..) |cell, ci| if (std.mem.eql(u8, cell, l.name)) {
                        const k: u32 = if (hz) @intCast(ci % grid_areas.columns) else @intCast(ci / grid_areas.columns);
                        if (first == null or k < first.?) first = k;
                        last = @max(last, k);
                    };
                    _ = lim;
                    if (first) |f| return if (is_start) f else last + 1;
                }
                var buf: [64]u8 = undefined;
                const suffix = if (is_start) "-start" else "-end";
                if (l.name.len + suffix.len <= buf.len) {
                    @memcpy(buf[0..l.name.len], l.name);
                    @memcpy(buf[l.name.len..][0..suffix.len], suffix);
                    if (findName(a, buf[0 .. l.name.len + suffix.len], l.n)) |x| return x;
                }
                if (findName(a, l.name, l.n)) |x| return x;
                return null;
            }
            const n: i64 = l.n;
            if (n > 0) return n - 1;
            return @as(i64, a.explicit) + 1 + n;
        }
    };
    s = R.line(ax, areas, horizontal, start, true);
    e_ = R.line(ax, areas, horizontal, end, false);
    if (start.kind == .span) span = @intCast(@max(1, start.n));
    if (end.kind == .span) span = @intCast(@max(1, end.n));
    if (s != null and e_ != null) {
        var a = s.?;
        var b = e_.?;
        if (b < a) std.mem.swap(i64, &a, &b);
        if (b == a) b = a + 1;
        return .{ @intCast(@max(0, a)), @intCast(b - a) };
    }
    if (s) |a| return .{ @intCast(@max(0, a)), span };
    if (e_) |b| return .{ @intCast(@max(0, b - span)), span };
    _ = explicit;
    return .{ null, span };
}

fn ensureTracks(e: *Engine, ax: *Axis, n: u32, auto: ?*const S.Tracks) Error!void {
    while (ax.tracks.items.len < n) {
        const k = ax.tracks.items.len - ax.explicit;
        try ax.tracks.append(e.scratch, .{ .size = autoTrack(auto, k) });
    }
}

const Grid = struct {
    cols: Axis = .{},
    rows: Axis = .{},
    items: std.ArrayList(Placed) = .empty,
    col_gap: f32 = 0,
    row_gap: f32 = 0,
};

fn place(e: *Engine, id: BoxId, content_w: ?f32, content_h: ?f32) Error!Grid {
    const st = e.style(id);
    var g: Grid = .{};
    g.col_gap = if (st.box.column_gap.tag == .length) st.box.column_gap.resolve(content_w orelse 0) else 0;
    g.row_gap = if (st.box.row_gap.tag == .length) st.box.row_gap.resolve(content_h orelse 0) else 0;
    try expand(e, &g.cols, st.box.grid_template_columns, content_w, g.col_gap);
    try expand(e, &g.rows, st.box.grid_template_rows, content_h, g.row_gap);
    // Named areas extend the explicit grid.
    if (st.box.grid_template_areas) |ar| {
        try ensureTracks(e, &g.cols, ar.columns, st.box.grid_auto_columns);
        try ensureTracks(e, &g.rows, ar.rows, st.box.grid_auto_rows);
        g.cols.explicit = @max(g.cols.explicit, ar.columns);
        g.rows.explicit = @max(g.rows.explicit, ar.rows);
    }
    const flow = st.box.grid_auto_flow;
    var occupied: std.AutoHashMapUnmanaged(u64, void) = .empty;
    const occ = struct {
        fn key(r: u32, c: u32) u64 {
            return @as(u64, r) << 32 | c;
        }
        fn free(o: *const std.AutoHashMapUnmanaged(u64, void), r: u32, c: u32, rs: u32, cs: u32) bool {
            for (r..r + rs) |rr| for (c..c + cs) |cc| if (o.contains(key(@intCast(rr), @intCast(cc)))) return false;
            return true;
        }
        fn mark(o: *std.AutoHashMapUnmanaged(u64, void), a: std.mem.Allocator, r: u32, c: u32, rs: u32, cs: u32) Error!void {
            for (r..r + rs) |rr| for (c..c + cs) |cc| try o.put(a, key(@intCast(rr), @intCast(cc)), {});
        }
    };
    var pending: std.ArrayList(Placed) = .empty;
    var it = e.tree.children(id);
    while (it.next()) |c| {
        if (e.tree.get(c).out_of_flow) continue;
        const ist = e.style(c);
        const col = resolveLines(&g.cols, st.box.grid_template_areas, true, ist.box.grid_column_start, ist.box.grid_column_end);
        const row = resolveLines(&g.rows, st.box.grid_template_areas, false, ist.box.grid_row_start, ist.box.grid_row_end);
        const p: Placed = .{ .id = c, .col = col[0] orelse std.math.maxInt(u32), .col_span = col[1], .row = row[0] orelse std.math.maxInt(u32), .row_span = row[1] };
        if (col[0] != null and row[0] != null) {
            try occ.mark(&occupied, e.scratch, p.row, p.col, p.row_span, p.col_span);
            try g.items.append(e.scratch, p);
        } else try pending.append(e.scratch, p);
    }
    // Auto placement.
    const ncols_base: u32 = @max(1, @as(u32, @intCast(g.cols.tracks.items.len)));
    const nrows_base: u32 = @max(1, @as(u32, @intCast(g.rows.tracks.items.len)));
    var cur_r: u32 = 0;
    var cur_c: u32 = 0;
    for (pending.items) |*p| {
        if (flow.dense) {
            cur_r = 0;
            cur_c = 0;
        }
        if (!flow.column) {
            const ncols = @max(ncols_base, if (p.col != std.math.maxInt(u32)) p.col + p.col_span else p.col_span);
            if (p.row != std.math.maxInt(u32)) {
                // Row fixed: find a column.
                var c: u32 = 0;
                while (!occ.free(&occupied, p.row, c, p.row_span, p.col_span)) c += 1;
                p.col = c;
            } else if (p.col != std.math.maxInt(u32)) {
                var r: u32 = cur_r;
                while (!occ.free(&occupied, r, p.col, p.row_span, p.col_span)) r += 1;
                p.row = r;
            } else {
                var r = cur_r;
                var c = cur_c;
                while (true) {
                    if (c + p.col_span > ncols) {
                        c = 0;
                        r += 1;
                        continue;
                    }
                    if (occ.free(&occupied, r, c, p.row_span, p.col_span)) break;
                    c += 1;
                }
                p.row = r;
                p.col = c;
                cur_r = r;
                cur_c = c + p.col_span;
            }
        } else {
            const nrows = @max(nrows_base, if (p.row != std.math.maxInt(u32)) p.row + p.row_span else p.row_span);
            if (p.col != std.math.maxInt(u32)) {
                var r: u32 = 0;
                while (!occ.free(&occupied, r, p.col, p.row_span, p.col_span)) r += 1;
                p.row = r;
            } else if (p.row != std.math.maxInt(u32)) {
                var c: u32 = cur_c;
                while (!occ.free(&occupied, p.row, c, p.row_span, p.col_span)) c += 1;
                p.col = c;
            } else {
                var r = cur_r;
                var c = cur_c;
                while (true) {
                    if (r + p.row_span > nrows) {
                        r = 0;
                        c += 1;
                        continue;
                    }
                    if (occ.free(&occupied, r, c, p.row_span, p.col_span)) break;
                    r += 1;
                }
                p.row = r;
                p.col = c;
                cur_c = c;
                cur_r = r + p.row_span;
            }
        }
        try occ.mark(&occupied, e.scratch, p.row, p.col, p.row_span, p.col_span);
        try g.items.append(e.scratch, p.*);
    }
    var max_c: u32 = 0;
    var max_r: u32 = 0;
    for (g.items.items) |p| {
        max_c = @max(max_c, p.col + p.col_span);
        max_r = @max(max_r, p.row + p.row_span);
    }
    try ensureTracks(e, &g.cols, max_c, st.box.grid_auto_columns);
    try ensureTracks(e, &g.rows, max_r, st.box.grid_auto_rows);
    // auto-fit collapses empty repeated tracks.
    return g;
}

fn isIntrinsicMin(b: S.Breadth) bool {
    return switch (b) {
        .auto, .min_content, .max_content => true,
        else => false,
    };
}

fn isFlexible(t: Track) bool {
    return t.size.max == .fr;
}

/// The track sizing algorithm (CSS Grid 1, 12.3 to 12.7), simplified for
/// spanning items: their extra size is shared evenly.
fn sizeTracks(e: *Engine, g: *Grid, columns: bool, avail: ?f32, contribution: anytype) Error!void {
    const ax = if (columns) &g.cols else &g.rows;
    const tracks = ax.tracks.items;
    const gap = if (columns) g.col_gap else g.row_gap;
    for (tracks) |*t| {
        t.base = switch (t.size.min) {
            .len => |l| l.resolve(avail orelse 0),
            else => 0,
        };
        t.limit = switch (t.size.max) {
            .len => |l| if (avail != null or l.pct == 0) l.resolve(avail orelse 0) else std.math.inf(f32),
            .fr => std.math.inf(f32),
            else => std.math.inf(f32),
        };
        if (t.size.max == .len and t.limit < t.base) t.limit = t.base;
    }
    // Intrinsic contributions: single-span items, then spanning items.
    for ([_]bool{ false, true }) |multi| {
        for (g.items.items) |p| {
            const start = if (columns) p.col else p.row;
            const span = if (columns) p.col_span else p.row_span;
            if ((span > 1) != multi) continue;
            // Items spanning a flexible track do not contribute.
            var flexible = false;
            for (tracks[start..][0..span]) |t| flexible = flexible or isFlexible(t);
            if (flexible and multi) continue;
            const mn = try contribution.of(p, false);
            const mx = try contribution.of(p, true);
            const span_gaps = gap * @as(f32, @floatFromInt(span - 1));
            var cur_base: f32 = span_gaps;
            var cur_limit: f32 = span_gaps;
            var n_min: f32 = 0;
            var n_max: f32 = 0;
            for (tracks[start..][0..span]) |t| {
                cur_base += t.base;
                cur_limit += if (std.math.isInf(t.limit)) t.base else t.limit;
                if (isIntrinsicMin(t.size.min)) n_min += 1;
                if (t.size.max == .auto or t.size.max == .max_content or t.size.max == .min_content or t.size.fit_content != null or (t.size.max == .fr and !multi)) n_max += 1;
            }
            if (n_min > 0 and mn > cur_base) {
                const extra = (mn - cur_base) / n_min;
                for (tracks[start..][0..span]) |*t| if (isIntrinsicMin(t.size.min)) {
                    t.base += extra;
                };
            }
            if (n_max > 0) {
                cur_limit = span_gaps;
                for (tracks[start..][0..span]) |t| cur_limit += if (std.math.isInf(t.limit)) t.base else t.limit;
                var want = mx;
                for (tracks[start..][0..span]) |t| if (t.size.max == .min_content) {
                    want = mn;
                };
                const extra = @max(0, want - cur_limit) / n_max;
                for (tracks[start..][0..span]) |*t| {
                    const intrinsic_max = t.size.max == .auto or t.size.max == .max_content or t.size.max == .min_content or t.size.fit_content != null;
                    if (!intrinsic_max) continue;
                    var lim = (if (std.math.isInf(t.limit)) t.base else t.limit) + extra;
                    if (t.size.fit_content) |fc| lim = @min(lim, @max(t.base, fc.resolve(avail orelse 0)));
                    t.limit = @max(lim, t.base);
                }
            }
        }
    }
    for (tracks) |*t| if (std.math.isInf(t.limit) and !isFlexible(t.*)) {
        t.limit = t.base;
    } else if (t.limit < t.base) {
        t.limit = t.base;
    };
    const gaps = gap * @as(f32, @floatFromInt(@max(1, tracks.len) - 1));
    // Maximize: grow tracks toward their limits.
    if (avail) |a| {
        var used = gaps;
        for (tracks) |t| used += t.base;
        var free = a - used;
        var guard: usize = 0;
        while (free > 0.01 and guard < 8) : (guard += 1) {
            var growable: f32 = 0;
            for (tracks) |t| if (!isFlexible(t) and t.limit > t.base) {
                growable += 1;
            };
            if (growable == 0) break;
            const share = free / growable;
            for (tracks) |*t| if (!isFlexible(t.*) and t.limit > t.base) {
                const add = @min(share, t.limit - t.base);
                t.base += add;
                free -= add;
            };
        }
    } else for (tracks) |*t| if (!isFlexible(t.*)) {
        t.base = t.limit;
    };
    // Flexible tracks.
    var sum_fr: f32 = 0;
    for (tracks) |t| if (isFlexible(t)) {
        sum_fr += t.size.max.fr;
    };
    if (sum_fr > 0) {
        var leftover: f32 = undefined;
        if (avail) |a| {
            leftover = a - gaps;
            for (tracks) |t| if (!isFlexible(t)) {
                leftover -= t.base;
            };
            // Tracks whose base exceeds their share are treated as fixed.
            var frs = sum_fr;
            var fixed_base: f32 = 0;
            var changed = true;
            var mark = try e.scratch.alloc(bool, tracks.len);
            @memset(mark, false);
            while (changed) {
                changed = false;
                const per = if (frs > 0) (leftover - fixed_base) / @max(frs, 1) else 0;
                for (tracks, 0..) |t, i| if (isFlexible(t) and !mark[i] and t.base > per * t.size.max.fr) {
                    mark[i] = true;
                    frs -= t.size.max.fr;
                    fixed_base += t.base;
                    changed = true;
                };
            }
            const per = if (frs > 0) (leftover - fixed_base) / @max(frs, 1) else 0;
            for (tracks, 0..) |*t, i| if (isFlexible(t.*) and !mark[i]) {
                t.base = @max(t.base, per * t.size.max.fr);
            };
        } else {
            // Indefinite: the fr size from the tracks' contributions.
            var per: f32 = 0;
            for (tracks) |t| if (isFlexible(t)) {
                per = @max(per, if (std.math.isInf(t.limit)) t.base / @max(t.size.max.fr, 1) else t.limit / @max(t.size.max.fr, 1));
            };
            for (tracks) |*t| if (isFlexible(t.*)) {
                t.base = @max(t.base, per * t.size.max.fr);
            };
        }
    }
    // Positions.
    var pos: f32 = 0;
    for (tracks) |*t| {
        t.pos = pos;
        pos += t.base + gap;
    }
}

fn areaSize(ax: *const Axis, start: u32, span: u32, gap: f32) f32 {
    var s: f32 = gap * @as(f32, @floatFromInt(span - 1));
    for (ax.tracks.items[start..][0..span]) |t| s += t.base;
    return s;
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

pub fn intrinsic(e: *Engine, id: BoxId, max: bool) Error!f32 {
    var g = try place(e, id, null, null);
    const C = struct {
        e: *Engine,
        want_max: bool,
        fn of(c: @This(), p: Placed, mx: bool) Error!f32 {
            return c.e.intrinsic(p.id, mx and c.want_max, true);
        }
    };
    try sizeTracks(e, &g, true, null, C{ .e = e, .want_max = max });
    var s: f32 = g.col_gap * @as(f32, @floatFromInt(@max(1, g.cols.tracks.items.len) - 1));
    for (g.cols.tracks.items) |t| s += t.base;
    return s;
}

pub fn layout(e: *Engine, id: BoxId, content_w: f32, content_h: ?f32) Error!f32 {
    const st = e.style(id);
    var g = try place(e, id, content_w, content_h);
    const cb = e.tree.get(id);
    const left = cb.border[3] + cb.padding[3];
    const top = cb.border[0] + cb.padding[0];
    for (g.items.items) |p| edgesOf(e, p.id, content_w);
    const Cols = struct {
        e: *Engine,
        fn of(c: @This(), p: Placed, mx: bool) Error!f32 {
            return c.e.intrinsic(p.id, mx, true);
        }
    };
    try sizeTracks(e, &g, true, content_w, Cols{ .e = e });
    // Rows: item heights at their column area widths.
    const Rows = struct {
        e: *Engine,
        g: *Grid,
        cw: f32,
        fn of(c: @This(), p: Placed, mx: bool) Error!f32 {
            _ = mx;
            const w = areaSize(&c.g.cols, p.col, p.col_span, c.g.col_gap);
            const b = c.e.tree.get(p.id);
            const ist = c.e.style(p.id);
            const margins = b.margin[1] + b.margin[3];
            const iw = if (ist.box.width.isAuto() and b.kind != .replaced) @max(0, w - margins) else blk: {
                try c.e.layoutShrink(p.id, w);
                break :blk c.e.tree.get(p.id).w;
            };
            try c.e.layoutAt(p.id, iw, c.cw, null, null);
            const bb = c.e.tree.get(p.id);
            return bb.h + bb.margin[0] + bb.margin[2];
        }
    };
    try sizeTracks(e, &g, false, content_h, Rows{ .e = e, .g = &g, .cw = content_w });
    // Content alignment (justify-content / align-content).
    const total_w = areaSize(&g.cols, 0, @intCast(g.cols.tracks.items.len), g.col_gap);
    const total_h = areaSize(&g.rows, 0, @intCast(g.rows.tracks.items.len), g.row_gap);
    const off_x = contentOffset(st.box.justify_content, content_w - total_w, &g.cols, g.col_gap);
    const off_y = if (content_h) |ch| contentOffset(st.box.align_content, ch - total_h, &g.rows, g.row_gap) else 0;
    // Place items in their areas.
    for (g.items.items) |p| {
        const b = e.tree.get(p.id);
        const ist = e.style(p.id);
        const aw = areaSize(&g.cols, p.col, p.col_span, g.col_gap);
        const ah = areaSize(&g.rows, p.row, p.row_span, g.row_gap);
        const jx = if (ist.box.justify_self == .auto) (if (st.box.justify_items == .legacy) S.Align.normal else st.box.justify_items) else ist.box.justify_self;
        const ay = if (ist.box.align_self == .auto) st.box.align_items else ist.box.align_self;
        const margins_x = b.margin[1] + b.margin[3];
        const margins_y = b.margin[0] + b.margin[2];
        const stretch_x = (jx == .stretch or jx == .normal) and ist.box.width.isAuto() and b.kind != .replaced;
        const stretch_y = (ay == .stretch or ay == .normal) and ist.box.height.isAuto() and b.kind != .replaced;
        var w: f32 = undefined;
        if (stretch_x) {
            w = @max(0, aw - margins_x);
            try e.layoutAt(p.id, w, content_w, null, if (stretch_y) @max(0, ah - margins_y) else null);
        } else {
            try e.layoutShrink(p.id, aw);
            w = e.tree.get(p.id).w;
            if (stretch_y) try e.layoutAt(p.id, w, content_w, null, @max(0, ah - margins_y));
        }
        const bb = e.tree.get(p.id);
        const h = bb.h;
        var x = g.cols.tracks.items[p.col].pos + bb.margin[3];
        var y = g.rows.tracks.items[p.row].pos + bb.margin[0];
        switch (jx) {
            .center => x += (aw - margins_x - w) / 2,
            .end, .right, .flex_end, .self_end => x += aw - margins_x - w,
            else => {},
        }
        switch (ay) {
            .center => y += (ah - margins_y - h) / 2,
            .end, .flex_end, .self_end => y += ah - margins_y - h,
            else => {},
        }
        bb.x = left + off_x + x;
        bb.y = top + off_y + y;
        if (ist.box.position == .relative) {
            if (!ist.box.inset[3].isAuto()) bb.x += ist.box.inset[3].resolve(content_w);
            if (!ist.box.inset[0].isAuto()) bb.y += ist.box.inset[0].resolve(content_w);
        }
        const cbb = e.tree.get(id);
        if (std.math.isNan(cbb.baseline) and !std.math.isNan(bb.baseline)) cbb.baseline = bb.y + bb.baseline;
    }
    var it = e.tree.children(id);
    while (it.next()) |c| if (e.tree.get(c).out_of_flow) {
        e.tree.get(c).static_x = left;
        e.tree.get(c).static_y = top;
        try e.absolutes.append(e.gpa, c);
    };
    return content_h orelse total_h;
}

fn contentOffset(a: S.Align, free: f32, ax: *Axis, gap: f32) f32 {
    _ = gap;
    if (free <= 0) return 0;
    const n: f32 = @floatFromInt(ax.tracks.items.len);
    switch (a) {
        .center => return free / 2,
        .end, .flex_end, .right => return free,
        .space_between => if (n > 1) {
            for (ax.tracks.items, 0..) |*t, i| t.pos += free / (n - 1) * @as(f32, @floatFromInt(i));
        },
        .space_around => {
            for (ax.tracks.items, 0..) |*t, i| t.pos += free / n * (@as(f32, @floatFromInt(i)) + 0.5);
        },
        .space_evenly => {
            for (ax.tracks.items, 0..) |*t, i| t.pos += free / (n + 1) * @as(f32, @floatFromInt(i + 1));
        },
        else => {},
    }
    return 0;
}
