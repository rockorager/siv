//! Match rules: the filter a connection asks the bus for with AddMatch, and
//! the same filter applied locally to route signals to subscriptions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const message = @import("message.zig");
const names = @import("names.zig");
const Message = message.Message;
const Type = message.Type;

pub const max_args = 64;

pub const Arg = struct {
    index: u8,
    kind: Kind = .string,
    value: []const u8,

    pub const Kind = enum {
        /// argN: the string argument equals the value.
        string,
        /// argNpath: the string or object path argument equals the value,
        /// or one is a prefix of the other ending in "/".
        path,
        /// arg0namespace: the string argument is the value or a bus or
        /// interface name below it.
        namespace,
    };
};

/// Every field that is set must match. Strings are borrowed.
pub const Rule = struct {
    type: ?Type = null,
    sender: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    path: ?[]const u8 = null,
    path_namespace: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    args: []const Arg = &.{},

    pub const Error = error{InvalidRule};

    /// Appends the rule in the bus's text form.
    pub fn format(r: *const Rule, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        var first = true;
        const W = struct {
            fn kv(gpa_: Allocator, o: *std.ArrayList(u8), f: *bool, key: []const u8, value: []const u8) !void {
                if (!f.*) try o.append(gpa_, ',');
                f.* = false;
                try o.appendSlice(gpa_, key);
                try o.appendSlice(gpa_, "='");
                for (value) |c| {
                    if (c == '\'') try o.appendSlice(gpa_, "'\\''") else try o.append(gpa_, c);
                }
                try o.append(gpa_, '\'');
            }
        };
        if (r.type) |t| try W.kv(gpa, out, &first, "type", switch (t) {
            .method_call => "method_call",
            .method_return => "method_return",
            .@"error" => "error",
            .signal => "signal",
            _ => unreachable,
        });
        if (r.sender) |v| try W.kv(gpa, out, &first, "sender", v);
        if (r.interface) |v| try W.kv(gpa, out, &first, "interface", v);
        if (r.member) |v| try W.kv(gpa, out, &first, "member", v);
        if (r.path) |v| try W.kv(gpa, out, &first, "path", v);
        if (r.path_namespace) |v| try W.kv(gpa, out, &first, "path_namespace", v);
        if (r.destination) |v| try W.kv(gpa, out, &first, "destination", v);
        for (r.args) |a| {
            var key_buf: [20]u8 = undefined;
            const suffix = switch (a.kind) {
                .string => "",
                .path => "path",
                .namespace => "namespace",
            };
            const key = std.fmt.bufPrint(&key_buf, "arg{d}{s}", .{ a.index, suffix }) catch unreachable;
            try W.kv(gpa, out, &first, key, a.value);
        }
    }

    /// Checks names and argument indexes, so that the bus accepts the rule.
    pub fn validate(r: *const Rule) Error!void {
        if (r.sender) |v| if (!names.isBusName(v)) return error.InvalidRule;
        if (r.interface) |v| if (!names.isInterfaceName(v)) return error.InvalidRule;
        if (r.member) |v| if (!names.isMemberName(v)) return error.InvalidRule;
        if (r.path) |v| if (!names.isObjectPath(v)) return error.InvalidRule;
        if (r.path_namespace) |v| if (!names.isObjectPath(v)) return error.InvalidRule;
        if (r.path != null and r.path_namespace != null) return error.InvalidRule;
        if (r.destination) |v| if (!names.isUniqueName(v)) return error.InvalidRule;
        if (r.type) |t| if (@intFromEnum(t) < 1 or @intFromEnum(t) > 4) return error.InvalidRule;
        for (r.args) |a| {
            if (a.index >= max_args) return error.InvalidRule;
            if (a.kind == .namespace and (a.index != 0 or !names.isBusName(a.value) and !names.isMemberName(a.value))) return error.InvalidRule;
        }
    }

    /// Parses the text form. Unescaped values are written to `strings`,
    /// which must be as long as `text`; args go to `args`.
    pub fn parse(text: []const u8, strings: []u8, args: *[max_args]Arg) Error!Rule {
        var r: Rule = .{};
        var n_args: usize = 0;
        var used: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and text[i] == ' ') i += 1;
            if (i == text.len) break;
            const eq = std.mem.indexOfScalarPos(u8, text, i, '=') orelse return error.InvalidRule;
            const key = text[i..eq];
            i = eq + 1;
            // The value: quoted runs, with \' outside quotes for a quote.
            const start = used;
            var quoted = false;
            while (i < text.len) {
                const c = text[i];
                if (quoted) {
                    if (c == '\'') quoted = false else {
                        strings[used] = c;
                        used += 1;
                    }
                    i += 1;
                } else if (c == '\'') {
                    quoted = true;
                    i += 1;
                } else if (c == ',') {
                    break;
                } else if (c == '\\' and i + 1 < text.len and text[i + 1] == '\'') {
                    strings[used] = '\'';
                    used += 1;
                    i += 2;
                } else {
                    strings[used] = c;
                    used += 1;
                    i += 1;
                }
            }
            if (quoted) return error.InvalidRule;
            if (i < text.len) i += 1; // ','
            const value = strings[start..used];
            if (std.mem.eql(u8, key, "type")) {
                if (r.type != null) return error.InvalidRule;
                r.type = if (std.mem.eql(u8, value, "signal")) .signal else if (std.mem.eql(u8, value, "method_call")) .method_call else if (std.mem.eql(u8, value, "method_return")) .method_return else if (std.mem.eql(u8, value, "error")) .@"error" else return error.InvalidRule;
            } else if (try setOnce(&r.sender, key, "sender", value)) {} else if (try setOnce(&r.interface, key, "interface", value)) {} else if (try setOnce(&r.member, key, "member", value)) {} else if (try setOnce(&r.path, key, "path", value)) {} else if (try setOnce(&r.path_namespace, key, "path_namespace", value)) {} else if (try setOnce(&r.destination, key, "destination", value)) {} else if (std.mem.startsWith(u8, key, "arg")) {
                var digits: usize = 3;
                while (digits < key.len and digits < 5 and std.ascii.isDigit(key[digits])) digits += 1;
                if (digits == 3) return error.InvalidRule;
                const index = std.fmt.parseInt(u8, key[3..digits], 10) catch return error.InvalidRule;
                const suffix = key[digits..];
                const kind: Arg.Kind = if (suffix.len == 0) .string else if (std.mem.eql(u8, suffix, "path")) .path else if (std.mem.eql(u8, suffix, "namespace")) .namespace else return error.InvalidRule;
                for (args[0..n_args]) |a| if (a.index == index and a.kind == kind) return error.InvalidRule;
                if (n_args == max_args) return error.InvalidRule;
                args[n_args] = .{ .index = index, .kind = kind, .value = value };
                n_args += 1;
            } else return error.InvalidRule; // includes eavesdrop
        }
        r.args = args[0..n_args];
        try r.validate();
        return r;
    }

    fn setOnce(field: *?[]const u8, key: []const u8, name: []const u8, value: []const u8) Error!bool {
        if (!std.mem.eql(u8, key, name)) return false;
        if (field.* != null) return error.InvalidRule;
        field.* = value;
        return true;
    }

    /// Whether `m` matches. `sender` is compared literally, so a rule with
    /// a well-known sender needs the name's owner resolved by the caller
    /// (`matchesExceptSender`).
    pub fn matches(r: *const Rule, m: *const Message) bool {
        if (r.sender) |s| if (!eqlOpt(m.sender, s)) return false;
        return r.matchesExceptSender(m);
    }

    pub fn matchesExceptSender(r: *const Rule, m: *const Message) bool {
        if (r.type) |t| if (m.type != t) return false;
        if (r.interface) |v| if (!eqlOpt(m.interface, v)) return false;
        if (r.member) |v| if (!eqlOpt(m.member, v)) return false;
        if (r.path) |v| if (!eqlOpt(m.path, v)) return false;
        if (r.path_namespace) |v| {
            const p = m.path orelse return false;
            if (!names.pathInNamespace(p, v)) return false;
        }
        if (r.destination) |v| if (!eqlOpt(m.destination, v)) return false;
        if (r.args.len == 0) return true;
        // Walk the top-level arguments once, checking every arg match.
        var d = m.body();
        var index: u8 = 0;
        var matched: usize = 0;
        while (d.peek()) |code| : (index += 1) {
            var str: ?[]const u8 = null;
            var is_path = false;
            if (code == 's') {
                str = d.readString() catch return false;
            } else if (code == 'o') {
                str = d.readObjectPath() catch return false;
                is_path = true;
            } else d.skip() catch return false;
            for (r.args) |a| {
                if (a.index != index) continue;
                const s = str orelse return false;
                const ok = switch (a.kind) {
                    .string => !is_path and std.mem.eql(u8, s, a.value),
                    .path => argPathMatch(s, a.value),
                    .namespace => !is_path and names.nameInNamespace(s, a.value),
                };
                if (!ok) return false;
                matched += 1;
            }
            if (matched == r.args.len) return true;
        }
        return false; // an argument the rule names is missing
    }
};

fn argPathMatch(arg: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, arg, value)) return true;
    if (arg.len > 0 and arg[arg.len - 1] == '/' and std.mem.startsWith(u8, value, arg)) return true;
    if (value.len > 0 and value[value.len - 1] == '/' and std.mem.startsWith(u8, arg, value)) return true;
    return false;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

const testing = std.testing;

test "format quotes values and round-trips through parse" {
    const rule: Rule = .{
        .type = .signal,
        .sender = "org.freedesktop.DBus",
        .member = "NameOwnerChanged",
        .path_namespace = "/org",
        .args = &.{ .{ .index = 0, .value = "it's" }, .{ .index = 2, .kind = .path, .value = "/a/" } },
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try rule.format(testing.allocator, &out);
    try testing.expectEqualStrings("type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',path_namespace='/org',arg0='it'\\''s',arg2path='/a/'", out.items);

    var strings: [256]u8 = undefined;
    var args: [max_args]Arg = undefined;
    const back = try Rule.parse(out.items, &strings, &args);
    try testing.expectEqual(Type.signal, back.type.?);
    try testing.expectEqualStrings("org.freedesktop.DBus", back.sender.?);
    try testing.expectEqualStrings("it's", back.args[0].value);
    try testing.expectEqual(Arg.Kind.path, back.args[1].kind);
    try testing.expectEqual(@as(u8, 2), back.args[1].index);
}

test "parse rejects malformed rules" {
    var strings: [256]u8 = undefined;
    var args: [max_args]Arg = undefined;
    for ([_][]const u8{ "type='bogus'", "member", "member='a',member='b'", "arg64='x'", "argx='y'", "member='unterminated", "eavesdrop='true'", "path='/a',path_namespace='/b'", "arg1namespace='a.b'" }) |s| {
        try testing.expectError(error.InvalidRule, Rule.parse(s, &strings, &args));
    }
    const r = try Rule.parse("", &strings, &args);
    try testing.expect(r.type == null);
}

test "matching headers and arguments" {
    var b: message.Builder = .init(testing.allocator, .{ .type = .signal, .path = "/org/a/b", .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .sender = "org.freedesktop.DBus" });
    defer b.deinit();
    try b.body.writeAll(.{ "org.gnome.Shell", "", ":1.5" });
    const data = try b.encode(testing.allocator, 1);
    defer testing.allocator.free(data);
    const m = try Message.parse(data);

    const yes = [_]Rule{
        .{ .type = .signal, .member = "NameOwnerChanged" },
        .{ .path_namespace = "/org/a" },
        .{ .path_namespace = "/" },
        .{ .args = &.{.{ .index = 0, .value = "org.gnome.Shell" }} },
        .{ .args = &.{.{ .index = 0, .kind = .namespace, .value = "org.gnome" }} },
        .{ .args = &.{ .{ .index = 1, .value = "" }, .{ .index = 2, .value = ":1.5" } } },
        .{ .sender = "org.freedesktop.DBus" },
    };
    for (yes) |r| try testing.expect(r.matches(&m));
    const no = [_]Rule{
        .{ .type = .method_call },
        .{ .path = "/org/a" },
        .{ .path_namespace = "/org/ab" },
        .{ .args = &.{.{ .index = 0, .kind = .namespace, .value = "org.gno" }} },
        .{ .args = &.{.{ .index = 3, .value = "x" }} },
        .{ .sender = ":1.1" },
    };
    for (no) |r| try testing.expect(!r.matches(&m));
    try testing.expect(argPathMatch("/aa/bb/", "/aa/bb/cc"));
    try testing.expect(argPathMatch("/aa/bb/cc", "/aa/"));
    try testing.expect(!argPathMatch("/aa/b", "/aa/bb"));
}

test "fuzz rule parsing" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &.{"type='signal',sender='org.freedesktop.DBus',arg0namespace='org.x',arg3path='/a/'"} });
}

/// A rule that parses formats to text that parses to the same rule.
fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    var strings: [512]u8 = undefined;
    var args: [max_args]Arg = undefined;
    const r = Rule.parse(text, &strings, &args) catch return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try r.format(testing.allocator, &out);
    const strings2 = try testing.allocator.alloc(u8, out.items.len);
    defer testing.allocator.free(strings2);
    var args2: [max_args]Arg = undefined;
    const r2 = try Rule.parse(out.items, strings2, &args2);
    try testing.expectEqual(r.args.len, r2.args.len);
    try testing.expectEqual(r.type, r2.type);
    if (r.sender) |s| try testing.expectEqualStrings(s, r2.sender.?);
    for (r.args, r2.args) |a, b2| try testing.expectEqualStrings(a.value, b2.value);
}
