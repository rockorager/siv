//! Stock widgets (D22) and theming (D29) through the C ABI on the headless
//! backend: built with the exported builders, driven by injected input
//! and assistive technology's entry points, checked against golden images
//! under test/golden/widgets/ and the semantics tree.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const abi = @import("abi");
const ui = @import("ui");
const harness = @import("../abi/harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const Harness = harness.Harness;
const ok = harness.ok;

const ks = struct {
    const space: u32 = 0x20;
    const tab: u32 = 0xff09;
    const @"return": u32 = 0xff0d;
    const home: u32 = 0xff50;
    const left: u32 = 0xff51;
    const up: u32 = 0xff52;
    const right: u32 = 0xff53;
    const down: u32 = 0xff54;
    const end: u32 = 0xff57;
};

/// What the application's handlers saw.
const Log = struct {
    changes: u32 = 0,
    value: f64 = -100,
    index: u32 = 0,
    node: t.Node = .null,
    activations: u32 = 0,

    fn onChange(ud: ?*anyopaque, node: t.Node, ev: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        std.debug.assert(ev.?.type == .change);
        log.changes += 1;
        log.value = ev.?.value;
        log.index = ev.?.index;
        log.node = node;
        return true;
    }

    fn onActivate(ud: ?*anyopaque, _: t.Node, _: ?*const t.Event) callconv(.c) bool {
        const log: *Log = @ptrCast(@alignCast(ud.?));
        log.activations += 1;
        return true;
    }
};

fn str(s: []const u8) struct { ?[*]const u8, usize } {
    return .{ s.ptr, s.len };
}

const Controls = struct {
    button: t.Node,
    primary: t.Node,
    disabled: t.Node,
    toggle: t.Node,
    check: t.Node,
    mixed: t.Node,
    sw: t.Node,
    group: t.Node,
    radios: [3]t.Node,
};

/// Buttons, toggles, check boxes, switches, and a radio group.
fn buildControls(h: *Harness, log: *Log) !Controls {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 12, .align_items = .start });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 16, .end = 16, .top = 16, .bottom = 16 } });
    const row = c.siv_flex(txn, col, &.{ .gap = 8 });
    var out: Controls = undefined;
    out.button = c.siv_push_button(txn, row, &.{ .label = "Cancel", .label_len = 6 });
    out.primary = c.siv_push_button(txn, row, &.{ .label = "Save", .label_len = 4, .style = .primary });
    _ = c.siv_push_button(txn, row, &.{ .label = "Flat", .label_len = 4, .style = .flat });
    _ = c.siv_push_button(txn, row, &.{ .label = "Delete", .label_len = 6, .style = .destructive });
    out.disabled = c.siv_push_button(txn, row, &.{ .label = "Off", .label_len = 3, .flags = .{ .disabled = true } });
    out.toggle = c.siv_toggle_button(txn, col, &.{ .label = "Bold", .label_len = 4, .checked = .on });
    out.check = c.siv_check_box(txn, col, &.{ .label = "Remember me", .label_len = 11 });
    const checks = c.siv_flex(txn, col, &.{ .gap = 16 });
    _ = c.siv_check_box(txn, checks, &.{ .label = "On", .label_len = 2, .checked = .on });
    out.mixed = c.siv_check_box(txn, checks, &.{ .label = "Mixed", .label_len = 5, .checked = .mixed });
    _ = c.siv_check_box(txn, checks, &.{ .label = "Disabled", .label_len = 8, .flags = .{ .disabled = true } });
    const switches = c.siv_flex(txn, col, &.{ .gap = 16 });
    out.sw = c.siv_switch(txn, switches, &.{ .label = "Wi-Fi", .label_len = 5 });
    _ = c.siv_switch(txn, switches, &.{ .label = "Bluetooth", .label_len = 9, .checked = .on });
    out.group = c.siv_radio_group(txn, col, &.{ .label = "Size", .label_len = 4 });
    for (&out.radios, [_][]const u8{ "Small", "Medium", "Large" }) |*r, label| r.* = c.siv_radio(txn, out.group, label.ptr, label.len);
    for ([_]t.Node{ out.toggle, out.check, out.mixed, out.sw, out.group }) |n| _ = c.siv_on(txn, n, .change, Log.onChange, null, log);
    _ = c.siv_on(txn, out.button, .activate, Log.onActivate, null, log);
    _ = c.siv_on(txn, out.disabled, .activate, Log.onActivate, null, log);
    try ok(c.siv_txn_commit(txn));
    return out;
}

const Inputs = struct {
    field: t.Node,
    area: t.Node,
    slider: t.Node,
    spin: t.Node,
    progress: t.Node,
};

/// Text fields and areas, a slider, a spin button, and progress bars.
fn buildInputs(h: *Harness, log: *Log) !Inputs {
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    const root = c.siv_window_root(h.window);
    _ = c.siv_set_visual(txn, root, &.{ .background_token = .window_bg });
    const col = c.siv_flex(txn, root, &.{ .axis = .column, .gap = 12, .align_items = .start });
    _ = c.siv_set_layout(txn, col, &.{ .padding = .{ .start = 16, .end = 16, .top = 16, .bottom = 16 } });
    var out: Inputs = undefined;
    out.field = c.siv_text_field(txn, col, &.{ .placeholder = "Search", .placeholder_len = 6 });
    _ = c.siv_text_field(txn, col, &.{ .text = "Ada Lovelace", .text_len = 12, .label = "Name", .label_len = 4 });
    out.area = c.siv_text_field(txn, col, &.{ .placeholder = "Notes", .placeholder_len = 5, .flags = .{ .multiline = true }, .rows = 2 });
    out.slider = c.siv_slider(txn, col, &.{ .label = "Volume", .label_len = 6, .value = 30, .step = 1 });
    _ = c.siv_set_layout(txn, out.slider, &.{ .width = .{ .unit = .px, .value = 200 } });
    out.spin = c.siv_spin_button(txn, col, &.{ .label = "Copies", .label_len = 6, .min = 1, .max = 99, .value = 3 });
    out.progress = c.siv_progress_bar(txn, col, &.{ .label = "Upload", .label_len = 6, .value = 60 });
    _ = c.siv_set_layout(txn, out.progress, &.{ .width = .{ .unit = .px, .value = 200 } });
    const busy = c.siv_progress_bar(txn, col, &.{ .label = "Working", .label_len = 7, .flags = .{ .indeterminate = true } });
    _ = c.siv_set_layout(txn, busy, &.{ .width = .{ .unit = .px, .value = 200 } });
    for ([_]t.Node{ out.slider, out.spin }) |n| _ = c.siv_on(txn, n, .change, Log.onChange, null, log);
    try ok(c.siv_txn_commit(txn));
    return out;
}

fn center(n: t.Node) ![2]f64 {
    var r: t.Rect = undefined;
    try ok(c.siv_node_get_rect(n, &r));
    return .{ r.x + r.width / 2, r.y + r.height / 2 };
}

fn value(n: t.Node) !f64 {
    var v: f64 = undefined;
    try ok(c.siv_widget_get_value(n, &v));
    return v;
}

fn uiId(n: t.Node) !struct { *ui.Window, ui.NodeId } {
    const w, const id = try abi.tree.lookup(n);
    return .{ w.uiWin(), id };
}

/// The semantics node of a widget's handle.
fn sem(n: t.Node) !ui.semantics.Node {
    const uw, const id = try uiId(n);
    const tree = try uw.semanticsTree();
    for (tree.nodes.items) |s| if (s.node == id) return s;
    return error.NotInSemanticsTree;
}

fn semName(n: t.Node) ![]const u8 {
    const uw, _ = try uiId(n);
    return (try uw.semanticsTree()).name(try sem(n));
}

fn setTheme(h: *Harness, scheme: t.ColorScheme, contrast: t.Contrast) !void {
    try ok(c.siv_app_set_theme(h.app, &.{ .scheme = scheme, .contrast = contrast }));
    try h.settle();
}

test "widgets: controls in light, dark, and high contrast" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(420, 330, null, null);
    defer h.stop();
    var log: Log = .{};
    _ = try buildControls(&h, &log);
    try h.settle();
    try h.expectGolden("controls-light", 420, 330);
    try setTheme(&h, .dark, .follow);
    try h.expectGolden("controls-dark", 420, 330);
    try setTheme(&h, .light, .high);
    try h.expectGolden("controls-high-contrast", 420, 330);
}

test "widgets: inputs in light and dark" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.start(320, 400, null, null);
    defer h.stop();
    var log: Log = .{};
    _ = try buildInputs(&h, &log);
    try h.settle();
    try h.expectGolden("inputs-light", 320, 400);
    try setTheme(&h, .dark, .follow);
    try h.expectGolden("inputs-dark", 320, 400);
}

test "widgets: right to left mirrors controls and inputs" {
    var h: Harness = .{ .golden = "test/golden/widgets" };
    try h.startWith(.{ .width = 420, .height = 330, .flags = .{ .rtl = true } });
    defer h.stop();
    var log: Log = .{};
    const w = try buildControls(&h, &log);
    try h.settle();
    try h.expectGolden("controls-rtl", 420, 330);
    // The switch's knob slides toward the start, which is on the left.
    try h.click((try center(w.sw))[0], (try center(w.sw))[1]);
    try h.settle();
    const uw, const sw = try uiId(w.sw);
    const knob = uw.node(uw.node(sw).first).first;
    try testing.expectEqual(@as(f32, -16), uw.node(knob).visual.transform.translate.x);
}

test "widgets: semantics of every control" {
    var h: Harness = .{};
    try h.start(420, 330, null, null);
    defer h.stop();
    var log: Log = .{};
    const w = try buildControls(&h, &log);
    try h.settle();
    const button = try sem(w.button);
    try testing.expectEqual(ui.Role.button, button.role);
    try testing.expectEqualStrings("Cancel", try semName(w.button));
    try testing.expect(button.focusable and button.actionable);
    const off = try sem(w.disabled);
    try testing.expect(off.disabled and !off.focusable and !off.actionable);
    try testing.expectEqual(ui.Toggle.on, (try sem(w.toggle)).pressed);
    try testing.expectEqual(ui.Role.toggle_button, (try sem(w.toggle)).role);
    const check = try sem(w.check);
    try testing.expectEqual(ui.Role.checkbox, check.role);
    try testing.expectEqualStrings("Remember me", try semName(w.check));
    try testing.expectEqual(ui.Toggle.off, check.checked);
    try testing.expectEqual(ui.Toggle.mixed, (try sem(w.mixed)).checked);
    try testing.expectEqual(ui.Role.@"switch", (try sem(w.sw)).role);
    try testing.expectEqualStrings("Wi-Fi", try semName(w.sw));
    const group = try sem(w.group);
    try testing.expectEqual(ui.Role.group, group.role);
    try testing.expectEqualStrings("Size", try semName(w.group));
    for (w.radios, [_]ui.Toggle{ .on, .off, .off }, [_]bool{ true, false, false }) |r, checked, stop| {
        const s = try sem(r);
        try testing.expectEqual(ui.Role.radio, s.role);
        try testing.expectEqual(checked, s.checked);
        // Roving focus: only the selected radio is a Tab stop.
        try testing.expectEqual(stop, s.focusable);
        try testing.expectEqual(s.parent, @as(u32, @intCast(blk: {
            const uw, const gid = try uiId(w.group);
            const tree = try uw.semanticsTree();
            for (tree.nodes.items, 0..) |n, i| if (n.node == gid) break :blk i;
            unreachable;
        })));
    }
}

test "widgets: pointer, keyboard, and overrides on toggles" {
    var h: Harness = .{};
    try h.start(420, 330, null, null);
    defer h.stop();
    var log: Log = .{};
    const w = try buildControls(&h, &log);
    try h.settle();

    // A click flips the check box and reports the new value.
    const cc = try center(w.check);
    try h.click(cc[0], cc[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.changes);
    try testing.expectEqual(@as(f64, 1), log.value);
    try testing.expectEqual(w.check, log.node);
    try testing.expectEqual(@as(f64, 1), try value(w.check));
    try testing.expectEqual(ui.Toggle.on, (try sem(w.check)).checked);
    // Space on the focused check box flips it back.
    try h.typeKey(ks.space, "", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 0), try value(w.check));
    try testing.expectEqual(@as(u32, 2), log.changes);
    // Mixed becomes on.
    try ok(c.siv_node_focus(w.mixed));
    try h.typeKey(ks.space, "", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 1), try value(w.mixed));
    // A toggle button and a switch.
    const tc = try center(w.toggle);
    try h.click(tc[0], tc[1]);
    try h.settle();
    try testing.expectEqual(@as(f64, 0), try value(w.toggle));
    try testing.expectEqual(ui.Toggle.off, (try sem(w.toggle)).pressed);
    const sc = try center(w.sw);
    try h.click(sc[0], sc[1]);
    try h.settle();
    try testing.expectEqual(@as(f64, 1), try value(w.sw));
    try testing.expectEqual(ui.Toggle.on, (try sem(w.sw)).checked);

    // Buttons activate; disabled ones do nothing and are skipped by Tab.
    const bc = try center(w.button);
    try h.click(bc[0], bc[1]);
    const dc = try center(w.disabled);
    try h.click(dc[0], dc[1]);
    try h.settle();
    try testing.expectEqual(@as(u32, 1), log.activations);
    // Save, then Flat, Delete, and (skipping Off) the toggle button.
    try ok(c.siv_node_focus(w.primary));
    for (0..3) |_| try h.typeKey(ks.tab, "", .{});
    try h.settle();
    const uw, const toggle_id = try uiId(w.toggle);
    try testing.expectEqual(toggle_id, uw.input.focus);

    // The application's handler runs first: returning true from it keeps
    // the widget from toggling.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    _ = c.siv_on(txn, w.check, .activate, Log.onActivate, null, &log);
    try ok(c.siv_txn_commit(txn));
    const before = log.changes;
    try h.click(cc[0], cc[1]);
    try h.settle();
    try testing.expectEqual(before, log.changes);
    try testing.expectEqual(@as(f64, 0), try value(w.check));
    try testing.expectEqual(@as(u32, 2), log.activations);

    // Values set by the application are not reported.
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_widget_set_value(txn, w.sw, 0));
    try ok(c.siv_widget_set_value(txn, w.mixed, 0.5));
    try ok(c.siv_txn_commit(txn));
    try h.settle();
    try testing.expectEqual(before, log.changes);
    try testing.expectEqual(ui.Toggle.mixed, (try sem(w.mixed)).checked);
    try testing.expectEqual(@as(f64, 0), try value(w.sw));
}

test "widgets: radio groups move the selection with arrows, mirrored in RTL" {
    for ([_]bool{ false, true }) |rtl| {
        var h: Harness = .{};
        try h.startWith(.{ .width = 420, .height = 330, .flags = .{ .rtl = rtl } });
        defer h.stop();
        var log: Log = .{};
        const w = try buildControls(&h, &log);
        try h.settle();
        try ok(c.siv_node_focus(w.radios[0]));
        try h.typeKey(ks.right, "", .{});
        try h.settle();
        // Right is forward in LTR and backward (wrapping) in RTL.
        const want: u32 = if (rtl) 2 else 1;
        try testing.expectEqual(@as(u32, 1), log.changes);
        try testing.expectEqual(want, log.index);
        try testing.expectEqual(@as(f64, @floatFromInt(want)), log.value);
        try testing.expectEqual(w.group, log.node);
        const uw, const id = try uiId(w.radios[want]);
        try testing.expectEqual(id, uw.input.focus);
        try testing.expectEqual(ui.Toggle.on, (try sem(w.radios[want])).checked);
        try testing.expect(!(try sem(w.radios[0])).focusable);
        // Down is forward either way; a click selects too.
        try h.typeKey(ks.down, "", .{});
        try h.settle();
        try testing.expectEqual((want + 1) % 3, log.index);
        const rc = try center(w.radios[1]);
        try h.click(rc[0], rc[1]);
        try h.settle();
        try testing.expectEqual(@as(f64, 1), try value(w.group));
        // Cleared by the application: no radio is checked, the first is the
        // Tab stop.
        var txn: t.Txn = .null;
        try ok(c.siv_txn_begin(h.window, &txn));
        try ok(c.siv_widget_set_value(txn, w.group, -1));
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        try testing.expectEqual(@as(f64, -1), try value(w.group));
        try testing.expect((try sem(w.radios[0])).focusable);
        for (w.radios) |r| try testing.expectEqual(ui.Toggle.off, (try sem(r)).checked);
    }
}

test "widgets: sliders follow keys, the pointer, and assistive technology" {
    for ([_]bool{ false, true }) |rtl| {
        var h: Harness = .{};
        try h.startWith(.{ .width = 320, .height = 400, .flags = .{ .rtl = rtl } });
        defer h.stop();
        var log: Log = .{};
        const w = try buildInputs(&h, &log);
        try h.settle();
        const s = try sem(w.slider);
        try testing.expectEqual(ui.Role.slider, s.role);
        try testing.expectEqualStrings("Volume", try semName(w.slider));
        try testing.expectEqual(ui.Range{ .min = 0, .max = 100, .now = 30, .step = 1 }, s.value.?);
        try ok(c.siv_node_focus(w.slider));
        try h.typeKey(ks.right, "", .{});
        try h.settle();
        try testing.expectEqual(@as(f64, if (rtl) 29 else 31), try value(w.slider));
        try testing.expectEqual(@as(f64, if (rtl) 29 else 31), log.value);
        try h.typeKey(ks.up, "", .{});
        try h.settle();
        try testing.expectEqual(@as(f64, if (rtl) 30 else 32), try value(w.slider));
        try h.typeKey(ks.end, "", .{});
        try h.settle();
        try testing.expectEqual(@as(f64, 100), try value(w.slider));
        try testing.expectEqual(@as(f64, 100), (try sem(w.slider)).value.?.now);
        // A press three quarters along the track (from the start edge).
        var r: t.Rect = undefined;
        try ok(c.siv_node_get_rect(w.slider, &r));
        const span = r.width - 18;
        const x = if (rtl) r.x + 9 + span * 0.25 else r.x + 9 + span * 0.75;
        try h.click(x, r.y + r.height / 2);
        try h.settle();
        try testing.expectEqual(@as(f64, 75), try value(w.slider));
        // Assistive technology sets a value; the slider steps and clamps it.
        const changes = log.changes;
        const uw, const id = try uiId(w.slider);
        try testing.expect(ui.input.setValue(uw, id, 42.4));
        try h.settle();
        try testing.expectEqual(@as(f64, 42), try value(w.slider));
        try testing.expectEqual(changes + 1, log.changes);
        try testing.expect(ui.input.setValue(uw, id, 1000));
        try h.settle();
        try testing.expectEqual(@as(f64, 100), try value(w.slider));
        // Disabled: neither keys nor assistive technology change it.
        var txn: t.Txn = .null;
        try ok(c.siv_txn_begin(h.window, &txn));
        try ok(c.siv_widget_set_disabled(txn, w.slider, true));
        try ok(c.siv_txn_commit(txn));
        try h.settle();
        try testing.expect(!ui.input.setValue(uw, id, 10));
        try testing.expect(!(try sem(w.slider)).focusable);
        try testing.expectEqual(@as(f64, 100), try value(w.slider));
    }
}

test "widgets: spin buttons step, page, and parse what was typed" {
    var h: Harness = .{};
    try h.start(320, 400, null, null);
    defer h.stop();
    var log: Log = .{};
    const w = try buildInputs(&h, &log);
    try h.settle();
    const field = blk: {
        var f: t.Node = .null;
        try ok(c.siv_node_get_related(w.spin, .first_child, &f));
        break :blk f;
    };
    const s = try sem(field);
    try testing.expectEqual(ui.Role.spin_button, s.role);
    try testing.expectEqualStrings("Copies", try semName(field));
    try testing.expectEqual(ui.Range{ .min = 1, .max = 99, .now = 3, .step = 1 }, s.value.?);
    try ok(c.siv_node_focus(field));
    try h.typeKey(ks.up, "", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 4), try value(w.spin));
    try testing.expectEqual(w.spin, log.node);
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_node_get_text(field, &buf, buf.len, &len));
    try testing.expectEqualStrings("4", buf[0..len]);
    // Type 250 over the text, press Enter: clamped to 99.
    var txn: t.Txn = .null;
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_selection(txn, field, 1, 0));
    try ok(c.siv_txn_commit(txn));
    for ("250") |ch| try h.typeKey(ch, &.{ch}, .{});
    try h.typeKey(ks.@"return", "", .{});
    try h.settle();
    try testing.expectEqual(@as(f64, 99), try value(w.spin));
    try ok(c.siv_node_get_text(field, &buf, buf.len, &len));
    try testing.expectEqualStrings("99", buf[0..len]);
    // Garbage puts the value back when the field loses focus.
    try ok(c.siv_txn_begin(h.window, &txn));
    try ok(c.siv_set_selection(txn, field, 2, 0));
    try ok(c.siv_txn_commit(txn));
    try h.typeKey('x', "x", .{});
    try h.typeKey(ks.tab, "", .{});
    try h.settle();
    try ok(c.siv_node_get_text(field, &buf, buf.len, &len));
    try testing.expectEqualStrings("99", buf[0..len]);
    // The decrement button.
    var dec: t.Node = .null;
    try ok(c.siv_node_get_related(field, .next, &dec));
    const dc = try center(dec);
    try h.click(dc[0], dc[1]);
    try h.settle();
    try testing.expectEqual(@as(f64, 98), try value(w.spin));
}

test "widgets: text fields are editors with placeholders and themed frames" {
    var h: Harness = .{};
    try h.start(320, 400, null, null);
    defer h.stop();
    var log: Log = .{};
    const w = try buildInputs(&h, &log);
    try h.settle();
    const s = try sem(w.field);
    try testing.expectEqual(ui.Role.text_input, s.role);
    try testing.expectEqualStrings("Search", try semName(w.field));
    try testing.expectEqualStrings("Search", s.placeholder);
    const fc = try center(w.field);
    try h.click(fc[0], fc[1]);
    try h.typeKey('h', "h", .{});
    try h.typeKey('i', "i", .{});
    try h.settle();
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    try ok(c.siv_node_get_text(w.field, &buf, buf.len, &len));
    try testing.expectEqualStrings("hi", buf[0..len]);
    const uw, const id = try uiId(w.field);
    try testing.expectEqual(ui.ColorToken.accent, uw.node(id).visual.border_token);
    try testing.expectEqual(ui.Role.progress_bar, (try sem(w.progress)).role);
    try testing.expectEqual(@as(f64, 60), (try sem(w.progress)).value.?.now);
}

test "theme: overrides, derived accents, and resolved colors" {
    var h: Harness = .{};
    try h.start(100, 100, null, null);
    defer h.stop();
    var col: t.Color = undefined;
    try ok(c.siv_window_get_color(h.window, .window_bg, &col));
    try testing.expectApproxEqAbs(@as(f32, 0xfa) / 255, col.r, 1e-3);
    try setTheme(&h, .dark, .follow);
    try ok(c.siv_window_get_color(h.window, .window_bg, &col));
    try testing.expectApproxEqAbs(@as(f32, 0x18) / 255, col.r, 1e-3);
    // An accent override moves the derived colors in every variant.
    try ok(c.siv_app_set_theme_color(h.app, .all, .accent, .{ .r = 1, .g = 0.8, .b = 0, .a = 1 }));
    try ok(c.siv_window_get_color(h.window, .focus_ring, &col));
    try testing.expectApproxEqAbs(@as(f32, 0.8), col.g, 1e-3);
    try ok(c.siv_window_get_color(h.window, .accent_fg, &col));
    try testing.expectEqual(@as(f32, 0), col.r);
    // A zero color removes the override.
    try ok(c.siv_app_set_theme_color(h.app, .all, .accent, .{ .r = 0, .g = 0, .b = 0, .a = 0 }));
    try ok(c.siv_window_get_color(h.window, .accent_fg, &col));
    try testing.expectApproxEqAbs(@as(f32, 1), col.r, 1e-5);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_window_get_color(h.window, .none, &col));
    try testing.expectEqual(t.Result.error_unsupported, c.siv_app_set_theme(h.app, &.{ .scheme = @fromBackingInt(9) }));
}
