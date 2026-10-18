//! Exports for locale-aware dates and times, the installed font families,
//! and the emoji catalogue (D41, api_pickers.zig): the intl module's
//! tables, and the application's language and fonts.

const std = @import("std");
const t = @import("siv");
const intl = @import("intl");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Error = application.Error;
const cldr = intl.cldr;
const emoji = intl.emoji;

fn copyOut(buf: []u8, s: []const u8, len: *usize) void {
    const k = @min(s.len, buf.len);
    @memcpy(buf[0..k], s[0..k]);
    len.* = s.len;
}

fn localeOf(self: *App) cldr.Locale {
    return cldr.Locale.find(self.app.fonts.name(self.app.language));
}

pub export fn siv_app_get_locale_info(app: t.App, info: ?*t.LocaleInfo) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, out: ?*t.LocaleInfo) Error!void {
            const self = try App.get(@backingInt(a));
            const dest = try runtime.out(t.LocaleInfo, out);
            const l = localeOf(self);
            dest.* = .{
                .first_weekday = l.first_day,
                .hour_cycle = switch (l.hourCycle()) {
                    .h12 => .h12,
                    .h23 => .h23,
                    .h11 => .h11,
                    .h24 => .h24,
                },
                .flags = .{ .period_first = l.periodFirst() },
                .time_separator = l.timeSeparator(),
            };
        }
    }.f(app, info));
}

/// Formats into a buffer large enough for any date or time a pattern
/// writes, then copies what fits.
fn format(buf: []u8, len: *usize, comptime func: anytype, args: anytype) void {
    var tmp: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&tmp);
    @call(.auto, func, .{&w} ++ args) catch {};
    copyOut(buf, w.buffered(), len);
}

pub export fn siv_app_format_date(app: t.App, days: i32, style: t.DateStyle, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, d: i32, st: t.DateStyle, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const self = try App.get(@backingInt(a));
            const s = try runtime.enumValue(t.DateStyle, st);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const l = localeOf(self);
            const Fmt = struct {
                fn run(w: *std.Io.Writer, loc: cldr.Locale, day: i64, style_: cldr.DateStyle) std.Io.Writer.Error!void {
                    try loc.formatDate(w, day, style_);
                }
            };
            format(buf, dest, Fmt.run, .{ l, @as(i64, d), @as(cldr.DateStyle, @enumFromInt(@backingInt(s))) });
        }
    }.f(app, days, style, buffer, buffer_cap, len));
}

pub export fn siv_app_format_time(app: t.App, seconds: u32, style: t.TimeStyle, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, secs: u32, st: t.TimeStyle, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const self = try App.get(@backingInt(a));
            const s = try runtime.enumValue(t.TimeStyle, st);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const l = localeOf(self);
            const Fmt = struct {
                fn run(w: *std.Io.Writer, loc: cldr.Locale, x: u32, style_: cldr.TimeStyle) std.Io.Writer.Error!void {
                    try loc.formatTime(w, x, style_);
                }
            };
            format(buf, dest, Fmt.run, .{ l, secs, @as(cldr.TimeStyle, @enumFromInt(@backingInt(s))) });
        }
    }.f(app, seconds, style, buffer, buffer_cap, len));
}

pub export fn siv_app_get_font_family_count(app: t.App, count: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, out: ?*u32) Error!void {
            const self = try App.get(@backingInt(a));
            const dest = try runtime.out(u32, out);
            dest.* = @intCast((try self.app.fonts.installed()).len);
        }
    }.f(app, count));
}

pub export fn siv_app_get_font_family_at(app: t.App, index: u32, id: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, i: u32, out: ?*u32) Error!void {
            const self = try App.get(@backingInt(a));
            const dest = try runtime.out(u32, out);
            const list = try self.app.fonts.installed();
            if (i >= list.len) return error.InvalidArgument;
            dest.* = list[i];
        }
    }.f(app, index, id));
}

pub export fn siv_emoji_get_count() u32 {
    return emoji.count;
}

fn toneOf(tone: t.SkinTone) Error!emoji.Tone {
    return @intCast(@backingInt(try runtime.enumValue(t.SkinTone, tone)));
}

pub export fn siv_emoji_get(index: u32, tone: t.SkinTone, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(i: u32, tn: t.SkinTone, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const tone_ = try toneOf(tn);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            if (i >= emoji.count) return error.InvalidArgument;
            copyOut(buf, emoji.sequence(i, tone_), dest);
        }
    }.f(index, tone, buffer, buffer_cap, len));
}

pub export fn siv_emoji_get_name(index: u32, tone: t.SkinTone, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(i: u32, tn: t.SkinTone, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const tone_ = try toneOf(tn);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            if (i >= emoji.count) return error.InvalidArgument;
            var tmp: [256]u8 = undefined;
            copyOut(buf, emoji.name(&tmp, i, tone_), dest);
        }
    }.f(index, tone, buffer, buffer_cap, len));
}

pub export fn siv_emoji_get_info(index: u32, info: ?*t.EmojiInfo) t.Result {
    return application.wrap(struct {
        fn f(i: u32, out: ?*t.EmojiInfo) Error!void {
            const dest = try runtime.out(t.EmojiInfo, out);
            if (i >= emoji.count) return error.InvalidArgument;
            dest.* = .{ .group = @enumFromInt(emoji.group(i)), .flags = .{ .skin_tones = emoji.takesTone(i) } };
        }
    }.f(index, info));
}

pub export fn siv_emoji_find(query: ?[*]const u8, query_len: usize, start: u32, found: ?*bool, index: ?*u32) t.Result {
    return application.wrap(struct {
        fn f(q_ptr: ?[*]const u8, q_len: usize, from: u32, found_out: ?*bool, index_out: ?*u32) Error!void {
            const q = try runtime.string(q_ptr, q_len);
            const f_dest = try runtime.out(bool, found_out);
            const i_dest = try runtime.out(u32, index_out);
            var i = from;
            while (i < emoji.count) : (i += 1) if (emoji.matches(i, q)) break;
            f_dest.* = i < emoji.count;
            i_dest.* = @min(i, emoji.count);
        }
    }.f(query, query_len, start, found, index));
}
