//! Tests of the UI module through its public interface: transactions,
//! layout, layers, input, and semantics. Pixel output is tested in
//! test/ui (headless golden images).

const std = @import("std");
const text = @import("text");
const text_node = @import("text_node.zig");
const scene = @import("scene");
const compositor = @import("compositor");
const raster = @import("raster");
const ui = @import("ui.zig");
const paint = @import("paint.zig");

const testing = std.testing;
const NodeId = ui.NodeId;

const CompLayer = std.meta.Elem(@FieldType(@FieldType(compositor.Tree, "layers"), "items"));

/// Stands in for the compositor thread: a compositor.Tree that applies
/// the window's ops under the compositor's own rules, with a log of them.
const Comp = struct {
    tree: compositor.Tree,
    log: std.ArrayList(compositor.Op) = .empty,
    keep_log: bool = false,
    seq: u64 = 0,

    fn sink(c: *Comp) ui.Sink {
        return .{ .ctx = c, .commit = commitFn };
    }

    fn commitFn(ctx: ?*anyopaque, ops: []const compositor.Op) error{OutOfMemory}!u64 {
        const c: *Comp = @ptrCast(@alignCast(ctx));
        if (c.keep_log) try c.log.appendSlice(testing.allocator, ops);
        c.seq += 1;
        for (ops) |op| {
            op.validate() catch std.debug.panic("invalid op {any}", .{op});
            if (!try c.tree.apply(op)) std.debug.panic("op does not fit the tree: {any}", .{op});
        }
        return c.seq;
    }

    fn get(c: *Comp, id: compositor.LayerId) *CompLayer {
        return c.tree.get(id).?;
    }

    fn count(c: *Comp) usize {
        var n: usize = 0;
        for (c.tree.layers.items) |l| n += @intFromBool(l.alive);
        return n;
    }

    fn children(c: *Comp, id: compositor.LayerId, buf: []compositor.LayerId) []compositor.LayerId {
        var n: usize = 0;
        var ch = c.get(id).first;
        while (ch != 0) : (ch = c.get(ch).next) {
            buf[n] = ch;
            n += 1;
        }
        return buf[0..n];
    }

    /// Scrolls as pointer input over the container would.
    fn scrollBy(c: *Comp, id: compositor.LayerId, delta: raster.Point) raster.Point {
        _ = c.tree.scrollBy(id, delta) catch unreachable;
        return c.get(id).offset;
    }

    fn deinit(c: *Comp) void {
        c.tree.deinit();
        c.log.deinit(testing.allocator);
    }
};

/// A window on the stand-in compositor with the Droid test fonts.
const Fixture = struct {
    fonts: ui.Fonts,
    comp: Comp,
    win: *ui.Window,
    frames_requested: usize = 0,
    /// Text input states the window sent, with their surrounding text.
    text_inputs: std.ArrayList(@import("platform").TextInputState) = .empty,
    surroundings: std.ArrayList([]u8) = .empty,

    fn init(f: *Fixture, options: struct { width: f32 = 200, height: f32 = 100, rtl: bool = false }) !void {
        f.* = .{ .fonts = try .init(testing.allocator), .comp = .{ .tree = .init(testing.allocator) }, .win = undefined };
        errdefer f.fonts.deinit();
        const tf = text.font.test_fonts;
        const chain = [_]text.FontId{
            try f.fonts.cache.add(tf.latin, 0, .borrowed),
            try f.fonts.cache.add(tf.arabic, 0, .borrowed),
            try f.fonts.cache.add(tf.hebrew, 0, .borrowed),
        };
        try f.fonts.register("Droid", &chain);
        try f.fonts.setDefault("Droid");
        f.win = try ui.Window.init(testing.allocator, .{
            .fonts = &f.fonts,
            .sink = f.comp.sink(),
            .host = .{ .ctx = f, .request_frame = requested, .text_input = textInput },
            .width = options.width,
            .height = options.height,
            .rtl = options.rtl,
        });
    }

    fn requested(ctx: ?*anyopaque) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.frames_requested += 1;
    }

    fn textInput(ctx: ?*anyopaque, seat: @import("platform").SeatId, state: *const @import("platform").TextInputState) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        std.debug.assert(seat == 0);
        const copy = testing.allocator.dupe(u8, state.surrounding) catch unreachable;
        f.surroundings.append(testing.allocator, copy) catch unreachable;
        var st = state.*;
        st.surrounding = copy;
        f.text_inputs.append(testing.allocator, st) catch unreachable;
    }

    fn deinit(f: *Fixture) void {
        for (f.surroundings.items) |b| testing.allocator.free(b);
        f.surroundings.deinit(testing.allocator);
        f.text_inputs.deinit(testing.allocator);
        // The compositor goes first; then nothing refers to the builders.
        f.comp.deinit();
        f.win.deinit();
        f.fonts.deinit();
    }

    /// Runs a frame, composes like the compositor's frame does, and hands
    /// back released builders and scroll reports as its events would.
    fn frame(f: *Fixture) !void {
        try f.win.frame();
        _ = try f.comp.tree.compose();
        for (f.comp.tree.endFrame()) |b| try f.win.handleEvent(&.{ .released = b });
        for (f.comp.tree.scrolled.items) |id| {
            f.comp.get(id).scrolled = false;
            try f.win.handleEvent(&.{ .scrolled = .{ .window = 0, .layer = id, .offset = f.comp.get(id).offset, .seq = f.comp.seq } });
        }
        f.comp.tree.scrolled.clearRetainingCapacity();
    }

    fn rect(f: *Fixture, id: NodeId) [4]f32 {
        const r = f.win.windowRect(id);
        return .{ r.x0, r.y0, r.width(), r.height() };
    }
};

fn box(t: *ui.Txn, parent: NodeId, kind: ui.Kind, layout: ui.Layout) !NodeId {
    const id = try t.create(parent, kind, .none);
    try t.setLayout(id, layout);
    return id;
}

test "flex row distributes free space and mirrors in RTL" {
    for ([_]bool{ false, true }) |rtl| {
        var f: Fixture = undefined;
        try f.init(.{ .width = 300, .height = 100, .rtl = rtl });
        defer f.deinit();
        const t = try f.win.begin();
        const row = try box(t, .root, .flex, .{ .padding = .{ .start = 10, .end = 20, .top = 5, .bottom = 5 } });
        try t.setFlex(row, .{ .gap = 10, .align_items = .start });
        const a = try box(t, row, .box, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } });
        const b = try box(t, row, .box, .{ .width = .{ .px = 30 }, .height = .{ .px = 40 }, .grow = 1 });
        const c = try box(t, row, .box, .{ .width = .{ .px = 30 }, .height = .{ .px = 10 }, .grow = 3, .align_y = .end });
        t.commit();
        try f.frame();
        // 300 - 30 padding - 20 gaps - 110 bases = 140 free: b +35, c +105.
        // The root stretches the row to the window.
        try testing.expectEqual([4]f32{ 0, 0, 300, 100 }, f.rect(row));
        if (!rtl) {
            try testing.expectEqual([4]f32{ 10, 5, 50, 20 }, f.rect(a));
            try testing.expectEqual([4]f32{ 70, 5, 65, 40 }, f.rect(b));
            try testing.expectEqual([4]f32{ 145, 85, 135, 10 }, f.rect(c));
        } else {
            // Start is the right edge; padding start (10) is on the right.
            try testing.expectEqual([4]f32{ 240, 5, 50, 20 }, f.rect(a));
            try testing.expectEqual([4]f32{ 165, 5, 65, 40 }, f.rect(b));
            try testing.expectEqual([4]f32{ 20, 85, 135, 10 }, f.rect(c));
        }
    }
}

test "flex items grow and shrink only to their max and min sizes" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 100, .height = 400 });
    defer f.deinit();
    const t = try f.win.begin();
    const col = try box(t, .root, .flex, .{ .width = .{ .px = 100 } });
    try t.setFlex(col, .{ .axis = .column });
    // 400 - 150 = 250 free, 125 each, but a stops at 150: b takes the rest.
    const a = try box(t, col, .box, .{ .height = .{ .px = 100 }, .grow = 1, .max_height = 150 });
    const b = try box(t, col, .box, .{ .height = .{ .px = 50 }, .grow = 1 });
    // 160 into 100 is 30 too much each, but c stops at its min of 70.
    const row = try box(t, col, .flex, .{ .height = .{ .px = 0 }, .width = .{ .px = 100 } });
    try t.setFlex(row, .{});
    const c = try box(t, row, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 10 }, .min_width = 70 });
    const d = try box(t, row, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 10 } });
    t.commit();
    try f.frame();
    try testing.expectEqual([4]f32{ 0, 0, 100, 150 }, f.rect(a));
    try testing.expectEqual([4]f32{ 0, 150, 100, 250 }, f.rect(b));
    try testing.expectEqual(@as(f32, 70), f.rect(c)[2]);
    try testing.expectEqual(@as(f32, 30), f.rect(d)[2]);
}

test "aborted transactions leave no trace; failed operations have no effect" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    var t = try f.win.begin();
    const a = try box(t, .root, .box, .{ .height = .{ .px = 10 } });
    const label = try t.create(a, .text, .none);
    try t.setText(label, "kept");
    t.commit();
    try f.frame();

    t = try f.win.begin();
    try testing.expectError(error.TransactionOpen, f.win.begin());
    const b = try box(t, .root, .flex, .{});
    _ = try t.create(b, .text, .none);
    try t.setText(label, "replaced");
    try t.setLayout(a, .{ .height = .{ .px = 50 } });
    try t.move(label, b, .none);
    try t.remove(a);
    // Rejected operations change nothing.
    try testing.expectError(error.InvalidNode, t.create(label, .box, .none)); // under a leaf
    try testing.expectError(error.InvalidNode, t.move(b, b, .none)); // cycle
    try testing.expectError(error.InvalidNode, t.remove(.root));
    try testing.expectError(error.InvalidArgument, t.setText(label, "\xff"));
    // Frames wait for the transaction.
    const before = f.win.stats.frames;
    try f.win.frame();
    try testing.expectEqual(before, f.win.stats.frames);
    t.abort();

    try testing.expectEqual(a, f.win.node(.root).first);
    try testing.expectEqual(a, f.win.node(.root).last);
    try testing.expectEqual(label, f.win.node(a).first);
    try testing.expectEqualStrings("kept", f.win.node(label).data.text.content);
    try testing.expectEqual(@as(f32, 10), f.win.node(a).layout.height.px);
    try testing.expect(!f.win.isLive(b));
    try f.frame();
    try testing.expectEqual(@as(f32, 10), f.rect(a)[3]);
    // A committed removal frees the subtree's slots after the next frame.
    t = try f.win.begin();
    try t.remove(a);
    t.commit();
    try testing.expect(!f.win.isLive(label));
    try f.frame();
    t = try f.win.begin();
    const reused = try t.create(.root, .box, .none);
    t.commit();
    try testing.expect(reused == a or reused == label);
}

test "box flows vertically; stack aligns and insets; grid tracks" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 400, .height = 300 });
    defer f.deinit();
    const t = try f.win.begin();
    const outer = try box(t, .root, .stack, .{});
    try t.setStack(outer, .{ .align_x = .start, .align_y = .start });
    // Box: shrinks to its widest child; children stretch to it unless aligned.
    const col = try box(t, outer, .box, .{ .padding = .all(4) });
    const wide = try box(t, col, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 10 } });
    const stretched = try box(t, col, .box, .{ .height = .{ .px = 5 } });
    const centered = try box(t, col, .box, .{ .width = .{ .px = 20 }, .height = .{ .px = 5 }, .align_x = .center });
    // Stack child pinned to the bottom end corner.
    const pinned = try box(t, outer, .box, .{ .width = .{ .px = 30 }, .height = .{ .px = 20 }, .inset = .{ .end = 5, .bottom = 10 } });
    // Grid: 50px, auto, 1fr columns in 300px.
    const g = try box(t, outer, .grid, .{ .width = .{ .px = 300 }, .inset = .{ .start = 0, .top = 100 } });
    try t.setGrid(g, .{ .columns = &.{ .{ .px = 50 }, .auto, .{ .fr = 1 } }, .column_gap = 10, .row_gap = 2 });
    var cells: [5]NodeId = undefined;
    for (&cells) |*c| c.* = try box(t, g, .box, .{ .height = .{ .px = 8 } });
    try t.setLayout(cells[1], .{ .width = .{ .px = 20 }, .height = .{ .px = 8 } });
    try t.setLayout(cells[3], .{ .height = .{ .px = 20 }, .column_span = 2 });
    t.commit();
    try f.frame();

    try testing.expectEqual([4]f32{ 0, 0, 88, 28 }, f.rect(col));
    try testing.expectEqual([4]f32{ 4, 4, 80, 10 }, f.rect(wide));
    try testing.expectEqual([4]f32{ 4, 14, 80, 5 }, f.rect(stretched));
    try testing.expectEqual([4]f32{ 34, 19, 20, 5 }, f.rect(centered));
    try testing.expectEqual([4]f32{ 365, 270, 30, 20 }, f.rect(pinned));
    // Column 2 is auto: its widest single-span item is cells[1] (20 wide).
    // fr gets the rest: 300 - 50 - 20 - 20 gaps = 210. Items stretch.
    try testing.expectEqual([4]f32{ 0, 100, 50, 8 }, f.rect(cells[0]));
    try testing.expectEqual([4]f32{ 60, 100, 20, 8 }, f.rect(cells[1]));
    try testing.expectEqual([4]f32{ 90, 100, 210, 8 }, f.rect(cells[2]));
    // cells[3] spans two columns of the second row, cells[4] follows it.
    try testing.expectEqual([4]f32{ 0, 110, 80, 20 }, f.rect(cells[3]));
    try testing.expectEqual([4]f32{ 90, 110, 210, 8 }, f.rect(cells[4]));
}

test "a fraction height in a box of definite height takes that fraction of it" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 200 });
    defer f.deinit();
    const t = try f.win.begin();
    // A pane: a box stretched by a flex row, as split panes are.
    const row = try box(t, .root, .flex, .{ .height = .{ .px = 120 } });
    const pane = try box(t, row, .box, .{ .width = .{ .px = 100 } });
    const header = try box(t, pane, .box, .{ .height = .{ .px = 20 } });
    const fill = try box(t, pane, .box, .{ .height = .{ .fraction = 0.5 } });
    // Inside a box whose height comes from its content the fraction stays
    // auto: the child takes its own content's height.
    const loose = try box(t, row, .box, .{});
    const inner = try box(t, loose, .box, .{});
    const auto = try box(t, inner, .box, .{ .height = .{ .fraction = 1 } });
    _ = try box(t, auto, .box, .{ .height = .{ .px = 15 } });
    t.commit();
    try f.frame();
    try testing.expectEqual([4]f32{ 0, 0, 100, 120 }, f.rect(pane));
    try testing.expectEqual([4]f32{ 0, 0, 100, 20 }, f.rect(header));
    try testing.expectEqual([4]f32{ 0, 20, 100, 60 }, f.rect(fill));
    try testing.expectEqual(@as(f32, 15), f.rect(auto)[3]);
}

test "grid columns run right to left in RTL" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 100, .height = 50, .rtl = true });
    defer f.deinit();
    const t = try f.win.begin();
    const g = try box(t, .root, .grid, .{});
    try t.setGrid(g, .{ .columns = &.{ .{ .px = 30 }, .{ .fr = 1 } } });
    const first = try box(t, g, .box, .{});
    const second = try box(t, g, .box, .{});
    t.commit();
    try f.frame();
    try testing.expectEqual([4]f32{ 70, 0, 30, 50 }, f.rect(first));
    try testing.expectEqual([4]f32{ 0, 0, 70, 50 }, f.rect(second));
}

test "text wraps; width changes relayout without reshaping; style color only repaints" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 400, .height = 200 });
    defer f.deinit();
    var t = try f.win.begin();
    const col = try box(t, .root, .box, .{});
    const label = try box(t, col, .text, .{ .align_x = .start });
    try t.setText(label, "The quick brown fox jumps over the lazy dog");
    t.commit();
    try f.frame();
    const one_line = f.rect(label);
    try testing.expect(one_line[2] < 400 and one_line[2] > 100);
    try testing.expectEqual(@as(u64, 1), f.win.stats.shapes);

    // Narrower: wraps into more lines, same paragraph.
    f.win.configure(120, 200, 1);
    try f.frame();
    const wrapped = f.rect(label);
    try testing.expect(wrapped[2] <= 120);
    try testing.expect(wrapped[3] >= 3 * one_line[3]);
    try testing.expectEqual(@as(u64, 1), f.win.stats.shapes);

    // Color: no layout at all, one layer repaint.
    const layouts = f.win.stats.layouts;
    const builds = f.win.stats.layer_builds;
    t = try f.win.begin();
    try t.setTextProps(label, .{ .style = .{ .color = .white } });
    t.commit();
    try f.frame();
    try testing.expectEqual(layouts, f.win.stats.layouts);
    try testing.expectEqual(builds + 1, f.win.stats.layer_builds);
    try testing.expectEqual(@as(u64, 1), f.win.stats.shapes);

    // New text in a node whose size cannot change still repaints.
    t = try f.win.begin();
    const fixed = try box(t, col, .text, .{ .width = .{ .px = 100 }, .height = .{ .px = 20 } });
    try t.setText(fixed, "abc");
    t.commit();
    try f.frame();
    const before = f.win.stats.layer_builds;
    t = try f.win.begin();
    try t.setText(fixed, "xyz");
    t.commit();
    try f.frame();
    try testing.expectEqual(before + 1, f.win.stats.layer_builds);

    // Size: reshapes.
    t = try f.win.begin();
    try t.setTextProps(label, .{ .style = .{ .size = 20 } });
    t.commit();
    try f.frame();
    try testing.expectEqual(@as(u64, 4), f.win.stats.shapes);
}

test "clean subtrees are not laid out again" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 400, .height = 400 });
    defer f.deinit();
    var t = try f.win.begin();
    const col = try box(t, .root, .flex, .{});
    try t.setFlex(col, .{ .axis = .column });
    var rows: [20]NodeId = undefined;
    for (&rows) |*r| {
        r.* = try box(t, col, .flex, .{ .padding = .all(2) });
        for (0..3) |_| _ = try box(t, r.*, .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    }
    t.commit();
    try f.frame();
    const first = f.win.stats.layouts;
    try testing.expect(first >= 81);

    // A paint-only change: no layout.
    t = try f.win.begin();
    try t.setVisual(rows[5], .{ .background = .black });
    t.commit();
    try f.frame();
    try testing.expectEqual(first, f.win.stats.layouts);

    // One leaf grows: its row, the column, and the root relayout. Siblings
    // keep their caches (their constraints did not change).
    t = try f.win.begin();
    try t.setLayout(f.win.node(rows[7]).first, .{ .width = .{ .px = 10 }, .height = .{ .px = 30 } });
    t.commit();
    try f.frame();
    const delta = f.win.stats.layouts - first;
    try testing.expect(delta <= 6);
    try testing.expectEqual(@as(f32, 34), f.rect(rows[7])[3]);
}

test "scroll content scrolls on the compositor; offsets are logical" {
    for ([_]bool{ false, true }) |rtl| {
        var f: Fixture = undefined;
        try f.init(.{ .width = 100, .height = 100, .rtl = rtl });
        defer f.deinit();
        var t = try f.win.begin();
        const sc = try box(t, .root, .scroll, .{ .padding = .all(5) });
        try t.setScroll(sc, .{ .axis = .both });
        const content = try box(t, sc, .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 500 } });
        t.commit();
        try f.frame();
        // The scroll container is a layer with the content box as viewport.
        const li = f.win.state(sc).own_layer;
        const l = f.comp.get(li + 1);
        try testing.expectEqual(@as(f32, 90), l.scroll.?.viewport.width());
        try testing.expectEqual(@as(f32, 300), l.scroll.?.content.width);
        // Logical offset 0 shows the start edge: in RTL the content's right.
        try testing.expectEqual(@as(f32, if (rtl) 210 else 0), l.offset.x);
        try testing.expectEqual([4]f32{ if (rtl) -205 else 5, 5, 300, 500 }, f.rect(content));

        // The compositor scrolls by itself and reports it.
        const layouts = f.win.stats.layouts;
        const off = f.comp.scrollBy(li + 1, .{ .x = if (rtl) -10 else 10, .y = 30 });
        try f.win.handleEvent(&.{ .scrolled = .{ .window = 0, .layer = li + 1, .offset = off, .seq = f.comp.seq } });
        try testing.expectEqual(@as(f32, 10), f.win.node(sc).data.scroll.offset.x);
        try testing.expectEqual(@as(f32, 30), f.win.node(sc).data.scroll.offset.y);
        try f.frame();
        try testing.expectEqual(layouts, f.win.stats.layouts);
        try testing.expectEqual(@as(f32, 5 - 30), f.rect(content)[1]);

        // A programmatic scroll is a scroll_to, without layout or paint.
        const builds = f.win.stats.layer_builds;
        t = try f.win.begin();
        try t.setScroll(sc, .{ .axis = .both, .offset = .{ .x = 0, .y = 1000 } });
        t.commit();
        try f.frame();
        try testing.expectEqual(builds, f.win.stats.layer_builds);
        try testing.expectEqual(@as(f32, 410), f.comp.get(li + 1).offset.y);
        // A stale report (from before the scroll_to) is ignored.
        try f.win.handleEvent(&.{ .scrolled = .{ .window = 0, .layer = li + 1, .offset = .{ .x = 0, .y = 3 }, .seq = 1 } });
        try testing.expectEqual(@as(f32, 1000), f.win.node(sc).data.scroll.offset.y);
    }
}

test "long text paints the lines near its scroll viewport; scrolling past them repaints" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 100 });
    defer f.deinit();
    var t = try f.win.begin();
    const sc = try box(t, .root, .scroll, .{ .width = .{ .fraction = 1 }, .height = .{ .fraction = 1 } });
    try t.setScroll(sc, .{ .axis = .vertical });
    const doc = try box(t, sc, .text, .{ .width = .{ .fraction = 1 } });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..400) |i| try buf.print(testing.allocator, "line {d}\n", .{i});
    try t.setText(doc, buf.items);
    t.commit();
    try f.frame();
    const runs = struct {
        /// Glyph runs in the layers, and the lowest and highest baseline.
        fn of(comp: *Comp) struct { usize, f32, f32 } {
            var n: usize = 0;
            var lo: f32 = std.math.inf(f32);
            var hi: f32 = -std.math.inf(f32);
            for (comp.tree.layers.items) |l| {
                if (!l.alive) continue;
                const c = l.content orelse continue;
                for (c.list.commands) |cmd| if (cmd == .glyphs) {
                    n += 1;
                    lo = @min(lo, cmd.glyphs.bounds.y0);
                    hi = @max(hi, cmd.glyphs.bounds.y1);
                };
            }
            return .{ n, lo, hi };
        }
    }.of;
    // 400 lines; a 100 px viewport and one viewport each side paint about
    // 300 px of them.
    const lines = text_node.current(f.win, doc).?.lineCount();
    try testing.expect(lines >= 400);
    const first = runs(&f.comp);
    try testing.expect(first[0] > 5 and first[0] < 40);
    try testing.expect(first[2] < 260);

    // A short scroll stays inside what was painted: no repaint.
    const li = f.win.state(sc).own_layer + 1;
    const builds = f.win.stats.layer_builds;
    var off = f.comp.scrollBy(li, .{ .x = 0, .y = 40 });
    try f.win.handleEvent(&.{ .scrolled = .{ .window = 0, .layer = li, .offset = off, .seq = f.comp.seq } });
    try f.frame();
    try testing.expectEqual(builds, f.win.stats.layer_builds);

    // Far down: the lines now in view are painted, in content coordinates.
    off = f.comp.scrollBy(li, .{ .x = 0, .y = 3000 });
    try f.win.handleEvent(&.{ .scrolled = .{ .window = 0, .layer = li, .offset = off, .seq = f.comp.seq } });
    try f.frame();
    try testing.expect(f.win.stats.layer_builds > builds);
    const far = runs(&f.comp);
    try testing.expect(far[0] > 5 and far[0] < 40);
    try testing.expect(far[1] <= 3040 and far[2] >= 3140);
}

test "opacity animates as a layer property; content repaints only its layer" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 200 });
    defer f.deinit();
    var t = try f.win.begin();
    const col = try box(t, .root, .box, .{});
    const a = try box(t, col, .box, .{ .height = .{ .px = 50 } });
    try t.setVisual(a, .{ .background = .black });
    const faded = try box(t, col, .box, .{ .height = .{ .px = 50 } });
    try t.setVisual(faded, .{ .background = .white, .opacity = 0.5 });
    const after = try box(t, col, .box, .{ .height = .{ .px = 50 } });
    try t.setVisual(after, .{ .background = .black });
    t.commit();
    f.comp.keep_log = true;
    try f.frame();
    // Root, the faded node's layer, and a chunk for what follows it.
    try testing.expectEqual(@as(usize, 3), f.comp.count());
    const fl = f.win.state(faded).own_layer + 1;
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ fl, f.win.state(after).layer + 1 }, f.comp.children(f.comp.tree.root, &buf));
    try testing.expectEqual(@as(f32, 50), f.comp.get(fl).transform.translate.y);
    try testing.expectEqual(@as(f32, 0.5), f.comp.get(fl).opacity);

    // Opacity change: one op, no content.
    f.comp.log.clearRetainingCapacity();
    t = try f.win.begin();
    try t.setVisual(faded, .{ .background = .white, .opacity = 0.25 });
    t.commit();
    try f.frame();
    try testing.expectEqual(@as(usize, 1), f.comp.log.items.len);
    try testing.expectEqual(@as(f32, 0.25), f.comp.log.items[0].set_opacity.opacity);

    // Background of the first box: only the root layer repaints, with the
    // box as damage.
    f.comp.log.clearRetainingCapacity();
    t = try f.win.begin();
    try t.setVisual(a, .{ .background = .white });
    t.commit();
    try f.frame();
    try testing.expectEqual(@as(usize, 1), f.comp.log.items.len);
    const sc = f.comp.log.items[0].set_content;
    try testing.expectEqual(f.comp.tree.root, sc.layer);
    try testing.expect(sc.damage.?.eql(.xywh(0, 0, 200, 50)));
}

fn countActivate(user: ?*anyopaque, _: *ui.Window, _: NodeId, ev: *const ui.Event) ui.HandlerResult {
    const n: *usize = @ptrCast(@alignCast(user));
    if (ev.* == .activate) n.* += 1;
    return .handled;
}

test "pointer presses activate; Tab moves focus; Enter activates" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 100 });
    defer f.deinit();
    var clicks: [2]usize = .{ 0, 0 };
    var t = try f.win.begin();
    const row = try box(t, .root, .flex, .{});
    try t.setFlex(row, .{ .align_items = .start });
    var buttons: [2]NodeId = undefined;
    for (&buttons, &clicks, 0..) |*b, *c, i| {
        b.* = try box(t, row, .box, .{ .padding = .all(4) });
        try t.setSemantics(b.*, .{ .role = .button, .focusable = true });
        try t.on(b.*, .activate, .{ .func = countActivate, .user = c });
        const label = try t.create(b.*, .text, .none);
        try t.setText(label, if (i == 0) "OK" else "Cancel");
    }
    t.commit();
    try f.frame();

    // Press and release over the label inside the first button.
    const r = f.win.windowRect(buttons[0]);
    const p: [2]f64 = .{ r.x0 + 8, r.y0 + 8 };
    try testing.expectEqual(f.win.node(buttons[0]).first, ui.input.hitTest(f.win, .{ .x = @floatCast(p[0]), .y = @floatCast(p[1]) }));
    f.win.handlePlatform(&.{ .pointer_motion = .{ .window = 0, .seat = 0, .x = p[0], .y = p[1] } });
    f.win.handlePlatform(&.{ .pointer_button = .{ .window = 0, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } });
    try testing.expectEqual(buttons[0], f.win.input.focus);
    try testing.expect(!f.win.input.focus_visible);
    f.win.handlePlatform(&.{ .pointer_button = .{ .window = 0, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } });
    try testing.expectEqual(@as(usize, 1), clicks[0]);

    // Released elsewhere: no activation.
    f.win.handlePlatform(&.{ .pointer_button = .{ .window = 0, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 3 } });
    f.win.handlePlatform(&.{ .pointer_motion = .{ .window = 0, .seat = 0, .x = 190, .y = 90 } });
    f.win.handlePlatform(&.{ .pointer_button = .{ .window = 0, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 4 } });
    try testing.expectEqual(@as(usize, 1), clicks[0]);

    // Keyboard: Tab to the second button, Enter activates it.
    const tab: @import("platform").Key = .{ .window = 0, .seat = 0, .keycode = 23, .keysym = ui.keysym.tab, .state = .pressed, .mods = .{}, .time = 0, .serial = 5 };
    f.win.handlePlatform(&.{ .key = tab });
    try testing.expectEqual(buttons[1], f.win.input.focus);
    try testing.expect(f.win.input.focus_visible);
    var enter = tab;
    enter.keysym = ui.keysym.@"return";
    f.win.handlePlatform(&.{ .key = enter });
    try testing.expectEqual(@as(usize, 1), clicks[1]);
    // Shift+Tab wraps backwards; Tab again wraps forwards.
    var back = tab;
    back.mods.shift = true;
    f.win.handlePlatform(&.{ .key = back });
    try testing.expectEqual(buttons[0], f.win.input.focus);
    f.win.handlePlatform(&.{ .key = back });
    try testing.expectEqual(buttons[1], f.win.input.focus);

    // Disabling the focused button drops focus at commit.
    t = try f.win.begin();
    try t.setSemantics(buttons[1], .{ .role = .button, .focusable = true, .disabled = true });
    t.commit();
    try testing.expectEqual(NodeId.none, f.win.input.focus);
    try f.frame();
}

test "semantics: roles, names from content, states, and pruning" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 100 });
    defer f.deinit();
    const t = try f.win.begin();
    const group = try box(t, .root, .flex, .{}); // generic: pruned
    const button = try box(t, group, .box, .{});
    try t.setSemantics(button, .{ .role = .button, .focusable = true, .pressed = .on });
    const inner = try box(t, button, .flex, .{});
    const a = try t.create(inner, .text, .none);
    try t.setText(a, "Save");
    const b = try t.create(inner, .text, .none);
    try t.setText(b, "file");
    const deco = try t.create(group, .text, .none);
    try t.setText(deco, "decoration");
    try t.setSemantics(deco, .{ .role = .none });
    const labelled = try box(t, group, .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    try t.setSemantics(labelled, .{ .role = .image, .label = "Logo" });
    t.commit();
    try f.frame();

    const sem = &f.win.semantics;
    const window = sem.nodes.items[0];
    try testing.expectEqual(ui.Role.window, window.role);
    var top = sem.children(0);
    const bi = top.next().?;
    const btn = sem.nodes.items[bi];
    try testing.expectEqual(ui.Role.button, btn.role);
    try testing.expectEqualStrings("Save file", sem.name(btn));
    try testing.expectEqual(ui.Toggle.on, btn.pressed);
    try testing.expect(btn.focusable and !btn.focused);
    // The button's labels are its children; the decoration is gone.
    var kids = sem.children(bi);
    try testing.expectEqualStrings("Save", sem.name(sem.nodes.items[kids.next().?]));
    try testing.expectEqualStrings("file", sem.name(sem.nodes.items[kids.next().?]));
    try testing.expectEqual(null, kids.next());
    const logo = sem.nodes.items[top.next().?];
    try testing.expectEqual(ui.Role.image, logo.role);
    try testing.expectEqualStrings("Logo", sem.name(logo));
    try testing.expectEqual(null, top.next());
    try testing.expect(sem.find(.label, "decoration") == null);
    try testing.expectEqual(f.win.windowRect(button).x0, sem.find(.button, "Save file").?.bounds.x0);
}

fn takeScroll(user: ?*anyopaque, _: *ui.Window, _: NodeId, ev: *const ui.Event) ui.HandlerResult {
    const total: *f32 = @ptrCast(@alignCast(user));
    if (ev.* != .scroll) return .pass;
    // Takes upward scrolling only; passes the rest on.
    if (ev.scroll.dy >= 0) return .pass;
    total.* += ev.scroll.dy;
    return .handled;
}

test "scroll handlers get wheel regions; declined input passes on as scroll_by" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 100, .height = 100 });
    defer f.deinit();
    var taken: f32 = 0;
    const t = try f.win.begin();
    const sc = try box(t, .root, .scroll, .{});
    const content = try box(t, sc, .box, .{ .height = .{ .px = 400 } });
    const knob = try box(t, content, .box, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } });
    try t.on(knob, .scroll, .{ .func = takeScroll, .user = &taken });
    t.commit();
    try f.frame();
    // The knob has its own layer with a wheel region over its box.
    const kl = f.comp.get(f.win.state(knob).own_layer + 1);
    try testing.expect(kl.wheel.?.eql(.xywh(0, 0, 20, 20)));
    try testing.expectEqual(compositor.Route.ui, f.comp.tree.routeScroll(.{ .x = 10, .y = 10 }, .{ .x = 0, .y = 40 }, .{}));
    const sl = f.win.state(sc).own_layer + 1;
    try testing.expectEqual(sl, f.comp.tree.routeScroll(.{ .x = 50, .y = 50 }, .{ .x = 0, .y = 40 }, .{}).scroll);
    try testing.expectEqual(compositor.Route.ui, f.comp.tree.routeScroll(.{ .x = 50, .y = 50 }, .{ .x = 0, .y = 40 }, .{ .ctrl = true }));

    // Over the knob: up is the handler's...
    f.win.handlePlatform(&.{ .pointer_motion = .{ .window = 0, .seat = 0, .x = 10, .y = 10 } });
    f.win.handlePlatform(&.{ .scroll = .{ .window = 0, .seat = 0, .dy = -10 } });
    try testing.expectEqual(@as(f32, -10), taken);
    // ...down passes on to the scroll node as scroll_by.
    f.win.handlePlatform(&.{ .scroll = .{ .window = 0, .seat = 0, .dy = 40 } });
    try f.frame();
    try testing.expectEqual(@as(f32, 40), f.comp.get(sl).offset.y);
    try testing.expectEqual(@as(f32, 40), f.win.node(sc).data.scroll.offset.y);
    // Ctrl+wheel that no handler takes goes nowhere.
    f.win.handlePlatform(&.{ .modifiers = .{ .window = 0, .seat = 0, .mods = .{ .ctrl = true } } });
    f.win.handlePlatform(&.{ .scroll = .{ .window = 0, .seat = 0, .dy = 40 } });
    try f.frame();
    try testing.expectEqual(@as(f32, 40), f.comp.get(sl).offset.y);
}

test "configures are acknowledged by the commit with their layout" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 100, .height = 100 });
    defer f.deinit();
    try f.frame();
    var state: @import("platform").WindowState = .{ .width = 150, .height = 80 };
    try f.win.handleEvent(&.{ .configure = .{ .window = 0, .state = state, .serial = 7 } });
    try testing.expectEqual(@as(u64, 0), f.comp.tree.acked_configure);
    try f.frame();
    try testing.expectEqual(@as(u64, 7), f.comp.tree.acked_configure);
    try testing.expectEqual([4]f32{ 0, 0, 150, 80 }, f.rect(.root));
    // A configure that changes nothing is still acknowledged.
    try f.win.handleEvent(&.{ .configure = .{ .window = 0, .state = state, .serial = 8 } });
    try f.frame();
    try testing.expectEqual(@as(u64, 8), f.comp.tree.acked_configure);
    state.scale = .int(2);
    try f.win.handleEvent(&.{ .configure = .{ .window = 0, .state = state, .serial = 9 } });
    try f.frame();
    try testing.expectEqual(@as(u64, 9), f.comp.tree.acked_configure);
    try testing.expectEqual(@as(f32, 2), f.win.scale);
}

const Keys = struct {
    f: *Fixture,
    fn press(k: Keys, sym: u32, mods: @import("platform").Mods) void {
        k.f.win.handlePlatform(&.{ .key = .{ .window = 0, .seat = 0, .keycode = 0, .keysym = sym, .state = .pressed, .mods = mods, .time = 0, .serial = 0 } });
    }
    fn typeText(k: Keys, str: []const u8) void {
        var ev: @import("platform").Key = .{ .window = 0, .seat = 0, .keycode = 0, .keysym = 0x20, .state = .pressed, .mods = .{}, .time = 0, .serial = 0 };
        @memcpy(ev.text_buf[0..str.len], str);
        ev.text_len = @intCast(str.len);
        k.f.win.handlePlatform(&.{ .key = ev });
    }
};

fn countChange(user: ?*anyopaque, _: *ui.Window, _: NodeId, ev: *const ui.Event) ui.HandlerResult {
    const n: *usize = @ptrCast(@alignCast(user));
    if (ev.* == .change) n.* += 1;
    return .handled;
}

test "editor: typing, deleting, selecting, and change events" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 100 });
    defer f.deinit();
    var changes: usize = 0;
    var t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .padding = .all(4), .align_y = .start });
    try t.on(ed, .change, .{ .func = countChange, .user = &changes });
    t.commit();
    try f.frame();
    // Editors are focusable without asking, and an empty one has a line.
    try testing.expect(f.rect(ed)[3] > 8 + 10);
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    try testing.expectEqual(ed, f.win.input.focus);

    k.typeText("hello");
    k.typeText(" world");
    try f.frame();
    const e = &f.win.node(ed).data.editor;
    try testing.expectEqualStrings("hello world", e.text.content);
    try testing.expectEqual(@as(u32, 11), e.caret);
    try testing.expectEqual(@as(usize, 2), changes);

    // Ctrl+Backspace deletes a word; Backspace a grapheme.
    k.press(0xff08, .{ .ctrl = true });
    try testing.expectEqualStrings("hello ", e.text.content);
    k.press(0xff08, .{});
    try testing.expectEqualStrings("hello", e.text.content);
    // Shift+Left twice selects "lo"; typing replaces it.
    k.press(ui.keysym.left, .{ .shift = true });
    k.press(ui.keysym.left, .{ .shift = true });
    try testing.expectEqual(@as(u32, 3), e.caret);
    try testing.expectEqual(@as(u32, 5), e.anchor);
    k.typeText("p!");
    try testing.expectEqualStrings("help!", e.text.content);
    // Ctrl+A then Delete clears; single-line editors ignore Enter.
    k.press('a', .{ .ctrl = true });
    k.press(0xffff, .{});
    try testing.expectEqualStrings("", e.text.content);
    k.typeText("a\nb");
    try testing.expectEqualStrings("ab", e.text.content);
    try f.frame();
    try testing.expectEqualStrings("ab", f.win.semantics.find(.text_input, "").?.value_text);
    try testing.expectEqual(@as(?u32, 2), f.win.semantics.find(.text_input, "").?.caret);

    // Input that arrives while the application holds a transaction open
    // is queued, never mixed in or lost, and replays in order at the next
    // frame, including keys that arrive after the transaction ends.
    t = try f.win.begin();
    k.typeText("x");
    k.press(ui.keysym.left, .{});
    k.typeText("y");
    try testing.expectEqualStrings("ab", e.text.content);
    try t.setLayout(ed, .{ .padding = .all(4), .align_y = .start });
    t.abort();
    k.typeText("z");
    try testing.expectEqualStrings("ab", e.text.content);
    try f.frame();
    try testing.expectEqualStrings("abyzx", e.text.content);
    try testing.expectEqual(@as(usize, 0), f.win.pending_input.items.len);

    // A click places the caret: left of the text is offset 0.
    const r = f.win.windowRect(ed);
    f.win.handlePlatform(&.{ .pointer_motion = .{ .window = 0, .seat = 0, .x = r.x0 + 4, .y = r.y0 + 8 } });
    f.win.handlePlatform(&.{ .pointer_button = .{ .window = 0, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 1 } });
    f.win.handlePlatform(&.{ .pointer_button = .{ .window = 0, .seat = 0, .button = 0x110, .pressed = false, .time = 0, .serial = 2 } });
    try testing.expectEqual(@as(u32, 0), e.caret);
    try f.frame();
}

test "editor: visual movement through right-to-left text; multiline lines" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 200 });
    defer f.deinit();
    const t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start });
    try t.setEditor(ed, .{ .multiline = true });
    try t.setText(ed, "ab \u{05d0}\u{05d1}");
    try t.setSelection(ed, 3, 3, .downstream); // before the Hebrew
    t.commit();
    try f.frame();
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    const e = &f.win.node(ed).data.editor;
    // Right moves visually: into the RTL run from its right edge... the
    // Hebrew is displayed right to left, so after offset 3 (its logical
    // start, at its right edge) Right reaches the end of the line.
    k.press(ui.keysym.right, .{});
    const after_right = e.caret;
    k.press(ui.keysym.left, .{});
    try testing.expect(e.caret != after_right);
    // End goes to the line's right edge, which in this left-to-right line
    // is the logical start of the Hebrew run; Ctrl+End to the text's end.
    k.press(ui.keysym.end, .{});
    try testing.expectEqual(@as(u32, 3), e.caret);
    k.press(ui.keysym.home, .{});
    try testing.expectEqual(@as(u32, 0), e.caret);
    // Enter splits lines; Down and Up move between them.
    k.press(ui.keysym.end, .{ .ctrl = true });
    try testing.expectEqual(@as(u32, 7), e.caret);
    k.press(ui.keysym.@"return", .{});
    k.typeText("cd");
    try testing.expectEqualStrings("ab \u{05d0}\u{05d1}\ncd", e.text.content);
    try f.frame();
    const one_line = f.rect(ed)[3];
    k.press(ui.keysym.up, .{});
    try testing.expect(e.caret <= 7);
    k.press(ui.keysym.down, .{});
    try testing.expect(e.caret >= 8);
    try f.frame();
    try testing.expectEqual(one_line, f.rect(ed)[3]);
}

test "editor: undo and redo merge typing and deleting; app edits reset history" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 100 });
    defer f.deinit();
    var t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start });
    t.commit();
    try f.frame();
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    const e = &f.win.node(ed).data.editor;
    for ([_][]const u8{ "o", "n", "e", " ", "t", "w", "o" }) |c| k.typeText(c);
    try testing.expectEqualStrings("one two", e.text.content);
    // Typing is one step per word (a space starts the next one).
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("one", e.text.content);
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("", e.text.content);
    k.press('z', .{ .ctrl = true, .shift = true });
    try testing.expectEqualStrings("one", e.text.content);
    k.press('y', .{ .ctrl = true });
    try testing.expectEqualStrings("one two", e.text.content);
    // Backspaces merge; undo restores them and the caret.
    k.press(0xff08, .{});
    k.press(0xff08, .{});
    try testing.expectEqualStrings("one t", e.text.content);
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("one two", e.text.content);
    try testing.expectEqual(@as(u32, 7), e.caret);
    // A selection replaced by typing undoes to the selection.
    k.press(ui.keysym.left, .{ .shift = true, .ctrl = true });
    k.typeText("2");
    try testing.expectEqualStrings("one 2", e.text.content);
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("one two", e.text.content);
    try testing.expectEqual(@as(u32, 4), e.caret);
    try testing.expectEqual(@as(u32, 7), e.anchor);
    // Text the application sets is not the user's to undo.
    t = try f.win.begin();
    try t.setText(ed, "replaced");
    t.commit();
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("replaced", e.text.content);
    try f.frame();
}

test "styled text: spans shape as runs, follow edits, format as undo steps, and set the typing style" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 100 });
    defer f.deinit();
    var t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start });
    try t.setText(ed, "one two");
    const bold: ui.SpanStyle = .{ .weight = .bold };
    try t.setSpans(ed, &.{.{ .start = 4, .end = 7, .style = bold }});
    // Not at a character boundary, overlapping, or out of order: refused.
    try testing.expectError(error.InvalidArgument, t.setSpans(ed, &.{.{ .start = 4, .end = 9, .style = bold }}));
    try testing.expectError(error.InvalidArgument, t.setSpans(ed, &.{ .{ .start = 4, .end = 6, .style = bold }, .{ .start = 5, .end = 7, .style = bold } }));
    t.commit();
    try f.frame();
    const e = &f.win.node(ed).data.editor;
    const shaped = struct {
        fn sizes(fx: *Fixture, id: NodeId) ![]const text.Style {
            _ = try text_node.layoutFor(fx.win, id, null);
            return fx.win.state(id).text.?.paragraph.?.blocks[0].paragraph.styles;
        }
    };
    // The bold word is a style run of its own.
    try testing.expectEqual(@as(usize, 2), (try shaped.sizes(&f, ed)).len);
    try testing.expectEqual(bold, f.win.state(ed).text.?.runStyle(1));

    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    k.press(ui.keysym.end, .{});
    // Typed text takes the style of the character before it.
    k.typeText("s");
    try testing.expectEqualStrings("one twos", e.text.content);
    try testing.expectEqualDeep(&[_]ui.Span{.{ .start = 4, .end = 8, .style = bold }}, e.text.spans);
    // Underline "one": a step of its own that undo and redo replay.
    k.press(ui.keysym.home, .{});
    k.press(ui.keysym.right, .{ .shift = true, .ctrl = true });
    try testing.expect(ui.access.format(f.win, ed, .{ .underline = true }, .{ .underline = true }));
    const formatted = [_]ui.Span{ .{ .start = 0, .end = 3, .style = .{ .underline = true } }, .{ .start = 4, .end = 8, .style = bold } };
    try testing.expectEqualDeep(&formatted, e.text.spans);
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualDeep(&[_]ui.Span{.{ .start = 4, .end = 8, .style = bold }}, e.text.spans);
    try testing.expectEqual(@as(u32, 3), @max(e.caret, e.anchor)); // selection back
    k.press('z', .{ .ctrl = true, .shift = true });
    try testing.expectEqualDeep(&formatted, e.text.spans);
    // Undoing the typing takes its span part back too.
    k.press('z', .{ .ctrl = true });
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("one two", e.text.content);
    try testing.expectEqualDeep(&[_]ui.Span{.{ .start = 4, .end = 7, .style = bold }}, e.text.spans);

    // With nothing selected, formatting sets the typing style, which the
    // next typed text takes and a caret move forgets.
    k.press(ui.keysym.home, .{});
    try testing.expect(ui.access.format(f.win, ed, .{ .slant = .italic }, .{ .slant = true }));
    try testing.expectEqual(ui.SpanStyle{ .slant = .italic }, ui.access.typingStyle(f.win, ed));
    k.typeText("A");
    k.typeText("B");
    try testing.expectEqualDeep(&[_]ui.Span{ .{ .start = 0, .end = 2, .style = .{ .slant = .italic } }, .{ .start = 6, .end = 9, .style = bold } }, e.text.spans);
    try testing.expect(ui.access.format(f.win, ed, .{}, .{ .slant = true }));
    k.press(ui.keysym.end, .{});
    try testing.expectEqual(bold, ui.access.typingStyle(f.win, ed));
    try f.frame();
    // Text the application sets drops the spans.
    t = try f.win.begin();
    try t.setText(ed, "plain");
    t.commit();
    try testing.expectEqual(@as(usize, 0), e.text.spans.len);
    try f.frame();
}

test "paragraph styles: whole paragraphs, laid out, kept through edits and undo" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 200 });
    defer f.deinit();
    var t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start, .width = .{ .px = 300 } });
    try t.setEditor(ed, .{ .multiline = true });
    try t.setText(ed, "first\nsecond\nthird");
    const centered: ui.ParagraphPatch = .{ .alignment = .center };
    // A range from the start of "second" styles all of it, separator
    // included; paragraphs take the style at their first character.
    try t.setParagraphSpans(ed, &.{ .{ .start = 6, .end = 9, .style = centered }, .{ .start = 15, .end = 16, .style = .{ .tab_width = 9 } } });
    try testing.expectError(error.InvalidArgument, t.setParagraphSpans(ed, &.{.{ .start = 0, .end = 2, .style = .{ .spacing = .{ .line_spacing = 0 } } }}));
    try testing.expectError(error.InvalidArgument, t.setParagraphSpans(ed, &.{.{ .start = 0, .end = 2, .style = .{ .indent = .{ .start = -1 } } }}));
    t.commit();
    const e = &f.win.node(ed).data.editor;
    try testing.expectEqualDeep(&[_]ui.ParagraphSpan{.{ .start = 6, .end = 13, .style = centered }}, e.text.paragraphs);
    try f.frame();
    // The second line is centered in the node, the others at the start.
    const l = text_node.current(f.win, ed).?;
    try testing.expectEqual(3, l.lineCount());
    try testing.expectEqual(text.layout.Alignment.center, l.line(1).alignment.?);
    const second = l.line(1);
    try testing.expectApproxEqAbs((300 - second.width) / 2, second.contentX() + text_node.lineShift(f.win, ed, second, 300), 0.01);
    try testing.expectApproxEqAbs(0, l.line(0).contentX() + text_node.lineShift(f.win, ed, l.line(0), 300), 0.01);

    // A line break inside the centered paragraph starts another centered
    // one; text typed at the start of "third" stays in "third".
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    t = try f.win.begin();
    try t.setSelection(ed, 9, 9, .downstream);
    t.commit();
    k.press(ui.keysym.@"return", .{});
    try testing.expectEqualStrings("first\nsec\nond\nthird", e.text.content);
    try testing.expectEqualDeep(&[_]ui.ParagraphSpan{.{ .start = 6, .end = 14, .style = centered }}, e.text.paragraphs);
    // Undo restores the paragraphs with the text.
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("first\nsecond\nthird", e.text.content);
    try testing.expectEqualDeep(&[_]ui.ParagraphSpan{.{ .start = 6, .end = 13, .style = centered }}, e.text.paragraphs);
    // Joining "second" to "first" makes one paragraph in first's style.
    t = try f.win.begin();
    try t.setSelection(ed, 6, 6, .downstream);
    t.commit();
    k.press(0xff08, .{}); // BackSpace
    try testing.expectEqualStrings("firstsecond\nthird", e.text.content);
    try testing.expectEqual(0, e.text.paragraphs.len);
    k.press('z', .{ .ctrl = true });

    // A paragraph command over a selection from "first" into "second"
    // indents both, as one undo step.
    t = try f.win.begin();
    try t.setSelection(ed, 2, 8, .downstream);
    t.commit();
    const indent: ui.ParagraphPatch = .{ .indent = .{ .start = 20 } };
    try testing.expect(ui.access.formatParagraph(f.win, ed, indent, .{ .indent = true }));
    try testing.expectEqualDeep(&[_]ui.ParagraphSpan{
        .{ .start = 0, .end = 6, .style = indent },
        .{ .start = 6, .end = 13, .style = .{ .alignment = .center, .indent = .{ .start = 20 } } },
    }, e.text.paragraphs);
    try testing.expectEqual(ui.ParagraphPatch{ .alignment = .center, .indent = .{ .start = 20 } }, ui.access.paragraphRun(f.win, ed, 7).?.style);
    try f.frame();
    try testing.expectEqual(20, text_node.current(f.win, ed).?.line(0).indent_start);
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualDeep(&[_]ui.ParagraphSpan{.{ .start = 6, .end = 13, .style = centered }}, e.text.paragraphs);

    // Text the application sets drops them.
    t = try f.win.begin();
    try t.setText(ed, "plain");
    t.commit();
    try testing.expectEqual(0, e.text.paragraphs.len);
    try f.frame();
}

test "a span's family shapes its run with that family" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.fonts.addFont("", text.font.test_fonts.siv_regular);
    const siv = try f.fonts.intern("SivTest");
    var t = try f.win.begin();
    const label = try box(t, .root, .text, .{});
    try t.setText(label, "Hello HIO");
    try t.setSpans(label, &.{.{ .start = 6, .end = 9, .style = .{ .family = siv } }});
    t.commit();
    try f.frame();
    const p = f.win.state(label).text.?.paragraph.?.blocks[0].paragraph;
    try testing.expectEqual(2, p.runs.len);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Droid Sans", f.fonts.cache.face(p.runs[0].font).?.familyName(&buf));
    try testing.expectEqualStrings("SivTest", f.fonts.cache.face(p.runs[1].font).?.familyName(&buf));
}

test "masked editor: locked secret, bullets, no undo, nothing for assistive technology" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 100 });
    defer f.deinit();
    var t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start });
    try t.setText(ed, "pre");
    try t.setEditor(ed, .{ .masked = true });
    try t.setSemantics(ed, .{ .label = "Password" });
    t.commit();
    try f.frame();
    const e = &f.win.node(ed).data.editor;
    try testing.expectEqualStrings("pre", f.win.secretOf(ed));
    try testing.expectEqualStrings("\u{2022}\u{2022}\u{2022}", e.text.content);
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    k.typeText("\u{e9}!");
    k.press(ui.keysym.left, .{});
    k.press(0xff08, .{}); // removes the é
    try testing.expectEqualStrings("pre!", f.win.secretOf(ed));
    try testing.expectEqual(@as(usize, 4 * 3), e.text.content.len);
    // The secret sits at the start of its own page (locked, not in the heap).
    try testing.expectEqual(@as(usize, 0), @intFromPtr(f.win.secretOf(ed).ptr) % std.heap.page_size_min);
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("pre!", f.win.secretOf(ed));
    try f.frame();
    const sem = f.win.semantics.find(.text_input, "Password").?;
    try testing.expect(sem.masked);
    try testing.expectEqualStrings("", sem.value_text);
    try testing.expectEqual(@as(?u32, null), sem.caret);
    // Unmasking moves the text back to ordinary memory.
    t = try f.win.begin();
    try t.setEditor(ed, .{});
    t.commit();
    try testing.expectEqualStrings("pre!", e.text.content);
    try testing.expectEqual(@as(usize, 0), f.win.secretOf(ed).len);
    try f.frame();
}

test "caret blinks on the compositor, stops by itself, and not with reduced motion" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 100 });
    defer f.deinit();
    const t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start });
    t.commit();
    try f.frame();
    f.comp.keep_log = true;
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    try f.frame();
    // Focus gives the editor a layer with the caret in a child layer.
    const caret = f.win.state(ed).content_layer + 1;
    try testing.expectEqual(f.win.state(ed).own_layer + 1, f.comp.get(caret).parent);
    const a = findAnimate(f.comp.log.items, caret).?;
    try testing.expectEqual(@as(f32, 0), a.to.opacity);
    try testing.expect(a.iterations != 0 and a.iterations % 2 == 0 and a.alternate); // ends visible
    // Typing moves the caret (a transform) and restarts the blink; the
    // editor's text layer repaints, the caret's content does not.
    f.comp.log.clearRetainingCapacity();
    k.typeText("a");
    try f.frame();
    try testing.expect(findAnimate(f.comp.log.items, caret) != null);
    for (f.comp.log.items) |op| if (op == .set_content) try testing.expect(op.set_content.layer != caret);
    // Idle: a frame with nothing new sends nothing, and nothing asks for one.
    f.comp.log.clearRetainingCapacity();
    const requested = f.frames_requested;
    try f.frame();
    try testing.expectEqual(@as(usize, 0), f.comp.log.items.len);
    try testing.expectEqual(requested, f.frames_requested);
    try testing.expect(!f.win.needsFrame());
    // Reduced motion: the running blink is cancelled and none starts.
    f.win.setDesktop(.{ .reduced_motion = true });
    try f.frame();
    try testing.expect(findAnimate(f.comp.log.items, caret) == null);
    try testing.expectEqual(@as(f32, 1), f.comp.log.items[0].set_opacity.opacity);
    f.comp.log.clearRetainingCapacity();
    k.typeText("b");
    try f.frame();
    try testing.expect(findAnimate(f.comp.log.items, caret) == null);
}

fn findAnimate(ops: []const compositor.Op, layer: compositor.LayerId) ?compositor.Animation {
    for (ops) |op| if (op == .animate and op.animate.layer == layer) return op.animate.animation;
    return null;
}

fn imeEvent(f: *Fixture, ev: @import("platform").TextInput) void {
    f.win.handlePlatform(&.{ .text_input = ev });
}

fn imeText(buf: []u8, s: []const u8) u16 {
    @memcpy(buf[0..s.len], s);
    return @intCast(s.len);
}

test "input method: enable, preedit inline, commit with undo, masked fields stay out" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 100 });
    defer f.deinit();
    var t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start });
    const pw = try box(t, .root, .editor, .{ .align_y = .end });
    try t.setEditor(pw, .{ .masked = true });
    t.commit();
    try f.frame();
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    try f.frame();
    // No text input has entered the window: nothing is sent.
    try testing.expectEqual(@as(usize, 0), f.text_inputs.items.len);
    f.win.handlePlatform(&.{ .text_input_enter = .{ .window = 0, .seat = 0, .serial = 0 } });
    try f.frame();
    try testing.expectEqual(@as(usize, 1), f.text_inputs.items.len);
    const first = f.text_inputs.items[0];
    try testing.expect(first.enabled);
    try testing.expectEqualStrings("", first.surrounding);
    try testing.expect(first.cursor_rect.height > 10);

    // A preedit shows inline but is not text.
    var ev: @import("platform").TextInput = .{ .window = 0, .seat = 0 };
    ev.preedit_len = imeText(&ev.preedit_buf, "ka");
    ev.cursor_begin = 2;
    ev.cursor_end = 2;
    imeEvent(&f, ev);
    try f.frame();
    const e = &f.win.node(ed).data.editor;
    try testing.expectEqualStrings("", e.text.content);
    try testing.expectEqualStrings("ka", f.win.state(ed).text.?.paragraph.?.blocks[0].paragraph.text);
    const moved = f.text_inputs.items[f.text_inputs.items.len - 1];
    try testing.expect(moved.cursor_rect.x > first.cursor_rect.x);
    // Editing keys wait while it composes.
    k.typeText("q");
    try testing.expectEqualStrings("", e.text.content);

    // The commit replaces the preedit and becomes text and an undo step.
    ev = .{ .window = 0, .seat = 0 };
    ev.commit_len = imeText(&ev.commit_buf, "\u{304b}");
    imeEvent(&f, ev);
    try f.frame();
    try testing.expectEqualStrings("\u{304b}", e.text.content);
    try testing.expectEqualStrings("\u{304b}", f.win.state(ed).text.?.paragraph.?.blocks[0].paragraph.text);
    const after = f.text_inputs.items[f.text_inputs.items.len - 1];
    try testing.expectEqualStrings("\u{304b}", after.surrounding);
    try testing.expectEqual(@as(u32, 3), after.cursor);
    try testing.expect(after.from_input_method);
    // Surrounding deletion with the caret at the end: one byte back, then
    // the commit.
    k.typeText("ab");
    ev = .{ .window = 0, .seat = 0, .delete_before = 1 };
    ev.commit_len = imeText(&ev.commit_buf, "Z");
    imeEvent(&f, ev);
    try testing.expectEqualStrings("\u{304b}aZ", e.text.content);
    // Undo: the replacement, then the commit and the typing after it,
    // which merge into one step like typing.
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("\u{304b}ab", e.text.content);
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("", e.text.content);

    // A masked field turns the input method off; input methods never see
    // passwords.
    k.press(ui.keysym.tab, .{});
    try testing.expectEqual(pw, f.win.input.focus);
    try f.frame();
    const off = f.text_inputs.items[f.text_inputs.items.len - 1];
    try testing.expect(!off.enabled);
    try testing.expectEqualStrings("", off.surrounding);
    ev = .{ .window = 0, .seat = 0 };
    ev.commit_len = imeText(&ev.commit_buf, "leak");
    imeEvent(&f, ev);
    try testing.expectEqualStrings("", f.win.secretOf(pw));
    // After the text input leaves, nothing more is sent.
    const sent = f.text_inputs.items.len;
    f.win.handlePlatform(&.{ .text_input_leave = .{ .window = 0, .seat = 0, .serial = 0 } });
    k.press(ui.keysym.tab, .{});
    try f.frame();
    try testing.expectEqual(sent, f.text_inputs.items.len);
}

test "editor: double click selects a word, triple a paragraph, dragging extends by them" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 400, .height = 100 });
    defer f.deinit();
    const t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start });
    try t.setEditor(ed, .{ .multiline = true });
    try t.setText(ed, "hello brave new world\nsecond line");
    t.commit();
    try f.frame();
    const e = &f.win.node(ed).data.editor;
    const l = @import("text_node.zig").current(f.win, ed).?;
    const line0 = l.line(0);
    // The middle of "brave" and of "world" on the first line.
    const bx = line0.x + (l.caret(.{ .offset = 6 }).x + l.caret(.{ .offset = 11 }).x) / 2;
    const wx = (l.caret(.{ .offset = 16 }).x + l.caret(.{ .offset = 21 }).x) / 2;
    const y = line0.top + line0.height / 2;
    const P = struct {
        fn press(fx: *Fixture, x: f32, yy: f32, time: u32, down: bool) void {
            fx.win.handlePlatform(&.{ .pointer_motion = .{ .window = 0, .seat = 0, .x = x, .y = yy } });
            fx.win.handlePlatform(&.{ .pointer_button = .{ .window = 0, .seat = 0, .button = 0x110, .pressed = down, .time = time, .serial = 0 } });
        }
    };
    P.press(&f, bx, y, 1000, true);
    P.press(&f, bx, y, 1010, false);
    try testing.expectEqual(e.caret, e.anchor);
    P.press(&f, bx, y, 1100, true);
    try testing.expectEqual(@as(u32, 6), @min(e.caret, e.anchor));
    try testing.expectEqual(@as(u32, 11), @max(e.caret, e.anchor));
    // Dragging to "world" extends by whole words.
    f.win.handlePlatform(&.{ .pointer_motion = .{ .window = 0, .seat = 0, .x = wx, .y = y } });
    try testing.expectEqual(@as(u32, 6), e.anchor);
    try testing.expectEqual(@as(u32, 21), e.caret);
    P.press(&f, wx, y, 1150, false);
    // A third press in time (back where the clicks started) selects the paragraph.
    P.press(&f, bx, y, 1200, true);
    P.press(&f, bx, y, 1210, false);
    try testing.expectEqual(@as(u32, 0), e.anchor);
    try testing.expectEqual(@as(u32, 21), e.caret);
    // Too late for a multi-click: back to a caret.
    P.press(&f, bx, y, 2000, true);
    P.press(&f, bx, y, 2010, false);
    try testing.expectEqual(e.caret, e.anchor);
    // A slower desktop double-click time makes the same gap a double click.
    f.win.setDesktop(.{ .double_click_ms = 1000 });
    P.press(&f, bx, y, 2600, true);
    try testing.expectEqual(@as(u32, 6), @min(e.caret, e.anchor));
    try testing.expectEqual(@as(u32, 11), @max(e.caret, e.anchor));
}

test "desktop settings: blink timing, text scale, and the accent color" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 100 });
    defer f.deinit();
    const t = try f.win.begin();
    const col = try box(t, .root, .flex, .{});
    try t.setFlex(col, .{ .axis = .column, .align_items = .start });
    const ed = try box(t, col, .editor, .{});
    try t.setText(ed, "abc");
    const label = try box(t, col, .text, .{});
    try t.setText(label, "Label");
    t.commit();
    try f.frame();
    f.comp.keep_log = true;
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    try f.frame();
    const caret = f.win.state(ed).content_layer + 1;
    // GTK's defaults: a 1.2 s cycle for 10 s, ending visible.
    var a = findAnimate(f.comp.log.items, caret).?;
    try testing.expectEqual(@as(u64, 600 * std.time.ns_per_ms), a.duration_ns);
    try testing.expectEqual(@as(u32, 16), a.iterations);

    f.comp.log.clearRetainingCapacity();
    f.win.setDesktop(.{ .cursor_blink_ms = 1000, .cursor_blink_timeout_s = 3 });
    try f.frame();
    a = findAnimate(f.comp.log.items, caret).?;
    try testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), a.duration_ns);
    try testing.expectEqual(@as(u32, 6), a.iterations);
    // Blinking off: the caret goes solid and stays.
    f.comp.log.clearRetainingCapacity();
    f.win.setDesktop(.{ .cursor_blink = false });
    try f.frame();
    try testing.expect(findAnimate(f.comp.log.items, caret) == null);
    try testing.expectEqual(@as(f32, 1), f.comp.get(caret).opacity);

    // Text scale reshapes text at the new size and lays it out again.
    const h1 = f.win.windowRect(label).height();
    const shapes = f.win.stats.shapes;
    f.win.setDesktop(.{ .text_scale = 2 });
    try f.frame();
    try testing.expectEqual(shapes + 2, f.win.stats.shapes);
    try testing.expectApproxEqAbs(2 * h1, f.win.windowRect(label).height(), 1);

    // The accent draws the focus ring.
    const accent: [3]f64 = .{ 0.5, 0.25, 0.75 };
    f.win.setDesktop(.{ .accent_color = accent });
    try f.frame();
    const want = scene.Color.srgb(0.5, 0.25, 0.75, 1);
    var found = false;
    for (f.comp.tree.layers.items) |l| {
        if (!l.alive) continue;
        const c = l.content orelse continue;
        for (c.list.commands) |cmd| if (cmd == .stroke and std.meta.eql(cmd.stroke.paint, scene.Paint.color(want))) {
            found = true;
        };
    }
    try testing.expect(found);
}

test "images: the tree and each display list that draws one hold a reference" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const px: [16]u8 = @splat(0xff);
    const img = try ui.Image.create(testing.allocator, .{ .pixels = &px, .width = 2, .height = 2 });
    defer img.release();
    const refs = struct {
        fn of(i: *ui.Image) u32 {
            return i.refs.load(.monotonic);
        }
    }.of;

    // An aborted transaction drops the reference it took.
    var t = try f.win.begin();
    var node = try t.create(.root, .image, .none);
    try t.setImage(node, .{ .image = img });
    try testing.expectEqual(@as(u32, 2), refs(img));
    t.abort();
    try testing.expectEqual(@as(u32, 1), refs(img));

    t = try f.win.begin();
    node = try t.create(.root, .image, .none);
    try t.setImage(node, .{ .image = img });
    // Setting it again in the same transaction keeps one reference.
    try t.setImage(node, .{ .image = img, .fit = .cover });
    t.commit();
    try testing.expectEqual(@as(u32, 2), refs(img));
    try f.win.frame();
    // Painted: the display list on its way to the compositor holds one.
    try testing.expectEqual(@as(u32, 3), refs(img));
    try testing.expect(!f.win.buildersHome());
    _ = try f.comp.tree.compose();
    for (f.comp.tree.endFrame()) |b| try f.win.handleEvent(&.{ .released = b });

    // Removed: the compositor still shows the old list until the next
    // frame replaces it, so the pixels stay until it is released.
    t = try f.win.begin();
    try t.remove(node);
    t.commit();
    try testing.expectEqual(@as(u32, 2), refs(img));
    try f.frame();
    try testing.expectEqual(@as(u32, 1), refs(img));
}

test "access: character rectangles, hit testing, and lines in window coordinates" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 120 });
    defer f.deinit();
    const access = ui.access;
    var t = try f.win.begin();
    const col = try box(t, .root, .flex, .{ .padding = .all(10) });
    try t.setFlex(col, .{ .axis = .column, .align_items = .start, .gap = 4 });
    const latin = try box(t, col, .text, .{});
    try t.setText(latin, "abc");
    const hebrew = try box(t, col, .text, .{});
    try t.setText(hebrew, "\u{5d0}\u{5d1}\u{5d2}");
    const ed = try box(t, col, .editor, .{ .width = .{ .px = 280 } });
    try t.setEditor(ed, .{ .multiline = true });
    try t.setText(ed, "hello\nworld");
    const narrow = try box(t, col, .editor, .{ .width = .{ .px = 60 } });
    try t.setText(narrow, "a long single line that scrolls");
    t.commit();
    try f.frame();

    // Left to right, inside the node, and back from their centers.
    const box_l = f.win.windowRect(latin);
    var prev_x1 = box_l.x0;
    for (0..3) |i| {
        const r = access.characterRect(f.win, latin, @intCast(i)).?;
        try testing.expect(r.width() > 1 and r.x0 >= prev_x1 - 0.01 and r.y0 >= box_l.y0 and r.y1 <= box_l.y1 + 0.01);
        prev_x1 = r.x1;
        const c: raster.Point = .{ .x = r.x0 + r.width() * 0.25, .y = (r.y0 + r.y1) / 2 };
        try testing.expectEqual(@as(?u32, @intCast(i)), access.offsetAt(f.win, latin, c));
    }
    // The end has a zero-width rectangle after the last character.
    const end = access.characterRect(f.win, latin, 3).?;
    try testing.expectEqual(end.x0, end.x1);
    try testing.expectApproxEqAbs(prev_x1, end.x0, 0.01);
    try testing.expect(access.characterRect(f.win, latin, 4) == null);
    // Right to left: the first character is the rightmost.
    const h0 = access.characterRect(f.win, hebrew, 0).?;
    const h1 = access.characterRect(f.win, hebrew, 2).?;
    try testing.expect(h0.x0 >= h1.x1 - 0.01);

    // Lines: with their line break, on the second line, and the end.
    try testing.expectEqual([2]u32{ 0, 6 }, access.lineRange(f.win, ed, 2).?);
    try testing.expectEqual([2]u32{ 6, 11 }, access.lineRange(f.win, ed, 8).?);
    try testing.expectEqual([2]u32{ 6, 11 }, access.lineRange(f.win, ed, 11).?);
    const w = access.characterRect(f.win, ed, 6).?;
    try testing.expect(w.y0 >= access.characterRect(f.win, ed, 0).?.y1 - 0.01);

    // A scrolled editor: the caret at the end is in view, and so is the
    // last character's rectangle.
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    k.press(ui.keysym.tab, .{});
    try testing.expectEqual(narrow, f.win.input.focus);
    k.press(ui.keysym.end, .{});
    try f.frame();
    try testing.expect(f.win.state(narrow).editor_scroll > 0);
    const nb = f.win.windowRect(narrow);
    const len: u32 = @intCast(f.win.node(narrow).data.editor.text.content.len);
    const last = access.characterRect(f.win, narrow, len - 1).?;
    try testing.expect(last.x0 >= nb.x0 and last.x1 <= nb.x1 + 0.01);
    try testing.expect(access.characterRect(f.win, narrow, 0).?.x1 < nb.x0);

    // A preedit is shown but not counted: "b" moves right past it, and a
    // point inside it is where it sits.
    k.press(ui.keysym.tab, .{ .shift = true });
    try testing.expectEqual(ed, f.win.input.focus);
    k.press(ui.keysym.home, .{ .ctrl = true });
    k.press(ui.keysym.right, .{});
    const before = access.characterRect(f.win, ed, 1).?;
    var ev: @import("platform").TextInput = .{ .window = 0, .seat = 0 };
    f.win.handlePlatform(&.{ .text_input_enter = .{ .window = 0, .seat = 0, .serial = 0 } });
    ev.preedit_len = imeText(&ev.preedit_buf, "XYZ");
    imeEvent(&f, ev);
    try f.frame();
    const after = access.characterRect(f.win, ed, 1).?;
    try testing.expect(after.x0 > before.x0 + 10);
    try testing.expectEqual(@as(?u32, 1), access.offsetAt(f.win, ed, .{ .x = (before.x0 + after.x0) / 2, .y = (after.y0 + after.y1) / 2 }));
    try testing.expectEqual([2]u32{ 0, 6 }, access.lineRange(f.win, ed, 1).?);
}

test "access: edits take the user's path, queue behind a transaction, and skip masked fields" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 300, .height = 100 });
    defer f.deinit();
    const access = ui.access;
    var changes: usize = 0;
    var t = try f.win.begin();
    const ed = try box(t, .root, .editor, .{ .align_y = .start });
    try t.setText(ed, "hello world");
    try t.on(ed, .change, .{ .func = countChange, .user = &changes });
    const pw = try box(t, .root, .editor, .{ .align_y = .end });
    try t.setEditor(pw, .{ .masked = true });
    const heading = try box(t, .root, .text, .{});
    try t.setText(heading, "Title");
    try t.setSemantics(heading, .{ .role = .heading, .level = 2 });
    t.commit();
    try f.frame();
    const e = &f.win.node(ed).data.editor;
    const gen = f.win.semantics.generation;

    try access.replaceText(f.win, ed, 6, 11, "there\nfriend");
    try testing.expectEqualStrings("hello there friend", e.text.content);
    try testing.expectEqual(@as(usize, 1), changes);
    try testing.expectEqual(@as(u32, 18), e.caret);
    try access.setSelection(f.win, ed, 0, 5);
    try testing.expectEqual(@as(u32, 0), e.caret);
    try testing.expectEqual(@as(u32, 5), e.anchor);
    // One undo step, like a paste.
    const k: Keys = .{ .f = &f };
    k.press(ui.keysym.tab, .{});
    k.press('z', .{ .ctrl = true });
    try testing.expectEqualStrings("hello world", e.text.content);

    // Behind an application transaction the edit waits, then applies.
    t = try f.win.begin();
    try access.replaceText(f.win, ed, 0, 5, "howdy");
    try testing.expectEqualStrings("hello world", e.text.content);
    t.commit();
    try f.frame();
    try testing.expectEqualStrings("howdy world", e.text.content);
    try testing.expect(f.win.semantics.generation > gen);
    const settled = f.win.semantics.generation;
    try f.frame();
    _ = try f.win.semanticsTree();
    try testing.expectEqual(settled, f.win.semantics.generation);

    try testing.expectError(error.InvalidArgument, access.replaceText(f.win, ed, 3, 99, ""));
    try testing.expectError(error.InvalidArgument, access.replaceText(f.win, ed, 4, 2, ""));
    try testing.expectError(error.InvalidArgument, access.replaceText(f.win, ed, 0, 0, "\xff"));
    try testing.expectError(error.InvalidNode, access.replaceText(f.win, pw, 0, 0, "x"));
    try testing.expectError(error.InvalidNode, access.copyText(f.win, pw, 0, 0, false));
    try testing.expect(access.characterRect(f.win, pw, 0) == null);
    const sem = try f.win.semanticsTree();
    try testing.expectEqual(@as(u8, 2), sem.find(.heading, "Title").?.level);
}

test "hidden nodes take no space, paint nothing, and leave focus, hit testing, and semantics" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 200 });
    defer f.deinit();
    var t = try f.win.begin();
    const row = try box(t, .root, .flex, .{});
    try t.setFlex(row, .{ .gap = 10 });
    const a = try box(t, row, .box, .{ .width = .{ .px = 30 }, .height = .{ .px = 30 } });
    const b = try box(t, row, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 30 } });
    const inner = try box(t, b, .box, .{ .height = .{ .px = 10 } });
    try t.setSemantics(inner, .{ .role = .button, .label = "Inner", .focusable = true });
    try t.setVisual(b, .{ .background = .black });
    const c = try box(t, row, .box, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } });
    t.commit();
    try f.frame();
    try testing.expectEqual(@as(f32, 90), f.rect(c)[0]);
    ui.input.setFocus(f.win, inner, true);
    try testing.expect((try f.win.semanticsTree()).find(.button, "Inner") != null);

    f.comp.keep_log = true;
    t = try f.win.begin();
    try t.setVisual(b, .{ .background = .black, .hidden = true });
    t.commit();
    try f.frame();
    // No space (and one gap fewer), focus gone, not hit, not exposed.
    try testing.expectEqual(@as(f32, 40), f.rect(c)[0]);
    try testing.expectEqual(NodeId.none, f.win.input.focus);
    try testing.expectEqual(row, ui.input.hitTest(f.win, .{ .x = 35, .y = 5 }));
    try testing.expect((try f.win.semanticsTree()).find(.button, "Inner") == null);
    try testing.expect(!ui.input.canFocus(f.win, inner));
    // Its old bounds are damaged in the layer it painted into.
    var damaged = false;
    for (f.comp.log.items) |op| if (op == .set_content) {
        if (op.set_content.damage) |d| damaged = damaged or d.intersect(.xywh(40, 0, 40, 30)).width() > 0;
    };
    try testing.expect(damaged);

    t = try f.win.begin();
    try t.setVisual(b, .{ .background = .black });
    t.commit();
    try f.frame();
    try testing.expectEqual(@as(f32, 90), f.rect(c)[0]);
    try testing.expect(ui.input.canFocus(f.win, inner));
    _ = a;
}

test "modal nodes keep focus and the pointer inside, and give focus back when they go" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 200 });
    defer f.deinit();
    var t = try f.win.begin();
    const outside = try box(t, .root, .box, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } });
    try t.setSemantics(outside, .{ .role = .button, .focusable = true });
    t.commit();
    try f.frame();
    ui.input.setFocus(f.win, outside, true);

    t = try f.win.begin();
    const dialog = try box(t, .root, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .align_x = .end, .align_y = .end });
    try t.setSemantics(dialog, .{ .role = .dialog, .modal = true });
    const first = try box(t, dialog, .box, .{ .height = .{ .px = 20 } });
    try t.setSemantics(first, .{ .role = .button, .focusable = true });
    const second = try box(t, dialog, .box, .{ .height = .{ .px = 20 } });
    try t.setSemantics(second, .{ .role = .button, .focusable = true });
    t.commit();
    try f.frame();
    // Focus moved in on its own, and stays in.
    try testing.expectEqual(first, f.win.input.focus);
    try testing.expectEqual(NodeId.none, ui.input.hitTest(f.win, .{ .x = 10, .y = 10 }));
    try testing.expectEqual(first, ui.input.hitTest(f.win, .{ .x = 150, .y = 110 }));
    try testing.expect(!ui.input.canFocus(f.win, outside));
    const keys: Keys = .{ .f = &f };
    for ([_]NodeId{ second, first, second }) |want| {
        keys.press(ui.keysym.tab, .{});
        try testing.expectEqual(want, f.win.input.focus);
    }
    try testing.expect((try f.win.semanticsTree()).find(.dialog, "").?.modal);

    // A dialog over the dialog, then each goes: focus returns to where it
    // was before each, with the ring it had.
    t = try f.win.begin();
    const inner = try box(t, .root, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } });
    try t.setSemantics(inner, .{ .role = .dialog, .modal = true, .focusable = true });
    t.commit();
    try testing.expectEqual(inner, f.win.input.focus);
    try testing.expect(!ui.input.canFocus(f.win, first));
    t = try f.win.begin();
    try t.remove(inner);
    t.commit();
    try testing.expectEqual(second, f.win.input.focus);
    t = try f.win.begin();
    try t.remove(dialog);
    t.commit();
    try f.frame();
    try testing.expectEqual(outside, f.win.input.focus);
    try testing.expect(f.win.input.focus_visible);
    try testing.expectEqual(outside, ui.input.hitTest(f.win, .{ .x = 10, .y = 10 }));

    // Hiding a modal node gives focus back too.
    t = try f.win.begin();
    const sheet = try box(t, .root, .box, .{});
    try t.setSemantics(sheet, .{ .role = .dialog, .modal = true, .focusable = true });
    t.commit();
    try testing.expectEqual(sheet, f.win.input.focus);
    t = try f.win.begin();
    try t.setVisual(sheet, .{ .hidden = true });
    t.commit();
    try testing.expectEqual(outside, f.win.input.focus);
}

test "transitions animate a node's own opacity and transform, not its first value; reduced motion jumps" {
    for ([_]bool{ false, true }) |reduced| {
        var f: Fixture = undefined;
        try f.init(.{ .width = 200, .height = 200 });
        defer f.deinit();
        f.win.force_reduced_motion = reduced;
        var t = try f.win.begin();
        const n = try box(t, .root, .box, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } });
        try t.setVisual(n, .{ .background = .black, .layer = true, .transition_ms = 150 });
        t.commit();
        f.comp.keep_log = true;
        try f.frame();
        for (f.comp.log.items) |op| try testing.expect(op != .animate);
        f.comp.log.clearRetainingCapacity();
        t = try f.win.begin();
        try t.setVisual(n, .{ .background = .black, .layer = true, .transition_ms = 150, .opacity = 0.5, .transform = .offset(30, 0) });
        t.commit();
        try f.frame();
        var animated: usize = 0;
        var set: usize = 0;
        for (f.comp.log.items) |op| switch (op) {
            .animate => |a| {
                animated += 1;
                try testing.expectEqual(@as(u64, 150 * std.time.ns_per_ms), a.animation.duration_ns);
                try testing.expect(a.animation.from == null);
            },
            .set_opacity, .set_transform => set += 1,
            else => {},
        };
        try testing.expectEqual(@as(usize, if (reduced) 0 else 2), animated);
        try testing.expectEqual(@as(usize, if (reduced) 2 else 0), set);
    }
}

test "animations run on the compositor while shown, follow size and base, and stop with reduced motion" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 200 });
    defer f.deinit();
    var t = try f.win.begin();
    const col = try box(t, .root, .box, .{ .align_y = .start, .align_x = .start });
    const n = try box(t, col, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 10 } });
    try t.setVisual(n, .{ .background = .black, .transform = .offset(5, 0), .animation = .{
        .property = .translate_x,
        .from = -1,
        .to = 2.5,
        .relative = true,
        .duration_ms = 1500,
        .easing = .linear,
    } });
    t.commit();
    f.comp.keep_log = true;
    try f.frame();
    const layer = f.win.state(n).own_layer + 1;
    var a = findAnimate(f.comp.log.items, layer).?;
    // Relative to the node's width, on top of its own transform.
    try testing.expectEqual(@as(f32, 5 - 40), a.from.?.transform.translate.x);
    try testing.expectEqual(@as(f32, 5 + 100), a.to.transform.translate.x);
    try testing.expectEqual(@as(u32, 0), a.iterations);
    try testing.expectEqual(@as(u64, 1500 * std.time.ns_per_ms), a.duration_ns);
    for (f.comp.log.items) |op| if (op == .set_transform) try testing.expect(op.set_transform.layer != layer);

    // An unrelated frame sends nothing; a new size sends it again.
    f.comp.log.clearRetainingCapacity();
    f.win.requestFrame();
    try f.frame();
    try testing.expect(findAnimate(f.comp.log.items, layer) == null);
    t = try f.win.begin();
    try t.setLayout(n, .{ .width = .{ .px = 60 }, .height = .{ .px = 10 } });
    t.commit();
    try f.frame();
    a = findAnimate(f.comp.log.items, f.win.state(n).own_layer + 1).?;
    try testing.expectEqual(@as(f32, 5 + 150), a.to.transform.translate.x);

    // Hidden, the layer goes and the animation with it; shown, it starts
    // again on a new layer.
    var v = f.win.node(n).visual;
    const before = f.win.state(n).own_layer + 1;
    f.comp.log.clearRetainingCapacity();
    t = try f.win.begin();
    v.hidden = true;
    try t.setVisual(n, v);
    t.commit();
    try f.frame();
    var destroyed = false;
    for (f.comp.log.items) |op| destroyed = destroyed or (op == .destroy and op.destroy == before);
    try testing.expect(destroyed);
    f.comp.log.clearRetainingCapacity();
    t = try f.win.begin();
    v.hidden = false;
    try t.setVisual(n, v);
    t.commit();
    try f.frame();
    try testing.expect(findAnimate(f.comp.log.items, f.win.state(n).own_layer + 1) != null);

    // Reduced motion cancels it by setting the node's own transform.
    f.comp.log.clearRetainingCapacity();
    var d = f.win.desktop;
    d.reduced_motion = true;
    f.win.setDesktop(d);
    try f.frame();
    const shown = f.win.state(n).own_layer + 1;
    try testing.expect(findAnimate(f.comp.log.items, shown) == null);
    var reset = false;
    for (f.comp.log.items) |op| if (op == .set_transform and op.set_transform.layer == shown) {
        reset = true;
        try testing.expectEqual(@as(f32, 5), op.set_transform.transform.translate.x - f.win.state(n).pos.x);
    };
    try testing.expect(reset);
    try testing.expect(f.comp.get(shown).anims[0] == null);
}

test "theme: tokens resolve at paint time and follow the desktop's scheme, contrast, accent, and font size" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 100 });
    defer f.deinit();
    var t = try f.win.begin();
    const col = try box(t, .root, .box, .{ .align_y = .start });
    const panel = try box(t, col, .box, .{ .height = .{ .px = 50 } });
    try t.setVisual(panel, .{ .background = .white, .background_token = .window_bg });
    const label = try t.create(col, .text, .none);
    try t.setText(label, "Theme");
    try t.setTextProps(label, .{ .style = .{ .size = 10, .size_role = .body, .color_token = .window_fg } });
    t.commit();
    try f.frame();
    const fill = struct {
        fn of(comp: *Comp) ?scene.Color {
            const root = comp.get(comp.tree.root);
            for (root.content.?.list.commands) |cmd| if (cmd == .fill) return cmd.fill.paint.solid;
            return null;
        }
    }.of;
    const theme = ui.theme;
    try testing.expect(fill(&f.comp).?.eql(theme.compiled[0][@intFromEnum(ui.ColorToken.window_bg)]));
    const h_body = f.rect(label)[3];

    f.win.setDesktop(.{ .color_scheme = .dark });
    try f.frame();
    try testing.expect(fill(&f.comp).?.eql(theme.compiled[1][@intFromEnum(ui.ColorToken.window_bg)]));
    f.win.setDesktop(.{ .color_scheme = .dark, .contrast = .high });
    try f.frame();
    try testing.expectEqual(theme.Variant.dark_high_contrast, f.win.palette.variant);
    try testing.expect(fill(&f.comp).?.eql(.black));

    // The application's choices win over the desktop's.
    var choice: ui.Theme = .{ .scheme = .light, .contrast = .normal };
    choice.overrides[0][@intFromEnum(ui.ColorToken.window_bg)] = .srgb(1, 0, 0, 1);
    f.win.setTheme(&choice);
    try f.frame();
    try testing.expect(fill(&f.comp).?.eql(.srgb(1, 0, 0, 1)));

    // Text with a size role follows the desktop's font size.
    const shapes = f.win.stats.shapes;
    f.win.setDesktop(.{ .font_size = 22 });
    try f.frame();
    try testing.expectEqual(shapes + 1, f.win.stats.shapes);
    try testing.expect(f.rect(label)[3] > 1.8 * h_body);
}

test "editor placeholders show while empty and are exposed to assistive technology" {
    var f: Fixture = undefined;
    try f.init(.{ .width = 200, .height = 100 });
    defer f.deinit();
    var t = try f.win.begin();
    const ed = try t.create(.root, .editor, .none);
    try t.setPlaceholder(ed, "Search");
    try testing.expectError(error.InvalidArgument, t.setPlaceholder(ed, "two\nlines"));
    t.commit();
    try f.frame();
    const glyphRuns = struct {
        fn count(comp: *Comp) usize {
            var n: usize = 0;
            for (comp.tree.layers.items) |l| {
                if (!l.alive) continue;
                const c = l.content orelse continue;
                for (c.list.commands) |cmd| n += @intFromBool(cmd == .glyphs);
            }
            return n;
        }
    }.count;
    try testing.expect(glyphRuns(&f.comp) > 0);
    try testing.expectEqualStrings("Search", (try f.win.semanticsTree()).find(.text_input, "").?.placeholder);
    t = try f.win.begin();
    try t.setText(ed, " ");
    t.commit();
    try f.frame();
    // A space shapes to nothing visible: the placeholder is gone.
    try testing.expectEqual(@as(usize, 0), glyphRuns(&f.comp));
}

fn takeValue(user: ?*anyopaque, _: *ui.Window, _: NodeId, ev: *const ui.Event) ui.HandlerResult {
    const v: *f64 = @ptrCast(@alignCast(user));
    v.* = ev.set_value;
    return .handled;
}

test "set_value goes to nodes with a range, unless disabled" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    var got: f64 = -1;
    var t = try f.win.begin();
    const s = try box(t, .root, .box, .{});
    try t.setSemantics(s, .{ .role = .slider, .value = .{ .min = 0, .max = 10, .now = 2, .step = 1 } });
    try t.on(s, .set_value, .{ .func = takeValue, .user = &got });
    const plain = try box(t, .root, .box, .{});
    try t.on(plain, .set_value, .{ .func = takeValue, .user = &got });
    t.commit();
    try testing.expect(ui.input.setValue(f.win, s, 7));
    try testing.expectEqual(@as(f64, 7), got);
    try testing.expect(!ui.input.setValue(f.win, plain, 3));
    try testing.expect(!ui.input.setValue(f.win, s, std.math.nan(f64)));
    t = try f.win.begin();
    try t.setSemantics(s, .{ .role = .slider, .disabled = true, .value = .{ .min = 0, .max = 10, .now = 2 } });
    t.commit();
    try testing.expect(!ui.input.setValue(f.win, s, 4));
    try testing.expectEqual(@as(f64, 7), got);
}
