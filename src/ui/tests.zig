//! Tests of the UI module through its public interface: transactions,
//! layout, layers, input, and semantics. Pixel output is tested in
//! test/ui (headless golden images).

const std = @import("std");
const text = @import("text");
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

fn countActivate(user: ?*anyopaque, _: *ui.Window, _: NodeId, ev: *const ui.Event) bool {
    const n: *usize = @ptrCast(@alignCast(user));
    if (ev.* == .activate) n.* += 1;
    return true;
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

fn takeScroll(user: ?*anyopaque, _: *ui.Window, _: NodeId, ev: *const ui.Event) bool {
    const total: *f32 = @ptrCast(@alignCast(user));
    if (ev.* != .scroll) return false;
    // Takes upward scrolling only; passes the rest on.
    if (ev.scroll.dy >= 0) return false;
    total.* += ev.scroll.dy;
    return true;
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

fn countChange(user: ?*anyopaque, _: *ui.Window, _: NodeId, ev: *const ui.Event) bool {
    const n: *usize = @ptrCast(@alignCast(user));
    if (ev.* == .change) n.* += 1;
    return true;
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
    f.win.setReducedMotion(true);
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
    try testing.expectEqualStrings("ka", f.win.state(ed).text.?.paragraph.?.text);
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
    try testing.expectEqualStrings("\u{304b}", f.win.state(ed).text.?.paragraph.?.text);
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
    const line0 = l.lines[0];
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
