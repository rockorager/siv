//! Grid layout (CSS Grid Layout 2): the explicit grid from templates
//! (`repeat()` with counts, `auto-fill`, and `auto-fit`, line names, and
//! named areas with their implicit `-start`/`-end` lines); line-based
//! placement with integers, names, negative indices, and spans, implicit
//! tracks on both sides; auto placement (8.5: row or column, sparse or
//! dense); the track sizing algorithm (12.3 to 12.8: fixed, percentage,
//! intrinsic, `minmax()`, `fit-content()`, and flexible tracks; items of
//! one span, then by increasing span with the distribution of extra
//! space, then items crossing flexible tracks; maximizing; the fr size;
//! stretching auto tracks); automatic minimum sizes of items (6.6);
//! `auto-fit` collapsing empty tracks; gaps; self alignment with auto
//! margins and baselines; content alignment; absolutely positioned
//! children against their grid area; and intrinsic sizes.

const std = @import("std");
const css = @import("css");
const layout_mod = @import("layout.zig");
const box_mod = @import("box.zig");

const Engine = layout_mod.Engine;
const Error = layout_mod.Error;
const BoxId = box_mod.BoxId;
const S = css.style;
const Align = S.Align;
const inf = std.math.inf(f32);

const Track = struct {
    min: S.Breadth,
    max: S.Breadth,
    fit: ?S.Len = null,
    base: f32 = 0,
    limit: f32 = inf,
    pos: f32 = 0,
    /// An empty auto-fit track: no size, no gaps around it.
    collapsed: bool = false,
    /// From a repeat(auto-fit).
    auto_fit: bool = false,
    // The distribution of extra space (12.5.1).
    planned: f32 = 0,
    incurred: f32 = 0,
    growable: bool = false,

    fn flexible(t: Track) bool {
        return t.max == .fr;
    }
    fn intrinsicMin(t: Track) bool {
        return switch (t.min) {
            .auto, .min_content, .max_content => true,
            else => false,
        };
    }
    fn intrinsicMax(t: Track) bool {
        return switch (t.max) {
            .auto, .min_content, .max_content => true,
            else => false,
        } or t.fit != null;
    }
    fn maxContentMax(t: Track) bool {
        return t.max == .auto or t.max == .max_content or t.fit != null;
    }
    fn fr(t: Track) f32 {
        return if (t.max == .fr) t.max.fr else 0;
    }
};

const Item = struct {
    id: BoxId,
    /// Lines (0-based, after implicit tracks before the explicit grid).
    col: [2]u32,
    row: [2]u32,
    /// Margins with auto as 0, and which are auto.
    m: [4]f32 = .{ 0, 0, 0, 0 },
    auto: [4]bool = .{ false, false, false, false },
    /// Contributions per axis, measured once: min-content, max-content,
    /// and the minimum contribution (outer sizes).
    c: [2][3]f32 = .{ .{ -1, -1, -1 }, .{ -1, -1, -1 } },
    baseline: f32 = 0,
};

const Axis = struct {
    tracks: std.ArrayList(Track) = .empty,
    /// Line names of the explicit grid, by line (before the offset).
    names: std.ArrayList([]const []const u8) = .empty,
    explicit: u32 = 0,
    /// Implicit tracks before the explicit grid.
    offset: u32 = 0,
    gap: f32 = 0,
};

const Grid = struct {
    cols: Axis = .{},
    rows: Axis = .{},
    items: std.ArrayList(Item) = .empty,
};

fn breadthFixed(b: S.Breadth, basis: ?f32) ?f32 {
    return switch (b) {
        .len => |l| l.definite(basis),
        else => null,
    };
}

/// The explicit tracks of one axis (7.2), with auto repetitions as many
/// as fit (7.2.3.2).
fn explicit(e: *Engine, ax: *Axis, tracks: ?*const S.Tracks, avail: ?f32, min_avail: ?f32) Error!void {
    const t = tracks orelse {
        try ax.names.append(e.scratch, &.{});
        return;
    };
    var names: []const []const u8 = &.{};
    const join = struct {
        fn f(a: std.mem.Allocator, x: []const []const u8, y: []const []const u8) Error![]const []const u8 {
            if (x.len == 0) return y;
            if (y.len == 0) return x;
            return std.mem.concat(a, []const u8, &.{ x, y });
        }
    }.f;
    for (t.items) |item| switch (item) {
        .names => |n| names = try join(e.scratch, names, n),
        .size => |s| {
            try ax.names.append(e.scratch, names);
            names = &.{};
            try ax.tracks.append(e.scratch, .{ .min = s.min, .max = s.max, .fit = s.fit_content });
        },
        .repeat => |r| {
            var count: u32 = r.count;
            if (r.auto != .none) {
                // Each repetition's size: definite max, else definite min.
                var per: f32 = 0;
                var ok = true;
                for (r.sizes) |s| {
                    const basis = avail orelse min_avail;
                    const mn = breadthFixed(s.min, basis);
                    // A definite maximum, floored by a definite minimum.
                    const mx = if ((if (s.fit_content) |fc| fc.definite(basis) else null) orelse breadthFixed(s.max, basis)) |x| (if (mn) |m| @max(x, m) else x) else null;
                    const v = mx orelse mn;
                    if (v) |x| per += @max(x, 0) else ok = false;
                }
                const rep_gap = ax.gap * @as(f32, @floatFromInt(r.sizes.len));
                count = 1;
                if (ok and per > 0) {
                    // Space for the other tracks of the template.
                    var others: f32 = 0;
                    var n_others: f32 = 0;
                    for (t.items) |o| if (o == .size) {
                        others += breadthFixed(o.size.max, avail orelse min_avail) orelse breadthFixed(o.size.min, avail orelse min_avail) orelse 0;
                        n_others += 1;
                    };
                    others += ax.gap * n_others;
                    if (avail) |a| {
                        const space = a - others + ax.gap;
                        count = @max(1, @as(u32, @intFromFloat(@max(0, @floor((space + 0.01) / (per + rep_gap))))));
                    } else if (min_avail) |a| {
                        // The fewest that reach the minimum.
                        const space = a - others + ax.gap;
                        count = @max(1, @as(u32, @intFromFloat(@max(1, @ceil((space - 0.01) / (per + rep_gap))))));
                    }
                }
            }
            for (0..@min(count, 10000)) |_| for (r.sizes, 0..) |s, k| {
                const before: []const []const u8 = if (k < r.names.len) r.names[k] else &.{};
                try ax.names.append(e.scratch, try join(e.scratch, names, before));
                names = &.{};
                try ax.tracks.append(e.scratch, .{ .min = s.min, .max = s.max, .fit = s.fit_content, .auto_fit = r.auto == .fit });
                if (k + 1 == r.sizes.len and r.names.len > r.sizes.len) names = r.names[r.sizes.len];
            };
        },
    };
    try ax.names.append(e.scratch, names);
}

/// The size of implicit track `k` (from the explicit grid's end; negative
/// before it) from grid-auto-rows or grid-auto-columns.
fn autoTrack(tracks: ?*const S.Tracks, k: i64) Track {
    const t = tracks orelse return .{ .min = .auto, .max = .auto };
    var n: i64 = 0;
    for (t.items) |item| if (item == .size) {
        n += 1;
    };
    if (n == 0) return .{ .min = .auto, .max = .auto };
    var i = @mod(k, n);
    for (t.items) |item| if (item == .size) {
        if (i == 0) return .{ .min = item.size.min, .max = item.size.max, .fit = item.size.fit_content };
        i -= 1;
    };
    return .{ .min = .auto, .max = .auto };
}

fn hasName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The explicit line of the nth (1-based; negative from the end) line
/// called `name`, possibly an area's implicit `-start`/`-end` line, or a
/// line in the implicit grid when there are fewer (8.3.1).
fn namedLine(ax: *const Axis, areas: ?*const S.Areas, horizontal: bool, name: []const u8, n: i32, suffix: []const u8) i64 {
    var buf: [128]u8 = undefined;
    const full: []const u8 = if (suffix.len > 0 and name.len + suffix.len <= buf.len) blk: {
        @memcpy(buf[0..name.len], name);
        @memcpy(buf[name.len..][0..suffix.len], suffix);
        break :blk buf[0 .. name.len + suffix.len];
    } else name;
    const lines = ax.names.items.len;
    const Has = struct {
        fn at(a: *const Axis, ar: ?*const S.Areas, hz: bool, line: usize, nm: []const u8, base: []const u8, sfx: []const u8) bool {
            if (hasName(a.names.items[line], nm)) return true;
            // An area's edges name lines `area-start` and `area-end`.
            const g = ar orelse return false;
            if (sfx.len == 0) return false;
            const lim = if (hz) g.columns else g.rows;
            var first: ?u32 = null;
            var last: u32 = 0;
            for (g.cells, 0..) |cell, ci| if (std.mem.eql(u8, cell, base)) {
                const k: u32 = if (hz) @intCast(ci % g.columns) else @intCast(ci / g.columns);
                if (first == null or k < first.?) first = k;
                last = @max(last, k);
            };
            _ = lim;
            const f = first orelse return false;
            return if (std.mem.eql(u8, sfx, "-start")) line == f else line == last + 1;
        }
    };
    if (n > 0) {
        var count: i32 = 0;
        for (0..lines) |line| if (Has.at(ax, areas, horizontal, line, full, name, suffix)) {
            count += 1;
            if (count == n) return @intCast(line);
        };
        if (suffix.len > 0) return namedLine(ax, areas, horizontal, name, n, "");
        // Implicit lines all have the name.
        return @as(i64, @intCast(lines - 1)) + (n - count);
    }
    var count: i32 = 0;
    var line: usize = lines;
    while (line > 0) {
        line -= 1;
        if (Has.at(ax, areas, horizontal, line, full, name, suffix)) {
            count -= 1;
            if (count == n) return @intCast(line);
        }
    }
    if (suffix.len > 0) return namedLine(ax, areas, horizontal, name, n, "");
    return -@as(i64, @intCast(-(n - count)));
}

/// A placement on one axis (8.3): start and end lines of the explicit
/// grid's numbering (negative before it), or a span to auto-place.
const Lines = struct { start: ?i64, span: u32 };

fn resolve(ax: *const Axis, areas: ?*const S.Areas, horizontal: bool, start: S.GridLine, end: S.GridLine) Lines {
    const explicit_last: i64 = @intCast(ax.names.items.len - 1);
    const Line = struct {
        fn of(a: *const Axis, ar: ?*const S.Areas, hz: bool, l: S.GridLine, is_start: bool, last: i64) ?i64 {
            if (l.kind != .line) return null;
            if (l.name.len > 0) return namedLine(a, ar, hz, l.name, l.n, if (is_start) "-start" else "-end");
            if (l.n > 0) return l.n - 1;
            return last + 1 + l.n;
        }
    };
    var s = Line.of(ax, areas, horizontal, start, true, explicit_last);
    var en = Line.of(ax, areas, horizontal, end, false, explicit_last);
    // A span with a name ends at the nth line with that name.
    if (s != null and end.kind == .span and end.name.len > 0) {
        var count: i32 = 0;
        var line = s.? + 1;
        while (line < ax.names.items.len) : (line += 1) if (line >= 0 and hasName(ax.names.items[@intCast(line)], end.name)) {
            count += 1;
            if (count == end.n) break;
        };
        en = line + (end.n - count) - @as(i64, if (count == end.n) 0 else 1);
        if (count == end.n) en = line;
    }
    if (en != null and start.kind == .span and start.name.len > 0) {
        var count: i32 = 0;
        var line = en.? - 1;
        while (line >= 0) : (line -= 1) if (line < ax.names.items.len and hasName(ax.names.items[@intCast(line)], start.name)) {
            count += 1;
            if (count == start.n) break;
        };
        s = if (count == start.n) line else line - (start.n - count) + 1;
    }
    const span_of = struct {
        fn f(l: S.GridLine) u32 {
            return if (l.kind == .span and l.name.len == 0) @intCast(@max(1, l.n)) else 1;
        }
    }.f;
    if (s != null and en != null) {
        var a = s.?;
        var b = en.?;
        if (b < a) std.mem.swap(i64, &a, &b);
        if (b == a) b = a + 1;
        return .{ .start = a, .span = @intCast(@min(b - a, 10000)) };
    }
    if (s) |a| return .{ .start = a, .span = span_of(end) };
    if (en) |b| {
        const sp = span_of(start);
        return .{ .start = b - sp, .span = sp };
    }
    // Both automatic: the start's span wins.
    return .{ .start = null, .span = if (start.kind == .span) span_of(start) else span_of(end) };
}

/// Occupied cells while auto placing, rows of a bitmap that grows.
const Cells = struct {
    bits: std.DynamicBitSetUnmanaged = .{},
    cols: usize,
    rows: usize = 0,

    fn ensure(c: *Cells, a: std.mem.Allocator, rows: usize) Error!void {
        if (rows <= c.rows) return;
        try c.bits.resize(a, rows * c.cols, false);
        c.rows = rows;
    }
    fn free(c: *Cells, r: usize, col: usize, rs: usize, cs: usize) bool {
        if (col + cs > c.cols) return false;
        for (r..r + rs) |rr| {
            if (rr >= c.rows) return true;
            for (col..col + cs) |cc| if (c.bits.isSet(rr * c.cols + cc)) return false;
        }
        return true;
    }
    fn mark(c: *Cells, a: std.mem.Allocator, r: usize, col: usize, rs: usize, cs: usize) Error!void {
        try c.ensure(a, r + rs);
        for (r..r + rs) |rr| for (col..@min(col + cs, c.cols)) |cc| c.bits.set(rr * c.cols + cc);
    }
};

const Pending = struct { id: BoxId, col: Lines, row: Lines, order: i32 };

fn place(e: *Engine, id: BoxId, content_w: ?f32, content_h: ?f32, min_w: ?f32, min_h: ?f32) Error!Grid {
    const st = e.style(id);
    var g: Grid = .{};
    g.cols.gap = if (st.box.column_gap.tag == .length) st.box.column_gap.resolve(content_w orelse 0) else 0;
    g.rows.gap = if (st.box.row_gap.tag == .length) st.box.row_gap.resolve(content_h orelse 0) else 0;
    try explicit(e, &g.cols, st.box.grid_template_columns, content_w, min_w);
    try explicit(e, &g.rows, st.box.grid_template_rows, content_h, min_h);
    // Named areas extend the explicit grid.
    const areas = st.box.grid_template_areas;
    if (areas) |ar| {
        while (g.cols.tracks.items.len < ar.columns) {
            try g.cols.tracks.append(e.scratch, autoTrack(st.box.grid_auto_columns, @intCast(g.cols.tracks.items.len)));
            try g.cols.names.append(e.scratch, &.{});
        }
        while (g.rows.tracks.items.len < ar.rows) {
            try g.rows.tracks.append(e.scratch, autoTrack(st.box.grid_auto_rows, @intCast(g.rows.tracks.items.len)));
            try g.rows.names.append(e.scratch, &.{});
        }
    }
    g.cols.explicit = @intCast(g.cols.tracks.items.len);
    g.rows.explicit = @intCast(g.rows.tracks.items.len);

    // Resolve each item's lines; the implicit grid before the explicit.
    var pending: std.ArrayList(Pending) = .empty;
    var reordered = false;
    var lo_c: i64 = 0;
    var lo_r: i64 = 0;
    var it = e.tree.children(id);
    while (it.next()) |c| {
        if (e.tree.get(c).out_of_flow) continue;
        const ist = e.style(c);
        const p: Pending = .{
            .id = c,
            .col = resolve(&g.cols, areas, true, ist.box.grid_column_start, ist.box.grid_column_end),
            .row = resolve(&g.rows, areas, false, ist.box.grid_row_start, ist.box.grid_row_end),
            .order = ist.box.order,
        };
        reordered = reordered or p.order != 0;
        if (p.col.start) |s| lo_c = @min(lo_c, s);
        if (p.row.start) |s| lo_r = @min(lo_r, s);
        try pending.append(e.scratch, p);
    }
    if (reordered) std.sort.insertion(Pending, pending.items, {}, struct {
        fn lt(_: void, a: Pending, b: Pending) bool {
            return a.order < b.order;
        }
    }.lt);
    g.cols.offset = @intCast(-lo_c);
    g.rows.offset = @intCast(-lo_r);

    const column_flow = st.box.grid_auto_flow.column;
    const dense = st.box.grid_auto_flow.dense;
    // In flow terms: "major" is the axis items advance along (rows for
    // row flow), "minor" the one they fill (columns).
    const MajorMinor = struct {
        fn minor(p: *const Pending, col_flow: bool) Lines {
            return if (col_flow) p.row else p.col;
        }
        fn major(p: *const Pending, col_flow: bool) Lines {
            return if (col_flow) p.col else p.row;
        }
    };
    const minor_off: i64 = if (column_flow) g.rows.offset else g.cols.offset;
    const major_off: i64 = if (column_flow) g.cols.offset else g.rows.offset;
    var minor_count: i64 = @as(i64, if (column_flow) g.rows.explicit else g.cols.explicit) + minor_off;
    for (pending.items) |*p| {
        const mn = MajorMinor.minor(p, column_flow);
        if (mn.start) |s| {
            minor_count = @max(minor_count, s + minor_off + mn.span);
        } else minor_count = @max(minor_count, mn.span);
    }
    minor_count = @max(minor_count, 1);
    var cells: Cells = .{ .cols = @intCast(minor_count) };
    var placed: std.ArrayList(struct { p: Pending, major: i64, minor: i64 }) = .empty;
    // 1. Items with both positions definite.
    for (pending.items) |p| {
        const mj = MajorMinor.major(&p, column_flow);
        const mn = MajorMinor.minor(&p, column_flow);
        if (mj.start == null or mn.start == null) continue;
        const r = mj.start.? + major_off;
        const c = mn.start.? + minor_off;
        try cells.mark(e.scratch, @intCast(r), @intCast(c), mj.span, mn.span);
        try placed.append(e.scratch, .{ .p = p, .major = r, .minor = c });
    }
    // 2. Items locked to a major line (a row, in row flow).
    {
        var cursors: std.AutoHashMapUnmanaged(i64, i64) = .empty;
        for (pending.items) |p| {
            const mj = MajorMinor.major(&p, column_flow);
            const mn = MajorMinor.minor(&p, column_flow);
            if (mj.start == null or mn.start != null) continue;
            const r = mj.start.? + major_off;
            var c: i64 = if (dense) 0 else cursors.get(r) orelse 0;
            while (!cells.free(@intCast(r), @intCast(c), mj.span, mn.span)) {
                c += 1;
                if (c + mn.span > cells.cols) {
                    // Wider than the grid: past the end, as implicit tracks.
                    break;
                }
            }
            try cells.mark(e.scratch, @intCast(r), @intCast(@min(c, @as(i64, @intCast(cells.cols)))), mj.span, mn.span);
            try placed.append(e.scratch, .{ .p = p, .major = r, .minor = c });
            try cursors.put(e.scratch, r, c + mn.span);
        }
    }
    // 3. The rest, with the auto-placement cursor.
    var cur_major: i64 = 0;
    var cur_minor: i64 = 0;
    for (pending.items) |p| {
        const mj = MajorMinor.major(&p, column_flow);
        const mn = MajorMinor.minor(&p, column_flow);
        if (mj.start != null) continue;
        if (dense) {
            cur_major = 0;
            cur_minor = 0;
        }
        if (mn.start) |s| {
            const c = s + minor_off;
            if (!dense and c < cur_minor) cur_major += 1;
            var r = cur_major;
            while (!cells.free(@intCast(r), @intCast(c), mj.span, mn.span)) r += 1;
            try cells.mark(e.scratch, @intCast(r), @intCast(c), mj.span, mn.span);
            try placed.append(e.scratch, .{ .p = p, .major = r, .minor = c });
            cur_major = r;
            cur_minor = c;
        } else {
            var r = cur_major;
            var c = cur_minor;
            while (true) {
                if (c + mn.span > cells.cols) {
                    c = 0;
                    r += 1;
                    continue;
                }
                if (cells.free(@intCast(r), @intCast(c), mj.span, mn.span)) break;
                c += 1;
            }
            try cells.mark(e.scratch, @intCast(r), @intCast(c), mj.span, mn.span);
            try placed.append(e.scratch, .{ .p = p, .major = r, .minor = c });
            cur_major = r;
            cur_minor = c + mn.span;
        }
    }
    // The implicit grid: tracks before (offset) and after.
    var max_c: i64 = @as(i64, g.cols.explicit) + g.cols.offset;
    var max_r: i64 = @as(i64, g.rows.explicit) + g.rows.offset;
    for (placed.items) |pl| {
        const col: [2]i64 = if (column_flow) .{ pl.major, pl.major + pl.p.col.span } else .{ pl.minor, pl.minor + pl.p.col.span };
        const row: [2]i64 = if (column_flow) .{ pl.minor, pl.minor + pl.p.row.span } else .{ pl.major, pl.major + pl.p.row.span };
        max_c = @max(max_c, col[1]);
        max_r = @max(max_r, row[1]);
        try g.items.append(e.scratch, .{ .id = pl.p.id, .col = .{ @intCast(col[0]), @intCast(col[1]) }, .row = .{ @intCast(row[0]), @intCast(row[1]) } });
    }
    try implicitTracks(e, &g.cols, st.box.grid_auto_columns, @intCast(max_c));
    try implicitTracks(e, &g.rows, st.box.grid_auto_rows, @intCast(max_r));
    // Children keep their tree order for painting; the order of items
    // only affects placement.
    std.sort.insertion(Item, g.items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return a.id < b.id;
        }
    }.lt);
    // auto-fit: empty repeated tracks collapse.
    for ([_]*Axis{ &g.cols, &g.rows }, [_]bool{ true, false }) |ax, cols| {
        for (ax.tracks.items, 0..) |*t, k| if (t.auto_fit) {
            var used = false;
            for (g.items.items) |item| {
                const r = if (cols) item.col else item.row;
                if (k >= r[0] and k < r[1]) used = true;
            }
            t.collapsed = !used;
        };
    }
    return g;
}

fn implicitTracks(e: *Engine, ax: *Axis, auto: ?*const S.Tracks, total: u32) Error!void {
    // Before: counted back from the explicit grid's start.
    var before: std.ArrayList(Track) = .empty;
    var k: u32 = 0;
    while (k < ax.offset) : (k += 1) try before.append(e.scratch, autoTrack(auto, -@as(i64, ax.offset - k)));
    try ax.tracks.insertSlice(e.scratch, 0, before.items);
    var after: i64 = 0;
    while (ax.tracks.items.len < total) : (after += 1) try ax.tracks.append(e.scratch, autoTrack(auto, after));
}

fn edgesOf(e: *Engine, id: BoxId, basis: f32) void {
    e.resolveEdges(id, basis);
}

fn spanOf(item: *const Item, columns: bool) [2]u32 {
    return if (columns) item.col else item.row;
}

fn gapsIn(ax: *const Axis, r: [2]u32) f32 {
    var n: f32 = 0;
    var k = r[0];
    while (k + 1 < r[1]) : (k += 1) if (!ax.tracks.items[k].collapsed and !ax.tracks.items[k + 1].collapsed) {
        n += 1;
    };
    return n * ax.gap;
}

fn areaSize(ax: *const Axis, r: [2]u32) f32 {
    var s: f32 = gapsIn(ax, r);
    for (ax.tracks.items[r[0]..r[1]]) |t| s += t.base;
    return s;
}

/// What sizes the tracks of an axis: the container's inner size when
/// definite, or a min-content or max-content constraint.
const Avail = union(enum) { definite: f32, min_content, max_content };

/// Contributions of an item in an axis (outer sizes): min-content,
/// max-content, and the minimum contribution (6.6).
fn contributions(e: *Engine, g: *Grid, item: *Item, columns: bool, cb_w: f32) Error![3]f32 {
    const ax: usize = if (columns) 0 else 1;
    if (item.c[ax][0] >= 0) return item.c[ax];
    const ist = e.style(item.id);
    const b = e.tree.get(item.id);
    var out: [3]f32 = undefined;
    if (columns) {
        out[0] = try e.intrinsic(item.id, false, true);
        out[1] = try e.intrinsic(item.id, true, true);
        const ml = ist.box.margin[1].resolve(0) + ist.box.margin[3].resolve(0);
        out[2] = if (e.borderBoxLen0(item.id, ist.box.min_width, true)) |v| v + ml else if (ist.box.min_width.isAuto() and visibleOverflow(ist)) try autoMinimum(e, g, item, true) + ml else e.extras0(item.id, true) + ml;
    } else {
        // Heights at the item's width in its column area.
        const w = try itemWidth(e, g, item, cb_w);
        e.resolveEdges(item.id, areaSize(&g.cols, item.col));
        const mt = e.tree.get(item.id).margin[0] + e.tree.get(item.id).margin[2];
        var h: f32 = undefined;
        if (b.kind == .replaced) {
            h = replacedHeight(e, item.id, w);
        } else {
            try e.layoutSized(item.id, w, cb_w, null, .{});
            h = e.tree.get(item.id).h;
        }
        out[0] = h + mt;
        out[1] = h + mt;
        if (e.borderBoxLen(item.id, ist.box.min_height, null, false)) |v| {
            out[2] = v + mt;
        } else if (ist.box.min_height.isAuto() and visibleOverflow(ist)) {
            // The content-based minimum: the content's height, or the
            // specified height when smaller.
            var content = h;
            if (b.kind != .replaced) {
                try e.layoutSized(item.id, w, cb_w, null, .{ .content = true });
                content = e.tree.get(item.id).h;
            }
            if (e.borderBoxLen(item.id, ist.box.height, null, false)) |spec| content = @min(content, spec);
            out[2] = @min(content, clampToFixed(g, item, false, content)) + mt;
        } else out[2] = Engine.verticalExtras(e.tree.get(item.id)) + mt;
    }
    item.c[ax] = out;
    return out;
}

fn visibleOverflow(st: *const css.Style) bool {
    return (st.box.overflow_x == .visible or st.box.overflow_x == .clip) and (st.box.overflow_y == .visible or st.box.overflow_y == .clip);
}

/// An item's content-based minimum width (6.6): the specified width when
/// smaller than its min-content width, limited to its tracks when they
/// all have fixed maximums.
fn autoMinimum(e: *Engine, g: *Grid, item: *Item, columns: bool) Error!f32 {
    const ist = e.style(item.id);
    const b = e.tree.get(item.id);
    var content = try e.contentWidth(item.id, false);
    if (b.kind == .replaced) {
        if (e.borderBoxLen0(item.id, ist.box.height, false)) |h| {
            const r = e.natural(item.id).ratio;
            if (r > 0) content = (h - e.extras0(item.id, false)) * r + e.extras0(item.id, true);
        }
    }
    if (e.borderBoxLen0(item.id, ist.box.width, true)) |w| content = @min(content, w);
    if (e.borderBoxLen0(item.id, ist.box.max_width, true)) |w| content = @min(content, w);
    return clampToFixed(g, item, columns, content);
}

/// The automatic minimum is not larger than the item's tracks when it
/// spans only tracks with a fixed maximum (6.6).
fn clampToFixed(g: *Grid, item: *const Item, columns: bool, v: f32) f32 {
    const ax = if (columns) &g.cols else &g.rows;
    const r = spanOf(item, columns);
    var sum: f32 = gapsIn(ax, r);
    var any_auto_min = false;
    for (ax.tracks.items[r[0]..r[1]]) |t| {
        if (t.min == .auto) any_auto_min = true;
        const fixed = switch (t.max) {
            .len => |l| if (l.pct == 0 and l.nl == null) l.px else return v,
            else => return v,
        };
        sum += fixed;
    }
    if (!any_auto_min) return v;
    return @min(v, sum);
}

fn replacedHeight(e: *Engine, id: BoxId, w: f32) f32 {
    const st = e.style(id);
    const b = e.tree.get(id);
    if (e.borderBoxLen(id, st.box.height, null, false)) |h| return e.clampHeight(id, h, null);
    const nat = e.natural(id);
    const hx = Engine.horizontalExtras(b);
    const vx = Engine.verticalExtras(b);
    const h = if (nat.ratio > 0) @max(0, w - hx) / nat.ratio + vx else nat.h + vx;
    return e.clampHeight(id, h, null);
}

/// An item's border-box width in its column area: stretched, specified,
/// or fit-content (with a ratio, from a definite height).
fn itemWidth(e: *Engine, g: *Grid, item: *Item, cb_w: f32) Error!f32 {
    const ist = e.style(item.id);
    const b = e.tree.get(item.id);
    const area = areaSize(&g.cols, item.col);
    _ = cb_w;
    // Percentages of margins and padding: against the area's width.
    e.resolveEdges(item.id, area);
    const bm = e.tree.get(item.id);
    const margins = bm.margin[1] + bm.margin[3];
    const avail = @max(0, area - margins);
    if (e.borderBoxLen(item.id, ist.box.width, area, true)) |w| return e.clampWidth(item.id, w, area);
    if (try e.keywordWidth(item.id, ist.box.width, true)) |w| return e.clampWidth(item.id, w, area);
    const container = e.style(b.parent);
    const js = justifyOf(container, ist);
    if (b.kind == .replaced) {
        const nat = e.natural(item.id);
        if (e.borderBoxLen(item.id, ist.box.height, null, false)) |h| if (nat.ratio > 0) {
            return e.clampWidth(item.id, (h - Engine.verticalExtras(b)) * nat.ratio + Engine.horizontalExtras(b), area);
        };
        if (js == .stretch and !ist.box.margin[1].isAuto() and !ist.box.margin[3].isAuto()) return e.clampWidth(item.id, avail, area);
        return e.clampWidth(item.id, @min(try e.contentWidth(item.id, true), @max(avail, try e.contentWidth(item.id, false))), area);
    }
    const stretch = (js == .stretch or js == .normal) and !ist.box.margin[1].isAuto() and !ist.box.margin[3].isAuto();
    if (stretch) {
        if (ist.box.aspect_ratio > 0) if (e.borderBoxLen(item.id, ist.box.height, null, false)) |h| {
            return e.clampWidth(item.id, if (ist.box.box_sizing == .border_box) h * ist.box.aspect_ratio else (h - Engine.verticalExtras(b)) * ist.box.aspect_ratio + Engine.horizontalExtras(b), area);
        };
        return e.clampWidth(item.id, avail, area);
    }
    const mn = try e.contentWidth(item.id, false);
    const mx = try e.contentWidth(item.id, true);
    return e.clampWidth(item.id, @min(@max(mn, avail), mx), area);
}

fn justifyOf(container: *const css.Style, ist: *const css.Style) Align {
    const j = if (ist.box.justify_self == .auto) (if (container.box.justify_items == .legacy) Align.normal else container.box.justify_items) else ist.box.justify_self;
    return j;
}

fn alignOf(container: *const css.Style, ist: *const css.Style) Align {
    return if (ist.box.align_self == .auto) container.box.align_items else ist.box.align_self;
}

/// The track sizing algorithm for one axis (12.3 to 12.8).
fn sizeTracks(e: *Engine, g: *Grid, columns: bool, avail: Avail, cb_w: f32, stretch_auto: bool) Error!void {
    const ax = if (columns) &g.cols else &g.rows;
    const tracks = ax.tracks.items;
    const basis: ?f32 = if (avail == .definite) avail.definite else null;
    // 12.4: initial sizes.
    for (tracks) |*t| {
        // A percentage against an indefinite size is auto.
        if (t.min == .len and basis == null and t.min.len.hasPercent()) t.min = .auto;
        if (t.max == .len and basis == null and t.max.len.hasPercent()) t.max = .auto;
        t.base = switch (t.min) {
            .len => |l| @max(0, l.resolve(basis)),
            else => 0,
        };
        t.limit = switch (t.max) {
            .len => |l| @max(0, l.resolve(basis)),
            else => inf,
        };
        if (t.limit < t.base) t.limit = t.base;
        if (t.collapsed) {
            t.base = 0;
            t.limit = 0;
        }
    }
    // 12.5: intrinsic sizes. Items of one span first.
    var max_span: u32 = 1;
    for (g.items.items) |*item| {
        const r = spanOf(item, columns);
        const span = r[1] - r[0];
        max_span = @max(max_span, span);
        if (span != 1) continue;
        const t = &tracks[r[0]];
        if (t.collapsed or t.flexible() and !t.intrinsicMin()) continue;
        const cs = try contributions(e, g, item, columns, cb_w);
        switch (t.min) {
            .min_content => t.base = @max(t.base, cs[0]),
            .max_content => t.base = @max(t.base, cs[1]),
            .auto => t.base = @max(t.base, switch (avail) {
                .min_content => cs[0],
                .max_content => cs[1],
                .definite => cs[2],
            }),
            else => {},
        }
        if (t.flexible()) continue;
        const want: f32 = switch (t.max) {
            .min_content => cs[0],
            .max_content, .auto => cs[1],
            else => 0,
        };
        if (t.fit) |fc| {
            const cap = fc.resolve(basis);
            t.limit = @max(t.base, @min(if (t.limit == inf) cs[1] else @max(t.limit, cs[1]), cap));
        } else if (t.intrinsicMax()) {
            t.limit = if (t.limit == inf) want else @max(t.limit, want);
        }
        if (t.limit < t.base) t.limit = t.base;
    }
    // Spanning items, by increasing span, not crossing flexible tracks.
    var span: u32 = 2;
    while (span <= max_span) : (span += 1) {
        for (0..5) |step| {
            for (tracks) |*t| t.planned = 0;
            var any = false;
            for (g.items.items) |*item| {
                const r = spanOf(item, columns);
                if (r[1] - r[0] != span) continue;
                const spanned = tracks[r[0]..r[1]];
                var crosses_flex = false;
                for (spanned) |t| crosses_flex = crosses_flex or t.flexible();
                if (crosses_flex) continue;
                const cs = try contributions(e, g, item, columns, cb_w);
                any = true;
                try distribute(spanned, step, cs, avail, gapsIn(ax, r));
            }
            if (!any) break;
            for (tracks) |*t| {
                if (step < 3) {
                    t.base += t.planned;
                    if (t.limit < t.base) t.limit = t.base;
                } else if (t.planned > 0 or t.growable) {
                    t.limit = (if (t.limit == inf) t.base else t.limit) + t.planned;
                }
            }
        }
    }
    // Items crossing flexible tracks: their minimums go to the flexible
    // tracks with intrinsic minimums, in proportion to their fr.
    for (g.items.items) |*item| {
        const r = spanOf(item, columns);
        if (r[1] - r[0] < 2) continue;
        const spanned = tracks[r[0]..r[1]];
        var sum_fr: f32 = 0;
        var n_flex: f32 = 0;
        var cur: f32 = gapsIn(ax, r);
        for (spanned) |t| {
            cur += t.base;
            if (t.flexible() and t.intrinsicMin()) {
                sum_fr += t.fr();
                n_flex += 1;
            }
        }
        if (n_flex == 0) continue;
        const cs = try contributions(e, g, item, columns, cb_w);
        const want = switch (avail) {
            .min_content => cs[0],
            .max_content => cs[1],
            .definite => cs[2],
        };
        const extra = want - cur;
        if (extra <= 0) continue;
        for (spanned) |*t| if (t.flexible() and t.intrinsicMin()) {
            t.base += if (sum_fr > 0) extra * t.fr() / sum_fr else extra / n_flex;
        };
    }
    for (tracks) |*t| {
        if (t.limit == inf) t.limit = t.base;
        if (t.limit < t.base) t.limit = t.base;
    }
    const gaps = blk: {
        var n: f32 = 0;
        var prev = false;
        for (tracks) |t| if (!t.collapsed) {
            if (prev) n += 1;
            prev = true;
        };
        break :blk n * ax.gap;
    };
    // 12.6: maximize tracks.
    switch (avail) {
        .definite => |a| {
            var free = a - gaps;
            for (tracks) |t| free -= t.base;
            var guard: usize = 0;
            while (free > 0.01 and guard < 16) : (guard += 1) {
                var n: f32 = 0;
                for (tracks) |t| if (!t.flexible() and t.limit > t.base + 0.001) {
                    n += 1;
                };
                if (n == 0) break;
                const share = free / n;
                for (tracks) |*t| if (!t.flexible() and t.limit > t.base + 0.001) {
                    const add = @min(share, t.limit - t.base);
                    t.base += add;
                    free -= add;
                };
            }
        },
        .max_content => for (tracks) |*t| if (!t.flexible()) {
            t.base = t.limit;
        },
        .min_content => {},
    }
    // 12.7: flexible tracks.
    var any_flex = false;
    for (tracks) |t| any_flex = any_flex or (t.flexible() and !t.collapsed);
    if (any_flex) {
        var fr: f32 = 0;
        switch (avail) {
            .definite => |a| fr = findFr(tracks, a - gaps),
            .max_content => {
                for (tracks) |t| if (t.flexible() and !t.collapsed) {
                    fr = @max(fr, if (t.fr() > 1) t.base / t.fr() else t.base);
                };
                for (g.items.items) |*item| {
                    const r = spanOf(item, columns);
                    var crosses = false;
                    for (tracks[r[0]..r[1]]) |t| crosses = crosses or t.flexible();
                    if (!crosses) continue;
                    const cs = try contributions(e, g, item, columns, cb_w);
                    fr = @max(fr, findFr(tracks[r[0]..r[1]], cs[1] - gapsIn(ax, r)));
                }
            },
            .min_content => {},
        }
        for (tracks) |*t| if (t.flexible() and !t.collapsed) {
            t.base = @max(t.base, fr * t.fr());
        };
    }
    // 12.8: stretch auto tracks.
    if (stretch_auto) if (avail == .definite) {
        var free = avail.definite - gaps;
        for (tracks) |t| free -= t.base;
        if (free > 0) {
            var n: f32 = 0;
            for (tracks) |t| if (t.max == .auto and !t.collapsed) {
                n += 1;
            };
            if (n > 0) for (tracks) |*t| if (t.max == .auto and !t.collapsed) {
                t.base += free / n;
            };
        }
    };
}

/// Distributes an item's contribution to its spanned tracks (12.5.1) for
/// one step of 12.5, 3: 0 intrinsic minimums, 1 content-based minimums,
/// 2 max-content minimums, 3 intrinsic maximums, 4 max-content maximums.
fn distribute(spanned: []Track, step: usize, cs: [3]f32, avail: Avail, gaps: f32) Error!void {
    const affected = struct {
        fn f(t: Track, s: usize, av: Avail) bool {
            return switch (s) {
                0 => t.intrinsicMin(),
                1 => t.min == .min_content or t.min == .max_content,
                2 => t.min == .max_content or (t.min == .auto and av == .max_content),
                3 => t.intrinsicMax(),
                4 => t.maxContentMax(),
                else => false,
            };
        }
    }.f;
    const want: f32 = switch (step) {
        0 => switch (avail) {
            .min_content => cs[0],
            .max_content => cs[1],
            .definite => cs[2],
        },
        1, 3 => cs[0],
        else => cs[1],
    };
    var n: f32 = 0;
    var cur: f32 = gaps;
    for (spanned) |t| {
        cur += if (step < 3) t.base else (if (t.limit == inf) t.base else t.limit);
        if (affected(t, step, avail) and !t.collapsed) n += 1;
    }
    var space = want - cur;
    if (space <= 0 or n == 0) return;
    for (spanned) |*t| t.incurred = 0;
    // Up to the limits, equally, freezing tracks that reach theirs.
    var guard: usize = 0;
    while (space > 0.001 and guard < spanned.len + 1) : (guard += 1) {
        var open: f32 = 0;
        for (spanned) |t| if (affected(t, step, avail) and !t.collapsed and room(t, step) > t.incurred + 0.001) {
            open += 1;
        };
        if (open == 0) break;
        const share = space / open;
        for (spanned) |*t| if (affected(t.*, step, avail) and !t.collapsed) {
            const left = room(t.*, step) - t.incurred;
            if (left <= 0.001) continue;
            const add = @min(share, left);
            t.incurred += add;
            space -= add;
        };
    }
    if (space > 0.001) {
        // Beyond the limits: to the tracks that may grow further.
        var beyond: f32 = 0;
        for (spanned) |t| if (affected(t, step, avail) and !t.collapsed and beyondOk(t, step)) {
            beyond += 1;
        };
        if (beyond == 0) {
            for (spanned) |t| if (affected(t, step, avail) and !t.collapsed) {
                beyond += 1;
            };
            for (spanned) |*t| if (affected(t.*, step, avail) and !t.collapsed) {
                t.incurred += space / beyond;
            };
        } else for (spanned) |*t| if (affected(t.*, step, avail) and !t.collapsed and beyondOk(t.*, step)) {
            var add = space / beyond;
            if (t.fit) |_| if (step >= 3) {
                add = @min(add, @max(0, room(t.*, step) - t.incurred));
            };
            t.incurred += add;
        };
    }
    for (spanned) |*t| {
        if (t.incurred > t.planned) t.planned = t.incurred;
        if (step == 3 and t.limit == inf and t.incurred > 0) t.growable = true;
    }
}

/// How far a track may grow in a step before its limit.
fn room(t: Track, step: usize) f32 {
    if (step < 3) return if (t.limit == inf) inf else @max(0, t.limit - t.base);
    // Growth limits: an infinite one may grow without bound.
    if (t.limit == inf or t.growable) return inf;
    if (t.fit) |_| return inf;
    return 0;
}

fn beyondOk(t: Track, step: usize) bool {
    return switch (step) {
        0, 1 => t.intrinsicMax(),
        2 => t.maxContentMax(),
        else => true,
    };
}

/// The size of an fr (12.7.1): the leftover space shared by the flexible
/// tracks, those whose base exceeds their share treated as inflexible.
fn findFr(tracks: []const Track, space: f32) f32 {
    var inflexible: std.StaticBitSet(64) = .empty;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        var leftover = space;
        var sum: f32 = 0;
        for (tracks, 0..) |t, k| {
            if (t.collapsed) continue;
            if (t.flexible() and !(k < 64 and inflexible.isSet(k))) {
                sum += t.fr();
            } else leftover -= t.base;
        }
        const fr = @max(0, leftover) / @max(sum, 1);
        var changed = false;
        for (tracks, 0..) |t, k| if (t.flexible() and !t.collapsed and k < 64 and !inflexible.isSet(k) and t.base > fr * t.fr()) {
            inflexible.set(k);
            changed = true;
        };
        if (!changed) return fr;
    }
    return 0;
}

pub fn intrinsic(e: *Engine, id: BoxId, max: bool) Error!f32 {
    var g = try place(e, id, null, null, null, null);
    for (g.items.items) |item| edgesOf(e, item.id, 0);
    try sizeTracks(e, &g, true, if (max) .max_content else .min_content, 0, false);
    return totalOf(&g.cols);
}

fn totalOf(ax: *const Axis) f32 {
    var s: f32 = 0;
    var prev = false;
    for (ax.tracks.items) |t| if (!t.collapsed) {
        if (prev) s += ax.gap;
        prev = true;
        s += t.base;
    };
    return s;
}

/// Positions of the tracks after content alignment (10.5): `free` is the
/// space beyond the tracks.
fn positions(ax: *Axis, a: Align, safe: bool, free_: f32) void {
    var n: f32 = 0;
    for (ax.tracks.items) |t| if (!t.collapsed) {
        n += 1;
    };
    var free = free_;
    var offset: f32 = 0;
    var between: f32 = 0;
    if (safe and free < 0) free = 0;
    switch (a) {
        .center => offset = free / 2,
        .end, .flex_end, .right => offset = free,
        .space_between => if (free > 0 and n > 1) {
            between = free / (n - 1);
        },
        .space_around => if (free > 0) {
            offset = free / n / 2;
            between = free / n;
        } else {
            offset = free / 2;
        },
        .space_evenly => if (free > 0) {
            offset = free / (n + 1);
            between = free / (n + 1);
        } else {
            offset = free / 2;
        },
        else => {},
    }
    var pos = offset;
    var first = true;
    for (ax.tracks.items) |*t| {
        if (t.collapsed) {
            t.pos = pos;
            continue;
        }
        if (!first) pos += ax.gap + between;
        first = false;
        t.pos = pos;
        pos += t.base;
    }
}

pub fn layout(e: *Engine, id: BoxId, content_w: f32, content_h: ?f32) Error!f32 {
    const st = e.style(id);
    const cb = e.tree.get(id);
    const left = cb.border[3] + cb.padding[3];
    const top = cb.border[0] + cb.padding[0];
    const vx = Engine.verticalExtras(cb);
    const min_h: ?f32 = if (e.borderBoxLen(id, st.box.min_height, null, false)) |v| @max(0, v - vx) else null;
    const max_h: ?f32 = if (e.borderBoxLen(id, st.box.max_height, null, false)) |v| @max(0, v - vx) else null;
    var g = try place(e, id, content_w, content_h orelse max_h, null, if (content_h == null) min_h else null);
    for (g.items.items) |*item| {
        edgesOf(e, item.id, content_w);
        const b = e.tree.get(item.id);
        item.m = b.margin;
        const ist = e.style(item.id);
        for (0..4) |k| item.auto[k] = ist.box.margin[k].isAuto();
    }
    const stretch_cols = st.box.justify_content == .normal or st.box.justify_content == .stretch;
    const stretch_rows = st.box.align_content == .normal or st.box.align_content == .stretch;
    try sizeTracks(e, &g, true, .{ .definite = content_w }, content_w, stretch_cols);
    // Rows: item heights at their column areas' widths.
    const rows_avail: Avail = if (content_h) |h| .{ .definite = h } else .max_content;
    try sizeTracks(e, &g, false, rows_avail, content_w, stretch_rows and content_h != null);
    var total_h = totalOf(&g.rows);
    var inner_h = content_h orelse total_h;
    if (content_h == null) {
        // The container's min-height and max-height, then the rows again
        // against that height if it is not their sum.
        var h = total_h;
        if (max_h) |m| h = @min(h, m);
        if (min_h) |m| h = @max(h, m);
        if (h != total_h) {
            for (g.items.items) |*item| item.c[1] = .{ -1, -1, -1 };
            try sizeTracks(e, &g, false, .{ .definite = h }, content_w, stretch_rows);
            total_h = totalOf(&g.rows);
        }
        inner_h = h;
    }
    positions(&g.cols, st.box.justify_content, st.box.align_safe.justify_content, content_w - totalOf(&g.cols));
    positions(&g.rows, st.box.align_content, st.box.align_safe.align_content, inner_h - total_h);

    // Baselines of rows (items of one row span aligned by baseline).
    var row_baseline = try e.scratch.alloc(f32, g.rows.tracks.items.len);
    @memset(row_baseline, 0);

    // Items: sized in their areas and aligned.
    for (g.items.items) |*item| {
        const b = e.tree.get(item.id);
        const ist = e.style(item.id);
        const aw = areaSize(&g.cols, item.col);
        const ah = areaSize(&g.rows, item.row);
        edgesOf(e, item.id, aw);
        item.m = e.tree.get(item.id).margin;
        const js = justifyOf(st, ist);
        const as_ = alignOf(st, ist);
        const replaced_ratio = b.kind == .replaced and e.natural(item.id).ratio > 0;
        const w = try itemWidth(e, &g, item, content_w);
        // Heights: stretched (normal stretches items without a ratio),
        // specified, or from content.
        const stretch_y = (as_ == .stretch or (as_ == .normal and !replaced_ratio and !(b.kind != .replaced and ist.box.aspect_ratio > 0))) and ist.box.height.isAuto() and !item.auto[0] and !item.auto[2];
        if (stretch_y) {
            const h = e.clampHeight(item.id, @max(0, ah - item.m[0] - item.m[2]), ah);
            try e.layoutSized(item.id, w, aw, ah, .{ .h = h });
        } else if (b.kind == .replaced) {
            try e.layoutSized(item.id, w, aw, ah, .{ .h = replacedHeight(e, item.id, w) });
        } else try e.layoutSized(item.id, w, aw, ah, .{});
        const bb = e.tree.get(item.id);
        if ((as_ == .baseline) and item.row[1] - item.row[0] == 1) {
            item.baseline = item.m[0] + (if (!std.math.isNan(bb.baseline)) bb.baseline else bb.h);
            row_baseline[item.row[0]] = @max(row_baseline[item.row[0]], item.baseline);
        }
        _ = js;
    }
    for (g.items.items) |*item| {
        const bb = e.tree.get(item.id);
        const ist = e.style(item.id);
        const aw = areaSize(&g.cols, item.col);
        const ah = areaSize(&g.rows, item.row);
        const js = justifyOf(st, ist);
        const as_ = alignOf(st, ist);
        const x = selfOffset(js, aw, bb.w, item, true, st.box.align_safe.justify_items or ist.box.align_safe.justify_self, 0);
        const y = selfOffset(as_, ah, bb.h, item, false, st.box.align_safe.align_items or ist.box.align_safe.align_self, if (item.row[1] - item.row[0] == 1) row_baseline[item.row[0]] - item.baseline else 0);
        bb.margin = item.m;
        bb.x = left + g.cols.tracks.items[item.col[0]].pos + x;
        bb.y = top + g.rows.tracks.items[item.row[0]].pos + y;
        e.relativeOffset(item.id, content_w);
    }
    // The container's baselines: the first row's first item (by row, then
    // column) with a baseline, or one aligned by baseline.
    {
        const cbb = e.tree.get(id);
        var best: ?*Item = null;
        for (g.items.items) |*item| {
            if (best == null or item.row[0] < best.?.row[0] or (item.row[0] == best.?.row[0] and item.col[0] < best.?.col[0])) best = item;
        }
        if (best) |item| {
            const bb = e.tree.get(item.id);
            cbb.baseline = bb.y + if (!std.math.isNan(bb.baseline)) bb.baseline else bb.h;
        }
        var last: ?*Item = null;
        for (g.items.items) |*item| {
            if (last == null or item.row[0] > last.?.row[0] or (item.row[0] == last.?.row[0] and item.col[0] > last.?.col[0])) last = item;
        }
        if (last) |item| {
            const bb = e.tree.get(item.id);
            cbb.last_baseline = bb.y + if (!std.math.isNan(bb.last_baseline)) bb.last_baseline else bb.h;
        }
    }
    // Out-of-flow children: their grid area (or the padding box where a
    // line is auto) is their containing block when the container is
    // positioned; their static position is the content box's start.
    var it = e.tree.children(id);
    while (it.next()) |c| if (e.tree.get(c).out_of_flow) {
        const cbx = e.tree.get(c);
        cbx.static_x = left;
        cbx.static_y = top;
        cbx.static_area = .{ 0, 0 };
        cbx.static_align = .{ 0, 0 };
        if (st.isPositioned()) {
            const ist = e.style(c);
            const area = absArea(&g, st, ist, cb, content_w, inner_h);
            if (area) |r| try e.grid_areas.put(e.gpa, c, r) else _ = e.grid_areas.remove(c);
        }
        try e.absolutes.append(e.gpa, c);
    };
    return inner_h;
}

/// An absolutely positioned child's grid area in the container's padding
/// box (10.1), or null when both its axes are auto (the padding box).
fn absArea(g: *Grid, st: *const css.Style, ist: *const css.Style, cb: *const box_mod.Box, content_w: f32, content_h: f32) ?[4]f32 {
    const pad_w = content_w + cb.padding[1] + cb.padding[3];
    const pad_h = content_h + cb.padding[0] + cb.padding[2];
    const areas = st.box.grid_template_areas;
    var out: [4]f32 = .{ 0, 0, pad_w, pad_h };
    var any = false;
    for ([_]bool{ true, false }) |cols| {
        const ax = if (cols) &g.cols else &g.rows;
        const start = if (cols) ist.box.grid_column_start else ist.box.grid_row_start;
        const end = if (cols) ist.box.grid_column_end else ist.box.grid_row_end;
        if (start.kind != .line and end.kind != .line) continue;
        const lines = resolve(ax, areas, cols, start, end);
        const pad0 = if (cols) cb.padding[3] else cb.padding[0];
        const n: i64 = @intCast(ax.tracks.items.len);
        const lineAt = struct {
            fn f(a: *const Axis, line: i64, p0: f32) f32 {
                const l = line + a.offset;
                if (l <= 0) return p0 + (if (a.tracks.items.len > 0) a.tracks.items[0].pos else 0);
                if (l >= a.tracks.items.len) {
                    const t = a.tracks.items[a.tracks.items.len - 1];
                    return p0 + t.pos + t.base;
                }
                return p0 + a.tracks.items[@intCast(l)].pos;
            }
        }.f;
        var lo: f32 = 0;
        var hi: f32 = if (cols) pad_w else pad_h;
        if (start.kind == .line) {
            const s = lines.start orelse 0;
            if (s + ax.offset >= 0 and s + ax.offset <= n) lo = lineAt(ax, s, pad0);
        }
        if (end.kind == .line) {
            const s = (lines.start orelse 0) + lines.span;
            if (s + ax.offset >= 0 and s + ax.offset <= n) {
                hi = lineAt(ax, s, pad0);
                if (s + ax.offset > 0 and s + ax.offset < n) hi -= ax.gap;
            }
        }
        if (cols) {
            out[0] = lo;
            out[2] = @max(0, hi - lo);
        } else {
            out[1] = lo;
            out[3] = @max(0, hi - lo);
        }
        any = true;
    }
    return if (any) out else null;
}

/// The offset of an item's margin box in its area along one axis, after
/// auto margins and self alignment (11.1, 11.2); the margin is added.
fn selfOffset(a: Align, area: f32, size: f32, item: *Item, horizontal: bool, safe: bool, baseline_shift: f32) f32 {
    const s: usize = if (horizontal) 3 else 0;
    const en: usize = if (horizontal) 1 else 2;
    var free = area - size - item.m[s] - item.m[en];
    if (item.auto[s] or item.auto[en]) {
        if (free > 0) {
            if (item.auto[s] and item.auto[en]) {
                item.m[s] += free / 2;
                item.m[en] += free / 2;
            } else if (item.auto[s]) item.m[s] += free else item.m[en] += free;
        }
        return item.m[s];
    }
    if (safe and free < 0) free = 0;
    return item.m[s] + switch (a) {
        .center => free / 2,
        .end, .flex_end, .self_end, .right => free,
        .baseline => if (!horizontal) baseline_shift else 0,
        .last_baseline => free,
        else => 0,
    };
}
