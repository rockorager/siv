//! Messages: the fixed header and header fields, parsing and validation of
//! received messages, and building outgoing ones.
//!
//! A received `Message` is a view into the connection's receive buffer: its
//! strings and body are borrowed and valid only while it is being
//! dispatched. Outgoing messages are a `Builder`: header fields (borrowed
//! until the message is sent) and a body `Encoder`.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Endian = std.builtin.Endian;
const codec = @import("codec.zig");
const sig = @import("signature.zig");
const names = @import("names.zig");

pub const Encoder = codec.Encoder;
pub const Decoder = codec.Decoder;

pub const Type = enum(u8) {
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
    _,
};

pub const Flags = packed struct(u8) {
    no_reply_expected: bool = false,
    no_auto_start: bool = false,
    allow_interactive_authorization: bool = false,
    _: u5 = 0,
};

const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
    _,

    fn typeCode(f: Field) ?u8 {
        return switch (f) {
            .path => 'o',
            .interface, .member, .error_name, .destination, .sender => 's',
            .reply_serial, .unix_fds => 'u',
            .signature => 'g',
            _ => null,
        };
    }
};

pub const fixed_header_len = 16;

/// Header fields of an outgoing message. Strings are borrowed until the
/// header is encoded.
pub const Header = struct {
    type: Type,
    flags: Flags = .{},
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    reply_serial: ?u32 = null,

    /// Checks names and required fields, so that a bus never receives an
    /// invalid message from siv.
    pub fn validate(h: *const Header) error{InvalidMessage}!void {
        if (h.path) |p| if (!names.isObjectPath(p)) return error.InvalidMessage;
        if (h.interface) |i| if (!names.isInterfaceName(i)) return error.InvalidMessage;
        if (h.member) |m| if (!names.isMemberName(m)) return error.InvalidMessage;
        if (h.error_name) |e| if (!names.isErrorName(e)) return error.InvalidMessage;
        if (h.destination) |d| if (!names.isBusName(d)) return error.InvalidMessage;
        if (h.sender) |s| if (!names.isBusName(s)) return error.InvalidMessage;
        const ok = switch (h.type) {
            .method_call => h.path != null and h.member != null,
            .signal => h.path != null and h.interface != null and h.member != null,
            .method_return => h.reply_serial != null,
            .@"error" => h.reply_serial != null and h.error_name != null,
            _ => false,
        };
        if (!ok) return error.InvalidMessage;
    }
};

/// Appends the header (fixed part, fields, padding to 8) in little-endian
/// order. The body follows it directly.
pub fn encodeHeader(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    h: *const Header,
    serial: u32,
    body_sig: []const u8,
    body_len: usize,
    n_fds: usize,
) (Allocator.Error || error{MessageTooLarge})!void {
    const start = out.items.len;
    try out.ensureUnusedCapacity(gpa, 256);
    const fixed = try out.addManyAsArray(gpa, fixed_header_len);
    fixed[0..4].* = .{ 'l', @intFromEnum(h.type), @bitCast(h.flags), 1 };
    std.mem.writeInt(u32, fixed[4..8], @intCast(body_len), .little);
    std.mem.writeInt(u32, fixed[8..12], serial, .little);

    const W = struct {
        gpa: Allocator,
        out: *std.ArrayList(u8),
        start: usize,

        fn pad(w: @This(), a: usize) !void {
            const rel = w.out.items.len - w.start;
            const n = std.mem.alignForward(usize, rel, a) - rel;
            try w.out.appendNTimes(w.gpa, 0, n);
        }
        fn field(w: @This(), f: Field, s: []const u8) !void {
            try w.pad(8);
            try w.out.appendSlice(w.gpa, &.{ @intFromEnum(f), 1, f.typeCode().?, 0 });
            if (f == .signature) {
                try w.out.append(w.gpa, @intCast(s.len));
            } else {
                try w.pad(4);
                var len: [4]u8 = undefined;
                std.mem.writeInt(u32, &len, @intCast(s.len), .little);
                try w.out.appendSlice(w.gpa, &len);
            }
            try w.out.appendSlice(w.gpa, s);
            try w.out.append(w.gpa, 0);
        }
        fn int(w: @This(), f: Field, v: u32) !void {
            try w.pad(8);
            try w.out.appendSlice(w.gpa, &.{ @intFromEnum(f), 1, 'u', 0 });
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try w.out.appendSlice(w.gpa, &b);
        }
    };
    const w: W = .{ .gpa = gpa, .out = out, .start = start };
    if (h.path) |s| try w.field(.path, s);
    if (h.interface) |s| try w.field(.interface, s);
    if (h.member) |s| try w.field(.member, s);
    if (h.error_name) |s| try w.field(.error_name, s);
    if (h.reply_serial) |v| try w.int(.reply_serial, v);
    if (h.destination) |s| try w.field(.destination, s);
    if (h.sender) |s| try w.field(.sender, s);
    if (body_sig.len > 0) try w.field(.signature, body_sig);
    if (n_fds > 0) try w.int(.unix_fds, @intCast(n_fds));
    const fields_len = out.items.len - start - fixed_header_len;
    std.mem.writeInt(u32, out.items[start + 12 ..][0..4], @intCast(fields_len), .little);
    try w.pad(8);
    if (out.items.len - start + body_len > codec.max_message_len) return error.MessageTooLarge;
}

/// A received message, validated in full. Borrowed from its buffer.
pub const Message = struct {
    data: []const u8,
    endian: Endian,
    type: Type,
    flags: Flags,
    serial: u32,
    body_offset: usize,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
    reply_serial: ?u32 = null,
    unix_fds: u32 = 0,
    /// The message's fds, owned by the connection until the message has
    /// been dispatched; `takeFd` keeps one.
    fds: []i32 = &.{},

    pub const Error = error{InvalidMessage};

    /// The total length of the message whose first 16 bytes are `head`.
    pub fn frameLength(head: *const [fixed_header_len]u8) Error!usize {
        const endian: Endian = switch (head[0]) {
            'l' => .little,
            'B' => .big,
            else => return error.InvalidMessage,
        };
        if (head[3] != 1) return error.InvalidMessage;
        const body_len = std.mem.readInt(u32, head[4..8], endian);
        const fields_len = std.mem.readInt(u32, head[12..16], endian);
        if (fields_len > codec.max_array_len or body_len > codec.max_message_len) return error.InvalidMessage;
        const total = std.mem.alignForward(usize, fixed_header_len + fields_len, 8) + body_len;
        if (total > codec.max_message_len) return error.InvalidMessage;
        return total;
    }

    /// Parses and validates a complete message (`frameLength` bytes).
    pub fn parse(data: []const u8) Error!Message {
        if (data.len < fixed_header_len) return error.InvalidMessage;
        if (try frameLength(data[0..fixed_header_len]) != data.len) return error.InvalidMessage;
        const endian: Endian = if (data[0] == 'l') .little else .big;
        var m: Message = .{
            .data = data,
            .endian = endian,
            .type = @enumFromInt(data[1]),
            .flags = @bitCast(data[2]),
            .serial = std.mem.readInt(u32, data[8..12], endian),
            .body_offset = 0,
        };
        if (m.serial == 0) return error.InvalidMessage;
        const fields_len = std.mem.readInt(u32, data[12..16], endian);
        const fields_end = fixed_header_len + fields_len;

        var v: codec.Validator = .{ .data = data[0..fields_end], .off = fixed_header_len, .endian = endian, .n_fds = 0 };
        var seen: u16 = 0;
        while (v.off < fields_end) {
            v.off = try alignZero(data[0..fields_end], v.off, 8);
            if (v.off >= fields_end) return error.InvalidMessage;
            const code: Field = @enumFromInt(data[v.off]);
            v.off += 1;
            // The variant's signature, then its value.
            const vs_start = v.off;
            _ = v.value("g", 1) catch return error.InvalidMessage;
            const vs = data[vs_start + 1 ..][0..data[vs_start]];
            sig.validateSingle(vs) catch return error.InvalidMessage;
            if (code.typeCode()) |expected| {
                if (vs.len != 1 or vs[0] != expected) return error.InvalidMessage;
                const bit = @as(u16, 1) << @intCast(@intFromEnum(code));
                if (seen & bit != 0) return error.InvalidMessage;
                seen |= bit;
            }
            const value_start = std.mem.alignForward(usize, v.off, sig.alignment(vs[0]));
            _ = v.value(vs, 1) catch return error.InvalidMessage;
            switch (code) {
                .path => m.path = stringAt(data, value_start, endian),
                .interface => m.interface = stringAt(data, value_start, endian),
                .member => m.member = stringAt(data, value_start, endian),
                .error_name => m.error_name = stringAt(data, value_start, endian),
                .destination => m.destination = stringAt(data, value_start, endian),
                .sender => m.sender = stringAt(data, value_start, endian),
                .signature => m.signature = data[value_start + 1 ..][0..data[value_start]],
                .reply_serial => m.reply_serial = std.mem.readInt(u32, data[value_start..][0..4], endian),
                .unix_fds => m.unix_fds = std.mem.readInt(u32, data[value_start..][0..4], endian),
                _ => {}, // unknown fields are ignored
            }
        }
        if (v.off != fields_end) return error.InvalidMessage;
        m.body_offset = try alignZero(data, fields_end, 8);

        if (m.interface) |i| if (!names.isInterfaceName(i)) return error.InvalidMessage;
        if (m.member) |s| if (!names.isMemberName(s)) return error.InvalidMessage;
        if (m.error_name) |s| if (!names.isErrorName(s)) return error.InvalidMessage;
        if (m.destination) |s| if (!names.isBusName(s)) return error.InvalidMessage;
        if (m.sender) |s| if (!names.isBusName(s)) return error.InvalidMessage;
        if (m.reply_serial) |s| if (s == 0) return error.InvalidMessage;
        const required = switch (m.type) {
            .method_call => m.path != null and m.member != null,
            .signal => m.path != null and m.interface != null and m.member != null,
            .method_return => m.reply_serial != null,
            .@"error" => m.reply_serial != null and m.error_name != null,
            _ => true, // unknown types are ignored by the receiver
        };
        if (!required) return error.InvalidMessage;
        if (m.unix_fds > codec.max_fds) return error.InvalidMessage;
        codec.validateBody(data[m.body_offset..], m.signature, endian, m.unix_fds) catch return error.InvalidMessage;
        return m;
    }

    pub fn body(m: *const Message) Decoder {
        return .init(m.data[m.body_offset..], m.signature, m.endian, m.fds);
    }

    pub fn bodyBytes(m: *const Message) []const u8 {
        return m.data[m.body_offset..];
    }

    /// The text of an error reply (its first argument, if a string).
    pub fn errorMessage(m: *const Message) ?[]const u8 {
        if (m.signature.len == 0 or m.signature[0] != 's') return null;
        var d = m.body();
        return d.readString() catch null;
    }

    /// Takes ownership of fd `index`, which the connection would otherwise
    /// close after dispatch. Returns null if it was taken already.
    pub fn takeFd(m: *const Message, index: usize) ?i32 {
        if (index >= m.fds.len or m.fds[index] < 0) return null;
        defer m.fds[index] = -1;
        return m.fds[index];
    }

    pub fn isMember(m: *const Message, interface: []const u8, member: []const u8) bool {
        return eqlOpt(m.interface, interface) and eqlOpt(m.member, member);
    }
};

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

fn stringAt(data: []const u8, off: usize, endian: Endian) []const u8 {
    const len = std.mem.readInt(u32, data[off..][0..4], endian);
    return data[off + 4 ..][0..len];
}

fn alignZero(data: []const u8, off: usize, a: usize) error{InvalidMessage}!usize {
    const new = std.mem.alignForward(usize, off, a);
    if (new > data.len) return error.InvalidMessage;
    for (data[off..new]) |b| if (b != 0) return error.InvalidMessage;
    return new;
}

/// An outgoing message: header fields and a body. Send it through a
/// connection, which takes the body, or `deinit` it.
pub const Builder = struct {
    header: Header,
    body: Encoder,

    pub fn init(gpa: Allocator, header: Header) Builder {
        return .{ .header = header, .body = .init(gpa) };
    }

    pub fn deinit(b: *Builder) void {
        b.body.deinit();
    }

    /// Encodes the whole message into one buffer, for tests and tools.
    pub fn encode(b: *const Builder, gpa: Allocator, serial: u32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try encodeHeader(gpa, &out, &b.header, serial, b.body.signature(), b.body.bytes().len, b.body.fds.items.len);
        try out.appendSlice(gpa, b.body.bytes());
        return out.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

test "a built message parses back with every field" {
    var b: Builder = .init(testing.allocator, .{
        .type = .method_call,
        .flags = .{ .no_auto_start = true },
        .path = "/org/freedesktop/portal/desktop",
        .interface = "org.freedesktop.portal.Settings",
        .member = "ReadAll",
        .destination = "org.freedesktop.portal.Desktop",
        .sender = ":1.7",
    });
    defer b.deinit();
    try b.body.write(@as([]const []const u8, &.{ "org.freedesktop.appearance", "org.gnome.*" }));
    try b.header.validate();
    const data = try b.encode(testing.allocator, 42);
    defer testing.allocator.free(data);

    try testing.expectEqual(data.len, try Message.frameLength(data[0..16]));
    const m = try Message.parse(data);
    try testing.expectEqual(Type.method_call, m.type);
    try testing.expect(m.flags.no_auto_start);
    try testing.expectEqual(@as(u32, 42), m.serial);
    try testing.expectEqualStrings("/org/freedesktop/portal/desktop", m.path.?);
    try testing.expectEqualStrings("org.freedesktop.portal.Settings", m.interface.?);
    try testing.expectEqualStrings("ReadAll", m.member.?);
    try testing.expectEqualStrings("org.freedesktop.portal.Desktop", m.destination.?);
    try testing.expectEqualStrings(":1.7", m.sender.?);
    try testing.expectEqualStrings("as", m.signature);
    var d = m.body();
    const a = try d.beginArray();
    try testing.expect(a.next(&d));
    try testing.expectEqualStrings("org.freedesktop.appearance", try d.readString());
    try testing.expectEqualStrings("org.gnome.*", try d.readString());
    try testing.expect(!a.next(&d));
}

test "the header encoding matches libdbus byte for byte" {
    var b: Builder = .init(testing.allocator, .{
        .type = .method_call,
        .path = "/a",
        .interface = "org.x.Y",
        .member = "M",
        .destination = "org.x.Y",
    });
    defer b.deinit();
    const data = try b.encode(testing.allocator, 1);
    defer testing.allocator.free(data);
    // What `dbus-send --dest=org.x.Y /a org.x.Y.M` (libdbus 1.14) wrote to
    // a socket.
    const expected = "6c01000100000000010000004000000001016f00020000002f61000000000000" ++
        "02017300070000006f72672e782e590003017300010000004d00000000000000" ++
        "06017300070000006f72672e782e5900";
    var raw: [expected.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw, expected);
    try testing.expectEqualSlices(u8, &raw, data);
}

test "big-endian messages parse" {
    // A signal with path "/", interface "a.b", member "C", body "u" = 1.
    const data = "B\x04\x00\x01\x00\x00\x00\x04\x00\x00\x00\x07\x00\x00\x00\x37" ++
        "\x01\x01o\x00\x00\x00\x00\x01/\x00\x00\x00\x00\x00\x00\x00" ++
        "\x02\x01s\x00\x00\x00\x00\x03a.b\x00\x00\x00\x00\x00" ++
        "\x03\x01s\x00\x00\x00\x00\x01C\x00\x00\x00\x00\x00\x00\x00" ++
        "\x08\x01g\x00\x01u\x00\x00" ++
        "\x00\x00\x00\x01";
    const m = try Message.parse(data);
    try testing.expectEqual(Type.signal, m.type);
    try testing.expectEqual(@as(u32, 7), m.serial);
    try testing.expectEqualStrings("a.b", m.interface.?);
    var d = m.body();
    try testing.expectEqual(@as(u32, 1), try d.readUint32());
}

test "invalid headers are rejected" {
    var b: Builder = .init(testing.allocator, .{ .type = .signal, .path = "/", .interface = "a.b", .member = "C" });
    defer b.deinit();
    try b.body.write(@as(u32, 1));
    const good = try b.encode(testing.allocator, 3);
    defer testing.allocator.free(good);
    _ = try Message.parse(good);

    var bad = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(bad);
    const mutations = [_]struct { usize, u8 }{
        .{ 0, 'x' }, // endianness
        .{ 3, 2 }, // protocol version
        .{ 8, 0 }, // serial 0 (with the other serial bytes zero)
        .{ 18, 's' }, // path field with the wrong type
        .{ 16, 3 }, // path field becomes a second member field
    };
    for (mutations) |mu| {
        @memcpy(bad, good);
        bad[mu[0]] = mu[1];
        try testing.expectError(error.InvalidMessage, Message.parse(bad));
    }
    // A signal without its interface field fails `validate` before sending.
    var h: Header = .{ .type = .signal, .path = "/", .member = "C" };
    try testing.expectError(error.InvalidMessage, h.validate());
    h.interface = "nodot";
    try testing.expectError(error.InvalidMessage, h.validate());
}

test "fuzz message parsing" {
    var b: Builder = .init(testing.allocator, .{ .type = .method_call, .path = "/a", .interface = "a.b", .member = "M", .destination = ":1.1" });
    defer b.deinit();
    try b.body.writeAll(.{ "x", codec.variant(@as(u32, 1)), @as([]const u8, &.{ 1, 2 }) });
    const seed = try b.encode(testing.allocator, 9);
    defer testing.allocator.free(seed);
    try std.testing.fuzz(seed, fuzzParse, .{ .corpus = &.{seed} });
}

/// A message that parses must decode completely.
fn fuzzParse(_: []const u8, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 align(8) = undefined;
    const data = buf[0..smith.slice(&buf)];
    if (data.len >= fixed_header_len) {
        const n = Message.frameLength(data[0..fixed_header_len]) catch return;
        _ = n;
    }
    const m = Message.parse(data) catch return;
    var fds: [codec.max_fds]i32 = @splat(-1);
    var mm = m;
    mm.fds = fds[0..m.unix_fds];
    var d = mm.body();
    while (d.peek() != null) try d.skip();
    try testing.expectEqual(m.bodyBytes().len, d.off);
}
