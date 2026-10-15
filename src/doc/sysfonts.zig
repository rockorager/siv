//! System fonts through Fontconfig, loaded synchronously: the font
//! resolver for programs without siv's application (the document
//! benchmarks and the render tool). Applications resolve through their
//! `ui.Fonts`, which loads on the worker pool.

const std = @import("std");
const text = @import("text");
const Document = @import("Document.zig");

pub const SystemFonts = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cache: text.FontCache,
    db: text.fontconfig.Database,
    chains: std.StringHashMapUnmanaged([]const text.FontId) = .empty,
    files: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*SystemFonts {
        const s = try gpa.create(SystemFonts);
        s.* = .{ .gpa = gpa, .io = io, .cache = .init(gpa), .db = try text.fontconfig.Database.init() };
        try s.cache.addLastResort();
        return s;
    }

    pub fn deinit(s: *SystemFonts) void {
        var it = s.chains.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.*);
        }
        s.chains.deinit(s.gpa);
        s.cache.deinit();
        for (s.files.items) |f| s.gpa.free(f);
        s.files.deinit(s.gpa);
        s.db.deinit();
        s.gpa.destroy(s);
    }

    fn chainFn(ctx: *anyopaque, family: []const u8, language: []const u8, weight: u16, italic: bool, stretch: f32, size: f32) Document.Error![]const text.FontId {
        _ = stretch;
        _ = size;
        const s: *SystemFonts = @ptrCast(@alignCast(ctx));
        const key = std.fmt.allocPrint(s.gpa, "{s}|{s}|{d}|{}", .{ family, language, weight, italic }) catch return error.OutOfMemory;
        if (s.chains.get(key)) |c| {
            s.gpa.free(key);
            return c;
        }
        const found = s.db.candidates(s.gpa, &s.cache, .{
            .family = family,
            .language = if (language.len == 0) null else language,
            .weight = @floatFromInt(weight),
            .slant = if (italic) .italic else .roman,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => s.gpa.alloc(text.FontId, 0) catch return error.OutOfMemory,
        };
        // Load the first few now; fallbacks for other scripts on demand.
        for (found[0..@min(found.len, 3)]) |id| s.load(id);
        s.chains.put(s.gpa, key, found) catch return error.OutOfMemory;
        return found;
    }

    /// Reads a pending font's file.
    pub fn load(s: *SystemFonts, id: text.FontId) void {
        if (s.cache.state(id) != .pending) return;
        const src = s.cache.source(id);
        const bytes = std.Io.Dir.cwd().readFileAlloc(s.io, src.path, s.gpa, .limited(256 << 20)) catch {
            s.cache.fail(id);
            return;
        };
        s.files.append(s.gpa, bytes) catch {
            s.gpa.free(bytes);
            s.cache.fail(id);
            return;
        };
        s.cache.load(id, bytes, .borrowed) catch s.cache.fail(id);
    }

    pub fn resolver(s: *SystemFonts) Document.FontResolver {
        return .{ .ctx = s, .cache = &s.cache, .chainFn = chainFn };
    }
};
