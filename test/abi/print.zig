//! Printing and PDF output through the exports (D9, D19) on the headless
//! backend: siv_pdf_write draws a document's pages at the next dispatch
//! and writes a PDF whose pages, sizes, and text read back; siv_print has
//! no portal here and ends as unavailable. The Print portal round trip,
//! and checks of the PDFs by qpdf and poppler, run in
//! `zig build test-integration`.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("abi");
const pdf = @import("pdf");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const A = abi.application;
const C = abi.canvas;
const P = abi.print;
const ok = harness.ok;

const Doc = struct {
    begins: u32 = 0,
    draws: u32 = 0,
    results: u32 = 0,
    destroys: u32 = 0,
    response: t.PortalResponse = .failed,
    count: u32 = 0,
    setup: t.PageSetup = .{},
    /// A drawing call that failed on purpose.
    bad_draw: t.Result = .ok,

    fn begin(user_data: ?*anyopaque, setup: ?*const t.PageSetup) callconv(.c) u32 {
        const d: *Doc = @ptrCast(@alignCast(user_data));
        d.begins += 1;
        d.setup = setup.?.*;
        return 2;
    }

    fn drawPage(user_data: ?*anyopaque, draw: t.Draw, page: u32, setup: ?*const t.PageSetup) callconv(.c) void {
        const d: *Doc = @ptrCast(@alignCast(user_data));
        d.draws += 1;
        const s = setup.?;
        _ = C.siv_draw_rect(draw, .{ .x = s.margin_left + 10, .y = s.margin_top + 10, .width = 100, .height = 50 });
        _ = C.siv_draw_fill(draw, &.{ .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } }, .{});
        const words: []const u8 = if (page == 0) "First page" else "Second page";
        _ = C.siv_draw_text(draw, 72, 144, 0, words.ptr, words.len, &.{ .font_size = 18 });
        // The second page fails, and is left blank as a canvas would be.
        if (page == 1) d.bad_draw = C.siv_draw_rect(draw, .{ .x = std.math.nan(f32), .y = 0, .width = 1, .height = 1 });
    }

    fn done(user_data: ?*anyopaque, result: ?*const t.PortalResult) callconv(.c) void {
        const d: *Doc = @ptrCast(@alignCast(user_data));
        d.results += 1;
        d.response = result.?.response;
        d.count = result.?.count;
    }

    fn destroy(user_data: ?*anyopaque) callconv(.c) void {
        const d: *Doc = @ptrCast(@alignCast(user_data));
        d.destroys += 1;
    }

    fn desc(d: *Doc) t.PrintDesc {
        return .{ .title = "Report", .title_len = 6, .user_data = d, .begin = begin, .draw_page = drawPage, .done = done, .destroy = destroy };
    }
};

fn memfd() !i32 {
    const rc = linux.memfd_create("siv-print-test", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    return @intCast(rc);
}

fn readAll(fd: i32) ![]u8 {
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    const buf = try testing.allocator.alloc(u8, size);
    errdefer testing.allocator.free(buf);
    if (linux.pread(fd, buf.ptr, buf.len, 0) != size) return error.ReadFailed;
    return buf;
}

fn dispatchUntil(h: *harness.Harness, d: *const Doc) !void {
    for (0..200) |_| {
        if (d.results > 0) return;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
    return error.Timeout;
}

test "siv_pdf_write draws the pages at the next dispatch and writes them" {
    var h: harness.Harness = .{};
    try h.start(64, 48, null, null);
    defer h.stop();
    const fd = try memfd();
    defer _ = linux.close(fd);
    var doc: Doc = .{};
    var desc = doc.desc();
    try ok(P.siv_pdf_write(h.app, &desc, fd));
    // The descriptor's pointers are not kept, and nothing ran yet.
    desc = .{};
    try testing.expectEqual(@as(u32, 0), doc.begins);
    try dispatchUntil(&h, &doc);
    try testing.expectEqual(t.PortalResponse.success, doc.response);
    try testing.expectEqual(@as(u32, 2), doc.count);
    try testing.expectEqual(@as(u32, 1), doc.destroys);
    // A4 without margins.
    try testing.expectApproxEqAbs(@as(f32, 595.2756), doc.setup.width, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 841.8898), doc.setup.height, 1e-3);
    try testing.expectEqual(@as(f32, 0), doc.setup.margin_left);
    try testing.expectEqual(@as(u32, 2), doc.draws);
    try testing.expectEqual(t.Result.error_invalid_argument, doc.bad_draw);

    const bytes = try readAll(fd);
    defer testing.allocator.free(bytes);
    var p = try pdf.testing.Parsed.parse(bytes);
    defer p.deinit();
    var pages: u32 = 0;
    var cmap: std.ArrayList(u8) = .empty;
    defer cmap.deinit(testing.allocator);
    var title = false;
    for (p.objects.items) |o| {
        if (std.mem.indexOf(u8, o, "/Type /Page ") != null) {
            pages += 1;
            try testing.expect(std.mem.indexOf(u8, o, "/MediaBox [0 0 595.2756 841.8898]") != null);
        }
        if (std.mem.indexOf(u8, o, "/Title (Report)") != null) title = true;
        if (std.mem.indexOf(u8, o, "/ToUnicode ") != null) {
            const s = try p.stream(try pdf.testing.ref(o, "/ToUnicode "));
            defer testing.allocator.free(s);
            try cmap.appendSlice(testing.allocator, s);
        }
    }
    try testing.expectEqual(@as(u32, 2), pages);
    try testing.expect(title);
    // The first page's text is in the ToUnicode map (F, 0046); the
    // second page's (S, 0053) is not.
    try testing.expect(std.mem.indexOf(u8, cmap.items, "> <0046>") != null);
    try testing.expect(std.mem.indexOf(u8, cmap.items, "> <0053>") == null);
}

test "siv_print without a portal ends as unavailable at the next dispatch" {
    var h: harness.Harness = .{};
    try h.start(64, 48, null, null);
    defer h.stop();
    var doc: Doc = .{};
    const desc = doc.desc();
    try ok(P.siv_print(h.app, h.window, &desc));
    try testing.expectEqual(@as(u32, 0), doc.results);
    try dispatchUntil(&h, &doc);
    try testing.expectEqual(t.PortalResponse.unavailable, doc.response);
    try testing.expectEqual(@as(u32, 0), doc.count);
    try testing.expectEqual(@as(u32, 0), doc.draws);
    try testing.expectEqual(@as(u32, 1), doc.destroys);
}

test "rejected documents run their destroy-notify; pending ones go with the application" {
    var h: harness.Harness = .{};
    try h.start(64, 48, null, null);
    var doc: Doc = .{};
    var desc = doc.desc();
    desc.draw_page = null;
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_pdf_write(h.app, &desc, 1));
    desc = doc.desc();
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_pdf_write(h.app, &desc, -1));
    desc.width = -5;
    desc.height = 10;
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_print(h.app, .null, &desc));
    desc = doc.desc();
    try testing.expectEqual(t.Result.error_invalid_handle, P.siv_print(h.app, @fromBackingInt(12345), &desc));
    try testing.expectEqual(@as(u32, 4), doc.destroys);

    // Destroying the application drops a job that has not run.
    const fd = try memfd();
    defer _ = linux.close(fd);
    try ok(P.siv_pdf_write(h.app, &desc, fd));
    h.stop();
    try testing.expectEqual(@as(u32, 5), doc.destroys);
    try testing.expectEqual(@as(u32, 0), doc.results);
}

const Aligned = struct {
    finished: bool = false,

    fn drawPage(_: ?*anyopaque, draw: t.Draw, _: u32, setup: ?*const t.PageSetup) callconv(.c) void {
        const s = setup.?;
        // Start-aligned across the page between the margins. Digits have
        // no direction of their own: the paragraph takes the page's.
        _ = C.siv_draw_text(draw, s.margin_left, s.margin_top, s.width - s.margin_left - s.margin_right, "42", 2, &.{ .font_size = 12 });
    }

    fn done(user_data: ?*anyopaque, _: ?*const t.PortalResult) callconv(.c) void {
        const a: *Aligned = @ptrCast(@alignCast(user_data));
        a.finished = true;
    }
};

/// The x of the first glyph a PDF draws (its first Tm).
fn firstGlyphX(bytes: []const u8) !f32 {
    var p = try pdf.testing.Parsed.parse(bytes);
    defer p.deinit();
    for (p.objects.items) |o| {
        if (std.mem.indexOf(u8, o, "/Type /Page ") == null) continue;
        const ops = try p.stream(try pdf.testing.ref(o, "/Contents "));
        defer testing.allocator.free(ops);
        var lines = std.mem.splitScalar(u8, ops, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "1 0 0 -1 ") or std.mem.indexOf(u8, line, " Tm ") == null) continue;
            var it = std.mem.tokenizeScalar(u8, line[9..], ' ');
            return std.fmt.parseFloat(f32, it.next().?);
        }
    }
    return error.NoText;
}

fn writeAligned(h: *harness.Harness, direction: t.Direction) !f32 {
    const fd = try memfd();
    defer _ = linux.close(fd);
    var a: Aligned = .{};
    try ok(P.siv_pdf_write(h.app, &.{ .user_data = &a, .page_count = 1, .width = 300, .height = 200, .margin = 20, .draw_page = Aligned.drawPage, .done = Aligned.done, .direction = direction, .language = "he", .language_len = 2 }, fd));
    for (0..200) |_| {
        if (a.finished) break;
        try ok(A.siv_app_dispatch(h.app, 5));
    }
    const bytes = try readAll(fd);
    defer testing.allocator.free(bytes);
    return firstGlyphX(bytes);
}

test "pages follow the document's direction" {
    var h: harness.Harness = .{};
    try h.start(64, 48, null, null);
    defer h.stop();
    // Left to right, text starts at the left margin; right to left, it
    // ends at the right one.
    try testing.expectApproxEqAbs(@as(f32, 20), try writeAligned(&h, .ltr), 0.5);
    try testing.expect(try writeAligned(&h, .rtl) > 250);
    try testing.expectEqual(t.Result.error_invalid_argument, P.siv_pdf_write(h.app, &.{ .draw_page = Aligned.drawPage, .margin = 400 }, 1));
}
