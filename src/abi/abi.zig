//! The C ABI (D1, D2): the exports of libsiv, one per function in api.zig.
//! Their parameter and return types come from the generated Zig wrapper
//! (`siv`), which matches the generated header; the comptime block below
//! checks every export against its schema signature. Exports go through
//! runtime.zig for argument checking, roots, and handles. The application
//! and windows are in application.zig, the tree in tree.zig.
//!
//! Imports: every internal module, build_options, siv (generated).

const std = @import("std");
const build_options = @import("build_options");
const t = @import("siv");
const schema = @import("schema.zig");
/// The schema (D3), for code compiled with libsiv's exports that reads it,
/// such as the Lua binding in the headless tests.
pub const api = @import("api.zig");

pub const runtime = @import("runtime.zig");
pub const handles = @import("handles.zig");
pub const alloc = @import("alloc.zig");
/// The application, its loop, and windows.
pub const application = @import("application.zig");
/// Transactions, nodes, and node events.
pub const tree = @import("tree.zig");
/// Canvases, drawing, and images.
pub const canvas = @import("canvas.zig");
/// External content: submitted frames and embedder surfaces.
pub const external = @import("external.zig");
/// Drag and drop.
pub const dnd = @import("dnd.zig");
/// The clipboard and primary selection.
pub const clipboard = @import("clipboard.zig");
/// Theming: scheme and contrast choices, color overrides.
pub const theme = @import("theme.zig");
/// Pointer cursors.
pub const cursor = @import("cursor.zig");
/// Desktop portals and application actions.
pub const portal = @import("portal.zig");
/// Printing and PDF output.
pub const print = @import("print.zig");
/// The system tray.
pub const tray = @import("tray.zig");
/// Decoding images.
pub const image_load = @import("image_load.zig");
/// Application file descriptors in the loop.
pub const watch = @import("watch.zig");
/// Themed icons.
pub const icon = @import("icon.zig");
/// The public D-Bus API.
pub const dbus = @import("dbus.zig");
/// Pointer constraints and shortcut inhibition.
pub const input = @import("input.zig");
/// The widget interface behind the generic siv_widget_* calls.
pub const widget = @import("widget.zig");
/// The desktop shell: outputs, layer windows, the session lock,
/// toplevels, workspaces, and idle watches.
pub const shell = @import("shell.zig");
/// Documents: HTML, CSS, and Markdown (D32).
pub const document = @import("document.zig");
/// Undo stacks (D35).
pub const undo = @import("undo.zig");
/// Settings and state (D36).
pub const settings = @import("settings.zig");
/// Driving and inspecting applications on the headless backend.
pub const testing = @import("testing.zig");

/// The generated wrapper's types, which the exports use.
pub const types = t;

/// The files that export schema functions.
const implementations = .{ @This(), application, tree, canvas, external, dnd, clipboard, theme, cursor, portal, print, tray, image_load, watch, icon, dbus, input, widget, shell, document, undo, settings, testing } ++ @import("widgets").implementations;

const version = build_options.version;

pub export fn siv_version() u32 {
    return api.makeVersion(version.major, version.minor, version.patch);
}

pub export fn siv_result_name(result: t.Result) [*:0]const u8 {
    inline for (comptime resultNames()) |entry| {
        if (@backingInt(result) == entry[0]) return entry[1];
    }
    return "SIV_RESULT_UNKNOWN";
}

fn resultNames() [api.result.@"enum".values.len]struct { i32, [:0]const u8 } {
    const e = api.result.@"enum";
    var names: [e.values.len]struct { i32, [:0]const u8 } = undefined;
    var buf: [64]u8 = undefined;
    for (e.values, &names) |v, *n| n.* = .{ v.value, std.fmt.comptimePrint("{s}{s}", .{ e.value_prefix.?, schema.upper(&buf, v.name) }) };
    return names;
}

// Every schema function is exported here with the signature the schema
// implies, and the schema follows the conventions.
comptime {
    @setEvalBranchQuota(1_000_000);
    if (schema.validate(api.spec, version)) |p| @compileError(api.spec.source ++ ": " ++ p.where ++ ": " ++ p.what);
    for (api.spec.functions) |f| {
        var found = false;
        for (implementations) |impl| if (@hasDecl(impl, f.name)) {
            if (found) @compileError("schema function exported twice: " ++ f.name);
            found = true;
            if (@TypeOf(@field(impl, f.name)) != @field(t.signatures, f.name)) @compileError("export does not match its schema signature: " ++ f.name);
        };
        if (!found) @compileError("schema function not exported: " ++ f.name);
    }
    runtime.checkDescriptors(t);
}

// The abi module's tests run elsewhere: its unit tests without siv in
// unit_tests.zig, the rest through the C API in the headless test binary
// (test/abi), so no test binary compiles all of siv for this module alone.
test {
    std.testing.refAllDecls(@This());
    _ = schema;
}
