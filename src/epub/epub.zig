//! EPUB 2 and 3 publications (D32): the zip container, META-INF's
//! container.xml, the OPF package (metadata, manifest, spine), and the
//! table of contents from the EPUB 3 navigation document or the EPUB 2
//! NCX. Chapters are XHTML that the document renderer shows; this module
//! only finds and reads the files.
//!
//! Imports: none.

const std = @import("std");
pub const zip = @import("zip.zig");
pub const xml = @import("xml.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, InvalidZip, Unsupported, TooLarge, NotEpub };

pub const Item = struct {
    id: []const u8,
    /// The file's path in the container.
    path: []const u8,
    media_type: []const u8,
    properties: []const u8,
};

pub const Spine = struct { item: u32, linear: bool };

pub const TocEntry = struct {
    label: []const u8,
    /// Path in the container, and the fragment after '#' (or empty).
    path: []const u8,
    fragment: []const u8,
    /// 1 for the top level.
    depth: u8,
};

pub const Book = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    bytes: []u8,
    archive: zip.Archive,
    title: []const u8 = "",
    author: []const u8 = "",
    language: []const u8 = "",
    identifier: []const u8 = "",
    /// The package document's path.
    opf: []const u8 = "",
    manifest: []Item = &.{},
    spine: []Spine = &.{},
    toc: []TocEntry = &.{},

    /// Opens a publication from its bytes (copied).
    pub fn open(gpa: Allocator, bytes: []const u8) Error!*Book {
        const b = try gpa.create(Book);
        errdefer gpa.destroy(b);
        const copy = try gpa.dupe(u8, bytes);
        errdefer gpa.free(copy);
        var archive = try zip.open(gpa, copy);
        errdefer archive.deinit(gpa);
        b.* = .{ .gpa = gpa, .arena = .init(gpa), .bytes = copy, .archive = archive };
        errdefer b.arena.deinit();
        try b.parse();
        return b;
    }

    pub fn destroy(b: *Book) void {
        const gpa = b.gpa;
        b.archive.deinit(gpa);
        b.arena.deinit();
        gpa.free(b.bytes);
        gpa.destroy(b);
    }

    /// A file of the container, allocated with `gpa`; null when missing
    /// or unreadable.
    pub fn read(b: *const Book, gpa: Allocator, path: []const u8) Error!?[]u8 {
        const e = b.archive.find(path) orelse return null;
        return b.archive.read(gpa, e) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    }

    pub fn item(b: *const Book, path: []const u8) ?*const Item {
        for (b.manifest) |*it| if (std.mem.eql(u8, it.path, path)) return it;
        return null;
    }

    /// The spine index of a chapter's path, or null.
    pub fn spineIndex(b: *const Book, path: []const u8) ?usize {
        for (b.spine, 0..) |s, i| if (std.mem.eql(u8, b.manifest[s.item].path, path)) return i;
        return null;
    }

    fn parse(b: *Book) Error!void {
        const a = b.arena.allocator();
        const gpa = b.gpa;
        const container = (try b.read(gpa, "META-INF/container.xml")) orelse return error.NotEpub;
        defer gpa.free(container);
        {
            var t: xml.Tokenizer = .init(gpa, container);
            defer t.deinit();
            while (try t.next()) |tok| switch (tok) {
                .start => |s| if (std.mem.eql(u8, xml.local(s.name), "rootfile")) {
                    if (xml.attr(s.attrs, "full-path")) |p| {
                        b.opf = try a.dupe(u8, p);
                        break;
                    }
                },
                else => {},
            };
        }
        if (b.opf.len == 0) return error.NotEpub;
        const opf = (try b.read(gpa, b.opf)) orelse return error.NotEpub;
        defer gpa.free(opf);
        var manifest: std.ArrayList(Item) = .empty;
        var spine_ids: std.ArrayList(struct { id: []const u8, linear: bool }) = .empty;
        defer spine_ids.deinit(gpa);
        var ncx_id: []const u8 = "";
        {
            var t: xml.Tokenizer = .init(gpa, opf);
            defer t.deinit();
            var field: enum { none, title, creator, language, identifier } = .none;
            while (try t.next()) |tok| switch (tok) {
                .start => |s| {
                    const n = xml.local(s.name);
                    field = .none;
                    if (std.mem.eql(u8, n, "item")) {
                        const href = xml.attr(s.attrs, "href") orelse continue;
                        try manifest.append(a, .{
                            .id = try a.dupe(u8, xml.attr(s.attrs, "id") orelse ""),
                            .path = try resolve(a, b.opf, href),
                            .media_type = try a.dupe(u8, xml.attr(s.attrs, "media-type") orelse ""),
                            .properties = try a.dupe(u8, xml.attr(s.attrs, "properties") orelse ""),
                        });
                    } else if (std.mem.eql(u8, n, "itemref")) {
                        const id = xml.attr(s.attrs, "idref") orelse continue;
                        const linear = xml.attr(s.attrs, "linear") orelse "yes";
                        try spine_ids.append(gpa, .{ .id = try a.dupe(u8, id), .linear = !std.mem.eql(u8, linear, "no") });
                    } else if (std.mem.eql(u8, n, "spine")) {
                        if (xml.attr(s.attrs, "toc")) |id| ncx_id = try a.dupe(u8, id);
                    } else if (!s.empty and std.mem.eql(u8, n, "title") and b.title.len == 0) {
                        field = .title;
                    } else if (!s.empty and std.mem.eql(u8, n, "creator") and b.author.len == 0) {
                        field = .creator;
                    } else if (!s.empty and std.mem.eql(u8, n, "language") and b.language.len == 0) {
                        field = .language;
                    } else if (!s.empty and std.mem.eql(u8, n, "identifier") and b.identifier.len == 0) {
                        field = .identifier;
                    }
                },
                .text => |txt| {
                    const v = try a.dupe(u8, std.mem.trim(u8, txt, " \t\r\n"));
                    switch (field) {
                        .none => {},
                        .title => b.title = v,
                        .creator => b.author = v,
                        .language => b.language = v,
                        .identifier => b.identifier = v,
                    }
                    field = .none;
                },
                .end => field = .none,
            };
        }
        b.manifest = manifest.items;
        var spine: std.ArrayList(Spine) = .empty;
        for (spine_ids.items) |s| for (b.manifest, 0..) |it, i| if (std.mem.eql(u8, it.id, s.id)) {
            try spine.append(a, .{ .item = @intCast(i), .linear = s.linear });
            break;
        };
        b.spine = spine.items;
        // The table of contents: EPUB 3's nav document, else the NCX.
        for (b.manifest) |it| if (hasWord(it.properties, "nav")) {
            if (try b.read(gpa, it.path)) |nav| {
                defer gpa.free(nav);
                b.toc = try parseNav(a, gpa, nav, it.path);
            }
            break;
        };
        if (b.toc.len == 0) for (b.manifest) |it| {
            if (!(std.mem.eql(u8, it.id, ncx_id) or std.mem.eql(u8, it.media_type, "application/x-dtbncx+xml"))) continue;
            if (try b.read(gpa, it.path)) |ncx| {
                defer gpa.free(ncx);
                b.toc = try parseNcx(a, gpa, ncx, it.path);
            }
            break;
        };
    }
};

fn hasWord(list: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// A reference from file `from` (a container path) resolved to a
/// container path: relative to `from`'s directory, percent-decoded, with
/// `.` and `..` removed. The fragment, if any, is dropped.
pub fn resolve(a: Allocator, from: []const u8, ref: []const u8) error{OutOfMemory}![]const u8 {
    var r = ref;
    if (std.mem.indexOfAny(u8, r, "#?")) |k| r = r[0..k];
    var parts: std.ArrayList([]const u8) = .empty;
    if (!std.mem.startsWith(u8, r, "/")) {
        if (std.mem.lastIndexOfScalar(u8, from, '/')) |k| {
            var it = std.mem.tokenizeScalar(u8, from[0..k], '/');
            while (it.next()) |p| try parts.append(a, p);
        }
    }
    var it = std.mem.tokenizeScalar(u8, r, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(a, p);
    }
    var out: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |p, i| {
        if (i > 0) try out.append(a, '/');
        var k: usize = 0;
        while (k < p.len) {
            if (p[k] == '%' and k + 2 < p.len) if (std.fmt.parseInt(u8, p[k + 1 .. k + 3], 16)) |v| {
                try out.append(a, v);
                k += 3;
                continue;
            } else |_| {};
            try out.append(a, p[k]);
            k += 1;
        }
    }
    return out.items;
}

fn fragmentOf(ref: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, ref, '#')) |k| ref[k + 1 ..] else "";
}

/// EPUB 3's `<nav epub:type="toc">`: nested lists of links.
fn parseNav(a: Allocator, gpa: Allocator, src: []const u8, path: []const u8) error{OutOfMemory}![]TocEntry {
    var out: std.ArrayList(TocEntry) = .empty;
    var t: xml.Tokenizer = .init(gpa, src);
    defer t.deinit();
    var in_toc = false;
    var nav_depth: u32 = 0;
    var depth: u8 = 0;
    var label: std.ArrayList(u8) = .empty;
    var href: ?[]const u8 = null;
    while (try t.next()) |tok| switch (tok) {
        .start => |s| {
            const n = xml.local(s.name);
            if (std.mem.eql(u8, n, "nav")) {
                if (in_toc) {
                    nav_depth += 1;
                } else if (xml.attr(s.attrs, "type")) |ty| if (hasWord(ty, "toc")) {
                    in_toc = true;
                    nav_depth = 0;
                };
            } else if (in_toc and std.mem.eql(u8, n, "ol") and !s.empty) {
                depth +|= 1;
            } else if (in_toc and std.mem.eql(u8, n, "a") and !s.empty) {
                label.clearRetainingCapacity();
                href = if (xml.attr(s.attrs, "href")) |h| try a.dupe(u8, h) else null;
            }
        },
        .text => |txt| if (href != null) try label.appendSlice(a, txt),
        .end => |e| {
            const n = xml.local(e);
            if (!in_toc) continue;
            if (std.mem.eql(u8, n, "nav")) {
                if (nav_depth == 0) break;
                nav_depth -= 1;
            } else if (std.mem.eql(u8, n, "ol")) {
                depth -|= 1;
            } else if (std.mem.eql(u8, n, "a")) if (href) |h| {
                try out.append(a, .{ .label = collapse(a, label.items) catch "", .path = try resolve(a, path, h), .fragment = try a.dupe(u8, fragmentOf(h)), .depth = @max(1, depth) });
                href = null;
            };
        },
    };
    return out.items;
}

/// EPUB 2's NCX: nested navPoints with a label and a content src.
fn parseNcx(a: Allocator, gpa: Allocator, src: []const u8, path: []const u8) error{OutOfMemory}![]TocEntry {
    var out: std.ArrayList(TocEntry) = .empty;
    var t: xml.Tokenizer = .init(gpa, src);
    defer t.deinit();
    var depth: u8 = 0;
    var in_text = false;
    var label: std.ArrayList(u8) = .empty;
    while (try t.next()) |tok| switch (tok) {
        .start => |s| {
            const n = xml.local(s.name);
            if (std.mem.eql(u8, n, "navPoint") and !s.empty) {
                depth +|= 1;
                label.clearRetainingCapacity();
            } else if (std.mem.eql(u8, n, "text") and !s.empty) {
                in_text = true;
            } else if (std.mem.eql(u8, n, "content")) {
                if (xml.attr(s.attrs, "src")) |h| try out.append(a, .{ .label = collapse(a, label.items) catch "", .path = try resolve(a, path, h), .fragment = try a.dupe(u8, fragmentOf(h)), .depth = @max(1, depth) });
            }
        },
        .text => |txt| if (in_text) try label.appendSlice(a, txt),
        .end => |e| {
            const n = xml.local(e);
            if (std.mem.eql(u8, n, "text")) in_text = false;
            if (std.mem.eql(u8, n, "navPoint")) depth -|= 1;
        },
    };
    return out.items;
}

fn collapse(a: Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (std.mem.trim(u8, s, " \t\r\n")) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = true;
            continue;
        }
        if (space) try out.append(a, ' ');
        space = false;
        try out.append(a, c);
    }
    return out.items;
}

test "paths resolve against the referring file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("epub/text/chapter-1.xhtml", try resolve(a, "epub/content.opf", "text/chapter-1.xhtml#s1"));
    try std.testing.expectEqualStrings("epub/css/core.css", try resolve(a, "epub/text/chapter-1.xhtml", "../css/core.css"));
    try std.testing.expectEqualStrings("OEBPS/my file.xhtml", try resolve(a, "OEBPS/content.opf", "my%20file.xhtml"));
}

test "fuzz the container and package parsers" {
    try std.testing.fuzz({}, fuzzOpen, .{ .corpus = &.{@embedFile("testdata/tiny.zip")} });
}

fn fuzzOpen(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const gpa = std.testing.allocator;
    const b = Book.open(gpa, buf[0..n]) catch return;
    defer b.destroy();
    for (b.spine) |s| if (try b.read(gpa, b.manifest[s.item].path)) |bytes| gpa.free(bytes);
}

test {
    std.testing.refAllDecls(@This());
}
