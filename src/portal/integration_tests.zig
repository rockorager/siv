//! Portal clients against the real xdg-desktop-portal on a private
//! dbus-daemon (`zig build test-integration`), with siv's test backend
//! behind it (test_desktop.zig). The frontend validates every option's
//! type and forwards calls to the backend, so these tests check that the
//! clients speak the portal's real protocol: request paths and tokens,
//! option names and types, responses, sessions, and signals.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const dbus = @import("dbus");
const Loop = @import("loop").Loop;
const portal = @import("portal.zig");
const test_desktop = @import("test_desktop.zig");

const Client = portal.Client;
const Request = portal.Request;
const vardict = portal.vardict;
const Backend = test_desktop.Backend;
const gpa = testing.allocator;

const Harness = struct {
    desktop: test_desktop.Desktop = .{},
    loop: Loop = undefined,
    conn: dbus.Connection = undefined,
    client: Client = undefined,

    fn start(h: *Harness) !void {
        try h.desktop.start();
        errdefer h.desktop.stop();
        h.loop = try Loop.init(gpa);
        try h.conn.init(gpa, &h.loop, h.desktop.daemon.address, .{});
        h.client = .init(&h.conn);
        try h.until(&h.client, Client.ready);
    }

    fn stop(h: *Harness) void {
        h.client.deinit();
        h.conn.deinit();
        h.loop.deinit();
        h.desktop.stop();
    }

    fn until(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        const deadline = Loop.now() + 10 * std.time.ns_per_s;
        while (!cond(ctx)) {
            if (Loop.now() > deadline) return error.TestTimeout;
            try h.loop.dispatch(20);
        }
    }

    fn untilFn(h: *Harness, comptime cond: fn (*Harness) bool) !void {
        return h.until(h, cond);
    }
};

const Outcome = struct {
    req: Request = .{ .func = cb },
    done: bool = false,
    code: ?Request.Response = null,
    failure: ?Request.Failure = null,
    uris: [2][96]u8 = undefined,
    uri_lens: [2]usize = .{ 0, 0 },
    uri_count: usize = 0,
    choice: [16]u8 = undefined,
    choice_len: usize = 0,
    filter: [16]u8 = undefined,
    filter_len: usize = 0,
    text: [96]u8 = undefined,
    text_len: usize = 0,
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
                    @memcpy(o.choice[0..c.len], c);
                    o.choice_len = c.len;
                }
                if (fc.filterName()) |n| {
                    @memcpy(o.filter[0..n.len], n);
                    o.filter_len = n.len;
                }
                if (res.results.string("uri")) |u| {
                    @memcpy(o.text[0..u.len], u);
                    o.text_len = u.len;
                }
                o.color = portal.screenshot.color(&res.results);
            },
        }
    }

    fn isDone(o: *Outcome) bool {
        return o.done;
    }
};

fn chooserResults(call: *const Backend.Call, w: vardict.Writer) anyerror!void {
    if (!std.mem.eql(u8, call.member, "OpenFile")) return;
    try w.open("uris", "as");
    try w.e.write(@as([]const []const u8, &.{ "file:///home/u/a.png", "file:///home/u/b%20c.png" }));
    try w.close();
    try w.open("choices", "a(ss)");
    try w.e.write(@as([]const struct { []const u8, []const u8 }, &.{.{ "encoding", "utf16" }}));
    try w.close();
    try w.open("current_filter", "(sa(us))");
    try w.e.write(.{ @as([]const u8, "Images"), @as([]const struct { u32, []const u8 }, &.{.{ 1, "image/png" }}) });
    try w.close();
}

test "the file chooser through xdg-desktop-portal" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    h.desktop.backend.setResponse(0, chooserResults);
    var o: Outcome = .{};
    try portal.file_chooser.start(&o.req, &h.client, "", .{
        .title = "Open Image",
        .accept_label = "_Open",
        .multiple = true,
        .filters = &.{
            .{ .name = "Images", .patterns = &.{ .{ .kind = .mime, .pattern = "image/png" }, .{ .kind = .glob, .pattern = "*.jpg" } } },
            .{ .name = "All", .patterns = &.{.{ .kind = .glob, .pattern = "*" }} },
        },
        .current_filter = 0,
        .choices = &.{.{ .id = "encoding", .label = "Encoding", .options = &.{ .{ .id = "utf8", .label = "UTF-8" }, .{ .id = "utf16", .label = "UTF-16" } }, .initial = "utf8" }},
        .current_folder = "/tmp",
    });
    try h.until(&o, Outcome.isDone);
    try testing.expectEqual(Request.Response.success, o.code.?);
    try testing.expectEqual(@as(usize, 2), o.uri_count);
    try testing.expectEqualStrings("file:///home/u/b%20c.png", o.uris[1][0..o.uri_lens[1]]);
    try testing.expectEqualStrings("utf16", o.choice[0..o.choice_len]);
    try testing.expectEqualStrings("Images", o.filter[0..o.filter_len]);

    // What the frontend passed on to the backend, after validating it.
    const call = h.desktop.backend.find("FileChooser", "OpenFile").?;
    try testing.expectEqualStrings("Open Image", call.string(2));
    const opts = call.options();
    try testing.expectEqualStrings("_Open", opts.string("accept_label").?);
    try testing.expectEqual(true, opts.boolean("multiple").?);
    try testing.expect(opts.get("filters", "a(sa(us))") != null);
    try testing.expect(opts.get("current_filter", "(sa(us))") != null);
    try testing.expect(opts.get("choices", "a(ssa(ss)s)") != null);
    // The impl request lives at the client's request path.
    try testing.expectEqualStrings(o.req.path(), call.path(0));

    // A cancelled save dialog.
    h.desktop.backend.setResponse(1, null);
    var s: Outcome = .{};
    try portal.file_chooser.start(&s.req, &h.client, "", .{ .mode = .save, .current_name = "x.txt", .current_file = "/etc/hostname", .current_folder = "/etc" });
    try h.until(&s, Outcome.isDone);
    try testing.expectEqual(Request.Response.cancelled, s.code.?);
    const save = h.desktop.backend.find("FileChooser", "SaveFile").?;
    try testing.expectEqualStrings("x.txt", save.options().string("current_name").?);
    try testing.expectEqualStrings("/etc/hostname", save.options().bytesZ("current_file").?);
    try testing.expectEqualStrings("/etc", save.options().bytesZ("current_folder").?);
}

fn shotResults(call: *const Backend.Call, w: vardict.Writer) anyerror!void {
    if (std.mem.eql(u8, call.member, "Screenshot")) try w.put("uri", @as([]const u8, "file:///tmp/shot.png"));
    if (std.mem.eql(u8, call.member, "PickColor")) try w.put("color", .{ @as(f64, 0.5), @as(f64, 0.25), @as(f64, 1) });
}

test "screenshots and colors through xdg-desktop-portal" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    h.desktop.backend.setResponse(0, shotResults);
    var o: Outcome = .{};
    try portal.screenshot.screenshot(&o.req, &h.client, "", .{ .interactive = true });
    try h.until(&o, Outcome.isDone);
    try testing.expectEqualStrings("file:///tmp/shot.png", o.text[0..o.text_len]);
    try testing.expectEqual(true, h.desktop.backend.find("Screenshot", "Screenshot").?.options().boolean("interactive").?);
    var c: Outcome = .{};
    try portal.screenshot.pickColor(&c.req, &h.client, "");
    try h.until(&c, Outcome.isDone);
    try testing.expectEqual([3]f64{ 0.5, 0.25, 1 }, c.color.?);
}

fn openedContains(h: *Harness, comptime what: []const u8) bool {
    var buf: [1024]u8 = undefined;
    return std.mem.indexOf(u8, h.desktop.opened(&buf), what) != null;
}

test "OpenURI launches the handler for URIs and files, and shows files in the file manager" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    var o: Outcome = .{};
    try portal.open_uri.openUri(&o.req, &h.client, "", "sivtest:hello", .{});
    try h.until(&o, Outcome.isDone);
    try testing.expectEqual(Request.Response.success, o.code.?);
    try h.untilFn(struct {
        fn f(hh: *Harness) bool {
            return openedContains(hh, "sivtest:hello");
        }
    }.f);

    // A file:// URI goes by descriptor (OpenFile); the handler gets the file.
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/note.txt", .{h.desktop.dir}, 0);
    try dbus.testing.daemon.writeFile(path, "hello\n");
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(gpa);
    try portal.uri.fromPath(gpa, &uri, path);
    var file: Outcome = .{};
    try portal.open_uri.openUri(&file.req, &h.client, "", uri.items, .{});
    try h.until(&file, Outcome.isDone);
    try testing.expectEqual(Request.Response.success, file.code.?);
    try h.untilFn(struct {
        fn f(hh: *Harness) bool {
            return openedContains(hh, "note.txt");
        }
    }.f);

    // Shown in its folder through org.freedesktop.FileManager1.
    var d: Outcome = .{};
    try portal.open_uri.openUri(&d.req, &h.client, "", uri.items, .{ .show_in_folder = true });
    try h.until(&d, Outcome.isDone);
    try testing.expectEqual(Request.Response.success, d.code.?);
    const show = h.desktop.backend.find("FileManager1", "ShowItems").?;
    var dec = show.decoder();
    const arr = try dec.beginArray();
    try testing.expect(arr.next(&dec));
    try testing.expect(std.mem.endsWith(u8, try dec.readString(), "/note.txt"));
}

const Invoked = struct {
    actions: portal.notification.Actions = .{ .func = cb },
    action: [16]u8 = undefined,
    action_len: usize = 0,
    target: [16]u8 = undefined,
    target_len: usize = 0,

    fn cb(a: *portal.notification.Actions, _: []const u8, action: []const u8, target: []const u8) void {
        const i: *Invoked = @fieldParentPtr("actions", a);
        @memcpy(i.action[0..action.len], action);
        i.action_len = action.len;
        @memcpy(i.target[0..target.len], target);
        i.target_len = target.len;
    }

    fn got(i: *Invoked) bool {
        return i.action_len > 0;
    }
};

fn hasCall(comptime iface: []const u8, comptime member: []const u8) fn (*Harness) bool {
    return struct {
        fn f(h: *Harness) bool {
            return h.desktop.backend.find(iface, member) != null;
        }
    }.f;
}

test "notifications and their actions through xdg-desktop-portal" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    var inv: Invoked = .{};
    try inv.actions.subscribe(&h.client);
    defer inv.actions.unsubscribe();
    try portal.notification.add(&h.client, "mail", .{
        .title = "New mail",
        .body = "From Ada",
        .icon = .{ .themed = "mail-unread" },
        .priority = .high,
        .default_action = "app.open",
        .buttons = &.{.{ .label = "Archive", .action = "app.archive", .target = "42" }},
    });
    try h.untilFn(hasCall("Notification", "AddNotification"));
    const call = h.desktop.backend.find("Notification", "AddNotification").?;
    try testing.expectEqualStrings("mail", call.string(1));
    const n = call.options();
    try testing.expectEqualStrings("New mail", n.string("title").?);
    try testing.expectEqualStrings("high", n.string("priority").?);
    try testing.expect(n.get("buttons", "aa{sv}") != null);
    try testing.expect(n.get("icon", "(sv)") != null);

    // The backend reports the button; the frontend forwards it to us.
    try h.desktop.backend.emit("/org/freedesktop/portal/desktop", "org.freedesktop.impl.portal.Notification", "ActionInvoked", struct {
        fn w(e: *dbus.Encoder) anyerror!void {
            var params = [_]dbus.Variant([]const u8){dbus.variant(@as([]const u8, "42"))};
            try e.writeAll(.{ @as([]const u8, ""), @as([]const u8, "mail"), @as([]const u8, "app.archive"), @as([]const dbus.Variant([]const u8), &params) });
        }
    }.w);
    try h.until(&inv, Invoked.got);
    try testing.expectEqualStrings("app.archive", inv.action[0..inv.action_len]);
    try testing.expectEqualStrings("42", inv.target[0..inv.target_len]);

    try portal.notification.remove(&h.client, "mail");
    try h.untilFn(hasCall("Notification", "RemoveNotification"));
}

test "an inhibition through xdg-desktop-portal ends when its request closes" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    var o: Outcome = .{};
    try portal.inhibit.start(&o.req, &h.client, "", .{ .idle = true, .suspend_ = true }, "Presenting");
    try h.until(&o, Outcome.isDone);
    try testing.expectEqual(Request.Response.success, o.code.?);
    const call = h.desktop.backend.find("Inhibit", "Inhibit").?;
    var d = call.decoder();
    const handle = try d.readObjectPath();
    _ = try d.readString();
    _ = try d.readString();
    try testing.expectEqual(@as(u32, 12), try d.readUint32());
    try testing.expectEqualStrings("Presenting", call.options().string("reason").?);
    try testing.expect(!h.desktop.backend.wasClosed(handle));
    const handle_copy = try gpa.dupe(u8, handle);
    defer gpa.free(handle_copy);
    o.req.cancel();
    const S = struct {
        var path: []const u8 = "";
        fn f(hh: *Harness) bool {
            return hh.desktop.backend.wasClosed(path);
        }
    };
    S.path = handle_copy;
    try h.untilFn(S.f);
}

fn bindResults(call: *const Backend.Call, w: vardict.Writer) anyerror!void {
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
    activated: u32 = 0,

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
            .activated => k.activated += 1,
            else => {},
        }
    }

    fn isBound(k: *Keys) bool {
        return k.bound;
    }

    fn wasActivated(k: *Keys) bool {
        return k.activated > 0;
    }
};

var session_path_buf: [160]u8 = undefined;
var session_path: []const u8 = "";

test "global shortcuts through xdg-desktop-portal" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    // Newer xdg-desktop-portal (1.22) binds shortcuts only for an app id,
    // which host applications register.
    try Client.register(&h.conn, test_desktop.test_app_id);
    h.desktop.backend.setResponse(0, bindResults);
    var k: Keys = .{};
    try k.g.bind(&h.client, "", &.{.{ .id = "toggle", .description = "Toggle", .preferred_trigger = "CTRL+ALT+t" }});
    try h.until(&k, Keys.isBound);
    try testing.expectEqualStrings("Ctrl+Alt+T", k.trigger[0..k.trigger_len]);
    const create = h.desktop.backend.find("GlobalShortcuts", "CreateSession").?;
    // The impl session is the client's session path.
    try testing.expectEqualStrings(k.g.session.path(), create.path(1));
    @memcpy(session_path_buf[0..k.g.session.path().len], k.g.session.path());
    session_path = session_path_buf[0..k.g.session.path().len];
    try h.desktop.backend.emit("/org/freedesktop/portal/desktop", "org.freedesktop.impl.portal.GlobalShortcuts", "Activated", struct {
        fn w(e: *dbus.Encoder) anyerror!void {
            try e.writeAll(.{ dbus.ObjectPath{ .path = session_path }, @as([]const u8, "toggle"), @as(u64, 77) });
            try e.beginArray("{sv}");
            try e.endArray();
        }
    }.w);
    try h.until(&k, Keys.wasActivated);
    k.g.close();
    const S = struct {
        fn f(hh: *Harness) bool {
            return hh.desktop.backend.wasClosed(session_path);
        }
    };
    try h.untilFn(S.f);
}

fn castResults(call: *const Backend.Call, w: vardict.Writer) anyerror!void {
    if (!std.mem.eql(u8, call.member, "Start")) return;
    try w.open("streams", "a(ua{sv})");
    try w.e.beginArray("(ua{sv})");
    try w.e.beginStruct();
    try w.e.writeUint32(42);
    const sw = try vardict.Writer.begin(w.e);
    try sw.put("source_type", @as(u32, 1));
    try sw.put("size", .{ @as(i32, 1280), @as(i32, 720) });
    try sw.end();
    try w.e.endStruct();
    try w.e.endArray();
    try w.close();
    // What the backend wants back to restore the choice; the frontend
    // keeps it and hands the client a token instead.
    try w.put("persist_mode", @as(u32, 1));
    try w.put("restore_data", .{ @as([]const u8, "siv-test"), @as(u32, 1), dbus.variant(@as([]const u8, "monitor-0")) });
}

const Cast = struct {
    sc: portal.screencast.ScreenCast = .{ .func = cb },
    event: ?portal.screencast.Event = null,

    fn cb(sc: *portal.screencast.ScreenCast, ev: portal.screencast.Event) void {
        const c: *Cast = @fieldParentPtr("sc", sc);
        c.event = ev;
    }

    fn any(c: *Cast) bool {
        return c.event != null;
    }
};

test "a screen cast through xdg-desktop-portal" {
    var h: Harness = .{};
    try h.start();
    defer h.stop();
    h.desktop.backend.setResponse(0, castResults);
    var c: Cast = .{};
    try c.sc.start(&h.client, "", .{ .types = .{ .monitor = true, .window = true }, .cursor_mode = .embedded, .persist_mode = .transient });
    try h.until(&c, Cast.any);
    const select = h.desktop.backend.find("ScreenCast", "SelectSources").?;
    try testing.expectEqual(@as(u32, 3), select.options().uint("types").?);
    try testing.expectEqual(@as(u32, 2), select.options().uint("cursor_mode").?);
    try testing.expectEqual(@as(u32, 1), select.options().uint("persist_mode").?);
    try testing.expectEqual(@as(usize, 1), c.sc.streams().len);
    try testing.expectEqual(@as(u32, 42), c.sc.streams()[0].node_id);
    try testing.expectEqual(@as(i32, 1280), c.sc.streams()[0].width);
    // The frontend generated a restore token for the transient grant.
    try testing.expect(c.sc.restoreToken().len > 0);
    // OpenPipeWireRemote needs a PipeWire daemon: the portal connects to
    // it and hands over a restricted connection.
    if (h.desktop.hasPipewire()) {
        try testing.expectEqual(portal.screencast.Event.started, c.event.?);
        const fd = c.sc.takePipewireFd().?;
        // A connected unix stream socket.
        var kind: i32 = 0;
        var len: linux.socklen_t = @sizeOf(i32);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.TYPE, @ptrCast(&kind), &len)));
        try testing.expectEqual(@as(i32, linux.SOCK.STREAM), kind);
        _ = linux.close(fd);
    } else {
        try testing.expectEqual(portal.screencast.Event{ .failed = .failed }, c.event.?);
    }
    c.sc.close();
}
