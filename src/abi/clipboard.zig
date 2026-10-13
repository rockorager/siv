//! Exports for the clipboard and primary selection (D19): what editors do
//! with Ctrl+C and Ctrl+V, for applications. Copies and pastes go through
//! the application's ui.Clipboard with the window's seat and latest input
//! serial; pasted text reaches C in the dispatch phase (D5).

const std = @import("std");
const t = @import("siv");
const platform = @import("platform");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Error = application.Error;

fn kindOf(s: t.Selection) Error!platform.SelectionKind {
    return switch (try runtime.enumValue(t.Selection, s)) {
        .clipboard => .clipboard,
        .primary => .primary,
        _ => unreachable,
    };
}

pub export fn siv_clipboard_write(window: t.Window, selection: t.Selection, text: ?[*]const u8, text_len: usize) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window, sel: t.Selection, p: ?[*]const u8, n: usize) Error!void {
            const w = try App.window(@backingInt(wh), application.window_tag);
            const kind = try kindOf(sel);
            const s = try runtime.string(p, n);
            const uw = w.uiWin();
            try w.owner.app.clipboard.copy(kind, uw.input.seat, uw.input.serial, s);
        }
    }.f(window, selection, text, text_len));
}

/// One paste: the callback and its user data until the text arrives.
const Read = struct {
    app: *App,
    callback: t.ClipboardFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    /// Inside ui.Clipboard.paste, which completes there when this
    /// application owns the selection or nothing is offered. Such a paste
    /// is kept and posted, so the callback never runs inside
    /// siv_clipboard_read.
    calling: bool = true,
    early: bool = false,
    text: ?[]u8 = null,

    fn done(ctx: *anyopaque, data: ?[]const u8) void {
        const r: *Read = @ptrCast(@alignCast(ctx));
        if (r.calling) {
            r.early = true;
            if (data) |d| r.text = r.app.gpa().dupe(u8, d) catch null;
            return;
        }
        r.call(data);
        r.finish();
    }

    fn call(r: *Read, data: ?[]const u8) void {
        const self = r.app;
        // Teardown runs destroy-notifies only (D5).
        if (self.closing.load(.seq_cst)) return;
        self.enter();
        defer self.leave();
        if (data) |d| r.callback(r.user_data, d.ptr, d.len) else r.callback(r.user_data, null, 0);
    }

    fn finish(r: *Read) void {
        const self = r.app;
        const destroy, const user_data = .{ r.destroy, r.user_data };
        if (r.text) |s| {
            std.crypto.secureZero(u8, s);
            self.gpa().free(s);
        }
        self.gpa().destroy(r);
        self.release(destroy, user_data);
    }

    fn posted(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Read = @ptrCast(@alignCast(ctx));
        r.call(r.text);
    }

    /// After `posted`, or alone when the application went first.
    fn dropped(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Read = @ptrCast(@alignCast(ctx));
        r.finish();
    }
};

pub export fn siv_clipboard_read(window: t.Window, selection: t.Selection, callback: ?t.ClipboardFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const w = App.window(@backingInt(window), application.window_tag) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    read(w, selection, callback, destroy, user_data) catch |err| {
        // Ownership of user_data passed with the call (D2).
        w.owner.release(destroy, user_data);
        return t.resultOf(err);
    };
    return .ok;
}

fn read(w: *application.Window, selection: t.Selection, callback: ?t.ClipboardFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) Error!void {
    const self = w.owner;
    const cb = callback orelse return error.InvalidArgument;
    const kind = try kindOf(selection);
    const r = try self.gpa().create(Read);
    r.* = .{ .app = self, .callback = cb, .destroy = destroy, .user_data = user_data };
    const uw = w.uiWin();
    // The window owns the paste: destroying it ends the paste with no
    // text.
    self.app.clipboard.paste(kind, uw.input.seat, uw, .{ .ctx = r, .func = Read.done });
    r.calling = false;
    if (r.early) {
        self.app.post(Read.posted, Read.dropped, r) catch {
            // Without memory to post, the request goes without its
            // callback; user_data is released once.
            r.destroy = null;
            r.finish();
            return error.OutOfMemory;
        };
    }
}
