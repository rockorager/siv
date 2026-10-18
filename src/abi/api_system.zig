//! The trash and system signals part of the API schema (D42): trashing,
//! restoring, listing, and emptying (the freedesktop.org Trash
//! specification, with the Trash portal inside Flatpak), and power
//! saving, memory pressure, and the network (the portals, with the system
//! services as fallbacks). api.zig appends these declarations and
//! functions to its own; the conventions are schema.zig's. Implemented in
//! trash.zig and system.zig.

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

fn callback(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Decl {
    return .{ .callback = .{ .name = name, .doc = doc, .since = v0_1, .params = params } };
}

fn call(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params, .ret = ref("siv_result") };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

fn f(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = t, .doc = doc };
}

fn reserved(comptime name: []const u8) schema.Field {
    return .{ .name = name, .type = .u32, .doc = "Reserved; zero.", .reserved = true };
}

const app_param = p("app", ref("siv_app"), "The application.");
const trash_callback = [_]Param{
    p("callback", ref("siv_trash_fn"), "Receives the result at a later dispatch, never inside the call; may be NULL."),
    p("destroy", ref("siv_destroy_fn"), "Releases user_data after the callback ran, or when the application is destroyed first; may be NULL."),
    p("user_data", .user_data, "Passed to both."),
};

pub const decls = [_]Decl{
    // The trash.
    enumeration("siv_trash_status", "How a trash operation ended (D42).", &.{
        .{ .name = "ok", .value = 0, .doc = "It was done." },
        .{ .name = "not_found", .value = 1, .doc = "The file, or the trashed item, does not exist; or the id names no item of a trash." },
        .{ .name = "access_denied", .value = 2, .doc = "Permission denied, or a read-only file system." },
        .{ .name = "exists", .value = 3, .doc = "Restoring: something is already at the destination. The item stays in the trash." },
        .{ .name = "unsupported", .value = 4, .doc = "The file's file system has no trash it can be moved to (its top directory allows neither .Trash/$uid nor .Trash-$uid), the file is the trash or in it, or restoring would cross file systems. Offer to delete it instead." },
        .{ .name = "no_space", .value = 5, .doc = "No space left for the trash's information file." },
        .{ .name = "unavailable", .value = 6, .doc = "Inside Flatpak: the trash is out of the sandbox's reach and no Trash portal answered (or, for listing, restoring, deleting, and emptying, which the portal cannot do, the home trash is not shared with the sandbox)." },
        .{ .name = "failed", .value = 7, .doc = "Anything else: the portal refused, an unexpected system error, out of memory." },
    }),
    flags("siv_trash_item_flags", "What a trashed item is.", &.{
        .{ .name = "directory", .bit = 0, .doc = "A directory: bytes is its disk usage." },
    }),
    value("siv_trash_item", "An item of a trash, as siv_trash_list reports it.", &.{
        f("id", .string, "The item: its path in its trash's files folder, for siv_trash_restore and siv_trash_delete, and to show or open it."),
        f("path", .string, "Where it was, absolute; empty if its information file names no place."),
        f("deletion_time", .i64, "When it was trashed, in seconds since the epoch; 0 if unknown."),
        f("bytes", .u64, "A file's size; a directory's disk usage, as du -B1 counts it."),
        f("flags", ref("siv_trash_item_flags"), "What it is."),
        reserved("reserved0"),
    }),
    descriptor("siv_trash_result", "The outcome of a trash operation. Filled by siv; strings and items are valid during the call.", &.{
        f("id", .string, "siv_trash_file: the trashed item's id, for siv_trash_restore (undo) and siv_trash_delete; empty when the Trash portal trashed it, since the portal does not say where it went (D42). siv_trash_restore and siv_trash_delete: the id given."),
        f("path", .string, "siv_trash_file: the file trashed. siv_trash_restore: where the item went."),
        f("items", array(ref("siv_trash_item")), "siv_trash_list: every item of every trash."),
        f("status", ref("siv_trash_status"), "How it ended; the other fields are set when it is ok."),
        reserved("reserved0"),
    }),
    callback("siv_trash_fn", "Receives the result of a trash operation at a safe point on the application's thread (D5).", &.{
        p("result", .{ .desc = "siv_trash_result" }, "The result, valid during the call."),
    }),

    // System signals.
    flags("siv_system_flags", "Power and network states in a siv_system_state.", &.{
        .{ .name = "power_saver", .bit = 0, .doc = "The user turned power saving on (power-profiles-daemon's power-saver profile): do less in the background, poll less often, defer work that can wait." },
        .{ .name = "network_available", .bit = 1, .doc = "A network is available: a route beyond this host. Set until something says otherwise, as GIO assumes." },
        .{ .name = "network_metered", .bit = 2, .doc = "The network is metered (a mobile connection, a hotspot): avoid large downloads and updates the user did not ask for." },
    }),
    enumeration("siv_network_connectivity", "How far the network reaches. Full until something says otherwise, as GIO assumes.", &.{
        .{ .name = "full", .value = 0, .doc = "The Internet." },
        .{ .name = "limited", .value = 1, .doc = "A network, but not the Internet." },
        .{ .name = "captive_portal", .value = 2, .doc = "The Internet after signing in to a captive portal, such as a hotel's." },
        .{ .name = "local", .value = 3, .doc = "Nothing beyond this host." },
    }),
    value("siv_system_state", "Power saving and the network as the desktop reports them (D42): xdg-desktop-portal's PowerProfileMonitor and NetworkMonitor, else power-profiles-daemon and NetworkManager on the system bus, else the defaults (power saving off, the network available, unmetered, and full). The headless backend, and applications with SIV_APP_NO_DESKTOP_SETTINGS, keep the defaults.", &.{
        f("flags", ref("siv_system_flags"), "States."),
        f("connectivity", ref("siv_network_connectivity"), "How far the network reaches."),
    }),
    enumeration("siv_memory_pressure", "How short the system is of memory, from low-memory-monitor's levels. siv drops its own caches first (D42).", &.{
        .{ .name = "low", .value = 0, .doc = "Free memory that is cheap to recreate." },
        .{ .name = "medium", .value = 1, .doc = "Free memory that takes some effort to recreate." },
        .{ .name = "critical", .value = 2, .doc = "Free everything that can be recreated; the system is about to end processes." },
    }),
    enumeration("siv_system_event_type", "What a siv_system_event reports.", &.{
        .{ .name = "power_saver", .value = 0, .doc = "Power saving went on or off; state has the new value." },
        .{ .name = "memory", .value = 1, .doc = "A low memory warning, at memory_pressure. siv has dropped its caches already." },
        .{ .name = "network", .value = 2, .doc = "The network's availability, metering, or connectivity changed; state has the new values." },
    }),
    descriptor("siv_system_event", "A system signal. Filled by siv.", &.{
        f("type", ref("siv_system_event_type"), "What happened."),
        f("memory_pressure", ref("siv_memory_pressure"), "Memory: the warning's level."),
        f("state", ref("siv_system_state"), "Power saving and the network after the change."),
    }),
    handle("siv_system_monitor", "Receives system signals (D42) until destroyed. Valid until siv_system_monitor_destroy or the application goes."),
    callback("siv_system_fn", "Receives a system signal at a safe point on the application's thread (D5).", &.{
        p("monitor", ref("siv_system_monitor"), "The monitor."),
        p("event", .{ .desc = "siv_system_event" }, "The event, valid during the call."),
    }),
    descriptor("siv_system_monitor_desc", "The event callback of a system monitor.", &.{
        f("user_data", .user_data, "Passed to on_event and destroy."),
        f("on_event", ref("siv_system_fn"), "Receives the signals; may be NULL."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the monitor is destroyed."),
    }),
};

pub const functions = [_]Function{
    call("siv_trash_file", "Moves a file or folder to the trash (D42) on the worker pool. Outside Flatpak siv does it as the freedesktop.org Trash specification says: files on the home trash's file system go to $XDG_DATA_HOME/Trash, others to the trash at the top of their mount, with an information file of where they were and when; the result's id restores the item (siv_trash_restore), so an application can push the delete onto an undo stack (D35). Inside Flatpak siv does the same when the sandbox can reach the home trash and the file is on its file system, and otherwise asks the Trash portal, which trashes the file but does not say where: the result's id is then empty and the delete cannot be undone. A symbolic link is trashed, not its target.", &([_]Param{
        app_param,
        p("path", .string, "The file, an absolute path."),
    } ++ trash_callback)),
    call("siv_trash_restore", "Moves a trashed item back to where it was, or to dest, on the worker pool, creating missing parent folders; never replaces anything (SIV_TRASH_STATUS_EXISTS).", &([_]Param{
        app_param,
        p("id", .string, "The item: an id from siv_trash_file or siv_trash_list."),
        p("dest", .string, "Where to put it, an absolute path; empty for where it was."),
    } ++ trash_callback)),
    call("siv_trash_delete", "Deletes a trashed item for good, on the worker pool.", &([_]Param{
        app_param,
        p("id", .string, "The item."),
    } ++ trash_callback)),
    call("siv_trash_list", "Lists every trashed item, of the home trash and of the trashes at the top of every mount, on the worker pool. Directory sizes come from each trash's directorysizes cache, which siv keeps current.", &([_]Param{app_param} ++ trash_callback)),
    call("siv_trash_empty", "Deletes everything in every trash for good, on the worker pool. It goes on past items it cannot delete and reports the first failure.", &([_]Param{app_param} ++ trash_callback)),

    call("siv_app_get_system_state", "Power saving and the network now (D42). System monitors say when they change.", &.{
        app_param,
        p("state", out(ref("siv_system_state")), "The state."),
    }),
    call("siv_system_monitor_create", "Starts receiving system signals: power saving going on or off, low memory warnings, and network changes. siv follows them itself whether or not a monitor exists: power saving stops caret blinking, and a memory warning drops siv's caches before monitors hear of it.", &.{
        app_param,
        p("desc", .{ .desc = "siv_system_monitor_desc" }, "The event callback."),
        p("monitor", out(ref("siv_system_monitor")), "The monitor."),
    }),
    .{ .name = "siv_system_monitor_destroy", .doc = "Stops a monitor and releases its user data. A stale handle does nothing.", .since = v0_1, .params = &.{p("monitor", ref("siv_system_monitor"), "The monitor.")} },
    call("siv_test_system_signal", "The desktop reports a system signal, as its portal or system service would (D27): power saving or the network takes event's state, or memory runs short at event's memory_pressure, and siv and the monitors react at once, as to a real signal. Headless backend only (SIV_ERROR_UNSUPPORTED otherwise).", &.{
        app_param,
        p("event", .{ .desc = "siv_system_event" }, "The signal."),
    }),
};
