//! D-Bus on the siv event loop (D19): the wire format, SASL EXTERNAL
//! authentication, unix fd passing, method calls, signals and match rules,
//! exported objects with introspection, and bus name ownership; and the
//! portal Settings client built on it.
//!
//! Imports: `loop`.

const std = @import("std");

pub const names = @import("names.zig");
pub const signature = @import("signature.zig");
pub const codec = @import("codec.zig");
pub const message = @import("message.zig");
pub const auth = @import("auth.zig");
pub const address = @import("address.zig");
pub const match = @import("match.zig");
pub const object = @import("object.zig");
pub const Connection = @import("Connection.zig");

pub const Interface = object.Interface;
pub const Method = object.Method;
pub const Property = object.Property;
pub const Object = object.Object;
pub const Node = object.Node;
pub const Request = Connection.Request;

pub const Encoder = codec.Encoder;
pub const Decoder = codec.Decoder;
pub const ObjectPath = codec.ObjectPath;
pub const Signature = codec.Signature;
pub const Fd = codec.Fd;
pub const Bytes = codec.Bytes;
pub const Variant = codec.Variant;
pub const variant = codec.variant;
pub const DictEntry = codec.DictEntry;
pub const signatureOf = codec.signatureOf;

pub const Message = message.Message;
pub const Builder = message.Builder;
pub const Header = message.Header;
pub const Type = message.Type;
pub const Flags = message.Flags;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
