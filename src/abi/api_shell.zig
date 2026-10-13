//! The desktop shell part of the API schema (D31): outputs, layer windows,
//! the session lock, the desktop's toplevels and workspaces, idle
//! notification, and what the compositor offers of them. api.zig appends
//! these declarations and functions to its own; the conventions are
//! schema.zig's. Implemented in shell.zig.

const schema = @import("schema.zig");
const ref = schema.ref;
const out = schema.out;
const array = schema.array;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn handle(comptime name: []const u8, comptime doc: []const u8) Decl {
    return .{ .handle = .{ .name = name, .doc = doc, .since = v0_1 } };
}

fn enumeration(comptime name: []const u8, comptime doc: []const u8, comptime values: []const schema.EnumValue) Decl {
    return .{ .@"enum" = .{ .name = name, .doc = doc, .since = v0_1, .values = values } };
}

fn flags(comptime name: []const u8, comptime doc: []const u8, comptime bits: []const schema.Flag) Decl {
    return .{ .flags = .{ .name = name, .doc = doc, .since = v0_1, .bits = bits } };
}

fn descriptor(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .descriptor, .fields = fields } };
}

fn callback(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Decl {
    return .{ .callback = .{ .name = name, .doc = doc, .since = v0_1, .params = params } };
}

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ref("siv_result") };
}

/// Teardown (D2): it cannot fail, and a stale handle does nothing.
fn teardown(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc ++ " A stale handle does nothing.", .since = v0_1, .params = params };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

fn f(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = t, .doc = doc };
}

const app_param = p("app", ref("siv_app"), "The application.");
const unsupported = " SIV_ERROR_UNSUPPORTED when the compositor lacks the protocol (GNOME's has none of the shell protocols; wlroots compositors such as sway, KWin, niri, Hyprland, and COSMIC have most); siv_app_get_capabilities tells in advance.";
const change_types = [_]schema.EnumValue{
    .{ .name = "added", .value = 0, .doc = "It appeared, or existed when watching began." },
    .{ .name = "changed", .value = 1, .doc = "Something in the event changed." },
    .{ .name = "removed", .value = 2, .doc = "It went away; the event has its last values, and its handle is invalid after the callback." },
};

pub const decls = [_]Decl{
    flags("siv_capabilities", "The optional desktop shell protocols the compositor offers (D31).", &.{
        .{ .name = "layers", .bit = 0, .doc = "Layer windows (wlr-layer-shell): siv_layer_create." },
        .{ .name = "lock", .bit = 1, .doc = "Session locks (ext-session-lock-v1): siv_lock_create." },
        .{ .name = "toplevels", .bit = 2, .doc = "The desktop's toplevel list: siv_toplevel_list_create." },
        .{ .name = "toplevel_management", .bit = 3, .doc = "Activating, closing, minimizing, maximizing, and fullscreening other clients' toplevels (wlr-foreign-toplevel-management)." },
        .{ .name = "workspaces", .bit = 4, .doc = "Workspaces (ext-workspace-v1): siv_workspace_list_create." },
        .{ .name = "idle", .bit = 5, .doc = "Idle notification (ext-idle-notify-v1): siv_idle_watch_create." },
        .{ .name = "blur", .bit = 6, .doc = "Blurring what is behind a window (ext-background-effect-v1), where nodes ask for it with SIV_VISUAL_WINDOW_BLUR. Without it those nodes' translucent backgrounds show the desktop unblurred, so choose a more opaque background." },
    }),

    // Outputs.
    handle("siv_output", "A monitor the compositor announced (D31). Valid from the added output event until the removed one."),
    enumeration("siv_output_event_type", "What a siv_output_event reports.", &change_types),
    descriptor("siv_output_event", "An output appeared, changed, or went away. Filled by siv; strings are valid during the call.", &.{
        f("type", ref("siv_output_event_type"), "What happened."),
        f("scale", .u32, "The integer scale the compositor gives the output (wl_output.scale); windows on it get their own, possibly fractional, scale."),
        f("output", ref("siv_output"), "The output."),
        f("name", .string, "Its connector name, such as DP-1 or HEADLESS-1, stable across hotplug."),
        f("description", .string, "A human-readable description."),
        f("make", .string, "The manufacturer."),
        f("model", .string, "The model."),
        f("x", .i32, "Position in the compositor's global space."),
        f("y", .i32, "Position in the compositor's global space."),
        f("pixel_width", .i32, "The current mode's width in hardware pixels."),
        f("pixel_height", .i32, "The current mode's height in hardware pixels."),
        f("refresh_mhz", .i32, "The current mode's refresh rate in millihertz; 0 if unknown."),
        f("transform", .u32, "Rotation and flip, as wl_output.transform."),
        f("physical_width_mm", .i32, "Physical width in millimeters; 0 if unknown."),
        f("physical_height_mm", .i32, "Physical height in millimeters; 0 if unknown."),
    }),
    callback("siv_output_fn", "Receives output events at safe points on the application's thread (D5).", &.{
        p("event", .{ .desc = "siv_output_event" }, "The event, valid during the call."),
    }),

    // Layer windows.
    enumeration("siv_layer", "The stacking layer of a layer window, which toplevels are between (bottom to top: background, bottom, toplevels, top, overlay). The default is top.", &.{
        .{ .name = "top", .value = 0, .doc = "Above toplevels, below fullscreen ones in most compositors: bars, docks, notifications." },
        .{ .name = "bottom", .value = 1, .doc = "Below toplevels, above the background: desktop widgets." },
        .{ .name = "background", .value = 2, .doc = "The lowest: wallpapers." },
        .{ .name = "overlay", .value = 3, .doc = "Above everything, fullscreen toplevels included: on-screen displays, launchers." },
    }),
    flags("siv_layer_anchor", "The output edges a layer window is anchored to. Anchored to one edge it sits against it, centered along it; to two opposite edges of an axis it spans the output between them when its size on that axis is 0; with no anchors it is centered.", &.{
        .{ .name = "top", .bit = 0, .doc = "The top edge." },
        .{ .name = "bottom", .bit = 1, .doc = "The bottom edge." },
        .{ .name = "left", .bit = 2, .doc = "The left edge." },
        .{ .name = "right", .bit = 3, .doc = "The right edge." },
    }),
    enumeration("siv_layer_keyboard", "When a layer window takes keyboard focus.", &.{
        .{ .name = "none", .value = 0, .doc = "Never: a bar or a notification that is only clicked." },
        .{ .name = "exclusive", .value = 1, .doc = "Always, while it is on the top or overlay layer: a launcher or a modal prompt. Other windows get no keys." },
        .{ .name = "on_demand", .value = 2, .doc = "When the user clicks it, like a toplevel: a bar with a search field." },
    }),
    flags("siv_layer_flags", "Layer window options.", &.{
        .{ .name = "auto_exclusive", .bit = 0, .doc = "Reserve the window's own size along the edge it is anchored to, following resizes, instead of exclusive_zone: maximized windows stay clear of a bar of any height. Applies when anchored to one edge, or to one edge and both edges beside it." },
    }),
    descriptor("siv_layer_desc", "Options for siv_layer_create and siv_window_set_layer.", &.{
        f("user_data", .user_data, "Passed to on_event and destroy."),
        f("on_event", ref("siv_window_event_fn"), "Receives the window's events: resized as the compositor configures it, closed when it took the window away."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the window is destroyed."),
        f("output", ref("siv_output"), "The output it goes on; 0 lets the compositor choose (usually the focused one). Fixed at creation."),
        f("namespace", .string, "What the window is (\"bar\", \"dock\", \"notifications\", \"launcher\"), for the compositor's rules. Fixed at creation."),
        f("language", .string, "BCP 47 language of the window's text; empty follows the application's. Fixed at creation."),
        f("layer", ref("siv_layer"), "The layer; default top."),
        f("anchor", ref("siv_layer_anchor"), "The edges it is anchored to."),
        f("keyboard", ref("siv_layer_keyboard"), "When it takes keyboard focus."),
        f("flags", ref("siv_layer_flags"), "Options."),
        f("window_flags", ref("siv_window_flags"), "Window options; only rtl and ltr apply. Fixed at creation."),
        f("width", .u32, "Logical width; 0 spans the output between the left and right edges, which needs both anchors."),
        f("height", .u32, "Logical height; 0 spans the output between the top and bottom edges, which needs both anchors."),
        f("margin_top", .i32, "Distance from the top edge, when anchored to it."),
        f("margin_right", .i32, "Distance from the right edge, when anchored to it."),
        f("margin_bottom", .i32, "Distance from the bottom edge, when anchored to it."),
        f("margin_left", .i32, "Distance from the left edge, when anchored to it."),
        f("exclusive_zone", .i32, "Logical pixels along its anchored edge that other windows keep clear of. 0 reserves nothing but keeps clear of other layer windows' zones; -1 ignores them too (a wallpaper, a full-output overlay). Ignored with SIV_LAYER_AUTO_EXCLUSIVE."),
    }),

    // The session lock.
    handle("siv_lock", "A session lock (ext-session-lock-v1, D31): while it holds, the compositor shows only its lock windows, one per output."),
    enumeration("siv_lock_event_type", "What a siv_lock_event reports.", &.{
        .{ .name = "window", .value = 0, .doc = "siv made the lock window of an output, the window field, when the lock was requested or when the output appeared later: build its content (a clock, a masked editor for the password). It is a siv_window with its own tree, and siv destroys it when its output goes or the lock ends." },
        .{ .name = "locked", .value = 1, .doc = "The compositor locked the session: every output shows only the lock windows (or a solid color where one has not presented yet)." },
        .{ .name = "denied", .value = 2, .doc = "The compositor refused the lock (another client holds one). The lock and its windows are gone; destroy the handle." },
        .{ .name = "finished", .value = 3, .doc = "The compositor ended the lock after locking, without this application unlocking it. Its windows are gone; destroy the handle." },
    }),
    descriptor("siv_lock_event", "A session lock event. Filled by siv.", &.{
        f("window", ref("siv_window"), "window: the new lock window."),
        f("output", ref("siv_output"), "window: the output it covers."),
        f("type", ref("siv_lock_event_type"), "What happened."),
        .{ .name = "reserved0", .type = .u32, .doc = "Zero.", .reserved = true },
    }),
    callback("siv_lock_fn", "Receives a session lock's events at safe points on the application's thread (D5).", &.{
        p("lock", ref("siv_lock"), "The lock."),
        p("event", .{ .desc = "siv_lock_event" }, "The event, valid during the call."),
    }),
    descriptor("siv_lock_desc", "Options for siv_lock_create.", &.{
        f("user_data", .user_data, "Passed to the callbacks and destroy."),
        f("on_event", ref("siv_lock_fn"), "Receives the lock's events."),
        f("on_window_event", ref("siv_window_event_fn"), "Receives the lock windows' events (resized, closed); may be NULL."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the lock handle is destroyed or unlocked."),
    }),

    // Toplevels.
    handle("siv_toplevel_list", "The desktop's toplevel windows, for task lists and docks (D31). Valid until siv_toplevel_list_destroy."),
    handle("siv_toplevel", "A toplevel window of any client, this one included. Valid from its added event until its removed one."),
    enumeration("siv_toplevel_event_type", "What a siv_toplevel_event reports.", &change_types),
    flags("siv_toplevel_states", "A toplevel's states.", &.{
        .{ .name = "maximized", .bit = 0, .doc = "Maximized." },
        .{ .name = "minimized", .bit = 1, .doc = "Minimized." },
        .{ .name = "activated", .bit = 2, .doc = "Focused." },
        .{ .name = "fullscreen", .bit = 3, .doc = "Fullscreen." },
        .{ .name = "managed", .bit = 4, .doc = "The compositor accepts siv_toplevel_activate and the other requests for it; without it, they fail with SIV_ERROR_UNSUPPORTED and the other states are never set." },
    }),
    descriptor("siv_toplevel_event", "A toplevel appeared, changed, or went away. Filled by siv; strings and arrays are valid during the call.", &.{
        f("type", ref("siv_toplevel_event_type"), "What happened."),
        f("states", ref("siv_toplevel_states"), "Its states."),
        f("toplevel", ref("siv_toplevel"), "The toplevel."),
        f("parent", ref("siv_toplevel"), "The toplevel it belongs to (a dialog's), or 0."),
        f("title", .string, "Its title."),
        f("app_id", .string, "Its application id, the .desktop file's name for icons and grouping."),
        f("identifier", .string, "An identifier that stays the same while it exists (ext-foreign-toplevel-list); empty when the compositor's list has none."),
        f("outputs", array(ref("siv_output")), "The outputs it is on, for a task list per output; empty when the compositor does not say."),
    }),
    callback("siv_toplevel_list_fn", "Receives toplevel events at safe points on the application's thread (D5).", &.{
        p("list", ref("siv_toplevel_list"), "The list."),
        p("event", .{ .desc = "siv_toplevel_event" }, "The event, valid during the call."),
    }),
    descriptor("siv_toplevel_list_desc", "Options for siv_toplevel_list_create.", &.{
        f("user_data", .user_data, "Passed to on_event and destroy."),
        f("on_event", ref("siv_toplevel_list_fn"), "Receives the toplevels' events."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the list is destroyed."),
    }),

    // Workspaces.
    handle("siv_workspace_list", "The desktop's workspaces (ext-workspace-v1, D31). Valid until siv_workspace_list_destroy."),
    handle("siv_workspace", "A workspace. Valid from its added event until its removed one."),
    enumeration("siv_workspace_event_type", "What a siv_workspace_event reports.", &change_types),
    flags("siv_workspace_states", "A workspace's states.", &.{
        .{ .name = "active", .bit = 0, .doc = "Shown on its outputs." },
        .{ .name = "urgent", .bit = 1, .doc = "A window on it wants attention." },
        .{ .name = "hidden", .bit = 2, .doc = "The compositor suggests not showing it in a workspace switcher." },
    }),
    flags("siv_workspace_capabilities", "What the compositor allows for a workspace.", &.{
        .{ .name = "activate", .bit = 0, .doc = "siv_workspace_activate." },
        .{ .name = "deactivate", .bit = 1, .doc = "siv_workspace_deactivate." },
        .{ .name = "remove", .bit = 2, .doc = "siv_workspace_remove." },
    }),
    descriptor("siv_workspace_event", "A workspace appeared, changed, or went away. The compositor's changes arrive together, one event per workspace. Filled by siv; strings and arrays are valid during the call.", &.{
        f("type", ref("siv_workspace_event_type"), "What happened."),
        f("states", ref("siv_workspace_states"), "Its states."),
        f("workspace", ref("siv_workspace"), "The workspace."),
        f("name", .string, "Its name, as a switcher shows it."),
        f("identifier", .string, "An identifier the compositor keeps across sessions where it can; may be empty."),
        f("outputs", array(ref("siv_output")), "The outputs its group is on, for a switcher per output."),
        f("capabilities", ref("siv_workspace_capabilities"), "What may be asked of it."),
        .{ .name = "reserved0", .type = .u32, .doc = "Zero.", .reserved = true },
    }),
    callback("siv_workspace_list_fn", "Receives workspace events at safe points on the application's thread (D5).", &.{
        p("list", ref("siv_workspace_list"), "The list."),
        p("event", .{ .desc = "siv_workspace_event" }, "The event, valid during the call."),
    }),
    descriptor("siv_workspace_list_desc", "Options for siv_workspace_list_create.", &.{
        f("user_data", .user_data, "Passed to on_event and destroy."),
        f("on_event", ref("siv_workspace_list_fn"), "Receives the workspaces' events."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the list is destroyed."),
    }),

    // Idle notification.
    handle("siv_idle_watch", "Watches whether the user is idle (ext-idle-notify-v1, D31). Valid until siv_idle_watch_destroy."),
    flags("siv_idle_flags", "Idle watch options.", &.{
        .{ .name = "ignore_inhibitors", .bit = 0, .doc = "Report idling even while an application inhibits it (a video playing): for a screen lock that must follow input alone. Needs version 2 of the protocol." },
    }),
    callback("siv_idle_fn", "Receives an idle watch's changes at safe points on the application's thread (D5).", &.{
        p("watch", ref("siv_idle_watch"), "The watch."),
        p("idle", .bool, "True when the user has been idle for the timeout, false when they are back."),
    }),
    descriptor("siv_idle_watch_desc", "Options for siv_idle_watch_create.", &.{
        f("user_data", .user_data, "Passed to on_event and destroy."),
        f("on_event", ref("siv_idle_fn"), "Receives the changes."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the watch is destroyed."),
        f("timeout_ms", .u32, "How long without input counts as idle."),
        f("flags", ref("siv_idle_flags"), "Options."),
    }),
};

pub const functions = [_]Function{
    call("siv_app_get_capabilities", "The optional desktop shell protocols the compositor offers (D31). The headless backend offers all but blur unless a test asks (siv_test_set_blur).", &.{
        app_param,
        p("capabilities", out(ref("siv_capabilities")), "What it offers."),
    }),
    call("siv_app_watch_outputs", "Reports the compositor's outputs: an added event for every output there is, at the next dispatch, then events as outputs are plugged in, change, and go. Replaces an earlier callback, whose destroy-notify runs; a NULL callback stops.", &.{
        app_param,
        p("callback", ref("siv_output_fn"), "Receives the events; may be NULL."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data when replaced or the application is destroyed; may be NULL."),
        p("user_data", .user_data, "Passed to both."),
    }),
    call("siv_layer_create", "Creates a layer window (D31, wlr-layer-shell): a desktop shell surface such as a bar, dock, wallpaper, notification, launcher, or on-screen display, placed by its output edges rather than by the window manager. It is a siv_window: its tree, popups, menus, tooltips, and the window calls that are not about toplevels work as for any window; the compositor sizes it with resized events. Its root is a window without a frame to assistive technology; give it a role and name (siv_set_semantics: toolbar for a bar, alert for a notification). Layer windows keep siv_app_run running as toplevels do: it returns when the last of them is destroyed. When the compositor closes it (its output went away) it gets a closed event and is destroyed." ++ unsupported ++ " SIV_ERROR_INVALID_ARGUMENT for a zero size on an axis without both of its anchors.", &.{
        app_param,
        p("desc", .{ .desc = "siv_layer_desc" }, "Where it goes and how it behaves."),
        p("window", out(ref("siv_window")), "The window."),
    }),
    call("siv_window_set_layer", "Changes a layer window's layer, anchors, margins, exclusive zone, keyboard mode, and size, from desc; its callbacks, output, namespace, language, and window flags stay those of its creation. Shown with its next frame; a resized event follows if its size changes. SIV_ERROR_INVALID_ARGUMENT for a window that is not a layer window, or a zero size without both anchors.", &.{
        p("window", ref("siv_window"), "A layer window."),
        p("desc", .{ .desc = "siv_layer_desc" }, "The new placement."),
    }),
    call("siv_lock_create", "Asks the compositor to lock the session (D31, ext-session-lock-v1), for a lock screen. siv makes a lock window for every output, and for outputs plugged in later, reported in window events, then the compositor locks (locked) or refuses (denied). Authenticate the user off the application's thread (siv_job_start running PAM, for example) with a masked editor for the password (SIV_EDITOR_MASKED, whose text is kept in locked memory), then call siv_lock_unlock. The lock keeps siv_app_run running until it is unlocked, destroyed, denied, or finished, so a lock screen of nothing else returns from siv_app_run then; its lock windows do not count, since they come and go with outputs. One lock at a time (SIV_ERROR_BUSY)." ++ unsupported, &.{
        app_param,
        p("desc", .{ .desc = "siv_lock_desc" }, "Callbacks."),
        p("lock", out(ref("siv_lock")), "The lock."),
    }),
    call("siv_lock_unlock", "Unlocks the session (or, before locked, withdraws the request) and ends the lock: its windows are destroyed, and so is the handle, whose destroy-notify runs.", &.{
        p("lock", ref("siv_lock"), "The lock."),
    }),
    teardown("siv_lock_destroy", "Destroys the handle without unlocking: a locked session stays locked, its lock windows are destroyed, and the compositor shows a solid color until another lock client unlocks it, as when a lock screen fails. For a lock that was denied or finished, the usual way to let go of it.", &.{
        p("lock", ref("siv_lock"), "The lock."),
    }),
    call("siv_toplevel_list_create", "Starts receiving the desktop's toplevel windows (D31): an added event for each one there is, then events as they change and close. Uses wlr-foreign-toplevel-management where the compositor offers it, whose toplevels have states, outputs, parents, and accept requests (SIV_TOPLEVEL_MANAGED), and ext-foreign-toplevel-list otherwise, whose toplevels have titles, app ids, and identifiers only. One list per application (SIV_ERROR_BUSY)." ++ unsupported, &.{
        app_param,
        p("desc", .{ .desc = "siv_toplevel_list_desc" }, "Callbacks."),
        p("list", out(ref("siv_toplevel_list")), "The list."),
    }),
    teardown("siv_toplevel_list_destroy", "Stops the list; its toplevel handles become invalid, and its destroy-notify runs.", &.{p("list", ref("siv_toplevel_list"), "The list.")}),
    call("siv_toplevel_activate", "Asks the compositor to focus a toplevel, unminimizing it and switching to its workspace as it sees fit. SIV_ERROR_UNSUPPORTED unless it is managed (SIV_TOPLEVEL_MANAGED).", &.{p("toplevel", ref("siv_toplevel"), "The toplevel.")}),
    call("siv_toplevel_close", "Asks a toplevel's application to close it, as its close button would; it may ask the user first. SIV_ERROR_UNSUPPORTED unless it is managed.", &.{p("toplevel", ref("siv_toplevel"), "The toplevel.")}),
    call("siv_toplevel_set_minimized", "Asks the compositor to minimize or restore a toplevel. SIV_ERROR_UNSUPPORTED unless it is managed.", &.{ p("toplevel", ref("siv_toplevel"), "The toplevel."), p("minimized", .bool, "Minimize.") }),
    call("siv_toplevel_set_maximized", "Asks the compositor to maximize or restore a toplevel. SIV_ERROR_UNSUPPORTED unless it is managed.", &.{ p("toplevel", ref("siv_toplevel"), "The toplevel."), p("maximized", .bool, "Maximize.") }),
    call("siv_toplevel_set_fullscreen", "Asks the compositor to make a toplevel fullscreen, on an output or its choice, or not. SIV_ERROR_UNSUPPORTED unless it is managed and the compositor has version 2 of the protocol.", &.{
        p("toplevel", ref("siv_toplevel"), "The toplevel."),
        p("fullscreen", .bool, "Fullscreen."),
        p("output", ref("siv_output"), "The output to fill; 0 for the compositor's choice."),
    }),
    call("siv_workspace_list_create", "Starts receiving the desktop's workspaces (D31, ext-workspace-v1): an added event for each one there is, then events as they change. One list per application (SIV_ERROR_BUSY)." ++ unsupported, &.{
        app_param,
        p("desc", .{ .desc = "siv_workspace_list_desc" }, "Callbacks."),
        p("list", out(ref("siv_workspace_list")), "The list."),
    }),
    teardown("siv_workspace_list_destroy", "Stops the list; its workspace handles become invalid, and its destroy-notify runs.", &.{p("list", ref("siv_workspace_list"), "The list.")}),
    call("siv_workspace_activate", "Asks the compositor to show a workspace on its outputs. SIV_ERROR_UNSUPPORTED unless its capabilities allow it.", &.{p("workspace", ref("siv_workspace"), "The workspace.")}),
    call("siv_workspace_deactivate", "Asks the compositor to stop showing a workspace, where it allows several at once. SIV_ERROR_UNSUPPORTED unless its capabilities allow it.", &.{p("workspace", ref("siv_workspace"), "The workspace.")}),
    call("siv_workspace_remove", "Asks the compositor to remove a workspace. SIV_ERROR_UNSUPPORTED unless its capabilities allow it.", &.{p("workspace", ref("siv_workspace"), "The workspace.")}),
    call("siv_idle_watch_create", "Watches whether the user is idle (D31, ext-idle-notify-v1): the callback runs with true once the seat has had no input for the timeout, and with false when input resumes, for screen blanking, away status, and locking after a while. Idle inhibitors (siv_inhibit, a video playing) hold it off unless SIV_IDLE_IGNORE_INHIBITORS." ++ unsupported, &.{
        app_param,
        p("desc", .{ .desc = "siv_idle_watch_desc" }, "The timeout and callbacks."),
        p("watch", out(ref("siv_idle_watch")), "The watch."),
    }),
    teardown("siv_idle_watch_destroy", "Stops watching; its destroy-notify runs.", &.{p("watch", ref("siv_idle_watch"), "The watch.")}),
};
