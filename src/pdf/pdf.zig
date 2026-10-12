//! PDF output (D9, D19): display lists lowered to PDF pages, for export
//! and for printing through the Print portal. One page per display list,
//! in points with y down from the top-left corner.
//!
//!     var w = try pdf.Writer.init(gpa, .{ .title = "Report" });
//!     defer w.deinit();
//!     try w.addPage(595.28, 841.89, list);
//!     try w.finish(&file_writer.interface);
//!
//! Imports: scene, raster, render_cpu (the shadow contract), text (tests),
//! harfbuzz_subset (font subsets).

const std = @import("std");

pub const Writer = @import("Writer.zig");
pub const content = @import("content.zig");

/// Test helpers for other modules' tests. Not for production use.
pub const testing = struct {
    /// Reads back a written PDF's objects and streams.
    pub const Parsed = @import("test_parse.zig").Parsed;
    pub const dictInt = @import("test_parse.zig").dictInt;
    pub const ref = @import("test_parse.zig").ref;
};

/// A4 in points.
pub const a4: struct { width: f32, height: f32 } = .{ .width = 595.2756, .height = 841.8898 };

test {
    std.testing.refAllDecls(@This());
    _ = @import("shading.zig");
    _ = @import("image.zig");
    _ = @import("font.zig");
    if (comptime @import("integration").enabled) {
        _ = @import("integration_tests.zig");
    } else {
        _ = @import("tests.zig");
    }
}
