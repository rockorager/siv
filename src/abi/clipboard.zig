//! Exports for the clipboard and primary selection (D19): what editors do
//! with Ctrl+C and Ctrl+V, for applications. Copies and pastes go through
//! the application's ui.Clipboard with the window's seat and latest input
//! serial; pasted text reaches C in the dispatch phase (D5).
//! siv_clipboard_write_data and siv_clipboard_read_data do the same for
//! any MIME types, such as a file manager's copied files.

const std = @import("std");
const t = @import("siv");
const platform = @import("platform");
const ui = @import("ui");
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

// Any MIME type ------------------------------------------------------------

/// Splits a descriptor's MIME lines and data into items, as drags do.
fn items(gpa: std.mem.Allocator, mimes: []const u8, data: []const u8, lengths: []const usize, out: *std.ArrayList(ui.Clipboard.DragItem)) Error!void {
    var it = std.mem.tokenizeScalar(u8, mimes, '\n');
    var offset: usize = 0;
    while (it.next()) |m| {
        const i = out.items.len;
        const bytes = if (lengths.len == 0) data else blk: {
            if (i >= lengths.len or lengths[i] > data.len - offset) return error.InvalidArgument;
            defer offset += lengths[i];
            break :blk data[offset..][0..lengths[i]];
        };
        try out.append(gpa, .{ .mime = m, .data = bytes });
    }
    if (out.items.len == 0) return error.InvalidArgument;
    if (lengths.len != 0 and (lengths.len != out.items.len or offset != data.len)) return error.InvalidArgument;
}

pub export fn siv_clipboard_write_data(window: t.Window, selection: t.Selection, desc: ?*const t.ClipboardDesc) t.Result {
    return application.wrap(writeData(window, selection, desc));
}

fn writeData(window: t.Window, selection: t.Selection, d_ptr: ?*const t.ClipboardDesc) Error!void {
    const w = try App.window(@backingInt(window), application.window_tag);
    const self = w.owner;
    const d = try runtime.readDesc(t.ClipboardDesc, d_ptr);
    const kind = try kindOf(selection);
    const mimes = try runtime.string(d.mimes, d.mimes_len);
    const data = try runtime.array(u8, d.data, d.data_count);
    const lengths = try runtime.array(usize, d.lengths, d.lengths_count);
    var list: std.ArrayList(ui.Clipboard.DragItem) = .empty;
    defer list.deinit(self.gpa());
    try items(self.gpa(), mimes, data, lengths, &list);
    const input = &w.uiWin().input;
    try self.app.clipboard.copyItems(kind, input.seat, input.serial, list.items);
}

/// A siv_clipboard_read_data in flight: the types asked for, then what
/// came back, delivered by a post so that the callback never runs inside
/// the call and only the destroy-notify runs at teardown (D5).
const ReadData = struct {
    owner: *App,
    callback: t.ClipboardDataFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
    /// The MIME lines asked for (owned) and slices into them.
    lines: []u8,
    prefs: [][]const u8,
    mime: usize = 0,
    data: ?[]u8 = null,

    fn arrived(ctx: *anyopaque, mime: usize, data: ?[]const u8) void {
        const r: *ReadData = @ptrCast(@alignCast(ctx));
        const self = r.owner;
        r.mime = mime;
        r.data = if (data) |bytes| self.gpa().dupe(u8, bytes) catch null else null;
        self.app.post(deliver, drop, r) catch drop(r);
    }

    fn text(_: *anyopaque, _: ?[]const u8) void {
        unreachable; // typed reads only
    }

    fn deliver(ctx: ?*anyopaque) callconv(.c) void {
        const r: *ReadData = @ptrCast(@alignCast(ctx));
        const self = r.owner;
        var out: t.ClipboardData = .{ .result = .error_unavailable };
        if (r.data) |bytes| {
            const m = r.prefs[r.mime];
            out = .{ .mime = m.ptr, .mime_len = m.len, .data = bytes.ptr, .data_count = bytes.len, .result = .ok, .index = @intCast(r.mime) };
        }
        self.enter();
        r.callback(r.user_data, &out);
        self.leave();
    }

    fn drop(ctx: ?*anyopaque) callconv(.c) void {
        const r: *ReadData = @ptrCast(@alignCast(ctx));
        const self = r.owner;
        const gpa = self.gpa();
        const destroy, const user_data = .{ r.destroy, r.user_data };
        if (r.data) |bytes| {
            std.crypto.secureZero(u8, bytes);
            gpa.free(bytes);
        }
        gpa.free(r.prefs);
        gpa.free(r.lines);
        gpa.destroy(r);
        self.release(destroy, user_data);
    }
};

pub export fn siv_clipboard_read_data(window: t.Window, selection: t.Selection, mimes: ?[*]const u8, mimes_len: usize, callback: ?t.ClipboardDataFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const w = App.window(@backingInt(window), application.window_tag) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const self = w.owner;
    readData(w, selection, mimes, mimes_len, callback, destroy, user_data) catch |err| {
        // Ownership of user_data passed with the call (D2).
        self.release(destroy, user_data);
        return t.resultOf(err);
    };
    return .ok;
}

fn readData(w: *application.Window, selection: t.Selection, mimes_ptr: ?[*]const u8, mimes_len: usize, callback: ?t.ClipboardDataFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) Error!void {
    const self = w.owner;
    const gpa = self.gpa();
    const cb = callback orelse return error.InvalidArgument;
    const kind = try kindOf(selection);
    const mimes = try runtime.string(mimes_ptr, mimes_len);
    const lines = try gpa.dupe(u8, mimes);
    errdefer gpa.free(lines);
    var prefs: std.ArrayList([]const u8) = .empty;
    errdefer prefs.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, lines, '\n');
    while (it.next()) |m| try prefs.append(gpa, m);
    if (prefs.items.len == 0) return error.InvalidArgument;
    const r = try gpa.create(ReadData);
    errdefer gpa.destroy(r);
    const owned = try prefs.toOwnedSlice(gpa);
    r.* = .{ .owner = self, .callback = cb, .destroy = destroy, .user_data = user_data, .lines = lines, .prefs = owned };
    const uw = w.uiWin();
    // The window owns the read: if it goes, the read ends unavailable.
    self.app.clipboard.pasteTypes(kind, uw.input.seat, r.prefs, uw, .{ .ctx = r, .func = ReadData.text, .typed = ReadData.arrived });
}
