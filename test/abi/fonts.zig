//! Font families through the C ABI (D13): faces added with
//! siv_app_add_font register their family and styles from their data,
//! text styles pick faces within the family, variable faces take their
//! axes from the style and opsz from the size, and missing weights and
//! slants are synthesized. Measured with the generated SivTest fonts,
//! whose I advances by two side bearings and a stem (see
//! src/text/testdata/make_test_fonts.py).

const std = @import("std");
const abi = @import("abi");
const text = @import("text");
const harness = @import("harness.zig");

const testing = std.testing;
const t = abi.types;
const c = t.c;
const ok = harness.ok;
const tf = text.font.test_fonts;

fn width(app: t.App, str: []const u8, style: t.TextStyleDesc) !f32 {
    var m: t.TextMetrics = undefined;
    try ok(c.siv_app_measure_text(app, str.ptr, str.len, 0, &style, &m));
    return m.width;
}

test "siv_app_add_font: families and styles from the font data, matched per style" {
    var app: t.App = .null;
    try ok(c.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true } }, &app));
    defer _ = c.siv_app_destroy(app);
    // Empty family names: each face's own ("SivTest", "SivTest VF").
    for ([_][]const u8{ tf.siv_regular, tf.siv_bold, tf.siv_italic, tf.siv_variable }) |font| try ok(c.siv_app_add_font(app, "", 0, font.ptr, font.len));
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_add_font(app, "", 0, "junk", 4));
    // Roboto has one style: everything else is synthesized from it.
    const roboto = @embedFile("../golden/fonts/Roboto-Regular.ttf");
    try ok(c.siv_app_add_font(app, "Roboto", 6, roboto.ptr, roboto.len));

    const static: t.TextStyleDesc = .{ .family = "SivTest", .family_len = 7, .font_size = 100 };
    // 0.1 px per unit at 100 px: the regular I is 60 + 90 + 60 units.
    try testing.expectApproxEqAbs(84, try width(app, "IIII", static), 0.01);
    var s = static;
    s.weight = .bold; // the Bold face: a 156-unit stem
    try testing.expectApproxEqAbs(110.4, try width(app, "IIII", s), 0.01);
    s.weight = .black; // still the Bold face, not emboldened further
    try testing.expectApproxEqAbs(110.4, try width(app, "IIII", s), 0.01);
    s = static;
    s.slant = .italic; // the Italic face: the regular advances
    try testing.expectApproxEqAbs(84, try width(app, "IIII", s), 0.01);
    s.weight = .bold; // no bold italic: the italic with synthetic bold, 1/24 em (42 units) wider
    try testing.expectApproxEqAbs(100.8, try width(app, "IIII", s), 0.01);

    // The variable face: opsz follows the size (side bearings of 30 units
    // at 72 and above), wght the weight, and weight_value any weight.
    const variable: t.TextStyleDesc = .{ .family = "SivTest VF", .family_len = 10, .font_size = 100 };
    try testing.expectApproxEqAbs(60, try width(app, "IIII", variable), 0.01);
    s = variable;
    s.weight = .bold;
    try testing.expectApproxEqAbs(86.4, try width(app, "IIII", s), 0.01);
    s.weight_value = 550; // a 123-unit stem
    try testing.expectApproxEqAbs(73.2, try width(app, "IIII", s), 0.01);
    s.weight_value = 1001;
    var m: t.TextMetrics = undefined;
    try testing.expectEqual(t.Result.error_invalid_argument, c.siv_app_measure_text(app, "I", 1, 0, &s, &m));
    // Condensed: the H's body is 75% of 500 units.
    s = variable;
    s.width = .condensed;
    try testing.expectApproxEqAbs(43.5, try width(app, "H", s), 0.01);
    // At 8 px, opsz 8: side bearings of 80 units.
    s = variable;
    s.font_size = 8;
    try testing.expectApproxEqAbs(8, try width(app, "IIII", s), 0.001);

    // Synthetic bold widens every advance by 1/24 em; oblique keeps them.
    const plain: t.TextStyleDesc = .{ .family = "Roboto", .family_len = 6, .font_size = 48 };
    const regular = try width(app, "Hamburgefonstiv", plain);
    s = plain;
    s.weight = .semibold;
    // Roboto has 2048 units per em: 85 units, rounded, per glyph.
    try testing.expectApproxEqAbs(regular + 15.0 * 85.0 * 48.0 / 2048.0, try width(app, "Hamburgefonstiv", s), 0.01);
    s = plain;
    s.slant = .oblique;
    try testing.expectApproxEqAbs(regular, try width(app, "Hamburgefonstiv", s), 0.01);
    s.weight = .medium; // below semibold: not emboldened
    try testing.expectApproxEqAbs(regular, try width(app, "Hamburgefonstiv", s), 0.01);
}
