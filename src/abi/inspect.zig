//! Exports for inspectors (D46): what a node is and its properties as
//! text, the accessible name, picking, a window's counters, the hook and
//! overlays an inspector sets on the window it inspects, and siv's own
//! inspector window, which Ctrl+Shift+I opens when the application or
//! SIV_INSPECTOR enables it. The inspector itself is a stock widget
//! (src/widgets/inspector.zig) on these exports.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const scene = @import("scene");
const compositor = @import("compositor");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");
const widgets = @import("widgets");

const App = application.App;
const Window = application.Window;
const Error = application.Error;
const NodeId = ui.NodeId;
const wrap = application.wrap;
const Writer = std.Io.Writer;
const window_tag = application.window_tag;

// Node information ------------------------------------------------------------

pub export fn siv_node_get_info(node: t.Node, info: ?*t.NodeInfo) t.Result {
    return wrap(struct {
        fn f(n: t.Node, o: ?*t.NodeInfo) Error!void {
            const w, const id = try tree.lookup(n);
            const dest = try runtime.out(t.NodeInfo, o);
            const uw = w.uiWin();
            const un = uw.node(id);
            const s = uw.state(id);
            const border, const content = ui.inspect.boxes(uw, id);
            var children: u32 = 0;
            var it = uw.children(id);
            while (it.next()) |_| children += 1;
            const accessible = (try semanticsNode(uw, id)) != null;
            dest.* = .{
                .kind = @enumFromInt(@intFromEnum(un.kind)),
                .role = @enumFromInt(@as(i32, @intFromEnum(un.role())) + 1),
                .flags = .{
                    .hidden = un.isHidden(),
                    .shown = uw.isShown(id),
                    .focusable = un.canFocus(),
                    .focused = uw.input.focus == id,
                    .disabled = un.semantics.disabled,
                    .layer = uw.paint.ownsLayerNow(uw, id),
                    .theme = un.theme != null,
                    .widget = w.nodes.widgets.contains(id.index()),
                    .accessible = accessible,
                    .rtl = s.rtl,
                },
                .variant = @enumFromInt(@as(i32, @intFromEnum(uw.paletteAt(id).variant)) + 1),
                .rect = rectOf(border),
                .content = rectOf(content),
                .children = children,
                .properties = count(.{ .w = w, .id = id, .n = un }),
            };
        }
    }.f(node, info));
}

fn rectOf(r: @import("raster").Rect) t.Rect {
    return .{ .x = r.x0, .y = r.y0, .width = r.x1 - r.x0, .height = r.y1 - r.y0 };
}

/// The node in the semantics tree, or null when it is left out.
fn semanticsNode(uw: *ui.Window, id: NodeId) Error!?*const ui.semantics.Node {
    const st = try uw.semanticsTree();
    for (st.nodes.items) |*sn| if (sn.node == id and sn.virtual == 0) return sn;
    return null;
}

pub export fn siv_node_get_name(node: t.Node, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return wrap(struct {
        fn f(n: t.Node, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const w, const id = try tree.lookup(n);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const uw = w.uiWin();
            const sn = try semanticsNode(uw, id);
            const s = if (sn) |x| (try uw.semanticsTree()).name(x.*) else "";
            copyOut(s, buf, dest);
        }
    }.f(node, buffer, buffer_cap, len));
}

fn copyOut(s: []const u8, buf: []u8, len: *usize) void {
    const k = @min(s.len, buf.len);
    @memcpy(buf[0..k], s[0..k]);
    len.* = s.len;
}

pub export fn siv_window_get_node_at(window: t.Window, x: f32, y: f32) t.Node {
    const w = App.window(@backingInt(window), window_tag) catch return .null;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return .null;
    const id = ui.inspect.nodeAt(w.uiWin(), .{ .x = x, .y = y });
    return @fromBackingInt(w.nodes.handle(id));
}

// Properties --------------------------------------------------------------------

/// The node a property reads, in the window that has it. `n` may be a
/// new node of the same kind, to find what the application set.
const Ctx = struct {
    w: *Window,
    id: NodeId,
    n: *const ui.Node,

    fn uw(c: Ctx) *ui.Window {
        return c.w.uiWin();
    }

    fn parentKind(c: Ctx) ?ui.Kind {
        const p = c.uw().node(c.id).parent;
        return if (p == .none) null else c.uw().node(p).kind;
    }

    fn ut(c: Ctx) *ui.Txn {
        return c.w.txn.ut;
    }
};

const When = enum { always, flex_child, grid_child, stack_child, flex, grid, stack, scroll, image, canvas, external, sized, editor, text, themed };

const Prop = struct {
    name: []const u8,
    group: t.PropertyGroup,
    type: t.PropertyType,
    when: When = .always,
    get: *const fn (Ctx, *Writer) Writer.Error!void,
    set: ?*const fn (Ctx, []const u8) Error!void = null,
    /// Read from the window rather than the node: never marked set.
    derived: bool = false,

    fn applies(p: Prop, c: Ctx) bool {
        const k = c.n.kind;
        return switch (p.when) {
            .always => true,
            .flex_child => c.parentKind() == .flex,
            .grid_child => c.parentKind() == .grid,
            .stack_child => c.parentKind() == .stack,
            .flex => k == .flex,
            .grid => k == .grid,
            .stack => k == .stack,
            .scroll => k == .scroll,
            .image => k == .image,
            .canvas => k == .canvas,
            .external => k == .external,
            .sized => k == .canvas or k == .external,
            .editor => k == .editor,
            .text => k == .text or k == .editor,
            .themed => c.n.theme != null,
        };
    }
};

fn count(c: Ctx) u32 {
    var k: u32 = 0;
    for (props) |p| {
        if (p.applies(c)) k += 1;
    }
    return k;
}

fn nth(c: Ctx, index: u32) ?*const Prop {
    var k: u32 = 0;
    for (&props) |*p| if (p.applies(c)) {
        if (k == index) return p;
        k += 1;
    };
    return null;
}

/// A new node of the same kind, as `Node.data` defaults it.
fn fresh(kind: ui.Kind) ui.Node {
    return .{ .kind = kind, .data = .default(kind) };
}

fn propertyAt(node: t.Node, index: u32) Error!struct { Ctx, *const Prop } {
    const w, const id = try tree.lookup(node);
    const c: Ctx = .{ .w = w, .id = id, .n = w.uiWin().node(id) };
    return .{ c, nth(c, index) orelse return error.InvalidArgument };
}

/// A property's value as text, in memory from the application's
/// allocator; the caller frees it.
fn format(gpa: std.mem.Allocator, c: Ctx, p: *const Prop) Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    p.get(c, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

pub export fn siv_node_get_property(node: t.Node, index: u32, property: ?*t.Property) t.Result {
    return wrap(struct {
        fn f(n: t.Node, i: u32, o: ?*t.Property) Error!void {
            const c, const p = try propertyAt(n, i);
            const dest = try runtime.out(t.Property, o);
            var set = false;
            if (!p.derived) {
                const gpa = c.w.owner.gpa();
                const def = fresh(c.n.kind);
                const dc: Ctx = .{ .w = c.w, .id = c.id, .n = &def };
                // What a new node lacks (a subtree theme) was set.
                set = !p.applies(dc);
                if (!set) {
                    const a = try format(gpa, c, p);
                    defer gpa.free(a);
                    const b = try format(gpa, dc, p);
                    defer gpa.free(b);
                    set = !std.mem.eql(u8, a, b);
                }
            }
            dest.* = .{ .group = p.group, .type = p.type, .flags = .{ .editable = p.set != null, .set = set } };
        }
    }.f(node, index, property));
}

pub export fn siv_node_get_property_name(node: t.Node, index: u32, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return wrap(struct {
        fn f(n: t.Node, i: u32, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            _, const p = try propertyAt(n, i);
            copyOut(p.name, try runtime.buffer(ptr, cap), try runtime.out(usize, out));
        }
    }.f(node, index, buffer, buffer_cap, len));
}

pub export fn siv_node_get_property_value(node: t.Node, index: u32, buffer: ?[*]u8, buffer_cap: usize, len: ?*usize) t.Result {
    return wrap(struct {
        fn f(n: t.Node, i: u32, ptr: ?[*]u8, cap: usize, out: ?*usize) Error!void {
            const c, const p = try propertyAt(n, i);
            const buf = try runtime.buffer(ptr, cap);
            const dest = try runtime.out(usize, out);
            const gpa = c.w.owner.gpa();
            const s = try format(gpa, c, p);
            defer gpa.free(s);
            copyOut(s, buf, dest);
        }
    }.f(node, index, buffer, buffer_cap, len));
}

pub export fn siv_set_property(txn: t.Txn, node: t.Node, name: ?[*]const u8, name_len: usize, value: ?[*]const u8, value_len: usize) void {
    _ = tree.run(txn, struct {
        fn f(w: *Window, n: t.Node, np: ?[*]const u8, nl: usize, vp: ?[*]const u8, vl: usize) Error!void {
            const id = try tree.nodeIn(w, n);
            const pname = try runtime.string(np, nl);
            const v = try runtime.string(vp, vl);
            const c: Ctx = .{ .w = w, .id = id, .n = w.uiWin().node(id) };
            for (&props) |*p| {
                if (!std.mem.eql(u8, p.name, pname) or !p.applies(c)) continue;
                const set = p.set orelse return error.Unsupported;
                return set(c, v);
            }
            return error.Unsupported;
        }
    }.f, .{ node, name, name_len, value, value_len });
}

// Formatting and parsing ------------------------------------------------------------

fn num(wr: *Writer, v: f32) Writer.Error!void {
    if (std.math.isInf(v)) return wr.writeAll("none");
    try wr.print("{d}", .{v});
}

fn parseNum(s: []const u8) Error!f32 {
    const x = std.mem.trim(u8, s, " \t");
    const v = std.fmt.parseFloat(f32, if (std.mem.endsWith(u8, x, "px")) x[0 .. x.len - 2] else x) catch return error.InvalidArgument;
    if (!std.math.isFinite(v)) return error.InvalidArgument;
    return v;
}

/// A maximum: a number, or none for no maximum.
fn parseMax(s: []const u8) Error!f32 {
    if (std.mem.eql(u8, std.mem.trim(u8, s, " \t"), "none")) return std.math.inf(f32);
    return parseNum(s);
}

fn parseInt(comptime T: type, s: []const u8) Error!T {
    return std.fmt.parseInt(T, std.mem.trim(u8, s, " \t"), 10) catch error.InvalidArgument;
}

fn length(wr: *Writer, d: ui.Dimension) Writer.Error!void {
    switch (d) {
        .auto => try wr.writeAll("auto"),
        .px => |v| try num(wr, v),
        .fraction => |v| try wr.print("{d}%", .{v * 100}),
    }
}

fn parseLength(s: []const u8) Error!ui.Dimension {
    const x = std.mem.trim(u8, s, " \t");
    if (std.mem.eql(u8, x, "auto")) return .auto;
    if (std.mem.endsWith(u8, x, "%")) return .{ .fraction = try parseNum(x[0 .. x.len - 1]) / 100 };
    return .{ .px = try parseNum(x) };
}

fn boolean(wr: *Writer, v: bool) Writer.Error!void {
    try wr.writeAll(if (v) "true" else "false");
}

fn parseBool(s: []const u8) Error!bool {
    const x = std.mem.trim(u8, s, " \t");
    for ([_][]const u8{ "true", "yes", "on", "1" }) |y| if (std.ascii.eqlIgnoreCase(x, y)) return true;
    for ([_][]const u8{ "false", "no", "off", "0" }) |y| if (std.ascii.eqlIgnoreCase(x, y)) return false;
    return error.InvalidArgument;
}

fn choice(wr: *Writer, v: anytype) Writer.Error!void {
    try wr.writeAll(@tagName(v));
}

fn parseChoice(comptime E: type, s: []const u8) Error!E {
    return std.meta.stringToEnum(E, std.mem.trim(u8, s, " \t")) orelse error.InvalidArgument;
}

/// Up to four numbers, as CSS shortens edges: one for all, two for
/// vertical and horizontal, three for top, horizontal, and bottom.
fn parseFour(s: []const u8) Error![4]f32 {
    var vs: [4]f32 = undefined;
    var k: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t,");
    while (it.next()) |tok| {
        if (k == 4) return error.InvalidArgument;
        vs[k] = try parseNum(tok);
        k += 1;
    }
    return switch (k) {
        1 => @splat(vs[0]),
        2 => .{ vs[0], vs[1], vs[0], vs[1] },
        3 => .{ vs[0], vs[1], vs[2], vs[1] },
        4 => vs,
        else => error.InvalidArgument,
    };
}

/// Edges as CSS orders them (top, end, bottom, start), shortened.
fn edges(wr: *Writer, e: ui.Edges) Writer.Error!void {
    if (e.top == e.bottom and e.start == e.end) {
        if (e.top == e.start) return num(wr, e.top);
        return wr.print("{d} {d}", .{ e.top, e.start });
    }
    if (e.start == e.end) return wr.print("{d} {d} {d}", .{ e.top, e.start, e.bottom });
    try wr.print("{d} {d} {d} {d}", .{ e.top, e.end, e.bottom, e.start });
}

fn parseEdges(s: []const u8) Error!ui.Edges {
    const v = try parseFour(s);
    return .{ .top = v[0], .end = v[1], .bottom = v[2], .start = v[3] };
}

fn hex(wr: *Writer, c: scene.Color) Writer.Error!void {
    const ch = struct {
        fn f(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.f;
    try wr.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ ch(scene.linearToSrgb(c.r)), ch(scene.linearToSrgb(c.g)), ch(scene.linearToSrgb(c.b)), ch(c.a) });
}

/// A themed color as its token and what it resolves to at the node, a
/// literal one as #rrggbbaa, a transparent one as none.
fn color(wr: *Writer, cx: Ctx, literal: scene.Color, token: ui.ColorToken) Writer.Error!void {
    if (token != .none) {
        try wr.print("{s} ", .{@tagName(token)});
        return hex(wr, cx.uw().paletteAt(cx.id).color(token));
    }
    if (literal.a == 0) return wr.writeAll("none");
    try hex(wr, literal);
}

const ColorValue = struct { color: scene.Color = .transparent, token: ui.ColorToken = .none };

/// none, #rgb, #rrggbb, #rrggbbaa, or a token's name (with what it
/// resolved to after it, as `color` writes it).
fn parseColor(s: []const u8) Error!ColorValue {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const first = it.next() orelse return error.InvalidArgument;
    if (std.mem.eql(u8, first, "none") or std.mem.eql(u8, first, "transparent")) return .{};
    if (first[0] != '#') {
        const tok = std.meta.stringToEnum(ui.ColorToken, first) orelse return error.InvalidArgument;
        return .{ .token = tok };
    }
    const h = first[1..];
    var b: [4]u8 = .{ 0, 0, 0, 255 };
    switch (h.len) {
        3 => for (0..3) |i| {
            const v = std.fmt.parseInt(u8, h[i .. i + 1], 16) catch return error.InvalidArgument;
            b[i] = v * 17;
        },
        6, 8 => for (0..h.len / 2) |i| {
            b[i] = std.fmt.parseInt(u8, h[2 * i .. 2 * i + 2], 16) catch return error.InvalidArgument;
        },
        else => return error.InvalidArgument,
    }
    if (it.next() != null) return error.InvalidArgument;
    return .{ .color = .srgb8(b[0], b[1], b[2], b[3]) };
}

fn txnErr(err: ui.TxnError) Error {
    return tree.mapTxn(err);
}

// Setters of whole groups ------------------------------------------------------------

fn putLayout(c: Ctx, l: ui.Layout) Error!void {
    c.ut().setLayout(c.id, l) catch |e| return txnErr(e);
}

fn putVisual(c: Ctx, v: ui.Visual) Error!void {
    c.ut().setVisual(c.id, v) catch |e| return txnErr(e);
}

fn putSemantics(c: Ctx, s: ui.Semantics) Error!void {
    c.ut().setSemantics(c.id, s) catch |e| return txnErr(e);
}

fn putText(c: Ctx, p: ui.Text) Error!void {
    c.ut().setTextProps(c.id, p) catch |e| return txnErr(e);
}

fn putFlex(c: Ctx, f: ui.Flex) Error!void {
    c.ut().setFlex(c.id, f) catch |e| return txnErr(e);
}

fn putScroll(c: Ctx, s: ui.Scroll) Error!void {
    c.ut().setScroll(c.id, s) catch |e| return txnErr(e);
}

fn textProps(n: *const ui.Node) *const ui.Text {
    return &n.textData().props;
}

// The properties ----------------------------------------------------------------

/// A layout field written and read as `kind`: length, number, max, or
/// choice.
fn layoutField(comptime name: []const u8, comptime field: []const u8, comptime kind: enum { length, number, max, choice }, comptime when: When) Prop {
    const S = struct {
        fn get(c: Ctx, wr: *Writer) Writer.Error!void {
            const v = @field(c.n.layout, field);
            switch (kind) {
                .length => try length(wr, v),
                .number, .max => try num(wr, v),
                .choice => try choice(wr, v),
            }
        }
        fn set(c: Ctx, s: []const u8) Error!void {
            var l = c.n.layout;
            @field(l, field) = switch (kind) {
                .length => try parseLength(s),
                .number => try parseNum(s),
                .max => try parseMax(s),
                .choice => try parseChoice(@FieldType(ui.Layout, field), s),
            };
            try putLayout(c, l);
        }
    };
    return .{ .name = name, .group = .layout, .type = switch (kind) {
        .length => .length,
        .number, .max => .number,
        .choice => .choice,
    }, .when = when, .get = S.get, .set = S.set };
}

fn visualBool(comptime name: []const u8, comptime field: []const u8, comptime invert: bool) Prop {
    const S = struct {
        fn get(c: Ctx, wr: *Writer) Writer.Error!void {
            try boolean(wr, @field(c.n.visual, field) != invert);
        }
        fn set(c: Ctx, s: []const u8) Error!void {
            var v = c.n.visual;
            @field(v, field) = (try parseBool(s)) != invert;
            try putVisual(c, v);
        }
    };
    return .{ .name = name, .group = .visual, .type = .bool, .get = S.get, .set = S.set };
}

/// A semantics field: a toggle, number, bool, or choice.
fn semanticsField(comptime name: []const u8, comptime field: []const u8, comptime ty: t.PropertyType) Prop {
    const S = struct {
        fn get(c: Ctx, wr: *Writer) Writer.Error!void {
            const v = @field(c.n.semantics, field);
            switch (ty) {
                .number => try wr.print("{d}", .{v}),
                .bool => try boolean(wr, v),
                .choice => try choice(wr, v),
                .text => try wr.writeAll(v),
                else => unreachable,
            }
        }
        fn set(c: Ctx, s: []const u8) Error!void {
            var sem = c.n.semantics;
            const F = @FieldType(ui.Semantics, field);
            @field(sem, field) = switch (ty) {
                .number => try parseInt(F, s),
                .bool => try parseBool(s),
                .choice => try parseChoice(F, s),
                .text => s,
                else => unreachable,
            };
            try putSemantics(c, sem);
        }
    };
    return .{ .name = name, .group = .semantics, .type = ty, .get = S.get, .set = S.set };
}

/// A text style or paragraph field of a text or editor node.
fn textField(comptime name: []const u8, comptime ty: t.PropertyType, comptime path: []const u8) Prop {
    const S = struct {
        fn ptr(p: anytype) switch (@TypeOf(p)) {
            *ui.Text => *@FieldType(@FieldType(ui.Text, "style"), path),
            else => *const @FieldType(@FieldType(ui.Text, "style"), path),
        } {
            return &@field(p.style, path);
        }
        fn get(c: Ctx, wr: *Writer) Writer.Error!void {
            const v = ptr(textProps(c.n)).*;
            switch (ty) {
                .number => try num(wr, v),
                .choice => try choice(wr, v),
                .text => try wr.writeAll(v),
                else => unreachable,
            }
        }
        fn set(c: Ctx, s: []const u8) Error!void {
            var p = textProps(c.n).*;
            const F = @FieldType(@FieldType(ui.Text, "style"), path);
            ptr(&p).* = switch (ty) {
                .number => try parseNum(s),
                .choice => try parseChoice(F, s),
                .text => s,
                else => unreachable,
            };
            try putText(c, p);
        }
    };
    return .{ .name = name, .group = .text, .type = ty, .when = .text, .get = S.get, .set = S.set };
}

/// A text node's own field (alignment, wrapping, lines).
fn textOwn(comptime name: []const u8, comptime ty: t.PropertyType, comptime field: []const u8) Prop {
    const S = struct {
        fn get(c: Ctx, wr: *Writer) Writer.Error!void {
            const v = @field(textProps(c.n).*, field);
            switch (ty) {
                .number => try wr.print("{d}", .{v}),
                .bool => try boolean(wr, v),
                .choice => try choice(wr, v),
                else => unreachable,
            }
        }
        fn set(c: Ctx, s: []const u8) Error!void {
            var p = textProps(c.n).*;
            const F = @FieldType(ui.Text, field);
            @field(p, field) = switch (ty) {
                .number => try parseInt(F, s),
                .bool => try parseBool(s),
                .choice => try parseChoice(F, s),
                else => unreachable,
            };
            try putText(c, p);
        }
    };
    return .{ .name = name, .group = .text, .type = ty, .when = .text, .get = S.get, .set = S.set };
}

fn flexField(comptime name: []const u8, comptime ty: t.PropertyType, comptime field: []const u8) Prop {
    const S = struct {
        fn get(c: Ctx, wr: *Writer) Writer.Error!void {
            const v = @field(c.n.data.flex, field);
            switch (ty) {
                .number => try num(wr, v),
                .bool => try boolean(wr, v),
                .choice => try choice(wr, v),
                else => unreachable,
            }
        }
        fn set(c: Ctx, s: []const u8) Error!void {
            var f = c.n.data.flex;
            @field(f, field) = switch (ty) {
                .number => try parseNum(s),
                .bool => try parseBool(s),
                .choice => try parseChoice(@FieldType(ui.Flex, field), s),
                else => unreachable,
            };
            try putFlex(c, f);
        }
    };
    return .{ .name = name, .group = .container, .type = ty, .when = .flex, .get = S.get, .set = S.set };
}

fn readOnly(comptime name: []const u8, comptime group: t.PropertyGroup, comptime ty: t.PropertyType, comptime when: When, comptime get: fn (Ctx, *Writer) Writer.Error!void) Prop {
    return .{ .name = name, .group = group, .type = ty, .when = when, .get = get };
}

fn tracks(wr: *Writer, ts: []const ui.Track) Writer.Error!void {
    if (ts.len == 0) return wr.writeAll("none");
    for (ts, 0..) |tr, i| {
        if (i != 0) try wr.writeByte(' ');
        switch (tr) {
            .auto => try wr.writeAll("auto"),
            .px => |v| try num(wr, v),
            .fr => |v| try wr.print("{d}fr", .{v}),
        }
    }
}

fn size2(wr: *Writer, w: f32, h: f32) Writer.Error!void {
    try wr.print("{d} {d}", .{ w, h });
}

const props = [_]Prop{
    // Layout.
    layoutField("width", "width", .length, .always),
    layoutField("height", "height", .length, .always),
    layoutField("min_width", "min_width", .number, .always),
    layoutField("max_width", "max_width", .max, .always),
    layoutField("min_height", "min_height", .number, .always),
    layoutField("max_height", "max_height", .max, .always),
    .{ .name = "padding", .group = .layout, .type = .number, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try edges(wr, c.n.layout.padding);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var l = c.n.layout;
            l.padding = try parseEdges(s);
            try putLayout(c, l);
        }
    }.f },
    layoutField("direction", "direction", .choice, .always),
    layoutField("align_x", "align_x", .choice, .always),
    layoutField("align_y", "align_y", .choice, .always),
    layoutField("grow", "grow", .number, .flex_child),
    layoutField("shrink", "shrink", .number, .flex_child),
    layoutField("basis", "basis", .length, .flex_child),
    .{ .name = "cell", .group = .layout, .type = .text, .when = .grid_child, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const l = c.n.layout;
            if (l.column) |col| try wr.print("{d}", .{col + 1}) else try wr.writeAll("auto");
            try wr.writeByte(' ');
            if (l.row) |row| try wr.print("{d}", .{row + 1}) else try wr.writeAll("auto");
            if (l.column_span != 1 or l.row_span != 1) try wr.print(" span {d} {d}", .{ l.column_span, l.row_span });
        }
    }.f },
    .{ .name = "inset", .group = .layout, .type = .number, .when = .stack_child, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const i = c.n.layout.inset;
            for ([_]?f32{ i.top, i.end, i.bottom, i.start }, 0..) |v, k| {
                if (k != 0) try wr.writeByte(' ');
                if (v) |x| try num(wr, x) else try wr.writeAll("auto");
            }
        }
    }.f },

    // Container: what the kind arranges or shows.
    flexField("axis", .choice, "axis"),
    flexField("gap", .number, "gap"),
    flexField("justify", .choice, "justify"),
    flexField("align_items", .choice, "align_items"),
    flexField("wrap", .bool, "wrap"),
    readOnly("columns", .container, .text, .grid, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try tracks(wr, c.n.data.grid.columns);
        }
    }.f),
    readOnly("rows", .container, .text, .grid, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try tracks(wr, c.n.data.grid.rows);
        }
    }.f),
    readOnly("gaps", .container, .number, .grid, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try wr.print("{d} {d}", .{ c.n.data.grid.column_gap, c.n.data.grid.row_gap });
        }
    }.f),
    readOnly("items", .container, .choice, .grid, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try wr.print("{s} {s}", .{ @tagName(c.n.data.grid.align_x), @tagName(c.n.data.grid.align_y) });
        }
    }.f),
    readOnly("items", .container, .choice, .stack, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try wr.print("{s} {s}", .{ @tagName(c.n.data.stack.align_x), @tagName(c.n.data.stack.align_y) });
        }
    }.f),
    .{ .name = "axis", .group = .container, .type = .choice, .when = .scroll, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try choice(wr, c.n.data.scroll.axis);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var sc = c.n.data.scroll;
            sc.axis = try parseChoice(ui.ScrollAxis, s);
            try putScroll(c, sc);
        }
    }.f },
    .{ .name = "offset", .group = .container, .type = .number, .when = .scroll, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try size2(wr, c.n.data.scroll.offset.x, c.n.data.scroll.offset.y);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var it = std.mem.tokenizeAny(u8, s, " \t,");
            const x = try parseNum(it.next() orelse return error.InvalidArgument);
            const y = try parseNum(it.next() orelse return error.InvalidArgument);
            if (it.next() != null) return error.InvalidArgument;
            var sc = c.n.data.scroll;
            sc.offset = .{ .x = x, .y = y };
            try putScroll(c, sc);
        }
    }.f },
    .{ .name = "zoom", .group = .container, .type = .number, .when = .scroll, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try num(wr, c.n.data.scroll.zoom);
        }
    }.f },
    .{ .name = "content_size", .group = .container, .type = .number, .when = .scroll, .derived = true, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const s = c.uw().state(c.id).content;
            try size2(wr, s.w, s.h);
        }
    }.f },
    .{ .name = "icon", .group = .container, .type = .text, .when = .image, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try wr.writeAll(c.n.data.image.icon);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var v = c.n.data.image;
            v.icon = s;
            c.ut().setImage(c.id, v) catch |e| return txnErr(e);
        }
    }.f },
    .{ .name = "icon_size", .group = .container, .type = .number, .when = .image, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try num(wr, c.n.data.image.icon_size);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var v = c.n.data.image;
            v.icon_size = try parseNum(s);
            c.ut().setImage(c.id, v) catch |e| return txnErr(e);
        }
    }.f },
    .{ .name = "fit", .group = .container, .type = .choice, .when = .image, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try choice(wr, c.n.data.image.fit);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var v = c.n.data.image;
            v.fit = try parseChoice(ui.Fit, s);
            c.ut().setImage(c.id, v) catch |e| return txnErr(e);
        }
    }.f },
    .{ .name = "image_size", .group = .container, .type = .number, .when = .image, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const sz = (if (c.n.data.image.image) |img| img.logicalSize() else null) orelse return wr.writeAll("none");
            try size2(wr, sz[0], sz[1]);
        }
    }.f },
    .{ .name = "intrinsic_size", .group = .container, .type = .number, .when = .sized, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            switch (c.n.data) {
                .canvas => |cv| try size2(wr, cv.width, cv.height),
                .external => |x| try size2(wr, x.width, x.height),
                else => unreachable,
            }
        }
    }.f },
    .{ .name = "selection", .group = .container, .type = .number, .when = .editor, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const e = c.n.data.editor;
            try wr.print("{d} {d}", .{ e.caret, e.anchor });
        }
    }.f },
    .{ .name = "multiline", .group = .container, .type = .bool, .when = .editor, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try boolean(wr, c.n.data.editor.editor.multiline);
        }
    }.f },
    .{ .name = "masked", .group = .container, .type = .bool, .when = .editor, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try boolean(wr, c.n.data.editor.editor.masked);
        }
    }.f },
    .{ .name = "placeholder", .group = .container, .type = .text, .when = .editor, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try wr.writeAll(c.n.data.editor.placeholder);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            c.ut().setPlaceholder(c.id, s) catch |e| return txnErr(e);
        }
    }.f },

    // Visual.
    .{ .name = "background", .group = .visual, .type = .color, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try color(wr, c, c.n.visual.background, c.n.visual.background_token);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            const cv = try parseColor(s);
            var v = c.n.visual;
            v.background = cv.color;
            v.background_token = cv.token;
            try putVisual(c, v);
        }
    }.f },
    .{ .name = "border_width", .group = .visual, .type = .number, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try num(wr, c.n.visual.border_width);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var v = c.n.visual;
            v.border_width = try parseNum(s);
            try putVisual(c, v);
        }
    }.f },
    .{ .name = "border_color", .group = .visual, .type = .color, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try color(wr, c, c.n.visual.border_color, c.n.visual.border_token);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            const cv = try parseColor(s);
            var v = c.n.visual;
            v.border_color = cv.color;
            v.border_token = cv.token;
            try putVisual(c, v);
        }
    }.f },
    .{ .name = "radius", .group = .visual, .type = .number, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const r = c.n.visual.radius;
            if (r.top_start == r.top_end and r.top_start == r.bottom_end and r.top_start == r.bottom_start) return num(wr, r.top_start);
            try wr.print("{d} {d} {d} {d}", .{ r.top_start, r.top_end, r.bottom_end, r.bottom_start });
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var it = std.mem.tokenizeAny(u8, s, " \t,");
            var vs: [4]f32 = undefined;
            var k: usize = 0;
            while (it.next()) |tok| : (k += 1) {
                if (k == 4) return error.InvalidArgument;
                vs[k] = try parseNum(tok);
                if (vs[k] < 0) return error.InvalidArgument;
            }
            if (k == 1) vs = @splat(vs[0]) else if (k != 4) return error.InvalidArgument;
            var v = c.n.visual;
            v.radius = .{ .top_start = vs[0], .top_end = vs[1], .bottom_end = vs[2], .bottom_start = vs[3] };
            try putVisual(c, v);
        }
    }.f },
    .{ .name = "opacity", .group = .visual, .type = .number, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try num(wr, c.n.visual.opacity);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var v = c.n.visual;
            v.opacity = try parseNum(s);
            if (v.opacity < 0 or v.opacity > 1) return error.InvalidArgument;
            try putVisual(c, v);
        }
    }.f },
    readOnly("transform", .visual, .text, .always, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const tr = c.n.visual.transform;
            if (tr.eql(.identity)) return wr.writeAll("none");
            var first = true;
            if (tr.translate.x != 0 or tr.translate.y != 0) {
                try wr.print("translate({d}, {d})", .{ tr.translate.x, tr.translate.y });
                first = false;
            }
            if (tr.scale.x != 1 or tr.scale.y != 1) {
                try wr.print("{s}scale({d}, {d})", .{ if (first) "" else " ", tr.scale.x, tr.scale.y });
                first = false;
            }
            if (tr.rotate != 0) try wr.print("{s}rotate({d})", .{ if (first) "" else " ", tr.rotate });
        }
    }.f),
    readOnly("shadows", .visual, .text, .always, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const list = c.n.visual.shadowList();
            if (list.len == 0) return wr.writeAll("none");
            for (list, 0..) |sh, i| {
                if (i != 0) try wr.writeAll(", ");
                try wr.print("{d} {d} {d} {d} ", .{ sh.offset_x, sh.offset_y, sh.sigma * 2, sh.spread });
                try color(wr, c, sh.color, sh.color_token);
                if (sh.inset) try wr.writeAll(" inset");
            }
        }
    }.f),
    visualBool("clip", "clip", false),
    visualBool("layer", "layer", false),
    visualBool("hit_test", "hit_test", false),
    visualBool("focus_ring", "focus_ring", false),
    .{ .name = "hidden", .group = .visual, .type = .bool, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try boolean(wr, c.n.isHidden());
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            c.ut().setHidden(c.id, try parseBool(s)) catch |e| return txnErr(e);
        }
    }.f },
    readOnly("motion", .visual, .text, .always, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const m = c.n.visual.motion;
            if (m.duration_ms == 0) return wr.writeAll("none");
            try wr.print("{d} ms {s}", .{ m.duration_ms, @tagName(m.curve) });
            if (m.layout) try wr.writeAll(" layout");
            if (m.enter != null) try wr.writeAll(" enter");
            if (m.exit != null) try wr.writeAll(" exit");
        }
    }.f),
    readOnly("animation", .visual, .text, .always, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const a = c.n.visual.animation;
            if (a.property == .none) return wr.writeAll("none");
            try wr.print("{s} {d} to {d}, {d} ms", .{ @tagName(a.property), a.from, a.to, a.duration_ms });
            if (a.iterations == 0) try wr.writeAll(", repeating") else if (a.iterations != 1) try wr.print(", {d} times", .{a.iterations});
        }
    }.f),
    .{ .name = "cursor", .group = .visual, .type = .choice, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            if (c.n.cursor) |cur| try choice(wr, cur) else try wr.writeAll("inherit");
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            const shape: ?ui.CursorShape = if (std.mem.eql(u8, std.mem.trim(u8, s, " \t"), "inherit")) null else try parseChoice(ui.CursorShape, s);
            c.ut().setCursor(c.id, shape) catch |e| return txnErr(e);
        }
    }.f },
    .{ .name = "tooltip", .group = .visual, .type = .text, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try wr.writeAll(c.n.tooltip);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            c.ut().setTooltip(c.id, s) catch |e| return txnErr(e);
        }
    }.f },

    // Text.
    .{ .name = "text", .group = .text, .type = .text, .when = .text, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            // A masked editor's text is its bullets (D15).
            const rope = c.n.textData().content;
            var buf: [4096]u8 = undefined;
            const total = rope.len();
            const k = @min(total, buf.len);
            rope.read(0, buf[0..k]);
            var end = k;
            if (k < total) {
                while (end > 0 and buf[end - 1] & 0xc0 == 0x80) end -= 1;
                if (end > 0) end -= 1;
            }
            try wr.writeAll(buf[0..end]);
            if (k < total) try wr.writeAll("…");
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            c.ut().setText(c.id, s) catch |e| return txnErr(e);
        }
    }.f },
    textField("family", .text, "family"),
    textField("size", .number, "size"),
    textField("size_role", .choice, "size_role"),
    .{ .name = "weight", .group = .text, .type = .number, .when = .text, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try wr.print("{d}", .{ui.cssWeight(textProps(c.n).style, null)});
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var p = textProps(c.n).*;
            const v = try parseInt(u16, s);
            if (v < 1 or v > 1000) return error.InvalidArgument;
            p.style.weight_value = v;
            try putText(c, p);
        }
    }.f },
    textField("slant", .choice, "slant"),
    textField("stretch", .choice, "width"),
    .{ .name = "color", .group = .text, .type = .color, .when = .text, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const st = textProps(c.n).style;
            try color(wr, c, st.color, st.color_token);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            const cv = try parseColor(s);
            var p = textProps(c.n).*;
            p.style.color = if (cv.token == .none and cv.color.a == 0) .black else cv.color;
            p.style.color_token = cv.token;
            try putText(c, p);
        }
    }.f },
    textField("language", .text, "language"),
    textOwn("alignment", .choice, "alignment"),
    textOwn("wrap", .bool, "wrap"),
    textOwn("max_lines", .number, "max_lines"),
    textOwn("ellipsize", .bool, "ellipsize"),
    textOwn("hyphenate", .bool, "hyphenate"),

    // Semantics.
    .{ .name = "role", .group = .semantics, .type = .choice, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try choice(wr, c.n.role());
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var sem = c.n.semantics;
            sem.role = if (std.mem.eql(u8, std.mem.trim(u8, s, " \t"), "default")) null else try parseChoice(ui.Role, s);
            try putSemantics(c, sem);
        }
    }.f },
    .{ .name = "name", .group = .semantics, .type = .text, .derived = true, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const uw = c.uw();
            const sn = (semanticsNode(uw, c.id) catch return error.WriteFailed) orelse return;
            const st = uw.semanticsTree() catch return error.WriteFailed;
            try wr.writeAll(st.name(sn.*));
        }
    }.f },
    semanticsField("label", "label", .text),
    semanticsField("description", "description", .text),
    semanticsField("focusable", "focusable", .bool),
    semanticsField("disabled", "disabled", .bool),
    semanticsField("checked", "checked", .choice),
    semanticsField("pressed", "pressed", .choice),
    semanticsField("selected", "selected", .choice),
    semanticsField("expanded", "expanded", .choice),
    .{ .name = "value", .group = .semantics, .type = .number, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const r = c.n.semantics.value orelse return wr.writeAll("none");
            try wr.print("{d} {d} {d} {d}", .{ r.now, r.min, r.max, r.step });
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var sem = c.n.semantics;
            if (std.mem.eql(u8, std.mem.trim(u8, s, " \t"), "none")) {
                sem.value = null;
            } else {
                var vs: [4]f64 = .{ 0, 0, 1, 0 };
                var it = std.mem.tokenizeAny(u8, s, " \t,");
                var k: usize = 0;
                while (it.next()) |tok| : (k += 1) {
                    if (k == 4) return error.InvalidArgument;
                    vs[k] = std.fmt.parseFloat(f64, tok) catch return error.InvalidArgument;
                }
                if (k == 0) return error.InvalidArgument;
                sem.value = .{ .now = vs[0], .min = vs[1], .max = vs[2], .step = vs[3] };
            }
            try putSemantics(c, sem);
        }
    }.f },
    semanticsField("value_text", "value_text", .text),
    semanticsField("level", "level", .number),
    semanticsField("position", "position", .number),
    semanticsField("set_size", "set_size", .number),
    semanticsField("row", "row", .number),
    semanticsField("column", "column", .number),
    semanticsField("sort", "sort", .choice),
    semanticsField("current", "current", .choice),
    semanticsField("live", "live", .choice),
    semanticsField("modal", "modal", .bool),

    // The subtree's theme (D43).
    .{ .name = "scheme", .group = .theme, .type = .choice, .when = .themed, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try choice(wr, c.n.theme.?.scheme);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var sc = c.n.theme.?.*;
            sc.scheme = try parseChoice(ui.theme.SubtreeScheme, s);
            c.ut().setTheme(c.id, &sc) catch |e| return txnErr(e);
        }
    }.f },
    .{ .name = "high_contrast", .group = .theme, .type = .bool, .when = .themed, .get = struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            try boolean(wr, c.n.theme.?.high_contrast);
        }
    }.f, .set = struct {
        fn f(c: Ctx, s: []const u8) Error!void {
            var sc = c.n.theme.?.*;
            sc.high_contrast = try parseBool(s);
            c.ut().setTheme(c.id, &sc) catch |e| return txnErr(e);
        }
    }.f },
    readOnly("overrides", .theme, .text, .themed, struct {
        fn f(c: Ctx, wr: *Writer) Writer.Error!void {
            const sc = c.n.theme.?;
            var any = false;
            for (std.enums.values(ui.ColorToken)) |tok| {
                if (tok == .none) continue;
                const i = @intFromEnum(tok);
                const vs = [4]?scene.Color{ sc.overrides[0][i], sc.overrides[1][i], sc.overrides[2][i], sc.overrides[3][i] };
                if (vs[0] == null and vs[1] == null and vs[2] == null and vs[3] == null) continue;
                if (any) try wr.writeAll(", ");
                any = true;
                try wr.writeAll(@tagName(tok));
                const same = for (vs[1..]) |v| {
                    if (v == null or vs[0] == null or !v.?.eql(vs[0].?)) break false;
                } else true;
                if (same) {
                    try wr.writeByte(' ');
                    try hex(wr, vs[0].?);
                    continue;
                }
                for (vs, std.enums.values(ui.theme.Variant)) |v, variant| if (v) |col| {
                    try wr.print(" {s} ", .{@tagName(variant)});
                    try hex(wr, col);
                };
            }
            if (!any) try wr.writeAll("none");
        }
    }.f),
};

// Counters -----------------------------------------------------------------------

/// The compositor's presentation timing of a window.
fn frameStats(w: *Window) Error!compositor.FrameStats {
    const C = struct {
        id: @TypeOf(w.win.id),
        out: compositor.FrameStats = .{},
        fn run(ctx: ?*anyopaque, comp: *compositor.Compositor) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (comp.frameStats(s.id)) |st| s.out = st;
        }
    };
    var cx: C = .{ .id = w.win.id };
    w.owner.app.comp.call(&cx, C.run) catch return error.OutOfMemory;
    return cx.out;
}

pub export fn siv_window_get_stats(window: t.Window, stats: ?*t.WindowStats) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, o: ?*t.WindowStats) Error!void {
            const w = try App.window(@backingInt(wh), window_tag);
            const dest = try runtime.out(t.WindowStats, o);
            const uw = w.uiWin();
            const fs = try frameStats(w);
            var nodes: u32 = 0;
            for (uw.nodes.items) |n| {
                if (n.status == .live) nodes += 1;
            }
            const s = uw.stats;
            dest.* = .{
                .frames = s.frames,
                .layouts = s.layouts,
                .shapes = s.shapes,
                .text_layouts = s.text_layouts,
                .layer_builds = s.layer_builds,
                .tree_changes = s.tree_changes,
                .commits = s.commits,
                .presented = fs.frames,
                .commit_ns = w.commit_ns,
                .present_ns = w.present_ns,
                .nodes = nodes,
                .layers = @intCast(uw.paint.order.items.len),
            };
        }
    }.f(window, stats));
}

pub export fn siv_window_get_frame_time(window: t.Window, index: u32, time_ns: ?*u64) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, i: u32, o: ?*u64) Error!void {
            const w = try App.window(@backingInt(wh), window_tag);
            const dest = try runtime.out(u64, o);
            const fs = try frameStats(w);
            const kept = @min(fs.frames, fs.history.len);
            if (i >= kept) return error.InvalidArgument;
            dest.* = fs.history[@intCast((fs.frames - 1 - i) % fs.history.len)];
        }
    }.f(window, index, time_ns));
}

// The hook and overlays ------------------------------------------------------------

/// An inspector's hook into a window (siv_window_set_inspect_hook).
pub const Hook = struct {
    callback: t.InspectFn,
    destroy: ?t.DestroyFn,
    user_data: ?*anyopaque,
};

pub export fn siv_window_set_inspect_hook(window: t.Window, callback: ?t.InspectFn, destroy: ?t.DestroyFn, user_data: ?*anyopaque) t.Result {
    const w = App.window(@backingInt(window), window_tag) catch |err| {
        if (destroy) |d| d(user_data);
        return t.resultOf(err);
    };
    const self = w.owner;
    const old = w.inspect_hook;
    if (callback) |cb| {
        w.inspect_hook = .{ .callback = cb, .destroy = destroy, .user_data = user_data };
        w.uiWin().inspect.host = .{ .ctx = w, .func = onPick };
    } else {
        w.inspect_hook = null;
        w.uiWin().inspect.host = null;
        self.release(destroy, user_data);
    }
    if (old) |h| self.release(h.destroy, h.user_data);
    return .ok;
}

pub export fn siv_window_set_inspect_overlay(window: t.Window, flags: t.InspectFlags, highlight: t.Node) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, fl_: t.InspectFlags, hl: t.Node) Error!void {
            const w = try App.window(@backingInt(wh), window_tag);
            const fl = try runtime.flags(t.InspectFlags, fl_);
            const id: NodeId = if (hl == .null) .none else try tree.nodeIn(w, hl);
            ui.inspect.set(w.uiWin(), id, .{ .bounds = fl.bounds, .repaints = fl.repaints, .pick = fl.pick });
        }
    }.f(window, flags, highlight));
}

fn onPick(ctx: ?*anyopaque, _: *ui.Window, event: ui.inspect.Event, id: NodeId) void {
    const w: *Window = @ptrCast(@alignCast(ctx));
    if (w.dead) return;
    const node: t.Node = if (id == .none) .null else @fromBackingInt(w.nodes.handle(id));
    call(w, switch (event) {
        .hovered => .hovered,
        .picked => .picked,
    }, node);
}

fn call(w: *Window, kind: t.InspectEventType, node: t.Node) void {
    const h = w.inspect_hook orelse return;
    const self = w.owner;
    self.enter();
    defer self.leave();
    h.callback(h.user_data, @fromBackingInt(w.handle), kind, node);
}

/// The window presented a frame (application.zig).
pub fn presented(w: *Window, commit_ns: u64, present_ns: u64) void {
    w.commit_ns = commit_ns;
    w.present_ns = present_ns;
    call(w, .presented, .null);
}

/// The window is being torn down: its hook goes, and siv's inspector
/// window with it when it inspects this one.
pub fn forgetWindow(w: *Window) void {
    const self = w.owner;
    if (w.inspect_hook) |h| {
        w.inspect_hook = null;
        self.release(h.destroy, h.user_data);
    }
    const ins = &self.inspector;
    if (ins.window == w.handle) {
        ins.* = .{ .keys = ins.keys };
        return;
    }
    if (ins.target != w.handle or self.closing.load(.monotonic)) return;
    ins.target = 0;
    const iw = App.window(ins.window, window_tag) catch return;
    if (!iw.dead) iw.destroyTree() catch {};
}

// siv's inspector window --------------------------------------------------------------

/// The application's inspector window, which siv_inspector_open and the
/// keys open.
pub const Inspector = struct {
    /// Ctrl+Shift+I and Ctrl+Shift+D open it.
    keys: bool = false,
    /// SIV_INSPECTOR=open: it opens on the first window created.
    open_first: bool = false,
    /// Its window and its siv_inspector node, and the window it
    /// inspects; 0 while it is closed.
    window: u64 = 0,
    panel: u64 = 0,
    target: u64 = 0,
};

/// SIV_INSPECTOR: unset, empty, or 0 leaves the keys off; open also opens
/// the inspector on the first window; anything else turns the keys on.
pub fn fromEnv(ins: *Inspector) void {
    const v = std.c.getenv("SIV_INSPECTOR") orelse return;
    const s = std.mem.span(v);
    if (s.len == 0 or std.mem.eql(u8, s, "0")) return;
    ins.keys = true;
    ins.open_first = std.mem.eql(u8, s, "open");
}

fn check(r: t.Result) Error!void {
    return switch (r) {
        .ok => {},
        .error_out_of_memory => error.OutOfMemory,
        .error_invalid_handle => error.InvalidHandle,
        .error_unsupported => error.Unsupported,
        .error_limit_exceeded => error.LimitExceeded,
        .error_busy => error.Busy,
        .error_unavailable => error.Unavailable,
        else => error.InvalidArgument,
    };
}

pub export fn siv_inspector_open(window: t.Window, node: t.Node) t.Result {
    return wrap(struct {
        fn f(wh: t.Window, n: t.Node) Error!void {
            const w = try App.window(@backingInt(wh), window_tag);
            if (n != .null) _ = try tree.nodeIn(w, n);
            try open(w, n);
        }
    }.f(window, node));
}

const inspector_title = "Inspector";

fn open(target: *Window, node: t.Node) Error!void {
    const self = target.owner;
    const ins = &self.inspector;
    if (target.handle == ins.window) return error.InvalidArgument;
    const tw: t.Window = @fromBackingInt(target.handle);
    var txn: t.Txn = .null;
    if (App.window(ins.window, window_tag) catch null) |iw| if (!iw.dead) {
        try check(tree.siv_txn_begin(@fromBackingInt(iw.handle), &txn));
        widgets.inspector.siv_inspector_inspect(txn, @fromBackingInt(ins.panel), tw, node);
        try check(tree.siv_txn_commit(txn));
        ins.target = target.handle;
        return;
    };
    var iwh: t.Window = .null;
    try check(application.siv_window_create(@fromBackingInt(self.root.handle), &.{
        .title = inspector_title,
        .title_len = inspector_title.len,
        .width = 960,
        .height = 640,
    }, &iwh));
    errdefer application.siv_window_destroy(iwh);
    try check(tree.siv_txn_begin(iwh, &txn));
    const root = application.siv_window_get_root(iwh);
    const panel = widgets.inspector.siv_inspector(txn, root, &.{ .window = tw, .node = node });
    try check(tree.siv_txn_commit(txn));
    ins.window = @backingInt(iwh);
    ins.panel = @backingInt(panel);
    ins.target = target.handle;
}

/// Ctrl+Shift+I or Ctrl+Shift+D in a window, with the keys enabled:
/// opens the inspector on it, or on the node under the pointer. True
/// when it was one of them (actions.zig).
pub fn key(w: *Window, keysym: u32, mods: ui.accel.Mods) bool {
    const self = w.owner;
    if (!self.inspector.keys or !mods.ctrl or !mods.shift or mods.alt or mods.super) return false;
    const pick = switch (keysym) {
        'I', 'i' => false,
        'D', 'd' => true,
        else => return false,
    };
    // Not on the inspector itself, nor a popup's: on its window.
    var target = w;
    while (target.parent) |p| target = p;
    if (target.handle == self.inspector.window) return true;
    var node: t.Node = .null;
    if (pick) if (w.uiWin().input.pointer) |p| {
        if (w == target) node = @fromBackingInt(w.nodes.handle(ui.inspect.nodeAt(w.uiWin(), p)));
    };
    self.enter();
    defer self.leave();
    // Without memory or a display, the key does nothing.
    open(target, node) catch {};
    return true;
}

/// A window was created: with SIV_INSPECTOR=open, the inspector opens
/// on the first.
pub fn windowCreated(w: *Window) void {
    const self = w.owner;
    if (!self.inspector.open_first or w.parent != null) return;
    self.inspector.open_first = false;
    open(w, .null) catch {};
}
