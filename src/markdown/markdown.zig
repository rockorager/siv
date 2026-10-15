//! Markdown (CommonMark and GFM) into the document tree (D32).
//!
//! Imports: html.

const std = @import("std");
const html = @import("html");

pub const Options = struct {};

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, options: Options) error{OutOfMemory}!html.Dom {
    _ = options;
    var dom = try html.parse(gpa, "", .{});
    const body = dom.body();
    var it = std.mem.splitSequence(u8, bytes, "\n\n");
    while (it.next()) |para| {
        const p = try dom.createElement(.html, .p, &.{});
        dom.append(body, p);
        dom.append(p, try dom.createText(para));
    }
    return dom;
}
