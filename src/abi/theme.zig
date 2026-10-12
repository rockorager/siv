//! Exports for theming (D29): the application's scheme and contrast
//! choices, color overrides, and resolved colors for canvases. The theme
//! itself is `ui.theme`; the coordinator hands it to every window.

const std = @import("std");
const t = @import("siv");
const ui = @import("ui");
const scene = @import("scene");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");

const App = application.App;
const Error = application.Error;

pub export fn siv_app_set_theme(app: t.App, desc: ?*const t.ThemeDesc) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, d_ptr: ?*const t.ThemeDesc) Error!void {
            const self = try App.get(@backingInt(a));
            const d = try runtime.readDesc(t.ThemeDesc, d_ptr);
            var th = self.app.theme;
            th.scheme = switch (try runtime.enumValue(t.ColorScheme, d.scheme)) {
                .follow => .follow,
                .light => .light,
                .dark => .dark,
                _ => unreachable,
            };
            th.contrast = switch (try runtime.enumValue(t.Contrast, d.contrast)) {
                .follow => .follow,
                .normal => .normal,
                .high => .high,
                _ => unreachable,
            };
            self.app.setTheme(&th);
        }
    }.f(app, desc));
}

pub export fn siv_app_set_theme_color(app: t.App, variant: t.ThemeVariant, token: t.ColorToken, color: t.Color) t.Result {
    return application.wrap(struct {
        fn f(a: t.App, v: t.ThemeVariant, tok: t.ColorToken, c: t.Color) Error!void {
            const self = try App.get(@backingInt(a));
            _ = try runtime.enumValue(t.ThemeVariant, v);
            const i = @intFromEnum(try tree.colorToken(tok, false));
            const zero = c.r == 0 and c.g == 0 and c.b == 0 and c.a == 0;
            const value: ?scene.Color = if (zero) null else try tree.color(c, .transparent);
            var th = self.app.theme;
            if (v == .all) {
                for (&th.overrides) |*o| o[i] = value;
            } else th.overrides[@intCast(@backingInt(v) - 1)][i] = value;
            self.app.setTheme(&th);
        }
    }.f(app, variant, token, color));
}

pub export fn siv_window_get_color(window: t.Window, token: t.ColorToken, color: ?*t.Color) t.Result {
    return application.wrap(struct {
        fn f(win: t.Window, tok: t.ColorToken, out: ?*t.Color) Error!void {
            const w = try App.window(@backingInt(win), application.window_tag);
            const dest = try runtime.out(t.Color, out);
            const c = w.uiWin().palette.color(try tree.colorToken(tok, false));
            dest.* = .{ .r = scene.linearToSrgb(c.r), .g = scene.linearToSrgb(c.g), .b = scene.linearToSrgb(c.b), .a = c.a };
        }
    }.f(window, token, color));
}

comptime {
    // siv_theme_variant is ui.theme.Variant shifted by one (0 is all).
    for (@typeInfo(ui.theme.Variant).@"enum".field_names, 0..) |name, i| {
        if (@backingInt(@field(t.ThemeVariant, name)) != i + 1) @compileError("siv_theme_variant does not match ui.theme.Variant at " ++ name);
    }
}
