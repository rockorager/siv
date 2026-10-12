//! The API schema (D3): every type and function of the C ABI. Generators
//! (gen.zig) turn it into siv.h and, later, the Zig wrapper, the Lua binding,
//! reference documentation, and a JSON description. Plain data only, so the
//! generator can import it on the build host.
//!
//! This is a placeholder shape with one function; the ABI workstream owns
//! its design.

pub const Type = enum {
    void,
    u32,

    pub fn c(t: Type) []const u8 {
        return switch (t) {
            .void => "void",
            .u32 => "uint32_t",
        };
    }
};

pub const Param = struct {
    name: []const u8,
    type: Type,
};

pub const Function = struct {
    name: []const u8,
    doc: []const u8,
    params: []const Param = &.{},
    ret: Type,
};

pub const functions = [_]Function{
    .{
        .name = "siv_version",
        .doc = "Returns the version of the loaded library, encoded as SIV_MAKE_VERSION(major, minor, patch).",
        .ret = .u32,
    },
};

/// Encodes a version as (major << 16) | (minor << 8) | patch.
pub fn makeVersion(major: usize, minor: usize, patch: usize) u32 {
    return @intCast(major << 16 | minor << 8 | patch);
}
