//! Popup placement (D17): the rules of xdg_positioner, for windows that
//! are xdg_popups. The Wayland compositor applies them itself; the
//! headless backend uses `place` so tests see the same placement.

const std = @import("std");

pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

/// An edge or corner of the anchor rectangle (xdg_positioner.anchor), or
/// the direction the popup extends from the anchor point (gravity).
pub const Edge = enum(u32) { none, top, bottom, left, right, top_left, bottom_left, top_right, bottom_right };

/// How the compositor may move or shrink a popup that would leave the
/// output (xdg_positioner.constraint_adjustment), tried per axis in this
/// order: flip, slide, resize.
pub const Adjustment = packed struct(u32) {
    slide_x: bool = false,
    slide_y: bool = false,
    flip_x: bool = false,
    flip_y: bool = false,
    resize_x: bool = false,
    resize_y: bool = false,
    _: u26 = 0,
};

pub const Positioner = struct {
    /// Logical size of the popup.
    width: u32,
    height: u32,
    /// In the parent window's surface coordinates.
    anchor_rect: Rect,
    anchor: Edge = .bottom_left,
    gravity: Edge = .bottom_right,
    adjustment: Adjustment = .{ .flip_y = true, .slide_x = true, .resize_y = true },
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    /// Have the compositor place the popup again when the parent moves or
    /// changes size (xdg_positioner.set_reactive).
    reactive: bool = false,
};

fn hside(e: Edge) i2 {
    return switch (e) {
        .left, .top_left, .bottom_left => -1,
        .right, .top_right, .bottom_right => 1,
        else => 0,
    };
}

fn vside(e: Edge) i2 {
    return switch (e) {
        .top, .top_left, .top_right => -1,
        .bottom, .bottom_left, .bottom_right => 1,
        else => 0,
    };
}

fn edge(h: i2, v: i2) Edge {
    return switch (v) {
        -1 => switch (h) {
            -1 => .top_left,
            1 => .top_right,
            else => .top,
        },
        1 => switch (h) {
            -1 => .bottom_left,
            1 => .bottom_right,
            else => .bottom,
        },
        else => switch (h) {
            -1 => .left,
            1 => .right,
            else => .none,
        },
    };
}

/// Start (x, or y) and length of the popup on one axis without
/// constraints: the anchor point's coordinate per `anchor`, then the popup
/// extended per `gravity` (centered for 0).
fn axis(rect_start: i32, rect_len: i32, anchor: i2, gravity: i2, len: i32, offset: i32) i32 {
    const point = switch (anchor) {
        -1 => rect_start,
        1 => rect_start + rect_len,
        else => rect_start + @divTrunc(rect_len, 2),
    };
    const start = switch (gravity) {
        -1 => point - len,
        1 => point,
        else => point - @divTrunc(len, 2),
    };
    return start + offset;
}

fn overflow(start: i32, len: i32, lo: i32, hi: i32) i32 {
    return @max(lo - start, 0) + @max(start + len - hi, 0);
}

/// The popup's rectangle in parent coordinates, kept inside `bounds` (the
/// output, in parent coordinates) as the adjustments allow.
pub fn place(p: Positioner, bounds: Rect) Rect {
    const ar = p.anchor_rect;
    const w: i32 = @intCast(p.width);
    const h: i32 = @intCast(p.height);
    var x = axis(ar.x, ar.width, hside(p.anchor), hside(p.gravity), w, p.offset_x);
    var y = axis(ar.y, ar.height, vside(p.anchor), vside(p.gravity), h, p.offset_y);
    var rw = w;
    var rh = h;
    const bx1 = bounds.x + bounds.width;
    const by1 = bounds.y + bounds.height;

    // Flip: mirror anchor and gravity on the axis if that fits better.
    if (p.adjustment.flip_x and overflow(x, rw, bounds.x, bx1) > 0) {
        const fx = axis(ar.x, ar.width, -hside(p.anchor), -hside(p.gravity), w, -p.offset_x);
        if (overflow(fx, rw, bounds.x, bx1) == 0) x = fx;
    }
    if (p.adjustment.flip_y and overflow(y, rh, bounds.y, by1) > 0) {
        const fy = axis(ar.y, ar.height, -vside(p.anchor), -vside(p.gravity), h, -p.offset_y);
        if (overflow(fy, rh, bounds.y, by1) == 0) y = fy;
    }
    // Slide: move inside, preferring to keep the start edge visible.
    if (p.adjustment.slide_x) {
        if (x + rw > bx1) x = bx1 - rw;
        if (x < bounds.x) x = bounds.x;
    }
    if (p.adjustment.slide_y) {
        if (y + rh > by1) y = by1 - rh;
        if (y < bounds.y) y = bounds.y;
    }
    // Resize: cut what is still outside.
    if (p.adjustment.resize_x) {
        const x0 = @max(x, bounds.x);
        rw = @max(@min(x + rw, bx1) - x0, 1);
        x = x0;
    }
    if (p.adjustment.resize_y) {
        const y0 = @max(y, bounds.y);
        rh = @max(@min(y + rh, by1) - y0, 1);
        y = y0;
    }
    return .{ .x = x, .y = y, .width = rw, .height = rh };
}

test "a menu below its button flips above near the bottom and slides in" {
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 400, .height = 300 };
    var p: Positioner = .{ .width = 100, .height = 80, .anchor_rect = .{ .x = 20, .y = 30, .width = 60, .height = 20 } };
    try std.testing.expectEqual(Rect{ .x = 20, .y = 50, .width = 100, .height = 80 }, place(p, bounds));
    // Near the bottom: flips above the button.
    p.anchor_rect.y = 250;
    try std.testing.expectEqual(Rect{ .x = 20, .y = 170, .width = 100, .height = 80 }, place(p, bounds));
    // Near the right edge: slides left.
    p.anchor_rect.x = 350;
    try std.testing.expectEqual(@as(i32, 300), place(p, bounds).x);
    // Taller than either side: no flip helps, so it shrinks to fit below.
    p = .{ .width = 100, .height = 400, .anchor_rect = .{ .x = 0, .y = 100, .width = 10, .height = 10 } };
    try std.testing.expectEqual(Rect{ .x = 0, .y = 110, .width = 100, .height = 190 }, place(p, bounds));
    // Right to left: anchored at the end corner, extending toward the start.
    p = .{ .width = 100, .height = 50, .anchor_rect = .{ .x = 300, .y = 0, .width = 80, .height = 20 }, .anchor = .bottom_right, .gravity = .bottom_left };
    try std.testing.expectEqual(Rect{ .x = 280, .y = 20, .width = 100, .height = 50 }, place(p, bounds));
    try std.testing.expectEqual(Edge.bottom_left, edge(-1, 1));
}
