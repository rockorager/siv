//! CSS for documents (D32): Syntax 3 tokenizing and rule parsing,
//! Selectors 4, the property values documents use (Values 4 with calc(),
//! Color 4 and 5, Fonts 4, Text 3 and 4, Backgrounds and Borders, Flexbox,
//! Grid, Lists, Positioning), media queries, custom properties, and
//! computed styles shared between elements. Matching and the cascade over
//! a document live in the document module, which knows the tree.
//!
//! Imports: none.

const std = @import("std");

pub const tokenizer = @import("tokenizer.zig");
pub const color = @import("color.zig");
pub const values = @import("values.zig");
pub const media = @import("media.zig");
pub const selector = @import("selector.zig");
pub const style = @import("style.zig");
pub const properties = @import("properties.zig");
pub const sheet = @import("sheet.zig");

pub const Sheet = sheet.Sheet;
pub const Style = style.Style;
pub const Color = color.Color;
pub const Len = style.Len;

test {
    std.testing.refAllDecls(@This());
}

test "fuzz the stylesheet parser" {
    try std.testing.fuzz({}, fuzzSheet, .{ .corpus = &.{
        "a.b > #c:nth-child(2n+1 of .x)::before { color: oklch(70% .1 200 / .5); margin: calc(1em - 2px) auto; }",
        "@media (400px < width < 800px) and (prefers-color-scheme: dark) { :root { --x: { a } ; } p { font: 12px/1.5 var(--f, serif) !important } }",
        "@supports selector(:has(> img)) { .g { grid-template: \"a b\" 1fr / repeat(auto-fill, minmax(10px, 1fr)) } }",
        "@font-face { font-family: X; src: url(x.woff2) format('woff2'); unicode-range: U+0-7F, U+4?? } @import 'a.css' layer(x) print;",
    } });
}

fn fuzzSheet(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    var s = try sheet.parse(std.testing.allocator, src, .{});
    defer s.deinit();
    for (s.rules) |r| {
        try std.testing.expect(r.selectors[0] + r.selectors[1] <= s.store.selectors.items.len);
        try std.testing.expect(r.decls[0] + r.decls[1] <= s.decls.len);
    }
}
