//! The settings part of the API schema (D36): typed values an application
//! keeps between runs, preferences and state, in human-editable files
//! under the XDG base directories. api.zig appends these declarations and
//! functions to its own (the `siv_settings` handle is declared there, since
//! `siv_window_desc` names it); the conventions are schema.zig's.
//! Implemented in settings.zig.

const schema = @import("schema.zig");
const ref = schema.ref;
const out = schema.out;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn enumeration(comptime name: []const u8, comptime doc: []const u8, comptime values: []const schema.EnumValue) Decl {
    return .{ .@"enum" = .{ .name = name, .doc = doc, .since = v0_1, .values = values } };
}

fn descriptor(comptime name: []const u8, comptime doc: []const u8, comptime fields: []const schema.Field) Decl {
    return .{ .@"struct" = .{ .name = name, .doc = doc, .since = v0_1, .kind = .descriptor, .fields = fields } };
}

/// A reserved field (D2): zero, until a version gives it a meaning.
fn reserved(comptime name: []const u8) schema.Field {
    return .{ .name = name, .type = .u32, .doc = "Reserved; must be zero (SIV_ERROR_UNSUPPORTED otherwise).", .reserved = true };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

fn f(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) schema.Field {
    return .{ .name = name, .type = t, .doc = doc };
}

const settings_param = p("settings", ref("siv_settings"), "The store.");
const key_param = p("key", .string, "The key: names of ASCII letters, digits, '_', and '-' joined by dots, such as \"view.mode\" (written as view's table), at most 255 bytes; SIV_ERROR_INVALID_ARGUMENT otherwise.");

/// A call on a store and a key.
fn keyCall(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = &([_]Param{ settings_param, key_param } ++ params[0..params.len].*), .ret = ref("siv_result") };
}

fn getter(comptime name: []const u8, comptime what: []const u8, comptime t: schema.Type, comptime extra: []const u8) Function {
    return keyCall(name, "Reads a key as " ++ what ++ ": its value, or fallback when the key is unset or holds another type (D36)." ++ extra, &.{
        p("fallback", t, "The application's default."),
        p("value", out(t), "The value."),
    });
}

fn setter(comptime name: []const u8, comptime what: []const u8, comptime t: schema.Type, comptime extra: []const u8) Function {
    return keyCall(name, "Sets a key to " ++ what ++ ". Reads see it at once; the file has it within half a second, written on the worker pool (D6), and the change callback hears of it at the next dispatch. Setting the value a key has changes nothing." ++ extra, &.{
        p("value", t, "The value."),
    });
}

pub const decls = [_]Decl{
    enumeration("siv_settings_kind", "What a store keeps, which decides where its file goes (D36).", &.{
        .{ .name = "config", .value = 0, .doc = "Preferences the user chose: $XDG_CONFIG_HOME/<app_id>/<name>.toml (~/.config without the variable)." },
        .{ .name = "state", .value = 1, .doc = "What the application remembers for the user (window sizes, the last folder, column widths), which loses nothing chosen if deleted: $XDG_STATE_HOME/<app_id>/<name>.toml (~/.local/state without the variable)." },
    }),
    enumeration("siv_settings_origin", "Who changed a key.", &.{
        .{ .name = "application", .value = 0, .doc = "This store: a set or reset call." },
        .{ .name = "outside", .value = 1, .doc = "The file changed: another instance of the application, or someone editing it." },
    }),
    enumeration("siv_settings_type", "What a key holds.", &.{
        .{ .name = "none", .value = 0, .doc = "Nothing: the key is unset, so the application's default applies." },
        .{ .name = "bool", .value = 1, .doc = "A boolean." },
        .{ .name = "int", .value = 2, .doc = "A 64-bit signed integer." },
        .{ .name = "float", .value = 3, .doc = "A finite double." },
        .{ .name = "string", .value = 4, .doc = "UTF-8 text of at most 4096 bytes." },
    }),
    descriptor("siv_settings_change", "A key whose value changed. Filled by siv; the key is valid during the call.", &.{
        f("key", .string, "The key."),
        f("origin", ref("siv_settings_origin"), "Who changed it."),
        reserved("reserved0"),
    }),
    .{ .callback = .{ .name = "siv_settings_change_fn", .doc = "A key's value changed; runs at a safe point on the application's thread (D5), at the next dispatch after the change, once per key for a burst. Read the key again for its value.", .since = v0_1, .params = &.{
        p("settings", ref("siv_settings"), "The store."),
        p("change", .{ .desc = "siv_settings_change" }, "The change, valid during the call."),
    } } },
    descriptor("siv_settings_desc", "Options for siv_settings_open.", &.{
        f("name", .string, "The file's name without \".toml\": letters, digits, '_', '-', and '.', not starting with a dot. Empty is \"settings\" for preferences and \"state\" for state."),
        f("directory", .string, "An absolute directory for the file instead of the XDG one: tests, or an application that keeps its files elsewhere. Created when first written. On the headless backend without one, the store keeps values in memory only, so tests never read or write the user's files."),
        f("user_data", .user_data, "Passed to on_change and destroy."),
        f("on_change", ref("siv_settings_change_fn"), "Hears of every key whose value changed, whoever changed it; may be NULL."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the store is destroyed."),
        f("kind", ref("siv_settings_kind"), "Preferences (the default) or state."),
        reserved("reserved0"),
    }),
};

pub const functions = [_]Function{
    .{ .name = "siv_settings_open", .doc = "Opens a store of the application's preferences or state (D36): a TOML file of typed values under the XDG base directory for its kind, in a directory named by siv_app_desc.app_id (Flatpak gives each application its own XDG directories). The file is read now, so values are there for the first window; it holds only what was set, and the application's defaults stay in its code. Changes from another instance or an edit of the file are read while the application runs. SIV_ERROR_INVALID_ARGUMENT for a bad name, a relative directory, or neither a directory nor an application id to name one (the headless backend keeps such a store in memory); SIV_ERROR_BUSY when the application has that file open already; SIV_ERROR_UNAVAILABLE when neither the XDG variable nor $HOME says where it goes. A file that cannot be read gives an empty store.", .since = v0_1, .params = &.{
        p("app", ref("siv_app"), "The application."),
        p("desc", .{ .desc = "siv_settings_desc" }, "Options; NULL for preferences in settings.toml."),
        p("settings", out(ref("siv_settings")), "The store."),
    }, .ret = ref("siv_result") },
    .{ .name = "siv_settings_destroy", .doc = "Closes a store: changes not yet written go to the file on the worker pool, or at siv_app_destroy, which writes what is left before it returns. Windows bound to it stop saving their state. A stale handle does nothing.", .since = v0_1, .params = &.{settings_param} },
    keyCall("siv_settings_get_type", "What a key holds.", &.{p("type", out(ref("siv_settings_type")), "The type, none when unset.")}),
    getter("siv_settings_get_bool", "a boolean", .bool, ""),
    getter("siv_settings_get_int", "an integer", .i64, ""),
    getter("siv_settings_get_float", "a double", .f64, " An integer reads as a double too, as people write 2 for 2.0."),
    keyCall("siv_settings_get_string", "Reads a key as text: its value, or fallback when the key is unset or holds another type (D36).", &.{
        p("fallback", .string, "The application's default."),
        p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
        p("len", out(.usize), "The full length in bytes."),
    }),
    setter("siv_settings_set_bool", "a boolean", .bool, ""),
    setter("siv_settings_set_int", "an integer", .i64, ""),
    setter("siv_settings_set_float", "a double", .f64, " SIV_ERROR_INVALID_ARGUMENT for infinities and NaN, which the file cannot hold."),
    setter("siv_settings_set_string", "text", .string, " SIV_ERROR_INVALID_ARGUMENT for invalid UTF-8 or more than 4096 bytes."),
    keyCall("siv_settings_reset", "Unsets a key, so the application's default applies again; written like a set. An unset key changes nothing.", &.{}),
};
