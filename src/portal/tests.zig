//! Portal clients against a stand-in frontend on the in-process test bus:
//! hermetic, on a real loop and real sockets. They check what goes on the
//! wire (request paths, tokens, option types) and how responses,
//! failures, cancellation, and sessions reach callers.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const dbus = @import("dbus");
const Loop = @import("loop").Loop;
const portal = @import("portal.zig");
const Frontend = @import("test_frontend.zig").Frontend;

const Client = portal.Client;
const Request = portal.Request;
const vardict = portal.vardict;
const gpa = testing.allocator;

const Harness = struct {
    loop: Loop,
    bus: dbus.testing.TestBus,
    app_conn: dbus.Connection,
    portal_conn: dbus.Connection,
    frontend: Frontend,
    client: Client,

    fn init(h: *Harness, with_frontend: bool) !void {
        h.loop = try Loop.init(gpa);
        h.bus = .init(gpa, &h.loop);
        try h.portal_conn.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        h.frontend = .{ .conn = &h.portal_conn };
        if (with_frontend) {
            try h.frontend.start();
            try h.until(&h.frontend, Frontend.owns);
        }
        try h.app_conn.initFd(gpa, &h.loop, try h.bus.connect(), .{});
        h.client = .init(&h.app_conn);
    }

    fn deinit(h: *Harness) void {
        h.client.deinit();
        h.app_conn.deinit();
        h.frontend.deinit();
        h.portal_conn.deinit();
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

    fn ready(h: *Harness) !void {
        try h.until(&h.client, Client.ready);
    }

    fn settle(h: *Harness) !void {
        for (0..20) |_| try h.loop.dispatch(5);
    }
};

/// Records the outcome of a request.
const Outcome = struct {
    req: Request = .{ .func = cb },
    done: bool = false,
    code: ?Request.Response = null,
    failure: ?Request.Failure = null,
    uris: [4][64]u8 = undefined,
    uri_lens: [4]usize = @splat(0),
    uri_count: usize = 0,
    text: [64]u8 = undefined,
    text_len: usize = 0,
    filter: [32]u8 = undefined,
    filter_len: usize = 0,
    color: ?[3]f64 = null,

    fn cb(r: *Request, outcome: Request.Outcome) void {
        const o: *Outcome = @fieldParentPtr("req", r);
        o.done = true;
        switch (outcome) {
            .failed => |f| o.failure = f,
            .response => |res| {
                o.code = res.code;
                const fc: portal.file_chooser.Results = .{ .r = res.results };
                if (fc.uris()) |it_| {
                    var it = it_;
                    while (it.next()) |u| : (o.uri_count += 1) {
                        @memcpy(o.uris[o.uri_count][0..u.len], u);
                        o.uri_lens[o.uri_count] = u.len;
                    }
                }
                if (fc.choice("encoding")) |c| {
                    @memcpy(o.text[0..c.len], c);
                    o.text_len = c.len;
                } else if (res.results.string("uri")) |u| {
                    @memcpy(o.text[0..u.len], u);
                    o.text_len = u.len;
                }
                if (fc.filterName()) |n| {
                    @memcpy(o.filter[0..n.len], n);
                    o.filter_len = n.len;
                }
                o.color = portal.screenshot.color(&res.results);
            },
        }
    }

    fn isDone(o: *Outcome) bool {
        return o.done;
    }

    fn uri(o: *const Outcome, i: usize) []const u8 {
        return o.uris[i][0..o.uri_lens[i]];
    }
};

fn chooserResults(_: *Frontend, call: *const Frontend.Call, w: vardict.Writer) anyerror!void {
    if (!std.mem.eql(u8, call.member, "OpenFile") and !std.mem.eql(u8, call.member, "SaveFile")) return;
    try w.open("uris", "as");
    try w.e.write(@as([]const []const u8, &.{ "file:///home/u/a.png", "file:///home/u/b%20c.png" }));
    try w.close();
    try w.open("choices", "a(ss)");
    try w.e.write(@as([]const struct { []const u8, []const u8 }, &.{ .{ "hidden", "true" }, .{ "encoding", "utf16" } }));
    try w.close();
    try w.open("current_filter", "(sa(us))");
    try w.e.write(.{ @as([]const u8, "Images"), @as([]const struct { u32, []const u8 }, &.{.{ 1, "image/png" }}) });
    try w.close();
}

test "the file chooser sends its options and reads the response" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    h.frontend.results = chooserResults;

    var o: Outcome = .{};
    const fc = portal.file_chooser;
    try fc.start(&o.req, &h.client, "wayland:abc", .{
        .title = "Open Image",
        .accept_label = "_Open",
        .multiple = true,
        .filters = &.{
            .{ .name = "Images", .patterns = &.{ .{ .kind = .mime, .pattern = "image/png" }, .{ .kind = .glob, .pattern = "*.jpg" } } },
            .{ .name = "All", .patterns = &.{.{ .kind = .glob, .pattern = "*" }} },
        },
        .current_filter = 0,
        .choices = &.{
            .{ .id = "encoding", .label = "Encoding", .options = &.{ .{ .id = "utf8", .label = "UTF-8" }, .{ .id = "utf16", .label = "UTF-16" } }, .initial = "utf8" },
            .{ .id = "hidden", .label = "Show hidden" },
        },
        .current_folder = "/home/u/Pictures",
    });
    try h.until(&o, Outcome.isDone);

    // The wire: method, parent, title, and every option with its type.
    const call = h.frontend.find("OpenFile").?;
    try testing.expectEqualStrings("org.freedesktop.portal.FileChooser", call.interface);
    try testing.expectEqualStrings("wayland:abc", call.firstString());
    var d = call.decoder();
    _ = try d.readString();
    try testing.expectEqualStrings("Open Image", try d.readString());
    const opts = call.options();
    const token = opts.string("handle_token").?;
    try testing.expectEqualStrings(o.req.tokenSlice(), token);
    try testing.expectEqualStrings("_Open", opts.string("accept_label").?);
    try testing.expectEqual(true, opts.boolean("multiple").?);
    try testing.expectEqual(true, opts.boolean("modal").?);
    try testing.expectEqual(null, opts.boolean("directory"));
    try testing.expectEqualStrings("/home/u/Pictures", opts.bytesZ("current_folder").?);
    // The request path is the documented one: sender without the colon,
    // dots as underscores, then the token.
    var expected: [Client.max_path]u8 = undefined;
    const unique = h.app_conn.uniqueName();
    var esc: [32]u8 = undefined;
    for (unique[1..], 0..) |ch, i| esc[i] = if (ch == '.') '_' else ch;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ esc[0 .. unique.len - 1], token }), call.request);

    var filters = opts.get("filters", "a(sa(us))").?;
    const fa = try filters.beginArray();
    var names: [2][]const u8 = undefined;
    var n: usize = 0;
    while (fa.next(&filters)) : (n += 1) {
        try filters.beginStruct();
        names[n] = try filters.readString();
        const pa = try filters.beginArray();
        var first = true;
        while (pa.next(&filters)) {
            const p = try filters.read(struct { u32, []const u8 });
            if (n == 0 and first) {
                try testing.expectEqual(@as(u32, 1), p[0]);
                try testing.expectEqualStrings("image/png", p[1]);
            }
            first = false;
        }
        try filters.endArray(pa);
        try filters.endStruct();
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("All", names[1]);
    var cf = opts.get("current_filter", "(sa(us))").?;
    try cf.beginStruct();
    try testing.expectEqualStrings("Images", try cf.readString());
    var choices = opts.get("choices", "a(ssa(ss)s)").?;
    const ca = try choices.beginArray();
    try testing.expect(ca.next(&choices));
    try choices.beginStruct();
    try testing.expectEqualStrings("encoding", try choices.readString());
    try testing.expectEqualStrings("Encoding", try choices.readString());
    const oa = try choices.beginArray();
    try testing.expect(oa.next(&choices));
    try testing.expectEqualStrings("utf8", (try choices.read(struct { []const u8, []const u8 }))[0]);
    try choices.endArray(oa);
    try testing.expectEqualStrings("utf8", try choices.readString());

    // The response.
    try testing.expectEqual(Request.Response.success, o.code.?);
    try testing.expectEqual(@as(usize, 2), o.uri_count);
    try testing.expectEqualStrings("file:///home/u/b%20c.png", o.uri(1));
    try testing.expectEqualStrings("utf16", o.text[0..o.text_len]);
    try testing.expectEqualStrings("Images", o.filter[0..o.filter_len]);
}

test "save dialogs send the name, file, and folder" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    var o: Outcome = .{};
    try portal.file_chooser.start(&o.req, &h.client, "", .{ .mode = .save, .current_name = "report.pdf", .current_file = "/home/u/old.pdf", .multiple = true, .modal = false });
    try h.until(&o, Outcome.isDone);
    const call = h.frontend.find("SaveFile").?;
    const opts = call.options();
    try testing.expectEqualStrings("report.pdf", opts.string("current_name").?);
    try testing.expectEqualStrings("/home/u/old.pdf", opts.bytesZ("current_file").?);
    // Save dialogs have no multiple selection.
    try testing.expectEqual(null, opts.boolean("multiple"));
    try testing.expectEqual(false, opts.boolean("modal").?);
}

test "a request made before the bus answered Hello waits for it" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try testing.expect(!h.client.ready());
    var o: Outcome = .{};
    try portal.screenshot.screenshot(&o.req, &h.client, "", .{});
    try testing.expect(o.req.queued);
    // The coordinator forwards the connection's ready event.
    try h.until(&h.client, Client.ready);
    h.client.connectionReady();
    try h.until(&o, Outcome.isDone);
    try testing.expectEqual(Request.Response.success, o.code.?);
}

test "cancelling a request closes it, and its callback never runs" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    h.frontend.immediate = false;
    var o: Outcome = .{};
    try portal.file_chooser.start(&o.req, &h.client, "", .{});
    try h.until(&h.frontend, struct {
        fn f(fr: *Frontend) bool {
            return fr.find("OpenFile") != null;
        }
    }.f);
    o.req.cancel();
    try h.settle();
    try testing.expect(h.frontend.wasClosed(h.frontend.find("OpenFile").?.request));
    // A response sent anyway is ignored.
    try h.frontend.respond(0, 0);
    try h.settle();
    try testing.expect(!o.done);
}

test "no portal, error replies, and a lost bus are failures" {
    {
        var h: Harness = undefined;
        try h.init(false);
        defer h.deinit();
        try h.ready();
        var o: Outcome = .{};
        try portal.screenshot.pickColor(&o.req, &h.client, "");
        try h.until(&o, Outcome.isDone);
        try testing.expectEqual(Request.Failure.unavailable, o.failure.?);
    }
    {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try h.ready();
        h.frontend.error_name = "org.freedesktop.portal.Error.InvalidArgument";
        var o: Outcome = .{};
        try portal.screenshot.pickColor(&o.req, &h.client, "");
        try h.until(&o, Outcome.isDone);
        try testing.expectEqual(Request.Failure.failed, o.failure.?);
    }
    {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        var o: Outcome = .{};
        try portal.screenshot.pickColor(&o.req, &h.client, "");
        h.client.connectionLost();
        try testing.expectEqual(Request.Failure.disconnected, o.failure.?);
    }
}

fn screenshotResults(_: *Frontend, call: *const Frontend.Call, w: vardict.Writer) anyerror!void {
    if (std.mem.eql(u8, call.member, "Screenshot")) try w.put("uri", @as([]const u8, "file:///tmp/shot.png"));
    if (std.mem.eql(u8, call.member, "PickColor")) try w.put("color", .{ @as(f64, 0.25), @as(f64, 1.5), @as(f64, 0) });
}

test "screenshots and picked colors" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    h.frontend.results = screenshotResults;
    var o: Outcome = .{};
    try portal.screenshot.screenshot(&o.req, &h.client, "wayland:w", .{ .interactive = true });
    try h.until(&o, Outcome.isDone);
    try testing.expectEqualStrings("file:///tmp/shot.png", o.text[0..o.text_len]);
    try testing.expectEqual(true, h.frontend.find("Screenshot").?.options().boolean("interactive").?);
    var p: Outcome = .{};
    try portal.screenshot.pickColor(&p.req, &h.client, "");
    try h.until(&p, Outcome.isDone);
    // Out-of-range components are clamped.
    try testing.expectEqual([3]f64{ 0.25, 1, 0 }, p.color.?);
}

test "file URIs open by descriptor, others by URI" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/siv-portal-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o700);
    defer _ = linux.rmdir(dir);
    var file_buf: [96]u8 = undefined;
    const file = try std.fmt.bufPrintSentinel(&file_buf, "{s}/a b.txt", .{dir}, 0);
    try dbus.testing.daemon.writeFile(file, "x");
    defer _ = linux.unlink(file);

    var a: Outcome = .{};
    try portal.open_uri.openUri(&a.req, &h.client, "", "https://example.com/?q=1", .{ .ask = true, .activation_token = "tok" });
    try h.until(&a, Outcome.isDone);
    const c1 = h.frontend.find("OpenURI").?;
    var d = c1.decoder();
    _ = try d.readString();
    try testing.expectEqualStrings("https://example.com/?q=1", try d.readString());
    try testing.expectEqual(true, c1.options().boolean("ask").?);
    try testing.expectEqualStrings("tok", c1.options().string("activation_token").?);

    var uri_buf: std.ArrayList(u8) = .empty;
    defer uri_buf.deinit(gpa);
    try portal.uri.fromPath(gpa, &uri_buf, file);
    var b: Outcome = .{};
    try portal.open_uri.openUri(&b.req, &h.client, "", uri_buf.items, .{ .writable = true });
    try h.until(&b, Outcome.isDone);
    const c2 = h.frontend.find("OpenFile").?;
    try testing.expectEqualStrings("org.freedesktop.portal.OpenURI", c2.interface);
    try testing.expectEqualStrings(file, c2.fd_path);
    try testing.expectEqual(true, c2.options().boolean("writable").?);

    var c: Outcome = .{};
    try portal.open_uri.openUri(&c.req, &h.client, "", uri_buf.items, .{ .show_in_folder = true });
    try h.until(&c, Outcome.isDone);
    try testing.expectEqualStrings(file, h.frontend.find("OpenDirectory").?.fd_path);

    var e: Outcome = .{};
    try testing.expectError(error.FileNotFound, portal.open_uri.openUri(&e.req, &h.client, "", "file:///nonexistent/x", .{}));
}

const Invoked = struct {
    actions: portal.notification.Actions = .{ .func = cb },
    id: [16]u8 = undefined,
    id_len: usize = 0,
    action: [16]u8 = undefined,
    action_len: usize = 0,
    target: [16]u8 = undefined,
    target_len: usize = 0,
    count: usize = 0,

    fn cb(a: *portal.notification.Actions, id: []const u8, action: []const u8, target: []const u8) void {
        const i: *Invoked = @fieldParentPtr("actions", a);
        i.count += 1;
        @memcpy(i.id[0..id.len], id);
        i.id_len = id.len;
        @memcpy(i.action[0..action.len], action);
        i.action_len = action.len;
        @memcpy(i.target[0..target.len], target);
        i.target_len = target.len;
    }

    fn got(i: *Invoked) bool {
        return i.count > 0;
    }
};

test "notifications carry their fields, and actions come back" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    var inv: Invoked = .{};
    try inv.actions.subscribe(&h.client);
    defer inv.actions.unsubscribe();
    try portal.notification.add(&h.client, "new-mail", .{
        .title = "New mail",
        .body = "From Ada",
        .icon = .{ .themed = "mail-unread" },
        .priority = .high,
        .default_action = "open",
        .default_target = "inbox",
        .buttons = &.{.{ .label = "Archive", .action = "archive", .target = "42" }},
    });
    try h.until(&h.frontend, struct {
        fn f(fr: *Frontend) bool {
            return fr.find("AddNotification") != null;
        }
    }.f);
    const call = h.frontend.find("AddNotification").?;
    try testing.expectEqualStrings("new-mail", call.firstString());
    const n = call.options();
    try testing.expectEqualStrings("New mail", n.string("title").?);
    try testing.expectEqualStrings("high", n.string("priority").?);
    try testing.expectEqualStrings("open", n.string("default-action").?);
    try testing.expectEqualStrings("inbox", n.string("default-action-target").?);
    var icon = n.get("icon", "(sv)").?;
    try icon.beginStruct();
    try testing.expectEqualStrings("themed", try icon.readString());
    try testing.expectEqualStrings("as", try icon.beginVariant());
    const names = try icon.beginArray();
    try testing.expect(names.next(&icon));
    try testing.expectEqualStrings("mail-unread", try icon.readString());
    var buttons = n.get("buttons", "aa{sv}").?;
    const ba = try buttons.beginArray();
    try testing.expect(ba.next(&buttons));
    const b0 = try vardict.Reader.take(&buttons);
    try testing.expectEqualStrings("Archive", b0.string("label").?);
    try testing.expectEqualStrings("42", b0.string("target").?);

    // ActionInvoked (ss av) with the target as the parameter.
    var params = [_]dbus.Variant([]const u8){dbus.variant(@as([]const u8, "42"))};
    try h.frontend.emit(portal.notification.interface, "ActionInvoked", .{ @as([]const u8, "new-mail"), @as([]const u8, "archive"), @as([]const dbus.Variant([]const u8), &params) });
    try h.until(&inv, Invoked.got);
    try testing.expectEqualStrings("new-mail", inv.id[0..inv.id_len]);
    try testing.expectEqualStrings("archive", inv.action[0..inv.action_len]);
    try testing.expectEqualStrings("42", inv.target[0..inv.target_len]);

    try portal.notification.remove(&h.client, "new-mail");
    try h.until(&h.frontend, struct {
        fn f(fr: *Frontend) bool {
            return fr.find("RemoveNotification") != null;
        }
    }.f);
}

test "an inhibition lasts until its request is closed" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    var o: Outcome = .{};
    try portal.inhibit.start(&o.req, &h.client, "wayland:x", .{ .suspend_ = true, .idle = true }, "Playing a video");
    try h.until(&o, Outcome.isDone);
    const call = h.frontend.find("Inhibit").?;
    var d = call.decoder();
    _ = try d.readString();
    try testing.expectEqual(@as(u32, 12), try d.readUint32());
    try testing.expectEqualStrings("Playing a video", call.options().string("reason").?);
    try testing.expect(!h.frontend.wasClosed(call.request));
    o.req.cancel();
    try h.settle();
    try testing.expect(h.frontend.wasClosed(call.request));
}

fn castResults(_: *Frontend, call: *const Frontend.Call, w: vardict.Writer) anyerror!void {
    if (!std.mem.eql(u8, call.member, "Start")) return;
    try w.open("streams", "a(ua{sv})");
    try w.e.beginArray("(ua{sv})");
    try w.e.beginStruct();
    try w.e.writeUint32(57);
    const sw = try vardict.Writer.begin(w.e);
    try sw.put("source_type", @as(u32, 1));
    try sw.put("size", .{ @as(i32, 1920), @as(i32, 1080) });
    try sw.put("position", .{ @as(i32, 10), @as(i32, 20) });
    try sw.end();
    try w.e.endStruct();
    try w.e.endArray();
    try w.close();
    try w.put("restore_token", @as([]const u8, "0f1e2d3c"));
}

const Cast = struct {
    sc: portal.screencast.ScreenCast = .{ .func = cb },
    events: [4]portal.screencast.Event = undefined,
    n: usize = 0,

    fn cb(sc: *portal.screencast.ScreenCast, ev: portal.screencast.Event) void {
        const c: *Cast = @fieldParentPtr("sc", sc);
        c.events[c.n] = ev;
        c.n += 1;
    }

    fn any(c: *Cast) bool {
        return c.n > 0;
    }

    fn two(c: *Cast) bool {
        return c.n > 1;
    }
};

test "a screen cast runs through its session steps to a PipeWire fd" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    h.frontend.results = castResults;
    var c: Cast = .{};
    try c.sc.start(&h.client, "wayland:p", .{ .types = .{ .monitor = true, .window = true }, .cursor_mode = .embedded, .persist_mode = .transient, .restore_token = "old" });
    try h.until(&c, Cast.any);
    try testing.expectEqual(portal.screencast.Event.started, c.events[0]);
    const sel = h.frontend.find("SelectSources").?.options();
    try testing.expectEqual(@as(u32, 3), sel.uint("types").?);
    try testing.expectEqual(@as(u32, 2), sel.uint("cursor_mode").?);
    try testing.expectEqual(@as(u32, 1), sel.uint("persist_mode").?);
    try testing.expectEqualStrings("old", sel.string("restore_token").?);
    // Start carries the parent; every step names the session.
    const start_call = h.frontend.find("Start").?;
    var d = start_call.decoder();
    const session = try d.readObjectPath();
    try testing.expectEqualStrings(c.sc.session.path(), session);
    try testing.expectEqualStrings("wayland:p", try d.readString());
    try testing.expectEqual(@as(usize, 1), c.sc.streams().len);
    try testing.expectEqual(portal.screencast.Stream{ .node_id = 57, .source_type = 1, .x = 10, .y = 20, .width = 1920, .height = 1080 }, c.sc.streams()[0]);
    try testing.expectEqualStrings("0f1e2d3c", c.sc.restoreToken());
    const fd = c.sc.takePipewireFd().?;
    _ = linux.close(fd);

    // The portal ends the cast.
    try h.frontend.closeSession(session);
    try h.until(&c, Cast.two);
    try testing.expectEqual(portal.screencast.Event.closed, c.events[1]);
    c.sc.close();
}

test "closing a screen cast closes its session" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    var c: Cast = .{};
    try c.sc.start(&h.client, "", .{});
    try h.until(&c, Cast.any);
    try testing.expectEqual(portal.screencast.Event.started, c.events[0]);
    const path = try gpa.dupe(u8, c.sc.session.path());
    defer gpa.free(path);
    c.sc.close();
    try h.settle();
    try testing.expect(h.frontend.wasClosed(path));
    // Cancelling the selection ends the cast with the response.
    h.frontend.code = 1;
    var c2: Cast = .{};
    try c2.sc.start(&h.client, "", .{});
    try h.until(&c2, Cast.any);
    try testing.expectEqual(portal.screencast.Event{ .ended = .cancelled }, c2.events[0]);
}

fn shortcutResults(_: *Frontend, call: *const Frontend.Call, w: vardict.Writer) anyerror!void {
    if (!std.mem.eql(u8, call.member, "BindShortcuts")) return;
    try w.open("shortcuts", "a(sa{sv})");
    try w.e.beginArray("(sa{sv})");
    try w.e.beginStruct();
    try w.e.writeString("toggle");
    const sw = try vardict.Writer.begin(w.e);
    try sw.put("description", @as([]const u8, "Toggle"));
    try sw.put("trigger_description", @as([]const u8, "Ctrl+Alt+T"));
    try sw.end();
    try w.e.endStruct();
    try w.e.endArray();
    try w.close();
}

const Keys = struct {
    g: portal.global_shortcuts.GlobalShortcuts = .{ .func = cb },
    trigger: [32]u8 = undefined,
    trigger_len: usize = 0,
    bound: bool = false,
    activated: usize = 0,
    deactivated: usize = 0,
    last_ts: u64 = 0,

    fn cb(g: *portal.global_shortcuts.GlobalShortcuts, ev: portal.global_shortcuts.Event) void {
        const k: *Keys = @fieldParentPtr("g", g);
        switch (ev) {
            .bound => |it_| {
                var it = it_;
                while (it.next()) |s| {
                    @memcpy(k.trigger[0..s.trigger.len], s.trigger);
                    k.trigger_len = s.trigger.len;
                }
                k.bound = true;
            },
            .activated => |a| {
                k.activated += 1;
                k.last_ts = a.timestamp_ms;
            },
            .deactivated => k.deactivated += 1,
            else => {},
        }
    }

    fn isBound(k: *Keys) bool {
        return k.bound;
    }

    fn released(k: *Keys) bool {
        return k.deactivated > 0;
    }
};

test "global shortcuts bind through a session and follow its signals" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    h.frontend.results = shortcutResults;
    var k: Keys = .{};
    try k.g.bind(&h.client, "wayland:q", &.{.{ .id = "toggle", .description = "Toggle", .preferred_trigger = "CTRL+ALT+t" }});
    try h.until(&k, Keys.isBound);
    try testing.expectEqualStrings("Ctrl+Alt+T", k.trigger[0..k.trigger_len]);
    const bind = h.frontend.find("BindShortcuts").?;
    var d = bind.decoder();
    try testing.expectEqualStrings(k.g.session.path(), try d.readObjectPath());
    const arr = try d.beginArray();
    try testing.expect(arr.next(&d));
    try d.beginStruct();
    try testing.expectEqualStrings("toggle", try d.readString());
    const props = try vardict.Reader.take(&d);
    try testing.expectEqualStrings("CTRL+ALT+t", props.string("preferred_trigger").?);

    const E = dbus.DictEntry([]const u8, dbus.Variant(u32));
    const none: []const E = &.{};
    // Another session's activation is not ours.
    try h.frontend.emit(portal.global_shortcuts.interface, "Activated", .{ dbus.ObjectPath{ .path = "/org/freedesktop/portal/desktop/session/1_99/other" }, @as([]const u8, "toggle"), @as(u64, 1), none });
    try h.frontend.emit(portal.global_shortcuts.interface, "Activated", .{ dbus.ObjectPath{ .path = k.g.session.path() }, @as([]const u8, "toggle"), @as(u64, 1234), none });
    try h.frontend.emit(portal.global_shortcuts.interface, "Deactivated", .{ dbus.ObjectPath{ .path = k.g.session.path() }, @as([]const u8, "toggle"), @as(u64, 1300), none });
    try h.until(&k, Keys.released);
    try testing.expectEqual(@as(usize, 1), k.activated);
    try testing.expectEqual(@as(u64, 1234), k.last_ts);
    k.g.close();
}

const Doc = struct {
    add: portal.documents.Add = .{ .func = cb },
    path: [128]u8 = undefined,
    path_len: usize = 0,
    done: bool = false,

    fn cb(a: *portal.documents.Add, r: portal.documents.Result) void {
        const doc: *Doc = @fieldParentPtr("add", a);
        doc.done = true;
        switch (r) {
            .added => |x| {
                @memcpy(doc.path[0..x.path.len], x.path);
                doc.path_len = x.path.len;
            },
            .failed => {},
        }
    }

    fn isDone(doc: *Doc) bool {
        return doc.done;
    }
};

test "documents register a file and grant permissions" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try h.ready();
    var doc: Doc = .{};
    try doc.add.start(&h.client, "/etc/hostname", "org.example.Viewer", .{ .read = true, .write = true }, .{ .reuse_existing = true, .persistent = true });
    try h.until(&doc, Doc.isDone);
    try testing.expectEqualStrings("/run/user/1000/doc/a1b2c3/hostname", doc.path[0..doc.path_len]);
    const call = h.frontend.find("AddFull").?;
    try testing.expectEqualStrings("/etc/hostname", call.fd_path);
    var d = call.decoder();
    try d.skip();
    try testing.expectEqual(@as(u32, 3), try d.readUint32());
    try testing.expectEqualStrings("org.example.Viewer", try d.readString());
    const pa = try d.beginArray();
    try testing.expect(pa.next(&d));
    try testing.expectEqualStrings("read", try d.readString());
    try testing.expectEqualStrings("write", try d.readString());
}

const AppLog = struct {
    activations: u32 = 0,
    opened: [2][64]u8 = undefined,
    opened_lens: [2]usize = .{ 0, 0 },
    open_count: usize = 0,
    act: [16]u8 = undefined,
    act_len: usize = 0,
    target: [16]u8 = undefined,
    target_len: usize = 0,
    token: [32]u8 = undefined,
    token_len: usize = 0,
    calls: u32 = 0,

    fn setToken(l: *AppLog, t: []const u8) void {
        @memcpy(l.token[0..t.len], t);
        l.token_len = t.len;
        l.calls += 1;
    }

    fn activate(ctx: ?*anyopaque, token: []const u8) void {
        const l: *AppLog = @ptrCast(@alignCast(ctx));
        l.activations += 1;
        l.setToken(token);
    }

    fn open(ctx: ?*anyopaque, uris: *vardict.StringIterator, token: []const u8) void {
        const l: *AppLog = @ptrCast(@alignCast(ctx));
        l.open_count = 0;
        while (uris.next()) |u| : (l.open_count += 1) {
            @memcpy(l.opened[l.open_count][0..u.len], u);
            l.opened_lens[l.open_count] = u.len;
        }
        l.setToken(token);
    }

    fn action(ctx: ?*anyopaque, name: []const u8, target: []const u8, token: []const u8) void {
        const l: *AppLog = @ptrCast(@alignCast(ctx));
        @memcpy(l.act[0..name.len], name);
        l.act_len = name.len;
        @memcpy(l.target[0..target.len], target);
        l.target_len = target.len;
        l.setToken(token);
    }

    fn handler(l: *AppLog) portal.application.Handler {
        return .{ .ctx = l, .activate = activate, .open = open, .action = action };
    }
};

const Forwarded = struct {
    f: portal.application.Forward = .{ .func = cb },
    done: bool = false,
    ok: bool = false,

    fn cb(f: *portal.application.Forward, ok: bool) void {
        const x: *Forwarded = @fieldParentPtr("f", f);
        x.done = true;
        x.ok = ok;
    }

    fn isDone(x: *Forwarded) bool {
        return x.done;
    }
};

test "application object paths follow the id" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/org/example/My_App", portal.application.objectPath(&buf, "org.example.My-App").?);
    try testing.expectEqual(null, portal.application.objectPath(&buf, "noDots"));
    try testing.expectEqual(null, portal.application.objectPath(&buf, ":1.2"));
}

test "a second instance forwards activation, URIs, and actions to the first" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try h.ready();
    var log: AppLog = .{};
    var first: portal.application.Server = .{ .handler = log.handler() };
    try first.start(&h.app_conn, "org.example.App");
    defer first.stop();
    try h.until(&first, struct {
        fn f(s: *portal.application.Server) bool {
            return s.owner.state == .primary;
        }
    }.f);

    // The second instance's connection.
    var conn2: dbus.Connection = undefined;
    try conn2.initFd(gpa, &h.loop, try h.bus.connect(), .{});
    defer conn2.deinit();
    var log2: AppLog = .{};
    var second: portal.application.Server = .{ .handler = log2.handler() };
    try second.start(&conn2, "org.example.App");
    defer second.stop();
    try h.until(&second, struct {
        fn f(s: *portal.application.Server) bool {
            return s.owner.state != .requesting and s.owner.state != .idle;
        }
    }.f);
    try testing.expectEqual(dbus.Connection.NameOwner.State.exists, second.owner.state);

    var fw: Forwarded = .{};
    try fw.f.open(&conn2, "org.example.App", &.{ "file:///a.txt", "https://x/" }, "tok-1");
    try h.until(&fw, Forwarded.isDone);
    try testing.expect(fw.ok);
    try testing.expectEqual(@as(usize, 2), log.open_count);
    try testing.expectEqualStrings("https://x/", log.opened[1][0..log.opened_lens[1]]);
    try testing.expectEqualStrings("tok-1", log.token[0..log.token_len]);

    fw = .{};
    try fw.f.action(&conn2, "org.example.App", "archive", "42", "");
    try h.until(&fw, Forwarded.isDone);
    try testing.expectEqualStrings("archive", log.act[0..log.act_len]);
    try testing.expectEqualStrings("42", log.target[0..log.target_len]);
    try testing.expectEqual(@as(usize, 0), log.token_len);

    fw = .{};
    try fw.f.activate(&conn2, "org.example.App", "tok-2");
    try h.until(&fw, Forwarded.isDone);
    try testing.expectEqual(@as(u32, 1), log.activations);
    try testing.expectEqualStrings("tok-2", log.token[0..log.token_len]);
    // Nothing reached the second instance.
    try testing.expectEqual(@as(u32, 0), log2.calls);

    // Without a primary, forwarding fails.
    first.stop();
    try h.settle();
    fw = .{};
    try fw.f.activate(&conn2, "org.example.App", "");
    try h.until(&fw, Forwarded.isDone);
    try testing.expect(!fw.ok);
}
