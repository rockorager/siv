//! The file manager's window: places sidebar, toolbar with history
//! buttons, breadcrumbs, and search, a virtualized list (table) or grid of
//! the current folder, an operations bar, and a status line.
//!
//! Everything goes through the generated `siv` wrapper of the C ABI, as a
//! C program would (D22's rule for stock widgets, applied to an
//! application). FRICTION.md records where that hurt.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const c = siv.c;
pub const model = @import("model.zig");
pub const fsops = @import("fsops.zig");
pub const icons = @import("icons.zig");
pub const places_mod = @import("places.zig");
pub const uri = @import("uri.zig");
pub const Thumbs = @import("Thumbs.zig");
pub const Watcher = @import("Watcher.zig");

const Files = @This();
const Node = siv.Node;
const Txn = siv.Txn;

pub const ViewMode = enum { list, grid };

pub const Options = struct {
    /// Thread-safe: jobs allocate on worker threads.
    gpa: Allocator,
    /// The folder to show first (absolute).
    path: []const u8,
    home: []const u8,
    config_home: ?[]const u8 = null,
    data_home: ?[]const u8 = null,
    width: u32 = 1000,
    height: u32 = 640,
    mode: ViewMode = .list,
    show_hidden: bool = false,
    /// Seconds east of UTC for the Modified column.
    tz_offset_s: i64 = 0,
    /// Decode image thumbnails in the grid.
    thumbnails: bool = true,
    /// Follow changes to the folder with inotify.
    watch: bool = true,
    window_flags: siv.WindowFlags = .{},
    /// Called when the window is gone, so `main` can quit.
    on_closed: ?*const fn (*Files) void = null,
};

gpa: Allocator,
app: siv.App,
window: siv.Window = .null,
opts: Options,
home: []u8,
places: places_mod.Places,

// Nodes.
root: Node = .null,
sidebar: Node = .null,
back_btn: Node = .null,
fwd_btn: Node = .null,
up_btn: Node = .null,
crumbs: Node = .null,
location: Node = .null,
search: Node = .null,
mode_btn: Node = .null,
app_menu: Node = .null,
table: Node = .null,
grid: Node = .null,
empty: Node = .null,
status: Node = .null,
ops_bar: Node = .null,
ops_label: Node = .null,
ops_progress: Node = .null,
ops_cancel: Node = .null,
context: Node = .null,
dialog: Node = .null,

// The folder.
path: []u8 = &.{},
listing: ?model.Listing = null,
/// Every entry's index, sorted.
order: std.ArrayList(u32) = .empty,
/// The entries shown, in order: the view's item i is entries[visible[i]].
visible: std.ArrayList(u32) = .empty,
sort: model.Sort = .{},
query: std.ArrayList(u8) = .empty,
show_hidden: bool = false,
mode: ViewMode = .list,
/// The listing being read, if any; a newer navigation replaces it.
loading: ?*Load = null,
load_gen: u32 = 0,
/// An error reading the folder, shown in place of the view.
load_error: ?model.ReadError = null,

history: std.ArrayList([]u8) = .empty,
history_pos: usize = 0,

/// The item being renamed, by entry index, and its editor.
renaming: ?u32 = null,
rename_editor: Node = .null,
/// Names to select once the next listing arrives (after paste, new
/// folder, rename, or going up).
pending_select: std.ArrayList(u8) = .empty,
pending_rename: bool = false,
/// The view's cursor and scroll to keep across a reload of the same
/// folder.
keep_cursor_name: std.ArrayList(u8) = .empty,

ops: std.ArrayList(*fsops.Op) = .empty,
ops_timer: siv.Timer = .null,
thumbs: Thumbs,
watcher: ?*Watcher = null,
reload_timer: siv.Timer = .null,
theme: siv.ColorScheme = .follow,
drag_armed: bool = false,
drag_x: f32 = 0,
drag_y: f32 = 0,
drag_entry: u32 = 0,
/// The active view's selection as of the last status update, and totals
/// over it, kept from the changed ranges select events report.
sel_bits: std.ArrayList(u8) = .empty,
/// Presented frames (SIV_WINDOW_EVENT_PRESENTED), for measurements: when
/// the first one and the first one with the folder's rows were committed
/// (CLOCK_MONOTONIC), and how many.
frames: u64 = 0,
first_frame_ns: u64 = 0,
rows_frame_ns: u64 = 0,
rows_pending: bool = false,
sel_count: usize = 0,
sel_bytes: u64 = 0,
tokens: std.ArrayList(*Token) = .empty,
op_jobs: std.ArrayList(*OpJob) = .empty,

/// Row parts, kept in node data on each row body.
const RowParts = extern struct {
    files: ?*Files,
    /// Entry index the row shows.
    entry: u32,
    icon: Node,
    name: Node,
    size: Node,
    modified: Node,
    kind: Node,
    image: Node,
    /// The grid cell's image shows a thumbnail.
    thumb_shown: bool,
};
var row_key: u8 = 0;
var place_key: u8 = 0;

const PlaceParts = extern struct {
    files: ?*Files,
    index: u32,
    icon: Node,
    label: Node,
};

pub fn create(app: siv.App, opts: Options) !*Files {
    const gpa = opts.gpa;
    const self = try gpa.create(Files);
    errdefer gpa.destroy(self);
    const home = try gpa.dupe(u8, opts.home);
    errdefer gpa.free(home);
    var places = try places_mod.load(gpa, .{ .home = opts.home, .config_home = opts.config_home, .data_home = opts.data_home });
    errdefer places.deinit();
    self.* = .{
        .gpa = gpa,
        .app = app,
        .opts = opts,
        .home = home,
        .places = places,
        .show_hidden = opts.show_hidden,
        .mode = opts.mode,
        .thumbs = .init(gpa, app),
    };
    self.thumbs.enabled = opts.thumbnails;
    self.thumbs.on_ready = thumbReady;
    self.thumbs.ctx = self;
    errdefer self.thumbs.deinit();

    self.window = try siv.windowCreate(app, &.{
        .title = "Files",
        .title_len = 5,
        .app_id = "org.siv.Files",
        .app_id_len = 13,
        .width = opts.width,
        .height = opts.height,
        .min_width = 360,
        .min_height = 240,
        .user_data = self,
        .on_event = onWindowEvent,
        .destroy = onWindowDestroyed,
        .flags = opts.window_flags,
    });
    try self.build();
    self.navigate(opts.path, .push);
    return self;
}

/// Frees what the window did not: called after the window is gone.
fn deinit(self: *Files) void {
    const gpa = self.gpa;
    if (self.watcher) |wt| wt.destroy();
    for (self.ops.items) |op| op.cancel.store(true, .release);
    if (self.ops_timer != .null) _ = c.siv_timer_cancel(self.ops_timer);
    if (self.reload_timer != .null) _ = c.siv_timer_cancel(self.reload_timer);
    if (self.loading) |l| l.files = null;
    // Running operations stop at their next check and free themselves
    // when their done callback finds the window gone.
    for (self.op_jobs.items) |j| j.files = null;
    // Callbacks still waiting free their tokens without the window.
    for (self.tokens.items) |t| t.files = null;
    self.tokens.deinit(gpa);
    self.op_jobs.deinit(gpa);
    self.ops.deinit(gpa);
    self.thumbs.deinit();
    if (self.listing) |*l| l.deinit();
    self.order.deinit(gpa);
    self.visible.deinit(gpa);
    self.query.deinit(gpa);
    for (self.history.items) |h| gpa.free(h);
    self.history.deinit(gpa);
    self.pending_select.deinit(gpa);
    self.keep_cursor_name.deinit(gpa);
    self.sel_bits.deinit(gpa);
    gpa.free(self.path);
    gpa.free(self.home);
    self.places.deinit();
    gpa.destroy(self);
}

fn onWindowEvent(ud: ?*anyopaque, _: siv.Window, ev: ?*const siv.WindowEvent) callconv(.c) bool {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    switch (e.type) {
        .scale_changed => self.thumbs.setScale(@floatCast(e.scale)),
        .presented => {
            self.frames += 1;
            if (self.first_frame_ns == 0) self.first_frame_ns = e.commit_ns;
            if (self.rows_pending) {
                self.rows_pending = false;
                self.rows_frame_ns = e.commit_ns;
            }
        },
        else => {},
    }
    return false;
}

fn onWindowDestroyed(ud: ?*anyopaque) callconv(.c) void {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const cb = self.opts.on_closed;
    self.window = .null;
    if (cb) |f| f(self);
    self.deinit();
}

/// Closes the window (and with it the application in `main`).
pub fn close(self: *Files) void {
    if (self.window != .null) _ = c.siv_window_destroy(self.window);
}

// Building ------------------------------------------------------------------------

fn begin(self: *Files) ?Txn {
    var txn: Txn = .null;
    if (c.siv_txn_begin(self.window, &txn) != .ok) return null;
    return txn;
}

fn commit(txn: Txn) bool {
    const r = c.siv_txn_commit(txn);
    if (r != .ok) std.log.warn("transaction failed: {s}", .{std.mem.span(c.siv_result_name(r))});
    return r == .ok;
}

fn px(v: f32) siv.Dimension {
    return .{ .unit = .px, .value = v };
}

fn text(txn: Txn, parent: Node, s: []const u8, token: siv.ColorToken, role: siv.TextRole) Node {
    const n = c.siv_text(txn, parent, s.ptr, s.len);
    // One line; cut short with an ellipsis when it does not fit.
    _ = c.siv_set_text_style(txn, n, &.{ .color_token = token, .size_role = role, .flags = .{ .no_wrap = true, .ellipsize = true } });
    return n;
}

fn iconCanvas(txn: Txn, parent: Node, size: f32, ud: ?*anyopaque, draw: siv.DrawFn) Node {
    const n = c.siv_canvas(txn, parent, &.{ .user_data = ud, .draw = draw, .width = size, .height = size });
    _ = c.siv_set_layout(txn, n, &.{ .width = px(size), .height = px(size), .flags = .{ .no_shrink = true }, .align_y = .center });
    _ = c.siv_set_semantics(txn, n, &.{ .role = .none });
    return n;
}

fn build(self: *Files) !void {
    const txn = self.begin() orelse return error.Busy;
    errdefer _ = c.siv_txn_abort(txn);
    self.root = c.siv_window_root(self.window);
    _ = c.siv_set_visual(txn, self.root, &.{ .background_token = .window_bg });
    _ = c.siv_on(txn, self.root, .key, onKey, null, self);

    const column = c.siv_flex(txn, self.root, &.{ .axis = .column });
    _ = c.siv_set_layout(txn, column, &.{ .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });

    // Toolbar.
    const bar = c.siv_flex(txn, column, &.{ .axis = .row, .gap = 6, .align_items = .center });
    _ = c.siv_set_layout(txn, bar, &.{ .padding = .{ .start = 8, .end = 8, .top = 6, .bottom = 6 } });
    _ = c.siv_set_semantics(txn, bar, &.{ .role = .toolbar, .label = "Navigation", .label_len = 10 });
    self.back_btn = c.siv_push_button(txn, bar, &.{ .label = "Back", .label_len = 4, .style = .flat });
    self.fwd_btn = c.siv_push_button(txn, bar, &.{ .label = "Forward", .label_len = 7, .style = .flat });
    self.up_btn = c.siv_push_button(txn, bar, &.{ .label = "Up", .label_len = 2, .style = .flat });
    _ = c.siv_on(txn, self.back_btn, .activate, onBack, null, self);
    _ = c.siv_on(txn, self.fwd_btn, .activate, onForward, null, self);
    _ = c.siv_on(txn, self.up_btn, .activate, onUp, null, self);

    // Breadcrumbs, or the location field while editing it.
    const where = c.siv_stack(txn, bar, &.{ .align_y = .center });
    _ = c.siv_set_layout(txn, where, &.{ .grow = 1, .basis = px(0), .min_width = 80 });
    self.crumbs = c.siv_flex(txn, where, &.{ .axis = .row, .gap = 0, .align_items = .center });
    _ = c.siv_set_semantics(txn, self.crumbs, &.{ .role = .group, .label = "Path", .label_len = 4 });
    _ = c.siv_set_visual(txn, self.crumbs, &.{ .flags = .{ .clip = true } });
    self.location = c.siv_text_field(txn, where, &.{ .label = "Location", .label_len = 8, .placeholder = "Type a path", .placeholder_len = 11 });
    _ = c.siv_set_layout(txn, self.location, &.{ .width = .{ .unit = .fraction, .value = 1 } });
    _ = c.siv_set_visual(txn, self.location, &.{ .flags = .{ .hidden = true } });
    _ = c.siv_on(txn, self.location, .key, onLocationKey, null, self);
    _ = c.siv_on(txn, self.location, .focus, onEditorFocus, null, self);

    self.search = c.siv_text_field(txn, bar, &.{ .label = "Search", .label_len = 6, .placeholder = "Search", .placeholder_len = 6 });
    _ = c.siv_set_layout(txn, self.search, &.{ .width = px(200) });
    _ = c.siv_on(txn, self.search, .change, onSearchChange, null, self);
    _ = c.siv_on(txn, self.search, .key, onSearchKey, null, self);
    _ = c.siv_on(txn, self.search, .focus, onEditorFocus, null, self);

    self.mode_btn = c.siv_push_button(txn, bar, &.{ .label = "Grid", .label_len = 4, .style = .flat });
    _ = c.siv_on(txn, self.mode_btn, .activate, onToggleMode, null, self);

    const menu_btn = c.siv_menu_button(txn, bar, &.{ .label = "Menu", .label_len = 4, .style = .flat });
    var appm: Node = .null;
    _ = c.siv_widget_get_part(menu_btn, .menu, 0, &appm);
    self.app_menu = menu_btn;
    for (app_menu_items) |it| {
        _ = c.siv_menu_item(txn, appm, &.{
            .label = it.label.ptr,
            .label_len = it.label.len,
            .shortcut = it.shortcut.ptr,
            .shortcut_len = it.shortcut.len,
            .flags = .{ .separator = it.label.len == 0, .checkable = it.check },
        });
    }
    _ = c.siv_on(txn, menu_btn, .select, onAppMenu, null, self);

    const rule = c.siv_box(txn, column);
    _ = c.siv_set_layout(txn, rule, &.{ .height = px(1) });
    _ = c.siv_set_visual(txn, rule, &.{ .background_token = .separator });

    // Sidebar and content.
    const split = c.siv_split_pane(txn, column, &.{ .position = 190, .min_start = 120, .min_end = 240, .label = "Sidebar", .label_len = 7 });
    _ = c.siv_set_layout(txn, split, &.{ .grow = 1, .basis = px(0) });
    var start: Node = .null;
    var end: Node = .null;
    _ = c.siv_widget_get_part(split, .start, 0, &start);
    _ = c.siv_widget_get_part(split, .end, 0, &end);

    self.sidebar = c.siv_list_view(txn, start, &.{
        .label = "Places",
        .label_len = 6,
        .user_data = self,
        .bind = bindPlace,
        .count = @intCast(self.places.items.items.len),
        .item_height = 32,
        .selection = .single,
    });
    _ = c.siv_set_layout(txn, self.sidebar, &.{ .height = .{ .unit = .fraction, .value = 1 }, .padding = .{ .start = 6, .end = 6, .top = 6, .bottom = 6 } });
    _ = c.siv_on(txn, self.sidebar, .select, onPlaceSelect, null, self);
    _ = c.siv_on(txn, self.sidebar, .activate, onPlaceSelect, null, self);

    const content = c.siv_stack(txn, end, null);
    _ = c.siv_set_layout(txn, content, &.{ .grow = 1, .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 }, .padding = .{ .start = 6, .end = 6, .top = 6, .bottom = 6 } });
    const drop_mimes = "text/uri-list";
    _ = c.siv_set_drop_target(txn, content, &.{ .mimes = drop_mimes, .mimes_len = drop_mimes.len, .actions = .{ .copy = true, .move = true }, .preferred = .copy });
    _ = c.siv_on(txn, content, .drop, onDrop, null, self);
    _ = c.siv_on(txn, content, .pointer, onContentPointer, null, self);

    self.table = c.siv_table_view(txn, content, &.{
        .label = "Files",
        .label_len = 5,
        .user_data = self,
        .bind = bindRow,
        .item_height = 30,
        .selection = .multiple,
    });
    _ = c.siv_set_layout(txn, self.table, &.{ .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    for (columns) |col| {
        _ = c.siv_table_column(txn, self.table, &.{ .title = col.title.ptr, .title_len = col.title.len, .width = col.width, .flags = .{ .sortable = true }, .min_width = col.min });
    }
    _ = c.siv_view_set_sort(txn, self.table, 0, .ascending);
    _ = c.siv_on(txn, self.table, .sort, onSort, null, self);
    _ = c.siv_on(txn, self.table, .activate, onActivateItem, null, self);
    _ = c.siv_on(txn, self.table, .select, onSelect, null, self);

    self.grid = c.siv_grid_view(txn, content, &.{
        .label = "Files",
        .label_len = 5,
        .user_data = self,
        .bind = bindCell,
        .item_width = 112,
        .item_height = 112,
        .selection = .multiple,
    });
    _ = c.siv_set_layout(txn, self.grid, &.{ .width = .{ .unit = .fraction, .value = 1 }, .height = .{ .unit = .fraction, .value = 1 } });
    _ = c.siv_on(txn, self.grid, .activate, onActivateItem, null, self);
    _ = c.siv_on(txn, self.grid, .select, onSelect, null, self);

    self.empty = c.siv_text(txn, content, "", 0);
    _ = c.siv_set_text_style(txn, self.empty, &.{ .color_token = .muted_fg, .size_role = .heading, .@"align" = .center });
    _ = c.siv_set_layout(txn, self.empty, &.{ .align_x = .center, .align_y = .center });
    _ = c.siv_set_visual(txn, self.empty, &.{ .flags = .{ .hidden = true, .no_hit_test = true } });

    self.context = c.siv_menu(txn, content, &.{ .label = "File actions", .label_len = 12 });
    for (context_items) |it| {
        _ = c.siv_menu_item(txn, self.context, &.{
            .label = it.label.ptr,
            .label_len = it.label.len,
            .shortcut = it.shortcut.ptr,
            .shortcut_len = it.shortcut.len,
            .flags = .{ .separator = it.label.len == 0 },
            .mnemonic = it.mnemonic,
        });
    }
    _ = c.siv_on(txn, self.context, .select, onContextSelect, null, self);

    // Operations in progress.
    self.ops_bar = c.siv_flex(txn, column, &.{ .axis = .row, .gap = 10, .align_items = .center });
    _ = c.siv_set_layout(txn, self.ops_bar, &.{ .padding = .{ .start = 10, .end = 10, .top = 4, .bottom = 4 } });
    _ = c.siv_set_visual(txn, self.ops_bar, &.{ .background_token = .card_bg, .flags = .{ .hidden = true } });
    _ = c.siv_set_semantics(txn, self.ops_bar, &.{ .role = .group, .label = "File operations", .label_len = 15 });
    self.ops_label = text(txn, self.ops_bar, "", .card_fg, .caption);
    _ = c.siv_set_semantics(txn, self.ops_label, &.{ .flags = .{ .live_polite = true } });
    self.ops_progress = c.siv_progress_bar(txn, self.ops_bar, &.{ .label = "Progress", .label_len = 8 });
    _ = c.siv_set_layout(txn, self.ops_progress, &.{ .grow = 1 });
    self.ops_cancel = c.siv_push_button(txn, self.ops_bar, &.{ .label = "Cancel", .label_len = 6 });
    _ = c.siv_on(txn, self.ops_cancel, .activate, onCancelOps, null, self);

    // Status line.
    const status_bar = c.siv_flex(txn, column, &.{ .axis = .row, .align_items = .center });
    _ = c.siv_set_layout(txn, status_bar, &.{ .padding = .{ .start = 10, .end = 10, .top = 3, .bottom = 4 } });
    self.status = text(txn, status_bar, "", .muted_fg, .caption);
    _ = c.siv_set_semantics(txn, self.status, &.{ .role = .status, .flags = .{ .live_polite = true } });

    try siv.check(c.siv_txn_commit(txn));
    try self.applyMode();
}

const ColumnSpec = struct { title: []const u8, width: siv.Track, min: f32 };
const columns = [_]ColumnSpec{
    .{ .title = "Name", .width = .{ .unit = .fr, .value = 1 }, .min = 120 },
    .{ .title = "Size", .width = .{ .unit = .px, .value = 90 }, .min = 60 },
    .{ .title = "Modified", .width = .{ .unit = .px, .value = 140 }, .min = 80 },
    .{ .title = "Type", .width = .{ .unit = .px, .value = 100 }, .min = 60 },
};

const MenuSpec = struct { label: []const u8, shortcut: []const u8 = "", check: bool = false, mnemonic: u32 = 0 };

const ContextAction = enum { open, open_with, sep1, cut, copy, paste, sep2, rename, trash, delete, sep3, new_folder, select_all };
const context_items = [_]MenuSpec{
    .{ .label = "Open", .shortcut = "Enter", .mnemonic = 'o' },
    .{ .label = "Open With…", .mnemonic = 'w' },
    .{ .label = "" },
    .{ .label = "Cut", .shortcut = "Ctrl+X", .mnemonic = 't' },
    .{ .label = "Copy", .shortcut = "Ctrl+C", .mnemonic = 'c' },
    .{ .label = "Paste", .shortcut = "Ctrl+V", .mnemonic = 'p' },
    .{ .label = "" },
    .{ .label = "Rename…", .shortcut = "F2", .mnemonic = 'r' },
    .{ .label = "Move to Trash", .shortcut = "Delete", .mnemonic = 'm' },
    .{ .label = "Delete Permanently", .shortcut = "Shift+Delete", .mnemonic = 'd' },
    .{ .label = "" },
    .{ .label = "New Folder", .shortcut = "Ctrl+Shift+N" },
    .{ .label = "Select All", .shortcut = "Ctrl+A", .mnemonic = 'a' },
};

const AppAction = enum { new_folder, hidden, sep1, list, grid, sep2, follow, light, dark, sep3, close };
const app_menu_items = [_]MenuSpec{
    .{ .label = "New Folder", .shortcut = "Ctrl+Shift+N" },
    .{ .label = "Show Hidden Files", .shortcut = "Ctrl+H", .check = true },
    .{ .label = "" },
    .{ .label = "List View", .shortcut = "Ctrl+1", .check = true },
    .{ .label = "Grid View", .shortcut = "Ctrl+2", .check = true },
    .{ .label = "" },
    .{ .label = "Follow System Style", .check = true },
    .{ .label = "Light Style", .check = true },
    .{ .label = "Dark Style", .check = true },
    .{ .label = "" },
    .{ .label = "Close", .shortcut = "Ctrl+W" },
};

/// The menu item node at `index` of a menu.
fn menuItem(menu: Node, index: usize) Node {
    var cur: Node = .null;
    _ = c.siv_node_get_related(menu, .first_child, &cur);
    var i: usize = 0;
    while (cur != .null and i < index) : (i += 1) {
        var next: Node = .null;
        _ = c.siv_node_get_related(cur, .next, &next);
        cur = next;
    }
    return cur;
}

fn appMenu(self: *Files) Node {
    var m: Node = .null;
    _ = c.siv_widget_get_part(self.app_menu, .menu, 0, &m);
    return m;
}

/// Check marks in the app menu follow the state.
fn syncAppMenu(self: *Files, txn: Txn) void {
    const m = self.appMenu();
    const checks = [_]struct { AppAction, bool }{
        .{ .hidden, self.show_hidden },
        .{ .list, self.mode == .list },
        .{ .grid, self.mode == .grid },
        .{ .follow, self.theme == .follow },
        .{ .light, self.theme == .light },
        .{ .dark, self.theme == .dark },
    };
    for (checks) |ch| _ = c.siv_widget_set_value(txn, menuItem(m, @intFromEnum(ch[0])), if (ch[1]) 1 else 0);
}

// The view --------------------------------------------------------------------------

fn activeView(self: *const Files) Node {
    return if (self.mode == .list) self.table else self.grid;
}

fn applyMode(self: *Files) !void {
    const txn = self.begin() orelse return error.Busy;
    _ = c.siv_set_visual(txn, self.table, &.{ .flags = .{ .hidden = self.mode != .list } });
    _ = c.siv_set_visual(txn, self.grid, &.{ .flags = .{ .hidden = self.mode != .grid } });
    const label = if (self.mode == .list) "Grid" else "List";
    _ = c.siv_widget_set_label(txn, self.mode_btn, label.ptr, label.len);
    self.syncAppMenu(txn);
    try siv.check(c.siv_txn_commit(txn));
}

pub fn setMode(self: *Files, mode: ViewMode) void {
    if (mode == self.mode) return;
    // Each view keeps its own selection: carry it over, with the cursor.
    const cursor = self.cursorIndex();
    const bits = self.selectionBits() catch return;
    defer self.gpa.free(bits);
    self.mode = mode;
    self.applyMode() catch return;
    const to = self.activeView();
    const txn = self.begin() orelse return;
    _ = c.siv_view_set_count(txn, to, @intCast(self.visible.items.len));
    _ = c.siv_view_set_selection(txn, to, bits.ptr, bits.len);
    if (cursor) |i| _ = c.siv_view_set_cursor(txn, to, @intCast(i));
    if (!commit(txn)) return;
    self.focusView();
    self.updateStatus();
}

fn focusView(self: *Files) void {
    _ = c.siv_view_focus(self.activeView());
}

fn entryOf(self: *const Files, view_index: u32) ?model.Entry {
    const l = self.listing orelse return null;
    if (view_index >= self.visible.items.len) return null;
    return l.entries[self.visible.items[view_index]];
}

fn nameOf(self: *const Files, entry: u32) []const u8 {
    const l = &(self.listing orelse return "");
    return l.name(l.entries[entry]);
}

fn rowParts(txn: Txn, row: Node) ?*RowParts {
    var p: ?*anyopaque = null;
    if (c.siv_node_get_data(row, &row_key, &p) == .ok and p != null) return @ptrCast(@alignCast(p));
    if (c.siv_set_data(txn, row, &row_key, @sizeOf(RowParts), &p) != .ok) return null;
    return @ptrCast(@alignCast(p));
}

fn drawRowIcon(ud: ?*anyopaque, node: Node, d: siv.Draw, w: f32, h: f32) callconv(.c) void {
    const parts: *RowParts = @ptrCast(@alignCast(ud.?));
    const self = parts.files orelse return;
    const l = &(self.listing orelse return);
    if (parts.entry >= l.entries.len) return;
    icons.draw(.of(l.entries[parts.entry].category), node, d, w, h);
}

fn bindRow(ud: ?*anyopaque, txn: Txn, row: Node, item: u64, _: u32, _: u32, _: bool) callconv(.c) void {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const parts = rowParts(txn, row) orelse return;
    const vi: u32 = @intCast(item);
    if (vi >= self.visible.items.len) return;
    const entry = self.visible.items[vi];
    const l = &self.listing.?;
    const e = l.entries[entry];
    if (parts.files == null) {
        parts.files = self;
        const name_cell = c.siv_flex(txn, row, &.{ .axis = .row, .gap = 8, .align_items = .center });
        _ = c.siv_set_visual(txn, name_cell, &.{ .flags = .{ .clip = true } });
        parts.icon = iconCanvas(txn, name_cell, 18, parts, drawRowIcon);
        parts.name = text(txn, name_cell, "", .view_fg, .body);
        _ = c.siv_set_layout(txn, parts.name, &.{ .grow = 1, .basis = px(0) });
        parts.size = text(txn, row, "", .muted_fg, .body);
        _ = c.siv_set_text_style(txn, parts.size, &.{ .color_token = .muted_fg, .size_role = .body, .@"align" = .end, .flags = .{ .no_wrap = true, .ellipsize = true } });
        parts.modified = text(txn, row, "", .muted_fg, .body);
        // Dates read left to right in right-to-left layouts too: their
        // two runs of digits would swap in an RTL paragraph (D21).
        _ = c.siv_set_text_style(txn, parts.modified, &.{ .color_token = .muted_fg, .size_role = .body, .direction = .ltr, .flags = .{ .no_wrap = true, .ellipsize = true } });
        parts.kind = text(txn, row, "", .muted_fg, .body);
        // Cells, with their column, for screen readers' table navigation.
        for ([_]Node{ name_cell, parts.size, parts.modified, parts.kind }, 1..) |cell, k| {
            _ = c.siv_set_semantics(txn, cell, &.{ .role = .cell, .column = @intCast(k) });
        }
        _ = c.siv_on(txn, row, .pointer, onRowPointer, null, parts);
        _ = c.siv_on(txn, row, .drop, onRowDrop, null, parts);
    }
    parts.entry = entry;
    _ = c.siv_set_text(txn, parts.name, l.name(e).ptr, l.name(e).len);
    var buf: [64]u8 = undefined;
    const size = if (e.kind == .dir) "—" else model.formatSize(&buf, e.size);
    _ = c.siv_set_text(txn, parts.size, size.ptr, size.len);
    var tbuf: [64]u8 = undefined;
    const t = model.formatTime(&tbuf, e.mtime, self.opts.tz_offset_s);
    _ = c.siv_set_text(txn, parts.modified, t.ptr, t.len);
    const kind = e.category.label();
    _ = c.siv_set_text(txn, parts.kind, kind.ptr, kind.len);
    _ = c.siv_invalidate(txn, parts.icon);
    self.bindDropTarget(txn, row, e);
    self.bindRename(txn, parts, entry);
}

fn bindCell(ud: ?*anyopaque, txn: Txn, cell: Node, item: u64, _: u32, _: u32, _: bool) callconv(.c) void {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const parts = rowParts(txn, cell) orelse return;
    const vi: u32 = @intCast(item);
    if (vi >= self.visible.items.len) return;
    const entry = self.visible.items[vi];
    const l = &self.listing.?;
    const e = l.entries[entry];
    if (parts.files == null) {
        parts.files = self;
        const col = c.siv_flex(txn, cell, &.{ .axis = .column, .gap = 4, .align_items = .center });
        _ = c.siv_set_layout(txn, col, &.{ .height = .{ .unit = .fraction, .value = 1 } });
        _ = c.siv_set_visual(txn, col, &.{ .flags = .{ .clip = true } });
        const pic = c.siv_stack(txn, col, &.{ .align_x = .center, .align_y = .center });
        _ = c.siv_set_layout(txn, pic, &.{ .width = px(64), .height = px(64), .flags = .{ .no_shrink = true } });
        parts.icon = iconCanvas(txn, pic, 56, parts, drawRowIcon);
        parts.image = c.siv_image_view(txn, pic, &.{ .fit = .contain });
        _ = c.siv_set_layout(txn, parts.image, &.{ .width = px(64), .height = px(64) });
        _ = c.siv_set_visual(txn, parts.image, &.{ .flags = .{ .hidden = true } });
        _ = c.siv_set_semantics(txn, parts.image, &.{ .role = .none });
        parts.name = c.siv_text(txn, col, "", 0);
        // Two lines at most, the second cut short with an ellipsis.
        _ = c.siv_set_text_style(txn, parts.name, &.{ .color_token = .view_fg, .size_role = .caption, .@"align" = .center, .max_lines = 2, .flags = .{ .break_words = true, .ellipsize = true } });
        _ = c.siv_set_layout(txn, parts.name, &.{ .width = .{ .unit = .fraction, .value = 1 } });
        _ = c.siv_on(txn, cell, .pointer, onRowPointer, null, parts);
        _ = c.siv_on(txn, cell, .drop, onRowDrop, null, parts);
    }
    parts.entry = entry;
    _ = c.siv_set_text(txn, parts.name, l.name(e).ptr, l.name(e).len);
    _ = c.siv_invalidate(txn, parts.icon);
    // A thumbnail when there is one; otherwise the icon, and ask for it.
    const img = if (e.kind == .file and model.thumbnailable(l.name(e))) self.thumbs.get(l.path, l.name(e), e.mtime) else null;
    if (img) |image| {
        _ = c.siv_set_image_view(txn, parts.image, &.{ .image = image, .fit = .contain });
    }
    parts.thumb_shown = img != null;
    _ = c.siv_set_visual(txn, parts.image, &.{ .flags = .{ .hidden = img == null } });
    _ = c.siv_set_visual(txn, parts.icon, &.{ .flags = .{ .hidden = img != null } });
    self.bindDropTarget(txn, cell, e);
    self.bindRename(txn, parts, entry);
}

/// Folders take drops of files (into them); other rows leave drops to
/// the view behind them.
fn bindDropTarget(self: *Files, txn: Txn, row: Node, e: model.Entry) void {
    _ = self;
    const mimes: []const u8 = if (e.kind == .dir) "text/uri-list" else "";
    _ = c.siv_set_drop_target(txn, row, &.{ .mimes = mimes.ptr, .mimes_len = mimes.len, .actions = .{ .copy = true, .move = true }, .preferred = .copy });
}

fn thumbReady(ctx: ?*anyopaque) void {
    const self: *Files = @ptrCast(@alignCast(ctx.?));
    if (self.mode != .grid or self.listing == null) return;
    // Rebind what is on screen: rows whose thumbnail arrived show it.
    const txn = self.begin() orelse return;
    _ = c.siv_view_refresh(txn, self.grid);
    _ = commit(txn);
}

// Places ------------------------------------------------------------------------------

fn drawPlaceIcon(ud: ?*anyopaque, node: Node, d: siv.Draw, w: f32, h: f32) callconv(.c) void {
    const parts: *PlaceParts = @ptrCast(@alignCast(ud.?));
    const self = parts.files orelse return;
    if (parts.index >= self.places.items.items.len) return;
    icons.draw(self.places.items.items[parts.index].icon, node, d, w, h);
}

fn bindPlace(ud: ?*anyopaque, txn: Txn, row: Node, item: u64, _: u32, _: u32, _: bool) callconv(.c) void {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    var p: ?*anyopaque = null;
    if (c.siv_node_get_data(row, &place_key, &p) != .ok or p == null) {
        if (c.siv_set_data(txn, row, &place_key, @sizeOf(PlaceParts), &p) != .ok) return;
    }
    const parts: *PlaceParts = @ptrCast(@alignCast(p));
    if (parts.files == null) {
        parts.files = self;
        const flex = c.siv_flex(txn, row, &.{ .axis = .row, .gap = 8, .align_items = .center });
        parts.icon = iconCanvas(txn, flex, 18, parts, drawPlaceIcon);
        parts.label = text(txn, flex, "", .view_fg, .body);
        const drop = "text/uri-list";
        _ = c.siv_set_drop_target(txn, row, &.{ .mimes = drop, .mimes_len = drop.len, .actions = .{ .copy = true, .move = true }, .preferred = .copy });
        _ = c.siv_on(txn, row, .drop, onPlaceDrop, null, parts);
    }
    parts.index = @intCast(item);
    const pl = self.places.items.items[parts.index];
    _ = c.siv_set_text(txn, parts.label, pl.label.ptr, pl.label.len);
    _ = c.siv_invalidate(txn, parts.icon);
}

fn onPlaceSelect(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const i = ev.?.index;
    if (i >= self.places.items.items.len) return .handled;
    const path = self.places.items.items[i].path;
    if (!std.mem.eql(u8, path, self.path)) {
        // The trash folder may not exist yet.
        if (std.mem.endsWith(u8, path, "/Trash/files") and !places_mod.isDir(path)) {
            fsops.makeDir(model.parent(path), "files") catch {};
        }
        self.navigate(path, .push);
    }
    return .handled;
}

fn syncSidebar(self: *Files, txn: Txn) void {
    const n = self.places.items.items.len;
    const hit = self.places.find(self.path);
    for (0..n) |i| _ = c.siv_view_set_selected(txn, self.sidebar, @intCast(i), hit == i);
}

// Navigation ------------------------------------------------------------------------

pub const HistoryMove = enum { push, back, forward, none };

const Load = struct {
    files: ?*Files,
    gpa: Allocator,
    path: []u8,
    gen: u32,
    sort: model.Sort,
    result: model.ReadError!model.Listing = error.Unexpected,
    order: []u32 = &.{},
    taken: bool = false,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const l: *Load = @ptrCast(@alignCast(ud.?));
        l.result = model.read(l.gpa, l.path);
        // Sort on the worker too: 100 000 names take a while.
        if (l.result) |*listing| {
            l.order = l.gpa.alloc(u32, listing.entries.len) catch {
                listing.deinit();
                l.result = error.OutOfMemory;
                return;
            };
            model.sort(listing, l.order, l.sort);
        } else |_| {}
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const l: *Load = @ptrCast(@alignCast(ud.?));
        const self = l.files orelse return;
        if (self.loading != l) return;
        self.loading = null;
        l.taken = true;
        self.loaded(l);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const l: *Load = @ptrCast(@alignCast(ud.?));
        if (!l.taken) {
            if (l.result) |*listing| listing.deinit() else |_| {}
            l.gpa.free(l.order);
        }
        l.gpa.free(l.path);
        l.gpa.destroy(l);
    }
};

/// Shows `path`: reads it on the worker pool, then swaps the listing in.
pub fn navigate(self: *Files, path_in: []const u8, how: HistoryMove) void {
    var nbuf: [linux.PATH_MAX]u8 = undefined;
    const path = normalize(&nbuf, path_in);
    const gpa = self.gpa;
    const same = std.mem.eql(u8, path, self.path);
    if (!same) {
        self.keep_cursor_name.clearRetainingCapacity();
        self.query.clearRetainingCapacity();
        self.cancelRename();
    }
    switch (how) {
        .push => if (!same) {
            // Forward history goes once a new place is visited.
            if (self.history.items.len > 0) {
                for (self.history.items[self.history_pos + 1 ..]) |h| gpa.free(h);
                self.history.shrinkRetainingCapacity(self.history_pos + 1);
            }
            const copy = gpa.dupe(u8, path) catch return;
            self.history.append(gpa, copy) catch {
                gpa.free(copy);
                return;
            };
            self.history_pos = self.history.items.len - 1;
        },
        .back => self.history_pos -|= 1,
        .forward => self.history_pos = @min(self.history_pos + 1, self.history.items.len -| 1),
        .none => {},
    }
    if (!same) {
        const copy = gpa.dupe(u8, path) catch return;
        gpa.free(self.path);
        self.path = copy;
        if (self.query.items.len == 0) {
            const txn = self.begin();
            if (txn) |t| {
                _ = c.siv_set_text(t, self.search, "", 0);
                _ = commit(t);
            }
        }
    }
    self.startLoad();
    self.updateChrome();
}

fn startLoad(self: *Files) void {
    const gpa = self.gpa;
    if (self.loading) |old| old.files = null;
    self.loading = null;
    const l = gpa.create(Load) catch return;
    const p = gpa.dupe(u8, self.path) catch {
        gpa.destroy(l);
        return;
    };
    self.load_gen +%= 1;
    l.* = .{ .files = self, .gpa = gpa, .path = p, .gen = self.load_gen, .sort = self.sort };
    self.loading = l;
    if (c.siv_job_start(self.app, .{}, Load.work, Load.done, Load.destroy, l) != .ok) {
        // The destroy-notify ran already.
        self.loading = null;
    }
}

/// Reads the folder again, keeping the selection and cursor by name.
pub fn reload(self: *Files) void {
    if (self.listing != null) {
        self.rememberSelection();
    }
    self.startLoad();
}

fn rememberSelection(self: *Files) void {
    const sel = self.selectedIndices() catch return;
    defer self.gpa.free(sel);
    for (sel) |vi| {
        const nm = self.nameOf(self.visible.items[vi]);
        self.pending_select.appendSlice(self.gpa, nm) catch return;
        self.pending_select.append(self.gpa, '\n') catch return;
    }
    self.keep_cursor_name.clearRetainingCapacity();
    if (self.cursorIndex()) |cursor| {
        const nm = self.nameOf(self.visible.items[cursor]);
        self.keep_cursor_name.appendSlice(self.gpa, nm) catch {};
    }
}

fn loaded(self: *Files, l: *Load) void {
    const gpa = self.gpa;
    if (l.result) |listing| {
        if (self.listing) |*old| old.deinit();
        self.listing = listing;
        self.load_error = null;
        self.order.clearRetainingCapacity();
        self.order.appendSlice(gpa, l.order) catch {};
        gpa.free(l.order);
        l.order = &.{};
        self.thumbs.setFolder(listing.path);
        if (self.opts.watch) self.watch();
    } else |err| {
        gpa.free(l.order);
        l.order = &.{};
        if (self.listing) |*old| old.deinit();
        self.listing = null;
        self.load_error = err;
        self.order.clearRetainingCapacity();
    }
    self.refilter();
    self.applySelectionAfterLoad();
    // The rows are committed: the next presented frame shows them.
    if (self.rows_frame_ns == 0) self.rows_pending = true;
}

/// Applies `pending_select` (names) and the remembered cursor to the new
/// listing.
fn applySelectionAfterLoad(self: *Files) void {
    const view = self.activeView();
    const txn = self.begin() orelse return;
    var first: ?u32 = null;
    var cursor: ?u32 = null;
    if (self.pending_select.items.len != 0 or self.keep_cursor_name.items.len != 0) {
        // Names to view indices: one pass over what is shown.
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        defer wanted.deinit(self.gpa);
        var it = std.mem.splitScalar(u8, self.pending_select.items, '\n');
        while (it.next()) |nm| if (nm.len != 0) wanted.put(self.gpa, nm, {}) catch {};
        const bits = self.gpa.alloc(u8, (self.visible.items.len + 7) / 8) catch {
            _ = c.siv_txn_abort(txn);
            return;
        };
        defer self.gpa.free(bits);
        @memset(bits, 0);
        for (self.visible.items, 0..) |e, vi| {
            const nm = self.nameOf(e);
            if (wanted.count() != 0 and wanted.contains(nm)) {
                bits[vi / 8] |= @as(u8, 1) << @intCast(vi % 8);
                if (first == null) first = @intCast(vi);
            }
            if (self.keep_cursor_name.items.len != 0 and std.mem.eql(u8, nm, self.keep_cursor_name.items)) cursor = @intCast(vi);
        }
        _ = c.siv_view_set_selection(txn, view, bits.ptr, bits.len);
    }
    const target = cursor orelse first;
    if (target) |t| {
        _ = c.siv_view_set_cursor(txn, view, @intCast(t));
    } else if (self.visible.items.len > 0) {
        _ = c.siv_view_set_cursor(txn, view, 0);
    }
    self.pending_select.clearRetainingCapacity();
    self.keep_cursor_name.clearRetainingCapacity();
    _ = commit(txn);
    if (self.pending_rename) {
        self.pending_rename = false;
        if (first) |f| self.startRename(f);
    }
    self.updateStatus();
}

/// Rebuilds `visible` from the order, the query, and the hidden setting,
/// and gives both views the new count.
fn refilter(self: *Files) void {
    const gpa = self.gpa;
    self.visible.resize(gpa, self.order.items.len) catch return;
    if (self.listing) |*l| {
        const n = model.filter(l, self.order.items, self.visible.items, self.query.items, self.show_hidden);
        self.visible.shrinkRetainingCapacity(n);
    } else self.visible.clearRetainingCapacity();
    const txn = self.begin() orelse return;
    const n: u32 = @intCast(self.visible.items.len);
    _ = c.siv_view_set_count(txn, self.table, n);
    _ = c.siv_view_set_count(txn, self.grid, n);
    // A new set of items: selection by position would point at others.
    self.clearSelection(txn, self.table);
    self.clearSelection(txn, self.grid);
    var msg: []const u8 = "";
    if (self.load_error) |err| {
        msg = switch (err) {
            error.AccessDenied => "You do not have permission to see this folder",
            error.FileNotFound => "This folder does not exist",
            error.NotDir => "This is not a folder",
            else => "This folder could not be read",
        };
    } else if (n == 0 and self.listing != null) {
        msg = if (self.query.items.len != 0) "No results" else "This folder is empty";
    }
    _ = c.siv_set_text(txn, self.empty, msg.ptr, msg.len);
    _ = c.siv_set_visual(txn, self.empty, &.{ .flags = .{ .hidden = msg.len == 0, .no_hit_test = true } });
    _ = commit(txn);
    self.updateStatus();
}

/// Clears a view's selection.
fn clearSelection(self: *Files, txn: Txn, view: Node) void {
    _ = self;
    _ = c.siv_view_set_selection(txn, view, null, 0);
}

/// The active view's selection as a bitset over view indices (owned).
fn selectionBits(self: *Files) ![]u8 {
    const view = self.activeView();
    var len: usize = 0;
    _ = c.siv_view_get_selection(view, null, 0, &len);
    const bits = try self.gpa.alloc(u8, len);
    errdefer self.gpa.free(bits);
    if (c.siv_view_get_selection(view, bits.ptr, bits.len, &len) != .ok) @memset(bits, 0);
    return bits;
}

/// The selection as a bitset over entries of the listing (owned), which
/// survives a new order, filter, or view.
fn selectedEntries(self: *Files) ![]u8 {
    const l = self.listing orelse return self.gpa.alloc(u8, 0);
    const out = try self.gpa.alloc(u8, (l.entries.len + 7) / 8);
    @memset(out, 0);
    const bits = try self.selectionBits();
    defer self.gpa.free(bits);
    for (bits, 0..) |byte, bi| {
        var b = byte;
        while (b != 0) : (b &= b - 1) {
            const vi = bi * 8 + @ctz(b);
            if (vi >= self.visible.items.len) break;
            const e = self.visible.items[vi];
            out[e / 8] |= @as(u8, 1) << @intCast(e % 8);
        }
    }
    return out;
}

/// Selects in `view` the shown items whose entries are set in
/// `entries`; returns the first such view index.
fn selectEntries(self: *Files, txn: Txn, view: Node, entries: []const u8) !?u32 {
    const bits = try self.gpa.alloc(u8, (self.visible.items.len + 7) / 8);
    defer self.gpa.free(bits);
    @memset(bits, 0);
    var first: ?u32 = null;
    for (self.visible.items, 0..) |e, vi| {
        if (e / 8 >= entries.len or entries[e / 8] & (@as(u8, 1) << @intCast(e % 8)) == 0) continue;
        bits[vi / 8] |= @as(u8, 1) << @intCast(vi % 8);
        if (first == null) first = @intCast(vi);
    }
    _ = c.siv_view_set_selection(txn, view, bits.ptr, bits.len);
    return first;
}

/// Re-sorts or re-filters with `change`, keeping the selection and the
/// cursor's item.
fn keepSelection(self: *Files, comptime change: type) void {
    const entries = self.selectedEntries() catch return;
    defer self.gpa.free(entries);
    const cursor_entry: ?u32 = if (self.cursorIndex()) |i| self.visible.items[i] else null;
    change.apply(self);
    self.refilter();
    const txn = self.begin() orelse return;
    const first = self.selectEntries(txn, self.activeView(), entries) catch null;
    const target = if (cursor_entry) |ce| self.viewIndexOfEntry(ce) else null;
    if (target orelse first) |t| {
        _ = c.siv_view_set_cursor(txn, self.activeView(), @intCast(t));
    }
    _ = commit(txn);
    self.updateStatus();
}

/// The selected view indices (owned), in order.
pub fn selectedIndices(self: *Files) ![]u32 {
    const bits = try self.selectionBits();
    defer self.gpa.free(bits);
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(self.gpa);
    for (bits, 0..) |byte, bi| {
        var b = byte;
        while (b != 0) : (b &= b - 1) try out.append(self.gpa, @intCast(bi * 8 + @ctz(b)));
    }
    return out.toOwnedSlice(self.gpa);
}

/// Absolute paths of the selection (or the cursor's item when nothing is
/// selected), owned.
pub fn selectedPaths(self: *Files) ![][]u8 {
    const gpa = self.gpa;
    const sel = try self.selectedIndices();
    defer gpa.free(sel);
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    const l = &(self.listing orelse return list.toOwnedSlice(gpa));
    for (sel) |vi| {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const p = model.join(&buf, l.path, l.name(l.entries[self.visible.items[vi]])) orelse continue;
        try list.append(gpa, try gpa.dupe(u8, p));
    }
    return list.toOwnedSlice(gpa);
}

fn freePaths(self: *Files, paths: [][]u8) void {
    for (paths) |p| self.gpa.free(p);
    self.gpa.free(paths);
}

fn normalize(buf: []u8, path: []const u8) []const u8 {
    // Collapse "//", "/./", and "/x/../"; drop a trailing slash.
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            while (n > 0 and buf[n - 1] != '/') n -= 1;
            if (n > 0) n -= 1;
            continue;
        }
        if (n + 1 + part.len > buf.len) break;
        buf[n] = '/';
        @memcpy(buf[n + 1 ..][0..part.len], part);
        n += 1 + part.len;
    }
    if (n == 0) {
        buf[0] = '/';
        n = 1;
    }
    return buf[0..n];
}

/// History buttons, breadcrumbs, title, and sidebar for the current path.
fn updateChrome(self: *Files) void {
    const txn = self.begin() orelse return;
    _ = c.siv_widget_set_disabled(txn, self.back_btn, self.history_pos == 0);
    _ = c.siv_widget_set_disabled(txn, self.fwd_btn, self.history_pos + 1 >= self.history.items.len);
    _ = c.siv_widget_set_disabled(txn, self.up_btn, std.mem.eql(u8, self.path, "/"));
    self.buildCrumbs(txn);
    self.syncSidebar(txn);
    _ = commit(txn);
    var tbuf: [512]u8 = undefined;
    const title = std.fmt.bufPrint(&tbuf, "{s} — Files", .{self.displayName(self.path)}) catch "Files";
    _ = c.siv_window_set_title(self.window, title.ptr, title.len);
}

fn displayName(self: *const Files, path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, self.home)) return "Home";
    if (std.mem.eql(u8, path, "/")) return "Computer";
    if (self.places.find(path)) |i| return self.places.items.items[i].label;
    return model.basename(path);
}

const Crumb = struct { files: *Files, depth: u32 };

fn buildCrumbs(self: *Files, txn: Txn) void {
    // Remove the old ones.
    while (true) {
        var child: Node = .null;
        _ = c.siv_node_get_related(self.crumbs, .first_child, &child);
        if (child == .null) break;
        _ = c.siv_remove(txn, child);
    }
    // Under home, the first crumb is Home; otherwise Computer ("/").
    const under_home = std.mem.startsWith(u8, self.path, self.home) and
        (self.path.len == self.home.len or self.path[self.home.len] == '/');
    const base_len: usize = if (under_home) self.home.len else 0;
    var rtl = false;
    _ = c.siv_node_is_rtl(self.crumbs, &rtl);
    var depth: u32 = 0;
    self.addCrumb(txn, if (under_home) "Home" else "Computer", depth, rtl, false);
    var it = std.mem.tokenizeScalar(u8, self.path[base_len..], '/');
    while (it.next()) |part| {
        depth += 1;
        self.addCrumb(txn, part, depth, rtl, true);
    }
}

fn addCrumb(self: *Files, txn: Txn, label: []const u8, depth: u32, rtl: bool, sep: bool) void {
    if (sep) {
        const chevron: []const u8 = if (rtl) "‹" else "›";
        _ = text(txn, self.crumbs, chevron, .muted_fg, .body);
    }
    const b = c.siv_push_button(txn, self.crumbs, &.{ .label = label.ptr, .label_len = label.len, .style = .flat });
    _ = c.siv_set_layout(txn, b, &.{ .flags = .{ .no_shrink = depth == 0 } });
    // Each button carries its depth in node data.
    var p: ?*anyopaque = null;
    if (c.siv_set_data(txn, b, &crumb_key, @sizeOf(u32), &p) == .ok) {
        const d: *u32 = @ptrCast(@alignCast(p));
        d.* = depth;
    }
    _ = c.siv_on(txn, b, .activate, onCrumb, null, self);
}
var crumb_key: u8 = 0;

fn onCrumb(ud: ?*anyopaque, node: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    var p: ?*anyopaque = null;
    if (c.siv_node_get_data(node, &crumb_key, &p) != .ok or p == null) return .handled;
    const depth = @as(*u32, @ptrCast(@alignCast(p))).*;
    const under_home = std.mem.startsWith(u8, self.path, self.home) and
        (self.path.len == self.home.len or self.path[self.home.len] == '/');
    var end: usize = if (under_home) self.home.len else 0;
    var k: u32 = 0;
    while (k < depth) : (k += 1) {
        const next = std.mem.indexOfScalarPos(u8, self.path, end + 1, '/') orelse self.path.len;
        end = next;
    }
    const target = if (end == 0) "/" else self.path[0..end];
    var buf: [linux.PATH_MAX]u8 = undefined;
    const copy = std.fmt.bufPrint(&buf, "{s}", .{target}) catch return .handled;
    self.navigate(copy, .push);
    return .handled;
}

fn onBack(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.goBack();
    return .handled;
}

fn onForward(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.goForward();
    return .handled;
}

fn onUp(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.goUp();
    return .handled;
}

pub fn goBack(self: *Files) void {
    if (self.history_pos == 0) return;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}", .{self.history.items[self.history_pos - 1]}) catch return;
    self.navigate(p, .back);
}

pub fn goForward(self: *Files) void {
    if (self.history_pos + 1 >= self.history.items.len) return;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}", .{self.history.items[self.history_pos + 1]}) catch return;
    self.navigate(p, .forward);
}

pub fn goUp(self: *Files) void {
    if (std.mem.eql(u8, self.path, "/")) return;
    // Select the folder we came from.
    self.pending_select.clearRetainingCapacity();
    self.pending_select.appendSlice(self.gpa, model.basename(self.path)) catch {};
    self.pending_select.append(self.gpa, '\n') catch {};
    var buf: [linux.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}", .{model.parent(self.path)}) catch return;
    self.navigate(p, .push);
}

// Opening -----------------------------------------------------------------------------

fn onActivateItem(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.openItem(ev.?.index, false);
    return .handled;
}

/// Opens a view item: folders in place, files with their default
/// application through the OpenURI portal.
pub fn openItem(self: *Files, vi: u32, ask: bool) void {
    const e = self.entryOf(vi) orelse return;
    const l = &self.listing.?;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const p = model.join(&buf, l.path, l.name(e)) orelse return;
    if (e.kind == .dir and !ask) {
        self.navigate(p, .push);
        return;
    }
    var ubuf: std.ArrayList(u8) = .empty;
    defer ubuf.deinit(self.gpa);
    uri.appendFileUri(&ubuf, self.gpa, p) catch return;
    _ = c.siv_open_uri(self.app, self.window, ubuf.items.ptr, ubuf.items.len, .{ .ask = ask }, onOpened, null, self);
}

fn onOpened(ud: ?*anyopaque, result: ?*const siv.PortalResult) callconv(.c) void {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    switch (result.?.response) {
        .success, .cancelled => {},
        .unavailable => self.toast("No application could be asked to open this file (no portal)", false),
        else => self.toast("The file could not be opened", false),
    }
}

// Sorting and searching ----------------------------------------------------------------

fn onSort(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const key: model.SortKey = switch (ev.?.index) {
        0 => .name,
        1 => .size,
        2 => .modified,
        else => .type,
    };
    self.setSort(.{ .key = key, .descending = ev.?.value < 0 });
    return .handled;
}

pub fn setSort(self: *Files, s: model.Sort) void {
    self.sort = s;
    if (self.listing != null) {
        // Keep the selection across the new order, by entry.
        self.keepSelection(struct {
            fn apply(f: *Files) void {
                model.sort(&f.listing.?, f.order.items, f.sort);
            }
        });
    }
    const txn = self.begin() orelse return;
    _ = c.siv_view_set_sort(txn, self.table, @intFromEnum(s.key), if (s.descending) .descending else .ascending);
    _ = commit(txn);
}

fn onSearchChange(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    const s = if (e.text) |p| p[0..e.text_len] else "";
    self.setQuery(s);
    return .handled;
}

pub fn setQuery(self: *Files, q: []const u8) void {
    if (std.mem.eql(u8, q, self.query.items)) return;
    self.query.clearRetainingCapacity();
    self.query.appendSlice(self.gpa, q) catch return;
    self.refilter();
    if (self.visible.items.len > 0) {
        const txn = self.begin() orelse return;
        _ = c.siv_view_set_cursor(txn, self.activeView(), 0);
        _ = commit(txn);
    }
}

fn onSearchKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed) return .pass;
    switch (e.keysym) {
        .escape => {
            const txn = self.begin() orelse return .handled;
            _ = c.siv_set_text(txn, self.search, "", 0);
            _ = commit(txn);
            self.setQuery("");
            self.focusView();
            return .handled;
        },
        .down, .@"return", .kp_enter => {
            self.focusView();
            return .handled;
        },
        else => return .pass,
    }
}

fn onEditorFocus(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const gained = ev.?.flags.gained;
    // Leaving the location field shows the breadcrumbs again.
    if (!gained and node == self.location) self.showLocation(false);
    return .pass;
}

fn onLocationKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed) return .pass;
    switch (e.keysym) {
        .escape => {
            self.showLocation(false);
            self.focusView();
            return .handled;
        },
        .@"return", .kp_enter => {
            var buf: [linux.PATH_MAX]u8 = undefined;
            var len: usize = 0;
            _ = c.siv_node_get_text(self.location, &buf, buf.len, &len);
            var t = std.mem.trim(u8, buf[0..@min(len, buf.len)], " \t");
            var ebuf: [linux.PATH_MAX]u8 = undefined;
            if (std.mem.startsWith(u8, t, "~")) {
                t = std.fmt.bufPrint(&ebuf, "{s}{s}", .{ self.home, t[1..] }) catch t;
            } else if (std.mem.startsWith(u8, t, "file://")) {
                t = uri.filePath(&ebuf, t) orelse t;
            } else if (t.len > 0 and t[0] != '/') {
                t = std.fmt.bufPrint(&ebuf, "{s}/{s}", .{ self.path, t }) catch t;
            }
            self.showLocation(false);
            if (t.len != 0) self.navigate(t, .push);
            self.focusView();
            return .handled;
        },
        else => return .pass,
    }
}

pub fn showLocation(self: *Files, show: bool) void {
    const txn = self.begin() orelse return;
    _ = c.siv_set_visual(txn, self.crumbs, &.{ .flags = .{ .hidden = show, .clip = true } });
    _ = c.siv_set_visual(txn, self.location, &.{ .flags = .{ .hidden = !show } });
    if (show) {
        _ = c.siv_set_text(txn, self.location, self.path.ptr, self.path.len);
        _ = c.siv_set_selection(txn, self.location, @intCast(self.path.len), 0);
    }
    if (!commit(txn)) return;
    if (show) _ = c.siv_node_focus(self.location);
}

// Selection and status ----------------------------------------------------------------

fn onSelect(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    self.applySelectChange(e.changed_index, e.changed_count) catch self.recountSelection() catch {};
    self.showStatus();
    return .handled;
}

/// Updates the totals from the rows whose selection may have changed:
/// reads the bitset only up to the range's end and looks at its bytes.
fn applySelectChange(self: *Files, lo: u32, n: u32) !void {
    const count = self.visible.items.len;
    if (self.sel_bits.items.len != (count + 7) / 8) return error.Stale;
    if (n == 0) return;
    const end: usize = @min(count, @as(usize, lo) + n);
    const first = lo / 8;
    const last = (end + 7) / 8;
    var buf: [4096]u8 = undefined;
    const now = if (last <= buf.len) buf[0..last] else try self.gpa.alloc(u8, last);
    defer if (now.ptr != &buf) self.gpa.free(now);
    var len: usize = 0;
    try siv.check(c.siv_view_get_selection(self.activeView(), now.ptr, now.len, &len));
    for (first..last) |bi| {
        var diff = now[bi] ^ self.sel_bits.items[bi];
        while (diff != 0) : (diff &= diff - 1) {
            const vi = bi * 8 + @ctz(diff);
            const on = now[bi] & (@as(u8, 1) << @intCast(@ctz(diff))) != 0;
            const e = self.entryOf(@intCast(vi)) orelse continue;
            const size: u64 = if (e.kind == .dir) 0 else e.size;
            if (on) {
                self.sel_count += 1;
                self.sel_bytes += size;
            } else {
                self.sel_count -= 1;
                self.sel_bytes -= size;
            }
        }
        self.sel_bits.items[bi] = now[bi];
    }
}

/// Reads the whole selection again, after the app changed it itself (those
/// changes are not reported) or the listing changed.
fn recountSelection(self: *Files) !void {
    const bits = try self.selectionBits();
    defer self.gpa.free(bits);
    self.sel_bits.clearRetainingCapacity();
    try self.sel_bits.appendSlice(self.gpa, bits);
    self.sel_count = 0;
    self.sel_bytes = 0;
    for (bits, 0..) |byte, bi| {
        var b = byte;
        while (b != 0) : (b &= b - 1) {
            const e = self.entryOf(@intCast(bi * 8 + @ctz(b))) orelse continue;
            self.sel_count += 1;
            if (e.kind != .dir) self.sel_bytes += e.size;
        }
    }
}

pub fn selectAll(self: *Files) void {
    const view = self.activeView();
    const bits = self.gpa.alloc(u8, (self.visible.items.len + 7) / 8) catch return;
    defer self.gpa.free(bits);
    @memset(bits, 0xff);
    const txn = self.begin() orelse return;
    _ = c.siv_view_set_selection(txn, view, bits.ptr, bits.len);
    _ = commit(txn);
    self.updateStatus();
}

/// Counts the selection again and shows it in the status line.
pub fn updateStatus(self: *Files) void {
    if (self.window == .null) return;
    self.recountSelection() catch return;
    self.showStatus();
}

fn showStatus(self: *Files) void {
    if (self.window == .null) return;
    var buf: [256]u8 = undefined;
    const n = self.visible.items.len;
    var msg: []const u8 = "";
    var sbuf: [32]u8 = undefined;
    if (self.listing == null) {
        msg = if (self.loading != null) "Loading…" else "";
    } else if (self.sel_count == 0) {
        msg = std.fmt.bufPrint(&buf, "{d} {s}", .{ n, if (n == 1) "item" else "items" }) catch "";
    } else if (self.sel_count == 1) {
        const vi = for (self.sel_bits.items, 0..) |byte, bi| {
            if (byte != 0) break bi * 8 + @ctz(byte);
        } else return;
        const e = self.entryOf(@intCast(vi)) orelse return;
        const nm = self.nameOf(self.visible.items[vi]);
        msg = if (e.kind == .dir)
            std.fmt.bufPrint(&buf, "“{s}” selected", .{nm}) catch ""
        else
            std.fmt.bufPrint(&buf, "“{s}” selected ({s})", .{ nm, model.formatSize(&sbuf, self.sel_bytes) }) catch "";
    } else {
        msg = std.fmt.bufPrint(&buf, "{d} of {d} items selected ({s})", .{ self.sel_count, n, model.formatSize(&sbuf, self.sel_bytes) }) catch "";
    }
    const txn = self.begin() orelse return;
    _ = c.siv_set_text(txn, self.status, msg.ptr, msg.len);
    _ = commit(txn);
}

pub fn toast(self: *Files, msg: []const u8, assertive: bool) void {
    const txn = self.begin() orelse return;
    _ = c.siv_toast(txn, self.root, &.{ .text = msg.ptr, .text_len = msg.len, .flags = .{ .assertive = assertive } });
    _ = commit(txn);
}

// Keyboard ----------------------------------------------------------------------------

fn onKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed) return .pass;
    const m = e.modifiers;
    const ctrl = m.ctrl and !m.alt;
    // Shortcuts that work everywhere, editors included.
    if (ctrl) switch (@intFromEnum(e.keysym)) {
        'l', 'L' => {
            self.showLocation(true);
            return .handled;
        },
        'f', 'F' => {
            _ = c.siv_node_focus(self.search);
            return .handled;
        },
        'w', 'W', 'q', 'Q' => {
            self.close();
            return .handled;
        },
        else => {},
    };
    if (m.alt and !m.ctrl) switch (e.keysym) {
        .left => {
            self.goBack();
            return .handled;
        },
        .right => {
            self.goForward();
            return .handled;
        },
        .up => {
            self.goUp();
            return .handled;
        },
        .home => {
            var buf: [linux.PATH_MAX]u8 = undefined;
            self.navigate(std.fmt.bufPrint(&buf, "{s}", .{self.home}) catch return .handled, .push);
            return .handled;
        },
        else => {},
    };
    switch (e.keysym) {
        .back => {
            self.goBack();
            return .handled;
        },
        .forward => {
            self.goForward();
            return .handled;
        },
        .f5 => {
            self.reload();
            return .handled;
        },
        else => {},
    }
    // The rest act on files; in an editor they are the editor's keys.
    if (self.inEditor()) return .pass;
    if (ctrl) switch (@intFromEnum(e.keysym)) {
        'a', 'A' => {
            self.selectAll();
            return .handled;
        },
        'c', 'C' => {
            self.copySelection(false);
            return .handled;
        },
        'x', 'X' => {
            self.copySelection(true);
            return .handled;
        },
        'v', 'V' => {
            self.paste();
            return .handled;
        },
        'h', 'H' => {
            self.setShowHidden(!self.show_hidden);
            return .handled;
        },
        'r', 'R' => {
            self.reload();
            return .handled;
        },
        '1' => {
            self.setMode(.list);
            return .handled;
        },
        '2' => {
            self.setMode(.grid);
            return .handled;
        },
        'n', 'N' => if (m.shift) {
            self.newFolder();
            return .handled;
        },
        else => {},
    };
    switch (e.keysym) {
        .backspace => {
            self.goUp();
            return .handled;
        },
        .f2 => {
            self.renameCursor();
            return .handled;
        },
        .delete => {
            if (m.shift) self.confirmDelete() else self.trashSelection();
            return .handled;
        },
        .menu => {
            self.openContextMenuAtCursor();
            return .handled;
        },
        .f10 => if (m.shift) {
            self.openContextMenuAtCursor();
            return .handled;
        },
        .escape => {
            const view = self.activeView();
            const txn = self.begin() orelse return .handled;
            self.clearSelection(txn, view);
            _ = commit(txn);
            self.updateStatus();
            return .handled;
        },
        else => {},
    }
    // Typing a name searches: the text goes to the search field.
    if (!m.ctrl and !m.alt and !m.super and e.text_len > 0 and e.text != null) {
        const t = e.text.?[0..e.text_len];
        if (t[0] >= 0x20 and t[0] != 0x7f and !(t.len == 1 and t[0] == ' ')) {
            var buf: [512]u8 = undefined;
            const q = std.fmt.bufPrint(&buf, "{s}{s}", .{ self.query.items, t }) catch return .handled;
            const txn = self.begin() orelse return .handled;
            _ = c.siv_set_text(txn, self.search, q.ptr, q.len);
            _ = c.siv_set_selection(txn, self.search, @intCast(q.len), @intCast(q.len));
            if (!commit(txn)) return .handled;
            self.setQuery(q);
            _ = c.siv_node_focus(self.search);
            return .handled;
        }
    }
    return .pass;
}

/// Whether keyboard focus is in one of the app's editors (search,
/// location, rename), whose keys are text rather than shortcuts.
fn inEditor(self: *Files) bool {
    var focus: Node = .null;
    _ = c.siv_window_get_focus(self.window, &focus);
    return focus != .null and (focus == self.search or focus == self.location or focus == self.rename_editor);
}

pub fn setShowHidden(self: *Files, on: bool) void {
    self.show_hidden = on;
    self.keepSelection(struct {
        fn apply(_: *Files) void {}
    });
    const txn = self.begin() orelse return;
    self.syncAppMenu(txn);
    _ = commit(txn);
}

fn onToggleMode(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.setMode(if (self.mode == .list) .grid else .list);
    return .handled;
}

fn onAppMenu(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    if (ev.?.index >= app_menu_items.len) return .handled;
    switch (@as(AppAction, @enumFromInt(ev.?.index))) {
        .new_folder => self.newFolder(),
        .hidden => self.setShowHidden(!self.show_hidden),
        .list => self.setMode(.list),
        .grid => self.setMode(.grid),
        .follow => self.setTheme(.follow),
        .light => self.setTheme(.light),
        .dark => self.setTheme(.dark),
        .close => self.close(),
        else => {},
    }
    return .handled;
}

pub fn setTheme(self: *Files, scheme: siv.ColorScheme) void {
    self.theme = scheme;
    _ = c.siv_app_set_theme(self.app, &.{ .scheme = scheme });
    const txn = self.begin() orelse return;
    self.syncAppMenu(txn);
    _ = commit(txn);
}

// Context menu ----------------------------------------------------------------------

fn onRowPointer(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const parts: *RowParts = @ptrCast(@alignCast(ud.?));
    const self = parts.files orelse return .pass;
    const e = ev.?;
    switch (e.phase) {
        .down => {
            if (e.button == .secondary) {
                // A right click on an unselected item selects only it.
                const vi = self.viewIndexOfEntry(parts.entry) orelse return .handled;
                var on = false;
                _ = c.siv_view_is_selected(self.activeView(), vi, &on);
                if (!on) {
                    const txn = self.begin() orelse return .handled;
                    self.clearSelection(txn, self.activeView());
                    _ = c.siv_view_set_selected(txn, self.activeView(), vi, true);
                    _ = c.siv_view_set_cursor(txn, self.activeView(), @intCast(vi));
                    _ = commit(txn);
                    self.updateStatus();
                }
                self.openContextMenu(node, e.x, e.y, true);
                return .handled;
            }
            if (e.button != .primary) return .pass;
            // The view keeps a larger selection on this press, so that the
            // drag carries all of it, and collapses it on release.
            self.dragArm(node, e, parts.entry);
            return .pass;
        },
        .move => {
            self.dragMove(node, e);
            return .pass;
        },
        .up, .cancel => {
            self.drag_armed = false;
            return .pass;
        },
        else => return .pass,
    }
}

fn onContentPointer(ud: ?*anyopaque, node: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (e.phase == .down and e.button == .secondary) {
        // Empty space: actions on the folder.
        const txn = self.begin() orelse return .handled;
        self.clearSelection(txn, self.activeView());
        _ = commit(txn);
        self.updateStatus();
        self.openContextMenu(node, e.x, e.y, false);
        return .handled;
    }
    return .pass;
}

fn isSelected(self: *Files, entry: u32) bool {
    const vi = self.viewIndexOfEntry(entry) orelse return false;
    var on = false;
    _ = c.siv_view_is_selected(self.activeView(), vi, &on);
    return on;
}

fn viewIndexOfEntry(self: *const Files, entry: u32) ?u32 {
    for (self.visible.items, 0..) |e, i| if (e == entry) return @intCast(i);
    return null;
}

/// The context menu from the keyboard (Menu, Shift+F10): at the cursor's
/// row when it is bound, else at the view's corner.
pub fn openContextMenuAtCursor(self: *Files) void {
    const sel = self.selectedIndices() catch return;
    defer self.gpa.free(sel);
    if (self.cursorRow()) |row| {
        var r: siv.Rect = .{};
        _ = c.siv_node_get_rect(row, &r);
        self.openContextMenu(row, @min(40, r.width), r.height, sel.len > 0);
    } else self.openContextMenu(self.activeView(), 40, 40, sel.len > 0);
}

/// The node showing the cursor's item, if its row is bound.
fn cursorRow(self: *Files) ?Node {
    const view = self.activeView();
    const cursor = self.cursorIndex() orelse return null;
    var row: Node = .null;
    _ = c.siv_view_get_row(view, cursor, &row);
    return if (row == .null) null else row;
}

/// The active view's cursor.
fn cursorIndex(self: *Files) ?u32 {
    var cursor: i32 = -1;
    _ = c.siv_view_get_cursor(self.activeView(), &cursor);
    return if (cursor >= 0 and cursor < self.visible.items.len) @intCast(cursor) else null;
}

/// Opens the context menu at (x, y) in `node`, for the selection
/// (`on_items`) or the folder.
pub fn openContextMenu(self: *Files, node: Node, x: f32, y: f32, on_items: bool) void {
    const txn = self.begin() orelse return;
    const disable = [_]struct { ContextAction, bool }{
        .{ .open, !on_items },
        .{ .open_with, !on_items },
        .{ .cut, !on_items },
        .{ .copy, !on_items },
        .{ .rename, !on_items },
        .{ .trash, !on_items },
        .{ .delete, !on_items },
        .{ .paste, false },
    };
    for (disable) |d| _ = c.siv_widget_set_disabled(txn, menuItem(self.context, @intFromEnum(d[0])), d[1]);
    if (!commit(txn)) return;
    _ = c.siv_menu_open_at(self.context, node, x, y);
}

fn onContextSelect(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    if (ev.?.index >= context_items.len) return .handled;
    self.runContextAction(@enumFromInt(ev.?.index));
    return .handled;
}

pub fn runContextAction(self: *Files, action: ContextAction) void {
    switch (action) {
        .open, .open_with => {
            const sel = self.selectedIndices() catch return;
            defer self.gpa.free(sel);
            for (sel) |vi| self.openItem(vi, action == .open_with);
        },
        .cut => self.copySelection(true),
        .copy => self.copySelection(false),
        .paste => self.paste(),
        .rename => self.renameCursor(),
        .trash => self.trashSelection(),
        .delete => self.confirmDelete(),
        .new_folder => self.newFolder(),
        .select_all => self.selectAll(),
        else => {},
    }
}

// Rename in place ---------------------------------------------------------------------

fn renameCursor(self: *Files) void {
    const sel = self.selectedIndices() catch return;
    defer self.gpa.free(sel);
    const vi: u32 = if (sel.len == 1) sel[0] else self.cursorIndex() orelse return;
    self.startRename(vi);
}

pub fn startRename(self: *Files, vi: u32) void {
    if (vi >= self.visible.items.len) return;
    self.renaming = self.visible.items[vi];
    const txn = self.begin() orelse return;
    _ = c.siv_view_set_cursor(txn, self.activeView(), @intCast(vi));
    // Rebinding puts the editor in the row (bindRename).
    _ = c.siv_view_refresh(txn, self.activeView());
    if (!commit(txn)) return;
    if (self.rename_editor != .null) _ = c.siv_node_focus(self.rename_editor);
}

/// Shows the rename editor in the row that shows `entry`, or takes it out
/// of a row that no longer does.
fn bindRename(self: *Files, txn: Txn, parts: *RowParts, entry: u32) void {
    var parent: Node = .null;
    _ = c.siv_node_get_related(parts.name, .parent, &parent);
    const want = self.renaming != null and self.renaming.? == entry;
    // Is the editor in this row?
    var has = false;
    if (self.rename_editor != .null) {
        var ep: Node = .null;
        _ = c.siv_node_get_related(self.rename_editor, .parent, &ep);
        has = ep == parent;
    }
    if (want and !has) {
        if (self.rename_editor != .null) _ = c.siv_remove(txn, self.rename_editor);
        const nm = self.nameOf(entry);
        const ed = c.siv_text_field(txn, parent, &.{ .text = nm.ptr, .text_len = nm.len, .label = "New name", .label_len = 8 });
        _ = c.siv_set_layout(txn, ed, &.{ .grow = 1, .basis = px(0) });
        // Select the name without its extension, as file managers do.
        const dot = std.mem.lastIndexOfScalar(u8, nm, '.');
        const stem: u32 = @intCast(if (dot) |d| (if (d == 0) nm.len else d) else nm.len);
        _ = c.siv_set_selection(txn, ed, stem, 0);
        _ = c.siv_on(txn, ed, .key, onRenameKey, null, self);
        _ = c.siv_on(txn, ed, .focus, onRenameFocus, null, self);
        self.rename_editor = ed;
        _ = c.siv_set_visual(txn, parts.name, &.{ .flags = .{ .hidden = true } });
    } else if (!want) {
        if (has) {
            _ = c.siv_remove(txn, self.rename_editor);
            self.rename_editor = .null;
        }
        _ = c.siv_set_visual(txn, parts.name, &.{});
    }
}

fn onRenameKey(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    const e = ev.?;
    if (!e.flags.pressed) return .pass;
    switch (e.keysym) {
        .@"return", .kp_enter => {
            self.finishRename(true);
            return .handled;
        },
        .escape => {
            self.finishRename(false);
            return .handled;
        },
        // The rest are the editor's: neither the row nor the window's
        // shortcuts see them, and the editor still types them.
        else => return .stop,
    }
}

fn onRenameFocus(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    if (!ev.?.flags.gained and self.renaming != null) self.finishRename(true);
    return .pass;
}

fn cancelRename(self: *Files) void {
    self.renaming = null;
    self.rename_editor = .null;
}

fn finishRename(self: *Files, apply: bool) void {
    const entry = self.renaming orelse return;
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    if (self.rename_editor != .null) _ = c.siv_node_get_text(self.rename_editor, &buf, buf.len, &len);
    const new = std.mem.trim(u8, buf[0..@min(len, buf.len)], " ");
    const old = self.nameOf(entry);
    var old_buf: [512]u8 = undefined;
    const old_copy = std.fmt.bufPrint(&old_buf, "{s}", .{old}) catch return;
    self.renaming = null;
    const txn = self.begin() orelse return;
    _ = c.siv_view_refresh(txn, self.activeView());
    _ = commit(txn);
    self.focusView();
    if (!apply or std.mem.eql(u8, new, old_copy)) return;
    fsops.rename(self.path, old_copy, new) catch |err| {
        var mbuf: [256]u8 = undefined;
        self.toast(std.fmt.bufPrint(&mbuf, "Could not rename “{s}”: {s}", .{ old_copy, fsops.describe(err) }) catch "Could not rename", true);
        return;
    };
    self.pending_select.clearRetainingCapacity();
    self.pending_select.appendSlice(self.gpa, new) catch {};
    self.pending_select.append(self.gpa, '\n') catch {};
    self.startLoad();
}

// Folders and file operations ---------------------------------------------------------

pub fn newFolder(self: *Files) void {
    var buf: [64]u8 = undefined;
    var k: u32 = 1;
    var name: []const u8 = "New Folder";
    while (k < 1000) : (k += 1) {
        name = if (k == 1) "New Folder" else std.fmt.bufPrint(&buf, "New Folder ({d})", .{k}) catch return;
        fsops.makeDir(self.path, name) catch |err| {
            if (err == error.Exists) continue;
            var mbuf: [256]u8 = undefined;
            self.toast(std.fmt.bufPrint(&mbuf, "Could not create a folder: {s}", .{fsops.describe(err)}) catch "Could not create a folder", true);
            return;
        };
        break;
    }
    self.pending_select.clearRetainingCapacity();
    self.pending_select.appendSlice(self.gpa, name) catch {};
    self.pending_select.append(self.gpa, '\n') catch {};
    self.pending_rename = true;
    self.startLoad();
}

pub fn trashSelection(self: *Files) void {
    const paths = self.selectedPaths() catch return;
    defer self.freePaths(paths);
    if (paths.len == 0) return;
    // Items in the trash are deleted for good.
    const in_trash = std.mem.startsWith(u8, self.path, self.places.trash_dir);
    self.startOp(if (in_trash) .delete else .trash, paths, "");
}

fn confirmDelete(self: *Files) void {
    const paths = self.selectedPaths() catch return;
    defer self.freePaths(paths);
    if (paths.len == 0 or self.dialog != .null) return;
    var buf: [512]u8 = undefined;
    const title = if (paths.len == 1)
        std.fmt.bufPrint(&buf, "Permanently delete “{s}”?", .{model.basename(paths[0])}) catch "Permanently delete?"
    else
        std.fmt.bufPrint(&buf, "Permanently delete {d} items?", .{paths.len}) catch "Permanently delete?";
    const msg = "Deleted items are not sent to the trash and cannot be restored.";
    const txn = self.begin() orelse return;
    const d = c.siv_dialog(txn, self.root, &.{ .title = title.ptr, .title_len = title.len, .text = msg, .text_len = msg.len });
    var actions: Node = .null;
    _ = c.siv_widget_get_part(d, .actions, 0, &actions);
    const cancel = c.siv_push_button(txn, actions, &.{ .label = "Cancel", .label_len = 6 });
    const del = c.siv_push_button(txn, actions, &.{ .label = "Delete", .label_len = 6, .style = .destructive });
    _ = c.siv_on(txn, cancel, .activate, onDialogCancel, null, self);
    _ = c.siv_on(txn, del, .activate, onDialogDelete, null, self);
    _ = c.siv_on(txn, d, .close, onDialogClose, null, self);
    if (!commit(txn)) return;
    self.dialog = d;
    _ = c.siv_node_focus(cancel);
}

fn closeDialog(self: *Files) void {
    if (self.dialog == .null) return;
    const txn = self.begin() orelse return;
    _ = c.siv_remove(txn, self.dialog);
    _ = commit(txn);
    self.dialog = .null;
}

fn onDialogClose(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.closeDialog();
    return .handled;
}

fn onDialogCancel(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.closeDialog();
    return .handled;
}

fn onDialogDelete(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.closeDialog();
    const paths = self.selectedPaths() catch return .handled;
    defer self.freePaths(paths);
    self.startOp(.delete, paths, "");
    return .handled;
}

const OpJob = struct {
    files: ?*Files,
    op: *fsops.Op,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const j: *OpJob = @ptrCast(@alignCast(ud.?));
        j.op.run();
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const j: *OpJob = @ptrCast(@alignCast(ud.?));
        if (j.files) |self| self.opFinished(j.op);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const j: *OpJob = @ptrCast(@alignCast(ud.?));
        const gpa = j.op.gpa;
        j.op.destroy();
        gpa.destroy(j);
    }
};

/// Runs a file operation on the worker pool, with progress in the
/// operations bar.
pub fn startOp(self: *Files, kind: fsops.Kind, sources: []const []const u8, dest: []const u8) void {
    const gpa = self.gpa;
    const op = fsops.Op.create(gpa, kind, sources, dest) catch return;
    if (kind == .trash) op.trash_dir = gpa.dupe(u8, self.places.trash_dir) catch &.{};
    const j = gpa.create(OpJob) catch {
        op.destroy();
        return;
    };
    j.* = .{ .files = self, .op = op };
    self.ops.append(gpa, op) catch {
        op.destroy();
        gpa.destroy(j);
        return;
    };
    self.op_jobs.append(gpa, j) catch {};
    if (c.siv_job_start(self.app, .{}, OpJob.work, OpJob.done, OpJob.destroy, j) != .ok) {
        _ = self.ops.pop();
        _ = self.op_jobs.pop();
        return;
    }
    self.updateOps();
    if (self.ops_timer == .null) _ = c.siv_timer_start(self.app, 100, onOpsTimer, null, self, &self.ops_timer);
}

fn onOpsTimer(ud: ?*anyopaque) callconv(.c) void {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.ops_timer = .null;
    self.updateOps();
    if (self.ops.items.len != 0) _ = c.siv_timer_start(self.app, 100, onOpsTimer, null, self, &self.ops_timer);
}

fn onCancelOps(ud: ?*anyopaque, _: Node, _: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    for (self.ops.items) |op| op.cancel.store(true, .release);
    return .handled;
}

fn opFinished(self: *Files, op: *fsops.Op) void {
    for (self.ops.items, 0..) |o, i| if (o == op) {
        _ = self.ops.orderedRemove(i);
        break;
    };
    for (self.op_jobs.items, 0..) |j, i| if (j.op == op) {
        j.files = null;
        _ = self.op_jobs.orderedRemove(i);
        break;
    };
    var buf: [512]u8 = undefined;
    if (op.result) |err| {
        if (err == error.Canceled) {
            self.toast("Canceled", false);
        } else {
            const verb = switch (op.kind) {
                .copy => "copy",
                .move => "move",
                .trash => "move to the trash",
                .delete => "delete",
            };
            self.toast(std.fmt.bufPrint(&buf, "Could not {s} “{s}”: {s}", .{ verb, model.basename(op.errPath()), fsops.describe(err) }) catch "The operation failed", true);
        }
    } else {
        const n = op.sources.len;
        const what = if (n == 1) model.basename(op.sources[0]) else "";
        const msg = switch (op.kind) {
            .copy => if (n == 1) std.fmt.bufPrint(&buf, "Copied “{s}”", .{what}) else std.fmt.bufPrint(&buf, "Copied {d} items", .{n}),
            .move => if (n == 1) std.fmt.bufPrint(&buf, "Moved “{s}”", .{what}) else std.fmt.bufPrint(&buf, "Moved {d} items", .{n}),
            .trash => if (n == 1) std.fmt.bufPrint(&buf, "“{s}” moved to the trash", .{what}) else std.fmt.bufPrint(&buf, "{d} items moved to the trash", .{n}),
            .delete => if (n == 1) std.fmt.bufPrint(&buf, "“{s}” deleted", .{what}) else std.fmt.bufPrint(&buf, "{d} items deleted", .{n}),
        } catch "";
        self.toast(msg, false);
        // Select what a paste brought here.
        if ((op.kind == .copy or op.kind == .move) and std.mem.eql(u8, op.dest, self.path)) {
            self.pending_select.clearRetainingCapacity();
            self.pending_select.appendSlice(self.gpa, op.created.items) catch {};
        }
    }
    self.updateOps();
    self.reloadSoon(0);
}

pub fn updateOps(self: *Files) void {
    if (self.window == .null) return;
    const txn = self.begin() orelse return;
    _ = c.siv_set_visual(txn, self.ops_bar, &.{ .background_token = .card_bg, .flags = .{ .hidden = self.ops.items.len == 0 } });
    if (self.ops.items.len != 0) {
        var total: u64 = 0;
        var done: u64 = 0;
        var items: u32 = 0;
        var done_items: u32 = 0;
        var scanning = false;
        for (self.ops.items) |op| {
            total += op.total_bytes.load(.monotonic);
            done += op.done_bytes.load(.monotonic);
            items += op.total_items.load(.monotonic);
            done_items += op.done_items.load(.monotonic);
            scanning = scanning or op.scanning.load(.monotonic);
        }
        const op = self.ops.items[0];
        const verb = switch (op.kind) {
            .copy => "Copying",
            .move => "Moving",
            .trash => "Moving to the trash",
            .delete => "Deleting",
        };
        var buf: [256]u8 = undefined;
        const frac: f64 = if (total > 0) @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(total)) else if (items > 0) @as(f64, @floatFromInt(done_items)) / @as(f64, @floatFromInt(items)) else 0;
        var sbuf: [32]u8 = undefined;
        var tbuf: [32]u8 = undefined;
        const msg = if (scanning)
            std.fmt.bufPrint(&buf, "Preparing to {s}…", .{verb}) catch ""
        else if (total > 0)
            std.fmt.bufPrint(&buf, "{s} {d} of {d} items — {s} of {s}", .{ verb, done_items, items, model.formatSize(&sbuf, done), model.formatSize(&tbuf, total) }) catch ""
        else
            std.fmt.bufPrint(&buf, "{s} {d} of {d} items", .{ verb, done_items, items }) catch "";
        _ = c.siv_set_text(txn, self.ops_label, msg.ptr, msg.len);
        _ = c.siv_widget_set_value(txn, self.ops_progress, @min(100, frac * 100));
    }
    _ = commit(txn);
}

/// Reloads after `ms`, once, however many changes arrive meanwhile.
pub fn reloadSoon(self: *Files, ms: u32) void {
    if (self.reload_timer != .null) return;
    _ = c.siv_timer_start(self.app, ms, onReloadTimer, null, self, &self.reload_timer);
}

fn onReloadTimer(ud: ?*anyopaque) callconv(.c) void {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    self.reload_timer = .null;
    self.reload();
}

fn watch(self: *Files) void {
    if (self.watcher == null) self.watcher = Watcher.create(self.gpa, self.app, onWatch, self) catch null;
    if (self.watcher) |wt| wt.setPath(self.path);
}

fn onWatch(ctx: ?*anyopaque) void {
    const self: *Files = @ptrCast(@alignCast(ctx.?));
    // Coalesce bursts (a copy of many files) into one reload.
    self.reloadSoon(150);
}

// Clipboard ---------------------------------------------------------------------------

/// The selection's paths as text/uri-list, x-special/gnome-copied-files
/// (with "copy" or "cut" first, so a paste here or in GNOME Files moves
/// cut files), and plain text, for the clipboard and drags.
const Offer = struct {
    data: std.ArrayList(u8) = .empty,
    lengths: [3]usize = .{ 0, 0, 0 },

    fn deinit(o: *Offer, gpa: Allocator) void {
        o.data.deinit(gpa);
    }

    fn build(gpa: Allocator, paths: []const []const u8, cut: bool, gnome: bool) !Offer {
        var o: Offer = .{};
        errdefer o.deinit(gpa);
        var start = o.data.items.len;
        for (paths) |p| {
            try uri.appendFileUri(&o.data, gpa, p);
            try o.data.appendSlice(gpa, "\r\n");
        }
        o.lengths[0] = o.data.items.len - start;
        var k: usize = 1;
        if (gnome) {
            start = o.data.items.len;
            try o.data.appendSlice(gpa, if (cut) "cut" else "copy");
            for (paths) |p| {
                try o.data.append(gpa, '\n');
                try uri.appendFileUri(&o.data, gpa, p);
            }
            o.lengths[k] = o.data.items.len - start;
            k += 1;
        }
        start = o.data.items.len;
        for (paths, 0..) |p, i| {
            if (i > 0) try o.data.append(gpa, '\n');
            try o.data.appendSlice(gpa, p);
        }
        o.lengths[k] = o.data.items.len - start;
        return o;
    }
};

pub fn copySelection(self: *Files, cut: bool) void {
    const paths = self.selectedPaths() catch return;
    defer self.freePaths(paths);
    if (paths.len == 0) return;
    var o = Offer.build(self.gpa, paths, cut, true) catch return;
    defer o.deinit(self.gpa);
    const mimes = "text/uri-list\nx-special/gnome-copied-files\ntext/plain;charset=utf-8";
    const r = c.siv_clipboard_write_data(self.window, .clipboard, &.{ .mimes = mimes, .mimes_len = mimes.len, .data = o.data.items.ptr, .data_count = o.data.items.len, .lengths = &o.lengths, .lengths_count = 3 });
    if (r != .ok) return self.toast("Could not copy to the clipboard", true);
    var buf: [128]u8 = undefined;
    const what = if (paths.len == 1) std.fmt.bufPrint(&buf, "“{s}”", .{model.basename(paths[0])}) catch "" else std.fmt.bufPrint(&buf, "{d} items", .{paths.len}) catch "";
    var mbuf: [192]u8 = undefined;
    self.toast(std.fmt.bufPrint(&mbuf, "{s} {s}", .{ if (cut) "Cut" else "Copied", what }) catch "", false);
}

/// A callback's way back to the window, which may be gone when it runs:
/// `files` is cleared when the window closes, and the token freed by the
/// callback's destroy-notify.
const Token = struct {
    files: ?*Files,
    gpa: Allocator,
    /// Where pasted or dropped files go (owned).
    dest: []u8 = &.{},

    fn create(self: *Files, dest: []const u8) ?*Token {
        const t = self.gpa.create(Token) catch return null;
        t.* = .{ .files = self, .gpa = self.gpa, .dest = self.gpa.dupe(u8, dest) catch &.{} };
        self.tokens.append(self.gpa, t) catch {
            self.gpa.free(t.dest);
            self.gpa.destroy(t);
            return null;
        };
        return t;
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const t: *Token = @ptrCast(@alignCast(ud.?));
        if (t.files) |self| for (self.tokens.items, 0..) |x, i| if (x == t) {
            _ = self.tokens.swapRemove(i);
            break;
        };
        t.gpa.free(t.dest);
        t.gpa.destroy(t);
    }
};

pub fn paste(self: *Files) void {
    self.pasteInto(self.path);
}

fn pasteInto(self: *Files, dest: []const u8) void {
    const tok = Token.create(self, dest) orelse return;
    const mimes = "x-special/gnome-copied-files\ntext/uri-list";
    _ = c.siv_clipboard_read_data(self.window, .clipboard, mimes, mimes.len, onPasted, Token.destroy, tok);
}

fn onPasted(ud: ?*anyopaque, d: ?*const siv.ClipboardData) callconv(.c) void {
    const tok: *Token = @ptrCast(@alignCast(ud.?));
    const self = tok.files orelse return;
    const x = d.?;
    if (x.result != .ok) return self.toast("Nothing to paste", false);
    const bytes = x.data.?[0..x.data_count];
    const g = if (x.index == 0) uri.gnomeCopied(bytes) else @TypeOf(uri.gnomeCopied(bytes)){ .cut = false, .uris = bytes };
    self.transferUris(g.uris, tok.dest, if (g.cut) .move else .copy);
}

/// Copies or moves the local files of a URI list into `dest`.
fn transferUris(self: *Files, uris: []const u8, dest: []const u8, kind: fsops.Kind) void {
    const gpa = self.gpa;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var it: uri.Lines = .{ .rest = uris };
    while (it.next()) |u| {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const p = uri.filePath(&buf, u) orelse continue;
        const copy = gpa.dupe(u8, p) catch return;
        paths.append(gpa, copy) catch {
            gpa.free(copy);
            return;
        };
    }
    if (paths.items.len == 0) return self.toast("Only local files can be pasted here", false);
    self.startOp(kind, paths.items, dest);
}

// Drag and drop -------------------------------------------------------------------------

/// A press on an item may start a drag once the pointer moves this far.
const drag_threshold: f32 = 6;

fn dragArm(self: *Files, node: Node, e: *const siv.Event, entry: u32) void {
    _ = node;
    self.drag_armed = true;
    self.drag_x = e.x;
    self.drag_y = e.y;
    self.drag_entry = entry;
}

fn dragMove(self: *Files, node: Node, e: *const siv.Event) void {
    if (!self.drag_armed) return;
    if (@abs(e.x - self.drag_x) < drag_threshold and @abs(e.y - self.drag_y) < drag_threshold) return;
    self.drag_armed = false;
    const paths = self.selectedPaths() catch return;
    defer self.freePaths(paths);
    if (paths.len == 0) return;
    var o = Offer.build(self.gpa, paths, false, false) catch return;
    defer o.deinit(self.gpa);
    const mimes = "text/uri-list\ntext/plain;charset=utf-8";
    _ = c.siv_drag_start(node, &.{
        .mimes = mimes,
        .mimes_len = mimes.len,
        .data = o.data.items.ptr,
        .data_count = o.data.items.len,
        .lengths = &o.lengths,
        .lengths_count = 2,
        .actions = .{ .copy = true, .move = true },
    });
}

/// Drops of files: on the view (into the folder shown), on a folder's row,
/// or on a place in the sidebar.
fn acceptDrop(self: *Files, ev: *const siv.Event, dest: []const u8) bool {
    switch (ev.phase) {
        .enter, .move => return dest.len != 0,
        .drop => {
            const data = if (ev.data) |p| p[0..ev.data_count] else return false;
            self.transferUris(data, dest, if (ev.action == .move) .move else .copy);
            return true;
        },
        else => return false,
    }
}

fn onDrop(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const self: *Files = @ptrCast(@alignCast(ud.?));
    var buf: [linux.PATH_MAX]u8 = undefined;
    const dest = std.fmt.bufPrint(&buf, "{s}", .{self.path}) catch return .pass;
    return if (self.acceptDrop(ev.?, dest)) .handled else .pass;
}

fn onRowDrop(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const parts: *RowParts = @ptrCast(@alignCast(ud.?));
    const self = parts.files orelse return .pass;
    const l = &(self.listing orelse return .pass);
    if (parts.entry >= l.entries.len or l.entries[parts.entry].kind != .dir) return .pass;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const dest = model.join(&buf, l.path, l.name(l.entries[parts.entry])) orelse return .pass;
    return if (self.acceptDrop(ev.?, dest)) .handled else .pass;
}

fn onPlaceDrop(ud: ?*anyopaque, _: Node, ev: ?*const siv.Event) callconv(.c) siv.EventResult {
    const parts: *PlaceParts = @ptrCast(@alignCast(ud.?));
    const self = parts.files orelse return .pass;
    if (parts.index >= self.places.items.items.len) return .pass;
    const pl = self.places.items.items[parts.index];
    var buf: [linux.PATH_MAX]u8 = undefined;
    const dest = std.fmt.bufPrint(&buf, "{s}", .{pl.path}) catch return .pass;
    // Dropping on the trash moves there.
    if (pl.icon == .trash and ev.?.phase == .drop) {
        const data = if (ev.?.data) |p| p[0..ev.?.data_count] else return .pass;
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| self.gpa.free(p);
            paths.deinit(self.gpa);
        }
        var it: uri.Lines = .{ .rest = data };
        while (it.next()) |u| {
            var pb: [linux.PATH_MAX]u8 = undefined;
            const p = uri.filePath(&pb, u) orelse continue;
            paths.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch {};
        }
        if (paths.items.len != 0) self.startOp(.trash, paths.items, "");
        return .handled;
    }
    return if (self.acceptDrop(ev.?, dest)) .handled else .pass;
}
