//! A window for the bridge's tests: a real ui.Window on the test fonts
//! with one node of each kind the bridge treats specially.

const std = @import("std");
const ui = @import("ui");
const text = @import("text");

const NodeId = ui.NodeId;
const Fixture = @This();

fonts: ui.Fonts,
win: *ui.Window,
nodes: Nodes,
clicks: usize = 0,

pub const Nodes = struct { button: NodeId, label: NodeId, editor: NodeId, check: NodeId, slider: NodeId, status: NodeId, status_text: NodeId, list: NodeId };

fn sinkCommit(_: ?*anyopaque, _: @typeInfo(@typeInfo(@FieldType(ui.Sink, "commit")).pointer.child).@"fn".param_types[1].?) error{OutOfMemory}!u64 {
    return 1;
}

pub fn init(f: *Fixture, gpa: std.mem.Allocator) !void {
    f.* = .{ .fonts = try .init(gpa), .win = undefined, .nodes = undefined };
    errdefer f.fonts.deinit();
    const tf = text.font.test_fonts;
    const chain = [_]text.FontId{try f.fonts.cache.add(tf.latin, 0, .borrowed)};
    try f.fonts.register("Droid", &chain);
    try f.fonts.setDefault("Droid");
    f.win = try ui.Window.init(gpa, .{ .fonts = &f.fonts, .sink = .{ .ctx = null, .commit = sinkCommit }, .width = 400, .height = 300 });
    errdefer f.win.deinit();
    try f.buildTree();
}

pub fn deinit(f: *Fixture) void {
    f.win.deinit();
    f.fonts.deinit();
}

fn onActivate(user: ?*anyopaque, _: *ui.Window, _: NodeId, ev: *const ui.Event) ui.HandlerResult {
    const self: *Fixture = @ptrCast(@alignCast(user));
    if (ev.* == .activate) self.clicks += 1;
    return .handled;
}

fn buildTree(f: *Fixture) !void {
    const t = try f.win.begin();
    const col = try t.create(.root, .flex, .none);
    try t.setFlex(col, .{ .axis = .column, .gap = 4 });
    const button = try t.create(col, .box, .none);
    try t.setSemantics(button, .{ .role = .button, .focusable = true });
    try t.on(button, .activate, .{ .func = onActivate, .user = f });
    const ok = try t.create(button, .text, .none);
    try t.setText(ok, "OK");
    const label = try t.create(col, .text, .none);
    try t.setText(label, "Hello wörld. Second sentence.");
    const editor = try t.create(col, .editor, .none);
    try t.setText(editor, "abc");
    try t.setSemantics(editor, .{ .label = "Name" });
    const check = try t.create(col, .box, .none);
    try t.setSemantics(check, .{ .role = .checkbox, .label = "Remember", .focusable = true, .checked = .off });
    const slider = try t.create(col, .box, .none);
    try t.setSemantics(slider, .{ .role = .slider, .label = "Volume", .value = .{ .min = 0, .max = 10, .now = 3 } });
    const status = try t.create(col, .box, .none);
    try t.setSemantics(status, .{ .role = .status, .live = .polite });
    const status_text = try t.create(status, .text, .none);
    try t.setText(status_text, "Ready");
    const list = try t.create(col, .box, .none);
    try t.setSemantics(list, .{ .role = .list });
    for ([_][]const u8{ "One", "Two" }, 0..) |name, i| {
        const item = try t.create(list, .box, .none);
        try t.setSemantics(item, .{ .role = .list_item, .label = name, .selected = if (i == 1) .on else .off });
        try t.on(item, .activate, .{ .func = onActivate, .user = f });
    }
    t.commit();
    try f.win.frame();
    f.nodes = .{ .button = button, .label = label, .editor = editor, .check = check, .slider = slider, .status = status, .status_text = status_text, .list = list };
}
