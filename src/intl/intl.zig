//! Internationalization (D21, D41): dates, times, and numbers as each
//! locale writes them and the plural rules of each language, from CLDR;
//! and the emoji catalogue of UTS #51. The CLDR data and the emoji are
//! tables generated at build time (gen.zig, build_steps.zig) from pinned
//! data, as the text engine's Unicode properties are.
//!
//! Imports: none (the generated tables only).

const std = @import("std");

pub const cldr = @import("cldr.zig");
pub const number = @import("number.zig");
pub const plural = @import("plural.zig");
pub const emoji = @import("emoji.zig");

test {
    std.testing.refAllDecls(@This());
}
