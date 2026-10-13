//! Tests of the generated Zig wrappers: their types match the generated C
//! headers (as translated by the C compiler), and their idiomatic functions
//! work against the shared libraries.

const std = @import("std");
const schema = @import("schema.zig");
const siv = @import("siv");
const sivtest = @import("sivtest");

test "wrapper layouts match the C headers" {
    inline for (.{
        .{ @import("api.zig").spec, siv, @import("siv_h") },
        .{ @import("test_api.zig").spec, sivtest, @import("sivtest_h") },
    }) |entry| {
        const s, const W, const H = entry;
        @setEvalBranchQuota(100_000);
        inline for (comptime s.decls) |d| {
            const Z = comptime @field(W, zigName(d.name()));
            const C = @field(H, d.name());
            switch (d) {
                .handle, .flags => try std.testing.expectEqual(@sizeOf(C), @sizeOf(Z)),
                .callback => try std.testing.expectEqual(@sizeOf(C), @sizeOf(?Z)),
                .@"enum" => |e| {
                    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Z));
                    inline for (e.values) |v| {
                        const c_name = comptime cName(schema.enumValuePrefix, e, v.name);
                        try std.testing.expectEqual(@field(H, c_name), @backingInt(@field(Z, v.name)));
                    }
                },
                .@"struct" => |st| {
                    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Z));
                    try std.testing.expectEqual(@alignOf(C), @alignOf(Z));
                    if (st.kind == .descriptor) try std.testing.expectEqual(@offsetOf(C, "size"), @offsetOf(Z, "size"));
                    inline for (st.fields) |f| {
                        try std.testing.expectEqual(@offsetOf(C, f.name), @offsetOf(Z, f.name));
                        if (f.type == .string) try std.testing.expectEqual(@offsetOf(C, f.name ++ "_len"), @offsetOf(Z, f.name ++ "_len"));
                        if (f.type == .array) try std.testing.expectEqual(@offsetOf(C, f.name ++ "_count"), @offsetOf(Z, f.name ++ "_count"));
                    }
                },
            }
            if (d == .flags) inline for (d.flags.bits) |b| {
                const c_name = comptime cName(schema.flagsValuePrefix, d.flags, b.name);
                var z: Z = .{};
                @field(z, b.name) = true;
                try std.testing.expectEqual(@field(H, c_name), @as(u32, @bitCast(z)));
            };
        }
        inline for (comptime s.functions) |f| {
            const zf = @typeInfo(@field(W.signatures, f.name)).@"fn";
            const cf = @typeInfo(@TypeOf(@field(H, f.name))).@"fn";
            try std.testing.expectEqual(cf.param_types.len, zf.param_types.len);
            inline for (zf.param_types, cf.param_types) |z, c| try std.testing.expectEqual(@sizeOf(c.?), @sizeOf(z.?));
            try std.testing.expectEqual(@sizeOf(cf.return_type.?), @sizeOf(zf.return_type.?));
        }
    }
}

fn zigName(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [128]u8 = undefined;
        const n = schema.zigTypeName(&buf, name);
        const out = n[0..n.len].*;
        return &out;
    }
}

fn cName(comptime prefixFn: anytype, comptime decl: anytype, comptime value: []const u8) []const u8 {
    comptime {
        var pbuf: [128]u8 = undefined;
        var ubuf: [128]u8 = undefined;
        const p = prefixFn(&pbuf, decl);
        const u = schema.upper(&ubuf, value);
        const out = (p ++ u)[0 .. p.len + u.len].*;
        return &out;
    }
}

test "idiomatic siv wrapper" {
    const v = siv.version();
    try std.testing.expectEqual(siv.header_version.major, v >> 16);
    try std.testing.expectEqual(siv.header_version.minor, v >> 8 & 0xff);
    try std.testing.expectEqualStrings("SIV_ERROR_UNSUPPORTED", siv.resultName(.error_unsupported));
    try std.testing.expectError(error.InvalidHandle, siv.check(.error_invalid_handle));
    try std.testing.expectError(error.Unexpected, siv.check(@fromBackingInt(77)));
    try std.testing.expectEqual(siv.Result.error_limit_exceeded, siv.resultOf(error.LimitExceeded));
}

test "idiomatic sivtest wrapper" {
    const ctx = try sivtest.contextCreate(null);
    defer sivtest.contextDestroy(ctx) catch unreachable;

    const name = "zig\x00name";
    const item = try sivtest.itemCreate(ctx, .{ .name = name, .shape = .circle, .flags = .{ .pinned = true } });
    const info = try sivtest.itemGet(item);
    try std.testing.expectEqual(sivtest.Shape.circle, info.shape);
    try std.testing.expect(info.flags.pinned and !info.flags.hidden);
    try std.testing.expectEqual(name.len, info.name_len);

    // Options take strings and arrays as slices (D3).
    const tagged = try sivtest.itemCreate(ctx, .{ .tags = &.{ 1, 2, 39 } });
    try std.testing.expectEqual(42, try sivtest.itemTagSum(tagged));
    try sivtest.itemDestroy(tagged);

    try sivtest.itemSetName(item, "x");
    try std.testing.expectEqual(1, (try sivtest.itemGet(item)).name_len);

    const Log = struct {
        seen: usize = 0,
        fn visit(user_data: ?*anyopaque, it: sivtest.Item, n: ?[*]const u8, len: usize) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(user_data));
            _ = it;
            self.seen += len;
            std.debug.assert(n != null);
            return true;
        }
    };
    var log: Log = .{};
    try std.testing.expectEqual(1, try sivtest.contextVisit(ctx, Log.visit, &log));
    try std.testing.expectEqual(1, log.seen);

    try sivtest.itemDestroy(item);
    try std.testing.expectError(error.InvalidHandle, sivtest.itemGet(item));
    try std.testing.expectError(error.Unsupported, sivtest.itemCreate(ctx, .{ .shape = @fromBackingInt(3) }));
}
