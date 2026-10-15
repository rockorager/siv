//! The email corpus (D32, test/doc/email/README): receipts, newsletters,
//! and replies as common senders and clients write them, rendered as
//! untrusted HTML with quoted replies collapsed, remote content blocked,
//! and cid: parts from the loader, against test/golden/doc/email-*.png.
//!
//! To accept new output: SIV_UPDATE_GOLDEN=1 zig build test-headless

const std = @import("std");
const corpus = @import("corpus.zig");
const Runner = @import("render.zig").Runner;

const testing = std.testing;

fn check(comptime name: []const u8, height: u32, open: bool) !void {
    const r = try Runner.init(testing.allocator, testing.io, "test/doc/email", "https://mail.example", 600, height);
    defer r.deinit();
    r.untrusted = true;
    r.remote = false;
    r.collapse_quotes = true;
    r.open_quotes = open;
    try r.render(name ++ ".html", .html, 0, r.pixels[0]);
    try corpus.expectGolden(r, if (open) "email-" ++ name ++ "-open" else "email-" ++ name, r.pixels[0]);
}

test "email: a store's receipt with a cid: logo and a blocked tracking pixel" {
    try check("receipt", 560, false);
}

test "email: a Mailchimp-style newsletter" {
    try check("newsletter", 640, false);
}

test "email: replies from Gmail, Outlook, and Apple Mail, quotes collapsed and open" {
    try check("reply-gmail", 260, false);
    try check("reply-gmail", 360, true);
    try check("reply-outlook", 300, false);
    try check("reply-outlook", 420, true);
    try check("reply-apple", 200, false);
}
