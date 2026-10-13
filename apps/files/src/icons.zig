//! File and place icons drawn on canvases (D28) in theme colors.
//!
//! siv has no icon theme loader or SVG renderer yet (FRICTION.md), so
//! every icon is a few paths drawn at whatever size the canvas is, which
//! keeps them sharp at any scale and in every theme variant.

const std = @import("std");
const siv = @import("siv");
const c = siv.c;
const model = @import("model.zig");

pub const Icon = enum(u8) {
    folder,
    file,
    text,
    image,
    audio,
    video,
    archive,
    document,
    code,
    executable,
    home,
    desktop,
    trash,
    computer,
    bookmark,
    download,

    pub fn of(cat: model.Category) Icon {
        return switch (cat) {
            .folder => .folder,
            .text => .text,
            .image => .image,
            .audio => .audio,
            .video => .video,
            .archive => .archive,
            .document => .document,
            .code => .code,
            .executable => .executable,
            .other => .file,
        };
    }
};

fn color(window: siv.Window, token: siv.ColorToken) siv.Color {
    var col: siv.Color = .{ .a = 1 };
    _ = c.siv_window_get_color(window, token, &col);
    return col;
}

fn mix(a: siv.Color, b: siv.Color, t: f32) siv.Color {
    return .{ .r = a.r + (b.r - a.r) * t, .g = a.g + (b.g - a.g) * t, .b = a.b + (b.b - a.b) * t, .a = a.a + (b.a - a.a) * t };
}

fn fill(d: siv.Draw, col: siv.Color) void {
    _ = c.siv_draw_fill(d, &.{ .color = col }, .{});
}

fn stroke(d: siv.Draw, col: siv.Color, width: f32) void {
    _ = c.siv_draw_stroke(d, &.{ .width = width, .join = .round, .cap = .round }, &.{ .color = col });
}

fn rrect(d: siv.Draw, x: f32, y: f32, w: f32, h: f32, r: f32) void {
    _ = c.siv_draw_rounded_rect(d, .{ .x = x, .y = y, .width = w, .height = h }, .{ .top_left = r, .top_right = r, .bottom_right = r, .bottom_left = r });
}

/// Draws `icon` centered in a `w` x `h` canvas of `node`, as a square of
/// the smaller side.
pub fn draw(icon: Icon, node: siv.Node, d: siv.Draw, w: f32, h: f32) void {
    var window: siv.Window = .null;
    _ = c.siv_node_get_window(node, &window);
    const s = @min(w, h);
    const x0 = (w - s) / 2;
    const y0 = (h - s) / 2;
    const accent = color(window, .accent);
    const fg = color(window, .view_fg);
    const muted = color(window, .muted_fg);
    const bg = color(window, .view_bg);
    const u = s / 16; // one sixteenth: icons are designed on a 16 grid
    switch (icon) {
        .folder, .home, .desktop, .download, .bookmark => {
            const back = mix(accent, bg, 0.35);
            // Tab, then body.
            rrect(d, x0 + 1 * u, y0 + 2.5 * u, 6 * u, 3 * u, 1 * u);
            fill(d, back);
            rrect(d, x0 + 1 * u, y0 + 4 * u, 14 * u, 10 * u, 1.2 * u);
            fill(d, back);
            rrect(d, x0 + 1 * u, y0 + 5.5 * u, 14 * u, 8.5 * u, 1.2 * u);
            fill(d, accent);
            const mark = color(window, .accent_fg);
            switch (icon) {
                .home => {
                    _ = c.siv_draw_move_to(d, x0 + 5 * u, y0 + 10 * u);
                    _ = c.siv_draw_line_to(d, x0 + 8 * u, y0 + 7.5 * u);
                    _ = c.siv_draw_line_to(d, x0 + 11 * u, y0 + 10 * u);
                    _ = c.siv_draw_move_to(d, x0 + 6 * u, y0 + 9.5 * u);
                    _ = c.siv_draw_line_to(d, x0 + 6 * u, y0 + 12 * u);
                    _ = c.siv_draw_line_to(d, x0 + 10 * u, y0 + 12 * u);
                    _ = c.siv_draw_line_to(d, x0 + 10 * u, y0 + 9.5 * u);
                    stroke(d, mark, @max(1, 1.1 * u));
                },
                .download => {
                    _ = c.siv_draw_move_to(d, x0 + 8 * u, y0 + 7.5 * u);
                    _ = c.siv_draw_line_to(d, x0 + 8 * u, y0 + 12 * u);
                    _ = c.siv_draw_move_to(d, x0 + 6 * u, y0 + 10 * u);
                    _ = c.siv_draw_line_to(d, x0 + 8 * u, y0 + 12 * u);
                    _ = c.siv_draw_line_to(d, x0 + 10 * u, y0 + 10 * u);
                    stroke(d, mark, @max(1, 1.1 * u));
                },
                .desktop => {
                    rrect(d, x0 + 5 * u, y0 + 8 * u, 6 * u, 4 * u, 0.5 * u);
                    stroke(d, mark, @max(1, 1 * u));
                },
                .bookmark => {
                    _ = c.siv_draw_move_to(d, x0 + 6 * u, y0 + 7.5 * u);
                    _ = c.siv_draw_line_to(d, x0 + 10 * u, y0 + 7.5 * u);
                    _ = c.siv_draw_line_to(d, x0 + 10 * u, y0 + 12.5 * u);
                    _ = c.siv_draw_line_to(d, x0 + 8 * u, y0 + 11 * u);
                    _ = c.siv_draw_line_to(d, x0 + 6 * u, y0 + 12.5 * u);
                    _ = c.siv_draw_close(d);
                    fill(d, mark);
                },
                else => {},
            }
        },
        .trash => {
            rrect(d, x0 + 3.5 * u, y0 + 4.5 * u, 9 * u, 10 * u, 1.2 * u);
            stroke(d, fg, @max(1, 1.2 * u));
            _ = c.siv_draw_move_to(d, x0 + 2 * u, y0 + 3.5 * u);
            _ = c.siv_draw_line_to(d, x0 + 14 * u, y0 + 3.5 * u);
            _ = c.siv_draw_move_to(d, x0 + 6 * u, y0 + 2 * u);
            _ = c.siv_draw_line_to(d, x0 + 10 * u, y0 + 2 * u);
            stroke(d, fg, @max(1, 1.2 * u));
        },
        .computer => {
            rrect(d, x0 + 1.5 * u, y0 + 2.5 * u, 13 * u, 9 * u, 1 * u);
            stroke(d, fg, @max(1, 1.2 * u));
            _ = c.siv_draw_move_to(d, x0 + 5 * u, y0 + 14 * u);
            _ = c.siv_draw_line_to(d, x0 + 11 * u, y0 + 14 * u);
            stroke(d, fg, @max(1, 1.2 * u));
        },
        else => {
            // A page with a folded corner.
            const paper = mix(bg, fg, 0.06);
            const edge = mix(bg, fg, 0.45);
            _ = c.siv_draw_move_to(d, x0 + 3 * u, y0 + 1 * u);
            _ = c.siv_draw_line_to(d, x0 + 10 * u, y0 + 1 * u);
            _ = c.siv_draw_line_to(d, x0 + 13 * u, y0 + 4 * u);
            _ = c.siv_draw_line_to(d, x0 + 13 * u, y0 + 15 * u);
            _ = c.siv_draw_line_to(d, x0 + 3 * u, y0 + 15 * u);
            _ = c.siv_draw_close(d);
            _ = c.siv_draw_fill(d, &.{ .color = paper }, .{ .keep_path = true });
            stroke(d, edge, @max(1, 0.9 * u));
            _ = c.siv_draw_move_to(d, x0 + 10 * u, y0 + 1 * u);
            _ = c.siv_draw_line_to(d, x0 + 10 * u, y0 + 4 * u);
            _ = c.siv_draw_line_to(d, x0 + 13 * u, y0 + 4 * u);
            stroke(d, edge, @max(1, 0.9 * u));
            const badge: ?siv.Color = switch (icon) {
                .image => .{ .r = 0.2, .g = 0.6, .b = 0.35, .a = 1 },
                .audio => .{ .r = 0.85, .g = 0.45, .b = 0.1, .a = 1 },
                .video => .{ .r = 0.75, .g = 0.2, .b = 0.3, .a = 1 },
                .archive => .{ .r = 0.6, .g = 0.45, .b = 0.25, .a = 1 },
                .document => .{ .r = 0.2, .g = 0.4, .b = 0.8, .a = 1 },
                .code => .{ .r = 0.45, .g = 0.3, .b = 0.75, .a = 1 },
                .executable => .{ .r = 0.35, .g = 0.35, .b = 0.35, .a = 1 },
                else => null,
            };
            switch (icon) {
                .image => {
                    // A mountain and a sun.
                    _ = c.siv_draw_move_to(d, x0 + 4.5 * u, y0 + 13 * u);
                    _ = c.siv_draw_line_to(d, x0 + 7.5 * u, y0 + 8.5 * u);
                    _ = c.siv_draw_line_to(d, x0 + 9.5 * u, y0 + 11 * u);
                    _ = c.siv_draw_line_to(d, x0 + 10.5 * u, y0 + 10 * u);
                    _ = c.siv_draw_line_to(d, x0 + 11.5 * u, y0 + 13 * u);
                    _ = c.siv_draw_close(d);
                    fill(d, badge.?);
                    _ = c.siv_draw_ellipse(d, .{ .x = x0 + 9.5 * u, .y = y0 + 3.5 * u, .width = 2 * u, .height = 2 * u });
                    fill(d, badge.?);
                },
                .text, .file => {
                    var k: f32 = 0;
                    while (k < 4) : (k += 1) {
                        _ = c.siv_draw_move_to(d, x0 + 5 * u, y0 + (6 + 2 * k) * u);
                        _ = c.siv_draw_line_to(d, x0 + (if (k == 3) @as(f32, 8.5) else 11) * u, y0 + (6 + 2 * k) * u);
                    }
                    if (icon == .text) stroke(d, muted, @max(1, 0.9 * u));
                },
                else => if (badge) |b| {
                    rrect(d, x0 + 4.5 * u, y0 + 8 * u, 7 * u, 5 * u, 1 * u);
                    fill(d, b);
                },
            }
        },
    }
}
