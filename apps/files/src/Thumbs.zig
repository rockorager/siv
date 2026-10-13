//! Thumbnails of images in the shown folder, decoded asynchronously by
//! siv_image_load straight to the size they are shown at.
//!
//! The grid asks for the cells it binds. Each request goes to siv at once
//! with a priority that grows with every ask, so what scrolled into view
//! last decodes first; asking again raises it, and the oldest requests
//! are cancelled once too many wait (they scrolled out of view long ago).
//! Thumbnails that other applications saved in the freedesktop.org
//! thumbnail cache are used instead of the original when they are newer
//! than it. Decoded images are kept up to a count and then dropped oldest
//! first.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
const uri = @import("uri.zig");

const Thumbs = @This();

pub const size: f32 = 64;
const max_cached = 400;
/// More waiting requests than this cancel the oldest.
const max_pending = 256;

gpa: std.mem.Allocator,
app: siv.App,
enabled: bool = true,
scale: f32 = 1,
folder: []u8 = &.{},
gen: u32 = 0,
map: std.StringHashMapUnmanaged(Slot) = .empty,
/// Requests siv has not answered.
pending: u32 = 0,
stamp: u64 = 0,
on_ready: ?*const fn (ctx: ?*anyopaque) void = null,
ctx: ?*anyopaque = null,
/// A refresh is scheduled: many thumbnails arriving together rebind once.
notify_timer: siv.Timer = .null,
/// Decodes that finished, for measurements.
loaded: u32 = 0,
cache_dir: []u8 = &.{},

const Slot = struct {
    state: enum { loading, ready, failed },
    image: siv.Image = .null,
    request: siv.ImageRequest = .null,
    mtime: i64,
    used: u64 = 0,
};

/// One siv_image_load; cancelled requests never call back.
const Request = struct {
    thumbs: *Thumbs,
    /// Key in the map (owned by the map).
    name: []const u8,

    fn done(ud: ?*anyopaque, result: siv.Result, image: siv.Image) callconv(.c) void {
        const r: *Request = @ptrCast(@alignCast(ud.?));
        r.thumbs.finished(r.name, result, image);
    }

    /// May run after the Thumbs is gone (a cancelled decode that was
    /// running), so requests come from the C allocator.
    fn free(ud: ?*anyopaque) callconv(.c) void {
        const r: *Request = @ptrCast(@alignCast(ud.?));
        std.heap.c_allocator.destroy(r);
    }
};

pub fn init(gpa: std.mem.Allocator, app: siv.App) Thumbs {
    return .{ .gpa = gpa, .app = app };
}

pub fn deinit(t: *Thumbs) void {
    if (t.notify_timer != .null) _ = c.siv_timer_cancel(t.notify_timer);
    t.clear();
    t.map.deinit(t.gpa);
    t.gpa.free(t.folder);
    t.gpa.free(t.cache_dir);
}

/// Drops every thumbnail and cancels every request.
fn clear(t: *Thumbs) void {
    var it = t.map.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.request != .null) _ = c.siv_image_request_cancel(kv.value_ptr.request);
        if (kv.value_ptr.image != .null) _ = c.siv_image_destroy(kv.value_ptr.image);
        t.gpa.free(kv.key_ptr.*);
    }
    t.map.clearRetainingCapacity();
    t.pending = 0;
}

pub fn setCacheDir(t: *Thumbs, dir: []const u8) void {
    t.gpa.free(t.cache_dir);
    t.cache_dir = t.gpa.dupe(u8, dir) catch &.{};
}

/// A new folder: thumbnails of the old one go.
pub fn setFolder(t: *Thumbs, folder: []const u8) void {
    if (std.mem.eql(u8, folder, t.folder)) return;
    t.clear();
    t.gen +%= 1;
    t.gpa.free(t.folder);
    t.folder = t.gpa.dupe(u8, folder) catch &.{};
}

pub fn setScale(t: *Thumbs, scale: f32) void {
    if (scale == t.scale or scale <= 0) return;
    t.scale = scale;
    // Sharper ones on demand.
    t.clear();
    t.gen +%= 1;
}

/// The thumbnail of `name` in the folder if it is decoded; otherwise asks
/// for it and returns null.
pub fn get(t: *Thumbs, folder: []const u8, name: []const u8, mtime: i64) ?siv.Image {
    if (!t.enabled or !std.mem.eql(u8, folder, t.folder)) return null;
    t.stamp += 1;
    if (t.map.getPtr(name)) |slot| {
        if (slot.mtime != mtime) {
            // Changed on disk: decode again.
            if (slot.request != .null) {
                _ = c.siv_image_request_cancel(slot.request);
                t.pending -= 1;
            }
            if (slot.image != .null) _ = c.siv_image_destroy(slot.image);
            slot.* = .{ .state = .failed, .mtime = mtime };
            t.request(t.map.getKey(name).?, slot);
        }
        slot.used = t.stamp;
        switch (slot.state) {
            .ready => return slot.image,
            .failed => return null,
            .loading => {
                // Wanted again: before everything asked so far.
                _ = c.siv_image_request_set_priority(slot.request, @intCast(t.stamp));
                return null;
            },
        }
    }
    const key = t.gpa.dupe(u8, name) catch return null;
    const gop = t.map.getOrPut(t.gpa, key) catch {
        t.gpa.free(key);
        return null;
    };
    gop.value_ptr.* = .{ .state = .failed, .mtime = mtime, .used = t.stamp };
    t.request(key, gop.value_ptr);
    if (t.pending > max_pending) t.cancelOldest();
    return null;
}

fn request(t: *Thumbs, name: []const u8, slot: *Slot) void {
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = t.cachedThumbnail(&pbuf, name, slot.mtime) orelse
        (std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ t.folder, name }) catch return);
    const r = std.heap.c_allocator.create(Request) catch return;
    r.* = .{ .thumbs = t, .name = name };
    // The newest request decodes first.
    if (c.siv_image_load(t.app, &.{
        .path = path.ptr,
        .path_len = path.len,
        .max_width = size,
        .max_height = size,
        .scale = t.scale,
        .flags = .{ .first_frame = true },
        .priority = @intCast(t.stamp),
    }, Request.done, Request.free, r, &slot.request) != .ok) return;
    slot.state = .loading;
    t.pending += 1;
}

/// Cancels the request asked for longest ago.
fn cancelOldest(t: *Thumbs) void {
    var oldest: ?*Slot = null;
    var it = t.map.valueIterator();
    while (it.next()) |slot| if (slot.state == .loading and (oldest == null or slot.used < oldest.?.used)) {
        oldest = slot;
    };
    const slot = oldest orelse return;
    _ = c.siv_image_request_cancel(slot.request);
    slot.request = .null;
    // Asked for again, it loads again.
    slot.mtime = -1;
    slot.state = .failed;
    t.pending -= 1;
}

/// A thumbnail another application saved ($XDG_CACHE_HOME/thumbnails,
/// named by the MD5 of the file's URI) that is newer than the file.
fn cachedThumbnail(t: *Thumbs, out: []u8, name: []const u8, mtime: i64) ?[]u8 {
    if (t.cache_dir.len == 0) return null;
    var ubuf: std.ArrayList(u8) = .empty;
    defer ubuf.deinit(t.gpa);
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ t.folder, name }) catch return null;
    uri.appendFileUri(&ubuf, t.gpa, p) catch return null;
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(ubuf.items, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    for ([_][]const u8{ "normal", "large" }) |kind| {
        const tp = std.fmt.bufPrintSentinel(out, "{s}/{s}/{s}.png", .{ t.cache_dir, kind, hex }, 0) catch return null;
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, tp, 0, .{ .MTIME = true }, &st)) != .SUCCESS) continue;
        const tm = st.mtime.sec * std.time.ns_per_s + st.mtime.nsec;
        if (tm >= mtime) return tp;
    }
    return null;
}

fn finished(t: *Thumbs, name: []const u8, result: siv.Result, image: siv.Image) void {
    t.loaded += 1;
    t.pending -= 1;
    const s = t.map.getPtr(name).?;
    s.request = .null;
    if (result == .ok) {
        s.state = .ready;
        s.image = image;
    } else s.state = .failed;
    t.evict();
    t.scheduleNotify();
}

fn evict(t: *Thumbs) void {
    var ready: usize = 0;
    var it = t.map.iterator();
    while (it.next()) |kv| if (kv.value_ptr.state == .ready) {
        ready += 1;
    };
    while (ready > max_cached) : (ready -= 1) {
        var oldest: ?[]const u8 = null;
        var best: u64 = std.math.maxInt(u64);
        var it2 = t.map.iterator();
        while (it2.next()) |kv| if (kv.value_ptr.state == .ready and kv.value_ptr.used < best) {
            best = kv.value_ptr.used;
            oldest = kv.key_ptr.*;
        };
        const key = oldest orelse return;
        const kv = t.map.fetchRemove(key).?;
        _ = c.siv_image_destroy(kv.value.image);
        t.gpa.free(kv.key);
    }
}

fn scheduleNotify(t: *Thumbs) void {
    if (t.notify_timer != .null) return;
    _ = c.siv_timer_start(t.app, 30, notify, null, t, &t.notify_timer);
}

fn notify(ud: ?*anyopaque) callconv(.c) void {
    const t: *Thumbs = @ptrCast(@alignCast(ud.?));
    t.notify_timer = .null;
    if (t.on_ready) |f| f(t.ctx);
}

/// Requests siv has not answered.
pub fn busy(t: *const Thumbs) bool {
    return t.pending != 0;
}
