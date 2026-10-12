//! A PDF document (D9, D19): pages lowered from display lists, fonts
//! embedded as subsets at the end, then the cross-reference table.
//!
//! Objects are serialized into memory as they are made and written in
//! order by `finish`; fonts are the exception, written last because their
//! subsets need every glyph the document uses. Streams are compressed
//! with Flate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scene = @import("scene");
const content = @import("content.zig");
const font_mod = @import("font.zig");

const Writer = @This();

gpa: Allocator,
/// Serialized objects by number - 1; null until set.
objects: std.ArrayList(?[]u8) = .empty,
pages: std.ArrayList(u32) = .empty,
pages_obj: u32 = 0,
fonts: font_mod.Fonts,
/// ExtGState objects by their content, shared across pages.
states: std.StringHashMapUnmanaged(u32) = .empty,
info: Info,

pub const Info = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    creator: []const u8 = "",
};

pub const Error = Allocator.Error || error{ InvalidFont, Unsupported };

pub fn init(gpa: Allocator, info: Info) Allocator.Error!Writer {
    var w: Writer = .{ .gpa = gpa, .fonts = .init(gpa), .info = info };
    errdefer w.deinit();
    w.pages_obj = try w.reserve();
    return w;
}

pub fn deinit(w: *Writer) void {
    for (w.objects.items) |o| if (o) |b| w.gpa.free(b);
    w.objects.deinit(w.gpa);
    w.pages.deinit(w.gpa);
    w.fonts.deinit();
    var it = w.states.keyIterator();
    while (it.next()) |k| w.gpa.free(k.*);
    w.states.deinit(w.gpa);
}

/// A new object number, to be set later.
pub fn reserve(w: *Writer) Allocator.Error!u32 {
    try w.objects.append(w.gpa, null);
    return @intCast(w.objects.items.len);
}

/// Sets object `num` to `body` (the part between "obj" and "endobj").
pub fn set(w: *Writer, num: u32, body: []const u8) Allocator.Error!void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(w.gpa);
    try out.print(w.gpa, "{d} 0 obj\n", .{num});
    try out.appendSlice(w.gpa, body);
    try out.appendSlice(w.gpa, "\nendobj\n");
    std.debug.assert(w.objects.items[num - 1] == null);
    w.objects.items[num - 1] = try out.toOwnedSlice(w.gpa);
}

/// A new object with `body`.
pub fn add(w: *Writer, body: []const u8) Allocator.Error!u32 {
    const num = try w.reserve();
    try w.set(num, body);
    return num;
}

/// Sets object `num` to a stream: `dict` holds the entries besides
/// /Length and /Filter; `data` is compressed.
pub fn setStream(w: *Writer, num: u32, dict: []const u8, data: []const u8) Allocator.Error!void {
    const z = try deflate(w.gpa, data);
    defer w.gpa.free(z);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(w.gpa);
    try out.print(w.gpa, "{d} 0 obj\n<< {s} /Length {d} /Filter /FlateDecode >>\nstream\n", .{ num, dict, z.len });
    try out.appendSlice(w.gpa, z);
    try out.appendSlice(w.gpa, "\nendstream\nendobj\n");
    std.debug.assert(w.objects.items[num - 1] == null);
    w.objects.items[num - 1] = try out.toOwnedSlice(w.gpa);
}

pub fn addStream(w: *Writer, dict: []const u8, data: []const u8) Allocator.Error!u32 {
    const num = try w.reserve();
    try w.setStream(num, dict, data);
    return num;
}

/// An ExtGState with `body` (its entries), shared by content.
pub fn state(w: *Writer, body: []const u8) Allocator.Error!u32 {
    if (w.states.get(body)) |n| return n;
    const key = try w.gpa.dupe(u8, body);
    errdefer w.gpa.free(key);
    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(w.gpa);
    try dict.print(w.gpa, "<< /Type /ExtGState {s} >>", .{body});
    const num = try w.add(dict.items);
    try w.states.put(w.gpa, key, num);
    return num;
}

/// Appends a page of `width` by `height` points showing `list`, whose
/// coordinates are points with y down from the top-left corner.
pub fn addPage(w: *Writer, width: f32, height: f32, list: scene.DisplayList) Error!void {
    if (!(width > 0 and height > 0) or !std.math.isFinite(width) or !std.math.isFinite(height)) return error.Unsupported;
    var c: content.Content = .init(w);
    defer c.deinit();
    // y down from the top-left corner, in points.
    try c.print("1 0 0 -1 0 {f} cm\n", .{content.num(height)});
    try c.lower(list.commands, .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height });
    const stream = try w.addStream("", c.out.items);
    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(w.gpa);
    try dict.print(w.gpa, "<< /Type /Page /Parent {d} 0 R /MediaBox [0 0 {f} {f}] /Contents {d} 0 R /Resources ", .{ w.pages_obj, content.num(width), content.num(height), stream });
    try c.res.write(w.gpa, &dict);
    try dict.appendSlice(w.gpa, " >>");
    try w.pages.append(w.gpa, try w.add(dict.items));
}

/// Embeds the fonts and writes the document to `out`.
pub fn finish(w: *Writer, out: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    try w.fonts.write(w);
    var kids: std.ArrayList(u8) = .empty;
    defer kids.deinit(w.gpa);
    try kids.appendSlice(w.gpa, "<< /Type /Pages /Kids [");
    for (w.pages.items, 0..) |p, i| try kids.print(w.gpa, "{s}{d} 0 R", .{ if (i == 0) "" else " ", p });
    try kids.print(w.gpa, "] /Count {d} >>", .{w.pages.items.len});
    try w.set(w.pages_obj, kids.items);
    var cat: [96]u8 = undefined;
    const catalog = try w.add(std.fmt.bufPrint(&cat, "<< /Type /Catalog /Pages {d} 0 R >>", .{w.pages_obj}) catch unreachable);
    var info: std.ArrayList(u8) = .empty;
    defer info.deinit(w.gpa);
    try info.appendSlice(w.gpa, "<< /Producer ");
    try content.textString(w.gpa, &info, "siv");
    if (w.info.title.len > 0) {
        try info.appendSlice(w.gpa, " /Title ");
        try content.textString(w.gpa, &info, w.info.title);
    }
    if (w.info.author.len > 0) {
        try info.appendSlice(w.gpa, " /Author ");
        try content.textString(w.gpa, &info, w.info.author);
    }
    if (w.info.creator.len > 0) {
        try info.appendSlice(w.gpa, " /Creator ");
        try content.textString(w.gpa, &info, w.info.creator);
    }
    try info.appendSlice(w.gpa, " >>");
    const info_obj = try w.add(info.items);

    // The header's second line marks the file as binary.
    const header = "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n";
    try out.writeAll(header);
    var offset: u64 = header.len;
    const offsets = try w.gpa.alloc(u64, w.objects.items.len);
    defer w.gpa.free(offsets);
    var id = std.hash.Wyhash.init(0);
    for (w.objects.items, offsets) |o, *off| {
        const bytes = o orelse return error.Unsupported; // every reserved object is set by now
        off.* = offset;
        try out.writeAll(bytes);
        offset += bytes.len;
        id.update(bytes);
    }
    try out.print("xref\n0 {d}\n0000000000 65535 f \n", .{w.objects.items.len + 1});
    for (offsets) |off| try out.print("{d:0>10} 00000 n \n", .{off});
    const h = id.final();
    try out.print("trailer\n<< /Size {d} /Root {d} 0 R /Info {d} 0 R /ID [<{x:0>16}{x:0>16}> <{x:0>16}{x:0>16}>] >>\nstartxref\n{d}\n%%EOF\n", .{ w.objects.items.len + 1, catalog, info_obj, h, ~h, h, ~h, offset });
    try out.flush();
}

/// zlib-compressed `data`.
pub fn deflate(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    const flate = std.compress.flate;
    // The compressor needs room in its output's buffer.
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, data.len / 4));
    defer aw.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    c.* = flate.Compress.init(&aw.writer, window, .zlib, .default) catch return error.OutOfMemory;
    c.writer.writeAll(data) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

test "deflate round-trips" {
    const gpa = std.testing.allocator;
    var data_buf: [27 * 50]u8 = undefined;
    for (0..50) |i| @memcpy(data_buf[i * 27 ..][0..27], "BT /F1 12 Tf (hello) Tj ET ");
    const data: []const u8 = &data_buf;
    const z = try deflate(gpa, data);
    defer gpa.free(z);
    try std.testing.expect(z.len < data.len / 4);
    var in: std.Io.Reader = .fixed(z);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &buf);
    _ = try d.reader.streamRemaining(&aw.writer);
    try std.testing.expectEqualStrings(data, aw.written());
}
