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
    pub const epub = struct {
        pub const Book = struct {
            title: []const u8 = "",
            author: []const u8 = "",
            language: []const u8 = "",
            identifier: []const u8 = "",
            spine: []const struct { item: u32 } = &.{},
            manifest: []const struct { path: []const u8 } = &.{},
            toc: []const struct { label: []const u8, path: []const u8, fragment: []const u8, depth: u8 } = &.{},
            pub fn destroy(_: *Book) void {}
            pub fn open(_: std.mem.Allocator, _: []const u8) error{ OutOfMemory, NotEpub }!*Book {
                return error.NotEpub;
            }
            pub fn spineIndex(_: *const Book, _: []const u8) ?usize {
                return null;
            }
        };
    };
    pub const ResourceKind = enum { stylesheet, image, font };
    pub const Event = union(enum) { link: struct { url: []const u8, rel: []const u8 }, loaded, size: f32, find: struct { count: u32, current: u32 }, selection, blocked_images: u32, page: struct { index: u32, count: u32 } };
    pub const View = struct {
        gpa: std.mem.Allocator,
        page: u32 = 0,
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
        pub fn setPage(_: *View, _: u32) void {}
        pub fn pageCount(_: *const View) u32 {
            return 1;
        }
        pub fn goTo(_: *View, _: []const u8) bool {
            return false;
        }
        pub fn positionLocator(_: *View, _: *std.ArrayList(u8)) error{OutOfMemory}!void {}
        pub fn setUserCss(_: *View, _: []const u8) error{OutOfMemory}!void {}
        pub fn elementHtml(_: *View, _: []const u8, _: *std.ArrayList(u8)) error{OutOfMemory}!bool {
            return false;
        }
    };
};

const App = application.App;
const Root = runtime.Root;
pub const epub_tag = @import("api.zig").spec.handleTag("siv_epub");

/// An open publication, shared by its handle and the document nodes
/// showing it.
pub const Epub = struct {
    book: *docview.epub.Book,
    refs: u32 = 1,
    handle: u64 = 0,

    fn unref(e: *Epub, gpa: std.mem.Allocator) void {
        e.refs -= 1;
        if (e.refs > 0) return;
        e.book.destroy();
        gpa.destroy(e);
    }
};

/// The application goes: its publications too.
pub fn teardown(self: *App) void {
    const gpa = self.gpa();
    for (self.epubs.items) |slot| if (slot) |e| {
        _ = self.root.handles.remove(e.handle, epub_tag) catch {};
        e.handle = 0;
        e.unref(gpa);
    };
    self.epubs.deinit(gpa);
}

fn epubOf(handle: t.Epub) Error!*Epub {
    if (!enabled) return error.Unsupported;
    const self, const index = try Root.owner(App, application.app_tag, @backingInt(handle), epub_tag);
    return self.epubs.items[index] orelse error.InvalidHandle;
}
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
    epub: ?*Epub = null,

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
            .link => |l| {
                e.type = .link;
                e.url = l.url.ptr;
                e.url_len = l.url.len;
                e.rel = l.rel.ptr;
                e.rel_len = l.rel.len;
            },
            .page => |pg| {
                e.type = .page;
                e.current = pg.index;
                e.count = pg.count;
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
    if (d.epub) |e| e.unref(app.gpa());
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
    const epub_path = try runtime.string(desc.epub_path, desc.epub_path_len);
    const pub_: ?*Epub = if (@backingInt(desc.epub) != 0) try epubOf(desc.epub) else null;
    if (!std.math.isFinite(desc.font_size) or desc.font_size < 0) return error.InvalidArgument;
    const self = w.owner;
    const gpa = self.gpa();
    const id = try tree.create(w, parent, .canvas);
    const d = try gpa.create(Doc);
    errdefer gpa.destroy(d);
    d.* = .{ .app = self, .w = w, .id = id, .view = undefined, .load = desc.load, .on_event = desc.on_event, .destroy = desc.destroy, .user_data = desc.user_data };
    if (pub_) |e| {
        e.refs += 1;
        d.epub = e;
    }
    errdefer if (d.epub) |e| e.unref(gpa);
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
        .untrusted = fl.untrusted,
        .collapse_quotes = fl.collapse_quotes,
        .paged = fl.paged,
        .spread = fl.spread,
        .reading = fl.reading,
        .book = if (pub_) |e| e.book else null,
        .book_path = epub_path,
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

// Publications ----------------------------------------------------------------

pub export fn siv_epub_open(app: t.App, data: ?[*]const u8, data_count: usize, out_epub: ?*t.Epub) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, ptr: ?[*]const u8, len: usize, o: ?*t.Epub) Error!void {
            if (!enabled) return error.Unsupported;
            const self = try App.get(@backingInt(a));
            const bytes = try runtime.array(u8, ptr, len);
            const dest = try runtime.out(t.Epub, o);
            const gpa = self.gpa();
            var index: usize = self.epubs.items.len;
            for (self.epubs.items, 0..) |slot, i| if (slot == null) {
                index = i;
                break;
            };
            if (index == self.epubs.items.len) try self.epubs.append(gpa, null);
            try self.root.handles.ensureUnusedCapacity(gpa);
            const book = docview.epub.Book.open(gpa, bytes) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidArgument,
            };
            errdefer book.destroy();
            const e = try gpa.create(Epub);
            e.* = .{ .book = book };
            e.handle = self.root.handles.insert(gpa, epub_tag, @intCast(index)) catch unreachable;
            self.epubs.items[index] = e;
            dest.* = @fromBackingInt(e.handle);
        }
    }.f(app, data, data_count, out_epub));
}

pub export fn siv_epub_destroy(epub: t.Epub) void {
    if (!enabled) return;
    const self, const index = Root.owner(App, application.app_tag, @backingInt(epub), epub_tag) catch return;
    const e = self.epubs.items[index] orelse return;
    _ = self.root.handles.remove(e.handle, epub_tag) catch {};
    self.epubs.items[index] = null;
    e.handle = 0;
    e.unref(self.gpa());
}

pub export fn siv_epub_get_counts(epub: t.Epub, spine: ?*u32, toc: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(h: t.Epub, s: ?*u32, tc: ?*u32) Error!void {
            const e = try epubOf(h);
            const ds = try runtime.out(u32, s);
            const dt = try runtime.out(u32, tc);
            ds.* = @intCast(e.book.spine.len);
            dt.* = @intCast(e.book.toc.len);
        }
    }.f(epub, spine, toc));
}

pub export fn siv_epub_get_metadata(epub: t.Epub, field: t.EpubField, text: ?[*]u8, text_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.Epub, fl: t.EpubField, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const e = try epubOf(h);
            const b = e.book;
            const v = switch (try runtime.enumValue(t.EpubField, fl)) {
                .title => b.title,
                .author => b.author,
                .language => b.language,
                .identifier => b.identifier,
                else => return error.Unsupported,
            };
            try copyOut(v, ptr, cap, out);
        }
    }.f(epub, field, text, text_cap, len));
}

pub export fn siv_epub_get_spine_path(epub: t.Epub, index: u32, path: ?[*]u8, path_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(h: t.Epub, i: u32, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const b = (try epubOf(h)).book;
            if (i >= b.spine.len) return error.InvalidArgument;
            try copyOut(b.manifest[b.spine[i].item].path, ptr, cap, out);
        }
    }.f(epub, index, path, path_cap, len));
}

pub export fn siv_epub_get_toc_label(epub: t.Epub, index: u32, label: ?[*]u8, label_cap: usize, len: ?*usize, depth: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(h: t.Epub, i: u32, ptr: ?[*]u8, cap: usize, out: ?*usize, dp: ?*u32) Error!void {
            const b = (try epubOf(h)).book;
            if (i >= b.toc.len) return error.InvalidArgument;
            const dd = try runtime.out(u32, dp);
            dd.* = b.toc[i].depth;
            try copyOut(b.toc[i].label, ptr, cap, out);
        }
    }.f(epub, index, label, label_cap, len, depth));
}

pub export fn siv_epub_get_toc_target(epub: t.Epub, index: u32, fragment: ?[*]u8, fragment_cap: usize, len: ?*usize, spine: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(h: t.Epub, i: u32, ptr: ?[*]u8, cap: usize, out: ?*usize, sp: ?*u32) Error!void {
            const b = (try epubOf(h)).book;
            if (i >= b.toc.len) return error.InvalidArgument;
            const ds = try runtime.out(u32, sp);
            ds.* = if (b.spineIndex(b.toc[i].path)) |k| @intCast(k) else std.math.maxInt(u32);
            var buf: [512]u8 = undefined;
            const frag = b.toc[i].fragment;
            const s = if (frag.len == 0) "" else std.fmt.bufPrint(&buf, "#{s}", .{frag}) catch return error.LimitExceeded;
            try copyOut(s, ptr, cap, out);
        }
    }.f(epub, index, fragment, fragment_cap, len, spine));
}

// Pages and positions ------------------------------------------------------------

pub export fn siv_docview_set_page(node: t.Node, index: u32) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, i: u32) Error!void {
            (try ready(n)).setPage(i);
        }
    }.f(node, index));
}

pub export fn siv_docview_get_page(node: t.Node, index: ?*u32, count: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ip: ?*u32, cp: ?*u32) Error!void {
            const v = try ready(n);
            const di = try runtime.out(u32, ip);
            const dc = try runtime.out(u32, cp);
            di.* = v.page;
            dc.* = v.pageCount();
        }
    }.f(node, index, count));
}

pub export fn siv_docview_go_to(node: t.Node, target: ?[*]const u8, target_len: usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]const u8, len: usize) Error!void {
            const s = try runtime.string(ptr, len);
            if (!(try ready(n)).goTo(s)) return error.InvalidArgument;
        }
    }.f(node, target, target_len));
}

pub export fn siv_docview_get_position(node: t.Node, locator: ?[*]u8, locator_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const v = try ready(n);
            var s: std.ArrayList(u8) = .empty;
            defer s.deinit(v.gpa);
            try v.positionLocator(&s);
            try copyOut(s.items, ptr, cap, out);
        }
    }.f(node, locator, locator_cap, len));
}

pub export fn siv_docview_set_user_css(node: t.Node, css: ?[*]const u8, css_len: usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]const u8, len: usize) Error!void {
            const s = try runtime.string(ptr, len);
            try (try docOf(n)).view.setUserCss(s);
        }
    }.f(node, css, css_len));
}

pub export fn siv_docview_get_element_html(node: t.Node, id: ?[*]const u8, id_len: usize, html: ?[*]u8, html_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ip: ?[*]const u8, il: usize, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const v = try ready(n);
            const key = try runtime.string(ip, il);
            var s: std.ArrayList(u8) = .empty;
            defer s.deinit(v.gpa);
            if (!try v.elementHtml(key, &s)) return error.InvalidArgument;
            try copyOut(s.items, ptr, cap, out);
        }
    }.f(node, id, id_len, html, html_cap, len));
}
