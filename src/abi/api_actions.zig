//! The actions part of the API schema (D34): named commands with an
//! enabled state and an optional value, which accelerators, widgets bound
//! to them, the desktop, and assistive technology share. api.zig appends
//! these declarations and functions to its own; the conventions are
//! schema.zig's. Implemented in actions.zig.

const schema = @import("schema.zig");
const ref = schema.ref;
const out = schema.out;
const array = schema.array;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn enumeration(comptime name: []const u8, comptime doc: []const u8, comptime values: []const schema.EnumValue) Decl {
    return .{ .@"enum" = .{ .name = name, .doc = doc, .since = v0_1, .values = values } };
}

fn flags(comptime name: []const u8, comptime doc: []const u8, comptime bits: []const schema.Flag) Decl {
    return .{ .flags = .{ .name = name, .doc = doc, .since = v0_1, .bits = bits } };
}

fn value(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .value, .fields = fields } };
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

fn reserved(comptime name: []const u8) schema.Field {
    return .{ .name = name, .type = .u32, .doc = "Reserved: zero.", .reserved = true };
}

const action_param = p("action", ref("siv_action"), "The action.");

pub const decls = [_]Decl{
    enumeration("siv_action_kind", "What an action's value means.", &.{
        .{ .name = "plain", .value = 0, .doc = "No value: activating it runs it." },
        .{ .name = "toggle", .value = 1, .doc = "On (1) or off (0): activating it flips the value, and toggles and menu items bound to it show it checked when on." },
        .{ .name = "choice", .value = 2, .doc = "One of several values, such as a view mode: activating it with a target sets the value to the target, and a node bound to it with that target shows it checked while the value equals it." },
    }),
    flags("siv_action_flags", "Action options.", &.{
        .{ .name = "disabled", .bit = 0, .doc = "Cannot run: its accelerators do nothing (the key goes on to siv's defaults), the desktop's requests are ignored, siv_action_activate fails, and nodes bound to it are disabled." },
    }),
    value("siv_accel", "A keyboard accelerator: a key, the modifiers held with it, and for an action the target it passes (D34). Letters match in either case; write Shift when it must be held (Ctrl+Shift+N is n with ctrl and shift). A symbol typed with Shift, such as + on a US layout, matches without shift in its modifiers.", &.{
        f("key", ref("siv_key"), "The keysym; not 0. Shift+Tab is SIV_KEY_TAB with shift."),
        f("modifiers", ref("siv_modifiers"), "Shift, Ctrl, Alt, and Super; Caps Lock and Num Lock are an invalid argument."),
        f("target", .f64, "Actions: what the key passes, as a bound node's target does, so that Ctrl+1 and Ctrl+2 choose two values of one choice action; finite. Ignored elsewhere."),
    }),
    descriptor("siv_action_desc", "An action.", &.{
        f("name", .string, "Identifies it in its scope: the application's, or its window's, where it shadows an application action with the same name. The desktop invokes application actions by it (notification buttons, desktop file actions). Not empty; copied."),
        f("label", .string, "What people call it, for menus, command palettes, and shortcut windows, copied: a menu item bound to it without a label of its own shows it."),
        f("window", ref("siv_window"), "The window it belongs to, or 0 for the application: a window's actions answer only its own keys (and its popups'), and go with it."),
        f("kind", ref("siv_action_kind"), "What its value means; default plain."),
        f("flags", ref("siv_action_flags"), "Options."),
        f("value", .f64, "Its first value: 0 or 1 for toggles, the chosen target for choices."),
        f("accels", array(ref("siv_accel")), "The keys that invoke it, copied. Menus and assistive technology show the first (for a node bound to a choice, the first with the node's target)."),
    }),
    value("siv_action_state", "An action's state, as siv_action_get_state reports it.", &.{
        f("window", ref("siv_window"), "The window it belongs to, or 0 for the application."),
        f("value", .f64, "Its value."),
        f("kind", ref("siv_action_kind"), "Its kind."),
        f("flags", ref("siv_action_flags"), "Its options: disabled."),
        f("accel_count", .u32, "How many accelerators it has (siv_action_get_accel)."),
        reserved("reserved0"),
        reserved("reserved1"),
        reserved("reserved2"),
    }),
    descriptor("siv_action_event", "An action invoked (D34). Filled by siv; strings are valid during the call.", &.{
        f("name", .string, "The action's name."),
        f("target", .string, "The desktop's parameter (a notification button's target, ActivateAction's first string parameter), or empty."),
        f("activation_token", .string, "From the desktop: an xdg-activation token for showing a window, or empty."),
        f("action", ref("siv_action"), "The action."),
        f("window", ref("siv_window"), "The window whose key, widget, or command invoked it; 0 when the desktop did."),
        f("value", .f64, "Plain actions: the target of the node or call that invoked it. Toggles and choices: the value it now has, set before the callback runs."),
    }),
    callback("siv_action_fn", "Runs an action at a safe point on the application's thread (D5).", &.{
        p("event", .{ .desc = "siv_action_event" }, "The invocation, valid during the call."),
    }),
};

pub const functions = [_]Function{
    call("siv_action_create", "Creates an action (D34). Its accelerators work at once, and nodes bound to it follow it. The application's actions are org.freedesktop.Application actions, which notification buttons and desktop file actions invoke by name (D19).", &.{
        p("app", ref("siv_app"), "The application."),
        p("desc", .{ .desc = "siv_action_desc" }, "The action. SIV_ERROR_INVALID_ARGUMENT for an empty or invalid name, a name its scope already has, a window of another application, or an invalid accelerator."),
        p("callback", ref("siv_action_fn"), "Runs it; may be NULL for a toggle or choice the application only reads."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data when the action is destroyed; may be NULL."),
        p("user_data", .user_data, "Passed to both."),
        .{ .name = "action", .type = out(ref("siv_action")), .doc = "The action, to bind nodes to, change, or destroy.", .optional = true },
    }),
    teardown("siv_action_destroy", "Destroys an action: its accelerators stop, the desktop can no longer invoke it, and nodes bound to it stay as they are and invoke nothing. Its destroy-notify runs.", &.{action_param}),
    call("siv_action_set_enabled", "Enables or disables an action. Nodes bound to it follow through their widget interface's set_disabled (D22): at once, or when an open transaction on their window ends.", &.{
        action_param,
        p("enabled", .bool, "Whether it can run."),
    }),
    call("siv_action_set_value", "Sets a toggle's or choice's value without running it, as when the application's state changed some other way. Nodes bound to it follow through their widget interface's set_value, as siv_action_set_enabled says. SIV_ERROR_INVALID_ARGUMENT for a plain action or a value that is not finite.", &.{
        action_param,
        p("value", .f64, "0 or 1 for toggles; any finite value for choices."),
    }),
    call("siv_action_set_accels", "Replaces an action's accelerators.", &.{
        action_param,
        p("accels", array(ref("siv_accel")), "The keys, copied; empty for none."),
    }),
    call("siv_action_activate", "Runs an action as a key or a bound widget would, from a command palette or the application's own code: a toggle flips, a choice takes the target, then the callback runs. SIV_ERROR_BUSY when it is disabled.", &.{
        action_param,
        p("window", ref("siv_window"), "The window it runs for, reported in the event; 0 for none (a window's action reports its own)."),
        p("target", .f64, "The value a choice takes, or a plain action's parameter; toggles ignore it."),
    }),
    call("siv_action_get_state", "An action's kind, value, enabled state, window, and number of accelerators.", &.{
        action_param,
        p("state", out(ref("siv_action_state")), "The state."),
    }),
    call("siv_action_get_name", "Copies an action's name.", &.{
        action_param,
        p("name", schema.text_buffer, "Receives at most name_cap bytes; may be NULL with name_cap 0."),
        p("len", out(.usize), "The name's full length in bytes."),
    }),
    call("siv_action_get_label", "Copies an action's label.", &.{
        action_param,
        p("label", schema.text_buffer, "Receives at most label_cap bytes; may be NULL with label_cap 0."),
        p("len", out(.usize), "The label's full length in bytes."),
    }),
    call("siv_action_get_accel", "One of an action's accelerators, in the order given. SIV_ERROR_INVALID_ARGUMENT past the last (siv_action_state.accel_count).", &.{
        action_param,
        p("index", .u32, "From 0."),
        p("accel", out(ref("siv_accel")), "The accelerator."),
    }),
    .{
        .name = "siv_app_get_action",
        .doc = "The actions a window's keys reach, one by one, for a shortcuts window or a command palette: the window's own in the order they were created, then the application's that none of them shadows; with window 0, the application's. Returns 0 past the last or for an invalid handle.",
        .since = v0_1,
        .params = &.{
            p("app", ref("siv_app"), "The application."),
            p("window", ref("siv_window"), "A window, or 0 for the application's actions only."),
            p("index", .u32, "From 0."),
        },
        .ret = ref("siv_action"),
    },
    .{
        .name = "siv_accel_format",
        .doc = "Writes an accelerator's key as menus show it: \"Ctrl+Shift+N\", \"Alt+Left\", \"F2\", \"Ctrl++\" (D34). The names are English. SIV_ERROR_INVALID_ARGUMENT for key 0 or modifiers other than Shift, Ctrl, Alt, and Super.",
        .since = v0_1,
        .thread = .any,
        .params = &.{
            p("accel", ref("siv_accel"), "The accelerator."),
            p("text", schema.text_buffer, "Receives at most text_cap bytes; may be NULL with text_cap 0."),
            p("len", out(.usize), "The text's full length in bytes."),
        },
        .ret = ref("siv_result"),
    },
    .{
        .name = "siv_set_action",
        .doc = "Binds a node to an action (D34), or unbinds it. Activating the node (a click, Enter or Space, assistive technology) then runs the action with the target, after the node's activate handlers unless one returned handled or prevent. The node follows the action through its widget interface (D22, set it first): set_disabled when the action is disabled or enabled, and for toggles and choices set_value with 1 when it is on (a choice: when its value equals the target) and 0 otherwise. A node without an interface only invokes it. Assistive technology sees the action's first accelerator with the node's target (any target for plain actions and toggles) as the node's key binding, unless siv_set_shortcut names one. A failure is the transaction's (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{
            p("txn", ref("siv_txn"), "An open transaction."),
            p("node", ref("siv_node"), "A node of the transaction's window."),
            p("action", ref("siv_action"), "The action, or 0 to unbind."),
            p("target", .f64, "What activating it passes: the value a choice takes, or a plain action's parameter."),
        },
    },
    .{
        .name = "siv_set_shortcut",
        .doc = "Names the key that does what activating a node does, for assistive technology: its key binding and keyshortcuts attribute (aria-keyshortcuts), as a menu row shows its item's (D34). It does not bind the key. A node bound to an action without one exposes the action's accelerator (siv_set_action). A failure is the transaction's (see siv_txn_commit).",
        .since = v0_1,
        .params = &.{
            p("txn", ref("siv_txn"), "An open transaction."),
            p("node", ref("siv_node"), "A node of the transaction's window."),
            p("accel", ref("siv_accel"), "The key; key 0 for none. The target is ignored."),
        },
    },
    call("siv_node_get_action", "The action a node is bound to (siv_set_action), as of the latest operation.", &.{
        p("node", ref("siv_node"), "The node."),
        p("action", out(ref("siv_action")), "The action, or 0 when it is bound to none."),
        .{ .name = "target", .type = out(.f64), .doc = "Its target.", .optional = true },
    }),
};
