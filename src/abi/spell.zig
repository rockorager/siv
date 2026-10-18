//! Exports for spell checking (D37, api_spell.zig). Editors' checking is
//! `ui.Spelling`'s; the application's dictionaries are its App's.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");

const App = application.App;
const Window = application.Window;
const Error = application.Error;

fn copyOut(buf: []u8, s: []const u8, len: *usize) void {
    const k = @min(s.len, buf.len);
    @memcpy(buf[0..k], s[0..k]);
    len.* = s.len;
}

pub export fn siv_set_spell_check(txn: t.Txn, node: t.Node, enabled: bool, language: ?[*]const u8, language_len: usize) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, on: bool, ptr: ?[*]const u8, len: usize) Error!void {
            const id = try tree.nodeIn(w, n);
            if (w.uiWin().node(id).kind != .editor) return error.InvalidArgument;
            const lang = try runtime.string(ptr, len);
            if (!std.unicode.utf8ValidateSlice(lang)) return error.InvalidArgument;
            w.txn.ut.setSpellCheck(id, on, lang) catch |err| return tree.mapTxn(err);
        }
    }.f, .{ node, enabled, language, language_len });
}

pub export fn siv_node_find_misspelling(node: t.Node, offset: u32, find: t.SpellFind, found: ?*bool, start: ?*u32, end: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, at: u32, how: t.SpellFind, found_out: ?*bool, start_out: ?*u32, end_out: ?*u32) Error!void {
            const w, const id = try tree.lookup(n);
            const f_dest = try runtime.out(bool, found_out);
            const s_dest = try runtime.out(u32, start_out);
            const e_dest = try runtime.out(u32, end_out);
            const uw = w.uiWin();
            if (uw.node(id).kind != .editor) return error.InvalidArgument;
            const r = ui.Spelling.find(uw, id, at, switch (try runtime.enumValue(t.SpellFind, how)) {
                .at => .at,
                .next => .next,
                .previous => .previous,
                _ => unreachable,
            });
            f_dest.* = r != null;
            s_dest.* = if (r) |x| x[0] else 0;
            e_dest.* = if (r) |x| x[1] else 0;
        }
    }.f(node, offset, find, found, start, end));
}

pub export fn siv_node_get_spell_language(node: t.Node, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const w, const id = try tree.lookup(n);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const uw = w.uiWin();
            if (uw.node(id).kind != .editor) return error.InvalidArgument;
            const l = ui.Spelling.langOf(uw, id);
            copyOut(buf, if (l) |x| x.name else "", dest);
        }
    }.f(node, buffer, buffer_cap, len));
}

pub export fn siv_editor_replace(node: t.Node, start: u32, end: u32, text: ?[*]const u8, text_len: usize) t.Result {
    return application.wrap(struct {
        fn f(n: t.Node, a: u32, b: u32, ptr: ?[*]const u8, len: usize) Error!void {
            const w, const id = try tree.lookup(n);
            if (w.owner.painting != 0) return error.Busy;
            const s = try runtime.string(ptr, len);
            const uw = w.uiWin();
            if (uw.txn.open) return error.Busy;
            ui.access.replaceText(uw, id, a, b, s) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidArgument,
            };
        }
    }.f(node, start, end, text, text_len));
}

/// The application's spelling and the loaded dictionary for a language
/// (empty: the application's).
fn langOf(self: *App, ptr: ?[*]const u8, len: usize) Error!*ui.Spelling.Lang {
    var tag = try runtime.string(ptr, len);
    if (tag.len == 0) tag = self.app.fonts.name(self.app.language);
    if (tag.len == 0) tag = ui.Spelling.default_language;
    return try self.app.spelling.langNow(tag) orelse error.Unavailable;
}

fn word(ptr: ?[*]const u8, len: usize) Error![]const u8 {
    const w = try runtime.string(ptr, len);
    if (!std.unicode.utf8ValidateSlice(w)) return error.InvalidArgument;
    return w;
}

pub export fn siv_app_check_spelling(app: t.App, language: ?[*]const u8, language_len: usize, w: ?[*]const u8, w_len: usize, correct: ?*bool) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, lp: ?[*]const u8, ll: usize, wp: ?[*]const u8, wl: usize, out: ?*bool) Error!void {
            const self = try App.get(@backingInt(a));
            const dest = try runtime.out(bool, out);
            const wd = try word(wp, wl);
            const l = try langOf(self, lp, ll);
            dest.* = l.check(wd);
        }
    }.f(app, language, language_len, w, w_len, correct));
}

pub export fn siv_app_suggest_spelling(app: t.App, language: ?[*]const u8, language_len: usize, w: ?[*]const u8, w_len: usize, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, lp: ?[*]const u8, ll: usize, wp: ?[*]const u8, wl: usize, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const self = try App.get(@backingInt(a));
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const wd = try word(wp, wl);
            const l = try langOf(self, lp, ll);
            const gpa = self.app.gpa;
            const list = try ui.Spelling.suggest(l, gpa, wd);
            defer {
                for (list) |s| gpa.free(s);
                gpa.free(list);
            }
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(gpa);
            for (list, 0..) |s, i| {
                if (i != 0) try joined.append(gpa, '\n');
                try joined.appendSlice(gpa, s);
            }
            copyOut(buf, joined.items, dest);
        }
    }.f(app, language, language_len, w, w_len, buffer, buffer_cap, len));
}

pub export fn siv_app_add_spelling_word(app: t.App, language: ?[*]const u8, language_len: usize, w: ?[*]const u8, w_len: usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, lp: ?[*]const u8, ll: usize, wp: ?[*]const u8, wl: usize) Error!void {
            const self = try App.get(@backingInt(a));
            const wd = try word(wp, wl);
            const l = try langOf(self, lp, ll);
            try self.app.spelling.addWord(l, wd);
        }
    }.f(app, language, language_len, w, w_len));
}

pub export fn siv_app_ignore_spelling_word(app: t.App, language: ?[*]const u8, language_len: usize, w: ?[*]const u8, w_len: usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, lp: ?[*]const u8, ll: usize, wp: ?[*]const u8, wl: usize) Error!void {
            const self = try App.get(@backingInt(a));
            const wd = try word(wp, wl);
            const l = try langOf(self, lp, ll);
            try self.app.spelling.ignoreWord(l, wd);
        }
    }.f(app, language, language_len, w, w_len));
}

pub export fn siv_app_add_dictionary(app: t.App, name: ?[*]const u8, name_len: usize, aff: ?[*]const u8, aff_count: usize, dic: ?[*]const u8, dic_count: usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, np: ?[*]const u8, nl: usize, ap: ?[*]const u8, al: usize, dp: ?[*]const u8, dl: usize) Error!void {
            const self = try App.get(@backingInt(a));
            const n = try runtime.string(np, nl);
            if (n.len == 0 or n.len > 64 or std.mem.indexOfAny(u8, n, "/\x00\n") != null or !std.unicode.utf8ValidateSlice(n)) return error.InvalidArgument;
            try self.app.spelling.addDictionary(n, try runtime.array(u8, ap, al), try runtime.array(u8, dp, dl));
        }
    }.f(app, name, name_len, aff, aff_count, dic, dic_count));
}

pub export fn siv_app_get_dictionaries(app: t.App, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const self = try App.get(@backingInt(a));
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const gpa = self.app.gpa;
            const names = try self.app.spelling.dictionaryNames(gpa);
            defer gpa.free(names);
            const joined = try std.mem.join(gpa, "\n", names);
            defer gpa.free(joined);
            copyOut(buf, joined, dest);
        }
    }.f(app, buffer, buffer_cap, len));
}
