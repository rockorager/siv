//! Type signatures: validation and the properties of type codes. A valid
//! signature is at most 255 bytes of complete types with at most 32 nested
//! arrays and 32 nested structs (dict entries count as structs). Structs
//! have at least one field; dict entries appear only as array elements,
//! with a basic key and exactly one value.

const std = @import("std");

pub const max_len = 255;
pub const max_array_depth = 32;
pub const max_struct_depth = 32;
/// Container nesting of a value, counting arrays, structs, dict entries,
/// and variants. Bounds the recursion of every walker.
pub const max_depth = 64;

pub const Error = error{InvalidSignature};

pub fn isBasic(c: u8) bool {
    return switch (c) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g' => true,
        else => false,
    };
}

/// Alignment of a value whose type starts with `c`.
pub fn alignment(c: u8) u8 {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

/// Wire size of a fixed-size basic type, or null.
pub fn fixedSize(c: u8) ?u8 {
    return switch (c) {
        'y' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h' => 4,
        'x', 't', 'd' => 8,
        else => null,
    };
}

/// Length of the complete type at the start of `sig`, validating it.
pub fn completeLen(sig: []const u8) Error!usize {
    var pos: usize = 0;
    try parseOne(sig, &pos, 0, 0);
    return pos;
}

/// Length of the complete type at the start of a signature already known
/// to be valid.
pub fn skipLen(sig: []const u8) usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (true) {
        const c = sig[i];
        i += 1;
        switch (c) {
            'a' => continue,
            '(', '{' => depth += 1,
            ')', '}' => depth -= 1,
            else => {},
        }
        if (depth == 0) return i;
    }
}

fn parseOne(sig: []const u8, pos: *usize, arrays: u8, structs: u8) Error!void {
    if (pos.* >= sig.len) return error.InvalidSignature;
    const c = sig[pos.*];
    pos.* += 1;
    switch (c) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => {},
        'a' => {
            if (arrays == max_array_depth) return error.InvalidSignature;
            if (pos.* < sig.len and sig[pos.*] == '{') {
                pos.* += 1;
                if (structs == max_struct_depth) return error.InvalidSignature;
                if (pos.* >= sig.len or !isBasic(sig[pos.*])) return error.InvalidSignature;
                pos.* += 1;
                try parseOne(sig, pos, arrays + 1, structs + 1);
                if (pos.* >= sig.len or sig[pos.*] != '}') return error.InvalidSignature;
                pos.* += 1;
            } else {
                try parseOne(sig, pos, arrays + 1, structs);
            }
        },
        '(' => {
            if (structs == max_struct_depth) return error.InvalidSignature;
            if (pos.* < sig.len and sig[pos.*] == ')') return error.InvalidSignature;
            while (true) {
                if (pos.* >= sig.len) return error.InvalidSignature;
                if (sig[pos.*] == ')') break;
                try parseOne(sig, pos, arrays, structs + 1);
            }
            pos.* += 1;
        },
        else => return error.InvalidSignature,
    }
}

/// Zero or more complete types.
pub fn validate(sig: []const u8) Error!void {
    if (sig.len > max_len) return error.InvalidSignature;
    var pos: usize = 0;
    while (pos < sig.len) try parseOne(sig, &pos, 0, 0);
}

/// Exactly one complete type, as in variants and array elements.
pub fn validateSingle(sig: []const u8) Error!void {
    if (sig.len > max_len) return error.InvalidSignature;
    if (try completeLen(sig) != sig.len) return error.InvalidSignature;
}

/// An array element type: a single complete type or a dict entry.
pub fn validateElement(elem: []const u8) Error!void {
    if (elem.len >= max_len) return error.InvalidSignature;
    var buf: [max_len]u8 = undefined;
    buf[0] = 'a';
    @memcpy(buf[1..][0..elem.len], elem);
    try validateSingle(buf[0 .. elem.len + 1]);
}

pub fn isValid(sig: []const u8) bool {
    validate(sig) catch return false;
    return true;
}

pub fn isSingle(sig: []const u8) bool {
    validateSingle(sig) catch return false;
    return true;
}

/// Iterates the complete types of a valid signature.
pub const Iterator = struct {
    sig: []const u8,
    pos: usize = 0,

    pub fn next(it: *Iterator) ?[]const u8 {
        if (it.pos >= it.sig.len) return null;
        const n = skipLen(it.sig[it.pos..]);
        defer it.pos += n;
        return it.sig[it.pos..][0..n];
    }
};

test "valid signatures" {
    for ([_][]const u8{ "", "y", "a{sv}", "(ii)", "a(sa{sv})", "aai", "v", "a{s(ddd)}", "(yv)", "a{sa{sv}}", "h" }) |s| {
        try std.testing.expect(isValid(s));
    }
    try std.testing.expect(isSingle("a{sa{sv}}"));
    try std.testing.expect(!isSingle("ii"));
    try std.testing.expect(!isSingle(""));
}

test "invalid signatures" {
    for ([_][]const u8{ "()", "(", ")", "a", "{sv}", "a{vs}", "a{s}", "a{sss}", "a{(i)s}", "z", "(i", "i)", "a{sv", "ae" }) |s| {
        try std.testing.expect(!isValid(s));
    }
}

test "depth limits" {
    const t = std.testing;
    try t.expect(isValid(rep('a', 32) ++ "i"));
    try t.expect(!isValid(rep('a', 33) ++ "i"));
    try t.expect(isValid(rep('(', 32) ++ "i" ++ rep(')', 32)));
    try t.expect(!isValid(rep('(', 33) ++ "i" ++ rep(')', 33)));
    // Dict entries count as structs.
    try t.expect(!isValid(rep('(', 32) ++ "a{si}" ++ rep(')', 32)));
    try t.expect(isValid(rep('(', 31) ++ "a{si}" ++ rep(')', 31)));
    try t.expect(!isValid(rep('i', 256)));
}

test "fuzz signature validation" {
    try std.testing.fuzz({}, fuzzValidate, .{ .corpus = &.{ "a{sv}", "(ii)a(sa{sv})", rep('a', 32) ++ "y" } });
}

fn fuzzValidate(_: void, smith: *std.testing.Smith) !void {
    var buf: [300]u8 = undefined;
    const sig = buf[0..smith.slice(&buf)];
    validate(sig) catch return;
    // A valid signature iterates into complete types that are each valid.
    var it: Iterator = .{ .sig = sig };
    var total: usize = 0;
    while (it.next()) |t| {
        try validateSingle(t);
        total += t.len;
    }
    try std.testing.expectEqual(sig.len, total);
}

fn rep(comptime c: u8, comptime n: usize) *const [n]u8 {
    const a: [n]u8 = @splat(c);
    return &a;
}
