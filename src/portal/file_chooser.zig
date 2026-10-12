//! org.freedesktop.portal.FileChooser: the system's file chooser (D19).
//! siv has no chooser of its own; this is the only one.

const std = @import("std");
const dbus = @import("dbus");
const Client = @import("Client.zig");
const Request = @import("Request.zig");
const vardict = @import("vardict.zig");

pub const interface = "org.freedesktop.portal.FileChooser";

pub const Mode = enum { open, save };

pub const PatternKind = enum(u32) { glob = 0, mime = 1 };

/// A glob such as "*.png" (case-sensitive, as the portal matches) or a
/// MIME type such as "image/png".
pub const Pattern = struct { kind: PatternKind, pattern: []const u8 };

pub const Filter = struct { name: []const u8, patterns: []const Pattern };

pub const ChoiceOption = struct { id: []const u8, label: []const u8 };

/// A combo box (with options) or a check box (without; its values are
/// "true" and "false").
pub const Choice = struct {
    id: []const u8,
    label: []const u8,
    options: []const ChoiceOption = &.{},
    initial: []const u8 = "",
};

pub const Options = struct {
    mode: Mode = .open,
    title: []const u8 = "",
    accept_label: []const u8 = "",
    modal: bool = true,
    /// Open: allow several files.
    multiple: bool = false,
    /// Open: choose folders instead of files.
    directory: bool = false,
    filters: []const Filter = &.{},
    /// Index into `filters` of the filter selected at first.
    current_filter: ?usize = null,
    choices: []const Choice = &.{},
    /// Save: the suggested file name.
    current_name: []const u8 = "",
    /// The folder to start in (a path).
    current_folder: []const u8 = "",
    /// Save: an existing file to save over (a path).
    current_file: []const u8 = "",
};

/// Shows the chooser for the window `parent` ("wayland:<handle>", or
/// empty). The request's results hold `uris` (as), `choices` (a(ss)),
/// and `current_filter` (sa(us)); see `Results`.
pub fn start(r: *Request, client: *Client, parent: []const u8, o: Options) dbus.Connection.Error!void {
    const tok = r.token(client);
    var b = client.conn.methodCall(Client.portal_name, Client.portal_path, interface, if (o.mode == .open) "OpenFile" else "SaveFile");
    write(&b.body, tok, parent, o) catch |err| {
        b.deinit();
        return err;
    };
    try r.start(&b);
}

fn write(e: *dbus.Encoder, tok: []const u8, parent: []const u8, o: Options) dbus.codec.EncodeError!void {
    try e.writeAll(.{ parent, o.title });
    const w = try vardict.Writer.begin(e);
    try w.put("handle_token", tok);
    if (o.accept_label.len > 0) try w.put("accept_label", o.accept_label);
    try w.put("modal", o.modal);
    if (o.mode == .open) {
        if (o.multiple) try w.put("multiple", true);
        if (o.directory) try w.put("directory", true);
    }
    if (o.filters.len > 0) {
        try w.open("filters", "a(sa(us))");
        try e.beginArray("(sa(us))");
        for (o.filters) |f| try writeFilter(e, f);
        try e.endArray();
        try w.close();
    }
    if (o.current_filter) |i| if (i < o.filters.len) {
        try w.open("current_filter", "(sa(us))");
        try writeFilter(e, o.filters[i]);
        try w.close();
    };
    if (o.choices.len > 0) {
        try w.open("choices", "a(ssa(ss)s)");
        try e.beginArray("(ssa(ss)s)");
        for (o.choices) |c| {
            try e.beginStruct();
            try e.writeAll(.{ c.id, c.label });
            try e.beginArray("(ss)");
            for (c.options) |opt| try e.write(.{ opt.id, opt.label });
            try e.endArray();
            try e.writeString(c.initial);
            try e.endStruct();
        }
        try e.endArray();
        try w.close();
    }
    if (o.mode == .save) {
        if (o.current_name.len > 0) try w.put("current_name", o.current_name);
        if (o.current_file.len > 0) try w.path("current_file", o.current_file);
    }
    if (o.current_folder.len > 0) try w.path("current_folder", o.current_folder);
    try w.end();
}

fn writeFilter(e: *dbus.Encoder, f: Filter) dbus.codec.EncodeError!void {
    try e.beginStruct();
    try e.writeString(f.name);
    try e.beginArray("(us)");
    for (f.patterns) |p| try e.write(.{ @intFromEnum(p.kind), p.pattern });
    try e.endArray();
    try e.endStruct();
}

/// Reads a chooser's results.
pub const Results = struct {
    r: vardict.Reader,

    /// The chosen files and folders as file:// URIs; inside Flatpak they
    /// point into the document portal's mount.
    pub fn uris(res: *const Results) ?vardict.StringIterator {
        return res.r.strings("uris");
    }

    /// The value the user chose for choice `id`.
    pub fn choice(res: *const Results, id: []const u8) ?[]const u8 {
        var d = res.r.get("choices", "a(ss)") orelse return null;
        const a = d.beginArray() catch return null;
        while (a.next(&d)) {
            const kv = d.read(struct { []const u8, []const u8 }) catch return null;
            if (std.mem.eql(u8, kv[0], id)) return kv[1];
        }
        return null;
    }

    /// The name of the filter selected when the user accepted.
    pub fn filterName(res: *const Results) ?[]const u8 {
        var d = res.r.get("current_filter", "(sa(us))") orelse return null;
        d.beginStruct() catch return null;
        return d.readString() catch null;
    }
};
