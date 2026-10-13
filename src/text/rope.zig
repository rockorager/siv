//! A text's bytes as a persistent rope (D15): a height-balanced (AVL)
//! tree of immutable leaves of up to `leaf_max` bytes, shared by
//! reference count between a text and the texts edits made from it. An
//! edit copies the leaves it touches and the path to them, and shares the
//! rest: it costs the edit plus the log of the text's size, and the text
//! before it stays valid (for a transaction to restore, or for comparing).
//! A text of up to `leaf_max` bytes is one leaf, so `flat` gives it whole.
//!
//! Comparing two ropes made from one another skips the subtrees they
//! share (`commonPrefix`, `commonSuffix`), so finding what an edit
//! changed costs the change, not the text.
//!
//! References are not atomic: one thread owns a rope and the ropes made
//! from it.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const leaf_max = 4096;

/// Deep enough for any text below 4 GiB (AVL height < 1.44 log2 of the
/// leaves, plus slack).
const max_height = 64;

const Node = struct {
    refs: u32 = 1,
    height: u8,
    len: usize,
    /// Leaves: their bytes, owned. Internal nodes: empty.
    bytes: []u8 = &.{},
    left: ?*Node = null,
    right: ?*Node = null,

    fn isLeaf(n: *const Node) bool {
        return n.height == 0;
    }

    fn retain(n: *Node) *Node {
        n.refs += 1;
        return n;
    }

    fn release(n: *Node, gpa: Allocator) void {
        var stack: [max_height * 2]*Node = undefined;
        var top: usize = 0;
        stack[0] = n;
        top = 1;
        while (top > 0) {
            top -= 1;
            const x = stack[top];
            x.refs -= 1;
            if (x.refs != 0) continue;
            if (x.isLeaf()) {
                gpa.free(x.bytes);
            } else {
                stack[top] = x.left.?;
                stack[top + 1] = x.right.?;
                top += 2;
            }
            gpa.destroy(x);
        }
    }
};

fn heightOf(n: ?*const Node) i32 {
    return if (n) |x| x.height else -1;
}

fn lenOf(n: ?*const Node) usize {
    return if (n) |x| x.len else 0;
}

pub const Rope = struct {
    root: ?*Node = null,

    pub const empty: Rope = .{};

    /// A rope of a copy of `bytes`.
    pub fn initBytes(gpa: Allocator, bytes: []const u8) Allocator.Error!Rope {
        return .{ .root = try build(gpa, bytes) };
    }

    /// Another reference to the same text.
    pub fn retain(r: Rope) Rope {
        if (r.root) |n| _ = n.retain();
        return r;
    }

    pub fn release(r: Rope, gpa: Allocator) void {
        if (r.root) |n| n.release(gpa);
    }

    pub fn len(r: Rope) usize {
        return lenOf(r.root);
    }

    /// The whole text when it is one leaf (always for texts of up to
    /// `leaf_max` bytes), else null.
    pub fn flat(r: Rope) ?[]const u8 {
        const n = r.root orelse return "";
        return if (n.isLeaf()) n.bytes else null;
    }

    /// Whether two ropes are the same tree (so the same text).
    pub fn same(a: Rope, b: Rope) bool {
        return a.root == b.root;
    }

    pub fn byteAt(r: Rope, i: usize) u8 {
        var n = r.root.?;
        var at = i;
        while (!n.isLeaf()) {
            const l = n.left.?;
            if (at < l.len) {
                n = l;
            } else {
                at -= l.len;
                n = n.right.?;
            }
        }
        return n.bytes[at];
    }

    /// The leaf holding byte `i`: where it starts, and its bytes.
    pub fn leafAt(r: Rope, i: usize) struct { start: usize, bytes: []const u8 } {
        var n = r.root.?;
        var base: usize = 0;
        while (!n.isLeaf()) {
            const l = n.left.?;
            if (i < base + l.len) n = l else {
                base += l.len;
                n = n.right.?;
            }
        }
        return .{ .start = base, .bytes = n.bytes };
    }

    /// Single bytes in any order, a leaf looked up only when the last one
    /// does not hold the byte asked for.
    pub fn reader(r: Rope) Reader {
        return .{ .rope = r };
    }

    pub const Reader = struct {
        rope: Rope,
        start: usize = 0,
        bytes: []const u8 = &.{},

        pub fn at(rd: *Reader, i: usize) u8 {
            if (i < rd.start or i >= rd.start + rd.bytes.len) {
                const l = rd.rope.leafAt(i);
                rd.start = l.start;
                rd.bytes = l.bytes;
            }
            return rd.bytes[i - rd.start];
        }

        /// `i` moved back to the start of its character.
        pub fn charStart(rd: *Reader, i: usize) usize {
            var j = @min(i, rd.rope.len());
            while (j > 0 and j < rd.rope.len() and rd.at(j) & 0xc0 == 0x80) j -= 1;
            return j;
        }
    };

    /// Copies `out.len` bytes from `from` into `out`.
    pub fn read(r: Rope, from: usize, out: []u8) void {
        var it = r.chunks(from, from + out.len);
        var at: usize = 0;
        while (it.next()) |c| {
            @memcpy(out[at..][0..c.len], c);
            at += c.len;
        }
        std.debug.assert(at == out.len);
    }

    /// Bytes `from..to`: a slice of a leaf when they lie in one, else a
    /// copy in `a`.
    pub fn slice(r: Rope, a: Allocator, from: usize, to: usize) Allocator.Error![]const u8 {
        var it = r.chunks(from, to);
        const first = it.next() orelse return "";
        if (first.len == to - from) return first;
        const out = try a.alloc(u8, to - from);
        r.read(from, out);
        return out;
    }

    /// The text in one buffer from `a`.
    pub fn toOwned(r: Rope, a: Allocator) Allocator.Error![]u8 {
        const out = try a.alloc(u8, r.len());
        r.read(0, out);
        return out;
    }

    /// Appends the text's bytes `from..to` to `list`.
    pub fn appendTo(r: Rope, gpa: Allocator, list: *std.ArrayList(u8), from: usize, to: usize) Allocator.Error!void {
        try list.ensureUnusedCapacity(gpa, to - from);
        var it = r.chunks(from, to);
        while (it.next()) |c| list.appendSliceAssumeCapacity(c);
    }

    pub fn eqlBytes(r: Rope, bytes: []const u8) bool {
        if (r.len() != bytes.len) return false;
        var it = r.chunks(0, bytes.len);
        var at: usize = 0;
        while (it.next()) |c| {
            if (!std.mem.eql(u8, c, bytes[at..][0..c.len])) return false;
            at += c.len;
        }
        return true;
    }

    /// The text with `from..to` replaced by `insert`: the leaves holding
    /// `from` and `to` are copied with the change, and everything else is
    /// shared with `r`, which is unchanged.
    pub fn replace(r: Rope, gpa: Allocator, from: usize, to: usize, insert: []const u8) Allocator.Error!Rope {
        const n = r.len();
        std.debug.assert(from <= to and to <= n);
        if (n + insert.len - (to - from) <= leaf_max) {
            // Small texts stay one leaf.
            const bytes = try gpa.alloc(u8, n + insert.len - (to - from));
            errdefer gpa.free(bytes);
            r.read(0, bytes[0..from]);
            @memcpy(bytes[from..][0..insert.len], insert);
            r.read(to, bytes[from + insert.len ..]);
            if (bytes.len == 0) {
                gpa.free(bytes);
                return .empty;
            }
            return .{ .root = try leafOf(gpa, bytes) };
        }
        // Widen to the leaves holding the ends, so no leaf is cut.
        const lo = leafStart(r.root.?, if (from == n) from - 1 else from);
        const hi = if (to == 0) 0 else leafEnd(r.root.?, to - 1);
        const hi_end = @max(hi, to);
        var stack_buf: [leaf_max * 2]u8 = undefined;
        const mid_len = (from - lo) + insert.len + (hi_end - to);
        const mid = if (mid_len <= stack_buf.len) stack_buf[0..mid_len] else try gpa.alloc(u8, mid_len);
        defer if (mid_len > stack_buf.len) gpa.free(mid);
        r.read(lo, mid[0 .. from - lo]);
        @memcpy(mid[from - lo ..][0..insert.len], insert);
        r.read(to, mid[from - lo + insert.len ..]);
        const left = try cut(gpa, r.root, 0, lo);
        const middle = build(gpa, mid) catch |err| {
            if (left) |x| x.release(gpa);
            return err;
        };
        const right = cut(gpa, r.root, hi_end, n) catch |err| {
            if (left) |x| x.release(gpa);
            if (middle) |x| x.release(gpa);
            return err;
        };
        const lm = join(gpa, left, middle) catch |err| {
            if (right) |x| x.release(gpa);
            return err;
        };
        return .{ .root = try join(gpa, lm, right) };
    }

    /// The length of the longest common prefix of two texts, skipping
    /// subtrees they share at the same offset.
    pub fn commonPrefix(a: Rope, b: Rope) usize {
        return common(a, b, .forward);
    }

    /// The length of the longest common suffix of two texts.
    pub fn commonSuffix(a: Rope, b: Rope) usize {
        return common(a, b, .backward);
    }

    const Way = enum { forward, backward };

    /// A frontier: the subtrees covering what is left of a text, nearest
    /// first, the nearest leaf with `used` bytes consumed from its near end.
    const Frontier = struct {
        stack: [max_height + 2]*Node = undefined,
        top: usize = 0,
        used: usize = 0,

        fn init(r: Rope) Frontier {
            var f: Frontier = .{};
            if (r.root) |n| {
                f.stack[0] = n;
                f.top = 1;
            }
            return f;
        }

        fn peek(f: *const Frontier) ?*Node {
            return if (f.top == 0) null else f.stack[f.top - 1];
        }

        fn pop(f: *Frontier) void {
            f.top -= 1;
            f.used = 0;
        }

        /// Replaces the nearest subtree by its children, nearest on top.
        fn expand(f: *Frontier, way: Way) void {
            const n = f.stack[f.top - 1];
            const near = if (way == .forward) n.left.? else n.right.?;
            const far = if (way == .forward) n.right.? else n.left.?;
            f.stack[f.top - 1] = far;
            f.stack[f.top] = near;
            f.top += 1;
        }
    };

    fn common(a: Rope, b: Rope, way: Way) usize {
        var fa: Frontier = .init(a);
        var fb: Frontier = .init(b);
        var done: usize = 0;
        while (true) {
            const x = fa.peek() orelse return done;
            const y = fb.peek() orelse return done;
            if (x == y and fa.used == fb.used) {
                // Shared at the same offset: equal throughout.
                done += x.len - fa.used;
                fa.pop();
                fb.pop();
                continue;
            }
            if (!x.isLeaf() and (y.isLeaf() or x.len >= y.len)) {
                fa.expand(way);
                continue;
            }
            if (!y.isLeaf()) {
                fb.expand(way);
                continue;
            }
            // Two leaves: compare what is left of them.
            const xs = if (way == .forward) x.bytes[fa.used..] else x.bytes[0 .. x.len - fa.used];
            const ys = if (way == .forward) y.bytes[fb.used..] else y.bytes[0 .. y.len - fb.used];
            const k = @min(xs.len, ys.len);
            var i: usize = 0;
            if (way == .forward) {
                while (i < k and xs[i] == ys[i]) i += 1;
            } else {
                while (i < k and xs[xs.len - 1 - i] == ys[ys.len - 1 - i]) i += 1;
            }
            done += i;
            if (i < k) return done;
            fa.used += k;
            fb.used += k;
            if (fa.used == x.len) fa.pop();
            if (fb.used == y.len) fb.pop();
        }
    }

    /// Bytes `from..to` in order, a leaf's worth at a time.
    pub fn chunks(r: Rope, from: usize, to: usize) Chunks {
        var it: Chunks = .{ .at = from, .to = to };
        if (from >= to) return it;
        // The path to the leaf holding `from`; right siblings wait.
        var n = r.root.?;
        var base: usize = 0;
        while (!n.isLeaf()) {
            const l = n.left.?;
            if (from < base + l.len) {
                it.stack[it.top] = n.right.?;
                it.top += 1;
                n = l;
            } else {
                base += l.len;
                n = n.right.?;
            }
        }
        it.leaf = n;
        it.offset = from - base;
        return it;
    }

    pub const Chunks = struct {
        stack: [max_height + 2]*Node = undefined,
        top: usize = 0,
        leaf: ?*Node = null,
        offset: usize = 0,
        at: usize,
        to: usize,

        pub fn next(it: *Chunks) ?[]const u8 {
            if (it.at >= it.to) return null;
            const leaf = it.leaf orelse {
                // The next leaf: leftmost of the nearest waiting subtree.
                var n = it.stack[it.top - 1];
                it.top -= 1;
                while (!n.isLeaf()) {
                    it.stack[it.top] = n.right.?;
                    it.top += 1;
                    n = n.left.?;
                }
                it.leaf = n;
                it.offset = 0;
                return it.next();
            };
            const c = leaf.bytes[it.offset..@min(leaf.len, it.offset + (it.to - it.at))];
            it.at += c.len;
            it.leaf = null;
            return c;
        }
    };

    /// Checks the tree's invariants (for tests).
    pub fn check(r: Rope) !void {
        if (r.root) |n| _ = try checkNode(n);
    }

    fn checkNode(n: *const Node) !usize {
        if (n.isLeaf()) {
            if (n.len != n.bytes.len or n.len == 0 or n.len > leaf_max) return error.BadLeaf;
            return n.len;
        }
        const l = try checkNode(n.left.?);
        const rr = try checkNode(n.right.?);
        if (l + rr != n.len) return error.BadLength;
        const hl = heightOf(n.left);
        const hr = heightOf(n.right);
        if (@abs(hl - hr) > 1 or n.height != @max(hl, hr) + 1) return error.Unbalanced;
        return n.len;
    }
};

fn leafOf(gpa: Allocator, owned: []u8) Allocator.Error!*Node {
    const n = try gpa.create(Node);
    n.* = .{ .height = 0, .len = owned.len, .bytes = owned };
    return n;
}

fn set(n: *Node, l: *Node, r: *Node) *Node {
    n.* = .{ .height = @intCast(@max(l.height, r.height) + 1), .len = l.len + r.len, .left = l, .right = r };
    return n;
}

/// A new internal node over `l` and `r`, taking their references (and
/// dropping them if it fails).
fn node(gpa: Allocator, l: *Node, r: *Node) Allocator.Error!*Node {
    const n = gpa.create(Node) catch |err| {
        l.release(gpa);
        r.release(gpa);
        return err;
    };
    return set(n, l, r);
}

/// A balanced tree of leaves holding a copy of `bytes` (null if empty).
fn build(gpa: Allocator, bytes: []const u8) Allocator.Error!?*Node {
    if (bytes.len == 0) return null;
    const leaves = (bytes.len + leaf_max - 1) / leaf_max;
    return try buildRange(gpa, bytes, 0, leaves, leaves);
}

/// Leaves `first..end` of `count` even pieces of `bytes`.
fn buildRange(gpa: Allocator, bytes: []const u8, first: usize, end: usize, count: usize) Allocator.Error!*Node {
    if (end - first == 1) {
        const s = bytes.len * first / count;
        const e = bytes.len * end / count;
        const owned = try gpa.dupe(u8, bytes[s..e]);
        errdefer gpa.free(owned);
        return leafOf(gpa, owned);
    }
    const mid = first + (end - first) / 2;
    const l = try buildRange(gpa, bytes, first, mid, count);
    const r = buildRange(gpa, bytes, mid, end, count) catch |err| {
        l.release(gpa);
        return err;
    };
    return node(gpa, l, r);
}

/// The leaf holding byte `i`: its start and end.
fn leafAround(root: *const Node, i: usize) [2]usize {
    var n = root;
    var base: usize = 0;
    while (!n.isLeaf()) {
        const l = n.left.?;
        if (i < base + l.len) n = l else {
            base += l.len;
            n = n.right.?;
        }
    }
    return .{ base, base + n.len };
}

fn leafStart(root: *const Node, i: usize) usize {
    return leafAround(root, i)[0];
}

fn leafEnd(root: *const Node, i: usize) usize {
    return leafAround(root, i)[1];
}

/// Bytes `from..to` of `n` as a new reference (leaves cut by the range
/// are copied).
fn cut(gpa: Allocator, n_: ?*Node, from: usize, to: usize) Allocator.Error!?*Node {
    const n = n_ orelse return null;
    if (from >= to) return null;
    if (from == 0 and to == n.len) return n.retain();
    if (n.isLeaf()) {
        const owned = try gpa.dupe(u8, n.bytes[from..to]);
        errdefer gpa.free(owned);
        return try leafOf(gpa, owned);
    }
    const l = n.left.?;
    if (to <= l.len) return cut(gpa, l, from, to);
    if (from >= l.len) return cut(gpa, n.right.?, from - l.len, to - l.len);
    const a = try cut(gpa, l, from, l.len);
    const b = cut(gpa, n.right.?, 0, to - l.len) catch |err| {
        if (a) |x| x.release(gpa);
        return err;
    };
    return join(gpa, a, b);
}

/// `a` then `b`, balanced, taking both references (and dropping them if
/// it fails).
fn join(gpa: Allocator, a_: ?*Node, b_: ?*Node) Allocator.Error!?*Node {
    const a = a_ orelse return b_;
    const b = b_ orelse return a;
    const ha: i32 = a.height;
    const hb: i32 = b.height;
    if (@abs(ha - hb) <= 1) return try node(gpa, a, b);
    if (ha > hb) {
        // Down a's right spine to where b fits.
        const r = join(gpa, a.right.?.retain(), b) catch |err| {
            a.release(gpa);
            return err;
        };
        const result = balanced(gpa, a.left.?.retain(), r.?) catch |err| {
            a.release(gpa);
            return err;
        };
        a.release(gpa);
        return result;
    }
    const l = join(gpa, a, b.left.?.retain()) catch |err| {
        b.release(gpa);
        return err;
    };
    const result = balanced(gpa, l.?, b.right.?.retain()) catch |err| {
        b.release(gpa);
        return err;
    };
    b.release(gpa);
    return result;
}

/// A node over `l` and `r`, rotated if their heights differ by two;
/// takes their references (and drops them if it fails).
fn balanced(gpa: Allocator, l: *Node, r: *Node) Allocator.Error!*Node {
    const hl: i32 = l.height;
    const hr: i32 = r.height;
    // Every node first, so that nothing fails halfway.
    var spare: [3]*Node = undefined;
    var got: usize = 0;
    const need: usize = if (@abs(hl - hr) == 2) 3 else 1;
    errdefer {
        for (spare[0..got]) |x| gpa.destroy(x);
        l.release(gpa);
        r.release(gpa);
    }
    while (got < need) : (got += 1) spare[got] = try gpa.create(Node);
    if (hr - hl == 2) {
        // Right heavy: rotate left (after rotating r right if its left is
        // the taller).
        const rl = r.left.?;
        const rr = r.right.?;
        if (rl.height > rr.height) {
            const x = set(spare[0], l, rl.left.?.retain());
            const y = set(spare[1], rl.right.?.retain(), rr.retain());
            const top = set(spare[2], x, y);
            r.release(gpa);
            return top;
        }
        const x = set(spare[0], l, rl.retain());
        const top = set(spare[1], x, rr.retain());
        gpa.destroy(spare[2]);
        r.release(gpa);
        return top;
    }
    if (hl - hr == 2) {
        const ll = l.left.?;
        const lr = l.right.?;
        if (lr.height > ll.height) {
            const x = set(spare[0], ll.retain(), lr.left.?.retain());
            const y = set(spare[1], lr.right.?.retain(), r);
            const top = set(spare[2], x, y);
            l.release(gpa);
            return top;
        }
        const y = set(spare[0], lr.retain(), r);
        const top = set(spare[1], ll.retain(), y);
        gpa.destroy(spare[2]);
        l.release(gpa);
        return top;
    }
    return set(spare[0], l, r);
}

// Tests ----------------------------------------------------------------------------

test "edits, reads, and comparisons agree with a flat buffer, and old texts stay" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(5);
    const rand = prng.random();
    for (0..40) |round| {
        var flat: std.ArrayList(u8) = .empty;
        defer flat.deinit(gpa);
        const start_len = rand.uintLessThan(usize, if (round % 4 == 0) 200_000 else 20_000);
        for (0..start_len) |i| try flat.append(gpa, 'a' + @as(u8, @intCast((i * 7 + round) % 26)));
        var r = try Rope.initBytes(gpa, flat.items);
        defer r.release(gpa);
        try r.check();
        try std.testing.expect(r.eqlBytes(flat.items));
        for (0..60) |_| {
            const n = flat.items.len;
            const from = rand.uintAtMost(usize, n);
            const to = @min(n, from + switch (rand.uintLessThan(u8, 4)) {
                0 => 0,
                1 => rand.uintLessThan(usize, 4),
                2 => rand.uintLessThan(usize, 10_000),
                else => rand.uintLessThan(usize, 100),
            });
            var insert: [9000]u8 = undefined;
            const ins_len = switch (rand.uintLessThan(u8, 5)) {
                0 => 0,
                1 => rand.uintLessThan(usize, 9000),
                else => rand.uintLessThan(usize, 5),
            };
            for (insert[0..ins_len]) |*c| c.* = 'A' + rand.uintLessThan(u8, 26);
            const next = try r.replace(gpa, from, to, insert[0..ins_len]);
            defer next.release(gpa);
            try next.check();
            var expect: std.ArrayList(u8) = .empty;
            defer expect.deinit(gpa);
            try expect.appendSlice(gpa, flat.items[0..from]);
            try expect.appendSlice(gpa, insert[0..ins_len]);
            try expect.appendSlice(gpa, flat.items[to..]);
            try std.testing.expect(next.eqlBytes(expect.items));
            // The old text is unchanged.
            try std.testing.expect(r.eqlBytes(flat.items));
            // Prefix and suffix against the naive ones.
            const m = @min(flat.items.len, expect.items.len);
            var p: usize = 0;
            while (p < m and flat.items[p] == expect.items[p]) p += 1;
            var s: usize = 0;
            while (s < m and flat.items[flat.items.len - 1 - s] == expect.items[expect.items.len - 1 - s]) s += 1;
            try std.testing.expectEqual(p, Rope.commonPrefix(r, next));
            try std.testing.expectEqual(s, Rope.commonSuffix(r, next));
            try std.testing.expectEqual(p, Rope.commonPrefix(next, r));
            // Reads and single bytes.
            if (expect.items.len > 0) {
                const a = rand.uintLessThan(usize, expect.items.len);
                const b = @min(expect.items.len, a + rand.uintLessThan(usize, 10_000));
                const got = try next.slice(gpa, a, b);
                defer if (!inLeaf(next, a, b)) gpa.free(got);
                try std.testing.expectEqualStrings(expect.items[a..b], got);
                try std.testing.expectEqual(expect.items[a], next.byteAt(a));
            }
            if (expect.items.len <= leaf_max) try std.testing.expectEqualStrings(expect.items, next.flat().?);
            // Carry on from the new text.
            r.release(gpa);
            r = next.retain();
            flat.clearRetainingCapacity();
            try flat.appendSlice(gpa, expect.items);
        }
    }
}

fn inLeaf(r: Rope, a: usize, b: usize) bool {
    var it = r.chunks(a, b);
    const first = it.next() orelse return true;
    return first.len == b - a;
}

test "an edit shares all but the path to it" {
    const gpa = std.testing.allocator;
    var counting = std.heap.DebugAllocator(.{ .enable_memory_limit = true }){};
    defer _ = counting.deinit();
    const a = counting.allocator();
    const big = try gpa.alloc(u8, 10 << 20);
    defer gpa.free(big);
    @memset(big, 'x');
    const r = try Rope.initBytes(a, big);
    defer r.release(a);
    const before = counting.total_requested_bytes;
    const next = try r.replace(a, 5 << 20, 5 << 20, "typed");
    defer next.release(a);
    // A leaf or two and a path of nodes, not megabytes.
    try std.testing.expect(counting.total_requested_bytes - before < 4 * leaf_max + max_height * 2 * @sizeOf(Node));
    try std.testing.expectEqual(@as(usize, 5 << 20), Rope.commonPrefix(r, next));
    try std.testing.expectEqual(@as(usize, 5 << 20), Rope.commonSuffix(r, next));
}
