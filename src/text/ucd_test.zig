//! Parser for the Unicode segmentation conformance files (GraphemeBreakTest,
//! WordBreakTest, LineBreakTest). Test-only.

const std = @import("std");

pub const Case = struct {
    line_number: usize,
    utf8: []const u8,
    /// Byte offsets marked `÷`, including 0 when the line starts with `÷`.
    breaks: []const usize,
};

pub const Cases = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    line_number: usize = 0,
    utf8: std.ArrayList(u8) = .empty,
    breaks: std.ArrayList(usize) = .empty,

    pub fn init(data: []const u8) Cases {
        return .{ .lines = std.mem.splitScalar(u8, data, '\n') };
    }

    pub fn deinit(self: *Cases, gpa: std.mem.Allocator) void {
        self.utf8.deinit(gpa);
        self.breaks.deinit(gpa);
    }

    pub fn next(self: *Cases, gpa: std.mem.Allocator) !?Case {
        while (self.lines.next()) |raw| {
            self.line_number += 1;
            const body = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
            if (body.len == 0) continue;
            self.utf8.clearRetainingCapacity();
            self.breaks.clearRetainingCapacity();
            var tokens = std.mem.tokenizeAny(u8, body, " \t");
            const encodable = while (tokens.next()) |token| {
                if (std.mem.eql(u8, token, "÷")) {
                    try self.breaks.append(gpa, self.utf8.items.len);
                } else if (!std.mem.eql(u8, token, "×")) {
                    const cp = try std.fmt.parseInt(u21, token, 16);
                    var encoded: [4]u8 = undefined;
                    // Surrogate code points cannot occur in UTF-8 text.
                    const len = std.unicode.utf8Encode(cp, &encoded) catch break false;
                    try self.utf8.appendSlice(gpa, encoded[0..len]);
                }
            } else true;
            if (!encodable) continue;
            return .{ .line_number = self.line_number, .utf8 = self.utf8.items, .breaks = self.breaks.items };
        }
        return null;
    }
};
