//! The desktop integration part of the API schema (D19): portals,
//! lifecycle, printing and PDF, and the tray.
//! api.zig appends these declarations and functions to its own; the
//! conventions are schema.zig's. Implemented in portal.zig, print.zig, and tray.zig.

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

/// Teardown (D2): it cannot fail, and a stale handle does nothing.
fn teardown(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc ++ " A stale handle does nothing.", .since = v0_1, .params = params };
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
    p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
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
        .{ .name = "token", .type = .string, .doc = "siv_window_request_activation_token: the token, empty if the compositor gave none." },
    }),
    callback("siv_portal_fn", "Receives the result of a portal request at a safe point on the application's thread (D5).", &.{
        p("result", .{ .desc = "siv_portal_result" }, "The result, valid during the call."),
    }, .void),

    // Session restore.
    enumeration("siv_session_reason", "Why the application starts a session, which may decide how much the compositor restores.", &.{
        .{ .name = "launch", .value = 0, .doc = "Started by the user, from a launcher: compositors restore sizes and places." },
        .{ .name = "recover", .value = 1, .doc = "Started again after the application or the compositor crashed: compositors may restore more, such as workspaces and stacking." },
        .{ .name = "restore", .value = 2, .doc = "Started as part of restoring the user's session." },
    }),
    enumeration("siv_session_event_type", "What a siv_session_event reports.", &.{
        .{ .name = "created", .value = 0, .doc = "A new session: nothing was restored. session_id is its id, to save and pass to siv_app_start_session next time." },
        .{ .name = "restored", .value = 1, .doc = "The session was found: windows created from now on with a session name it knows are restored. Its id stays the same." },
        .{ .name = "replaced", .value = 2, .doc = "Another instance took the session over; it is gone here." },
        .{ .name = "unavailable", .value = 3, .doc = "The compositor offers no session management; windows open as usual." },
    }),
    descriptor("siv_session_event", "A session event. Filled by siv; strings are valid during the call.", &.{
        .{ .name = "session_id", .type = .string, .doc = "Created: the session's id." },
        .{ .name = "type", .type = ref("siv_session_event_type"), .doc = "What happened." },
        .{ .name = "reserved0", .type = .u32, .doc = "Reserved; zero.", .reserved = true },
    }),
    callback("siv_session_fn", "Receives session events at safe points on the application's thread (D5).", &.{
        p("event", .{ .desc = "siv_session_event" }, "The event, valid during the call."),
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
    value("siv_notification_button", "A notification button: activating it invokes an application action (siv_action_create, D34).", &.{
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
    enumeration("siv_screencast_cursor", "How a screen cast shows the pointer.", &.{
        .{ .name = "default", .value = 0, .doc = "The desktop's choice." },
        .{ .name = "hidden", .value = 1, .doc = "Not at all." },
        .{ .name = "embedded", .value = 2, .doc = "Drawn into the frames." },
        .{ .name = "metadata", .value = 3, .doc = "As stream metadata." },
    }),
    enumeration("siv_screencast_persist", "Whether the user's choice of sources can be restored.", &.{
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
        .{ .name = "cursor", .type = ref("siv_screencast_cursor"), .doc = "Default: the desktop's choice." },
        .{ .name = "persist", .type = ref("siv_screencast_persist"), .doc = "Default none." },
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

    // Lifecycle.
    value("siv_uri", "A URI.", &.{
        .{ .name = "uri", .type = .string, .doc = "The URI." },
    }),
    flags("siv_launch_flags", "How an application launches.", &.{
        .{ .name = "service", .bit = 0, .doc = "Started by D-Bus activation (the Exec line of the application's D-Bus service file passes an argument saying so): wait for the desktop's call instead of activating." },
        .{ .name = "multiple_instances", .bit = 1, .doc = "Allow several instances: every launch is primary, and nothing is exported on the bus." },
    }),
    enumeration("siv_activation_type", "What an activation asks for.", &.{
        .{ .name = "activate", .value = 0, .doc = "Show the application (a window)." },
        .{ .name = "open", .value = 1, .doc = "Open the URIs." },
    }),
    enumeration("siv_activation_source", "Where an activation came from.", &.{
        .{ .name = "launch", .value = 0, .doc = "This launch." },
        .{ .name = "remote", .value = 1, .doc = "Another instance, or the desktop over D-Bus." },
    }),
    descriptor("siv_activation", "An activation. Filled by siv; valid during the call.", &.{
        .{ .name = "uris", .type = array(ref("siv_uri")), .doc = "Open: the URIs." },
        .{ .name = "activation_token", .type = .string, .doc = "An xdg-activation token: pass it to siv_window_activate for the window the activation shows. Empty if there is none." },
        .{ .name = "type", .type = ref("siv_activation_type"), .doc = "What to do." },
        .{ .name = "source", .type = ref("siv_activation_source"), .doc = "Where it came from." },
    }),
    callback("siv_activate_fn", "Handles an activation at a safe point on the application's thread (D5): typically creates or presents a window.", &.{
        p("app", ref("siv_app"), "The application."),
        p("activation", .{ .desc = "siv_activation" }, "The activation, valid during the call."),
    }, .void),
    descriptor("siv_launch_desc", "How an application launches (siv_app_launch).", &.{
        .{ .name = "uris", .type = array(ref("siv_uri")), .doc = "URIs to open, such as files from the command line (copied)." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to on_activate and destroy." },
        .{ .name = "on_activate", .type = ref("siv_activate_fn"), .doc = "Handles activations." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the application is destroyed." },
        .{ .name = "flags", .type = ref("siv_launch_flags"), .doc = "Options." },
        .{ .name = "idle_timeout_ms", .type = .u32, .doc = "Services: siv_app_run returns when no window is open this long after an activation; 0 waits forever." },
    }),
    enumeration("siv_instance", "What this process is, after siv_app_launch.", &.{
        .{ .name = "none", .value = 0, .doc = "siv_app_launch was not called." },
        .{ .name = "pending", .value = 1, .doc = "Waiting for the bus to say whether another instance runs." },
        .{ .name = "primary", .value = 2, .doc = "The instance that serves the application: activations come here." },
        .{ .name = "secondary", .value = 3, .doc = "Another instance runs: this launch was forwarded to it, and siv_app_run returns." },
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

    // Printing and PDF.
    descriptor("siv_page_setup", "The paper pages are laid out on, in points (1/72 inch) with y down from its top-left corner, as oriented: landscape paper is wider than tall. Filled by siv.", &.{
        .{ .name = "width", .type = .f32, .doc = "The paper's width." },
        .{ .name = "height", .type = .f32, .doc = "The paper's height." },
        .{ .name = "margin_top", .type = .f32, .doc = "The margins the printer or the user chose; content outside them may not print." },
        .{ .name = "margin_right", .type = .f32, .doc = "Right margin." },
        .{ .name = "margin_bottom", .type = .f32, .doc = "Bottom margin." },
        .{ .name = "margin_left", .type = .f32, .doc = "Left margin." },
    }),
    callback("siv_print_begin_fn", "Lays a document out for a page setup at a safe point on the application's thread (D5), before its pages are drawn.", &.{
        p("setup", .{ .desc = "siv_page_setup" }, "The page setup, valid during the call."),
    }, .u32),
    callback("siv_print_page_fn", "Draws one page of a document at a safe point on the application's thread (D5), with the siv_draw_* functions as a canvas does. Text keeps its characters (searchable and copyable in the PDF) and follows the document's language and direction; colors are the light theme's.", &.{
        p("draw", ref("siv_draw"), "Valid during the call."),
        p("page", .u32, "The page, from 0."),
        p("setup", .{ .desc = "siv_page_setup" }, "The page setup, valid during the call."),
    }, .void),
    flags("siv_print_flags", "Printing options.", &.{
        .{ .name = "not_modal", .bit = 0, .doc = "siv_print: do not make the dialog modal to the window." },
    }),
    descriptor("siv_print_desc", "A document to print or write as PDF: its pages, drawn on demand.", &.{
        .{ .name = "title", .type = .string, .doc = "The document's title: the PDF's, and the print job's name." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to the callbacks." },
        .{ .name = "begin", .type = ref("siv_print_begin_fn"), .doc = "Returns the number of pages for the page setup; NULL uses page_count." },
        .{ .name = "draw_page", .type = ref("siv_print_page_fn"), .doc = "Draws a page. Required." },
        .{ .name = "done", .type = ref("siv_portal_fn"), .doc = "Receives the outcome; the result's count is the number of pages. May be NULL." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data after done ran or the application was destroyed." },
        .{ .name = "page_count", .type = .u32, .doc = "The number of pages when begin is NULL." },
        .{ .name = "width", .type = .f32, .doc = "siv_pdf_write: the paper's width in points; 0 with height 0 is A4. siv_print: the paper to assume if the dialog names none." },
        .{ .name = "height", .type = .f32, .doc = "The paper's height in points." },
        .{ .name = "flags", .type = ref("siv_print_flags"), .doc = "Options." },
        .{ .name = "language", .type = .string, .doc = "BCP 47 language of the pages' text, for shaping and font fallback; empty is the window's for siv_print with a window, else the application's (siv_app_desc.language)." },
        .{ .name = "direction", .type = ref("siv_direction"), .doc = "The pages' direction, which siv_draw_text aligns and orders text by; inherit is the window's for siv_print with a window, else the application's." },
        .{ .name = "margin", .type = .f32, .doc = "siv_pdf_write: the margins siv_page_setup reports, in points, on every side. siv_print: the margins to assume if the dialog names none." },
    }),

    // The tray.
    handle("siv_tray_item", "A system tray icon (StatusNotifierItem) with an optional menu. One per application."),
    enumeration("siv_tray_status", "How prominently the desktop shows a tray item.", &.{
        .{ .name = "active", .value = 0, .doc = "Shown." },
        .{ .name = "passive", .value = 1, .doc = "Nothing needs the user; the desktop may hide it." },
        .{ .name = "needs_attention", .value = 2, .doc = "Shown with the attention icon." },
    }),
    enumeration("siv_tray_category", "What a tray item is about.", &.{
        .{ .name = "application_status", .value = 0, .doc = "The application's status." },
        .{ .name = "communications", .value = 1, .doc = "Messages and calls." },
        .{ .name = "system_services", .value = 2, .doc = "A system service." },
        .{ .name = "hardware", .value = 3, .doc = "Hardware." },
    }),
    flags("siv_tray_flags", "Tray item options.", &.{
        .{ .name = "item_is_menu", .bit = 0, .doc = "Activating the item shows its menu instead of sending activate." },
    }),
    enumeration("siv_tray_event_type", "What a siv_tray_event reports.", &.{
        .{ .name = "registered", .value = 0, .doc = "The desktop's tray accepted the item: it may be shown." },
        .{ .name = "unregistered", .value = 1, .doc = "No tray runs, or it went away or refused the item: show the application another way. It registers again when a tray appears." },
        .{ .name = "activate", .value = 2, .doc = "The item was activated (clicked); x and y are screen coordinates if the desktop knows them, and activation_token lets a window take focus (siv_window_activate)." },
        .{ .name = "secondary_activate", .value = 3, .doc = "Secondary activation (a middle click)." },
        .{ .name = "context_menu", .value = 4, .doc = "The desktop asks for a context menu, for an item without menu entries." },
        .{ .name = "scroll", .value = 5, .doc = "A scroll over the item by delta steps." },
        .{ .name = "menu", .value = 6, .doc = "The menu entry menu_item was clicked." },
    }),
    flags("siv_tray_event_flags", "Details of a tray event.", &.{
        .{ .name = "horizontal", .bit = 0, .doc = "Scroll: horizontal, not vertical." },
    }),
    descriptor("siv_tray_event", "A tray event. Filled by siv; strings are valid during the call.", &.{
        .{ .name = "activation_token", .type = .string, .doc = "Activate: an xdg-activation token from the desktop, or empty." },
        .{ .name = "type", .type = ref("siv_tray_event_type"), .doc = "What happened." },
        .{ .name = "x", .type = .i32, .doc = "Activations and context menus: the screen position, or 0." },
        .{ .name = "y", .type = .i32, .doc = "The screen position, or 0." },
        .{ .name = "delta", .type = .i32, .doc = "Scroll: the steps." },
        .{ .name = "menu_item", .type = .u32, .doc = "Menu: the entry's id." },
        .{ .name = "flags", .type = ref("siv_tray_event_flags"), .doc = "Details." },
    }),
    callback("siv_tray_fn", "Receives tray events at safe points on the application's thread (D5).", &.{
        p("item", ref("siv_tray_item"), "The item."),
        p("event", .{ .desc = "siv_tray_event" }, "The event, valid during the call."),
    }, .void),
    descriptor("siv_tray_item_desc", "A tray item.", &.{
        .{ .name = "id", .type = .string, .doc = "Identifies the item to the desktop across runs; empty uses the application id." },
        .{ .name = "title", .type = .string, .doc = "The item's name, such as the application's." },
        .{ .name = "icon_name", .type = .string, .doc = "A themed icon name; siv_tray_item_set_icon can add an image." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to on_event and destroy." },
        .{ .name = "on_event", .type = ref("siv_tray_fn"), .doc = "Receives events; may be NULL." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the item is destroyed." },
        .{ .name = "category", .type = ref("siv_tray_category"), .doc = "Default application status." },
        .{ .name = "flags", .type = ref("siv_tray_flags"), .doc = "Options." },
    }),
    enumeration("siv_tray_menu_item_kind", "What a tray menu entry is.", &.{
        .{ .name = "normal", .value = 0, .doc = "A command, or a submenu once entries are added to it." },
        .{ .name = "separator", .value = 1, .doc = "A separator." },
        .{ .name = "check", .value = 2, .doc = "A check box." },
        .{ .name = "radio", .value = 3, .doc = "A radio button." },
    }),
    flags("siv_tray_menu_item_flags", "Tray menu entry state.", &.{
        .{ .name = "disabled", .bit = 0, .doc = "Shown but not clickable." },
        .{ .name = "hidden", .bit = 1, .doc = "Not shown." },
        .{ .name = "checked", .bit = 2, .doc = "Check and radio entries: checked." },
    }),
    descriptor("siv_tray_menu_item_desc", "An entry of a tray item's menu.", &.{
        .{ .name = "label", .type = .string, .doc = "The label, with a mnemonic underscore." },
        .{ .name = "icon_name", .type = .string, .doc = "A themed icon name, or empty." },
        .{ .name = "id", .type = .u32, .doc = "Identifies the entry: nonzero, below 2^31." },
        .{ .name = "parent", .type = .u32, .doc = "The entry it is in, or 0 for the top level." },
        .{ .name = "kind", .type = ref("siv_tray_menu_item_kind"), .doc = "Default normal." },
        .{ .name = "flags", .type = ref("siv_tray_menu_item_flags"), .doc = "State." },
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
    call("siv_notification_send", "Shows a desktop notification through the portal, replacing one with the same id. Fails with SIV_ERROR_UNAVAILABLE without a session bus.", &.{
        app_param, p("desc", .{ .desc = "siv_notification_desc" }, "The notification."),
    }),
    teardown("siv_notification_withdraw", "Takes a notification back.", &.{ app_param, p("id", .string, "Its id.") }),
    call("siv_app_start_session", "Joins a session (D17, xdg-session-management): the compositor remembers the size, place, and states of windows with a session name (siv_window_desc.session_name), and restores them in the next run that joins the same session, before they map. Start it before creating the windows to restore; windows that already exist are only remembered. Replaces the application's earlier session and its callback.", &.{
        app_param,
        p("session_id", .string, "The id a created event gave in an earlier run, or empty for a new session; an unknown id starts a new one."),
        p("reason", ref("siv_session_reason"), "Why the application is starting."),
        p("callback", ref("siv_session_fn"), "Receives the session's events; may be NULL."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data when the session ends or the application is destroyed; may be NULL."),
        p("user_data", .user_data, "Passed to both."),
    }),
    teardown("siv_app_remove_session", "Leaves the session and has the compositor forget it, as when the user closes the application for good.", &.{app_param}),
    call("siv_inhibit", "Keeps the session from logging out, switching users, suspending, or going idle, as the desktop allows, until the handle is destroyed (D17). An inhibition of idling alone for a window goes through the compositor (idle-inhibit) when it offers that: it holds while the window is visible, which is what a video or presentation in it needs, and works without a portal. Everything else, and idling without that protocol, goes through the portal; without one it does nothing.", &.{
        app_param,
        parent_param,
        p("flags", ref("siv_inhibit_flags"), "What to inhibit; at least one."),
        p("reason", .string, "Why, as the desktop may show it."),
        p("inhibition", out(ref("siv_inhibition")), "The inhibition."),
    }),
    teardown("siv_inhibition_destroy", "Ends an inhibition.", &.{p("inhibition", ref("siv_inhibition"), "The inhibition.")}),

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
    teardown("siv_file_chooser_cancel", "Closes the shown dialog; the callback does not run (its destroy-notify does).", &.{p("chooser", ref("siv_file_chooser"), "The chooser.")}),
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
    teardown("siv_file_chooser_destroy", "Destroys a chooser, closing its dialog if shown.", &.{p("chooser", ref("siv_file_chooser"), "The chooser.")}),

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
    teardown("siv_global_shortcuts_destroy", "Unbinds and destroys the shortcuts.", &.{p("shortcuts", ref("siv_global_shortcuts"), "The shortcuts.")}),

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
    teardown("siv_screencast_destroy", "Stops and destroys a cast; an untaken PipeWire fd is closed.", &.{p("screencast", ref("siv_screencast"), "The cast.")}),

    call("siv_app_launch", "Launches the application as a single instance (D19): the first instance to own the application id (siv_app_desc.app_id) on the session bus is primary and gets its activation (on_activate, at the next dispatch, with $XDG_ACTIVATION_TOKEN's token, which is removed from the environment) and every later one, from other instances and from the desktop over org.freedesktop.Application (D-Bus activation for DBusActivatable desktop files). A later instance forwards its activation, or its URIs, to the primary instead, and siv_app_run returns (SIV_ERROR_UNAVAILABLE if forwarding failed). Without an application id or a session bus, every launch is primary. Once per application (SIV_ERROR_BUSY).", &.{
        app_param,
        p("desc", .{ .desc = "siv_launch_desc" }, "The activation handler and URIs."),
    }),
    call("siv_app_get_instance", "Whether this process is the primary instance.", &.{
        app_param,
        p("instance", out(ref("siv_instance")), "The instance."),
    }),
    call("siv_window_activate", "Asks the compositor to focus the window with an xdg-activation token another application passed on (siv_activation.activation_token); for a window not shown yet, once it is.", &.{
        p("window", ref("siv_window"), "The window."),
        p("token", .string, "The token; empty does nothing."),
    }),
    call("siv_window_request_activation_token", "Asks for an xdg-activation token tied to the window's last input, to pass to an application this one starts ($XDG_ACTIVATION_TOKEN) so that it may take focus. The result's token is empty when the compositor gives none.", &.{
        p("window", ref("siv_window"), "The window."),
        result_callback[0],
        result_callback[1],
        result_callback[2],
    }),

    call("siv_pdf_write", "Writes a document as PDF (D9) to a file descriptor, which is duplicated: at the next dispatch the pages are drawn, waiting for fonts that are still loading, and written; then done gets success, or failed if writing failed. Text is embedded as font subsets with its characters. Fails without starting (and runs destroy) if draw_page is NULL or fd is negative.", &.{
        app_param,
        p("desc", .{ .desc = "siv_print_desc" }, "The document."),
        p("fd", .i32, "Where to write, from its current offset."),
    }),
    call("siv_print", "Prints a document through the Print portal (D19): the system's print dialog asks for the printer and page setup, then the pages are drawn for that page setup as a PDF the print system receives. done gets success when the job was handed over, cancelled if the user cancelled, or unavailable without a portal. The print system applies copies and page ranges itself.", &.{
        app_param,
        parent_param,
        p("desc", .{ .desc = "siv_print_desc" }, "The document."),
    }),

    call("siv_tray_item_create", "Shows a tray icon (D19): an org.kde.StatusNotifierItem registered with the desktop's tray, with a com.canonical.dbusmenu menu. Events say whether a tray shows it. SIV_ERROR_UNAVAILABLE without a session bus, SIV_ERROR_BUSY if the application has one already.", &.{
        app_param,
        p("desc", .{ .desc = "siv_tray_item_desc" }, "The item."),
        p("item", out(ref("siv_tray_item")), "The item."),
    }),
    call("siv_tray_item_set_title", "Sets the item's title.", &.{ p("item", ref("siv_tray_item"), "The item."), p("title", .string, "The title.") }),
    call("siv_tray_item_set_status", "Sets how prominently the item shows.", &.{ p("item", ref("siv_tray_item"), "The item."), p("status", ref("siv_tray_status"), "The status.") }),
    call("siv_tray_item_set_icon", "Sets the icon: a themed name, an image, or both; the desktop prefers the name when its theme has it. Images with 8-bit pixels are sent; others are SIV_ERROR_UNSUPPORTED.", &.{
        p("item", ref("siv_tray_item"), "The item."),
        p("icon_name", .string, "A themed icon name, or empty."),
        p("image", ref("siv_image"), "An image, or 0."),
    }),
    call("siv_tray_item_set_attention_icon", "Sets the icon shown with SIV_TRAY_STATUS_NEEDS_ATTENTION, as siv_tray_item_set_icon.", &.{
        p("item", ref("siv_tray_item"), "The item."),
        p("icon_name", .string, "A themed icon name, or empty."),
        p("image", ref("siv_image"), "An image, or 0."),
    }),
    call("siv_tray_item_set_tooltip", "Sets the tooltip.", &.{
        p("item", ref("siv_tray_item"), "The item."),
        p("title", .string, "Its title."),
        p("body", .string, "Its text, which desktops may show with simple markup."),
    }),
    call("siv_tray_item_set_menu_item", "Adds a menu entry, or replaces the one with its id. New entries go after their siblings. SIV_ERROR_INVALID_ARGUMENT if the parent does not exist or is inside the entry.", &.{
        p("item", ref("siv_tray_item"), "The item."),
        p("desc", .{ .desc = "siv_tray_menu_item_desc" }, "The entry."),
    }),
    teardown("siv_tray_item_remove_menu_item", "Removes a menu entry and the entries in it.", &.{ p("item", ref("siv_tray_item"), "The item."), p("id", .u32, "The entry.") }),
    teardown("siv_tray_item_destroy", "Removes the item from the tray and destroys it.", &.{p("item", ref("siv_tray_item"), "The item.")}),

    call("siv_document_export", "Makes a file available to sandboxed applications through the document portal; the result's uri is its path there and id its document id.", &([_]Param{
        app_param,
        p("desc", .{ .desc = "siv_document_desc" }, "The file."),
    } ++ result_callback)),
};
