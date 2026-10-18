//! Exports for locale-aware dates, times, and numbers, plural rules, and
//! gettext translations (D21, D41, api_pickers.zig and api_intl.zig), the
//! installed font families, and the emoji catalogue: the intl module's
//! tables, and the application's language, catalogs, and fonts.

const std = @import("std");
const t = @import("siv");
const intl = @import("intl");
const runtime = @import("runtime.zig");
const application = @import("application.zig");

const App = application.App;
const Error = application.Error;
const cldr = intl.cldr;
const number = intl.number;
const emoji = intl.emoji;

fn copyOut(buf: []u8, s: []const u8, len: *usize) void {
    const k = @min(s.len, buf.len);
    @memcpy(buf[0..k], s[0..k]);
    len.* = s.len;
}

fn languageOf(self: *App) []const u8 {
    return self.app.fonts.name(self.app.language);
}

fn localeOf(self: *App) cldr.Locale {
    return cldr.Locale.find(languageOf(self));
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

fn numberOptions(desc: ?*const t.NumberFormatDesc) Error!number.Options {
    const d = try runtime.readDesc(t.NumberFormatDesc, desc);
    const style = try runtime.enumValue(t.NumberStyle, d.style);
    const fl = try runtime.flags(t.NumberFlags, d.flags);
    var o: number.Options = .{ .style = @enumFromInt(@backingInt(style)), .grouping = !fl.no_grouping };
    if (fl.fraction_digits) {
        if (d.max_fraction_digits > number.max_fraction or d.min_fraction_digits > d.max_fraction_digits) return error.InvalidArgument;
        o.fraction = .{ @intCast(d.min_fraction_digits), @intCast(d.max_fraction_digits) };
    }
    return o;
}

pub export fn siv_app_format_number(app: t.App, value: f64, format_desc: ?*const t.NumberFormatDesc, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, v: f64, desc: ?*const t.NumberFormatDesc, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const self = try App.get(@backingInt(a));
            const opts = try numberOptions(desc);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const Fmt = struct {
                fn run(w: *std.Io.Writer, loc: cldr.Locale, x: f64, o: number.Options) std.Io.Writer.Error!void {
                    try number.format(loc, w, x, o);
                }
            };
            format(buf, dest, Fmt.run, .{ localeOf(self), v, opts });
        }
    }.f(app, value, format_desc, buffer, buffer_cap, len));
}

pub export fn siv_app_parse_number(app: t.App, text: ?[*]const u8, text_len: usize, valid: ?*bool, value: ?*f64) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, ptr: ?[*]const u8, n: usize, valid_out: ?*bool, value_out: ?*f64) Error!void {
            const self = try App.get(@backingInt(a));
            const s = try runtime.string(ptr, n);
            const v_dest = try runtime.out(bool, valid_out);
            const x_dest = try runtime.out(f64, value_out);
            const x = number.parse(localeOf(self), s);
            v_dest.* = x != null;
            x_dest.* = x orelse 0;
        }
    }.f(app, text, text_len, valid, value));
}

pub export fn siv_app_get_plural_category(app: t.App, value: f64, kind: t.PluralType, format_desc: ?*const t.NumberFormatDesc, category: ?*t.PluralCategory) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, v: f64, k: t.PluralType, desc: ?*const t.NumberFormatDesc, out: ?*t.PluralCategory) Error!void {
            const self = try App.get(@backingInt(a));
            const kind_ = try runtime.enumValue(t.PluralType, k);
            const opts = try numberOptions(desc);
            const dest = try runtime.out(t.PluralCategory, out);
            const cat = number.category(localeOf(self), intl.plural.Rules.find(languageOf(self)), @enumFromInt(@backingInt(kind_)), v, opts);
            dest.* = @enumFromInt(@intFromEnum(cat));
        }
    }.f(app, value, kind, format_desc, category));
}

pub export fn siv_app_bind_text_domain(app: t.App, domain: ?[*]const u8, domain_len: usize, directory: ?[*]const u8, directory_len: usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, d_ptr: ?[*]const u8, d_len: usize, dir_ptr: ?[*]const u8, dir_len: usize) Error!void {
            const self = try App.get(@backingInt(a));
            const name = try runtime.string(d_ptr, d_len);
            const dir = try runtime.string(dir_ptr, dir_len);
            if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\x00") != null or std.mem.indexOfScalar(u8, dir, 0) != null) return error.InvalidArgument;
            try self.translations.bind(self.gpa(), name, dir);
        }
    }.f(app, domain, domain_len, directory, directory_len));
}

pub export fn siv_app_translate(app: t.App, message: ?*const t.TranslationDesc, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, desc: ?*const t.TranslationDesc, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.TranslationDesc, desc);
            const domain = try runtime.string(d.domain, d.domain_len);
            const context = try runtime.string(d.context, d.context_len);
            const text = try runtime.string(d.text, d.text_len);
            const plural = try runtime.string(d.plural, d.plural_len);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const s = try self.translations.translate(self.gpa(), languageOf(self), domain, context, text, plural.len > 0, plural, d.count);
            copyOut(buf, s, dest);
        }
    }.f(app, message, buffer, buffer_cap, len));
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
