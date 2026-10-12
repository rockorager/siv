//! Exports for printing and PDF output (D9, D19). A document's pages are
//! drawn with the siv_draw_* functions (canvas.zig) into display lists,
//! which the `pdf` module writes; siv_print hands the PDF to the Print
//! portal (`portal.print`) after its dialog chose the page setup.
//!
//! Pages are drawn at a dispatch, never inside the call that started the
//! job. Text drawn while a font is still loading draws the document again
//! once fonts finish loading (canvas.onFontsLoaded), a few times at most.
//! Destroying the application drops unfinished jobs and runs their
//! destroy-notifies.

const std = @import("std");
const linux = std.os.linux;
const t = @import("siv");
const app_mod = @import("app");
const portal = @import("portal");
const loop_mod = @import("loop");
const pdf = @import("pdf");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const canvas = @import("canvas.zig");

const App = application.App;
const Error = application.Error;
const Loop = loop_mod.Loop;
const Parent = app_mod.portals.Parent;
const List = std.DoublyLinkedList;
const PageSetup = portal.print.PageSetup;

/// Drawing passes before a document is written with the fonts it has.
const max_passes = 3;

pub const State = struct {
    jobs: List = .{},
};

pub fn teardown(self: *App) void {
    while (self.desktop.prints.jobs.popFirst()) |n| {
        const j: *Job = @fieldParentPtr("node", n);
        j.free();
    }
}

/// Fonts finished loading: documents waiting for them draw again.
pub fn onFontsLoaded(self: *App) void {
    var it = self.desktop.prints.jobs.first;
    while (it) |n| : (it = n.next) {
        const j: *Job = @fieldParentPtr("node", n);
        if (j.stage == .fonts) {
            j.stage = .render;
            self.app.loop.schedule(&j.task, .dispatch);
        }
    }
}

const Job = struct {
    self: *App,
    node: List.Node = .{},
    title: []u8,
    user_data: ?*anyopaque,
    begin: ?t.PrintBeginFn,
    draw_page: t.PrintPageFn,
    done: ?t.PortalFn,
    destroy: ?t.DestroyFn,
    page_count: u32,
    setup: PageSetup,
    modal: bool,
    /// siv_pdf_write's destination; -1 for printing.
    fd: i32,
    window: ?*app_mod.Window = null,
    stage: Stage,
    passes: u8 = 0,
    pages: u32 = 0,
    task: Loop.Task = .{ .func = onTask },
    parent: Parent = .{ .func = onParent },
    parent_id: [300]u8 = undefined,
    parent_len: usize = 0,
    req: portal.Request = .{ .func = onResponse },
    token: u32 = 0,
    response: t.PortalResponse = .failed,

    const Stage = enum {
        /// Ends with `response` at the next dispatch, such as without a
        /// portal.
        ending,
        /// Waiting for the dialog's parent id or response.
        dialog,
        /// Drawing at the next dispatch.
        render,
        /// Waiting for fonts to load before drawing again.
        fonts,
        /// Waiting for the Print call's response.
        printing,
    };

    fn free(j: *Job) void {
        const self = j.self;
        j.parent.cancel();
        j.req.abandon();
        self.app.loop.unschedule(&j.task);
        if (j.fd >= 0) _ = linux.close(j.fd);
        self.release(j.destroy, j.user_data);
        self.gpa().free(j.title);
        self.gpa().destroy(j);
    }

    fn finish(j: *Job, response: t.PortalResponse) void {
        const self = j.self;
        self.desktop.prints.jobs.remove(&j.node);
        if (j.done) |f| {
            var r: t.PortalResult = .{ .response = response, .count = if (response == .success) j.pages else 0 };
            self.enter();
            f(j.user_data, &r);
            self.leave();
        }
        j.free();
    }

    fn onTask(task: *Loop.Task) void {
        const j: *Job = @fieldParentPtr("task", task);
        switch (j.stage) {
            .ending => j.finish(j.response),
            .render => j.render(),
            else => {},
        }
    }

    /// Ends at the next dispatch: this may run inside siv_print.
    fn end(j: *Job, response: t.PortalResponse) void {
        j.stage = .ending;
        j.response = response;
        j.self.app.loop.schedule(&j.task, .dispatch);
    }

    fn onParent(pa: *Parent, id: []const u8) void {
        const j: *Job = @fieldParentPtr("parent", pa);
        const client = j.self.app.portals.get() orelse return j.end(.unavailable);
        const n = @min(id.len, j.parent_id.len);
        @memcpy(j.parent_id[0..n], id[0..n]);
        j.parent_len = n;
        portal.print.prepare(&j.req, client, j.parent_id[0..n], j.title, .{ .modal = j.modal }) catch return j.end(.failed);
    }

    fn onResponse(r: *portal.Request, outcome: portal.Request.Outcome) void {
        const j: *Job = @fieldParentPtr("req", r);
        const response: t.PortalResponse = switch (outcome) {
            .response => |res| switch (res.code) {
                .success => .success,
                .cancelled => .cancelled,
                .other => .ended,
            },
            .failed => |f| switch (f) {
                .unavailable => .unavailable,
                .failed, .disconnected => .failed,
            },
        };
        if (response != .success or j.stage == .printing) return j.finish(response);
        const results = &outcome.response.results;
        j.setup = PageSetup.of(results, j.setup);
        j.token = portal.print.token(results);
        j.stage = .render;
        j.render();
    }

    /// Draws every page and writes the PDF, or waits for fonts.
    fn render(j: *Job) void {
        const self = j.self;
        const gpa = self.gpa();
        var setup: t.PageSetup = .{
            .width = j.setup.width,
            .height = j.setup.height,
            .margin_top = j.setup.margin_top,
            .margin_right = j.setup.margin_right,
            .margin_bottom = j.setup.margin_bottom,
            .margin_left = j.setup.margin_left,
        };
        var count = j.page_count;
        if (j.begin) |b| {
            self.enter();
            count = b(j.user_data, &setup);
            self.leave();
        }
        var w = pdf.Writer.init(gpa, .{ .title = j.title, .creator = "siv" }) catch return j.finish(.failed);
        defer w.deinit();
        j.passes += 1;
        var wanted = false;
        for (0..count) |page| {
            wanted = (j.drawPage(&w, @intCast(page), &setup) catch return j.finish(.failed)) or wanted;
        }
        if (wanted and j.passes < max_passes) {
            j.stage = .fonts;
            return;
        }
        j.pages = count;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        w.finish(&out.writer) catch return j.finish(.failed);
        if (j.fd >= 0) {
            writeAll(j.fd, out.written()) catch return j.finish(.failed);
            return j.finish(.success);
        }
        // Printing: the PDF goes to the portal in a sealed-off memfd.
        const rc = linux.memfd_create("siv-print", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return j.finish(.failed);
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        writeAll(fd, out.written()) catch return j.finish(.failed);
        _ = linux.lseek(fd, 0, linux.SEEK.SET);
        const client = self.app.portals.get() orelse return j.finish(.failed);
        j.stage = .printing;
        portal.print.print(&j.req, client, j.parent_id[0..j.parent_len], j.title, fd, j.token, .{ .modal = j.modal }) catch return j.finish(.failed);
    }

    /// Draws one page into `w`; true if text wanted fonts still loading.
    fn drawPage(j: *Job, w: *pdf.Writer, page: u32, setup: *t.PageSetup) Error!bool {
        const self = j.self;
        const gpa = self.gpa();
        const d = &self.draw;
        d.builder.reset();
        d.clearPath();
        d.err = null;
        d.depth = 0;
        d.window = null;
        d.node = .none;
        d.wanted_fonts = false;
        defer d.dropImages(gpa);
        try self.root.handles.ensureUnusedCapacity(gpa);
        d.handle = self.root.handles.insert(gpa, canvas.draw_tag, 0) catch unreachable;
        self.enter();
        j.draw_page(j.user_data, @fromBackingInt(d.handle), page, setup);
        self.leave();
        _ = self.root.handles.remove(d.handle, canvas.draw_tag) catch unreachable;
        d.handle = 0;
        while (d.err == null and d.depth > 0) : (d.depth -= 1) d.builder.popLayer() catch |err| {
            d.err = canvas.mapScene(err);
        };
        // A page whose drawing failed is left blank, as a canvas is.
        const list = if (d.err == null) d.builder.finish(0) catch null else null;
        w.addPage(j.setup.width, j.setup.height, list orelse .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidArgument,
        };
        return d.wanted_fonts;
    }
};

fn writeAll(fd: i32, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR, .AGAIN => continue,
            else => return error.WriteFailed,
        }
    }
}

/// A call that took a destroy-notify and failed runs it (D2).
fn failed(self: *App, d: *const t.PrintDesc, err: Error) t.Result {
    self.release(d.destroy, d.user_data);
    return t.resultOf(err);
}

fn newJob(self: *App, d: *const t.PrintDesc, default: PageSetup, fd: i32) Error!*Job {
    const title = try runtime.string(d.title, d.title_len);
    const fl = try runtime.flags(t.PrintFlags, d.flags);
    const draw_page = d.draw_page orelse return error.InvalidArgument;
    var setup = default;
    if (d.width != 0 or d.height != 0) {
        if (!(std.math.isFinite(d.width) and std.math.isFinite(d.height) and d.width > 0 and d.height > 0 and d.width <= 14400 and d.height <= 14400)) return error.InvalidArgument;
        setup = .{ .width = d.width, .height = d.height };
    }
    const gpa = self.gpa();
    const j = try gpa.create(Job);
    errdefer gpa.destroy(j);
    j.* = .{
        .self = self,
        .title = try gpa.dupe(u8, title),
        .user_data = d.user_data,
        .begin = d.begin,
        .draw_page = draw_page,
        .done = d.done,
        .destroy = d.destroy,
        .page_count = d.page_count,
        .setup = setup,
        .modal = !fl.not_modal,
        .fd = fd,
        .stage = .render,
    };
    return j;
}

const a4: PageSetup = .{ .width = pdf.a4.width, .height = pdf.a4.height };

/// The application and descriptor of a call; a descriptor that cannot
/// be read has no destroy-notify to run.
fn start(app: t.App, desc: ?*const t.PrintDesc) Error!struct { *App, t.PrintDesc } {
    const d = try runtime.readDesc(t.PrintDesc, desc);
    const self = App.get(@backingInt(app)) catch |err| {
        if (d.destroy) |f| f(d.user_data);
        return err;
    };
    return .{ self, d };
}

pub export fn siv_pdf_write(app: t.App, desc: ?*const t.PrintDesc, fd: i32) t.Result {
    const self, const d = start(app, desc) catch |err| return t.resultOf(err);
    if (fd < 0) return failed(self, &d, error.InvalidArgument);
    const dup = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
    if (linux.errno(dup) != .SUCCESS) return failed(self, &d, error.InvalidArgument);
    const j = newJob(self, &d, a4, @intCast(dup)) catch |err| {
        _ = linux.close(@intCast(dup));
        return failed(self, &d, err);
    };
    self.desktop.prints.jobs.append(&j.node);
    self.app.loop.schedule(&j.task, .dispatch);
    return .ok;
}

pub export fn siv_print(app: t.App, window: t.Window, desc: ?*const t.PrintDesc) t.Result {
    const self, const d = start(app, desc) catch |err| return t.resultOf(err);
    var win: ?*app_mod.Window = null;
    if (window != .null) {
        const w = App.window(@backingInt(window), application.window_tag) catch |err| return failed(self, &d, err);
        if (w.owner != self) return failed(self, &d, error.InvalidArgument);
        win = w.win;
    }
    const j = newJob(self, &d, a4, -1) catch |err| return failed(self, &d, err);
    j.window = win;
    self.desktop.prints.jobs.append(&j.node);
    if (self.app.portals.get() == null) {
        j.end(.unavailable);
        return .ok;
    }
    j.stage = .dialog;
    app_mod.portals.parentOf(self.app, win, &j.parent);
    return .ok;
}
