//! The static modules (`siv-static` and `siv_webview-static`): the Zig
//! module's tests, in a binary that has siv and siv-webview linked in and
//! loads WPE WebKit and the rest from the system.
const std = @import("std");

test {
    _ = @import("zig.zig");
}

test "siv is linked in, WPE WebKit is the system's" {
    const Loaded = struct {
        siv: ?[*:0]const u8 = null,
        webkit: bool = false,

        fn each(info: *std.c.dl_phdr_info, _: usize, data: ?*anyopaque) callconv(.c) c_int {
            const seen: *@This() = @ptrCast(@alignCast(data.?));
            const path = info.name orelse return 0;
            const name = std.fs.path.basename(std.mem.span(path));
            if (std.mem.startsWith(u8, name, "libsiv")) seen.siv = path;
            if (std.mem.startsWith(u8, name, "libWPEWebKit")) seen.webkit = true;
            return 0;
        }
    };
    var seen: Loaded = .{};
    _ = std.c.dl_iterate_phdr(Loaded.each, &seen);
    if (seen.siv) |path| {
        std.debug.print("loaded {s}\n", .{path});
        return error.SharedSiv;
    }
    try std.testing.expect(seen.webkit);
}
