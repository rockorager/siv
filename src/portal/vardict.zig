//! Portal option and result dictionaries (a{sv}): writing options, and
//! looking up keys in results by type without allocating. Lookups ignore
//! values of the wrong type, as a client must for keys a newer portal
//! might type differently.

const std = @import("std");
const dbus = @import("dbus");

const Encoder = dbus.Encoder;
const Decoder = dbus.Decoder;

/// Writes an a{sv} into an encoder.
pub const Writer = struct {
    e: *Encoder,

    pub fn begin(e: *Encoder) dbus.codec.EncodeError!Writer {
        try e.beginArray("{sv}");
        return .{ .e = e };
    }

    pub fn end(w: Writer) dbus.codec.EncodeError!void {
        try w.e.endArray();
    }

    /// One entry whose value is written with `Encoder.write`.
    pub fn put(w: Writer, key: []const u8, value: anytype) dbus.codec.EncodeError!void {
        try w.e.beginDictEntry();
        try w.e.writeString(key);
        try w.e.write(dbus.variant(value));
        try w.e.endDictEntry();
    }

    /// Opens an entry of signature `sig`; write the value, then `close`.
    pub fn open(w: Writer, key: []const u8, sig: []const u8) dbus.codec.EncodeError!void {
        try w.e.beginDictEntry();
        try w.e.writeString(key);
        try w.e.beginVariant(sig);
    }

    pub fn close(w: Writer) dbus.codec.EncodeError!void {
        try w.e.endVariant();
        try w.e.endDictEntry();
    }

    /// A NUL-terminated byte string (ay), as portals take file paths.
    pub fn path(w: Writer, key: []const u8, p: []const u8) dbus.codec.EncodeError!void {
        try w.open(key, "ay");
        try writeBytesZ(w.e, p);
        try w.close();
    }
};

/// Writes `s` and a NUL as an ay.
pub fn writeBytesZ(e: *Encoder, s: []const u8) dbus.codec.EncodeError!void {
    try e.beginArray("y");
    for (s) |c| try e.writeByte(c);
    try e.writeByte(0);
    try e.endArray();
}

/// Reads an ay, dropping one trailing NUL.
pub fn readBytesZ(d: *Decoder) dbus.codec.DecodeError![]const u8 {
    const b = (try d.read(dbus.Bytes)).bytes;
    return if (b.len > 0 and b[b.len - 1] == 0) b[0 .. b.len - 1] else b;
}

/// An a{sv} in a received message, read in place.
pub const Reader = struct {
    /// Positioned at the a{sv}.
    d: Decoder,

    /// A reader for the a{sv} at `d`'s cursor; advances `d` past it.
    pub fn take(d: *Decoder) dbus.codec.DecodeError!Reader {
        // At an array element's start the remaining signature is empty, so
        // the type is checked by opening the array on a copy.
        var probe = d.*;
        const a = try probe.beginArray();
        if (!std.mem.eql(u8, a.elem, "{sv}")) return error.SignatureMismatch;
        const r: Reader = .{ .d = d.* };
        try d.skip();
        return r;
    }

    pub const empty: Reader = .{ .d = Decoder.init(&empty_dict, "a{sv}", .little, &.{}) };
    const empty_dict = [_]u8{ 0, 0, 0, 0 };

    /// The value of `key` with signature `sig`: a decoder positioned on
    /// it inside its variant. Null if absent or of another type.
    pub fn get(r: *const Reader, key: []const u8, sig: []const u8) ?Decoder {
        var d = r.d;
        const a = d.beginArray() catch return null;
        while (a.next(&d)) {
            d.beginDictEntry() catch return null;
            const k = d.readString() catch return null;
            const vs = d.beginVariant() catch return null;
            if (std.mem.eql(u8, k, key) and std.mem.eql(u8, vs, sig)) return d;
            d.endVariant() catch return null;
            d.endDictEntry() catch return null;
        }
        return null;
    }

    pub fn string(r: *const Reader, key: []const u8) ?[]const u8 {
        var d = r.get(key, "s") orelse return null;
        return d.readString() catch null;
    }

    pub fn objectPath(r: *const Reader, key: []const u8) ?[]const u8 {
        var d = r.get(key, "o") orelse return null;
        return d.readObjectPath() catch null;
    }

    pub fn uint(r: *const Reader, key: []const u8) ?u32 {
        var d = r.get(key, "u") orelse return null;
        return d.readUint32() catch null;
    }

    pub fn boolean(r: *const Reader, key: []const u8) ?bool {
        var d = r.get(key, "b") orelse return null;
        return d.readBool() catch null;
    }

    /// An ay value without its trailing NUL.
    pub fn bytesZ(r: *const Reader, key: []const u8) ?[]const u8 {
        var d = r.get(key, "ay") orelse return null;
        return readBytesZ(&d) catch null;
    }

    /// Iterates the strings of an `as` value.
    pub fn strings(r: *const Reader, key: []const u8) ?StringIterator {
        var d = r.get(key, "as") orelse return null;
        const a = d.beginArray() catch return null;
        return .{ .d = d, .a = a };
    }
};

pub const StringIterator = struct {
    d: Decoder,
    a: Decoder.Array,

    pub fn next(it: *StringIterator) ?[]const u8 {
        if (!it.a.next(&it.d)) return null;
        return it.d.readString() catch null;
    }
};
