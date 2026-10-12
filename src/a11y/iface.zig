//! The AT-SPI interfaces a node exports, as D-Bus interface tables:
//! Accessible and Application on the root, and Accessible, Component,
//! Action, Text, EditableText, Value, and Selection on semantics nodes as
//! fitting. Every handler resolves its object from the path and answers
//! from the published snapshot.

const std = @import("std");
const dbus = @import("dbus");
const ui = @import("ui");
const raster = @import("raster");
const atspi = @import("atspi.zig");
const textutil = @import("textutil.zig");
const Bridge = @import("Bridge.zig");

const Interface = dbus.Interface;
const Request = dbus.Request;
const Encoder = dbus.Encoder;
const PropertyContext = dbus.object.PropertyContext;
const Snapshot = Bridge.Snapshot;
const SNode = Bridge.SNode;
const Ref = Bridge.Ref;
const Win = Bridge.Win;

// Resolution -------------------------------------------------------------------

const Obj = union(enum) {
    root: *Bridge,
    node: NodeObj,
};

const NodeObj = struct {
    b: *Bridge,
    w: *Win,
    i: u32,

    fn n(o: NodeObj) *SNode {
        return &o.w.cur.nodes.items[o.i];
    }

    fn snap(o: NodeObj) *Snapshot {
        return &o.w.cur;
    }

    fn id(o: NodeObj) ui.NodeId {
        return @fromBackingInt(@intCast(o.n().node));
    }

    fn text(o: NodeObj) []const u8 {
        return o.snap().str(o.n().text);
    }

    fn ref(o: NodeObj, index: u32) Ref {
        return o.w.ref(index);
    }

    fn live(o: NodeObj) bool {
        return o.w.ui.isLive(o.id());
    }
};

fn resolve(b: *Bridge, path: []const u8) error{UnknownObject}!Obj {
    const t = b.resolve(path) orelse return error.UnknownObject;
    return switch (t) {
        .root => .{ .root = b },
        .node => |x| .{ .node = .{ .b = b, .w = x.win, .i = x.index } },
    };
}

fn obj(r: *Request) error{UnknownObject}!Obj {
    return resolve(@ptrCast(@alignCast(r.node.ctx)), r.path);
}

fn nodeObj(r: *Request) error{UnknownObject}!NodeObj {
    return switch (try obj(r)) {
        .node => |o| o,
        .root => error.UnknownObject,
    };
}

fn propObj(ctx: PropertyContext) error{UnknownObject}!Obj {
    return resolve(@ptrCast(@alignCast(ctx.node.ctx)), ctx.path);
}

fn propNode(ctx: PropertyContext) error{UnknownObject}!NodeObj {
    return switch (try propObj(ctx)) {
        .node => |o| o,
        .root => error.UnknownObject,
    };
}

fn replyRef(r: *Request, ref: Ref) !void {
    var m = r.newReply();
    errdefer m.deinit();
    try ref.write(&m.body);
    try r.sendReply(&m);
}

fn replyBool(r: *Request, v: bool) !void {
    try r.reply(.{v});
}

// Interface sets ---------------------------------------------------------------

pub const root_interfaces = [_]*const Interface{ &accessible, &application };

const optional = [_]*const Interface{ &action, &text, &editable_text, &value, &selection };

fn maskOf(n: *const SNode) u5 {
    var m: u5 = 0;
    if (n.actionable) m |= 1;
    if (n.has_text) m |= 2;
    if (n.editable) m |= 4;
    if (n.value != null) m |= 8;
    if (selects(n.role)) m |= 16;
    return m;
}

fn selects(r: ui.Role) bool {
    return switch (r) {
        .list, .tree, .tab_list, .menu, .menu_bar, .table, .combo_box => true,
        else => false,
    };
}

const sets_data = blk: {
    var out: [32][7]*const Interface = undefined;
    var lens: [32]usize = undefined;
    for (0..32) |m| {
        out[m][0] = &accessible;
        out[m][1] = &component;
        var len: usize = 2;
        for (optional, 0..) |o, bit| {
            if (m & (1 << bit) != 0) {
                out[m][len] = o;
                len += 1;
            }
        }
        lens[m] = len;
    }
    break :blk .{ out, lens };
};
const set_ifaces: [32][7]*const Interface = sets_data[0];
const set_lens: [32]usize = sets_data[1];

pub fn interfacesOf(n: *const SNode) []const *const Interface {
    const m = maskOf(n);
    return set_ifaces[m][0..set_lens[m]];
}

// Accessible -----------------------------------------------------------------

pub const accessible: Interface = .{
    .name = atspi.iface.accessible,
    .methods = &.{
        .{ .name = "GetChildAtIndex", .in = "i", .out = "(so)", .func = getChildAtIndex },
        .{ .name = "GetChildren", .out = "a(so)", .func = getChildren },
        .{ .name = "GetIndexInParent", .out = "i", .func = getIndexInParent },
        .{ .name = "GetRelationSet", .out = "a(ua(so))", .func = getRelationSet },
        .{ .name = "GetRole", .out = "u", .func = getRole },
        .{ .name = "GetRoleName", .out = "s", .func = getRoleName },
        .{ .name = "GetLocalizedRoleName", .out = "s", .func = getRoleName },
        .{ .name = "GetState", .out = "au", .func = getState },
        .{ .name = "GetAttributes", .out = "a{ss}", .func = getAttributes },
        .{ .name = "GetApplication", .out = "(so)", .func = getApplication },
        .{ .name = "GetInterfaces", .out = "as", .func = getInterfaces },
    },
    .properties = &.{
        .{ .name = "Name", .signature = "s", .get = propName },
        .{ .name = "Description", .signature = "s", .get = propDescription },
        .{ .name = "Parent", .signature = "(so)", .get = propParent },
        .{ .name = "ChildCount", .signature = "i", .get = propChildCount },
        .{ .name = "Locale", .signature = "s", .get = propEmpty },
        .{ .name = "AccessibleId", .signature = "s", .get = propEmpty },
    },
};

fn childAt(o: Obj, index: i32) ?Ref {
    if (index < 0) return null;
    switch (o) {
        .root => |b| {
            var it = b.rootChildren();
            var k: i32 = 0;
            while (it.next()) |c| : (k += 1) if (k == index) return c[0].ref(c[1]);
            return null;
        },
        .node => |x| {
            var it = x.snap().children(x.i);
            var k: i32 = 0;
            while (it.next()) |c| : (k += 1) if (k == index) return x.ref(c);
            return null;
        },
    }
}

fn getChildAtIndex(r: *Request) anyerror!void {
    var d = r.args();
    const index = try d.readInt32();
    try replyRef(r, childAt(try obj(r), index) orelse Ref.null_ref);
}

fn getChildren(r: *Request) anyerror!void {
    var m = r.newReply();
    errdefer m.deinit();
    try m.body.beginArray("(so)");
    switch (try obj(r)) {
        .root => |b| {
            var it = b.rootChildren();
            while (it.next()) |c| try c[0].ref(c[1]).write(&m.body);
        },
        .node => |x| {
            var it = x.snap().children(x.i);
            while (it.next()) |c| try x.ref(c).write(&m.body);
        },
    }
    try m.body.endArray();
    try r.sendReply(&m);
}

fn getIndexInParent(r: *Request) anyerror!void {
    const index: i32 = switch (try obj(r)) {
        .root => -1,
        .node => |x| blk: {
            const n = x.n();
            const base: usize = if (n.parent == Bridge.none) x.b.rootIndexOf(x.w) else 0;
            break :blk @intCast(base + n.child_index);
        },
    };
    try r.reply(.{index});
}

fn getRelationSet(r: *Request) anyerror!void {
    _ = try obj(r);
    var m = r.newReply();
    errdefer m.deinit();
    try m.body.beginArray("(ua(so))");
    try m.body.endArray();
    try r.sendReply(&m);
}

fn roleOf(o: Obj) atspi.Role {
    return switch (o) {
        .root => .application,
        .node => |x| atspi.role(x.n().role, x.n().masked),
    };
}

fn getRole(r: *Request) anyerror!void {
    try r.reply(.{@backingInt(roleOf(try obj(r)))});
}

fn getRoleName(r: *Request) anyerror!void {
    try r.reply(.{roleOf(try obj(r)).name()});
}

fn getState(r: *Request) anyerror!void {
    const s: atspi.States = switch (try obj(r)) {
        .root => .{},
        .node => |x| x.n().states,
    };
    try r.reply(.{@as([]const u32, &s.words())});
}

fn getAttributes(r: *Request) anyerror!void {
    var m = r.newReply();
    errdefer m.deinit();
    try m.body.beginArray("{ss}");
    try entry(&m.body, "toolkit", "siv");
    switch (try obj(r)) {
        .root => {},
        .node => |x| {
            const n = x.n();
            var buf: [12]u8 = undefined;
            if (n.level != 0) try entry(&m.body, "level", std.fmt.bufPrint(&buf, "{d}", .{n.level}) catch unreachable);
            // Items of virtualized views: where they are among all items.
            if (n.position != 0) try entry(&m.body, "posinset", std.fmt.bufPrint(&buf, "{d}", .{n.position}) catch unreachable);
            if (n.set_size != 0) try entry(&m.body, "setsize", std.fmt.bufPrint(&buf, "{d}", .{n.set_size}) catch unreachable);
            if (n.row != 0) try entry(&m.body, "rowindex", std.fmt.bufPrint(&buf, "{d}", .{n.row}) catch unreachable);
            if (n.live != .off) {
                const v = if (n.live == .polite) "polite" else "assertive";
                try entry(&m.body, "live", v);
                try entry(&m.body, "container-live", v);
            }
        },
    }
    try m.body.endArray();
    try r.sendReply(&m);
}

fn entry(e: *Encoder, k: []const u8, v: []const u8) !void {
    try e.beginDictEntry();
    try e.writeString(k);
    try e.writeString(v);
    try e.endDictEntry();
}

fn getApplication(r: *Request) anyerror!void {
    const o = try obj(r);
    const b = switch (o) {
        .root => |b| b,
        .node => |x| x.b,
    };
    try replyRef(r, b.rootRef());
}

fn getInterfaces(r: *Request) anyerror!void {
    const list: []const *const Interface = switch (try obj(r)) {
        .root => &root_interfaces,
        .node => |x| interfacesOf(x.n()),
    };
    var m = r.newReply();
    errdefer m.deinit();
    try m.body.beginArray("s");
    for (list) |i| try m.body.writeString(i.name);
    try m.body.endArray();
    try r.sendReply(&m);
}

fn propName(ctx: PropertyContext, out: *Encoder) anyerror!void {
    switch (try propObj(ctx)) {
        .root => |b| try out.writeString(b.options.app_name),
        .node => |x| try out.writeString(x.w.name(x.i)),
    }
}

fn propDescription(ctx: PropertyContext, out: *Encoder) anyerror!void {
    switch (try propObj(ctx)) {
        .root => try out.writeString(""),
        .node => |x| try out.writeString(x.snap().str(x.n().description)),
    }
}

fn propParent(ctx: PropertyContext, out: *Encoder) anyerror!void {
    const ref: Ref = switch (try propObj(ctx)) {
        .root => |b| b.desktop(),
        .node => |x| if (x.n().parent == Bridge.none) x.b.rootRef() else x.ref(x.n().parent),
    };
    try ref.write(out);
}

fn propChildCount(ctx: PropertyContext, out: *Encoder) anyerror!void {
    const count: usize = switch (try propObj(ctx)) {
        .root => |b| blk: {
            var n: usize = 0;
            for (b.windows.items) |w| if (w) |x| {
                n += x.cur.top_count;
            };
            break :blk n;
        },
        .node => |x| x.n().child_count,
    };
    try out.writeInt32(@intCast(count));
}

fn propEmpty(ctx: PropertyContext, out: *Encoder) anyerror!void {
    _ = try propObj(ctx);
    try out.writeString("");
}

// Application ----------------------------------------------------------------

pub const application: Interface = .{
    .name = atspi.iface.application,
    .methods = &.{
        .{ .name = "GetLocale", .in = "u", .out = "s", .func = getLocale },
        .{ .name = "GetApplicationBusAddress", .out = "s", .func = getBusAddress },
    },
    .properties = &.{
        .{ .name = "ToolkitName", .signature = "s", .get = propToolkit },
        .{ .name = "Version", .signature = "s", .get = propVersion },
        .{ .name = "ToolkitVersion", .signature = "s", .get = propVersion },
        .{ .name = "AtspiVersion", .signature = "s", .get = propAtspiVersion },
        .{ .name = "Id", .signature = "i", .access = .readwrite, .get = propId, .set = setId },
    },
};

fn getLocale(r: *Request) anyerror!void {
    const b: *Bridge = @ptrCast(@alignCast(r.node.ctx));
    try r.reply(.{b.locale()});
}

fn getBusAddress(r: *Request) anyerror!void {
    // No peer-to-peer server: clients use the accessibility bus.
    try r.reply(.{""});
}

fn propToolkit(_: PropertyContext, out: *Encoder) anyerror!void {
    try out.writeString("siv");
}

fn propVersion(ctx: PropertyContext, out: *Encoder) anyerror!void {
    const b: *Bridge = @ptrCast(@alignCast(ctx.node.ctx));
    try out.writeString(b.options.toolkit_version);
}

fn propAtspiVersion(_: PropertyContext, out: *Encoder) anyerror!void {
    try out.writeString("2.1");
}

fn propId(ctx: PropertyContext, out: *Encoder) anyerror!void {
    const b: *Bridge = @ptrCast(@alignCast(ctx.node.ctx));
    try out.writeInt32(b.app_id);
}

fn setId(ctx: PropertyContext, in: *dbus.Decoder) anyerror!void {
    const b: *Bridge = @ptrCast(@alignCast(ctx.node.ctx));
    b.app_id = try in.readInt32();
}

// Component --------------------------------------------------------------------

pub const component: Interface = .{
    .name = atspi.iface.component,
    .methods = &.{
        .{ .name = "Contains", .in = "iiu", .out = "b", .func = contains },
        .{ .name = "GetAccessibleAtPoint", .in = "iiu", .out = "(so)", .func = accessibleAtPoint },
        .{ .name = "GetExtents", .in = "u", .out = "(iiii)", .func = getExtents },
        .{ .name = "GetPosition", .in = "u", .out = "ii", .func = getPosition },
        .{ .name = "GetSize", .out = "ii", .func = getSize },
        .{ .name = "GetLayer", .out = "u", .func = getLayer },
        .{ .name = "GetMDIZOrder", .out = "n", .func = getZOrder },
        .{ .name = "GrabFocus", .out = "b", .func = grabFocus },
        .{ .name = "GetAlpha", .out = "d", .func = getAlpha },
        .{ .name = "SetExtents", .in = "iiiiu", .out = "b", .func = refuse },
        .{ .name = "SetPosition", .in = "iiu", .out = "b", .func = refuse },
        .{ .name = "SetSize", .in = "ii", .out = "b", .func = refuse },
        .{ .name = "ScrollTo", .in = "u", .out = "b", .func = refuse },
        .{ .name = "ScrollToPoint", .in = "uii", .out = "b", .func = refuse },
    },
};

/// The origin of `coord` in window coordinates.
fn origin(x: NodeObj, coord: u32) raster.Point {
    if (coord == @backingInt(atspi.Coord.parent)) {
        const p = x.n().parent;
        if (p != Bridge.none) {
            const pb = x.snap().nodes.items[p].bounds;
            return .{ .x = pb.x0, .y = pb.y0 };
        }
    }
    return .{ .x = 0, .y = 0 };
}

const Extents = struct { i32, i32, i32, i32 };

fn extentsOf(rect: raster.Rect, o: raster.Point) Extents {
    if (rect.isEmpty()) return .{ 0, 0, 0, 0 };
    return .{
        @intFromFloat(@round(rect.x0 - o.x)),
        @intFromFloat(@round(rect.y0 - o.y)),
        @intFromFloat(@round(rect.width())),
        @intFromFloat(@round(rect.height())),
    };
}

fn contains(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const px, const py, const coord = try d.readAll(struct { i32, i32, u32 });
    const o = origin(x, coord);
    const b = x.n().bounds;
    const wx = @as(f32, @floatFromInt(px)) + o.x;
    const wy = @as(f32, @floatFromInt(py)) + o.y;
    try replyBool(r, wx >= b.x0 and wx < b.x1 and wy >= b.y0 and wy < b.y1);
}

fn accessibleAtPoint(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const px, const py, const coord = try d.readAll(struct { i32, i32, u32 });
    const o = origin(x, coord);
    var id = ui.input.hitTest(x.w.ui, .{ .x = @as(f32, @floatFromInt(px)) + o.x, .y = @as(f32, @floatFromInt(py)) + o.y });
    // The nearest published ancestor of the hit node, if it lies below
    // this object.
    while (id != .none) : (id = x.w.ui.node(id).parent) {
        const k = x.snap().index.get(id.index()) orelse continue;
        if (k > x.i and k < x.n().end) return replyRef(r, x.ref(k));
        break;
    }
    try replyRef(r, Ref.null_ref);
}

fn getExtents(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const coord = try d.readUint32();
    try r.reply(.{extentsOf(x.n().bounds, origin(x, coord))});
}

fn getPosition(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const coord = try d.readUint32();
    const e = extentsOf(x.n().bounds, origin(x, coord));
    try r.reply(.{ e[0], e[1] });
}

fn getSize(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    const e = extentsOf(x.n().bounds, .{ .x = 0, .y = 0 });
    try r.reply(.{ e[2], e[3] });
}

fn getLayer(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    // ATSPI_LAYER_WINDOW for windows, ATSPI_LAYER_WIDGET otherwise.
    try r.reply(.{@as(u32, if (x.n().role == .window) 7 else 3)});
}

fn getZOrder(r: *Request) anyerror!void {
    _ = try nodeObj(r);
    try r.reply(.{@as(i16, 0)});
}

fn grabFocus(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    if (!x.n().focusable or !x.live() or !ui.input.canFocus(x.w.ui, x.id())) return replyBool(r, false);
    ui.input.setFocus(x.w.ui, x.id(), true);
    try replyBool(r, true);
}

fn getAlpha(r: *Request) anyerror!void {
    _ = try nodeObj(r);
    try r.reply(.{@as(f64, 1)});
}

fn refuse(r: *Request) anyerror!void {
    _ = try nodeObj(r);
    try replyBool(r, false);
}

// Action -----------------------------------------------------------------------

pub const action: Interface = .{
    .name = atspi.iface.action,
    .methods = &.{
        .{ .name = "GetDescription", .in = "i", .out = "s", .func = actionEmpty },
        .{ .name = "GetName", .in = "i", .out = "s", .func = actionName },
        .{ .name = "GetLocalizedName", .in = "i", .out = "s", .func = actionName },
        .{ .name = "GetKeyBinding", .in = "i", .out = "s", .func = actionEmpty },
        .{ .name = "GetActions", .out = "a(sss)", .func = getActions },
        .{ .name = "DoAction", .in = "i", .out = "b", .func = doAction },
    },
    .properties = &.{.{ .name = "NActions", .signature = "i", .get = nActions }},
};

/// One action per actionable node, named like GTK's for its role.
fn actionNameOf(role: ui.Role) []const u8 {
    return switch (role) {
        .checkbox, .toggle_button, .@"switch" => "toggle",
        .link => "jump",
        .button, .radio, .menu_item, .tab, .list_item, .tree_item => "click",
        else => "activate",
    };
}

fn actionName(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const index = try d.readInt32();
    try r.reply(.{if (index == 0) actionNameOf(x.n().role) else ""});
}

fn actionEmpty(r: *Request) anyerror!void {
    _ = try nodeObj(r);
    try r.reply(.{""});
}

fn getActions(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    try r.reply(.{@as([]const struct { []const u8, []const u8, []const u8 }, &.{.{ actionNameOf(x.n().role), "", "" }})});
}

fn doAction(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const index = try d.readInt32();
    if (index != 0 or !x.n().actionable or !x.live()) return replyBool(r, false);
    ui.input.activate(x.w.ui, x.id());
    try replyBool(r, true);
}

fn nActions(ctx: PropertyContext, out: *Encoder) anyerror!void {
    const x = try propNode(ctx);
    try out.writeInt32(@intFromBool(x.n().actionable));
}

// Text ---------------------------------------------------------------------------

pub const text: Interface = .{
    .name = atspi.iface.text,
    .methods = &.{
        .{ .name = "GetStringAtOffset", .in = "iu", .out = "sii", .func = getStringAtOffset },
        .{ .name = "GetText", .in = "ii", .out = "s", .func = getText },
        .{ .name = "SetCaretOffset", .in = "i", .out = "b", .func = setCaretOffset },
        .{ .name = "GetTextBeforeOffset", .in = "iu", .out = "sii", .func = getTextBeforeOffset },
        .{ .name = "GetTextAtOffset", .in = "iu", .out = "sii", .func = getTextAtOffset },
        .{ .name = "GetTextAfterOffset", .in = "iu", .out = "sii", .func = getTextAfterOffset },
        .{ .name = "GetCharacterAtOffset", .in = "i", .out = "i", .func = getCharacterAtOffset },
        .{ .name = "GetAttributeValue", .in = "is", .out = "s", .func = getAttributeValue },
        .{ .name = "GetAttributes", .in = "i", .out = "a{ss}ii", .func = getTextAttributes },
        .{ .name = "GetDefaultAttributes", .out = "a{ss}", .func = getDefaultAttributes },
        .{ .name = "GetCharacterExtents", .in = "iu", .out = "iiii", .func = getCharacterExtents },
        .{ .name = "GetOffsetAtPoint", .in = "iiu", .out = "i", .func = getOffsetAtPoint },
        .{ .name = "GetNSelections", .out = "i", .func = getNSelections },
        .{ .name = "GetSelection", .in = "i", .out = "ii", .func = getSelection },
        .{ .name = "AddSelection", .in = "ii", .out = "b", .func = addSelection },
        .{ .name = "RemoveSelection", .in = "i", .out = "b", .func = removeSelection },
        .{ .name = "SetSelection", .in = "iii", .out = "b", .func = setSelectionRange },
        .{ .name = "GetRangeExtents", .in = "iiu", .out = "iiii", .func = getRangeExtents },
        .{ .name = "GetBoundedRanges", .in = "iiiiuuu", .out = "a(iisv)", .func = getBoundedRanges },
        .{ .name = "GetAttributeRun", .in = "ib", .out = "a{ss}ii", .func = getAttributeRun },
        .{ .name = "GetDefaultAttributeSet", .out = "a{ss}", .func = getDefaultAttributes },
        .{ .name = "ScrollSubstringTo", .in = "iiu", .out = "b", .func = refuse },
        .{ .name = "ScrollSubstringToPoint", .in = "iiuii", .out = "b", .func = refuse },
    },
    .properties = &.{
        .{ .name = "CharacterCount", .signature = "i", .get = characterCount },
        .{ .name = "CaretOffset", .signature = "i", .get = caretOffset },
    },
};

fn characterCount(ctx: PropertyContext, out: *Encoder) anyerror!void {
    const x = try propNode(ctx);
    try out.writeInt32(@intCast(textutil.charCount(x.text())));
}

fn caretOffset(ctx: PropertyContext, out: *Encoder) anyerror!void {
    const x = try propNode(ctx);
    const c: i32 = if (x.n().caret) |c| @intCast(textutil.charOf(x.text(), c)) else -1;
    try out.writeInt32(c);
}

/// Characters [start, end) of the node's text; end -1 is the end.
fn slice(s: []const u8, start: i32, end: i32) []const u8 {
    const a = textutil.byteOf(s, start);
    const z = if (end < 0) s.len else textutil.byteOf(s, end);
    return if (z <= a) "" else s[a..z];
}

fn getText(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const start, const end = try d.readAll(struct { i32, i32 });
    try r.reply(.{slice(x.text(), start, end)});
}

fn replyRange(r: *Request, s: []const u8, range: textutil.Range) !void {
    try r.reply(.{ s[textutil.byteOf(s, range.start)..textutil.byteOf(s, range.end)], @as(i32, @intCast(range.start)), @as(i32, @intCast(range.end)) });
}

/// The range of `g` at character `offset`; lines come from the layout.
fn rangeAt(x: NodeObj, g: atspi.Granularity, offset: i64) !textutil.Range {
    const s = x.text();
    if (g == .line) {
        const len = textutil.charCount(s);
        const o: u32 = @intCast(std.math.clamp(offset, 0, len));
        if (ui.access.lineRange(x.w.ui, x.id(), @intCast(textutil.byteOf(s, o)))) |line| {
            return .{ .start = textutil.charOf(s, line[0]), .end = textutil.charOf(s, line[1]) };
        }
    }
    return textutil.rangeAt(x.b.arena.allocator(), s, g, offset);
}

fn getStringAtOffset(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const offset, const g = try d.readAll(struct { i32, u32 });
    defer _ = x.b.arena.reset(.retain_capacity);
    try replyRange(r, x.text(), try rangeAt(x, @fromBackingInt(@intCast(g)), offset));
}

const Side = enum { before, at, after };

fn textAround(r: *Request, side: Side) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const offset, const boundary = try d.readAll(struct { i32, u32 });
    defer _ = x.b.arena.reset(.retain_capacity);
    const s = x.text();
    const g = textutil.granularityOf(@fromBackingInt(@intCast(boundary)));
    const len = textutil.charCount(s);
    var range = try rangeAt(x, g, offset);
    switch (side) {
        .at => {},
        .before => range = if (range.start == 0) .{ .start = 0, .end = 0 } else try rangeAt(x, g, range.start - 1),
        .after => range = if (range.end >= len) .{ .start = len, .end = len } else try rangeAt(x, g, range.end),
    }
    try replyRange(r, s, range);
}

fn getTextBeforeOffset(r: *Request) anyerror!void {
    try textAround(r, .before);
}

fn getTextAtOffset(r: *Request) anyerror!void {
    try textAround(r, .at);
}

fn getTextAfterOffset(r: *Request) anyerror!void {
    try textAround(r, .after);
}

fn getCharacterAtOffset(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const offset = try d.readInt32();
    const s = x.text();
    const b = textutil.byteOf(s, offset);
    var c: i32 = 0;
    if (b < s.len and offset >= 0) {
        const n = std.unicode.utf8ByteSequenceLength(s[b]) catch 1;
        c = @intCast(std.unicode.utf8Decode(s[b..@min(s.len, b + n)]) catch 0xfffd);
    }
    try r.reply(.{c});
}

fn getAttributeValue(r: *Request) anyerror!void {
    _ = try nodeObj(r);
    try r.reply(.{""});
}

/// No text attributes yet: one run covering the text.
fn getTextAttributes(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var m = r.newReply();
    errdefer m.deinit();
    try m.body.beginArray("{ss}");
    try m.body.endArray();
    try m.body.writeAll(.{ @as(i32, 0), @as(i32, @intCast(textutil.charCount(x.text()))) });
    try r.sendReply(&m);
}

fn getAttributeRun(r: *Request) anyerror!void {
    try getTextAttributes(r);
}

fn getDefaultAttributes(r: *Request) anyerror!void {
    _ = try nodeObj(r);
    var m = r.newReply();
    errdefer m.deinit();
    try m.body.beginArray("{ss}");
    try m.body.endArray();
    try r.sendReply(&m);
}

/// The window rectangle of character `offset`, from the last frame's
/// layout. Magnifiers follow the caret through this.
fn charRect(x: NodeObj, offset: i32) ?raster.Rect {
    if (offset < 0) return null;
    const s = x.text();
    if (offset > textutil.charCount(s)) return null;
    return ui.access.characterRect(x.w.ui, x.id(), @intCast(textutil.byteOf(s, offset)));
}

fn getCharacterExtents(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const offset, const coord = try d.readAll(struct { i32, u32 });
    const rect = charRect(x, offset) orelse raster.Rect.empty;
    try r.reply(extentsOf(rect, origin(x, coord)));
}

fn getRangeExtents(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const start, const end, const coord = try d.readAll(struct { i32, i32, u32 });
    var rect = raster.Rect.empty;
    var i = start;
    while (i < end) : (i += 1) {
        const c = charRect(x, i) orelse break;
        rect = rect.unite(c);
    }
    try r.reply(extentsOf(rect, origin(x, coord)));
}

fn getOffsetAtPoint(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const px, const py, const coord = try d.readAll(struct { i32, i32, u32 });
    const o = origin(x, coord);
    const at = ui.access.offsetAt(x.w.ui, x.id(), .{ .x = @as(f32, @floatFromInt(px)) + o.x, .y = @as(f32, @floatFromInt(py)) + o.y });
    try r.reply(.{if (at) |b| @as(i32, @intCast(textutil.charOf(x.text(), b))) else -1});
}

fn selectionOf(x: NodeObj) ?struct { u32, u32 } {
    const n = x.n();
    const c = n.caret orelse return null;
    const a = n.anchor orelse c;
    if (a == c) return null;
    const s = x.text();
    return .{ textutil.charOf(s, @min(a, c)), textutil.charOf(s, @max(a, c)) };
}

fn getNSelections(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    try r.reply(.{@as(i32, @intFromBool(selectionOf(x) != null))});
}

fn getSelection(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const index = try d.readInt32();
    const sel = selectionOf(x);
    if (index != 0 or sel == null) return r.reply(.{ @as(i32, 0), @as(i32, 0) });
    try r.reply(.{ @as(i32, @intCast(sel.?[0])), @as(i32, @intCast(sel.?[1])) });
}

/// Moves an editor's caret and anchor (characters) the way the user
/// would; while the application holds a transaction open the change
/// queues for the next frame.
fn select(x: NodeObj, caret: i32, anchor: i32) bool {
    if (!x.n().editable or caret < 0 or anchor < 0) return false;
    const s = x.text();
    ui.access.setSelection(x.w.ui, x.id(), @intCast(textutil.byteOf(s, caret)), @intCast(textutil.byteOf(s, anchor))) catch return false;
    return true;
}

fn setCaretOffset(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const offset = try d.readInt32();
    try replyBool(r, select(x, offset, offset));
}

fn addSelection(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const start, const end = try d.readAll(struct { i32, i32 });
    try replyBool(r, selectionOf(x) == null and select(x, end, start));
}

fn setSelectionRange(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const index, const start, const end = try d.readAll(struct { i32, i32, i32 });
    try replyBool(r, index == 0 and select(x, end, start));
}

fn removeSelection(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const index = try d.readInt32();
    if (index != 0 or selectionOf(x) == null) return replyBool(r, false);
    const c: i32 = @intCast(textutil.charOf(x.text(), x.n().caret.?));
    try replyBool(r, select(x, c, c));
}

fn getBoundedRanges(r: *Request) anyerror!void {
    _ = try nodeObj(r);
    var m = r.newReply();
    errdefer m.deinit();
    try m.body.beginArray("(iisv)");
    try m.body.endArray();
    try r.sendReply(&m);
}

// EditableText -------------------------------------------------------------------

/// Edits take the user's path (an undo step and a change event each);
/// while the application holds a transaction open they queue for the
/// next frame, and success means queued.
pub const editable_text: Interface = .{
    .name = atspi.iface.editable_text,
    .methods = &.{
        .{ .name = "SetTextContents", .in = "s", .out = "b", .func = setTextContents },
        .{ .name = "InsertText", .in = "isi", .out = "b", .func = insertText },
        .{ .name = "CopyText", .in = "ii", .func = copyText },
        .{ .name = "CutText", .in = "ii", .out = "b", .func = cutText },
        .{ .name = "DeleteText", .in = "ii", .out = "b", .func = deleteText },
        .{ .name = "PasteText", .in = "i", .out = "b", .func = pasteText },
    },
};

/// Characters [start, end) as bytes; end -1 is the end.
fn byteRange(s: []const u8, start: i32, end: i32) ?[2]u32 {
    if (start < 0) return null;
    const a = textutil.byteOf(s, start);
    const z = if (end < 0) s.len else textutil.byteOf(s, end);
    if (z < a) return null;
    return .{ @intCast(a), @intCast(z) };
}

fn replace(x: NodeObj, start: i32, end: i32, str: []const u8) bool {
    const range = byteRange(x.text(), start, end) orelse return false;
    ui.access.replaceText(x.w.ui, x.id(), range[0], range[1], str) catch return false;
    return true;
}

fn setTextContents(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    try replyBool(r, replace(x, 0, -1, try d.readString()));
}

fn insertText(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const pos, const str, const len = try d.readAll(struct { i32, []const u8, i32 });
    // `length` counts characters of `text` to insert.
    const part = if (len >= 0) str[0..textutil.byteOf(str, len)] else str;
    try replyBool(r, replace(x, pos, pos, part));
}

fn deleteText(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const start, const end = try d.readAll(struct { i32, i32 });
    try replyBool(r, replace(x, start, end, ""));
}

fn copyOrCut(x: NodeObj, start: i32, end: i32, cut: bool) bool {
    const range = byteRange(x.text(), start, end) orelse return false;
    ui.access.copyText(x.w.ui, x.id(), range[0], range[1], cut) catch return false;
    return true;
}

fn copyText(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const start, const end = try d.readAll(struct { i32, i32 });
    _ = copyOrCut(x, start, end, false);
}

fn cutText(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const start, const end = try d.readAll(struct { i32, i32 });
    try replyBool(r, copyOrCut(x, start, end, true));
}

fn pasteText(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const pos = try d.readInt32();
    const range = byteRange(x.text(), pos, pos) orelse return replyBool(r, false);
    ui.access.pasteText(x.w.ui, x.id(), range[0]) catch return replyBool(r, false);
    try replyBool(r, true);
}

// Value --------------------------------------------------------------------------

pub const value: Interface = .{
    .name = atspi.iface.value,
    .properties = &.{
        .{ .name = "MinimumValue", .signature = "d", .get = valueMin },
        .{ .name = "MaximumValue", .signature = "d", .get = valueMax },
        .{ .name = "MinimumIncrement", .signature = "d", .get = valueIncrement },
        .{ .name = "CurrentValue", .signature = "d", .access = .readwrite, .get = valueNow, .set = setValueNow },
        .{ .name = "Text", .signature = "s", .get = propEmpty },
    },
};

fn rangeOf(ctx: PropertyContext) !ui.Range {
    const x = try propNode(ctx);
    return x.n().value orelse .{};
}

fn valueMin(ctx: PropertyContext, out: *Encoder) anyerror!void {
    try out.writeDouble((try rangeOf(ctx)).min);
}

fn valueMax(ctx: PropertyContext, out: *Encoder) anyerror!void {
    try out.writeDouble((try rangeOf(ctx)).max);
}

fn valueIncrement(ctx: PropertyContext, out: *Encoder) anyerror!void {
    try out.writeDouble((try rangeOf(ctx)).step);
}

/// Setting the value asks the node's widget for it (`set_value`), which
/// clamps and steps it, or refuses; the change reaches assistive
/// technology through the tree's next update like any other.
fn setValueNow(ctx: PropertyContext, in: *dbus.Decoder) anyerror!void {
    const x = try propNode(ctx);
    const v = try in.readDouble();
    if (x.n().value == null or !x.live()) return error.AccessDenied;
    if (!ui.input.setValue(x.w.ui, x.id(), v)) return error.AccessDenied;
}

fn valueNow(ctx: PropertyContext, out: *Encoder) anyerror!void {
    try out.writeDouble((try rangeOf(ctx)).now);
}

// Selection ----------------------------------------------------------------------

pub const selection: Interface = .{
    .name = atspi.iface.selection,
    .methods = &.{
        .{ .name = "GetSelectedChild", .in = "i", .out = "(so)", .func = getSelectedChild },
        .{ .name = "SelectChild", .in = "i", .out = "b", .func = selectChild },
        .{ .name = "DeselectSelectedChild", .in = "i", .out = "b", .func = refuse },
        .{ .name = "IsChildSelected", .in = "i", .out = "b", .func = isChildSelected },
        .{ .name = "SelectAll", .out = "b", .func = refuse },
        .{ .name = "ClearSelection", .out = "b", .func = refuse },
        .{ .name = "DeselectChild", .in = "i", .out = "b", .func = refuse },
    },
    .properties = &.{.{ .name = "NSelectedChildren", .signature = "i", .get = nSelected }},
};

fn nSelected(ctx: PropertyContext, out: *Encoder) anyerror!void {
    const x = try propNode(ctx);
    var n: i32 = 0;
    var it = x.snap().children(x.i);
    while (it.next()) |c| n += @intFromBool(x.snap().nodes.items[c].states.has(.selected));
    try out.writeInt32(n);
}

fn getSelectedChild(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const index = try d.readInt32();
    var k: i32 = 0;
    var it = x.snap().children(x.i);
    while (it.next()) |c| {
        if (!x.snap().nodes.items[c].states.has(.selected)) continue;
        if (k == index) return replyRef(r, x.ref(c));
        k += 1;
    }
    try replyRef(r, Ref.null_ref);
}

fn nthChild(x: NodeObj, index: i32) ?u32 {
    var k: i32 = 0;
    var it = x.snap().children(x.i);
    while (it.next()) |c| : (k += 1) if (k == index) return c;
    return null;
}

fn isChildSelected(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const c = nthChild(x, try d.readInt32()) orelse return replyBool(r, false);
    try replyBool(r, x.snap().nodes.items[c].states.has(.selected));
}

/// Selecting a child activates it, as a click would.
fn selectChild(r: *Request) anyerror!void {
    const x = try nodeObj(r);
    var d = r.args();
    const c = nthChild(x, try d.readInt32()) orelse return replyBool(r, false);
    const n = x.snap().nodes.items[c];
    const id: ui.NodeId = @fromBackingInt(@intCast(n.node));
    if (!n.actionable or !x.w.ui.isLive(id)) return replyBool(r, false);
    ui.input.activate(x.w.ui, id);
    try replyBool(r, true);
}

// Cache ----------------------------------------------------------------------------

/// org.a11y.atspi.Cache at /org/a11y/atspi/cache: libatspi reads the whole
/// tree with one call when it first meets the application, then follows
/// events.
pub const cache: Interface = .{
    .name = "org.a11y.atspi.Cache",
    .methods = &.{.{ .name = "GetItems", .out = "a((so)(so)(so)iiassusau)", .func = getItems }},
    .signals = &.{
        .{ .name = "AddAccessible", .signature = "((so)(so)(so)iiassusau)" },
        .{ .name = "RemoveAccessible", .signature = "(so)" },
    },
};

fn getItems(r: *Request) anyerror!void {
    const b: *Bridge = @ptrCast(@alignCast(r.node.ctx));
    var m = r.newReply();
    errdefer m.deinit();
    const e = &m.body;
    try e.beginArray("((so)(so)(so)iiassusau)");
    const root = b.rootRef();
    // The application.
    try e.beginStruct();
    try root.write(e);
    try root.write(e);
    try b.desktop().write(e);
    var top_total: i32 = 0;
    for (b.windows.items) |w| if (w) |x| {
        top_total += @intCast(x.cur.top_count);
    };
    try e.writeAll(.{ @as(i32, -1), top_total });
    try writeNames(e, &root_interfaces);
    try e.writeAll(.{ b.options.app_name, @intFromEnum(atspi.Role.application), "" });
    try e.write(@as([]const u32, &.{ 0, 0 }));
    try e.endStruct();
    for (b.windows.items) |w| {
        const x = w orelse continue;
        const base = b.rootIndexOf(x);
        for (x.cur.nodes.items, 0..) |*n, i| {
            try e.beginStruct();
            try x.ref(@intCast(i)).write(e);
            try root.write(e);
            const parent = if (n.parent == Bridge.none) root else x.ref(n.parent);
            try parent.write(e);
            const index: usize = if (n.parent == Bridge.none) base + n.child_index else n.child_index;
            try e.writeAll(.{ @as(i32, @intCast(index)), @as(i32, @intCast(n.child_count)) });
            try writeNames(e, interfacesOf(n));
            try e.writeAll(.{ x.name(@intCast(i)), @intFromEnum(atspi.role(n.role, n.masked)), x.cur.str(n.description) });
            try e.write(@as([]const u32, &n.states.words()));
            try e.endStruct();
        }
    }
    try e.endArray();
    try r.sendReply(&m);
}

fn writeNames(e: *Encoder, list: []const *const Interface) !void {
    try e.beginArray("s");
    for (list) |i| try e.writeString(i.name);
    try e.endArray();
}
