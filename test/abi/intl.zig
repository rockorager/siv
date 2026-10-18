//! Numbers, plural categories, and gettext translations through the C
//! ABI (D21), in the application's language and following it when it
//! changes. The catalogs are written by the test (intl's .mo writer), so
//! no gettext tools are needed.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("abi");
const gettext = @import("intl").gettext;

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = @import("harness.zig").ok;

fn newApp() !t.App {
    var app: t.App = .null;
    try ok(c.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true, .no_system_icons = true } }, &app));
    return app;
}

fn setLanguage(app: t.App, lang: []const u8) !void {
    try ok(c.siv_app_set_language(app, lang.ptr, lang.len, .inherit));
}

var out_buf: [256]u8 = undefined;

fn fmt(app: t.App, value: f64, desc: ?*const t.NumberFormatDesc) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_app_format_number(app, value, desc, &out_buf, out_buf.len, &len));
    return out_buf[0..len];
}

fn category(app: t.App, value: f64, kind: t.PluralType, desc: ?*const t.NumberFormatDesc) !t.PluralCategory {
    var cat: t.PluralCategory = .other;
    try ok(c.siv_app_get_plural_category(app, value, kind, desc, &cat));
    return cat;
}

test "numbers in the application's language" {
    const app = try newApp();
    defer c.siv_app_destroy(app);
    // No language: English.
    try testing.expectEqualStrings("1,234.5", try fmt(app, 1234.5, null));
    try testing.expectEqualStrings("1.2K", try fmt(app, 1234, &.{ .style = .compact }));
    try testing.expectEqualStrings("53.2 kB", try fmt(app, 53_200, &.{ .style = .bytes }));
    try testing.expectEqualStrings("3.10", try fmt(app, 3.1, &.{ .flags = .{ .fraction_digits = true }, .min_fraction_digits = 2, .max_fraction_digits = 2 }));
    try testing.expectEqualStrings("3", try fmt(app, 3.1, &.{ .flags = .{ .fraction_digits = true } }));
    try testing.expectEqualStrings("1234567", try fmt(app, 1234567, &.{ .flags = .{ .no_grouping = true } }));
    // The full length, for a second call with a larger buffer.
    var len: usize = 0;
    try ok(c.siv_app_format_number(app, 1234.5, null, null, 0, &len));
    try testing.expectEqual(@as(usize, 7), len);
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_format_number(app, 1, &.{ .flags = .{ .fraction_digits = true }, .min_fraction_digits = 3, .max_fraction_digits = 2 }, &out_buf, out_buf.len, &len));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_format_number(app, 1, &.{ .flags = .{ .fraction_digits = true }, .max_fraction_digits = 16 }, &out_buf, out_buf.len, &len));
    try testing.expectEqual(t.Result.error_unsupported, c.siv_app_format_number(app, 1, &.{ .style = @enumFromInt(9) }, &out_buf, out_buf.len, &len));

    try setLanguage(app, "de-DE");
    try testing.expectEqualStrings("1.234,5", try fmt(app, 1234.5, null));
    try testing.expectEqualStrings("25\u{00A0}%", try fmt(app, 0.25, &.{ .style = .percent }));
    try setLanguage(app, "ar-EG");
    try testing.expectEqualStrings("١٬٢٣٤٫٥", try fmt(app, 1234.5, null));

    var valid = false;
    var value: f64 = 0;
    try ok(c.siv_app_parse_number(app, "١٬٢٣٤٫٥", "١٬٢٣٤٫٥".len, &valid, &value));
    try testing.expect(valid and value == 1234.5);
    try setLanguage(app, "de");
    try ok(c.siv_app_parse_number(app, "1.234,5", 7, &valid, &value));
    try testing.expect(valid and value == 1234.5);
    try ok(c.siv_app_parse_number(app, "zwölf", "zwölf".len, &valid, &value));
    try testing.expect(!valid and value == 0);
}

test "plural categories in the application's language" {
    const app = try newApp();
    defer c.siv_app_destroy(app);
    try testing.expectEqual(t.PluralCategory.one, try category(app, 1, .cardinal, null));
    // "1.0" is not one in English.
    try testing.expectEqual(t.PluralCategory.other, try category(app, 1, .cardinal, &.{ .flags = .{ .fraction_digits = true }, .min_fraction_digits = 1, .max_fraction_digits = 1 }));
    try testing.expectEqual(t.PluralCategory.two, try category(app, 22, .ordinal, null));
    try testing.expectEqual(t.PluralCategory.few, try category(app, 103, .ordinal, null));
    try setLanguage(app, "ru_RU.UTF-8");
    try testing.expectEqual(t.PluralCategory.few, try category(app, 22, .cardinal, null));
    try testing.expectEqual(t.PluralCategory.many, try category(app, 11, .cardinal, null));
    try testing.expectEqual(t.PluralCategory.other, try category(app, 1.5, .cardinal, null));
    try setLanguage(app, "ar");
    try testing.expectEqual(t.PluralCategory.zero, try category(app, 0, .cardinal, null));
    try testing.expectEqual(t.PluralCategory.many, try category(app, 11, .cardinal, null));
    try setLanguage(app, "fr");
    try testing.expectEqual(t.PluralCategory.many, try category(app, 2e6, .cardinal, &.{ .style = .compact }));
    try testing.expectEqual(t.PluralCategory.one, try category(app, 0, .cardinal, null));
    var cat: t.PluralCategory = .other;
    try testing.expectEqual(t.Result.error_unsupported, c.siv_app_get_plural_category(app, 1, @enumFromInt(2), null, &cat));
}

/// A directory of catalogs in /tmp: <dir>/<lang>/LC_MESSAGES/<domain>.mo.
const Catalogs = struct {
    buf: [64]u8 = undefined,
    path: []const u8 = "",

    var counter: std.atomic.Value(u32) = .init(0);

    fn init(d: *Catalogs) void {
        d.path = std.fmt.bufPrint(&d.buf, "/tmp/siv-abi-intl-{d}-{d}", .{ linux.getpid(), counter.fetchAdd(1, .monotonic) }) catch unreachable;
    }

    fn mkdir(path: []const u8) void {
        var buf: [256]u8 = undefined;
        _ = linux.mkdir(std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch unreachable, 0o700);
    }

    fn add(d: *const Catalogs, lang: []const u8, domain: []const u8, messages: []const gettext.Message) !void {
        var buf: [256]u8 = undefined;
        mkdir(d.path);
        mkdir(try std.fmt.bufPrint(&buf, "{s}/{s}", .{ d.path, lang }));
        mkdir(try std.fmt.bufPrint(&buf, "{s}/{s}/LC_MESSAGES", .{ d.path, lang }));
        const bytes = try gettext.build(testing.allocator, messages, .little, true);
        defer testing.allocator.free(bytes);
        const path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}/LC_MESSAGES/{s}.mo", .{ d.path, lang, domain }, 0);
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(rc) != .SUCCESS) return error.Unwritable;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        if (linux.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.Unwritable;
    }

    fn remove(d: *const Catalogs, langs: []const []const u8, domains: []const []const u8) void {
        var buf: [256]u8 = undefined;
        for (langs) |l| {
            for (domains) |dom| _ = linux.unlink(std.fmt.bufPrintSentinel(&buf, "{s}/{s}/LC_MESSAGES/{s}.mo", .{ d.path, l, dom }, 0) catch unreachable);
            _ = linux.rmdir(std.fmt.bufPrintSentinel(&buf, "{s}/{s}/LC_MESSAGES", .{ d.path, l }, 0) catch unreachable);
            _ = linux.rmdir(std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ d.path, l }, 0) catch unreachable);
        }
        _ = linux.rmdir(std.fmt.bufPrintSentinel(&buf, "{s}", .{d.path}, 0) catch unreachable);
    }
};

fn tr(app: t.App, domain: []const u8, context: []const u8, text: []const u8, plural: []const u8, count: u64) ![]const u8 {
    var len: usize = 0;
    try ok(c.siv_app_translate(app, &.{
        .domain = domain.ptr,
        .domain_len = domain.len,
        .context = context.ptr,
        .context_len = context.len,
        .text = text.ptr,
        .text_len = text.len,
        .plural = plural.ptr,
        .plural_len = plural.len,
        .count = count,
    }, &out_buf, out_buf.len, &len));
    return out_buf[0..len];
}

test "translations follow the application's language" {
    var dir: Catalogs = .{};
    dir.init();
    defer dir.remove(&.{ "ru", "pt_BR", "sr@latin" }, &.{ "notes", "extra" });
    try dir.add("ru", "notes", &.{
        .{ .id = "", .strs = &.{"Content-Type: text/plain; charset=UTF-8\nPlural-Forms: nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);\n"} },
        .{ .id = "Open", .strs = &.{"Открыть"} },
        .{ .context = "verb", .id = "Close", .strs = &.{"Закрыть"} },
        .{ .id = "%d note", .plural = "%d notes", .strs = &.{ "%d заметка", "%d заметки", "%d заметок" } },
    });
    // No Plural-Forms: Brazilian Portuguese's CLDR rules, where 0 is one.
    try dir.add("pt_BR", "notes", &.{
        .{ .id = "Open", .strs = &.{"Abrir"} },
        .{ .id = "%d note", .plural = "%d notes", .strs = &.{ "%d nota", "%d notas" } },
    });
    try dir.add("sr@latin", "notes", &.{.{ .id = "Open", .strs = &.{"Otvori"} }});
    try dir.add("ru", "extra", &.{.{ .id = "Open", .strs = &.{"Открыть файл"} }});

    const app = try newApp();
    defer c.siv_app_destroy(app);
    // Nothing bound: the message itself.
    try testing.expectEqualStrings("Open", try tr(app, "", "", "Open", "", 0));
    try testing.expectEqualStrings("%d notes", try tr(app, "", "", "%d note", "%d notes", 5));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_bind_text_domain(app, "", 0, dir.path.ptr, dir.path.len));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_bind_text_domain(app, "a/b", 3, dir.path.ptr, dir.path.len));
    try ok(c.siv_app_bind_text_domain(app, "notes", 5, dir.path.ptr, dir.path.len));
    try ok(c.siv_app_bind_text_domain(app, "extra", 5, dir.path.ptr, dir.path.len));
    // No language yet: untranslated.
    try testing.expectEqualStrings("Open", try tr(app, "", "", "Open", "", 0));

    try setLanguage(app, "ru-RU");
    // The first domain bound is the default.
    try testing.expectEqualStrings("Открыть", try tr(app, "", "", "Open", "", 0));
    try testing.expectEqualStrings("Открыть файл", try tr(app, "extra", "", "Open", "", 0));
    try testing.expectEqualStrings("Закрыть", try tr(app, "notes", "verb", "Close", "", 0));
    try testing.expectEqualStrings("Close", try tr(app, "notes", "", "Close", "", 0));
    for ([_]struct { u64, []const u8 }{ .{ 1, "%d заметка" }, .{ 3, "%d заметки" }, .{ 11, "%d заметок" }, .{ 21, "%d заметка" } }) |case| {
        try testing.expectEqualStrings(case[1], try tr(app, "notes", "", "%d note", "%d notes", case[0]));
    }
    // Untranslated messages fall back by gettext's English rule.
    try testing.expectEqualStrings("Missing", try tr(app, "notes", "", "Missing", "Missings", 1));
    try testing.expectEqualStrings("Missings", try tr(app, "notes", "", "Missing", "Missings", 0));

    try setLanguage(app, "pt-BR");
    try testing.expectEqualStrings("Abrir", try tr(app, "", "", "Open", "", 0));
    try testing.expectEqualStrings("%d nota", try tr(app, "", "", "%d note", "%d notes", 0));
    try testing.expectEqualStrings("%d notas", try tr(app, "", "", "%d note", "%d notes", 2));
    try testing.expectEqualStrings("Open", try tr(app, "extra", "", "Open", "", 0));
    try setLanguage(app, "sr-Latn-RS");
    try testing.expectEqualStrings("Otvori", try tr(app, "", "", "Open", "", 0));
    try setLanguage(app, "de");
    try testing.expectEqualStrings("Open", try tr(app, "", "", "Open", "", 0));

    // Forgetting the default domain makes the next one the default.
    try setLanguage(app, "ru");
    try ok(c.siv_app_bind_text_domain(app, "notes", 5, "", 0));
    try testing.expectEqualStrings("Открыть файл", try tr(app, "", "", "Open", "", 0));
    try testing.expectEqualStrings("Open", try tr(app, "notes", "", "Open", "", 0));
}
