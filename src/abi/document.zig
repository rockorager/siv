//! Exports for documents (D32, api_document.zig): a canvas node driven by
//! a docview.View, its C callbacks kept in the node's canvas slot so that
//! the node's end releases them. Built out with -Ddocument=false: every
//! function returns SIV_ERROR_UNSUPPORTED and nothing of the renderer is
//! compiled.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");

const enabled = @import("build_options").document;
const docview = if (enabled) @import("docview") else stub;

/// What the exports use of docview, without it: nothing is ever made.
const stub = struct {
    pub const ResourceKind = enum { stylesheet, image, font };
    pub const Event = union(enum) { link: []const u8, loaded, size: f32, find: struct { count: u32, current: u32 }, selection, blocked_images: u32 };
    pub const View = struct {
        gpa: std.mem.Allocator,
        /// Never called: siv_docview fails first.
        pub fn create(_: std.mem.Allocator, _: *ui.Txn, _: NodeId, _: []const u8, _: anytype, _: anytype) (error{OutOfMemory} || ui.TxnError)!*View {
            return error.OutOfMemory;
        }
        pub fn destroy(_: *View) void {}
        pub fn document(_: *View) ?*struct { title: []const u8 } {
            return null;
        }
        pub fn supply(_: *View, _: u32, _: ?[]const u8) error{OutOfMemory}!void {}
        pub fn loadImages(_: *View) void {}
        pub fn find(_: *View, _: []const u8, _: bool) error{OutOfMemory}!void {}
        pub fn selectedText(_: *View, _: std.mem.Allocator) error{OutOfMemory}![]u8 {
            return &.{};
        }
        pub fn selectAll(_: *View) void {}
        pub fn scrollToFragment(_: *View, _: []const u8) bool {
            return false;
        }
        pub fn locatorAt(_: *View, _: f32, _: *std.ArrayList(u8)) error{OutOfMemory}!void {}
        pub fn locatorY(_: *View, _: []const u8) ?f32 {
            return null;
        }
    };
};

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;

/// A document node's application side.
const Doc = struct {
    app: *App,
    w: *Window,
    id: NodeId,
    view: *docview.View,
    load: ?t.DocviewLoadFn,
    on_event: ?t.DocviewEventFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,

    fn node(d: *Doc) t.Node {
        return @fromBackingInt(d.w.nodes.handle(d.id));
    }

    fn onLoad(ctx: ?*anyopaque, _: *docview.View, request: u32, url: []const u8, kind: docview.ResourceKind) void {
        const d: *Doc = @ptrCast(@alignCast(ctx));
        const f = d.load orelse return;
        d.app.enter();
        defer d.app.leave();
        f(d.user_data, d.node(), request, url.ptr, url.len, switch (kind) {
            .stylesheet => .stylesheet,
            .image => .image,
            .font => .font,
        });
    }

    fn onEvent(ctx: ?*anyopaque, _: *docview.View, event: docview.Event) void {
        const d: *Doc = @ptrCast(@alignCast(ctx));
        const f = d.on_event orelse return;
        var e: t.DocviewEvent = .{};
        switch (event) {
            .link => |u| {
                e.type = .link;
                e.url = u.ptr;
                e.url_len = u.len;
            },
            .loaded => e.type = .loaded,
            .size => |h| {
                e.type = .size;
                e.height = h;
            },
            .find => |x| {
                e.type = .find;
                e.count = x.count;
                e.current = x.current;
            },
            .selection => e.type = .selection,
            .blocked_images => |n| {
                e.type = .blocked_images;
                e.count = n;
            },
        }
        d.app.enter();
        defer d.app.leave();
        f(d.user_data, d.node(), &e);
    }
};

/// The node is gone (or its transaction aborted).
fn release(user: ?*anyopaque) callconv(.c) void {
    const d: *Doc = @ptrCast(@alignCast(user));
    const app = d.app;
    d.view.destroy();
    app.release(d.destroy, d.user_data);
    app.gpa().destroy(d);
}

fn create(w: *Window, parent: t.Node, ptr: ?*const t.DocviewDesc) Error!NodeId {
    if (!enabled) return error.Unsupported;
    const desc = try runtime.readDesc(t.DocviewDesc, ptr);
    const source = try runtime.array(u8, desc.source, desc.source_count);
    const base_url = try runtime.string(desc.base_url, desc.base_url_len);
    const user_css = try runtime.string(desc.user_css, desc.user_css_len);
    const kind = try runtime.enumValue(t.DocviewKind, desc.kind);
    const scheme = try runtime.enumValue(t.DocviewColorScheme, desc.color_scheme);
    const fl = try runtime.flags(t.DocviewFlags, desc.flags);
    if (!std.math.isFinite(desc.font_size) or desc.font_size < 0) return error.InvalidArgument;
    const self = w.owner;
    const gpa = self.gpa();
    const id = try tree.create(w, parent, .canvas);
    const d = try gpa.create(Doc);
    errdefer gpa.destroy(d);
    d.* = .{ .app = self, .w = w, .id = id, .view = undefined, .load = desc.load, .on_event = desc.on_event, .destroy = desc.destroy, .user_data = desc.user_data };
    d.view = docview.View.create(gpa, w.txn.ut, id, source, .{
        .kind = switch (kind) {
            .html => .html,
            .markdown => .markdown,
            .text => .text,
            else => return error.Unsupported,
        },
        .base_url = base_url,
        .user_css = user_css,
        .color_scheme = switch (scheme) {
            .theme => .theme,
            .light => .light,
            .dark => .dark,
            else => return error.Unsupported,
        },
        .remote_images = fl.remote_images,
        .author_styles = !fl.no_author_styles,
        .font_size = desc.font_size,
    }, .{ .ctx = d, .event = Doc.onEvent, .load = Doc.onLoad }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => |e| tree.mapTxn(e),
    };
    // The canvas slot owns the document: the node's end releases it.
    w.nodes.canvas(id).* = .{ .draw = null, .measure = null, .destroy = release, .user_data = d };
    return id;
}

pub export fn siv_docview(txn: t.Txn, parent: t.Node, desc: ?*const t.DocviewDesc) t.Node {
    return tree.build(txn, create, .{ parent, desc });
}

/// The document of a node.
fn docOf(node: t.Node) Error!*Doc {
    if (!enabled) return error.Unsupported;
    const w, const id = try tree.lookup(node);
    const cb = w.nodes.canvas(id).* orelse return error.InvalidArgument;
    if (cb.destroy != release) return error.InvalidArgument;
    return @ptrCast(@alignCast(cb.user_data));
}

/// The document of a node, unless a job has it.
fn ready(node: t.Node) Error!*docview.View {
    const d = try docOf(node);
    if (d.view.document() == null) return error.Busy;
    return d.view;
}

fn copyOut(s: []const u8, ptr: ?[*]u8, cap: usize, len: ?*usize) Error!void {
    const buf = try runtime.buffer(ptr, cap);
    const dest = try runtime.out(usize, len);
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    dest.* = s.len;
}

pub export fn siv_docview_supply(node: t.Node, request: u32, data: ?[*]const u8, data_count: usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, r: u32, ptr: ?[*]const u8, len: usize) Error!void {
            const d = try docOf(n);
            const bytes = try runtime.array(u8, ptr, len);
            try d.view.supply(r, if (bytes.len == 0) null else bytes);
        }
    }.f(node, request, data, data_count));
}

pub export fn siv_docview_load_images(node: t.Node) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node) Error!void {
            (try docOf(n)).view.loadImages();
        }
    }.f(node));
}

pub export fn siv_docview_find(node: t.Node, text: ?[*]const u8, text_len: usize, backwards: bool) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]const u8, len: usize, back: bool) Error!void {
            const s = try runtime.string(ptr, len);
            try (try ready(n)).find(s, back);
        }
    }.f(node, text, text_len, backwards));
}

pub export fn siv_docview_get_selection(node: t.Node, text: ?[*]u8, text_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const v = try ready(n);
            const s = try v.selectedText(v.gpa);
            defer v.gpa.free(s);
            try copyOut(s, ptr, cap, out);
        }
    }.f(node, text, text_cap, len));
}

pub export fn siv_docview_select_all(node: t.Node) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node) Error!void {
            (try ready(n)).selectAll();
        }
    }.f(node));
}

pub export fn siv_docview_scroll_to(node: t.Node, fragment: ?[*]const u8, fragment_len: usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]const u8, len: usize) Error!void {
            const s = try runtime.string(ptr, len);
            if (!(try ready(n)).scrollToFragment(s)) return error.InvalidArgument;
        }
    }.f(node, fragment, fragment_len));
}

pub export fn siv_docview_get_locator(node: t.Node, y: f32, locator: ?[*]u8, locator_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, at: f32, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            if (!std.math.isFinite(at)) return error.InvalidArgument;
            const v = try ready(n);
            var s: std.ArrayList(u8) = .empty;
            defer s.deinit(v.gpa);
            try v.locatorAt(at, &s);
            try copyOut(s.items, ptr, cap, out);
        }
    }.f(node, y, locator, locator_cap, len));
}

pub export fn siv_docview_get_locator_y(node: t.Node, locator: ?[*]const u8, locator_len: usize, y: ?*f32) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]const u8, len: usize, out: ?*f32) Error!void {
            const s = try runtime.string(ptr, len);
            const dest = try runtime.out(f32, out);
            dest.* = (try ready(n)).locatorY(s) orelse return error.InvalidArgument;
        }
    }.f(node, locator, locator_len, y));
}

pub export fn siv_docview_get_title(node: t.Node, title: ?[*]u8, title_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const v = try ready(n);
            try copyOut(v.document().?.title, ptr, cap, out);
        }
    }.f(node, title, title_cap, len));
}
