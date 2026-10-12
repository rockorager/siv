//! AT-SPI 2 constants (at-spi2-core's atspi-constants.h) and the mapping
//! from siv's semantics roles and properties to them.

const std = @import("std");
const ui = @import("ui");

pub const registry_name = "org.a11y.atspi.Registry";
pub const root_path = "/org/a11y/atspi/accessible/root";
pub const null_path = "/org/a11y/atspi/null";
pub const accessible_prefix = "/org/a11y/atspi/accessible";

pub const iface = struct {
    pub const accessible = "org.a11y.atspi.Accessible";
    pub const application = "org.a11y.atspi.Application";
    pub const component = "org.a11y.atspi.Component";
    pub const action = "org.a11y.atspi.Action";
    pub const text = "org.a11y.atspi.Text";
    pub const editable_text = "org.a11y.atspi.EditableText";
    pub const value = "org.a11y.atspi.Value";
    pub const selection = "org.a11y.atspi.Selection";
    pub const socket = "org.a11y.atspi.Socket";
    pub const event_object = "org.a11y.atspi.Event.Object";
    pub const event_window = "org.a11y.atspi.Event.Window";
};

/// AtspiRole values used by siv.
pub const Role = enum(u32) {
    alert = 2,
    canvas = 6,
    check_box = 7,
    column_header = 10,
    combo_box = 11,
    dialog = 16,
    frame = 23,
    image = 27,
    label = 29,
    list = 31,
    list_item = 32,
    menu = 33,
    menu_bar = 34,
    menu_item = 35,
    page_tab = 37,
    page_tab_list = 38,
    panel = 39,
    password_text = 40,
    progress_bar = 42,
    button = 43,
    radio_button = 44,
    scroll_pane = 49,
    separator = 50,
    slider = 51,
    spin_button = 52,
    status_bar = 54,
    table = 55,
    table_cell = 56,
    text = 61,
    toggle_button = 62,
    tool_bar = 63,
    tool_tip = 64,
    tree = 65,
    unknown = 67,
    paragraph = 73,
    application = 75,
    entry = 79,
    document_frame = 82,
    heading = 83,
    link = 88,
    table_row = 90,
    tree_item = 91,
    grouping = 99,
    notification = 101,
    _,

    /// The role's name as libatspi spells it (GetRoleName).
    pub fn name(r: Role) []const u8 {
        return switch (r) {
            .alert => "alert",
            .canvas => "canvas",
            .check_box => "check box",
            .column_header => "column header",
            .combo_box => "combo box",
            .dialog => "dialog",
            .frame => "frame",
            .image => "image",
            .label => "label",
            .list => "list",
            .list_item => "list item",
            .menu => "menu",
            .menu_bar => "menu bar",
            .menu_item => "menu item",
            .page_tab => "page tab",
            .page_tab_list => "page tab list",
            .panel => "panel",
            .password_text => "password text",
            .progress_bar => "progress bar",
            .button => "push button",
            .radio_button => "radio button",
            .scroll_pane => "scroll pane",
            .separator => "separator",
            .slider => "slider",
            .spin_button => "spin button",
            .status_bar => "status bar",
            .table => "table",
            .table_cell => "table cell",
            .text => "text",
            .toggle_button => "toggle button",
            .tool_bar => "tool bar",
            .tool_tip => "tool tip",
            .tree => "tree",
            .unknown => "unknown",
            .paragraph => "paragraph",
            .application => "application",
            .entry => "entry",
            .document_frame => "document frame",
            .heading => "heading",
            .link => "link",
            .table_row => "table row",
            .tree_item => "tree item",
            .grouping => "grouping",
            .notification => "notification",
            _ => "unknown",
        };
    }
};

/// The AT-SPI role of a semantics node. Switches are toggle buttons: the
/// switch role is newer (at-spi2-core 2.56) than the registries and
/// screen readers in current distributions.
pub fn role(r: ui.Role, masked: bool) Role {
    return switch (r) {
        .none, .generic, .tab_panel => .panel,
        .window => .frame,
        .group => .grouping,
        .label => .label,
        .paragraph => .paragraph,
        .heading => .heading,
        .link => .link,
        .button => .button,
        .toggle_button, .@"switch" => .toggle_button,
        .checkbox => .check_box,
        .radio => .radio_button,
        .text_input => if (masked) .password_text else .entry,
        .image => .image,
        .scroll_area => .scroll_pane,
        .list => .list,
        .list_item => .list_item,
        .tree => .tree,
        .tree_item => .tree_item,
        .table => .table,
        .row => .table_row,
        .cell => .table_cell,
        .column_header => .column_header,
        .tab_list => .page_tab_list,
        .tab => .page_tab,
        .menu => .menu,
        .menu_bar => .menu_bar,
        .menu_item => .menu_item,
        .toolbar => .tool_bar,
        .dialog => .dialog,
        .alert => .notification,
        .status => .status_bar,
        .tooltip => .tool_tip,
        .slider => .slider,
        .spin_button => .spin_button,
        .progress_bar => .progress_bar,
        .separator => .separator,
        .combo_box => .combo_box,
        .canvas => .canvas,
        .document => .document_frame,
    };
}

/// AtspiStateType.
pub const State = enum(u6) {
    active = 1,
    busy = 3,
    checked = 4,
    collapsed = 5,
    defunct = 6,
    editable = 7,
    enabled = 8,
    expandable = 9,
    expanded = 10,
    focusable = 11,
    focused = 12,
    horizontal = 14,
    modal = 16,
    multi_line = 17,
    pressed = 20,
    resizable = 21,
    selectable = 22,
    selected = 23,
    sensitive = 24,
    showing = 25,
    single_line = 26,
    visible = 30,
    indeterminate = 32,
    selectable_text = 38,
    checkable = 41,
    read_only = 43,

    /// The name StateChanged events carry (libatspi's nick).
    pub fn nick(s: State) []const u8 {
        return switch (s) {
            .single_line => "single-line",
            .multi_line => "multi-line",
            .selectable_text => "selectable-text",
            .read_only => "read-only",
            inline else => |t| @tagName(t),
        };
    }
};

/// A set of states, two 32-bit words on the wire.
pub const States = packed struct(u64) {
    bits: u64 = 0,

    pub fn with(s: States, st: State) States {
        return .{ .bits = s.bits | (@as(u64, 1) << @backingInt(st)) };
    }

    pub fn has(s: States, st: State) bool {
        return s.bits & (@as(u64, 1) << @backingInt(st)) != 0;
    }

    pub fn words(s: States) [2]u32 {
        return .{ @truncate(s.bits), @truncate(s.bits >> 32) };
    }
};

/// AtspiCoordType. On Wayland a client cannot know its position on the
/// screen, so screen coordinates are window coordinates.
pub const Coord = enum(u32) { screen = 0, window = 1, parent = 2, _ };

/// AtspiTextGranularity.
pub const Granularity = enum(u32) { char = 0, word = 1, sentence = 2, line = 3, paragraph = 4, _ };

/// AtspiTextBoundaryType (the deprecated GetText{Before,At,After}Offset).
pub const Boundary = enum(u32) { char = 0, word_start = 1, word_end = 2, sentence_start = 3, sentence_end = 4, line_start = 5, line_end = 6, _ };

/// AtspiLive, the politeness of an Announcement.
pub fn live(l: ui.Live) i32 {
    return switch (l) {
        .off => 0,
        .polite => 1,
        .assertive => 2,
    };
}

test "states encode into two words" {
    const s = (States{}).with(.focused).with(.indeterminate);
    try std.testing.expectEqual([2]u32{ 1 << 12, 1 }, s.words());
    try std.testing.expect(s.has(.focused) and !s.has(.checked));
    try std.testing.expectEqualStrings("selectable-text", State.selectable_text.nick());
    try std.testing.expectEqualStrings("focused", State.focused.nick());
}
