//! Internationalization data (D21, D41): dates and times as each locale
//! writes them, from CLDR, and the emoji catalogue of UTS #51. Both are
//! tables generated at build time (gen.zig, build_steps.zig) from pinned
//! data, as the text engine's Unicode properties are.
//!
//! Imports: none (the generated tables only).

const std = @import("std");

pub const cldr = @import("cldr.zig");
pub const emoji = @import("emoji.zig");

test {
    std.testing.refAllDecls(@This());
}
