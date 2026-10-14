//! The user guide's samples on the headless backend, and checks of the
//! guide's text: each test runs one sample unchanged, drives it like a
//! user, and compares its window with the screenshot the guide shows.
//!
//! To accept new screenshots: SIV_UPDATE_GOLDEN=1 zig build guide

const std = @import("std");
const abi = @import("abi");
const harness = @import("harness.zig");
const ui = @import("ui");

const testing = std.testing;
const Guide = harness.Guide;

comptime {
    _ = abi;
    // The C and Zig samples call these in place of siv's, also when a
    // test filter skips every test that runs one.
    _ = &harness.guide_app_create;
    _ = &harness.guide_window_create;
    _ = &harness.guide_app_run;
    _ = &harness.guide_app_dispatch;
}

test {
    _ = @import("docs.zig");
}

const ks = struct {
    const tab = 0xff09;
    const enter = 0xff0d;
    const escape = 0xff1b;
    const left = 0xff51;
    const up = 0xff52;
    const right = 0xff53;
    const down = 0xff54;
};

// Getting started -------------------------------------------------------------

extern fn guide_main_hello() c_int;

/// The same window in every language, clicked from the keyboard.
fn hello(g: *Guide) !void {
    try g.expectImage("hello");
    try g.key(ks.tab, "", .{});
    try g.key(ks.enter, "\r", .{});
    try g.key(ks.enter, "\r", .{});
    try g.expectText("Clicked 2 times");
    try g.expectImage("hello-clicked");
}

test "guide: hello.c" {
    try harness.runC(guide_main_hello, hello);
}

test "guide: hello.zig" {
    try harness.runZig(@import("zig_hello"), hello);
}

test "guide: hello.lua" {
    try harness.runLua("docs/guide/examples/hello.lua", hello);
}

// The model -----------------------------------------------------------------

extern fn guide_main_model() c_int;

test "guide: model.c posts from a thread and asks before closing" {
    try harness.runC(guide_main_model, struct {
        fn f(g: *Guide) !void {
            try g.waitText("Loaded 3 notes on a worker thread");
            try g.expectImage("model");
            try g.typeText("Milk");
            try g.expectText("Edited");
            // A close request with unsaved changes is kept and asks.
            try g.close(g.window());
            _ = try g.find(.dialog, "Discard the note?");
            try g.expectImage("model-close");
            // Discarding destroys the last window, which ends siv_run.
            try g.clickOn(.button, "Discard");
        }
    }.f);
}

// Layout and text -------------------------------------------------------------

extern fn guide_main_layout() c_int;

test "guide: layout.c" {
    try harness.runC(guide_main_layout, struct {
        fn f(g: *Guide) !void {
            try g.expectImage("layout");
        }
    }.f);
}

test "guide: text.lua" {
    try harness.runLua("docs/guide/examples/text.lua", struct {
        fn f(g: *Guide) !void {
            try g.expectImage("text");
        }
    }.f);
}

// Widgets and theming ---------------------------------------------------------

test "guide: settings.zig in the light and dark themes" {
    try harness.runZig(@import("zig_settings"), struct {
        fn f(g: *Guide) !void {
            try g.expectImage("settings");
            try g.clickOn(.@"switch", "Dark theme");
            try g.clickOn(.button, "Save");
            try g.expectText("Settings saved");
            try g.expectImage("settings-dark");
        }
    }.f);
}

test "guide: settings.zig under the user's theme.toml" {
    try harness.runZig(@import("zig_settings"), struct {
        fn f(g: *Guide) !void {
            // As siv reads ~/.config/siv/theme.toml (D29).
            const app = try abi.application.App.get(@backingInt(g.app));
            app.app.setUserTheme(&ui.user_theme.parseFile(@embedFile("../examples/theme.toml")).theme);
            try g.clickOn(.@"switch", "Dark theme");
            try g.expectImage("settings-theme");
        }
    }.f);
}

extern fn guide_main_menus() c_int;

test "guide: menus.c opens a menu, a popover, and a dialog" {
    try harness.runC(guide_main_menus, struct {
        fn f(g: *Guide) !void {
            try g.expectImage("menus");
            try g.clickOn(.button, "File");
            const menu = (try g.popup()) orelse return error.NoMenu;
            try g.expectImageOf(menu, "menus-file");
            try g.keyIn(menu, ks.down, "", .{});
            try g.keyIn(menu, ks.enter, "\r", .{});
            try g.expectText("Chose Open…");
            try g.clickOn(.button, "Details");
            const popover = (try g.popup()) orelse return error.NoPopover;
            try g.expectImageOf(popover, "menus-popover");
            try g.keyIn(popover, ks.escape, "", .{});
            try testing.expect(try g.popup() == null);
            try g.clickOn(.button, "Delete…");
            try g.expectImage("menus-dialog");
            try g.clickOn(.button, "Delete");
            try g.expectText("Deleted “Draft”");
        }
    }.f);
}

extern fn guide_main_export() c_int;

test "guide: export.c shows tooltips and chooses in a combo box" {
    try harness.runC(guide_main_export, struct {
        fn f(g: *Guide) !void {
            try g.expectImage("export");
            try g.hover(.button, "Copy");
            try g.expectTooltip("export-tooltip");
            try g.hover(.button, "Export");
            try g.expectTooltip("export-tooltip-own");
            try g.clickOn(.combo_box, "Format");
            const list = (try g.popup()) orelse return error.NoList;
            try g.expectImageOf(list, "export-list");
            try g.keyIn(list, ks.down, "", .{});
            try g.keyIn(list, ks.down, "", .{});
            try g.keyIn(list, ks.enter, "\r", .{});
            try testing.expect(try g.popup() == null);
            try g.expectText("Format: WebP");
            // Closed, typing picks an option by its first letters.
            try g.typeText("j");
            try g.expectText("Format: JPEG");
        }
    }.f);
}

// Events and focus ------------------------------------------------------------

extern fn guide_main_events() c_int;

test "guide: events.c moves focus with keys and opens a context menu" {
    try harness.runC(guide_main_events, struct {
        fn f(g: *Guide) !void {
            try g.key(ks.tab, "", .{});
            try g.key(ks.tab, "", .{});
            try testing.expectEqualStrings("Inbox", try g.focusedName());
            try g.key(ks.right, "", .{});
            try testing.expectEqualStrings("Drafts", try g.focusedName());
            try g.expectImage("events");
            try g.key(ks.enter, "\r", .{});
            try g.expectText("Opened Drafts");
            // "/" focuses the search field from anywhere; typed into the
            // field, it is text.
            try g.key('/', "/", .{});
            try testing.expectEqualStrings("Search", try g.focusedName());
            try g.typeText("a/b");
            try g.expectImage("events-search");
            const p = try g.center(.button, "Archive");
            try g.rightClick(p[0], p[1]);
            const menu = (try g.popup()) orelse return error.NoMenu;
            try g.expectImageOf(menu, "events-menu");
            try g.keyIn(menu, ks.enter, "\r", .{});
            try g.expectText("Rename chosen");
        }
    }.f);
}

// Custom widgets ----------------------------------------------------------------

extern fn guide_main_segmented() c_int;

test "guide: segmented.c, a widget built from primitives" {
    try harness.runC(guide_main_segmented, struct {
        fn f(g: *Guide) !void {
            try g.expectImage("segmented");
            try g.clickOn(.radio, "Month");
            try g.expectText("Showing this month");
            try g.key(ks.left, "", .{});
            try g.expectText("Showing this week");
            try testing.expectEqualStrings("Week", try g.focusedName());
            const week = try g.find(.radio, "Week");
            try testing.expect(week.checked == .on);
        }
    }.f);
}

test "guide: chart.zig draws on a canvas and follows the pointer" {
    try harness.runZig(@import("zig_chart"), struct {
        fn f(g: *Guide) !void {
            try g.expectImage("chart");
            const b = (try g.find(.image, "Sales by month")).bounds;
            try g.pointer(g.window(), b.x + b.width * 4.5 / 6.0, b.y + b.height - 40, null);
            try g.expectImage("chart-hover");
        }
    }.f);
}

// Images and icons ----------------------------------------------------------------

extern fn guide_main_images() c_int;

test "guide: images.c" {
    try harness.runC(guide_main_images, struct {
        fn f(g: *Guide) !void {
            try g.waitText("landscape.png, 240 × 150");
            try g.expectImage("images");
        }
    }.f);
}

// Lists and tables ----------------------------------------------------------------

extern fn guide_main_table() c_int;

test "guide: table.c sorts and selects 100 000 rows" {
    try harness.runC(guide_main_table, struct {
        fn f(g: *Guide) !void {
            try g.expectImage("table");
            try g.clickOn(.column_header, "Size");
            // The first row is the header's.
            try g.clickNode(try g.nth(.row, 1));
            try g.key(ks.down, "", .{ .shift = true });
            try g.key(ks.down, "", .{ .shift = true });
            try g.expectText("3 of 100000 selected");
            try g.expectImage("table-sorted");
        }
    }.f);
}

test "guide: tree.lua expands from the keyboard" {
    try harness.runLua("docs/guide/examples/tree.lua", struct {
        fn f(g: *Guide) !void {
            try g.key(ks.right, "", .{});
            try g.key(ks.down, "", .{});
            try g.key(ks.right, "", .{});
            try g.key(ks.down, "", .{});
            try g.expectText("Selected To Ana");
            try g.expectImage("tree");
        }
    }.f);
}

// Async work ----------------------------------------------------------------------

extern fn guide_main_jobs() c_int;

test "guide: jobs.c counts primes on the worker pool" {
    try harness.runC(guide_main_jobs, struct {
        fn f(g: *Guide) !void {
            try g.clickOn(.button, "Start");
            try g.waitText("17984 primes below 200000");
            try g.expectImage("jobs");
        }
    }.f);
}

extern fn guide_main_watch() c_int;

test "guide: watch.c reads a child's output in siv's loop" {
    try harness.runC(guide_main_watch, struct {
        fn f(g: *Guide) !void {
            try g.waitText("Done: 5 lines");
            try g.expectImage("watch");
        }
    }.f);
}

test "guide: async.lua waits in coroutines" {
    try harness.runLua("docs/guide/examples/async.lua", struct {
        fn f(g: *Guide) !void {
            try g.waitText("landscape.png, 240 × 150");
            // Without a session bus the portal is unavailable, and the
            // coroutine hears so.
            try g.clickOn(.button, "Open…");
            try g.waitText("No image chosen (unavailable)");
            try g.clickOn(.button, "Count primes");
            try g.waitText("5133 primes below 50000");
            try g.expectImage("async");
        }
    }.f);
}

// Clipboard and drag and drop -------------------------------------------------

extern fn guide_main_clipboard() c_int;

test "guide: clipboard.c copies, pastes, and takes a drop" {
    try harness.runC(guide_main_clipboard, struct {
        fn f(g: *Guide) !void {
            try g.clickOn(.button, "Copy");
            try g.clickOn(.button, "Paste");
            try g.waitText("Pasted: Hello from siv");
            const p = try g.center(.group, "Drop area");
            try g.dropFromElsewhere("text/plain;charset=utf-8", "A line from another application", p[0], p[1]);
            try g.expectText("Dropped: A line from another application");
            try g.expectImage("clipboard");
        }
    }.f);
}

// Embedding ---------------------------------------------------------------------

extern fn guide_main_embed() c_int;

test "guide: embed.c runs in the host's poll loop" {
    try harness.runC(guide_main_embed, struct {
        fn f(g: *Guide) !void {
            try g.expectImage("embed");
            // The host's loop ends when the window closes.
            try g.close(g.window());
        }
    }.f);
}

// External content ----------------------------------------------------------------

extern fn guide_main_video() c_int;

test "guide: video.c shows frames from a producer thread" {
    try harness.runC(guide_main_video, struct {
        fn f(g: *Guide) !void {
            try g.waitText("Played 60 frames");
            try g.expectImage("video");
        }
    }.f);
}

extern fn guide_main_wayland() c_int;

test "guide: wayland.c extends its window with content-type-v1" {
    try harness.runC(guide_main_wayland, struct {
        fn f(g: *Guide) !void {
            // The headless backend has no Wayland connection to bind on.
            try g.expectText("No Wayland compositor to tell");
            try g.expectImage("wayland");
            // The close request unbinds before siv destroys the window.
            try g.close(g.window());
        }
    }.f);
}

// Printing --------------------------------------------------------------------------

extern fn guide_main_print() c_int;

test "guide: print.c writes a PDF and asks the print portal" {
    try harness.runC(guide_main_print, struct {
        fn f(g: *Guide) !void {
            try g.expectImage("print");
            const dir = testing.environ.getPosix("TMPDIR") orelse "/tmp";
            var buf: [300]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/invoice.pdf", .{if (dir.len == 0) "/tmp" else dir});
            var status: [400]u8 = undefined;
            try g.clickOn(.button, "Export PDF");
            try g.waitText(try std.fmt.bufPrint(&status, "Wrote 2 pages to {s}", .{path}));
            const pdf = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
            defer testing.allocator.free(pdf);
            try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-"));
            try testing.expect(std.mem.indexOf(u8, pdf, "/Count 2") != null);
            try g.clickOn(.button, "Print…");
            try g.waitText("No print portal on this system");
        }
    }.f);
}

// Packaging ---------------------------------------------------------------------------

extern fn guide_main_launch(argc: c_int, argv: [*]const ?[*:0]const u8) c_int;

test "guide: launch.c creates its window when activated" {
    try harness.runCArgs(guide_main_launch, &.{ "notes", "notes.txt" }, struct {
        fn f(g: *Guide) !void {
            try g.waitText("Opened 1 file");
            try g.expectImage("launch");
        }
    }.f);
}

// Testing -------------------------------------------------------------------------

test "guide: counter_test.lua drives a window through the test API" {
    // The script is the test: it runs to its end, raising on a failure.
    try harness.runLua("docs/guide/examples/counter_test.lua", struct {
        fn f(_: *Guide) !void {}
    }.f);
}
