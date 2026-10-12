//! Marshalling: the encoder and decoder for message bodies and the
//! validator for values received from the wire.
//!
//! The encoder tracks the signature as values are written. At the top level
//! (the body) it accumulates the signature; inside arrays and variants,
//! whose element types are declared up front, it checks each value against
//! the declared type, so a body it produces always matches its signature.
//!
//! Received bodies are validated once, in full, when the message is parsed
//! (`validateBody`): alignment padding is zero, booleans are 0 or 1,
//! strings are UTF-8 without NUL, paths and signatures are well formed,
//! array lengths match their elements, fd indexes are in range, and
//! containers nest at most 64 deep. The decoder then reads borrowed slices
//! out of the message without copying, and checks only that each read
//! matches the signature.
//!
//! Typed values map to D-Bus types as follows: u8 y, bool b, i16 n, u16 q,
//! i32 i, u32 u, i64 x, u64 t, f64 d, []const u8 s, `ObjectPath` o,
//! `Signature` g, `Fd` h, `Bytes` ay, `Variant(T)` v, slices and arrays a,
//! `DictEntry(K, V)` {}, and other structs and tuples ().

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Endian = std.builtin.Endian;
const sig = @import("signature.zig");
const names = @import("names.zig");

pub const max_message_len = 1 << 27;
pub const max_array_len = 1 << 26;
/// The kernel's SCM_MAX_FD: fds one sendmsg can carry.
pub const max_fds = 253;

pub const DecodeError = error{
    /// The bytes violate the wire format.
    InvalidMessage,
    /// The read does not match the body's signature.
    SignatureMismatch,
};

pub const EncodeError = error{
    /// The write does not match the declared type of its container, or
    /// closes a container that is not open or not complete.
    SignatureMismatch,
    /// A signature argument is invalid, or the body signature or nesting
    /// would exceed the limits.
    InvalidSignature,
    /// A string is not UTF-8 or contains NUL, or an object path is invalid.
    InvalidValue,
    /// An array or the message would exceed the protocol limits, or more
    /// than 253 fds are attached.
    MessageTooLarge,
    /// Duplicating an fd failed.
    SystemResources,
} || Allocator.Error;

// Typed values ------------------------------------------------------------

pub const ObjectPath = struct {
    path: []const u8,
    pub const dbus_signature = "o";
};

pub const Signature = struct {
    sig: []const u8,
    pub const dbus_signature = "g";
};

/// A unix fd. Writing duplicates it; reading borrows the message's copy
/// (see `Message.takeFd` to keep it).
pub const Fd = struct {
    fd: i32,
    pub const dbus_signature = "h";
};

/// A byte array (ay), read without copying.
pub const Bytes = struct {
    bytes: []const u8,
    pub const dbus_signature = "ay";
};

/// A variant holding a value of static type `T`.
pub fn Variant(comptime T: type) type {
    return struct {
        value: T,
        pub const dbus_variant = T;
    };
}

pub fn variant(value: anytype) Variant(@TypeOf(value)) {
    return .{ .value = value };
}

/// An element of a dictionary (an array of `DictEntry`).
pub fn DictEntry(comptime K: type, comptime V: type) type {
    return struct {
        key: K,
        value: V,
        pub const dbus_dict_entry = true;
    };
}

/// The D-Bus signature of a Zig type.
pub fn signatureOf(comptime T: type) []const u8 {
    comptime {
        if (T == u8) return "y";
        if (T == bool) return "b";
        if (T == i16) return "n";
        if (T == u16) return "q";
        if (T == i32) return "i";
        if (T == u32) return "u";
        if (T == i64) return "x";
        if (T == u64) return "t";
        if (T == f64) return "d";
        if (isString(T)) return "s";
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                if (@hasDecl(T, "dbus_signature")) return T.dbus_signature;
                if (@hasDecl(T, "dbus_variant")) return "v";
                if (@hasDecl(T, "dbus_dict_entry")) {
                    return "{" ++ signatureOf(@FieldType(T, "key")) ++ signatureOf(@FieldType(T, "value")) ++ "}";
                }
                var out: []const u8 = "(";
                for (s.field_types) |ft| out = out ++ signatureOf(ft);
                return out ++ ")";
            },
            .pointer => |p| if (p.size == .slice) return "a" ++ signatureOf(p.child),
            .array => |a| return "a" ++ signatureOf(a.child),
            else => {},
        }
        @compileError("no D-Bus type for " ++ @typeName(T));
    }
}

/// The signature of a tuple of top-level values.
pub fn signatureOfArgs(comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(T).@"struct".field_types) |ft| out = out ++ signatureOf(ft);
        return out;
    }
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

// Encoder -----------------------------------------------------------------

pub const Encoder = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Duplicated fds the message owns, in index order.
    fds: std.ArrayList(i32) = .empty,
    sig_buf: [sig.max_len]u8 = undefined,
    sig_len: u8 = 0,
    stack: [sig.max_depth]Frame = undefined,
    depth: u8 = 0,
    arrays: u8 = 0,
    structs: u8 = 0,
    /// Index plus one of the innermost array or variant frame, whose
    /// declared type checks writes; 0 when writes extend the body
    /// signature.
    ctx: u8 = 0,

    const Frame = struct {
        kind: enum { array, variant, @"struct", dict_entry },
        // Array and variant frames.
        src: enum { sig_buf, body } = .sig_buf,
        sig_off: u32 = 0,
        sig_len: u8 = 0,
        pos: u8 = 0,
        prev_ctx: u8 = 0,
        // Array frames.
        len_off: u32 = 0,
        data_start: u32 = 0,
    };

    /// After any error the encoder's state is unspecified: discard it.
    pub fn init(gpa: Allocator) Encoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *Encoder) void {
        e.buf.deinit(e.gpa);
        for (e.fds.items) |fd| _ = linux.close(fd);
        e.fds.deinit(e.gpa);
        e.* = undefined;
    }

    /// The body signature written so far.
    pub fn signature(e: *const Encoder) []const u8 {
        return e.sig_buf[0..e.sig_len];
    }

    pub fn bytes(e: *const Encoder) []const u8 {
        return e.buf.items;
    }

    /// Whether every container has been closed.
    pub fn complete(e: *const Encoder) bool {
        return e.depth == 0;
    }

    fn frameSig(e: *const Encoder, f: *const Frame) []const u8 {
        const base = switch (f.src) {
            .sig_buf => e.sig_buf[0..],
            .body => e.buf.items,
        };
        return base[f.sig_off..][0..f.sig_len];
    }

    /// Accounts for a value starting with type code `code`.
    fn expect(e: *Encoder, code: u8) EncodeError!void {
        if (e.ctx == 0) {
            if (e.sig_len == sig.max_len) return error.InvalidSignature;
            e.sig_buf[e.sig_len] = code;
            e.sig_len += 1;
            return;
        }
        const f = &e.stack[e.ctx - 1];
        if (f.pos == f.sig_len) {
            if (f.kind != .array) return error.SignatureMismatch;
            f.pos = 0; // next element
        }
        if (e.frameSig(f)[f.pos] != code) return error.SignatureMismatch;
        f.pos += 1;
    }

    fn pad(e: *Encoder, a: usize) Allocator.Error!void {
        const n = std.mem.alignForward(usize, e.buf.items.len, a) - e.buf.items.len;
        @memset(try e.buf.addManyAsSlice(e.gpa, n), 0);
    }

    fn putInt(e: *Encoder, comptime T: type, v: T) Allocator.Error!void {
        try e.pad(@sizeOf(T));
        std.mem.writeInt(T, (try e.buf.addManyAsArray(e.gpa, @sizeOf(T))), v, .little);
    }

    fn push(e: *Encoder, f: Frame) EncodeError!void {
        if (e.depth == sig.max_depth) return error.InvalidSignature;
        e.stack[e.depth] = f;
        e.depth += 1;
    }

    pub fn writeByte(e: *Encoder, v: u8) EncodeError!void {
        try e.expect('y');
        try e.buf.append(e.gpa, v);
    }

    pub fn writeBool(e: *Encoder, v: bool) EncodeError!void {
        try e.expect('b');
        try e.putInt(u32, @intFromBool(v));
    }

    pub fn writeInt16(e: *Encoder, v: i16) EncodeError!void {
        try e.expect('n');
        try e.putInt(i16, v);
    }

    pub fn writeUint16(e: *Encoder, v: u16) EncodeError!void {
        try e.expect('q');
        try e.putInt(u16, v);
    }

    pub fn writeInt32(e: *Encoder, v: i32) EncodeError!void {
        try e.expect('i');
        try e.putInt(i32, v);
    }

    pub fn writeUint32(e: *Encoder, v: u32) EncodeError!void {
        try e.expect('u');
        try e.putInt(u32, v);
    }

    pub fn writeInt64(e: *Encoder, v: i64) EncodeError!void {
        try e.expect('x');
        try e.putInt(i64, v);
    }

    pub fn writeUint64(e: *Encoder, v: u64) EncodeError!void {
        try e.expect('t');
        try e.putInt(u64, v);
    }

    pub fn writeDouble(e: *Encoder, v: f64) EncodeError!void {
        try e.expect('d');
        try e.putInt(u64, @bitCast(v));
    }

    fn putString(e: *Encoder, s: []const u8) EncodeError!void {
        if (s.len > max_message_len) return error.MessageTooLarge;
        try e.putInt(u32, @intCast(s.len));
        try e.buf.ensureUnusedCapacity(e.gpa, s.len + 1);
        e.buf.appendSliceAssumeCapacity(s);
        e.buf.appendAssumeCapacity(0);
    }

    pub fn writeString(e: *Encoder, s: []const u8) EncodeError!void {
        if (!isValidString(s)) return error.InvalidValue;
        try e.expect('s');
        try e.putString(s);
    }

    pub fn writeObjectPath(e: *Encoder, p: []const u8) EncodeError!void {
        if (!names.isObjectPath(p)) return error.InvalidValue;
        try e.expect('o');
        try e.putString(p);
    }

    fn putSig(e: *Encoder, s: []const u8) Allocator.Error!void {
        try e.buf.ensureUnusedCapacity(e.gpa, s.len + 2);
        e.buf.appendAssumeCapacity(@intCast(s.len));
        e.buf.appendSliceAssumeCapacity(s);
        e.buf.appendAssumeCapacity(0);
    }

    pub fn writeSignature(e: *Encoder, s: []const u8) EncodeError!void {
        try sig.validate(s);
        try e.expect('g');
        try e.putSig(s);
    }

    /// Attaches a duplicate of `fd`; the caller keeps its own.
    pub fn writeFd(e: *Encoder, fd: i32) EncodeError!void {
        if (e.fds.items.len == max_fds) return error.MessageTooLarge;
        try e.expect('h');
        try e.fds.ensureUnusedCapacity(e.gpa, 1);
        const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 3);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        e.fds.appendAssumeCapacity(@intCast(rc));
        try e.putInt(u32, @intCast(e.fds.items.len - 1));
    }

    /// Opens an array of `elem`, a single complete type.
    pub fn beginArray(e: *Encoder, elem: []const u8) EncodeError!void {
        try sig.validateElement(elem);
        if (e.arrays == sig.max_array_depth) return error.InvalidSignature;
        var f: Frame = .{ .kind = .array, .sig_len = @intCast(elem.len), .prev_ctx = e.ctx };
        if (e.ctx == 0) {
            if (@as(usize, e.sig_len) + 1 + elem.len > sig.max_len) return error.InvalidSignature;
            e.sig_buf[e.sig_len] = 'a';
            @memcpy(e.sig_buf[e.sig_len + 1 ..][0..elem.len], elem);
            f.src = .sig_buf;
            f.sig_off = e.sig_len + 1;
            e.sig_len += @intCast(1 + elem.len);
        } else {
            try e.expect('a');
            const p = &e.stack[e.ctx - 1];
            const rest = e.frameSig(p)[p.pos..];
            if (!std.mem.startsWith(u8, rest, elem) or sig.skipLen(rest) != elem.len) return error.SignatureMismatch;
            f.src = switch (p.src) {
                .sig_buf => .sig_buf,
                .body => .body,
            };
            f.sig_off = p.sig_off + p.pos;
            p.pos += @intCast(elem.len);
        }
        try e.pad(4);
        f.len_off = @intCast(e.buf.items.len);
        try e.buf.appendNTimes(e.gpa, 0, 4);
        try e.pad(sig.alignment(elem[0]));
        f.data_start = @intCast(e.buf.items.len);
        try e.push(f);
        e.arrays += 1;
        e.ctx = e.depth;
    }

    pub fn endArray(e: *Encoder) EncodeError!void {
        if (e.depth == 0) return error.SignatureMismatch;
        const f = &e.stack[e.depth - 1];
        if (f.kind != .array or (f.pos != 0 and f.pos != f.sig_len)) return error.SignatureMismatch;
        const len = e.buf.items.len - f.data_start;
        if (len > max_array_len) return error.MessageTooLarge;
        std.mem.writeInt(u32, e.buf.items[f.len_off..][0..4], @intCast(len), .little);
        e.ctx = f.prev_ctx;
        e.depth -= 1;
        e.arrays -= 1;
    }

    pub fn beginStruct(e: *Encoder) EncodeError!void {
        if (e.structs == sig.max_struct_depth) return error.InvalidSignature;
        try e.expect('(');
        try e.pad(8);
        try e.push(.{ .kind = .@"struct" });
        e.structs += 1;
    }

    pub fn endStruct(e: *Encoder) EncodeError!void {
        if (e.depth == 0 or e.stack[e.depth - 1].kind != .@"struct") return error.SignatureMismatch;
        if (e.ctx == 0 and e.sig_buf[e.sig_len - 1] == '(') return error.SignatureMismatch; // empty
        try e.expect(')');
        e.depth -= 1;
        e.structs -= 1;
    }

    /// Opens a dict entry, which must be an element of an array of them.
    pub fn beginDictEntry(e: *Encoder) EncodeError!void {
        if (e.ctx == 0) return error.SignatureMismatch;
        if (e.structs == sig.max_struct_depth) return error.InvalidSignature;
        try e.expect('{');
        try e.pad(8);
        try e.push(.{ .kind = .dict_entry });
        e.structs += 1;
    }

    pub fn endDictEntry(e: *Encoder) EncodeError!void {
        if (e.depth == 0 or e.stack[e.depth - 1].kind != .dict_entry) return error.SignatureMismatch;
        try e.expect('}');
        e.depth -= 1;
        e.structs -= 1;
    }

    /// Opens a variant holding one value of type `s`.
    pub fn beginVariant(e: *Encoder, s: []const u8) EncodeError!void {
        try sig.validateSingle(s);
        try e.expect('v');
        const off: u32 = @intCast(e.buf.items.len + 1);
        try e.putSig(s);
        try e.push(.{ .kind = .variant, .src = .body, .sig_off = off, .sig_len = @intCast(s.len), .prev_ctx = e.ctx });
        e.ctx = e.depth;
    }

    pub fn endVariant(e: *Encoder) EncodeError!void {
        if (e.depth == 0) return error.SignatureMismatch;
        const f = &e.stack[e.depth - 1];
        if (f.kind != .variant or f.pos != f.sig_len) return error.SignatureMismatch;
        e.ctx = f.prev_ctx;
        e.depth -= 1;
    }

    /// Writes one value of a type listed in the module documentation.
    pub fn write(e: *Encoder, value: anytype) EncodeError!void {
        const T = @TypeOf(value);
        switch (T) {
            u8 => return e.writeByte(value),
            bool => return e.writeBool(value),
            i16 => return e.writeInt16(value),
            u16 => return e.writeUint16(value),
            i32 => return e.writeInt32(value),
            u32 => return e.writeUint32(value),
            i64 => return e.writeInt64(value),
            u64 => return e.writeUint64(value),
            f64 => return e.writeDouble(value),
            ObjectPath => return e.writeObjectPath(value.path),
            Signature => return e.writeSignature(value.sig),
            Fd => return e.writeFd(value.fd),
            Bytes => {
                try e.beginArray("y");
                try e.buf.appendSlice(e.gpa, value.bytes);
                return e.endArray();
            },
            else => {},
        }
        if (comptime isString(T)) return e.writeString(value);
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                if (@hasDecl(T, "dbus_variant")) {
                    try e.beginVariant(comptime signatureOf(T.dbus_variant));
                    try e.write(value.value);
                    return e.endVariant();
                }
                if (@hasDecl(T, "dbus_dict_entry")) {
                    try e.beginDictEntry();
                    try e.write(value.key);
                    try e.write(value.value);
                    return e.endDictEntry();
                }
                try e.beginStruct();
                inline for (s.field_names) |name| try e.write(@field(value, name));
                return e.endStruct();
            },
            .pointer, .array => {
                const Elem = std.meta.Elem(T);
                try e.beginArray(comptime signatureOf(Elem));
                if (comptime fixedNative(Elem)) {
                    // Little-endian fixed-size elements are already in wire
                    // layout; the element alignment padding was written.
                    const f = &e.stack[e.depth - 1];
                    const items: []const Elem = if (@typeInfo(T) == .array) &value else value;
                    try e.buf.appendSlice(e.gpa, std.mem.sliceAsBytes(items));
                    if (items.len > 0) f.pos = f.sig_len;
                } else {
                    for (value) |item| try e.write(item);
                }
                return e.endArray();
            },
            else => @compileError("no D-Bus type for " ++ @typeName(T)),
        }
    }

    /// Writes each field of the tuple `values` as a top-level value.
    pub fn writeAll(e: *Encoder, values: anytype) EncodeError!void {
        inline for (@typeInfo(@TypeOf(values)).@"struct".field_names) |name| try e.write(@field(values, name));
    }
};

fn fixedNative(comptime T: type) bool {
    if (@import("builtin").cpu.arch.endian() != .little) return false;
    return switch (T) {
        u8, i16, u16, i32, u32, i64, u64, f64 => true,
        else => false,
    };
}

fn isValidString(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s);
}

// Validation --------------------------------------------------------------

/// Walks values in `data`, whose offset 0 is 8-aligned in the message.
pub const Validator = struct {
    data: []const u8,
    off: usize = 0,
    endian: Endian,
    n_fds: u32,

    fn pad(v: *Validator, a: usize) DecodeError!void {
        const new = std.mem.alignForward(usize, v.off, a);
        if (new > v.data.len) return error.InvalidMessage;
        for (v.data[v.off..new]) |b| if (b != 0) return error.InvalidMessage;
        v.off = new;
    }

    fn take(v: *Validator, n: usize) DecodeError![]const u8 {
        if (v.data.len - v.off < n) return error.InvalidMessage;
        defer v.off += n;
        return v.data[v.off..][0..n];
    }

    fn int(v: *Validator, comptime T: type) DecodeError!T {
        try v.pad(@sizeOf(T));
        return std.mem.readInt(T, (try v.take(@sizeOf(T)))[0..@sizeOf(T)], v.endian);
    }

    /// Reads a string-like value's bytes (without the NUL).
    fn str(v: *Validator) DecodeError![]const u8 {
        const len = try v.int(u32);
        const b = try v.take(@as(usize, len) + 1);
        if (b[len] != 0) return error.InvalidMessage;
        return b[0..len];
    }

    fn sigValue(v: *Validator) DecodeError![]const u8 {
        const len = (try v.take(1))[0];
        const b = try v.take(@as(usize, len) + 1);
        if (b[len] != 0) return error.InvalidMessage;
        return b[0..len];
    }

    /// Validates one value of the complete type at the start of `s`, a
    /// valid signature, and returns the type's length.
    pub fn value(v: *Validator, s: []const u8, depth: u8) DecodeError!usize {
        switch (s[0]) {
            'y' => _ = try v.take(1),
            'b' => if (try v.int(u32) > 1) return error.InvalidMessage,
            'n', 'q' => _ = try v.int(u16),
            'i', 'u' => _ = try v.int(u32),
            'x', 't', 'd' => _ = try v.int(u64),
            'h' => if (try v.int(u32) >= v.n_fds) return error.InvalidMessage,
            's' => if (!isValidString(try v.str())) return error.InvalidMessage,
            'o' => if (!names.isObjectPath(try v.str())) return error.InvalidMessage,
            'g' => sig.validate(try v.sigValue()) catch return error.InvalidMessage,
            'v' => {
                if (depth == sig.max_depth) return error.InvalidMessage;
                const inner = try v.sigValue();
                sig.validateSingle(inner) catch return error.InvalidMessage;
                _ = try v.value(inner, depth + 1);
            },
            'a' => {
                if (depth == sig.max_depth) return error.InvalidMessage;
                const len = try v.int(u32);
                if (len > max_array_len) return error.InvalidMessage;
                const elem = s[1..][0..sig.skipLen(s[1..])];
                try v.pad(sig.alignment(elem[0]));
                if (len > v.data.len - v.off) return error.InvalidMessage;
                const end = v.off + len;
                if (elem.len == 1 and sig.fixedSize(elem[0]) != null) {
                    const size = sig.fixedSize(elem[0]).?;
                    if (len % size != 0) return error.InvalidMessage;
                    if (elem[0] == 'b' or elem[0] == 'h') {
                        while (v.off < end) _ = try v.value(elem, depth + 1);
                    }
                    v.off = end;
                } else {
                    while (v.off < end) _ = try v.value(elem, depth + 1);
                    if (v.off != end) return error.InvalidMessage;
                }
                return 1 + elem.len;
            },
            '(', '{' => {
                if (depth == sig.max_depth) return error.InvalidMessage;
                try v.pad(8);
                var i: usize = 1;
                while (s[i] != ')' and s[i] != '}') i += try v.value(s[i..], depth + 1);
                return i + 1;
            },
            else => unreachable, // the signature was validated
        }
        return 1;
    }
};

/// Validates a whole body against its signature (already validated).
pub fn validateBody(body: []const u8, body_sig: []const u8, endian: Endian, n_fds: u32) DecodeError!void {
    var v: Validator = .{ .data = body, .endian = endian, .n_fds = n_fds };
    var i: usize = 0;
    while (i < body_sig.len) i += try v.value(body_sig[i..], 0);
    if (v.off != body.len) return error.InvalidMessage;
}

// Decoder -----------------------------------------------------------------

/// Reads a validated body. Strings and byte arrays are borrowed from the
/// message.
pub const Decoder = struct {
    data: []const u8,
    endian: Endian,
    off: usize = 0,
    fds: []const i32 = &.{},
    stack: [sig.max_depth + 1]Ctx = undefined,
    depth: u8 = 0,

    const Ctx = struct {
        sig: []const u8,
        pos: usize = 0,
        kind: enum { top, array, variant },
        /// End offset of an array's data.
        end: usize = 0,
    };

    pub fn init(data: []const u8, body_sig: []const u8, endian: Endian, fds: []const i32) Decoder {
        var d: Decoder = .{ .data = data, .endian = endian, .fds = fds };
        d.stack[0] = .{ .sig = body_sig, .kind = .top };
        return d;
    }

    fn cur(d: *Decoder) *Ctx {
        return &d.stack[d.depth];
    }

    /// The type code of the next value, or null at the end of the body,
    /// of an array element, or of a variant.
    pub fn peek(d: *Decoder) ?u8 {
        const c = d.cur();
        if (c.pos == c.sig.len) {
            if (c.kind == .array and d.off < c.end) return c.sig[0];
            return null;
        }
        return c.sig[c.pos];
    }

    /// The signature of the remaining top-level values or container
    /// contents at the cursor.
    pub fn remainingSignature(d: *Decoder) []const u8 {
        const c = d.cur();
        return c.sig[c.pos..];
    }

    fn consume(d: *Decoder, code: u8) DecodeError!void {
        const c = d.cur();
        if (c.pos == c.sig.len) {
            if (c.kind != .array or d.off >= c.end) return error.SignatureMismatch;
            c.pos = 0;
        }
        if (c.sig[c.pos] != code) return error.SignatureMismatch;
        c.pos += 1;
    }

    fn pad(d: *Decoder, a: usize) DecodeError!void {
        d.off = std.mem.alignForward(usize, d.off, a);
        if (d.off > d.data.len) return error.InvalidMessage;
    }

    fn take(d: *Decoder, n: usize) DecodeError![]const u8 {
        if (d.data.len - d.off < n) return error.InvalidMessage;
        defer d.off += n;
        return d.data[d.off..][0..n];
    }

    fn int(d: *Decoder, comptime T: type) DecodeError!T {
        try d.pad(@sizeOf(T));
        return std.mem.readInt(T, (try d.take(@sizeOf(T)))[0..@sizeOf(T)], d.endian);
    }

    fn str(d: *Decoder) DecodeError![]const u8 {
        const len = try d.int(u32);
        const b = try d.take(@as(usize, len) + 1);
        return b[0..len];
    }

    pub fn readByte(d: *Decoder) DecodeError!u8 {
        try d.consume('y');
        return (try d.take(1))[0];
    }

    pub fn readBool(d: *Decoder) DecodeError!bool {
        try d.consume('b');
        return try d.int(u32) != 0;
    }

    pub fn readInt16(d: *Decoder) DecodeError!i16 {
        try d.consume('n');
        return d.int(i16);
    }

    pub fn readUint16(d: *Decoder) DecodeError!u16 {
        try d.consume('q');
        return d.int(u16);
    }

    pub fn readInt32(d: *Decoder) DecodeError!i32 {
        try d.consume('i');
        return d.int(i32);
    }

    pub fn readUint32(d: *Decoder) DecodeError!u32 {
        try d.consume('u');
        return d.int(u32);
    }

    pub fn readInt64(d: *Decoder) DecodeError!i64 {
        try d.consume('x');
        return d.int(i64);
    }

    pub fn readUint64(d: *Decoder) DecodeError!u64 {
        try d.consume('t');
        return d.int(u64);
    }

    pub fn readDouble(d: *Decoder) DecodeError!f64 {
        try d.consume('d');
        return @bitCast(try d.int(u64));
    }

    pub fn readString(d: *Decoder) DecodeError![]const u8 {
        try d.consume('s');
        return d.str();
    }

    pub fn readObjectPath(d: *Decoder) DecodeError![]const u8 {
        try d.consume('o');
        return d.str();
    }

    pub fn readSignature(d: *Decoder) DecodeError![]const u8 {
        try d.consume('g');
        const len = (try d.take(1))[0];
        return (try d.take(@as(usize, len) + 1))[0..len];
    }

    /// The fd stays owned by the message.
    pub fn readFd(d: *Decoder) DecodeError!i32 {
        try d.consume('h');
        const i = try d.int(u32);
        if (i >= d.fds.len) return error.InvalidMessage;
        return d.fds[i];
    }

    /// An open array; iterate with `next`.
    pub const Array = struct {
        end: usize,
        depth: u8,
        elem: []const u8,

        /// Whether another element follows. The previous element must have
        /// been read completely.
        pub fn next(a: *const Array, d: *const Decoder) bool {
            return d.off < a.end;
        }
    };

    pub fn beginArray(d: *Decoder) DecodeError!Array {
        try d.consume('a');
        const c = d.cur();
        const elem = c.sig[c.pos..][0..sig.skipLen(c.sig[c.pos..])];
        c.pos += elem.len;
        const len = try d.int(u32);
        try d.pad(sig.alignment(elem[0]));
        if (len > d.data.len - d.off) return error.InvalidMessage;
        d.depth += 1;
        d.stack[d.depth] = .{ .sig = elem, .pos = elem.len, .kind = .array, .end = d.off + len };
        return .{ .end = d.off + len, .depth = d.depth, .elem = elem };
    }

    /// Closes the array, skipping elements not read.
    pub fn endArray(d: *Decoder, a: Array) DecodeError!void {
        if (d.depth != a.depth) return error.SignatureMismatch;
        d.off = a.end;
        d.depth -= 1;
    }

    /// The bytes of an array of fixed-size elements, without copying. They
    /// are in the message's byte order.
    pub fn readFixedArray(d: *Decoder) DecodeError![]const u8 {
        const a = try d.beginArray();
        if (a.elem.len != 1 or sig.fixedSize(a.elem[0]) == null) return error.SignatureMismatch;
        const b = d.data[d.off..a.end];
        try d.endArray(a);
        return b;
    }

    pub fn beginStruct(d: *Decoder) DecodeError!void {
        try d.consume('(');
        try d.pad(8);
    }

    pub fn endStruct(d: *Decoder) DecodeError!void {
        try d.consume(')');
    }

    pub fn beginDictEntry(d: *Decoder) DecodeError!void {
        try d.consume('{');
        try d.pad(8);
    }

    pub fn endDictEntry(d: *Decoder) DecodeError!void {
        try d.consume('}');
    }

    /// Opens a variant and returns the signature of its value.
    pub fn beginVariant(d: *Decoder) DecodeError![]const u8 {
        try d.consume('v');
        const len = (try d.take(1))[0];
        const s = (try d.take(@as(usize, len) + 1))[0..len];
        d.depth += 1;
        d.stack[d.depth] = .{ .sig = s, .kind = .variant };
        return s;
    }

    /// Closes the variant, skipping its value if it was not read.
    pub fn endVariant(d: *Decoder) DecodeError!void {
        const c = d.cur();
        if (c.kind != .variant) return error.SignatureMismatch;
        if (c.pos == 0) try d.skip();
        if (c.pos != c.sig.len) return error.SignatureMismatch;
        d.depth -= 1;
    }

    /// Skips the next complete value.
    pub fn skip(d: *Decoder) DecodeError!void {
        const c = d.cur();
        if (c.pos == c.sig.len) {
            if (c.kind != .array or d.off >= c.end) return error.SignatureMismatch;
            c.pos = 0;
        }
        var v: Validator = .{ .data = d.data, .off = d.off, .endian = d.endian, .n_fds = std.math.maxInt(u32) };
        c.pos += try v.value(c.sig[c.pos..], 0);
        d.off = v.off;
    }

    /// Reads one value of a type listed in the module documentation.
    /// Slices other than `Bytes` and strings are not supported: iterate
    /// arrays with `beginArray`.
    pub fn read(d: *Decoder, comptime T: type) DecodeError!T {
        switch (T) {
            u8 => return d.readByte(),
            bool => return d.readBool(),
            i16 => return d.readInt16(),
            u16 => return d.readUint16(),
            i32 => return d.readInt32(),
            u32 => return d.readUint32(),
            i64 => return d.readInt64(),
            u64 => return d.readUint64(),
            f64 => return d.readDouble(),
            []const u8 => return d.readString(),
            ObjectPath => return .{ .path = try d.readObjectPath() },
            Signature => return .{ .sig = try d.readSignature() },
            Fd => return .{ .fd = try d.readFd() },
            Bytes => {
                const a = try d.beginArray();
                if (!std.mem.eql(u8, a.elem, "y")) return error.SignatureMismatch;
                const b = d.data[d.off..a.end];
                try d.endArray(a);
                return .{ .bytes = b };
            },
            else => {},
        }
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                if (@hasDecl(T, "dbus_variant")) {
                    const vs = try d.beginVariant();
                    if (!std.mem.eql(u8, vs, comptime signatureOf(T.dbus_variant))) return error.SignatureMismatch;
                    const out: T = .{ .value = try d.read(T.dbus_variant) };
                    try d.endVariant();
                    return out;
                }
                if (@hasDecl(T, "dbus_dict_entry")) {
                    try d.beginDictEntry();
                    const out: T = .{ .key = try d.read(@FieldType(T, "key")), .value = try d.read(@FieldType(T, "value")) };
                    try d.endDictEntry();
                    return out;
                }
                var out: T = undefined;
                try d.beginStruct();
                inline for (s.field_names, s.field_types) |name, ft| @field(out, name) = try d.read(ft);
                try d.endStruct();
                return out;
            },
            else => @compileError("cannot read " ++ @typeName(T) ++ " directly"),
        }
    }

    /// Reads the remaining top-level values into a tuple of types `T`.
    pub fn readAll(d: *Decoder, comptime T: type) DecodeError!T {
        var out: T = undefined;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, ft| @field(out, name) = try d.read(ft);
        return out;
    }
};

// Tests -------------------------------------------------------------------

const testing = std.testing;

fn expectValid(e: *const Encoder) !void {
    try sig.validate(e.signature());
    try validateBody(e.bytes(), e.signature(), .little, @intCast(e.fds.items.len));
}

test "typed values round-trip through the wire layout" {
    var e: Encoder = .init(testing.allocator);
    defer e.deinit();
    const Entry = DictEntry([]const u8, Variant(u32));
    const entries = [_]Entry{ .{ .key = "a", .value = variant(@as(u32, 7)) }, .{ .key = "bc", .value = variant(@as(u32, 9)) } };
    try e.writeAll(.{
        @as(u8, 0xfe),
        true,
        @as(i16, -2),
        @as(u64, 1 << 40),
        "héllo",
        ObjectPath{ .path = "/org/x" },
        Signature{ .sig = "a{sv}" },
        @as([]const Entry, &entries),
        .{ @as(i32, -5), @as(f64, 2.5) },
        @as([]const u32, &.{ 1, 2, 3 }),
        Bytes{ .bytes = "raw" },
    });
    try testing.expectEqualStrings("ybntsoga{sv}(id)auay", e.signature());
    try testing.expect(e.complete());
    try expectValid(&e);

    var d: Decoder = .init(e.bytes(), e.signature(), .little, &.{});
    try testing.expectEqual(@as(u8, 0xfe), try d.read(u8));
    try testing.expect(try d.read(bool));
    try testing.expectEqual(@as(i16, -2), try d.read(i16));
    try testing.expectEqual(@as(u64, 1 << 40), try d.read(u64));
    try testing.expectEqualStrings("héllo", try d.read([]const u8));
    try testing.expectEqualStrings("/org/x", (try d.read(ObjectPath)).path);
    try testing.expectEqualStrings("a{sv}", (try d.read(Signature)).sig);
    const a = try d.beginArray();
    var keys: [2][]const u8 = undefined;
    var n: usize = 0;
    while (a.next(&d)) : (n += 1) {
        const entry = try d.read(Entry);
        keys[n] = entry.key;
        try testing.expectEqual(@as(u32, if (n == 0) 7 else 9), entry.value.value);
    }
    try d.endArray(a);
    try testing.expectEqualStrings("bc", keys[1]);
    const s = try d.read(struct { i32, f64 });
    try testing.expectEqual(@as(i32, -5), s[0]);
    try testing.expectEqual(2.5, s[1]);
    const u = try d.readFixedArray();
    try testing.expectEqual(@as(usize, 12), u.len);
    try testing.expectEqualStrings("raw", (try d.read(Bytes)).bytes);
    try testing.expect(d.peek() == null);
}

test "exact wire bytes match the specification" {
    var e: Encoder = .init(testing.allocator);
    defer e.deinit();
    // A byte, then a u32 aligned to 4, then a string and an empty array of
    // u64, whose padding to 8 is present even though it is empty.
    try e.writeAll(.{ @as(u8, 1), @as(u32, 0x01020304), "ab", @as([]const u64, &.{}) });
    try testing.expectEqualSlices(u8, &.{
        1, 0, 0, 0, 4, 3, 2, 1, // y, pad, u
        2, 0, 0, 0, 'a', 'b', 0, // s
        0, // pad to 4
        0, 0, 0, 0, // array length
        0, 0, 0, 0, // pad to 8 for the elements
    }, e.bytes());
    try testing.expectEqualStrings("yusat", e.signature());
}

test "the encoder rejects writes that do not match declared types" {
    var e: Encoder = .init(testing.allocator);
    defer e.deinit();
    try e.beginArray("(su)");
    try e.beginStruct();
    try e.writeString("x");
    try testing.expectError(error.SignatureMismatch, e.writeInt32(1));
    try testing.expectError(error.SignatureMismatch, e.endStruct()); // incomplete

    var f: Encoder = .init(testing.allocator);
    defer f.deinit();
    try testing.expectError(error.SignatureMismatch, f.beginDictEntry()); // not in an array
    try testing.expectError(error.InvalidSignature, f.beginArray("{vs}"));
    try testing.expectError(error.InvalidValue, f.writeString("a\x00b"));
    try testing.expectError(error.InvalidValue, f.writeString("\xff"));
    try testing.expectError(error.InvalidValue, f.writeObjectPath("/a/"));
    try f.beginVariant("u");
    try testing.expectError(error.SignatureMismatch, f.endVariant()); // empty
    try f.writeUint32(1);
    try testing.expectError(error.SignatureMismatch, f.writeUint32(2)); // one value only
    try f.endVariant();
    try f.beginStruct();
    try testing.expectError(error.SignatureMismatch, f.endStruct()); // empty struct
}

test "nested arrays inside variants check against the variant's type" {
    var e: Encoder = .init(testing.allocator);
    defer e.deinit();
    try e.beginVariant("a(sai)");
    try e.beginArray("(sai)");
    for (0..3) |i| {
        try e.beginStruct();
        try e.writeString("k");
        try e.beginArray("i");
        for (0..i) |j| try e.writeInt32(@intCast(j));
        try e.endArray();
        try e.endStruct();
    }
    try e.endArray();
    try e.endVariant();
    try testing.expectEqualStrings("v", e.signature());
    try expectValid(&e);

    var d: Decoder = .init(e.bytes(), e.signature(), .little, &.{});
    try testing.expectEqualStrings("a(sai)", try d.beginVariant());
    const outer = try d.beginArray();
    var total: i32 = 0;
    var count: usize = 0;
    while (outer.next(&d)) : (count += 1) {
        try d.beginStruct();
        try testing.expectEqualStrings("k", try d.readString());
        const inner = try d.beginArray();
        while (inner.next(&d)) total += try d.readInt32();
        try d.endArray(inner);
        try d.endStruct();
    }
    try d.endArray(outer);
    try d.endVariant();
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(i32, 1), total);
}

test "the decoder rejects reads that do not match and skips values" {
    var e: Encoder = .init(testing.allocator);
    defer e.deinit();
    try e.writeAll(.{ variant(@as([]const []const u8, &.{ "a", "b" })), @as(u32, 5), "end" });
    var d: Decoder = .init(e.bytes(), e.signature(), .little, &.{});
    try testing.expectError(error.SignatureMismatch, d.readUint32());
    try d.skip();
    try testing.expectEqual(@as(u32, 5), try d.readUint32());
    try testing.expectEqualStrings("end", try d.readString());
    try testing.expectError(error.SignatureMismatch, d.readString());
}

test "the validator rejects malformed bodies" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "b", &.{ 2, 0, 0, 0 } }, // boolean other than 0 or 1
        .{ "yu", &.{ 1, 9, 0, 0, 1, 0, 0, 0 } }, // nonzero padding
        .{ "s", &.{ 1, 0, 0, 0, 'a', 'x' } }, // missing NUL
        .{ "s", &.{ 1, 0, 0, 0, 0, 0 } }, // embedded NUL
        .{ "s", &.{ 1, 0, 0, 0, 0xff, 0 } }, // invalid UTF-8
        .{ "o", &.{ 2, 0, 0, 0, '/', '/', 0 } }, // invalid path
        .{ "g", &.{ 1, '(', 0 } }, // invalid signature
        .{ "v", &.{ 2, 'u', 'u', 0 } }, // variant with two types
        .{ "au", &.{ 3, 0, 0, 0, 1, 2, 3 } }, // length not a multiple
        .{ "as", &.{ 7, 0, 0, 0, 1, 0, 0, 0, 'a', 0 } }, // length past the end
        .{ "ah", &.{ 4, 0, 0, 0, 0, 0, 0, 0 } }, // fd index without fds
        .{ "u", &.{ 1, 0, 0, 0, 0 } }, // trailing bytes
        .{ "u", &.{ 1, 0, 0 } }, // truncated
        .{ "a(u)", &.{ 6, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0 } }, // element straddles the end
    };
    for (cases) |c| {
        errdefer std.debug.print("case {s} {any}\n", .{ c[0], c[1] });
        try testing.expectError(error.InvalidMessage, validateBody(c[1], c[0], .little, 0));
    }
    try validateBody(&.{ 4, 0, 0, 0, 0, 0, 0, 0 }, "ah", .little, 1);
    try validateBody(&.{ 0, 0, 0, 1 }, "u", .big, 0);
}

test "variant nesting is limited to 64 containers" {
    var buf: [200]u8 = undefined;
    for (0..64) |i| buf[i * 3 ..][0..3].* = .{ 1, 'v', 0 };
    buf[192..][0..4].* = .{ 1, 'y', 0, 7 };
    // 64 variants plus the byte inside would need depth 65.
    try testing.expectError(error.InvalidMessage, validateBody(buf[0..196], "v", .little, 0));
    try validateBody(buf[3..196], "v", .little, 0);
}

test "fuzz body validation" {
    try std.testing.fuzz({}, fuzzBody, .{ .corpus = &.{
        "a{sv}\x00\x10\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00k\x00\x01u\x00\x00\x07\x00\x00\x00",
        "(yv)\x00\x01\x01y\x00\x05",
    } });
}

/// Input: a signature, NUL, then body bytes. A body that validates must
/// decode completely with `skip`.
fn fuzzBody(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const in = buf[0..smith.slice(&buf)];
    const nul = std.mem.indexOfScalar(u8, in, 0) orelse return;
    const s = in[0..nul];
    sig.validate(s) catch return;
    const body = in[nul + 1 ..];
    for ([_]Endian{ .little, .big }) |endian| {
        validateBody(body, s, endian, 2) catch continue;
        var d: Decoder = .init(body, s, endian, &.{ -1, -1 });
        while (d.peek() != null) try d.skip();
        try testing.expectEqual(body.len, d.off);
    }
}
