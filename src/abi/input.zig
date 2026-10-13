//! Input on request (D16): pointer constraints with relative motion, and
//! shortcut inhibition, per window.

const std = @import("std");
const t = @import("siv");
const runtime = @import("runtime.zig");
const application = @import("application.zig");
const tree = @import("tree.zig");
const platform = @import("platform");

const Error = application.Error;
const App = application.App;
const Window = application.Window;

fn windowOf(window: t.Window) Error!*Window {
    const w = try App.window(@backingInt(window), application.window_tag);
    if (w.dead) return error.InvalidHandle;
    return w;
}

pub export fn siv_window_set_pointer_constraint(window: t.Window, node: t.Node, kind: t.PointerConstraint, flags: t.PointerConstraintFlags) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window, n: t.Node, k: t.PointerConstraint, fl: t.PointerConstraintFlags) Error!void {
            const w = try windowOf(wh);
            const options = try runtime.flags(t.PointerConstraintFlags, fl);
            const pk: platform.PointerConstraint = switch (try runtime.enumValue(t.PointerConstraint, k)) {
                .none => .none,
                .lock => .lock,
                .confine => .confine,
                _ => unreachable,
            };
            const id: @import("ui").NodeId = if (n == .null) .root else try tree.nodeIn(w, n);
            w.uiWin().setPointerConstraint(id, pk, options.persistent, options.relative);
        }
    }.f(window, node, kind, flags));
}

pub export fn siv_window_inhibit_shortcuts(window: t.Window, inhibit: bool) t.Result {
    return application.wrap(struct {
        fn f(wh: t.Window, on: bool) Error!void {
            try (try windowOf(wh)).win.inhibitShortcuts(on);
        }
    }.f(window, inhibit));
}
