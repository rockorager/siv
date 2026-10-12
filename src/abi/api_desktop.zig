//! The desktop integration part of the API schema (D19): portals,
//! application actions, and (later) lifecycle, printing, and the tray.
//! api.zig appends these declarations and functions to its own; the
//! conventions are schema.zig's. Implemented in portal.zig.

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

fn value(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .value, .fields = fields } };
}

fn descriptor(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .descriptor, .fields = fields } };
}

fn callback(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param, comptime ret: schema.Type) Decl {
    return .{ .callback = .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ret } };
}

const result_ref = ref("siv_result");

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = result_ref };
}

fn op(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = result_ref, .must_use = false };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

const app_param = p("app", ref("siv_app"), "The application.");
const parent_param = p("window", ref("siv_window"), "The window the dialog belongs to, or 0 for none.");
const result_callback = [_]Param{
    p("callback", ref("siv_portal_fn"), "Receives the result; may be NULL."),
    p("destroy", ref("siv_destroy_fn"), "Releases user_data after the callback ran or the application was destroyed; may be NULL."),
    p("user_data", .user_data, "Passed to both."),
};
const buffer_out = [_]Param{
    p("buffer", .buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
    p("len", out(.usize), "The full length in bytes."),
};

pub const decls = [_]Decl{
    // Portals.
    enumeration("siv_portal_response", "How a portal request ended (D19).", &.{
        .{ .name = "success", .value = 0, .doc = "The interaction completed; the results are set." },
        .{ .name = "cancelled", .value = 1, .doc = "The user cancelled." },
        .{ .name = "ended", .value = 2, .doc = "The desktop ended the interaction another way, such as denying it." },
        .{ .name = "unavailable", .value = 3, .doc = "No portal provides this: there is no session bus (the headless backend has none), or xdg-desktop-portal or its backend lacks the interface." },
        .{ .name = "failed", .value = 4, .doc = "The portal refused the request, or the bus connection was lost." },
    }),
    descriptor("siv_portal_result", "The outcome of a portal request. Filled by siv; fields that do not apply are zero, and strings are valid during the call.", &.{
        .{ .name = "uri", .type = .string, .doc = "siv_screenshot: the image's URI. siv_document_export: the file's path in the document portal." },
        .{ .name = "id", .type = .string, .doc = "siv_document_export: the document's id." },
        .{ .name = "color", .type = ref("siv_color"), .doc = "siv_pick_color: the color picked." },
        .{ .name = "response", .type = ref("siv_portal_response"), .doc = "How the request ended." },
        .{ .name = "count", .type = .u32, .doc = "siv_file_chooser_show: how many files or folders were chosen." },
    }),
    callback("siv_portal_fn", "Receives the result of a portal request at a safe point on the application's thread (D5).", &.{
        p("result", .{ .desc = "siv_portal_result" }, "The result, valid during the call."),
    }, .void),

    flags("siv_open_uri_flags", "Options for siv_open_uri.", &.{
        .{ .name = "ask", .bit = 0, .doc = "Let the user choose the application even if there is a default." },
        .{ .name = "writable", .bit = 1, .doc = "A local file: let the application write to it." },
        .{ .name = "show_in_folder", .bit = 2, .doc = "A local file: show it in the file manager instead of opening it." },
    }),
    flags("siv_screenshot_flags", "Options for siv_screenshot.", &.{
        .{ .name = "interactive", .bit = 0, .doc = "Let the user choose the area and options first." },
        .{ .name = "not_modal", .bit = 1, .doc = "Do not make the dialog modal to the window." },
    }),

    // Notifications and actions.
    enumeration("siv_notification_priority", "How urgent a notification is.", &.{
        .{ .name = "normal", .value = 0, .doc = "Normal." },
        .{ .name = "low", .value = 1, .doc = "Low." },
        .{ .name = "high", .value = 2, .doc = "High." },
        .{ .name = "urgent", .value = 3, .doc = "Urgent." },
    }),
    flags("siv_notification_flags", "Notification options.", &.{
        .{ .name = "transient", .bit = 0, .doc = "Show it without keeping it in the notification list. Needs version 2 of the portal's interface; older portals show it as usual." },
    }),
    value("siv_notification_button", "A notification button: activating it invokes an application action (siv_app_add_action).", &.{
        .{ .name = "label", .type = .string, .doc = "The button's label." },
        .{ .name = "action", .type = .string, .doc = "The action's name." },
        .{ .name = "target", .type = .string, .doc = "The action's parameter; empty for none." },
    }),
    descriptor("siv_notification_desc", "A desktop notification.", &.{
        .{ .name = "id", .type = .string, .doc = "Identifies the notification: sending one with the same id replaces it, and siv_notification_withdraw takes it back." },
        .{ .name = "title", .type = .string, .doc = "The title." },
        .{ .name = "body", .type = .string, .doc = "The body text." },
        .{ .name = "icon", .type = .string, .doc = "A themed icon name, such as mail-unread; empty for the application's icon." },
        .{ .name = "icon_data", .type = array(.u8), .doc = "An encoded image (PNG) instead of a themed icon." },
        .{ .name = "default_action", .type = .string, .doc = "The action activating the notification invokes; empty activates the application." },
        .{ .name = "default_target", .type = .string, .doc = "The default action's parameter." },
        .{ .name = "buttons", .type = array(ref("siv_notification_button")), .doc = "Buttons (copied)." },
        .{ .name = "priority", .type = ref("siv_notification_priority"), .doc = "Default normal." },
        .{ .name = "flags", .type = ref("siv_notification_flags"), .doc = "Options." },
    }),
    descriptor("siv_action_event", "An application action invoked by the desktop. Filled by siv; strings are valid during the call.", &.{
        .{ .name = "name", .type = .string, .doc = "The action's name." },
        .{ .name = "target", .type = .string, .doc = "Its parameter, or empty." },
        .{ .name = "activation_token", .type = .string, .doc = "An xdg-activation token for showing a window, or empty." },
    }),
    callback("siv_action_fn", "Runs an application action at a safe point on the application's thread (D5).", &.{
        p("event", .{ .desc = "siv_action_event" }, "The invocation, valid during the call."),
    }, .void),

    // Inhibiting the session.
    handle("siv_inhibition", "Keeps the session from logging out, switching users, suspending, or going idle until destroyed."),
    flags("siv_inhibit_flags", "What to inhibit.", &.{
        .{ .name = "logout", .bit = 0, .doc = "Logging out." },
        .{ .name = "user_switch", .bit = 1, .doc = "Switching users." },
        .{ .name = "suspend", .bit = 2, .doc = "Suspending." },
        .{ .name = "idle", .bit = 3, .doc = "Going idle (screen blanking and locking)." },
    }),

    // The file chooser.
    handle("siv_file_chooser", "The system's file chooser (the portal's; siv has none of its own): a dialog to set up, show, and read the choice from."),
    enumeration("siv_file_chooser_mode", "What a file chooser asks for.", &.{
        .{ .name = "open", .value = 0, .doc = "Existing files (or folders, with SIV_FILE_CHOOSER_DIRECTORY)." },
        .{ .name = "save", .value = 1, .doc = "A file name to save to." },
    }),
    flags("siv_file_chooser_flags", "File chooser options.", &.{
        .{ .name = "multiple", .bit = 0, .doc = "Open: allow choosing several." },
        .{ .name = "directory", .bit = 1, .doc = "Open: choose folders instead of files." },
        .{ .name = "not_modal", .bit = 2, .doc = "Do not make the dialog modal to the window." },
    }),
    enumeration("siv_file_pattern_kind", "How a file filter pattern matches.", &.{
        .{ .name = "glob", .value = 0, .doc = "A case-sensitive shell glob such as *.png." },
        .{ .name = "mime", .value = 1, .doc = "A MIME type such as image/png." },
    }),
    descriptor("siv_file_chooser_desc", "How a file chooser starts.", &.{
        .{ .name = "title", .type = .string, .doc = "The dialog's title." },
        .{ .name = "accept_label", .type = .string, .doc = "The accept button's label, with a mnemonic underscore; empty for the default." },
        .{ .name = "current_name", .type = .string, .doc = "Save: the suggested file name." },
        .{ .name = "current_folder", .type = .string, .doc = "The folder to start in (a path)." },
        .{ .name = "current_file", .type = .string, .doc = "Save: an existing file to save over (a path)." },
        .{ .name = "mode", .type = ref("siv_file_chooser_mode"), .doc = "Default open." },
        .{ .name = "flags", .type = ref("siv_file_chooser_flags"), .doc = "Options." },
    }),

    // Global shortcuts.
    handle("siv_global_shortcuts", "Shortcuts that work while the application is not focused, bound through the desktop, which lets the user choose their keys."),
    enumeration("siv_global_shortcut_event_type", "What a siv_global_shortcut_event reports.", &.{
        .{ .name = "bound", .value = 0, .doc = "siv_global_shortcuts_bind finished; response says how. Triggers are set." },
        .{ .name = "activated", .value = 1, .doc = "The shortcut id was pressed." },
        .{ .name = "deactivated", .value = 2, .doc = "The shortcut id was released." },
        .{ .name = "changed", .value = 3, .doc = "The user changed the triggers." },
        .{ .name = "closed", .value = 4, .doc = "The desktop ended the session; bind again to use the shortcuts." },
    }),
    descriptor("siv_global_shortcut_event", "A global shortcut event. Filled by siv; strings are valid during the call.", &.{
        .{ .name = "type", .type = ref("siv_global_shortcut_event_type"), .doc = "What happened." },
        .{ .name = "response", .type = ref("siv_portal_response"), .doc = "Bound: how binding ended." },
        .{ .name = "id", .type = .string, .doc = "Activated and deactivated: the shortcut." },
        .{ .name = "timestamp_ms", .type = .u64, .doc = "Activated and deactivated: when, in milliseconds." },
    }),
    callback("siv_global_shortcut_fn", "Receives global shortcut events at safe points on the application's thread (D5).", &.{
        p("shortcuts", ref("siv_global_shortcuts"), "The shortcuts."),
        p("event", .{ .desc = "siv_global_shortcut_event" }, "The event, valid during the call."),
    }, .void),
    descriptor("siv_global_shortcuts_desc", "The event callback of a set of global shortcuts.", &.{
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to on_event and destroy." },
        .{ .name = "on_event", .type = ref("siv_global_shortcut_fn"), .doc = "Receives events; may be NULL." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the shortcuts are destroyed." },
    }),

    // Screen casts.
    handle("siv_screencast", "A screen cast: monitors or windows the user chose, as PipeWire streams the application reads with its own PipeWire client."),
    flags("siv_screencast_sources", "What a screen cast may record.", &.{
        .{ .name = "monitor", .bit = 0, .doc = "Monitors." },
        .{ .name = "window", .bit = 1, .doc = "Windows." },
        .{ .name = "virtual", .bit = 2, .doc = "A virtual monitor." },
    }),
    enumeration("siv_cursor_mode", "How a screen cast shows the pointer.", &.{
        .{ .name = "default", .value = 0, .doc = "The desktop's choice." },
        .{ .name = "hidden", .value = 1, .doc = "Not at all." },
        .{ .name = "embedded", .value = 2, .doc = "Drawn into the frames." },
        .{ .name = "metadata", .value = 3, .doc = "As stream metadata." },
    }),
    enumeration("siv_persist_mode", "Whether the user's choice of sources can be restored.", &.{
        .{ .name = "none", .value = 0, .doc = "No." },
        .{ .name = "transient", .value = 1, .doc = "While the application runs." },
        .{ .name = "persistent", .value = 2, .doc = "Until the user revokes it." },
    }),
    flags("siv_screencast_flags", "Screen cast options.", &.{
        .{ .name = "multiple", .bit = 0, .doc = "Let the user choose several sources." },
    }),
    enumeration("siv_screencast_event_type", "What a siv_screencast_event reports.", &.{
        .{ .name = "started", .value = 0, .doc = "The cast started (response success, streams and the PipeWire fd set) or did not (response says why)." },
        .{ .name = "closed", .value = 1, .doc = "The desktop stopped the cast." },
    }),
    descriptor("siv_screencast_event", "A screen cast event. Filled by siv.", &.{
        .{ .name = "type", .type = ref("siv_screencast_event_type"), .doc = "What happened." },
        .{ .name = "response", .type = ref("siv_portal_response"), .doc = "Started: how starting ended." },
    }),
    callback("siv_screencast_fn", "Receives screen cast events at safe points on the application's thread (D5).", &.{
        p("screencast", ref("siv_screencast"), "The cast."),
        p("event", .{ .desc = "siv_screencast_event" }, "The event, valid during the call."),
    }, .void),
    descriptor("siv_screencast_desc", "What a screen cast records, and its event callback.", &.{
        .{ .name = "restore_token", .type = .string, .doc = "A token from an earlier cast (siv_screencast_get_restore_token) to restore its sources without asking." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to on_event and destroy." },
        .{ .name = "on_event", .type = ref("siv_screencast_fn"), .doc = "Receives events; may be NULL." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the cast is destroyed." },
        .{ .name = "sources", .type = ref("siv_screencast_sources"), .doc = "What may be recorded; 0 is monitors." },
        .{ .name = "cursor", .type = ref("siv_cursor_mode"), .doc = "Default: the desktop's choice." },
        .{ .name = "persist", .type = ref("siv_persist_mode"), .doc = "Default none." },
        .{ .name = "flags", .type = ref("siv_screencast_flags"), .doc = "Options." },
    }),
    value("siv_screencast_stream", "A stream of a running screen cast.", &.{
        .{ .name = "node_id", .type = .u32, .doc = "The PipeWire node to connect to." },
        .{ .name = "sources", .type = ref("siv_screencast_sources"), .doc = "What it shows (one bit), or 0 if the desktop did not say." },
        .{ .name = "x", .type = .i32, .doc = "Position in the desktop's space; 0 if unknown." },
        .{ .name = "y", .type = .i32, .doc = "Position in the desktop's space; 0 if unknown." },
        .{ .name = "width", .type = .i32, .doc = "Size in logical pixels; 0 if unknown." },
        .{ .name = "height", .type = .i32, .doc = "Size in logical pixels; 0 if unknown." },
    }),

    // The document portal.
    flags("siv_document_permissions", "What another application may do with an exported document.", &.{
        .{ .name = "read", .bit = 0, .doc = "Read it." },
        .{ .name = "write", .bit = 1, .doc = "Write it." },
        .{ .name = "grant", .bit = 2, .doc = "Grant permissions to others." },
        .{ .name = "delete", .bit = 3, .doc = "Delete it." },
    }),
    flags("siv_document_flags", "How a document is exported.", &.{
        .{ .name = "reuse_existing", .bit = 0, .doc = "Return the existing document if the file is exported already." },
        .{ .name = "persistent", .bit = 1, .doc = "Keep the document after this session." },
        .{ .name = "directory", .bit = 2, .doc = "Export a directory." },
    }),
    descriptor("siv_document_desc", "A file to make available to sandboxed applications through the document portal.", &.{
        .{ .name = "path", .type = .string, .doc = "The file (or directory)." },
        .{ .name = "app_id", .type = .string, .doc = "The application to grant permissions to; empty for none." },
        .{ .name = "permissions", .type = ref("siv_document_permissions"), .doc = "What app_id may do." },
        .{ .name = "flags", .type = ref("siv_document_flags"), .doc = "Options." },
    }),
};

pub const functions = [_]Function{
    call("siv_open_uri", "Opens a URI in the user's preferred application through the portal (D19), or with SIV_OPEN_URI_SHOW_IN_FOLDER shows a local file in the file manager. file:// URIs are opened by file descriptor, which works inside Flatpak too. The application opened gets an activation token from the window's last input, so it may take focus.", &.{
        app_param,                                    parent_param,
        p("uri", .string, "The URI."),               p("flags", ref("siv_open_uri_flags"), "Options."),
        result_callback[0],                           result_callback[1],
        result_callback[2],
    }),
    call("siv_screenshot", "Takes a screenshot through the portal; the result's uri names the image.", &.{
        app_param,          parent_param, p("flags", ref("siv_screenshot_flags"), "Options."),
        result_callback[0], result_callback[1], result_callback[2],
    }),
    call("siv_pick_color", "Lets the user pick a color from the screen through the portal; the result's color has it.", &.{
        app_param, parent_param, result_callback[0], result_callback[1], result_callback[2],
    }),
    call("siv_notify", "Shows a desktop notification through the portal, replacing one with the same id. Fails with SIV_ERROR_UNAVAILABLE without a session bus.", &.{
        app_param, p("desc", .{ .desc = "siv_notification_desc" }, "The notification."),
    }),
    op("siv_notification_withdraw", "Takes a notification back.", &.{ app_param, p("id", .string, "Its id.") }),
    call("siv_app_add_action", "Registers an application action, or replaces the one with the same name: notification buttons invoke it, and so does the desktop through D-Bus activation. The replaced callback's destroy-notify runs.", &.{
        app_param,
        p("name", .string, "The action's name."),
        p("callback", ref("siv_action_fn"), "Runs the action."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data when the action is removed or replaced or the application destroyed; may be NULL."),
        p("user_data", .user_data, "Passed to both."),
    }),
    op("siv_app_remove_action", "Removes an application action; its destroy-notify runs.", &.{ app_param, p("name", .string, "The action's name.") }),
    call("siv_inhibit", "Keeps the session from logging out, switching users, suspending, or going idle, as the desktop allows, until the handle is destroyed. Without a portal it does nothing.", &.{
        app_param,
        parent_param,
        p("flags", ref("siv_inhibit_flags"), "What to inhibit; at least one."),
        p("reason", .string, "Why, as the desktop may show it."),
        p("inhibition", out(ref("siv_inhibition")), "The inhibition."),
    }),
    op("siv_inhibition_destroy", "Ends an inhibition.", &.{p("inhibition", ref("siv_inhibition"), "The inhibition.")}),

    call("siv_file_chooser_create", "Creates a file chooser. Add filters and choices, then show it.", &.{
        app_param,
        p("desc", .{ .desc = "siv_file_chooser_desc" }, "How it starts; NULL opens one file."),
        p("chooser", out(ref("siv_file_chooser")), "The chooser."),
    }),
    call("siv_file_chooser_add_filter", "Adds a filter the user can select; patterns added next belong to it.", &.{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("name", .string, "The filter's name, such as Images."),
    }),
    call("siv_file_chooser_add_pattern", "Adds a pattern to the last filter added.", &.{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("kind", ref("siv_file_pattern_kind"), "How it matches."),
        p("pattern", .string, "The glob or MIME type."),
    }),
    call("siv_file_chooser_set_current_filter", "Selects a filter at first, by the order filters were added.", &.{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("index", .u32, "The filter."),
    }),
    call("siv_file_chooser_add_choice", "Adds a choice shown with the dialog: a combo box once options are added to it, otherwise a check box whose values are true and false.", &.{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("id", .string, "Identifies it in the result."),
        p("label", .string, "Its label."),
        p("initial", .string, "The option (or true or false) selected at first."),
    }),
    call("siv_file_chooser_add_choice_option", "Adds an option to the last choice added.", &.{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("id", .string, "Identifies the option."),
        p("label", .string, "Its label."),
    }),
    call("siv_file_chooser_show", "Shows the chooser; the callback gets the response, after which the getters return the choice. SIV_ERROR_BUSY while it is shown.", &.{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        parent_param,
        result_callback[0],
        result_callback[1],
        result_callback[2],
    }),
    op("siv_file_chooser_cancel", "Closes the shown dialog; the callback does not run (its destroy-notify does).", &.{p("chooser", ref("siv_file_chooser"), "The chooser.")}),
    call("siv_file_chooser_get_uri_count", "How many files or folders were chosen.", &.{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("count", out(.u32), "The number of URIs."),
    }),
    call("siv_file_chooser_get_uri", "Copies a chosen file's file:// URI. Inside Flatpak it points into the document portal.", &([_]Param{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("index", .u32, "Below the URI count."),
    } ++ buffer_out)),
    call("siv_file_chooser_get_path", "Copies a chosen file's local path, decoded from its URI; SIV_ERROR_UNSUPPORTED for a URI that is not a local file.", &([_]Param{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("index", .u32, "Below the URI count."),
    } ++ buffer_out)),
    call("siv_file_chooser_get_choice", "Copies the value the user chose for a choice; SIV_ERROR_INVALID_ARGUMENT if the portal returned none.", &([_]Param{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("id", .string, "The choice."),
    } ++ buffer_out)),
    call("siv_file_chooser_get_filter", "The filter selected when the user accepted, by the order filters were added, or -1.", &.{
        p("chooser", ref("siv_file_chooser"), "The chooser."),
        p("index", out(.i32), "The filter, or -1."),
    }),
    op("siv_file_chooser_destroy", "Destroys a chooser, closing its dialog if shown.", &.{p("chooser", ref("siv_file_chooser"), "The chooser.")}),

    call("siv_global_shortcuts_create", "Creates a set of global shortcuts. Add shortcuts, then bind them.", &.{
        app_param,
        p("desc", .{ .desc = "siv_global_shortcuts_desc" }, "The event callback; NULL for none."),
        p("shortcuts", out(ref("siv_global_shortcuts")), "The shortcuts."),
    }),
    call("siv_global_shortcuts_add", "Adds a shortcut to bind.", &.{
        p("shortcuts", ref("siv_global_shortcuts"), "The shortcuts."),
        p("id", .string, "Identifies it in events."),
        p("description", .string, "What it does, as the desktop shows it."),
        p("preferred_trigger", .string, "Keys to suggest, in the XDG shortcuts format (CTRL+ALT+t); empty for none."),
    }),
    call("siv_global_shortcuts_bind", "Binds the shortcuts added so far; the desktop may ask the user to assign keys. A bound event follows. SIV_ERROR_BUSY while binding.", &.{
        p("shortcuts", ref("siv_global_shortcuts"), "The shortcuts."),
        parent_param,
    }),
    call("siv_global_shortcuts_get_trigger", "Copies the keys bound to a shortcut, as the desktop describes them; empty if none.", &([_]Param{
        p("shortcuts", ref("siv_global_shortcuts"), "The shortcuts."),
        p("id", .string, "The shortcut."),
    } ++ buffer_out)),
    op("siv_global_shortcuts_destroy", "Unbinds and destroys the shortcuts.", &.{p("shortcuts", ref("siv_global_shortcuts"), "The shortcuts.")}),

    call("siv_screencast_start", "Starts a screen cast: the desktop asks the user what to share, then a started event follows. Its streams are PipeWire nodes on the remote siv_screencast_take_pipewire_fd returns.", &.{
        app_param,
        parent_param,
        p("desc", .{ .desc = "siv_screencast_desc" }, "What to record; NULL for one monitor."),
        p("screencast", out(ref("siv_screencast")), "The cast."),
    }),
    call("siv_screencast_get_stream_count", "The number of streams of a started cast.", &.{
        p("screencast", ref("siv_screencast"), "The cast."),
        p("count", out(.u32), "The number of streams."),
    }),
    call("siv_screencast_get_stream", "A stream of a started cast.", &.{
        p("screencast", ref("siv_screencast"), "The cast."),
        p("index", .u32, "Below the stream count."),
        p("stream", out(ref("siv_screencast_stream")), "The stream."),
    }),
    call("siv_screencast_get_restore_token", "Copies the token that restores this cast's sources later (siv_screencast_desc.restore_token); empty unless persisted.", &([_]Param{
        p("screencast", ref("siv_screencast"), "The cast."),
    } ++ buffer_out)),
    call("siv_screencast_take_pipewire_fd", "Takes the PipeWire remote of a started cast; the caller owns and closes it. SIV_ERROR_INVALID_ARGUMENT if there is none or it was taken.", &.{
        p("screencast", ref("siv_screencast"), "The cast."),
        p("fd", out(.i32), "The file descriptor."),
    }),
    op("siv_screencast_destroy", "Stops and destroys a cast; an untaken PipeWire fd is closed.", &.{p("screencast", ref("siv_screencast"), "The cast.")}),

    call("siv_document_export", "Makes a file available to sandboxed applications through the document portal; the result's uri is its path there and id its document id.", &([_]Param{
        app_param,
        p("desc", .{ .desc = "siv_document_desc" }, "The file."),
    } ++ result_callback)),
};
