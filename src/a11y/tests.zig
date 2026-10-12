//! Bridge tests against dbus's in-process test bus: a stand-in registry,
//! an assistive technology client, and a real ui.Window on the test fonts.

const std = @import("std");
const testing = std.testing;
const dbus = @import("dbus");
const ui = @import("ui");
const text = @import("text");
const Loop = @import("loop").Loop;
const Bridge = @import("Bridge.zig");
const atspi = @import("atspi.zig");
const Fixture = @import("test_fixture.zig");

const Connection = dbus.Connection;
const TestBus = dbus.testing.TestBus;
const NodeId = ui.NodeId;
const gpa = testing.allocator;

/// Answers Socket.Embed like at-spi2-registryd.
const Registry = struct {
    conn: Connection = undefined,
    owner: Connection.NameOwner = .{ .name = atspi.registry_name },
    obj: dbus.Object = undefined,
    embedded: usize = 0,

    const socket: dbus.Interface = .{
        .name = atspi.iface.socket,
        .methods = &.{.{ .name = "Embed", .in = "(so)", .out = "(so)", .func = embed }},
    };

    fn embed(r: *dbus.Request) anyerror!void {
        const self: *Registry = @ptrCast(@alignCast(r.node.ctx));
        self.embedded += 1;
        try r.reply(.{.{ self.conn.uniqueName(), dbus.ObjectPath{ .path = atspi.root_path } }});
    }
};

/// Records events from the bridge.
const Events = struct {
    sub: Connection.Subscription = .{ .rule = .{ .path_namespace = atspi.accessible_prefix }, .func = cb },
    log: std.ArrayList(u8) = .empty,

    fn cb(s: *Connection.Subscription, m: *const dbus.Message) void {
        const self: *Events = @fieldParentPtr("sub", s);
        if (!std.mem.eql(u8, m.signature, "siiva{sv}")) return;
        var d = m.body();
        const detail = d.readString() catch return;
        const d1 = d.readInt32() catch return;
        _ = d.readInt32() catch return;
        const vs = d.beginVariant() catch return;
        var buf: [256]u8 = undefined;
        const any = if (std.mem.eql(u8, vs, "s")) d.readString() catch "" else if (std.mem.eql(u8, vs, "(so)")) blk: {
            const r = d.read(struct { []const u8, dbus.ObjectPath }) catch break :blk "";
            break :blk r[1].path[r[1].path.len - @min(r[1].path.len, 8) ..];
        } else "";
        const line = std.fmt.bufPrint(&buf, "{s}:{s}:{d}:{s}\n", .{ m.member.?, detail, d1, any }) catch return;
        self.log.appendSlice(gpa, line) catch {};
    }

    fn has(self: *const Events, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.log.items, needle) != null;
    }
};

const Harness = struct {
    loop: Loop,
    bus: TestBus,
    registry: Registry = .{},
    at: Connection = undefined,
    bridge: Bridge = undefined,
    fx: Fixture,
    win: *ui.Window,
    nodes: Fixture.Nodes,
    events: Events = .{},
    wid: Bridge.WindowId = 0,

    fn init(h: *Harness) !void {
        h.* = .{ .loop = try Loop.init(gpa), .bus = undefined, .fx = undefined, .win = undefined, .nodes = undefined };
        h.bus = .init(gpa, &h.loop);
        try h.fx.init(gpa);
        h.win = h.fx.win;
        h.nodes = h.fx.nodes;

        try h.registry.conn.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        h.registry.obj = .{ .path = atspi.root_path, .ctx = &h.registry, .interfaces = &.{&Registry.socket} };
        try h.registry.conn.exportObject(&h.registry.obj);
        try h.registry.conn.requestName(&h.registry.owner);
        try h.at.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        try h.at.subscribe(&h.events.sub);

        h.bridge.init(gpa, &h.loop, .{ .app_name = "a11y-test", .toolkit_version = "0.1" });
        h.wid = try h.bridge.addWindow(h.win, "Test window");
        try h.bridge.connectFd(try h.bus.connect());
        try h.until(&h.bridge, struct {
            fn f(b: *Bridge) bool {
                return b.active() and b.embed_call == 0;
            }
        }.f);
    }

    fn deinit(h: *Harness) void {
        h.bridge.deinit();
        h.at.unsubscribe(&h.events.sub);
        h.events.log.deinit(gpa);
        h.at.deinit();
        h.registry.conn.deinit();
        h.fx.deinit();
        h.bus.deinit();
        h.loop.deinit();
    }

    fn until(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + 2 * std.time.ns_per_s;
        while (!cond(ctx)) {
            if (Loop.now() > deadline) return error.TestTimeout;
            try h.loop.dispatch(50);
        }
    }

    fn settle(h: *Harness) !void {
        for (0..20) |_| try h.loop.dispatch(2);
    }

    /// A frame of the window followed by the bridge's update, as the
    /// application does.
    fn frame(h: *Harness) !void {
        try h.win.frame();
        try h.bridge.update(h.wid);
        try h.settle();
    }

    fn path(h: *Harness, id: NodeId, buf: []u8) []const u8 {
        const w = h.bridge.window(h.wid).?;
        const i = w.cur.index.get(id.index()).?;
        return w.path(buf, i);
    }

    /// Calls a method and returns the reply's body for `read`.
    fn call(h: *Harness, path_: []const u8, iface: []const u8, member: []const u8, args: anytype) !Reply {
        var r: Reply = .{};
        _ = try h.at.callMethod(h.bridge.conn.?.uniqueName(), path_, iface, member, args, Reply.cb, &r);
        try h.until(&r, Reply.isDone);
        if (r.err != null) return error.CallFailed;
        return r;
    }

    fn get(h: *Harness, path_: []const u8, iface: []const u8, prop: []const u8) !Reply {
        return h.call(path_, "org.freedesktop.DBus.Properties", "Get", .{ iface, prop });
    }
};

/// A reply's body, copied.
const Reply = struct {
    done: bool = false,
    err: ?[128]u8 = null,
    err_len: usize = 0,
    data: [8192]u8 align(8) = undefined,
    len: usize = 0,
    sig: [64]u8 = undefined,
    sig_len: usize = 0,

    fn cb(ctx: ?*anyopaque, reply: Connection.Reply) void {
        const r: *Reply = @ptrCast(@alignCast(ctx));
        r.done = true;
        switch (reply) {
            .ok => |m| {
                const body = m.bodyBytes();
                @memcpy(r.data[0..body.len], body);
                r.len = body.len;
                @memcpy(r.sig[0..m.signature.len], m.signature);
                r.sig_len = m.signature.len;
            },
            .err => |m| {
                r.err = undefined;
                const n = @min(m.error_name.?.len, 128);
                @memcpy(r.err.?[0..n], m.error_name.?[0..n]);
                r.err_len = n;
            },
            .failed => r.err = @splat('?'),
        }
    }

    fn isDone(r: *Reply) bool {
        return r.done;
    }

    fn decoder(r: *const Reply) dbus.Decoder {
        return .init(r.data[0..r.len], r.sig[0..r.sig_len], .little, &.{});
    }

    /// Reads a reply of top-level values `T`, or the value inside a
    /// property's variant.
    fn read(r: *const Reply, comptime T: type) !T {
        var d = r.decoder();
        if (std.mem.eql(u8, r.sig[0..r.sig_len], "v")) {
            _ = try d.beginVariant();
            return d.read(T);
        }
        return d.read(T);
    }

    /// Reads several top-level values.
    fn args(r: *const Reply, comptime T: type) !T {
        var d = r.decoder();
        return d.readAll(T);
    }
};

const Ref = struct { []const u8, dbus.ObjectPath };

test "the tree, its roles, names, states, and interfaces" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expectEqual(@as(usize, 1), h.registry.embedded);

    // The application root and its one window.
    try testing.expectEqualStrings("a11y-test", try (try h.get(atspi.root_path, atspi.iface.accessible, "Name")).read([]const u8));
    try testing.expectEqual(@as(u32, 75), try (try h.call(atspi.root_path, atspi.iface.accessible, "GetRole", .{})).read(u32));
    const parent = try (try h.get(atspi.root_path, atspi.iface.accessible, "Parent")).read(Ref);
    try testing.expectEqualStrings(h.registry.conn.uniqueName(), parent[0]);
    try testing.expectEqualStrings("0.1", try (try h.get(atspi.root_path, atspi.iface.application, "Version")).read([]const u8));

    var children = try h.call(atspi.root_path, atspi.iface.accessible, "GetChildren", .{});
    var d = children.decoder();
    const arr = try d.beginArray();
    try testing.expect(arr.next(&d));
    const frame_path = (try d.read(Ref))[1].path;
    var frame_buf: [96]u8 = undefined;
    @memcpy(frame_buf[0..frame_path.len], frame_path);
    const fp = frame_buf[0..frame_path.len];
    try testing.expect(!arr.next(&d));
    try testing.expectEqual(@as(u32, 23), try (try h.call(fp, atspi.iface.accessible, "GetRole", .{})).read(u32));
    try testing.expectEqualStrings("Test window", try (try h.get(fp, atspi.iface.accessible, "Name")).read([]const u8));
    const fparent = try (try h.get(fp, atspi.iface.accessible, "Parent")).read(Ref);
    try testing.expectEqualStrings(atspi.root_path, fparent[1].path);

    var buf: [96]u8 = undefined;
    const cases = [_]struct { NodeId, u32, []const u8 }{
        .{ h.nodes.button, 43, "OK" },
        .{ h.nodes.label, 29, "Hello wörld. Second sentence." },
        .{ h.nodes.editor, 79, "Name" },
        .{ h.nodes.check, 7, "Remember" },
        .{ h.nodes.slider, 51, "Volume" },
        .{ h.nodes.status, 54, "Ready" },
        .{ h.nodes.list, 31, "" },
    };
    for (cases) |c| {
        const p = h.path(c[0], &buf);
        try testing.expectEqual(c[1], try (try h.call(p, atspi.iface.accessible, "GetRole", .{})).read(u32));
        try testing.expectEqualStrings(c[2], try (try h.get(p, atspi.iface.accessible, "Name")).read([]const u8));
    }

    // States: two words of bits.
    const check_states = try h.call(h.path(h.nodes.check, &buf), atspi.iface.accessible, "GetState", .{});
    var sd = check_states.decoder();
    const words = try sd.readFixedArray();
    const lo = std.mem.readInt(u32, words[0..4], .little);
    const hi = std.mem.readInt(u32, words[4..8], .little);
    const s: atspi.States = .{ .bits = lo | @as(u64, hi) << 32 };
    try testing.expect(s.has(.checkable) and s.has(.focusable) and s.has(.enabled) and !s.has(.checked));

    // Interfaces follow the node.
    const ifaces = try h.call(h.path(h.nodes.editor, &buf), atspi.iface.accessible, "GetInterfaces", .{});
    var id = ifaces.decoder();
    const ia = try id.beginArray();
    var names: [8][]const u8 = undefined;
    var n: usize = 0;
    while (ia.next(&id)) : (n += 1) names[n] = try id.readString();
    try testing.expectEqualStrings("org.a11y.atspi.Text", names[2]);
    try testing.expectEqualStrings("org.a11y.atspi.EditableText", names[3]);
    try testing.expectEqual(@as(f64, 3), try (try h.get(h.path(h.nodes.slider, &buf), atspi.iface.value, "CurrentValue")).read(f64));
    try testing.expectEqual(@as(i32, 1), try (try h.get(h.path(h.nodes.list, &buf), atspi.iface.selection, "NSelectedChildren")).read(i32));
}

test "actions, focus, text, and editing reach the window" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var buf: [96]u8 = undefined;

    try testing.expectEqualStrings("click", try (try h.call(h.path(h.nodes.button, &buf), atspi.iface.action, "GetName", .{@as(i32, 0)})).read([]const u8));
    try testing.expect(try (try h.call(h.path(h.nodes.button, &buf), atspi.iface.action, "DoAction", .{@as(i32, 0)})).read(bool));
    try testing.expectEqual(@as(usize, 1), h.fx.clicks);
    try testing.expect(try (try h.call(h.path(h.nodes.list, &buf), atspi.iface.selection, "SelectChild", .{@as(i32, 0)})).read(bool));
    try testing.expectEqual(@as(usize, 2), h.fx.clicks);

    try testing.expect(try (try h.call(h.path(h.nodes.check, &buf), atspi.iface.component, "GrabFocus", .{})).read(bool));
    try testing.expectEqual(h.nodes.check, h.win.input.focus);
    try testing.expect(!try (try h.call(h.path(h.nodes.slider, &buf), atspi.iface.component, "GrabFocus", .{})).read(bool));

    const label = h.path(h.nodes.label, &buf);
    try testing.expectEqualStrings("wörld", try (try h.call(label, atspi.iface.text, "GetText", .{ @as(i32, 6), @as(i32, 11) })).read([]const u8));
    const word = try (try h.call(label, atspi.iface.text, "GetStringAtOffset", .{ @as(i32, 8), @as(u32, 1) })).args(struct { []const u8, i32, i32 });
    try testing.expectEqualStrings("wörld. ", word[0]);
    try testing.expectEqual(@as(i32, 6), word[1]);
    const sentence = try (try h.call(label, atspi.iface.text, "GetTextAfterOffset", .{ @as(i32, 2), @as(u32, 3) })).args(struct { []const u8, i32, i32 });
    try testing.expectEqualStrings("Second sentence.", sentence[0]);
    // Character extents come from the layout: later characters are to the
    // right, within the node's bounds.
    const e0 = try (try h.call(label, atspi.iface.text, "GetCharacterExtents", .{ @as(i32, 0), @as(u32, 1) })).args(struct { i32, i32, i32, i32 });
    const e5 = try (try h.call(label, atspi.iface.text, "GetCharacterExtents", .{ @as(i32, 5), @as(u32, 1) })).args(struct { i32, i32, i32, i32 });
    try testing.expect(e5[0] > e0[0] and e0[2] > 0 and e0[3] > 0);
    const at = try (try h.call(label, atspi.iface.text, "GetOffsetAtPoint", .{ e5[0] + 1, e5[1] + 1, @as(u32, 1) })).read(i32);
    try testing.expectEqual(@as(i32, 5), at);

    // Styled ranges are text attributes, by character offsets: "wörld" is
    // bytes 6..12, characters 6..11.
    var t = try h.win.begin();
    try t.setSpans(h.nodes.label, &.{.{ .start = 6, .end = 12, .style = .{ .weight = .bold, .underline = true } }});
    t.commit();
    const Run = struct {
        keys: [4][]const u8 = undefined,
        values: [4][]const u8 = undefined,
        count: usize = 0,
        range: [2]i32 = .{ 0, 0 },

        fn of(reply: anytype) !@This() {
            var out: @This() = .{};
            var rd = reply.decoder();
            const attrs = try rd.beginArray();
            while (attrs.next(&rd)) : (out.count += 1) {
                try rd.beginDictEntry();
                out.keys[out.count] = try rd.readString();
                out.values[out.count] = try rd.readString();
                try rd.endDictEntry();
            }
            try rd.endArray(attrs);
            out.range = .{ try rd.readInt32(), try rd.readInt32() };
            return out;
        }
    };
    var styled_reply = try h.call(label, atspi.iface.text, "GetAttributeRun", .{ @as(i32, 8), false });
    const styled = try Run.of(&styled_reply);
    try testing.expectEqual(@as(usize, 2), styled.count);
    try testing.expectEqualStrings("weight", styled.keys[0]);
    try testing.expectEqualStrings("700", styled.values[0]);
    try testing.expectEqualStrings("underline", styled.keys[1]);
    try testing.expectEqualStrings("single", styled.values[1]);
    try testing.expectEqual([2]i32{ 6, 11 }, styled.range);
    // Before it, the unstyled stretch has none.
    var plain_reply = try h.call(label, atspi.iface.text, "GetAttributes", .{@as(i32, 1)});
    const plain = try Run.of(&plain_reply);
    try testing.expectEqual(@as(usize, 0), plain.count);
    try testing.expectEqual([2]i32{ 0, 6 }, plain.range);

    const ed = h.path(h.nodes.editor, &buf);
    try testing.expectEqual(@as(i32, 3), try (try h.get(ed, atspi.iface.text, "CharacterCount")).read(i32));
    try testing.expect(try (try h.call(ed, atspi.iface.editable_text, "InsertText", .{ @as(i32, 1), "XYZ", @as(i32, 2) })).read(bool));
    try testing.expectEqualStrings("aXYbc", h.win.node(h.nodes.editor).data.editor.text.content);
    try testing.expect(try (try h.call(ed, atspi.iface.text, "SetSelection", .{ @as(i32, 0), @as(i32, 1), @as(i32, 3) })).read(bool));
    try testing.expectEqual(@as(u32, 3), h.win.node(h.nodes.editor).data.editor.caret);
    try testing.expectEqual(@as(u32, 1), h.win.node(h.nodes.editor).data.editor.anchor);
}

test "changes become events" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.settle();
    h.events.log.clearRetainingCapacity();

    var t = try h.win.begin();
    try t.setSemantics(h.nodes.check, .{ .role = .checkbox, .label = "Remember me", .focusable = true, .checked = .on });
    try t.setText(h.nodes.status_text, "Saved");
    try t.setSemantics(h.nodes.slider, .{ .role = .slider, .label = "Volume", .value = .{ .min = 0, .max = 10, .now = 7 } });
    t.commit();
    ui.input.setFocus(h.win, h.nodes.editor, true);
    try h.frame();
    for ([_][]const u8{
        "StateChanged:checked:1:",
        "PropertyChange:accessible-name:0:Remember me",
        "PropertyChange:accessible-value:0:",
        "Announcement::1:Saved",
        "StateChanged:focused:1:",
    }) |want| if (!h.events.has(want)) {
        std.debug.print("missing {s} in\n{s}", .{ want, h.events.log.items });
        return error.TestExpectedEqual;
    };

    // Text and caret.
    h.events.log.clearRetainingCapacity();
    try ui.access.replaceText(h.win, h.nodes.editor, 3, 3, "de");
    try h.frame();
    try testing.expect(h.events.has("TextChanged:insert:3:de"));
    try testing.expect(h.events.has("TextCaretMoved::5:"));

    // A removed node: the parent reports it and its path dies.
    var buf: [96]u8 = undefined;
    var old: [96]u8 = undefined;
    const old_path = h.path(h.nodes.button, &old);
    h.events.log.clearRetainingCapacity();
    t = try h.win.begin();
    try t.remove(h.nodes.button);
    t.commit();
    try h.frame();
    try testing.expect(h.events.has("ChildrenChanged:remove:0:"));
    try testing.expectError(error.CallFailed, h.call(old_path, atspi.iface.accessible, "GetRole", .{}));
    // Added nodes are reported with their index.
    h.events.log.clearRetainingCapacity();
    t = try h.win.begin();
    const fresh = try t.create(.root, .box, .none);
    try t.setSemantics(fresh, .{ .role = .button, .label = "New", .focusable = true });
    t.commit();
    try h.frame();
    try testing.expect(h.events.has("ChildrenChanged:add:"));
    try testing.expectEqualStrings("New", try (try h.get(h.path(fresh, &buf), atspi.iface.accessible, "Name")).read([]const u8));
}

test "window activation and titles" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.events.log.clearRetainingCapacity();
    h.bridge.setActive(h.wid, true);
    try h.bridge.setTitle(h.wid, "Renamed");
    try h.settle();
    try testing.expect(h.events.has("Activate::0:"));
    try testing.expect(h.events.has("StateChanged:active:1:"));
    try testing.expect(h.events.has("PropertyChange:accessible-name:0:Renamed"));
    h.bridge.removeWindow(h.wid);
    try h.settle();
    try testing.expect(h.events.has("ChildrenChanged:remove:0:"));
    try testing.expectEqual(@as(i32, 0), try (try h.get(atspi.root_path, atspi.iface.accessible, "ChildCount")).read(i32));
}

fn takeValue(user: ?*anyopaque, _: *ui.Window, _: ui.NodeId, ev: *const ui.Event) bool {
    const v: *f64 = @ptrCast(@alignCast(user));
    v.* = ev.set_value;
    return true;
}

test "setting Value.CurrentValue asks the node's handler for the value" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var buf: [96]u8 = undefined;
    const slider = h.path(h.nodes.slider, &buf);
    try testing.expectEqual(@as(f64, 0), try (try h.get(slider, atspi.iface.value, "MinimumIncrement")).read(f64));
    // Without a set_value handler, nobody takes it.
    const props = "org.freedesktop.DBus.Properties";
    try testing.expectError(error.CallFailed, h.call(slider, props, "Set", .{ atspi.iface.value, "CurrentValue", dbus.variant(@as(f64, 5)) }));
    var got: f64 = -1;
    var t = try h.win.begin();
    try t.on(h.nodes.slider, .set_value, .{ .func = takeValue, .user = &got });
    try t.setSemantics(h.nodes.slider, .{ .role = .slider, .label = "Volume", .value = .{ .min = 0, .max = 10, .now = 3, .step = 0.5 } });
    t.commit();
    try h.frame();
    _ = try h.call(slider, props, "Set", .{ atspi.iface.value, "CurrentValue", dbus.variant(@as(f64, 5)) });
    try testing.expectEqual(@as(f64, 5), got);
    try testing.expectEqual(@as(f64, 0.5), try (try h.get(slider, atspi.iface.value, "MinimumIncrement")).read(f64));
}

test "Application.GetLocale reports the application's language" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var r = try h.call(atspi.root_path, atspi.iface.application, "GetLocale", .{@as(u32, 0)});
    try testing.expectEqualStrings("C", try r.read([]const u8));
    h.bridge.setLanguage("ar-EG");
    r = try h.call(atspi.root_path, atspi.iface.application, "GetLocale", .{@as(u32, 0)});
    try testing.expectEqualStrings("ar_EG", try r.read([]const u8));
    // POSIX names have no script: the region follows the language.
    h.bridge.setLanguage("sr-Latn-rs");
    r = try h.call(atspi.root_path, atspi.iface.application, "GetLocale", .{@as(u32, 0)});
    try testing.expectEqualStrings("sr_RS", try r.read([]const u8));
}
