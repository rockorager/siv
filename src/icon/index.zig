//! index.theme, the desktop entry file that describes an icon theme: its
//! parents and its directories, each with a nominal size, a scale, and a
//! type that says which sizes it serves (freedesktop icon theme
//! specification 0.13, with KDE's ScaledDirectories).

const std = @import("std");

pub const DirType = enum(u8) { fixed, scalable, threshold };

pub const Dir = struct {
    /// Relative to the theme's directory.
    path: []const u8,
    size: u32,
    scale: u32 = 1,
    type: DirType = .threshold,
    min_size: u32,
    max_size: u32,
    threshold: u32 = 2,

    /// DirectoryMatchesSize.
    pub fn matches(d: Dir, size: u32, scale: u32) bool {
        if (d.scale != scale) return false;
        return switch (d.type) {
            .fixed => d.size == size,
            .scalable => d.min_size <= size and size <= d.max_size,
            .threshold => d.size -| d.threshold <= size and size <= d.size + d.threshold,
        };
    }

    /// DirectorySizeDistance, in pixels.
    pub fn distance(d: Dir, size: u32, scale: u32) u64 {
        const want = @as(u64, size) * scale;
        const k: u64 = d.scale;
        return switch (d.type) {
            .fixed => absDiff(d.size * k, want),
            .scalable => outside(d.min_size * k, d.max_size * k, want),
            .threshold => outside((d.size -| d.threshold) * k, (@as(u64, d.size) + d.threshold) * k, want),
        };
    }
};

fn absDiff(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

fn outside(lo: u64, hi: u64, v: u64) u64 {
    if (v < lo) return lo - v;
    if (v > hi) return v - hi;
    return 0;
}

pub const Index = struct {
    /// Parent themes, in order; hicolor is the implicit last.
    inherits: []const []const u8,
    dirs: []const Dir,
};

/// Parses an index.theme into memory from `arena`. Directories listed
/// without a section of their own are dropped, as the specification
/// requires a section for each.
pub fn parse(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Index {
    var inherits: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var sections: std.StringHashMapUnmanaged(Dir) = .empty;
    var section: []const u8 = "";
    var dir: ?*Dir = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = line[1..end];
            dir = null;
            if (!std.mem.eql(u8, section, "Icon Theme")) {
                const gop = try sections.getOrPut(arena, section);
                if (!gop.found_existing) gop.value_ptr.* = .{ .path = section, .size = 0, .min_size = 0, .max_size = 0 };
                dir = gop.value_ptr;
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, section, "Icon Theme")) {
            if (std.mem.eql(u8, key, "Inherits")) {
                try list(arena, value, &inherits);
            } else if (std.mem.eql(u8, key, "Directories") or std.mem.eql(u8, key, "ScaledDirectories")) {
                try list(arena, value, &names);
            }
        } else if (dir) |d| {
            const n = std.fmt.parseInt(u32, value, 10) catch {
                if (std.mem.eql(u8, key, "Type")) {
                    if (std.mem.eql(u8, value, "Fixed")) d.type = .fixed;
                    if (std.mem.eql(u8, value, "Scalable")) d.type = .scalable;
                    if (std.mem.eql(u8, value, "Threshold")) d.type = .threshold;
                }
                continue;
            };
            if (n > 1 << 16) continue;
            if (std.mem.eql(u8, key, "Size")) d.size = n;
            if (std.mem.eql(u8, key, "Scale") and n >= 1 and n <= 16) d.scale = n;
            if (std.mem.eql(u8, key, "MinSize")) d.min_size = n;
            if (std.mem.eql(u8, key, "MaxSize")) d.max_size = n;
            if (std.mem.eql(u8, key, "Threshold")) d.threshold = n;
        }
    }
    var dirs: std.ArrayList(Dir) = .empty;
    for (names.items) |name| {
        // Listed twice (Directories and ScaledDirectories) counts once.
        for (dirs.items) |d| {
            if (std.mem.eql(u8, d.path, name)) break;
        } else if (sections.get(name)) |s| {
            if (s.size == 0) continue;
            var d = s;
            // MinSize and MaxSize default to Size.
            if (d.min_size == 0) d.min_size = d.size;
            if (d.max_size == 0) d.max_size = d.size;
            try dirs.append(arena, d);
        }
    }
    return .{ .inherits = inherits.items, .dirs = dirs.items };
}

fn list(arena: std.mem.Allocator, value: []const u8, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    var it = std.mem.tokenizeAny(u8, value, ",;");
    while (it.next()) |item| {
        const s = std.mem.trim(u8, item, " \t");
        if (s.len == 0 or std.mem.indexOf(u8, s, "..") != null or s[0] == '/') continue;
        try out.append(arena, s);
    }
}

const testing = std.testing;

test "index.theme sections, inheritance, and scaled directories" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const idx = try parse(arena.allocator(),
        \\[Icon Theme]
        \\Name=Test
        \\Name[de]=Prüfung
        \\Inherits=Parent,hicolor
        \\Directories=16x16/actions,scalable/actions,missing,../escape
        \\ScaledDirectories=16x16@2/actions
        \\
        \\[16x16/actions]
        \\Size=16
        \\Type=Fixed
        \\
        \\[16x16@2/actions]
        \\Size=16
        \\Scale=2
        \\Type=Fixed
        \\
        \\[scalable/actions]
        \\Size=16
        \\MinSize=8
        \\MaxSize=512
        \\Type=Scalable
    );
    try testing.expectEqual(@as(usize, 2), idx.inherits.len);
    try testing.expectEqualStrings("Parent", idx.inherits[0]);
    try testing.expectEqual(@as(usize, 3), idx.dirs.len);
    const fixed = idx.dirs[0];
    const scalable = idx.dirs[1];
    const scaled = idx.dirs[2];
    try testing.expect(fixed.matches(16, 1) and !fixed.matches(16, 2) and !fixed.matches(24, 1));
    try testing.expect(scaled.matches(16, 2));
    try testing.expect(scalable.matches(48, 1) and !scalable.matches(4, 1));
    try testing.expectEqual(@as(u64, 8), fixed.distance(24, 1));
    try testing.expectEqual(@as(u64, 0), scaled.distance(32, 1));
    try testing.expectEqual(@as(u64, 4), scalable.distance(1, 4));
    // Threshold directories serve their size ± 2 by default.
    const t: Dir = .{ .path = "", .size = 32, .min_size = 32, .max_size = 32 };
    try testing.expect(t.matches(30, 1) and t.matches(34, 1) and !t.matches(35, 1));
    try testing.expectEqual(@as(u64, 3), t.distance(37, 1));
}

test "fuzz index.theme" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "[Icon Theme]\nInherits=a,b\nDirectories=x\n[x]\nSize=16\nType=Scalable\nMaxSize=64\n",
        "[Icon Theme\nDirectories=,,;\n[]\n=\nSize=99999999999\n",
    } });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [2048]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const idx = try parse(arena.allocator(), text);
    for (idx.dirs) |d| {
        try testing.expect(d.size > 0 and d.scale >= 1);
        _ = d.matches(16, 1);
        _ = d.distance(0xffff, 64);
    }
}
