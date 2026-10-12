//! Desktop settings from the portal (D19): color scheme, accent color,
//! contrast, reduced motion, text scale, fonts, cursor theme and size,
//! double-click time, and caret blinking, read from
//! org.freedesktop.portal.Settings and followed live through
//! SettingChanged. Without a portal the built-in defaults stay in effect.
//!
//! The standardized org.freedesktop.appearance keys come first. The rest
//! has no standard key, so the GNOME keys (org.gnome.desktop.interface,
//! org.gnome.desktop.a11y.interface, and
//! org.gnome.desktop.peripherals.mouse, which xdg-desktop-portal-gnome and
//! -gtk expose) come next, then KDE's (org.kde.kdeglobals.General and
//! .KDE, from xdg-desktop-portal-kde, as strings). A setting no source
//! provides takes its default.
//!
//! When the portal starts or restarts, the settings are read again. When
//! it goes away, the last values stay.

const std = @import("std");
const Connection = @import("Connection.zig");
const codec = @import("codec.zig");
const Message = @import("message.zig").Message;

const Settings = @This();

conn: *Connection,
values: Values = .{},
raw: Raw = .{},
/// The first read has finished (with values or without a portal).
ready: bool = false,
on_change: ?*const fn (ctx: ?*anyopaque, s: *Settings, changed: Changed) void,
ctx: ?*anyopaque,
sub: Connection.Subscription,
watch: Connection.NameWatch,
read_serial: u32 = 0,
read_owner: Connection.Name = .{},

pub const portal_name = "org.freedesktop.portal.Desktop";
pub const portal_path = "/org/freedesktop/portal/desktop";
pub const portal_interface = "org.freedesktop.portal.Settings";

const ns_appearance = "org.freedesktop.appearance";
const ns_gnome = "org.gnome.desktop.interface";
const ns_gnome_a11y = "org.gnome.desktop.a11y.interface";
const ns_gnome_mouse = "org.gnome.desktop.peripherals.mouse";
const ns_kde = "org.kde.kdeglobals.General";
const ns_kde_kde = "org.kde.kdeglobals.KDE";
const namespaces = [_][]const u8{ ns_appearance, ns_gnome, ns_gnome_a11y, ns_gnome_mouse, ns_kde, ns_kde_kde };

pub const ColorScheme = enum { no_preference, dark, light };
pub const Contrast = enum { normal, high };

/// A short string stored inline.
pub fn Text(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: u8 = 0,

        const Self = @This();

        pub fn init(s: []const u8) Self {
            var t: Self = .{};
            t.set(s);
            return t;
        }

        /// Truncates at a UTF-8 boundary if `s` is too long.
        pub fn set(t: *Self, s: []const u8) void {
            var n = @min(s.len, cap);
            while (n > 0 and n < s.len and s[n] & 0xc0 == 0x80) n -= 1;
            if (n == 0) n = @min(s.len, cap); // not UTF-8 anyway
            @memcpy(t.buf[0..n], s[0..n]);
            t.len = @intCast(n);
        }

        pub fn slice(t: *const Self) []const u8 {
            return t.buf[0..t.len];
        }

        pub fn eql(a: *const Self, b: *const Self) bool {
            return std.mem.eql(u8, a.slice(), b.slice());
        }
    };
}

pub const Font = struct {
    /// A Fontconfig family name or generic family.
    family: Text(128),
    /// In points.
    size: f64,
    /// CSS weight, 100 to 900.
    weight: u16 = 400,
    italic: bool = false,

    pub fn eql(a: Font, b: Font) bool {
        return a.family.eql(&b.family) and a.size == b.size and a.weight == b.weight and a.italic == b.italic;
    }
};

pub const Values = struct {
    color_scheme: ColorScheme = .no_preference,
    /// sRGB components in [0, 1], or null for no accent.
    accent_color: ?[3]f64 = null,
    contrast: Contrast = .normal,
    reduced_motion: bool = false,
    /// Multiplies text sizes.
    text_scale: f64 = 1.0,
    font: Font = .{ .family = .init("sans-serif"), .size = 11 },
    document_font: Font = .{ .family = .init("sans-serif"), .size = 11 },
    monospace_font: Font = .{ .family = .init("monospace"), .size = 11 },
    cursor_theme: Text(64) = .init("default"),
    /// In logical pixels.
    cursor_size: u32 = 24,
    /// Most time between the clicks of a double click, in milliseconds.
    double_click_ms: u32 = 400,
    /// Whether the text caret blinks.
    cursor_blink: bool = true,
    /// One whole blink cycle, shown and hidden, in milliseconds.
    cursor_blink_ms: u32 = 1200,
    /// The caret stops blinking after this many seconds without input.
    cursor_blink_timeout_s: u32 = 10,
};

/// Which values changed.
pub const Changed = packed struct(u16) {
    color_scheme: bool = false,
    accent_color: bool = false,
    contrast: bool = false,
    reduced_motion: bool = false,
    text_scale: bool = false,
    font: bool = false,
    document_font: bool = false,
    monospace_font: bool = false,
    cursor_theme: bool = false,
    cursor_size: bool = false,
    double_click: bool = false,
    /// Any of the three caret blink values.
    cursor_blink: bool = false,
    _: u4 = 0,

    pub fn any(c: Changed) bool {
        return @as(u16, @bitCast(c)) != 0;
    }
};

/// What each source said, before precedence and defaults.
pub const Raw = struct {
    color_scheme: ?u32 = null,
    accent_color: ?[3]f64 = null,
    accent_set: bool = false,
    contrast: ?u32 = null,
    reduced_motion: ?u32 = null,
    gnome_enable_animations: ?bool = null,
    gnome_high_contrast: ?bool = null,
    gnome_text_scale: ?f64 = null,
    gnome_font: ?Font = null,
    gnome_document_font: ?Font = null,
    gnome_monospace_font: ?Font = null,
    gnome_cursor_theme: ?Text(64) = null,
    gnome_cursor_size: ?i64 = null,
    gnome_double_click: ?i64 = null,
    gnome_cursor_blink: ?bool = null,
    gnome_cursor_blink_time: ?i64 = null,
    gnome_cursor_blink_timeout: ?i64 = null,
    kde_font: ?Font = null,
    kde_fixed: ?Font = null,
    kde_double_click: ?i64 = null,
    /// Milliseconds per cycle; 0 means no blinking.
    kde_cursor_blink_rate: ?i64 = null,

    /// Applies one setting; unknown keys and values of the wrong type
    /// are ignored. `d` is positioned on the value inside its variant.
    pub fn apply(r: *Raw, namespace: []const u8, key: []const u8, value_sig: []const u8, d: *codec.Decoder) void {
        const eq = std.mem.eql;
        if (eq(u8, namespace, ns_appearance)) {
            if (eq(u8, key, "color-scheme")) {
                r.color_scheme = readUint(value_sig, d);
            } else if (eq(u8, key, "accent-color")) {
                r.accent_set = true;
                r.accent_color = readAccent(value_sig, d);
            } else if (eq(u8, key, "contrast")) {
                r.contrast = readUint(value_sig, d);
            } else if (eq(u8, key, "reduced-motion")) {
                r.reduced_motion = readUint(value_sig, d);
            }
        } else if (eq(u8, namespace, ns_gnome)) {
            if (eq(u8, key, "enable-animations")) {
                r.gnome_enable_animations = readBool(value_sig, d);
            } else if (eq(u8, key, "text-scaling-factor")) {
                r.gnome_text_scale = readDouble(value_sig, d);
            } else if (eq(u8, key, "font-name")) {
                r.gnome_font = parsePangoFont(readString(value_sig, d) orelse return);
            } else if (eq(u8, key, "document-font-name")) {
                r.gnome_document_font = parsePangoFont(readString(value_sig, d) orelse return);
            } else if (eq(u8, key, "monospace-font-name")) {
                r.gnome_monospace_font = parsePangoFont(readString(value_sig, d) orelse return);
            } else if (eq(u8, key, "cursor-theme")) {
                const s = readString(value_sig, d) orelse return;
                r.gnome_cursor_theme = if (s.len > 0) .init(s) else null;
            } else if (eq(u8, key, "cursor-size")) {
                r.gnome_cursor_size = readInt(value_sig, d);
            } else if (eq(u8, key, "cursor-blink")) {
                r.gnome_cursor_blink = readBool(value_sig, d);
            } else if (eq(u8, key, "cursor-blink-time")) {
                r.gnome_cursor_blink_time = readInt(value_sig, d);
            } else if (eq(u8, key, "cursor-blink-timeout")) {
                r.gnome_cursor_blink_timeout = readInt(value_sig, d);
            }
        } else if (eq(u8, namespace, ns_gnome_a11y)) {
            if (eq(u8, key, "high-contrast")) r.gnome_high_contrast = readBool(value_sig, d);
        } else if (eq(u8, namespace, ns_gnome_mouse)) {
            if (eq(u8, key, "double-click")) r.gnome_double_click = readInt(value_sig, d);
        } else if (eq(u8, namespace, ns_kde_kde)) {
            if (eq(u8, key, "DoubleClickInterval")) {
                r.kde_double_click = readIntString(value_sig, d);
            } else if (eq(u8, key, "CursorBlinkRate")) {
                r.kde_cursor_blink_rate = readIntString(value_sig, d);
            }
        } else if (eq(u8, namespace, ns_kde)) {
            if (eq(u8, key, "font")) {
                r.kde_font = parseQtFont(readString(value_sig, d) orelse return);
            } else if (eq(u8, key, "fixed")) {
                r.kde_fixed = parseQtFont(readString(value_sig, d) orelse return);
            }
        }
    }

    /// The effective values: first source that has one, else the default.
    pub fn resolve(r: *const Raw) Values {
        const def: Values = .{};
        var v: Values = .{};
        v.color_scheme = switch (r.color_scheme orelse 0) {
            1 => .dark,
            2 => .light,
            else => .no_preference,
        };
        v.accent_color = r.accent_color;
        v.contrast = if (r.contrast) |c| (if (c == 1) .high else .normal) else if (r.gnome_high_contrast orelse false) .high else .normal;
        v.reduced_motion = if (r.reduced_motion) |m| m == 1 else if (r.gnome_enable_animations) |a| !a else false;
        v.text_scale = if (r.gnome_text_scale) |s| (if (s >= 0.25 and s <= 8) s else def.text_scale) else def.text_scale;
        v.font = r.gnome_font orelse r.kde_font orelse def.font;
        v.document_font = r.gnome_document_font orelse r.gnome_font orelse r.kde_font orelse def.document_font;
        v.monospace_font = r.gnome_monospace_font orelse r.kde_fixed orelse def.monospace_font;
        v.cursor_theme = r.gnome_cursor_theme orelse def.cursor_theme;
        v.cursor_size = if (r.gnome_cursor_size) |s| (if (s >= 8 and s <= 512) @intCast(s) else def.cursor_size) else def.cursor_size;
        v.double_click_ms = inRange(r.gnome_double_click, 100, 5000) orelse inRange(r.kde_double_click, 100, 5000) orelse def.double_click_ms;
        v.cursor_blink = r.gnome_cursor_blink orelse if (r.kde_cursor_blink_rate) |k| k != 0 else def.cursor_blink;
        v.cursor_blink_ms = inRange(r.gnome_cursor_blink_time, 100, 10_000) orelse inRange(r.kde_cursor_blink_rate, 100, 10_000) orelse def.cursor_blink_ms;
        v.cursor_blink_timeout_s = inRange(r.gnome_cursor_blink_timeout, 1, 86_400) orelse def.cursor_blink_timeout_s;
        return v;
    }
};

fn inRange(v: ?i64, min: u32, max: u32) ?u32 {
    const x = v orelse return null;
    return if (x >= min and x <= max) @intCast(x) else null;
}

/// An integer, or a string holding one (KDE's portal sends strings).
fn readIntString(sig: []const u8, d: *codec.Decoder) ?i64 {
    if (!std.mem.eql(u8, sig, "s")) return readInt(sig, d);
    const s = d.readString() catch return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch null;
}

fn readUint(sig: []const u8, d: *codec.Decoder) ?u32 {
    const v = readInt(sig, d) orelse return null;
    return std.math.cast(u32, v);
}

fn readInt(sig: []const u8, d: *codec.Decoder) ?i64 {
    if (sig.len != 1) return null;
    return switch (sig[0]) {
        'y' => d.readByte() catch null,
        'n' => d.readInt16() catch null,
        'q' => d.readUint16() catch null,
        'i' => d.readInt32() catch null,
        'u' => d.readUint32() catch null,
        'x' => d.readInt64() catch null,
        't' => std.math.cast(i64, d.readUint64() catch return null),
        else => null,
    };
}

fn readBool(sig: []const u8, d: *codec.Decoder) ?bool {
    if (!std.mem.eql(u8, sig, "b")) return null;
    return d.readBool() catch null;
}

fn readDouble(sig: []const u8, d: *codec.Decoder) ?f64 {
    if (!std.mem.eql(u8, sig, "d")) return null;
    const v = d.readDouble() catch return null;
    return if (std.math.isFinite(v)) v else null;
}

fn readString(sig: []const u8, d: *codec.Decoder) ?[]const u8 {
    if (!std.mem.eql(u8, sig, "s")) return null;
    return d.readString() catch null;
}

/// (ddd) in [0, 1]; anything else is no accent.
fn readAccent(sig: []const u8, d: *codec.Decoder) ?[3]f64 {
    if (!std.mem.eql(u8, sig, "(ddd)")) return null;
    const rgb = d.read(struct { f64, f64, f64 }) catch return null;
    const out: [3]f64 = .{ rgb[0], rgb[1], rgb[2] };
    for (out) |c| if (!(c >= 0 and c <= 1)) return null;
    return out;
}

/// Parses a Pango font description as GNOME stores it: "Family [style
/// words] size", for example "Cantarell 11" or "Noto Sans Bold Italic 10".
/// Sizes with "px" are converted at 96 dpi.
pub fn parsePangoFont(s: []const u8) ?Font {
    var rest = std.mem.trim(u8, s, " ");
    var size: f64 = 0;
    if (std.mem.lastIndexOfScalar(u8, rest, ' ')) |sp| {
        var tok = rest[sp + 1 ..];
        const px = std.mem.endsWith(u8, tok, "px");
        if (px) tok = tok[0 .. tok.len - 2];
        if (std.fmt.parseFloat(f64, tok)) |v| {
            if (std.math.isFinite(v) and v > 0 and v <= 1000) {
                size = if (px) v * 72.0 / 96.0 else v;
                rest = std.mem.trimEnd(u8, rest[0..sp], " ,");
            }
        } else |_| {}
    }
    if (size == 0) return null;
    var font: Font = .{ .family = .{}, .size = size };
    // Strip style words from the end; what remains is the family.
    while (rest.len > 0) {
        const sp = std.mem.lastIndexOfScalar(u8, rest, ' ');
        const word = if (sp) |i| rest[i + 1 ..] else rest;
        if (styleWeight(word)) |w| {
            font.weight = w;
        } else if (std.ascii.eqlIgnoreCase(word, "Italic") or std.ascii.eqlIgnoreCase(word, "Oblique")) {
            font.italic = true;
        } else if (!isIgnoredStyle(word)) break;
        rest = if (sp) |i| std.mem.trimEnd(u8, rest[0..i], " ") else "";
    }
    rest = std.mem.trimEnd(u8, rest, ",");
    if (rest.len == 0) return null;
    font.family.set(rest);
    return font;
}

fn styleWeight(word: []const u8) ?u16 {
    const table = [_]struct { []const u8, u16 }{
        .{ "Thin", 100 },        .{ "Ultra-Light", 200 }, .{ "Extra-Light", 200 }, .{ "Light", 300 },
        .{ "Semi-Light", 350 },  .{ "Book", 380 },        .{ "Regular", 400 },     .{ "Medium", 500 },
        .{ "Semi-Bold", 600 },   .{ "Demi-Bold", 600 },   .{ "Bold", 700 },        .{ "Ultra-Bold", 800 },
        .{ "Extra-Bold", 800 },  .{ "Heavy", 900 },       .{ "Black", 900 },       .{ "Ultra-Heavy", 1000 },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(word, e[0])) return @min(e[1], 900);
    return null;
}

fn isIgnoredStyle(word: []const u8) bool {
    const words = [_][]const u8{ "Normal", "Roman", "Small-Caps", "Ultra-Condensed", "Extra-Condensed", "Condensed", "Semi-Condensed", "Semi-Expanded", "Expanded", "Extra-Expanded", "Ultra-Expanded" };
    for (words) |w| if (std.ascii.eqlIgnoreCase(word, w)) return true;
    return false;
}

/// Parses a QFont string as KDE stores it: "family,pointSize,pixelSize,
/// styleHint,weight,style,...", with weights on Qt 5's 0-99 scale or Qt
/// 6's CSS scale.
pub fn parseQtFont(s: []const u8) ?Font {
    var it = std.mem.splitScalar(u8, s, ',');
    const family = std.mem.trim(u8, it.next() orelse return null, " ");
    if (family.len == 0) return null;
    const point = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const pixel = std.fmt.parseFloat(f64, it.next() orelse "-1") catch -1;
    const size = if (point > 0) point else if (pixel > 0) pixel * 72.0 / 96.0 else return null;
    if (!std.math.isFinite(size) or size > 1000) return null;
    var font: Font = .{ .family = .init(family), .size = size };
    _ = it.next(); // style hint
    if (it.next()) |w| {
        const weight = std.fmt.parseInt(u16, w, 10) catch 0;
        font.weight = if (weight >= 100) @min(weight, 900) else qt5Weight(weight);
    }
    if (it.next()) |style| font.italic = !std.mem.eql(u8, style, "0");
    return font;
}

fn qt5Weight(w: u16) u16 {
    // QFont::Weight in Qt 5 and the CSS weights it stands for.
    const table = [_][2]u16{ .{ 0, 100 }, .{ 12, 200 }, .{ 25, 300 }, .{ 50, 400 }, .{ 57, 500 }, .{ 63, 600 }, .{ 75, 700 }, .{ 81, 800 }, .{ 87, 900 } };
    var best = table[0];
    for (table) |e| if (@abs(@as(i32, e[0]) - @as(i32, w)) < @abs(@as(i32, best[0]) - @as(i32, w))) {
        best = e;
    };
    return best[1];
}

pub const Options = struct {
    /// Called at a safe point when values change, and once when the first
    /// read finishes (`ready`), even if nothing changed.
    on_change: ?*const fn (ctx: ?*anyopaque, s: *Settings, changed: Changed) void = null,
    ctx: ?*anyopaque = null,
};

/// Starts reading the settings on a session bus connection. `s` must stay
/// at the same address until `deinit`.
pub fn init(s: *Settings, conn: *Connection, options: Options) Connection.Error!void {
    s.* = .{
        .conn = conn,
        .on_change = options.on_change,
        .ctx = options.ctx,
        .sub = .{
            .rule = .{ .sender = portal_name, .path = portal_path, .interface = portal_interface, .member = "SettingChanged" },
            .func = onSettingChanged,
        },
        .watch = .{ .name = portal_name, .func = onPortalOwner },
    };
    try conn.subscribe(&s.sub);
    errdefer conn.unsubscribe(&s.sub);
    try conn.watchName(&s.watch);
    errdefer conn.unwatchName(&s.watch);
    try s.read();
}

pub fn deinit(s: *Settings) void {
    if (s.read_serial != 0) s.conn.cancelCall(s.read_serial);
    s.conn.unwatchName(&s.watch);
    s.conn.unsubscribe(&s.sub);
    s.* = undefined;
}

fn read(s: *Settings) Connection.Error!void {
    var b = s.conn.methodCall(portal_name, portal_path, portal_interface, "ReadAll");
    b.body.write(@as([]const []const u8, &namespaces)) catch |err| {
        b.deinit();
        return err;
    };
    s.read_serial = try s.conn.call(&b, onReadAll, s, .{});
}

fn onReadAll(ctx: ?*anyopaque, reply: Connection.Reply) void {
    const s: *Settings = @ptrCast(@alignCast(ctx));
    s.read_serial = 0;
    switch (reply) {
        .ok => |m| {
            var raw: Raw = .{};
            if (parseReadAll(&raw, m)) {
                s.raw = raw;
                s.read_owner.set(m.sender orelse "");
            } else |_| {}
        },
        // No portal (ServiceUnknown), or one without this interface: the
        // defaults stay.
        .err, .failed => {},
    }
    const first = !s.ready;
    s.ready = true;
    s.update(first);
}

/// Reads a{sa{sv}} into `raw`.
pub fn parseReadAll(raw: *Raw, m: *const Message) codec.DecodeError!void {
    if (!std.mem.eql(u8, m.signature, "a{sa{sv}}")) return error.SignatureMismatch;
    var d = m.body();
    const outer = try d.beginArray();
    while (outer.next(&d)) {
        try d.beginDictEntry();
        const namespace = try d.readString();
        const inner = try d.beginArray();
        while (inner.next(&d)) {
            try d.beginDictEntry();
            const key = try d.readString();
            const vs = try d.beginVariant();
            raw.apply(namespace, key, vs, &d);
            try d.endVariant();
            try d.endDictEntry();
        }
        try d.endArray(inner);
        try d.endDictEntry();
    }
    try d.endArray(outer);
}

fn onSettingChanged(sub: *Connection.Subscription, m: *const Message) void {
    const s: *Settings = @fieldParentPtr("sub", sub);
    if (!std.mem.eql(u8, m.signature, "ssv")) return;
    var d = m.body();
    const namespace = d.readString() catch return;
    const key = d.readString() catch return;
    const vs = d.beginVariant() catch return;
    s.raw.apply(namespace, key, vs, &d);
    // A change before the first read finished shows up in its result.
    if (s.ready) s.update(false);
}

fn onPortalOwner(w: *Connection.NameWatch) void {
    const s: *Settings = @fieldParentPtr("watch", w);
    const owner = w.owner() orelse {
        // Keep the last values, and read again when a portal returns.
        s.read_owner.len = 0;
        return;
    };
    if (s.read_serial != 0 or std.mem.eql(u8, owner, s.read_owner.slice())) return;
    // The portal started or restarted: read everything again.
    s.read() catch {};
}

fn update(s: *Settings, always: bool) void {
    const new = s.raw.resolve();
    const old = s.values;
    s.values = new;
    const changed: Changed = .{
        .color_scheme = old.color_scheme != new.color_scheme,
        .accent_color = !std.meta.eql(old.accent_color, new.accent_color),
        .contrast = old.contrast != new.contrast,
        .reduced_motion = old.reduced_motion != new.reduced_motion,
        .text_scale = old.text_scale != new.text_scale,
        .font = !old.font.eql(new.font),
        .document_font = !old.document_font.eql(new.document_font),
        .monospace_font = !old.monospace_font.eql(new.monospace_font),
        .cursor_theme = !old.cursor_theme.eql(&new.cursor_theme),
        .cursor_size = old.cursor_size != new.cursor_size,
        .double_click = old.double_click_ms != new.double_click_ms,
        .cursor_blink = old.cursor_blink != new.cursor_blink or old.cursor_blink_ms != new.cursor_blink_ms or
            old.cursor_blink_timeout_s != new.cursor_blink_timeout_s,
    };
    if (!changed.any() and !always) return;
    if (s.on_change) |f| f(s.ctx, s, changed);
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

test "Pango font descriptions" {
    const cases = [_]struct { []const u8, ?[]const u8, f64, u16, bool }{
        .{ "Cantarell 11", "Cantarell", 11, 400, false },
        .{ "Noto Sans Bold Italic 10.5", "Noto Sans", 10.5, 700, true },
        .{ "Source Code Pro Semi-Bold 12", "Source Code Pro", 12, 600, false },
        .{ "DejaVu Sans, Bold 9", "DejaVu Sans", 9, 700, false },
        .{ "Inter 16px", "Inter", 12, 400, false },
        .{ "Monospace", null, 0, 0, false },
        .{ "Bold 10", null, 0, 0, false },
        .{ "", null, 0, 0, false },
        .{ "Sans nan", null, 0, 0, false },
    };
    for (cases) |c| {
        const f = parsePangoFont(c[0]);
        if (c[1]) |family| {
            try testing.expectEqualStrings(family, f.?.family.slice());
            try testing.expectEqual(c[2], f.?.size);
            try testing.expectEqual(c[3], f.?.weight);
            try testing.expectEqual(c[4], f.?.italic);
        } else try testing.expect(f == null);
    }
}

test "QFont strings" {
    const qt5 = parseQtFont("Noto Sans,10,-1,5,75,1,0,0,0,0").?;
    try testing.expectEqualStrings("Noto Sans", qt5.family.slice());
    try testing.expectEqual(@as(f64, 10), qt5.size);
    try testing.expectEqual(@as(u16, 700), qt5.weight);
    try testing.expect(qt5.italic);
    const qt6 = parseQtFont("Hack,9,-1,5,400,0,0,0,0,0,0,0,0,0,0,1").?;
    try testing.expectEqual(@as(u16, 400), qt6.weight);
    try testing.expect(!qt6.italic);
    const pixels = parseQtFont("Inter,-1,16,5,50,0").?;
    try testing.expectEqual(@as(f64, 12), pixels.size);
    try testing.expect(parseQtFont("") == null);
    try testing.expect(parseQtFont("Sans") == null);
    try testing.expect(parseQtFont("Sans,x") == null);
}

test "precedence and defaults" {
    var raw: Raw = .{};
    try testing.expectEqual(@as(u32, 24), raw.resolve().cursor_size);
    try testing.expectEqualStrings("sans-serif", raw.resolve().font.family.slice());
    raw.gnome_enable_animations = false;
    raw.gnome_high_contrast = true;
    raw.kde_font = parseQtFont("Noto Sans,10,-1,5,50,0");
    var v = raw.resolve();
    try testing.expect(v.reduced_motion);
    try testing.expectEqual(Contrast.high, v.contrast);
    try testing.expectEqualStrings("Noto Sans", v.document_font.family.slice());
    // The standardized keys win over the GNOME ones.
    raw.reduced_motion = 0;
    raw.contrast = 0;
    raw.gnome_font = parsePangoFont("Cantarell 11");
    raw.gnome_cursor_size = 4096; // out of range
    raw.gnome_text_scale = 1.25;
    v = raw.resolve();
    try testing.expect(!v.reduced_motion);
    try testing.expectEqual(Contrast.normal, v.contrast);
    try testing.expectEqualStrings("Cantarell", v.font.family.slice());
    try testing.expectEqual(@as(u32, 24), v.cursor_size);
    try testing.expectEqual(@as(f64, 1.25), v.text_scale);
}

test "double-click and caret blink: GNOME, then KDE, then defaults" {
    var raw: Raw = .{};
    var v = raw.resolve();
    try testing.expectEqual(@as(u32, 400), v.double_click_ms);
    try testing.expect(v.cursor_blink);
    try testing.expectEqual(@as(u32, 1200), v.cursor_blink_ms);
    try testing.expectEqual(@as(u32, 10), v.cursor_blink_timeout_s);
    // KDE: a blink rate of 0 turns blinking off and keeps the default
    // period.
    raw.kde_double_click = 250;
    raw.kde_cursor_blink_rate = 0;
    v = raw.resolve();
    try testing.expectEqual(@as(u32, 250), v.double_click_ms);
    try testing.expect(!v.cursor_blink);
    try testing.expectEqual(@as(u32, 1200), v.cursor_blink_ms);
    raw.kde_cursor_blink_rate = 800;
    try testing.expectEqual(@as(u32, 800), raw.resolve().cursor_blink_ms);
    // GNOME wins; out-of-range values fall through.
    raw.gnome_double_click = 600;
    raw.gnome_cursor_blink = true;
    raw.gnome_cursor_blink_time = 50;
    raw.gnome_cursor_blink_timeout = 0;
    v = raw.resolve();
    try testing.expectEqual(@as(u32, 600), v.double_click_ms);
    try testing.expect(v.cursor_blink);
    try testing.expectEqual(@as(u32, 800), v.cursor_blink_ms);
    try testing.expectEqual(@as(u32, 10), v.cursor_blink_timeout_s);
}

test "Text truncates at a UTF-8 boundary" {
    var t: Text(4) = .{};
    t.set("abcé");
    try testing.expectEqualStrings("abc", t.slice());
}

test "fuzz font strings" {
    try std.testing.fuzz({}, fuzzFonts, .{ .corpus = &.{ "Noto Sans Bold Italic 10.5", "Noto Sans,10,-1,5,75,1,0,0,0,0" } });
}

fn fuzzFonts(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const s = buf[0..smith.slice(&buf)];
    for ([_]?Font{ parsePangoFont(s), parseQtFont(s) }) |f| {
        const font = f orelse continue;
        try testing.expect(font.size > 0 and font.size <= 1000);
        try testing.expect(font.weight >= 100 and font.weight <= 900);
        try testing.expect(font.family.len > 0);
    }
}
