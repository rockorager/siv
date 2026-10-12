//! UI end to end on the headless backend (D24): transactions, layout,
//! text, layers, input, and damage, rendered by the CPU renderer and
//! compared with PNGs under test/golden/ui/.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless
//! On a mismatch the actual image is written to .zig-cache/golden-failures/.

const std = @import("std");
const scene = @import("scene");
const text = @import("text");
const ui = @import("ui");
const platform = @import("platform");
const png = @import("../render/png.zig");
const App = @import("harness.zig").App;

const testing = std.testing;
const NodeId = ui.NodeId;
const Color = scene.Color;

const golden_dir = "test/golden/ui";
const failure_dir = ".zig-cache/golden-failures";

const ink = Color.srgb8(0x18, 0x18, 0x1b, 0xff);
const panel = Color.srgb8(0xf4, 0xf4, 0xf5, 0xff);
const blue = Color.srgb8(0x25, 0x63, 0xeb, 0xff);
const green = Color.srgb8(0x10, 0xb9, 0x81, 0xff);
const red = Color.srgb8(0xdc, 0x26, 0x26, 0xff);
const border = Color.srgb8(0xa1, 0xa1, 0xaa, 0xff);

fn node(t: *ui.Txn, parent: NodeId, kind: ui.Kind, layout: ui.Layout, visual: ui.Visual) !NodeId {
    const id = try t.create(parent, kind, .none);
    try t.setLayout(id, layout);
    try t.setVisual(id, visual);
    return id;
}

fn label(t: *ui.Txn, parent: NodeId, str: []const u8, style: ui.TextStyle, layout: ui.Layout) !NodeId {
    const id = try t.create(parent, .text, .none);
    try t.setLayout(id, layout);
    try t.setText(id, str);
    try t.setTextProps(id, .{ .style = style });
    return id;
}

const Form = struct { save: NodeId, check: NodeId, badge: NodeId };

/// A small settings panel: heading, a row with a button, a checkbox, a
/// grid of swatches, a wrapped bidi paragraph, and a translucent badge.
fn form(win: *ui.Window) !Form {
    const t = try win.begin();
    errdefer t.abort();
    const p = try node(t, .root, .flex, .{ .padding = .all(16) }, .{ .background = panel });
    try t.setFlex(p, .{ .axis = .column, .gap = 10 });
    _ = try label(t, p, "Settings", .{ .size = 20, .color = ink }, .{});

    const row = try node(t, p, .flex, .{}, .{});
    try t.setFlex(row, .{ .gap = 8, .align_items = .center });
    _ = try label(t, row, "Display name", .{ .color = ink }, .{ .grow = 1 });
    const save = try node(t, row, .box, .{ .padding = .symmetric(12, 6) }, .{ .background = blue, .radius = .all(6) });
    try t.setSemantics(save, .{ .role = .button, .focusable = true });
    _ = try label(t, save, "Save", .{ .color = .white }, .{});

    const check_row = try node(t, p, .flex, .{}, .{});
    try t.setFlex(check_row, .{ .gap = 8, .align_items = .center });
    const check = try node(t, check_row, .box, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }, .{
        .border_width = 2,
        .border_color = border,
        .radius = .{ .top_start = 6, .top_end = 2, .bottom_end = 2, .bottom_start = 2 },
    });
    try t.setSemantics(check, .{ .role = .checkbox, .focusable = true, .checked = .off, .label = "Notify me" });
    _ = try label(t, check_row, "Notify me", .{ .color = ink }, .{});

    const g = try node(t, p, .grid, .{}, .{});
    try t.setGrid(g, .{ .columns = &.{ .{ .px = 40 }, .{ .fr = 1 }, .{ .fr = 2 } }, .column_gap = 6, .row_gap = 6 });
    const colors = [_]Color{ blue, green, red, ink, border, blue };
    for (colors) |c| _ = try node(t, g, .box, .{ .height = .{ .px = 18 } }, .{ .background = c, .radius = .all(4) });

    _ = try label(t, p, "Mixed text: \u{05e9}\u{05dc}\u{05d5}\u{05dd} world, \u{0645}\u{0631}\u{062d}\u{0628}\u{0627} wraps at the panel edge.", .{ .size = 13, .color = ink }, .{});

    // A translucent badge pinned to the top end corner: its own layer.
    const badge = try node(t, .root, .box, .{
        .width = .{ .px = 22 },
        .height = .{ .px = 22 },
        .inset = .{ .end = 10, .top = 10 },
        .padding = .{ .start = 7, .top = 2 },
    }, .{ .background = red, .radius = .all(11), .opacity = 0.75 });
    _ = try label(t, badge, "3", .{ .size = 13, .color = .white }, .{});
    t.commit();
    return .{ .save = save, .check = check, .badge = badge };
}

fn expectGolden(app: *App, name: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    const img = try app.presented();
    const got = img.rgba;
    defer gpa.free(got);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ golden_dir, name });
    defer gpa.free(path);
    if (testing.environ.getPosix("SIV_UPDATE_GOLDEN") != null) {
        const bytes = try png.encode(gpa, img.width, img.height, got);
        defer gpa.free(bytes);
        try std.Io.Dir.cwd().createDirPath(io, golden_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        return;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |e| {
        std.debug.print("golden {s}: cannot read {s}: {t} (run with SIV_UPDATE_GOLDEN=1)\n", .{ name, path, e });
        return error.MissingGolden;
    };
    defer gpa.free(bytes);
    const want = try png.decode(gpa, bytes);
    defer want.deinit(gpa);
    if (want.width != img.width or want.height != img.height) return error.GoldenSizeMismatch;
    // The CPU renderer's tolerance (test/render/golden.zig).
    var worst: u8 = 0;
    var off: usize = 0;
    for (0..got.len / 4) |i| {
        var d: u8 = 0;
        for (0..4) |c| d = @max(d, absDiff(want.pixels[i * 4 + c], got[i * 4 + c]));
        worst = @max(worst, d);
        if (d > 1) off += 1;
    }
    if (worst <= 3 and off * 200 <= got.len / 4) return;
    std.debug.print("golden {s}: max channel difference {d}, {d} pixels off by more than 1\n", .{ name, worst, off });
    try std.Io.Dir.cwd().createDirPath(io, failure_dir);
    const out = try png.encode(gpa, img.width, img.height, got);
    defer gpa.free(out);
    const fpath = try std.fmt.allocPrint(gpa, "{s}/ui-{s}-actual.png", .{ failure_dir, name });
    defer gpa.free(fpath);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fpath, .data = out });
    return error.GoldenMismatch;
}

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// The presented frame (drawn with damage only) equals a full redraw.
fn expectDamageExact(app: *App) !void {
    const got = try app.presented();
    defer testing.allocator.free(got.rgba);
    const full = try app.fullRender(got.width, got.height);
    defer testing.allocator.free(full);
    try testing.expectEqualSlices(u8, full, got.rgba);
}

test "form: layout, text, focus ring, and a translucent layer (LTR and RTL)" {
    for ([_]bool{ false, true }) |rtl| {
        var app: App = undefined;
        try app.init(testing.allocator, .{ .width = 320, .height = 240, .rtl = rtl });
        defer app.deinit();
        const f = try form(app.win);
        try app.settle();
        // Keyboard focus on the button shows its ring.
        app.key(ui.keysym.tab, .{});
        try app.settle();
        try testing.expectEqual(f.save, app.win.input.focus);
        try expectDamageExact(&app);
        try expectGolden(&app, if (rtl) "form-rtl" else "form-ltr");

        // Mirroring: the badge sits at the end corner, the button at the end.
        const badge = app.win.windowRect(f.badge);
        const save = app.win.windowRect(f.save);
        if (rtl) {
            try testing.expectEqual(@as(f32, 10), badge.x0);
            try testing.expectEqual(@as(f32, 16), save.x0);
        } else {
            try testing.expectEqual(@as(f32, 320 - 10 - 22), badge.x0);
            try testing.expectEqual(@as(f32, 320 - 16), save.x1);
        }
        // The semantics tree sees the same UI.
        const sem = &app.win.semantics;
        try testing.expect(sem.find(.button, "Save").?.focused);
        try testing.expectEqual(ui.Toggle.off, sem.find(.checkbox, "Notify me").?.checked);
        try testing.expect(sem.find(.label, "Settings") != null);
    }
}

fn activateCheck(user: ?*anyopaque, win: *ui.Window, id: NodeId, ev: *const ui.Event) bool {
    _ = user;
    if (ev.* != .activate) return false;
    const n = win.node(id);
    const on = n.semantics.checked != .on;
    const t = win.begin() catch return false;
    var sem = n.semantics;
    sem.checked = if (on) .on else .off;
    var v = n.visual;
    v.background = if (on) blue else .transparent;
    v.border_color = if (on) blue else border;
    t.setSemantics(id, sem) catch {
        t.abort();
        return false;
    };
    t.setVisual(id, v) catch {
        t.abort();
        return false;
    };
    t.commit();
    return true;
}

test "clicks toggle through a handler; paint-only changes damage only what changed" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 320, .height = 240 });
    defer app.deinit();
    const f = try form(app.win);
    {
        const t = try app.win.begin();
        try t.on(f.check, .activate, .{ .func = activateCheck });
        t.commit();
    }
    try app.settle();
    const layouts = app.win.stats.layouts;
    const r = app.win.windowRect(f.check);
    app.click(r.x0 + 4, r.y0 + 4);
    try app.settle();
    try testing.expectEqual(ui.Toggle.on, app.win.node(f.check).semantics.checked);
    try testing.expectEqual(ui.Toggle.on, app.win.semantics.find(.checkbox, "Notify me").?.checked);
    // No layout; the presented damage is the checkbox (and its focus-free
    // neighbourhood), not the window.
    try testing.expectEqual(layouts, app.win.stats.layouts);
    const img = try app.presented();
    testing.allocator.free(img.rgba);
    const d = img.damage.?;
    try testing.expect(d.x >= @as(i32, @intFromFloat(r.x0)) - 2 and d.x + d.width <= @as(i32, @intFromFloat(r.x1)) + 2);
    try testing.expect(d.y >= @as(i32, @intFromFloat(r.y0)) - 2 and d.y + d.height <= @as(i32, @intFromFloat(r.y1)) + 2);
    try expectDamageExact(&app);
    try expectGolden(&app, "form-checked");
}

test "scrolling on the compositor at 2x: no layout, no repaint, exact damage" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 160, .height = 120, .scale = 2 });
    defer app.deinit();
    var list: NodeId = undefined;
    {
        const t = try app.win.begin();
        const col = try node(t, .root, .flex, .{ .padding = .all(8) }, .{ .background = panel });
        try t.setFlex(col, .{ .axis = .column, .gap = 6 });
        _ = try label(t, col, "Inbox", .{ .size = 16, .color = ink }, .{});
        // The border draws over the padding, so the padding keeps the
        // scrolled content off it.
        list = try node(t, col, .scroll, .{ .grow = 1, .basis = .{ .px = 0 }, .padding = .all(1) }, .{ .background = .white, .radius = .all(6), .clip = true, .border_width = 1, .border_color = border });
        for (0..12) |i| {
            const item = try node(t, list, .box, .{ .padding = .symmetric(8, 5) }, .{ .background = if (i % 2 == 0) .white else panel });
            var buf: [32]u8 = undefined;
            _ = try label(t, item, try std.fmt.bufPrint(&buf, "Message {d}", .{i + 1}), .{ .size = 12, .color = ink }, .{});
        }
        t.commit();
    }
    try app.settle();
    const layouts = app.win.stats.layouts;
    const builds = app.win.stats.layer_builds;
    const r = app.win.windowRect(list);
    app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = r.x0 + 20, .y = r.y0 + 20 } });
    app.inject(.{ .scroll = .{ .window = app.wid, .seat = 0, .dy = 80, .v120_y = 120 * 2, .source = .wheel } });
    try app.settle();
    try testing.expectEqual(@as(f32, 80), app.win.node(list).data.scroll.offset.y);
    try testing.expectEqual(layouts, app.win.stats.layouts);
    try testing.expectEqual(builds, app.win.stats.layer_builds);
    // Damage stays inside the viewport (device pixels at 2x).
    const img = try app.presented();
    testing.allocator.free(img.rgba);
    const d = img.damage.?;
    try testing.expect(d.y >= @as(i32, @intFromFloat(r.y0 * 2)) - 1);
    try testing.expect(d.y + d.height <= @as(i32, @intFromFloat(r.y1 * 2)) + 1);
    try expectDamageExact(&app);
    try expectGolden(&app, "scroll-2x");
    // Hit testing follows the compositor's offset.
    var hit = ui.input.hitTest(app.win, .{ .x = r.x0 + 20, .y = r.y0 + 10 });
    if (app.win.node(hit).kind != .text) hit = app.win.node(hit).first;
    try testing.expectEqualStrings("Message 4", app.win.node(hit).data.text.content);
}

test "a pending font loads on the pool and the text reshapes" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 200, .height = 60 });
    defer app.deinit();
    var path_buf: [64]u8 = undefined;
    const path = try writeFont(&path_buf, text.font.test_fonts.hebrew);
    defer _ = std.os.linux.unlink(path);
    const latin: text.FontId = @enumFromInt(0); // the harness adds it first
    const hebrew = try app.fonts.cache.addPending(.{ .path = path }, null);
    try app.fonts.register("Pending", &.{ latin, hebrew });
    var id: NodeId = undefined;
    {
        const t = try app.win.begin();
        id = try label(t, .root, "Shalom \u{05e9}\u{05dc}\u{05d5}\u{05dd}", .{ .family = "Pending", .color = ink }, .{});
        t.commit();
    }
    try app.settle();
    try testing.expectEqual(text.font.State.ready, app.fonts.cache.state(hebrew));
    try testing.expectEqual(@as(u64, 2), app.win.stats.shapes);
    const c = app.win.state(id).text.?;
    try testing.expect(!c.paragraph.?.missing);
    try testing.expectEqual(@as(usize, 0), c.paragraph.?.wanted.len);
}

fn writeFont(buf: []u8, bytes: []const u8) ![:0]const u8 {
    const linux = std.os.linux;
    const path = try std.fmt.bufPrintSentinel(buf, "/tmp/siv-ui-golden-{d}.ttf", .{linux.getpid()}, 0);
    const fd: i32 = @intCast(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600));
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        done += n;
    }
    return path;
}

test "editors: selection, caret, horizontal scrolling, and RTL" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 240, .height = 130 });
    defer app.deinit();
    var eds: [3]NodeId = undefined;
    {
        const t = try app.win.begin();
        const col = try node(t, .root, .flex, .{ .padding = .all(10) }, .{ .background = panel });
        try t.setFlex(col, .{ .axis = .column, .gap = 8, .align_items = .start });
        const field: ui.Visual = .{ .background = .white, .border_width = 1, .border_color = border, .radius = .all(4) };
        eds[0] = try node(t, col, .editor, .{ .width = .{ .px = 200 }, .padding = .symmetric(6, 4) }, field);
        try t.setText(eds[0], "Hello wide world");
        // A narrow field whose text overflows: it scrolls to the caret.
        eds[1] = try node(t, col, .editor, .{ .width = .{ .px = 110 }, .padding = .symmetric(6, 4) }, field);
        try t.setText(eds[1], "A rather long line of text");
        try t.setSelection(eds[1], 26, 26, .downstream);
        // Right to left: the field mirrors and the text starts at the right.
        eds[2] = try node(t, col, .editor, .{ .width = .{ .px = 200 }, .padding = .symmetric(6, 4), .direction = .rtl }, field);
        try t.setText(eds[2], "\u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e2}\u{05d5}\u{05dc}\u{05dd}");
        try t.setSelection(eds[2], 9, 17, .downstream);
        t.commit();
    }
    try app.settle();
    // Click into the first field after "wide", then shift+End selects the rest.
    const r = app.win.windowRect(eds[0]);
    app.click(r.x0 + 6 + 66, r.y0 + 10);
    app.key(ui.keysym.end, .{ .shift = true });
    try app.settle();
    const e = app.win.node(eds[0]).data.editor;
    try testing.expectEqual(@as(u32, 16), e.caret);
    try testing.expect(e.anchor > 6 and e.anchor < 16);
    try testing.expect(app.win.state(eds[1]).editor_scroll > 0);
    try expectDamageExact(&app);
    try expectGolden(&app, "editors");
}

test "input method on the compositor: enable, inline preedit, commit" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 200, .height = 50 });
    defer app.deinit();
    var ed: NodeId = undefined;
    {
        const t = try app.win.begin();
        const col = try node(t, .root, .box, .{ .padding = .all(10) }, .{ .background = panel });
        ed = try node(t, col, .editor, .{ .padding = .symmetric(6, 4) }, .{ .background = .white, .border_width = 1, .border_color = border, .radius = .all(4) });
        try t.setText(ed, "Caf");
        try t.setSelection(ed, 3, 3, .downstream);
        t.commit();
    }
    try app.settle();
    app.inject(.{ .text_input_enter = .{ .window = app.wid, .seat = 0, .serial = 0 } });
    app.key(ui.keysym.tab, .{});
    try app.settle();
    var st = try app.textInputState();
    try testing.expect(st.enabled);
    try testing.expectEqualStrings("Caf", st.surrounding);
    try testing.expectEqual(@as(u32, 3), st.cursor);
    testing.allocator.free(st.surrounding);

    var pre: platform.TextInput = .{ .window = app.wid, .seat = 0, .cursor_begin = 2, .cursor_end = 2 };
    @memcpy(pre.preedit_buf[0..2], "\u{e9}");
    pre.preedit_len = 2;
    app.inject(.{ .text_input = pre });
    try app.settle();
    try testing.expectEqualStrings("Caf", app.win.node(ed).data.editor.text.content);
    try expectDamageExact(&app);
    try expectGolden(&app, "ime-preedit");

    var done: platform.TextInput = .{ .window = app.wid, .seat = 0 };
    @memcpy(done.commit_buf[0..2], "\u{e9}");
    done.commit_len = 2;
    app.inject(.{ .text_input = done });
    try app.settle();
    try testing.expectEqualStrings("Caf\u{e9}", app.win.node(ed).data.editor.text.content);
    st = try app.textInputState();
    defer testing.allocator.free(st.surrounding);
    try testing.expectEqualStrings("Caf\u{e9}", st.surrounding);
    try testing.expectEqual(@as(u32, 5), st.cursor);
}
