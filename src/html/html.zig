//! HTML parsing for documents (D32): the WHATWG tokenizer and tree
//! construction with their error recovery, into a compact tree (`Dom`)
//! with interned names. No scripting, no networking: `<script>` content
//! is parsed and never run.
//!
//! Imports: none.

const std = @import("std");

pub const Dom = @import("Dom.zig");
pub const atoms = @import("atoms.zig");
pub const Atom = atoms.Atom;
pub const NodeId = Dom.NodeId;
pub const tokenizer = @import("tokenizer.zig");
pub const encoding = @import("encoding.zig");
pub const serialize = @import("serialize.zig");
const tree = @import("tree.zig");

pub const Options = struct {
    /// A charset label from outside the document (an email part's
    /// Content-Type), which wins over `<meta charset>`.
    charset: []const u8 = "",
    /// Fragment parsing (innerHTML) in this context element; null parses
    /// a whole document.
    context: ?Context = null,

    pub const Context = struct { name: []const u8, ns: Dom.Namespace = .html };
};

const Sink = struct {
    b: *Builder,

    pub fn token(s: Sink, t: tokenizer.Token) error{OutOfMemory}!void {
        return s.b.token(t);
    }

    pub fn cdataAllowed(s: Sink) bool {
        return s.b.cdataAllowed();
    }
};

const Tokenizer = tokenizer.Tokenizer(Sink);
const Builder = tree.Builder(Tokenizer);

/// Parses a document (or a fragment) from bytes in any encoding siv
/// decodes.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, options: Options) error{OutOfMemory}!Dom {
    const enc = encoding.sniff(bytes, options.charset);
    const utf8 = try encoding.decode(gpa, bytes, enc);
    const owned = utf8.ptr != bytes.ptr and !(bytes.len >= 3 and utf8.ptr == bytes.ptr + 3);
    defer if (owned) gpa.free(utf8);
    const input = try tokenizer.preprocess(gpa, utf8);
    defer if (input.ptr != utf8.ptr) gpa.free(input);

    var dom = try Dom.init(gpa);
    errdefer dom.deinit();
    // About a node per 24 bytes in typical markup.
    try dom.nodes.ensureTotalCapacity(gpa, input.len / 24 + 8);
    try dom.bytes.ensureTotalCapacity(gpa, input.len / 2 + 64);

    var b: Builder = .{ .dom = &dom, .gpa = gpa };
    defer b.deinit();
    var t = Tokenizer.init(gpa, input, .{ .b = &b });
    defer t.deinit();
    b.tokenizer = &t;
    if (options.context) |ctx| {
        // 13.4: a root html element, the context element outside the tree.
        const name = try dom.atom(ctx.name);
        b.context = try dom.createElement(ctx.ns, name, &.{});
        const root = try dom.createElement(.html, .html, &.{});
        dom.append(.document, root);
        try b.open.append(gpa, root);
        if (ctx.ns == .html) {
            t.state = switch (name) {
                .title, .textarea => .rcdata,
                .style, .xmp, .iframe, .noembed, .noframes => .rawtext,
                .script => .script_data,
                .plaintext => .plaintext,
                else => .data,
            };
            if (name == .template) try b.template_modes.append(gpa, .in_template);
        }
        b.resetMode();
    }
    try t.run();
    return dom;
}

test {
    std.testing.refAllDecls(@This());
    _ = Dom;
    _ = encoding;
    _ = @import("tests.zig");
}
