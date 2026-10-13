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
const compositor = @import("compositor");
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
    return expectGoldenOf(app, app.wid, name);
}

fn expectGoldenOf(app: *App, wid: platform.WindowId, name: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    const img = try app.presentedOf(wid);
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

fn activateCheck(user: ?*anyopaque, win: *ui.Window, id: NodeId, ev: *const ui.Event) ui.HandlerResult {
    _ = user;
    if (ev.* != .activate) return .pass;
    const n = win.node(id);
    const on = n.semantics.checked != .on;
    const t = win.begin() catch return .pass;
    var sem = n.semantics;
    sem.checked = if (on) .on else .off;
    var v = n.visual;
    v.background = if (on) blue else .transparent;
    v.border_color = if (on) blue else border;
    t.setSemantics(id, sem) catch {
        t.abort();
        return .pass;
    };
    t.setVisual(id, v) catch {
        t.abort();
        return .pass;
    };
    t.commit();
    return .handled;
}

test "images: copied at creation, still shown after the creator lets go, mirrored in RTL" {
    for ([_]bool{ false, true }) |rtl| {
        var app: App = undefined;
        try app.init(testing.allocator, .{ .width = 160, .height = 60, .rtl = rtl });
        defer app.deinit();
        // An arrow pointing to the start edge: red tip, blue shaft.
        var px: [8 * 4 * 4]u8 = undefined;
        for (0..4) |y| for (0..8) |x| {
            const tip = x < 2 or (x < 4 and (y == 1 or y == 2));
            px[(y * 8 + x) * 4 ..][0..4].* = if (tip) .{ 0xdc, 0x26, 0x26, 0xff } else .{ 0x25, 0x63, 0xeb, 0xff };
        };
        const img = try ui.Image.create(testing.allocator, .{ .pixels = &px, .width = 8, .height = 4 });
        var row: NodeId = undefined;
        {
            const t = try app.win.begin();
            row = try node(t, .root, .flex, .{ .padding = .all(10) }, .{ .background = panel });
            try t.setFlex(row, .{ .gap = 10 });
            const a = try node(t, row, .image, .{ .width = .{ .px = 64 }, .height = .{ .px = 32 } }, .{});
            try t.setImage(a, .{ .image = img, .filter = .nearest, .mirror = true });
            const b = try node(t, row, .image, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } }, .{});
            try t.setImage(b, .{ .image = img, .filter = .nearest, .fit = .cover });
            t.commit();
        }
        // The tree has its own references and its own copy of the pixels.
        img.release();
        @memset(&px, 0);
        try app.settle();
        try expectGolden(&app, if (rtl) "image-rtl" else "image-ltr");
        // Removed, the last display list showing them is released and the
        // testing allocator sees the pixels freed.
        {
            const t = try app.win.begin();
            try t.remove(row);
            t.commit();
        }
        try app.settle();
    }
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
    const latin = app.fonts.families.get(try app.fonts.intern("Droid")).?[0]; // the harness adds it first
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

fn twoEditors(app: *App) ![2]NodeId {
    var eds: [2]NodeId = undefined;
    const t = try app.win.begin();
    const col = try node(t, .root, .flex, .{ .padding = .all(10) }, .{ .background = panel });
    try t.setFlex(col, .{ .axis = .column, .gap = 8, .align_items = .start });
    for (&eds) |*e| e.* = try node(t, col, .editor, .{ .width = .{ .px = 200 }, .padding = .symmetric(6, 4) }, .{ .background = .white });
    try t.setText(eds[0], "copy this text");
    t.commit();
    return eds;
}

const Sel = struct { kind: platform.SelectionKind, mimes: []const []const u8 = &.{}, data: []const u8 = "", fd: i32 = -1, mime: []const u8 = "" };

fn offer(hl: *platform.Headless, s: *Sel) void {
    hl.offerSelection(0, s.kind, s.mimes, s.data) catch unreachable;
}

fn request(hl: *platform.Headless, s: *Sel) void {
    s.fd = hl.requestSelection(0, s.kind, s.mime) catch -1;
}

test "clipboard: copy and paste through the platform, and its size limit" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 240, .height = 90 });
    defer app.deinit();
    const eds = try twoEditors(&app);
    try app.settle();
    // Select "this" and copy it.
    app.key(ui.keysym.tab, .{});
    app.key(ui.keysym.home, .{});
    app.key(ui.keysym.right, .{ .ctrl = true });
    app.key(ui.keysym.right, .{ .ctrl = true, .shift = true });
    app.key('c', .{ .ctrl = true });
    try app.settle();
    // Another client pastes it: the window writes it into the pipe.
    var req: Sel = .{ .kind = .clipboard, .mime = "text/plain;charset=utf-8" };
    app.onHeadless(&req, request);
    try testing.expect(req.fd >= 0);
    const got = try app.readAll(req.fd);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(" this", got);
    // Pasting the window's own copy takes it directly.
    app.key(ui.keysym.tab, .{});
    app.key('v', .{ .ctrl = true });
    try app.settle();
    try testing.expectEqualStrings(" this", app.win.node(eds[1]).data.editor.text.content);

    // Another client copies more than a pipe holds, with a line break; a
    // single-line editor gets a space instead.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "first\nsecond ");
    for (0..20_000) |_| try big.appendSlice(testing.allocator, "0123456789");
    var o: Sel = .{ .kind = .clipboard, .mimes = &.{ "image/png", "UTF8_STRING" }, .data = big.items };
    app.onHeadless(&o, offer);
    try app.settle();
    app.key('a', .{ .ctrl = true });
    app.key('v', .{ .ctrl = true });
    try app.settle();
    const pasted = app.win.node(eds[1]).data.editor.text.content;
    try testing.expectEqual(big.items.len, pasted.len);
    try testing.expectEqualStrings("first second 0123", pasted[0..17]);
    // Past the limit, the paste is dropped and the text stays.
    app.clipboard.limit = 1000;
    app.key('a', .{ .ctrl = true });
    app.key('v', .{ .ctrl = true });
    try app.settle();
    try testing.expectEqual(big.items.len, app.win.node(eds[1]).data.editor.text.content.len);
    // Undo removes the paste in one step.
    app.key('z', .{ .ctrl = true });
    try app.settle();
    try testing.expectEqualStrings(" this", app.win.node(eds[1]).data.editor.text.content);

    // Assistive technology cuts a range and pastes it at an offset.
    try ui.access.copyText(app.win, eds[0], 0, 5, true);
    try app.settle();
    try testing.expectEqualStrings("this text", app.win.node(eds[0]).data.editor.text.content);
    try ui.access.pasteText(app.win, eds[1], 0);
    try app.settle();
    try testing.expectEqualStrings("copy  this", app.win.node(eds[1]).data.editor.text.content);
}

test "primary selection: selecting offers it, the middle button pastes it" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 240, .height = 90 });
    defer app.deinit();
    const eds = try twoEditors(&app);
    try app.settle();
    app.key(ui.keysym.tab, .{});
    app.key(ui.keysym.home, .{});
    app.key(ui.keysym.right, .{ .shift = true, .ctrl = true });
    try app.settle();
    var req: Sel = .{ .kind = .primary, .mime = "UTF8_STRING" };
    app.onHeadless(&req, request);
    try testing.expect(req.fd >= 0);
    const got = try app.readAll(req.fd);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("copy", got);
    // Middle click into the second editor pastes it there.
    const r = app.win.windowRect(eds[1]);
    app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = r.x0 + 10, .y = r.y0 + 8 } });
    app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x112, .pressed = true, .time = 0, .serial = 9 } });
    app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x112, .pressed = false, .time = 0, .serial = 10 } });
    try app.settle();
    try testing.expectEqualStrings("copy", app.win.node(eds[1]).data.editor.text.content);
    try testing.expectEqual(eds[1], app.win.input.focus);
}

fn menu(win: *ui.Window) ![3]NodeId {
    var items: [3]NodeId = undefined;
    const t = try win.begin();
    const col = try node(t, .root, .flex, .{ .padding = .all(4) }, .{ .background = .white, .border_width = 1, .border_color = border, .radius = .all(6) });
    try t.setFlex(col, .{ .axis = .column });
    try t.setSemantics(col, .{ .role = .menu });
    for (&items, [_][]const u8{ "Open", "Save as\u{2026}", "Quit" }) |*it, name| {
        it.* = try node(t, col, .box, .{ .padding = .symmetric(10, 4) }, .{ .radius = .all(4) });
        try t.setSemantics(it.*, .{ .role = .menu_item, .focusable = true });
        _ = try label(t, it.*, name, .{ .size = 13, .color = ink }, .{});
    }
    t.commit();
    return items;
}

test "popups: placed below their button, flipped at the edge, keyboard, dismissed by outside presses" {
    for ([_]bool{ false, true }) |rtl| {
        var app: App = undefined;
        // The output is the window's size, so a popup below the button
        // must flip above it.
        try app.init(testing.allocator, .{ .width = 240, .height = 160, .rtl = rtl, .output_width = 240, .output_height = 160 });
        defer app.deinit();
        var button: NodeId = undefined;
        var near_bottom: NodeId = undefined;
        {
            const t = try app.win.begin();
            const col = try node(t, .root, .stack, .{ .padding = .all(10) }, .{ .background = panel });
            button = try node(t, col, .box, .{ .padding = .symmetric(12, 6), .align_x = .start, .align_y = .start }, .{ .background = blue, .radius = .all(6) });
            try t.setSemantics(button, .{ .role = .button, .focusable = true });
            _ = try label(t, button, "File", .{ .color = .white }, .{});
            near_bottom = try node(t, col, .box, .{ .width = .{ .px = 60 }, .height = .{ .px = 20 }, .inset = .{ .end = 0, .bottom = 0 } }, .{ .background = blue });
            t.commit();
        }
        try app.settle();
        const br = app.win.windowRect(button);
        app.click(br.x0 + 5, br.y0 + 5);
        try app.settle();

        const p = try app.openPopup(button, 120, 90, .below, true);
        const items = try menu(p.win);
        try app.settle();
        var st = try app.windowState(p.wid);
        // Below the button, at its start edge (the right edge in RTL).
        try testing.expectEqual(@as(i32, @intFromFloat(@ceil(br.y1))), st.popup.?.y);
        if (rtl) {
            try testing.expectEqual(@as(i32, @intFromFloat(@ceil(br.x1))) - 120, st.popup.?.x);
        } else {
            try testing.expectEqual(@as(i32, @intFromFloat(@floor(br.x0))), st.popup.?.x);
        }
        if (!rtl) try expectGoldenOf(&app, p.wid, "popup-menu");
        // The grab gives it the keyboard: Tab moves through its items.
        const k: platform.Key = .{ .window = p.wid, .seat = 0, .keycode = 0, .keysym = ui.keysym.tab, .state = .pressed, .mods = .{}, .time = 0, .serial = 20 };
        app.inject(.{ .key = k });
        try app.settle();
        try testing.expectEqual(items[0], p.win.input.focus);
        // A press outside dismisses it and reaches nothing else.
        const focus_before = app.win.input.focus;
        app.inject(.{ .pointer_motion = .{ .window = app.wid, .seat = 0, .x = 200, .y = 10 } });
        app.inject(.{ .pointer_button = .{ .window = app.wid, .seat = 0, .button = 0x110, .pressed = true, .time = 0, .serial = 21 } });
        try app.settle();
        try testing.expect(p.closed);
        try testing.expectEqual(focus_before, app.win.input.focus);
        p.close();
        try app.settle();

        // From the bottom of the output it opens above instead.
        const q = try app.openPopup(near_bottom, 100, 60, .below, false);
        _ = try menu(q.win);
        try app.settle();
        st = try app.windowState(q.wid);
        const nr = app.win.windowRect(near_bottom);
        try testing.expectEqual(@as(i32, @intFromFloat(@floor(nr.y0))) - 60, st.popup.?.y);
        // Repositioned to follow a moved anchor: below the button now.
        try app.comp.repositionPopup(q.wid, app.win.popupPositioner(button, 100, 60, .below, null));
        try app.settle();
        st = try app.windowState(q.wid);
        try testing.expectEqual(@as(i32, @intFromFloat(@ceil(br.y1))), st.popup.?.y);
        q.close();
    }
}

const Video = struct {
    fd: i32,
    pixels: []u8,
    frame: compositor.ExternalFrame,
    mode: enum { above, below, composited } = .composited,

    fn init(w: u32, h: u32) !Video {
        const linux = std.os.linux;
        const fd: i32 = @intCast(linux.memfd_create("siv-video", linux.MFD.CLOEXEC));
        const pixels = try testing.allocator.alloc(u8, w * h * 4);
        for (0..h) |y| for (0..w) |x| {
            pixels[(y * w + x) * 4 ..][0..4].* = .{ @intCast(x * 255 / w), @intCast(y * 255 / h), 0x40, 0 };
        };
        _ = linux.ftruncate(fd, @intCast(pixels.len));
        _ = linux.pwrite(fd, pixels.ptr, pixels.len, 0);
        return .{ .fd = fd, .pixels = pixels, .frame = .{ .fd = fd, .width = w, .height = h, .stride = w * 4, .key = 7 } };
    }

    fn deinit(v: *Video) void {
        _ = std.os.linux.close(v.fd);
        testing.allocator.free(v.pixels);
    }

    /// For the harness's full redraw, drawn as the compositor decided.
    fn draw(ctx: *anyopaque, _: compositor.ExternalId) compositor.tree.Draw {
        const v: *Video = @ptrCast(@alignCast(ctx));
        return .{ .promoted = v.mode != .composited, .what = switch (v.mode) {
            .above => .none,
            .below => .hole,
            .composited => .{ .image = .{ .pixels = v.pixels.ptr, .width = v.frame.width, .height = v.frame.height, .stride = v.frame.stride, .format = .bgrx8_srgb, .key = 7 } },
        } };
    }
};

fn subsurfaceOf(app: *App) ?platform.SubsurfaceState {
    const S = struct {
        wid: platform.WindowId,
        out: ?platform.SubsurfaceState = null,
        fn f(hl: *platform.Headless, s: *@This()) void {
            const subs = hl.subsurfaces(s.wid);
            s.out = if (subs.len != 0) subs[0] else null;
        }
    };
    var s: S = .{ .wid = app.wid };
    app.onHeadless(&s, S.f);
    return s.out;
}

/// Draws the holes the compositor punches for an embedder's surface below
/// the window, for the harness's full redraws.
const Embedded = struct {
    app: *App,

    fn draw(ctx: *anyopaque, _: compositor.ExternalId) compositor.tree.Draw {
        const e: *Embedded = @ptrCast(@alignCast(ctx));
        const sub = subsurfaceOf(e.app) orelse return .{};
        return .{ .promoted = sub.visible, .what = if (sub.visible and sub.below) .hole else .none };
    }
};

fn bareCommitsOf(app: *App) u32 {
    const S = struct {
        wid: platform.WindowId,
        out: u32 = 0,
        fn f(hl: *platform.Headless, s: *@This()) void {
            s.out = hl.bareCommits(s.wid);
        }
    };
    var s: S = .{ .wid = app.wid };
    app.onHeadless(&s, S.f);
    return s.out;
}

test "embedded surfaces: told their size, hidden until a frame fits a crop, never outside the window" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 240, .height = 160, .scale = 2 });
    defer app.deinit();
    var embedded: Embedded = .{ .app = &app };
    app.mirror.externals = .{ .ctx = &embedded, .draw = Embedded.draw };
    const es = try app.comp.createExternalSurface(app.wid);
    try testing.expect(es.display == null and es.surface == null);
    var root: NodeId = undefined;
    var scroll: NodeId = undefined;
    var player: NodeId = undefined;
    {
        const t = try app.win.begin();
        root = try node(t, .root, .stack, .{ .padding = .all(10) }, .{ .background = panel });
        try t.setStack(root, .{ .align_x = .start, .align_y = .start });
        // Only the top half of the 120x80 player shows in the scroll view.
        scroll = try node(t, root, .scroll, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
        player = try node(t, scroll, .external, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } }, .{});
        try t.setExternal(player, .{ .id = es.id, .fit = .fill });
        t.commit();
    }
    try app.settle();
    // Told its size in logical and buffer pixels (scale 2).
    const cf = app.external_configure.?;
    try testing.expectEqual(es.id, cf.id);
    try testing.expectEqual([4]u32{ 120, 80, 240, 160 }, [4]u32{ cf.width, cf.height, cf.buffer_width, cf.buffer_height });
    // No frame of that size yet, and it needs cropping: hidden, and no
    // hole in the window.
    var sub = subsurfaceOf(&app).?;
    try testing.expect(sub.embed and !sub.visible);
    try expectDamageExact(&app);

    // A frame of the right size: cropped through the viewport, above the
    // window.
    try app.comp.externalSurfaceCommitted(app.wid, es.id, 240, 160);
    try app.settle();
    sub = subsurfaceOf(&app).?;
    try testing.expect(sub.visible and !sub.below);
    try testing.expectEqual(platform.Rect{ .x = 10, .y = 10, .width = 120, .height = 40 }, sub.rect);
    try testing.expectEqual(@as(f32, 80), sub.source.?.height);
    try testing.expectEqual(@as(f32, 240), sub.source.?.width);
    try expectDamageExact(&app);
    // The next frame changes nothing else: a bare commit shows it.
    const bare = bareCommitsOf(&app);
    const presented = app.presented_seq;
    try app.comp.externalSurfaceCommitted(app.wid, es.id, 240, 160);
    try app.settle();
    try testing.expectEqual(bare + 1, bareCommitsOf(&app));
    try testing.expectEqual(presented, app.presented_seq);

    // A new size: told again, and hidden until a frame of it arrives (the
    // old source could fall outside the new buffer).
    {
        const t = try app.win.begin();
        try t.setLayout(player, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } });
        t.commit();
    }
    try app.settle();
    try testing.expectEqual(@as(u32, 200), app.external_configure.?.buffer_width);
    try testing.expect(!subsurfaceOf(&app).?.visible);
    try app.comp.externalSurfaceCommitted(app.wid, es.id, 200, 160);
    try app.settle();
    sub = subsurfaceOf(&app).?;
    try testing.expect(sub.visible and sub.source.?.width == 200);

    // Uncropped, it shows as soon as it is placed, scaled to fit whatever
    // frame it has: inside the window either way.
    {
        const t = try app.win.begin();
        try t.remove(scroll);
        player = try node(t, root, .external, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } }, .{});
        try t.setExternal(player, .{ .id = es.id, .fit = .fill });
        t.commit();
    }
    try app.settle();
    sub = subsurfaceOf(&app).?;
    try testing.expect(sub.visible and !sub.below and sub.source == null);
    try testing.expectEqual(platform.Rect{ .x = 10, .y = 10, .width = 100, .height = 80 }, sub.rect);

    // Moved past the window's right edge (180 to 280 in a 240 wide
    // window): the window crops it like a clip.
    {
        const t = try app.win.begin();
        try t.setVisual(player, .{ .transform = .offset(170, 0) });
        t.commit();
    }
    try app.settle();
    sub = subsurfaceOf(&app).?;
    try testing.expect(sub.visible and !sub.below);
    try testing.expectEqual(platform.Rect{ .x = 180, .y = 10, .width = 60, .height = 80 }, sub.rect);
    try testing.expectEqual(@as(f32, 120), sub.source.?.width);
    try expectDamageExact(&app);
    // Translucent and uncovered: above the window at that alpha
    // (alpha-modifier-v1), still cropped.
    {
        const t = try app.win.begin();
        try t.setVisual(player, .{ .transform = .offset(170, 0), .opacity = 0.9 });
        t.commit();
    }
    try app.settle();
    sub = subsurfaceOf(&app).?;
    try testing.expect(sub.visible and !sub.below);
    try testing.expectEqual(@as(f32, 0.9), sub.alpha);
    try testing.expectEqual(platform.Rect{ .x = 180, .y = 10, .width = 60, .height = 80 }, sub.rect);
    try testing.expectEqual(@as(f32, 120), sub.source.?.width);
    try expectDamageExact(&app);
    // Rotated past the edge too: its bounding box, cropped by the window.
    {
        const t = try app.win.begin();
        try t.setVisual(player, .{ .transform = .{ .translate = .{ .x = 170, .y = 0 }, .rotate = 0.2, .origin = .{ .x = 50, .y = 40 } } });
        t.commit();
    }
    try app.settle();
    // The box is larger, so the embedder is told a new size; hidden until
    // a frame of it arrives.
    const rotated = app.external_configure.?;
    try testing.expect(rotated.width > 100 and !subsurfaceOf(&app).?.visible);
    try app.comp.externalSurfaceCommitted(app.wid, es.id, rotated.buffer_width, rotated.buffer_height);
    try app.settle();
    sub = subsurfaceOf(&app).?;
    try testing.expect(sub.visible and sub.below and sub.source != null);
    try testing.expect(sub.rect.x + sub.rect.width <= 240 and sub.rect.y >= 0);
    try testing.expect(sub.source.?.x + sub.source.?.width <= @as(f32, @floatFromInt(rotated.buffer_width)));
    try expectDamageExact(&app);

    // Gone: hidden.
    {
        const t = try app.win.begin();
        try t.remove(player);
        t.commit();
    }
    try app.settle();
    try testing.expect(!subsurfaceOf(&app).?.visible);
    try expectDamageExact(&app);
}

test "external content: above the window, below it with a hole under controls, composited when translucent" {
    var app: App = undefined;
    try app.init(testing.allocator, .{ .width = 240, .height = 160 });
    defer app.deinit();
    var video = try Video.init(64, 36);
    defer video.deinit();
    const ext = try app.comp.createExternal(app.wid);
    try app.comp.setExternalFrame(app.wid, ext, video.frame);
    app.mirror.externals = .{ .ctx = &video, .draw = Video.draw };
    var player: NodeId = undefined;
    {
        const t = try app.win.begin();
        const col = try node(t, .root, .stack, .{ .padding = .all(10) }, .{ .background = panel });
        try t.setStack(col, .{ .align_x = .stretch, .align_y = .stretch });
        player = try node(t, col, .external, .{}, .{ .background = ink });
        try t.setExternal(player, .{ .id = ext, .width = 16, .height = 9 });
        t.commit();
    }
    try app.settle();
    // 220x140 box, 16:9 content letterboxed: 220x123.75 centered.
    const sub = subsurfaceOf(&app).?;
    try testing.expect(sub.visible);
    try testing.expectEqual(@as(i32, 10), sub.rect.x);
    try testing.expectEqual(@as(i32, 220), sub.rect.width);
    try testing.expectEqual(@as(u64, 7), sub.frame.?.key);
    try testing.expect(!sub.below);
    video.mode = .above;
    try expectDamageExact(&app);

    // Controls over the corner keep the zero-copy path: the subsurface goes
    // below the window, which is transparent over the video except for
    // the controls.
    {
        const t = try app.win.begin();
        _ = try node(t, app.win.node(.root).first, .box, .{ .width = .{ .px = 60 }, .height = .{ .px = 24 }, .inset = .{ .end = 16, .top = 30 } }, .{ .background = red, .radius = .all(12), .opacity = 0.8 });
        t.commit();
    }
    try app.settle();
    const below = subsurfaceOf(&app).?;
    try testing.expect(below.visible and below.below);
    video.mode = .below;
    try expectDamageExact(&app);
    try expectGolden(&app, "external-hole");

    // Translucent video: composited into the window.
    {
        const t = try app.win.begin();
        try t.setVisual(player, .{ .background = ink, .opacity = 0.9 });
        t.commit();
    }
    try app.settle();
    try testing.expect(!subsurfaceOf(&app).?.visible);
    video.mode = .composited;
    try expectDamageExact(&app);
    try expectGolden(&app, "external-composited");
}
