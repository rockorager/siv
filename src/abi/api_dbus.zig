//! The D-Bus part of the API schema (D19): connections to the session
//! bus, the system bus, or any address on the application's loop; method
//! calls with replies and errors; signals and match rules; bus name
//! ownership and watching; and exported objects with methods,
//! properties, and signals. Messages are written and read value by value
//! with the D-Bus type codes, so every binding reads and writes any
//! signature. api.zig appends these declarations and functions to its
//! own; the conventions are schema.zig's. Implemented in dbus.zig.

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

/// Cannot fail: a failure is recorded on the message (siv_dbus_message_status).
fn op(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc, .since = v0_1, .params = params };
}

fn teardown(comptime name: []const u8, comptime doc: []const u8, comptime params: []const Param) Function {
    return .{ .name = name, .doc = doc ++ " A stale handle does nothing.", .since = v0_1, .params = params };
}

fn p(comptime name: []const u8, comptime t: schema.Type, comptime doc: []const u8) Param {
    return .{ .name = name, .type = t, .doc = doc };
}

fn reserved(comptime name: []const u8) schema.Field {
    return .{ .name = name, .type = .u32, .doc = "Reserved; must be zero (SIV_ERROR_UNSUPPORTED otherwise).", .reserved = true };
}

const dbus_param = p("dbus", ref("siv_dbus"), "The connection.");
const msg_param = p("message", ref("siv_dbus_message"), "The message being written.");
const reader_param = p("reader", ref("siv_dbus_reader"), "The reader, valid during the callback it was passed to.");
const type_param = p("type", .u8, "The D-Bus type code, such as 'u' or 's'.");
const buffer_out = [_]Param{
    p("buffer", schema.text_buffer, "Receives at most buffer_cap bytes; may be NULL with buffer_cap 0."),
    p("len", out(.usize), "The full length in bytes."),
};

pub const decls = [_]Decl{
    handle("siv_dbus", "A connection to a message bus on the application's loop (D19). Valid until siv_dbus_disconnect or the application's destruction; everything made on it goes with it."),
    handle("siv_dbus_message", "An outgoing message being written: a method call, a signal, or a reply. Valid until it is sent (siv_dbus_message_call, siv_dbus_message_send) or destroyed. The message handed to a property's get callback is valid during the call."),
    handle("siv_dbus_reader", "Reads a received message's arguments, value by value: valid only during the callback it is passed to."),
    handle("siv_dbus_subscription", "Signals matching a rule, delivered to a callback. Valid until siv_dbus_subscription_destroy."),
    handle("siv_dbus_name", "A request to own a bus name. Valid until siv_dbus_name_release."),
    handle("siv_dbus_name_watch", "Follows the owner of a bus name. Valid until siv_dbus_name_watch_destroy."),
    handle("siv_dbus_object", "An exported object: one interface at one path, with methods, properties, and signals. Valid until siv_dbus_object_destroy."),
    handle("siv_dbus_invocation", "An incoming method call to answer: valid until it is answered (a reply sent with siv_dbus_message_send, or siv_dbus_invocation_reply_error), or its object or connection goes, when siv answers with an error."),
    enumeration("siv_dbus_bus", "Which bus to connect to.", &.{
        .{ .name = "session", .value = 0, .doc = "The session bus: the application's own connection, shared with portals and accessibility." },
        .{ .name = "system", .value = 1, .doc = "The system bus ($DBUS_SYSTEM_BUS_ADDRESS, else /run/dbus/system_bus_socket): a new connection." },
        .{ .name = "address", .value = 2, .doc = "A bus at the descriptor's address (unix:path=... or unix:abstract=...): a new connection." },
        .{ .name = "fd", .value = 3, .doc = "A bus over the descriptor's connected socket, which siv takes over (tests, embedders)." },
    }),
    descriptor("siv_dbus_desc", "A connection to open (siv_dbus_connect).", &.{
        .{ .name = "address", .type = .string, .doc = "SIV_DBUS_BUS_ADDRESS: the address, copied." },
        .{ .name = "bus", .type = ref("siv_dbus_bus"), .doc = "Which bus; default session." },
        .{ .name = "fd", .type = .i32, .doc = "SIV_DBUS_BUS_FD: the connected socket." },
    }),
    flags("siv_dbus_message_flags", "Header flags of a method call.", &.{
        .{ .name = "no_reply", .bit = 0, .doc = "No reply is wanted (siv_dbus_message_send only)." },
        .{ .name = "no_auto_start", .bit = 1, .doc = "Do not start the destination by D-Bus activation." },
        .{ .name = "interactive", .bit = 2, .doc = "The caller may be asked for authorization (polkit)." },
        .{ .name = "secret", .bit = 3, .doc = "The arguments hold a secret, such as a passphrase: siv wipes every copy of the message it made once the message is sent or dropped, and does not reuse its memory." },
    }),
    descriptor("siv_dbus_message_desc", "A method call (siv_dbus_new_call) or a signal (siv_dbus_new_signal).", &.{
        .{ .name = "destination", .type = .string, .doc = "The bus name it goes to; required for calls on a bus, optional for signals (broadcast without)." },
        .{ .name = "path", .type = .string, .doc = "The object path." },
        .{ .name = "interface", .type = .string, .doc = "The interface; required for signals, optional for calls." },
        .{ .name = "member", .type = .string, .doc = "The method or signal name." },
        .{ .name = "flags", .type = ref("siv_dbus_message_flags"), .doc = "Calls: header flags." },
        reserved("reserved0"),
    }),
    enumeration("siv_dbus_message_type", "What a received message is.", &.{
        .{ .name = "method_call", .value = 0, .doc = "A method call to an exported object." },
        .{ .name = "method_return", .value = 1, .doc = "A call's reply." },
        .{ .name = "error", .value = 2, .doc = "A call's error reply: error_name says which, and the reader holds its arguments (usually a message string)." },
        .{ .name = "signal", .value = 3, .doc = "A signal." },
        .{ .name = "failed", .value = 4, .doc = "No reply will come: the call timed out (error_name org.freedesktop.DBus.Error.NoReply) or the connection went away (org.freedesktop.DBus.Error.Disconnected)." },
    }),
    descriptor("siv_dbus_message_info", "A received message's header. Filled by siv; strings are valid during the call and empty when absent.", &.{
        .{ .name = "sender", .type = .string, .doc = "The sender's unique name." },
        .{ .name = "path", .type = .string, .doc = "Calls and signals: the object path." },
        .{ .name = "interface", .type = .string, .doc = "Calls and signals: the interface." },
        .{ .name = "member", .type = .string, .doc = "Calls and signals: the member." },
        .{ .name = "error_name", .type = .string, .doc = "Errors and failures: the error's name." },
        .{ .name = "signature", .type = .string, .doc = "The signature of the arguments." },
        .{ .name = "type", .type = ref("siv_dbus_message_type"), .doc = "What the message is." },
        .{ .name = "serial", .type = .u32, .doc = "The message's serial." },
    }),
    callback("siv_dbus_message_fn", "Receives a call's reply, or a signal, at a safe point on the application's thread (D5).", &.{
        p("info", .{ .desc = "siv_dbus_message_info" }, "The message's header, valid during the call."),
        p("reader", ref("siv_dbus_reader"), "Reads its arguments, valid during the call."),
    }, .void),
    descriptor("siv_dbus_match", "Which signals a subscription gets: every field given must match; empty fields match anything.", &.{
        .{ .name = "sender", .type = .string, .doc = "The sender: a unique name, or a well-known name whose owner siv follows." },
        .{ .name = "path", .type = .string, .doc = "The object path." },
        .{ .name = "path_namespace", .type = .string, .doc = "The object path or any path below it." },
        .{ .name = "interface", .type = .string, .doc = "The interface." },
        .{ .name = "member", .type = .string, .doc = "The signal's name." },
        .{ .name = "arg0", .type = .string, .doc = "The first argument, a string." },
    }),
    flags("siv_dbus_name_flags", "How to ask for a bus name.", &.{
        .{ .name = "allow_replacement", .bit = 0, .doc = "Let another connection that asks with replace_existing take it." },
        .{ .name = "replace_existing", .bit = 1, .doc = "Take it from an owner that allows replacement." },
        .{ .name = "do_not_queue", .bit = 2, .doc = "Fail (state exists) instead of waiting in the bus's queue." },
    }),
    enumeration("siv_dbus_name_state", "Where a name request stands.", &.{
        .{ .name = "primary", .value = 0, .doc = "This connection owns the name." },
        .{ .name = "queued", .value = 1, .doc = "Waiting in the bus's queue for the name." },
        .{ .name = "exists", .value = 2, .doc = "Another connection owns it and the request did not queue." },
        .{ .name = "lost", .value = 3, .doc = "Another connection took it over." },
        .{ .name = "failed", .value = 4, .doc = "The bus refused the request, or the connection went away." },
    }),
    callback("siv_dbus_name_fn", "Reports a name request's state at a safe point, when it changes.", &.{
        p("name", ref("siv_dbus_name"), "The request."),
        p("state", ref("siv_dbus_name_state"), "Its state."),
    }, .void),
    callback("siv_dbus_name_watch_fn", "Reports a watched name's owner at a safe point: once known, and when it changes.", &.{
        p("watch", ref("siv_dbus_name_watch"), "The watch."),
        p("owner", .string, "The owner's unique name, valid during the call; empty when nobody owns it."),
    }, .void),
    enumeration("siv_dbus_access", "Who may read and write an exported property.", &.{
        .{ .name = "read", .value = 0, .doc = "Read only." },
        .{ .name = "write", .value = 1, .doc = "Write only." },
        .{ .name = "readwrite", .value = 2, .doc = "Read and write." },
    }),
    value("siv_dbus_method", "A method of an exported interface.", &.{
        .{ .name = "name", .type = .string, .doc = "The method's name." },
        .{ .name = "in_signature", .type = .string, .doc = "Its arguments' signature; calls with others get InvalidArgs without reaching the application." },
        .{ .name = "out_signature", .type = .string, .doc = "Its reply's signature; replies with another become errors." },
    }),
    value("siv_dbus_property", "A property of an exported interface.", &.{
        .{ .name = "name", .type = .string, .doc = "The property's name." },
        .{ .name = "signature", .type = .string, .doc = "Its type, a single complete type." },
        .{ .name = "access", .type = ref("siv_dbus_access"), .doc = "Who may read and write it." },
        reserved("reserved0"),
    }),
    value("siv_dbus_signal", "A signal of an exported interface, for introspection.", &.{
        .{ .name = "name", .type = .string, .doc = "The signal's name." },
        .{ .name = "signature", .type = .string, .doc = "Its arguments' signature." },
    }),
    callback("siv_dbus_method_call_fn", "Handles a call to an exported object's method at a safe point. Answer the invocation now or later: a reply from siv_dbus_invocation_new_reply sent with siv_dbus_message_send, or siv_dbus_invocation_reply_error.", &.{
        p("info", .{ .desc = "siv_dbus_message_info" }, "The call's header, valid during the call."),
        p("args", ref("siv_dbus_reader"), "Reads its arguments, valid during the call."),
        p("invocation", ref("siv_dbus_invocation"), "The call to answer."),
    }, .void),
    callback("siv_dbus_get_property_fn", "Writes a property's value (not wrapped in a variant) for a Get, a GetAll, or a PropertiesChanged signal, at a safe point.", &.{
        p("name", .string, "The property, valid during the call."),
        p("message", ref("siv_dbus_message"), "Where to write the value, valid during the call."),
    }, result_ref),
    callback("siv_dbus_set_property_fn", "Takes a new value for a property from a Set, at a safe point; a failure becomes an error reply.", &.{
        p("name", .string, "The property, valid during the call."),
        p("value", ref("siv_dbus_reader"), "Reads the value (inside its variant), valid during the call."),
    }, result_ref),
    descriptor("siv_dbus_object_desc", "An object to export (siv_dbus_export): one interface at a path. Introspection, Properties (Get, GetAll, Set, and PropertiesChanged), and Peer come with it.", &.{
        .{ .name = "path", .type = .string, .doc = "The object path, copied." },
        .{ .name = "interface", .type = .string, .doc = "The interface's name, copied." },
        .{ .name = "methods", .type = array(ref("siv_dbus_method")), .doc = "Its methods, copied." },
        .{ .name = "properties", .type = array(ref("siv_dbus_property")), .doc = "Its properties, copied." },
        .{ .name = "signals", .type = array(ref("siv_dbus_signal")), .doc = "Its signals, copied, for introspection; emit them with siv_dbus_new_signal." },
        .{ .name = "user_data", .type = .user_data, .doc = "Passed to the callbacks and destroy." },
        .{ .name = "on_call", .type = ref("siv_dbus_method_call_fn"), .doc = "Handles method calls; NULL answers each with an error." },
        .{ .name = "get_property", .type = ref("siv_dbus_get_property_fn"), .doc = "Reads properties; needed for readable ones." },
        .{ .name = "set_property", .type = ref("siv_dbus_set_property_fn"), .doc = "Writes properties; needed for writable ones." },
        .{ .name = "destroy", .type = ref("siv_destroy_fn"), .doc = "Releases user_data when the object goes." },
    }),
};

pub const functions = [_]Function{
    call("siv_dbus_connect", "Connects to a bus on the application's loop (D19). The session bus is the application's own connection; the others are new ones. Fails with SIV_ERROR_UNAVAILABLE without such a bus (the headless backend has no session bus). Calls made before the bus answered Hello wait for it.", &.{
        p("app", ref("siv_app"), "The application."),
        p("desc", .{ .desc = "siv_dbus_desc" }, "The bus; NULL for the session bus."),
        p("dbus", out(ref("siv_dbus")), "The connection."),
    }),
    teardown("siv_dbus_disconnect", "Closes the connection (the session bus's only for this handle): its subscriptions, names, watches, and objects go, unsent messages are dropped, pending calls are forgotten, and every destroy-notify runs.", &.{dbus_param}),
    call("siv_dbus_get_unique_name", "Copies the connection's unique name (\":1.42\"); empty until the bus answered Hello.", &([_]Param{dbus_param} ++ buffer_out)),

    call("siv_dbus_new_call", "Starts writing a method call; write its arguments, then send it with siv_dbus_message_call or siv_dbus_message_send.", &.{
        dbus_param,
        p("desc", .{ .desc = "siv_dbus_message_desc" }, "Where it goes."),
        p("message", out(ref("siv_dbus_message")), "The message."),
    }),
    call("siv_dbus_new_signal", "Starts writing a signal; write its arguments, then send it with siv_dbus_message_send.", &.{
        dbus_param,
        p("desc", .{ .desc = "siv_dbus_message_desc" }, "The signal: path, interface, member, and an optional destination."),
        p("message", out(ref("siv_dbus_message")), "The message."),
    }),
    call("siv_dbus_invocation_new_reply", "Starts writing the reply to an invocation; send it with siv_dbus_message_send, which answers the invocation. Its signature must be the method's out_signature.", &.{
        p("invocation", ref("siv_dbus_invocation"), "The call to answer."),
        p("message", out(ref("siv_dbus_message")), "The reply."),
    }),
    teardown("siv_dbus_message_destroy", "Drops a message without sending it.", &.{msg_param}),
    op("siv_dbus_message_write_int", "Appends an integer of a basic type: y, n, q, i, u, x, t (the value's 64 bits), b (0 or 1), or h (a file descriptor, duplicated). A value out of the type's range, or a type the signature being written does not expect there, fails the message.", &.{ msg_param, type_param, p("value", .i64, "The value.") }),
    op("siv_dbus_message_write_double", "Appends a double (type d).", &.{ msg_param, p("value", .f64, "The value.") }),
    op("siv_dbus_message_write_string", "Appends a string (s), an object path (o), or a signature (g); invalid paths, signatures, and UTF-8 fail the message.", &.{ msg_param, type_param, p("value", .string, "The value, copied.") }),
    op("siv_dbus_message_write_open", "Opens a container: an array (a) of elements of the given signature, a variant (v) holding a value of the given signature, a struct (r), or a dictionary entry (e, inside an array of them). Close it with siv_dbus_message_write_close.", &.{ msg_param, type_param, p("signature", .string, "Arrays: the element type. Variants: the value's type. Structs and dictionary entries: empty.") }),
    op("siv_dbus_message_write_close", "Closes the container opened last.", &.{msg_param}),
    call("siv_dbus_message_status", "The first failure of the writes so far, or SIV_OK.", &.{msg_param}),
    call("siv_dbus_message_call", "Sends a method call and consumes the message, whatever the result. The callback runs once, at a safe point after this returns: with the reply, an error reply, or a failure (timeout, disconnection). A message whose writes failed, or with a container left open, fails here and runs destroy.", &.{
        msg_param,
        p("timeout_ms", .i32, "How long to wait for the reply: 0 is 25 s, -1 forever."),
        p("callback", ref("siv_dbus_message_fn"), "Receives the outcome."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data after the callback ran or the call was forgotten; may be NULL."),
        p("user_data", .user_data, "Passed to both."),
    }),
    call("siv_dbus_message_send", "Sends a signal, a reply (answering its invocation), or a method call without waiting for a reply, and consumes the message whatever the result.", &.{msg_param}),

    call("siv_dbus_reader_read_type", "The type code of the next value ('i', 's', 'a', '(', '{', 'v', ...), or 0 at the end of the arguments or of the container entered last.", &.{ reader_param, p("type", out(.u8), "The type code, or 0.") }),
    call("siv_dbus_reader_read_signature", "Copies the signature of the next complete value (\"a{sv}\"); empty at the end.", &([_]Param{reader_param} ++ buffer_out)),
    call("siv_dbus_reader_read_int", "Reads an integer of a basic type: y, n, q, i, u, x, t (as its 64 bits), b, or h (a file descriptor owned by the message: duplicate it to keep it). SIV_ERROR_INVALID_ARGUMENT if the next value is of another type.", &.{ reader_param, p("value", out(.i64), "The value.") }),
    call("siv_dbus_reader_read_double", "Reads a double.", &.{ reader_param, p("value", out(.f64), "The value.") }),
    call("siv_dbus_reader_read_string", "Reads a string, an object path, or a signature. If it is longer than buffer_cap, nothing is read and len says how much room it needs.", &([_]Param{reader_param} ++ buffer_out)),
    call("siv_dbus_reader_read_enter", "Enters the array, struct, dictionary entry, or variant at the cursor: reads then go through its contents, and siv_dbus_reader_read_type reports 0 at its end.", &.{reader_param}),
    call("siv_dbus_reader_read_exit", "Leaves the container entered last, skipping what was not read.", &.{reader_param}),
    call("siv_dbus_reader_read_skip", "Skips the next complete value.", &.{reader_param}),

    call("siv_dbus_subscribe", "Delivers signals that match to callback, at safe points. On a bus the rule is also sent to it (AddMatch).", &.{
        dbus_param,
        p("match", .{ .desc = "siv_dbus_match" }, "Which signals; copied."),
        p("callback", ref("siv_dbus_message_fn"), "Receives each signal."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data when the subscription goes; may be NULL."),
        p("user_data", .user_data, "Passed to both."),
        p("subscription", out(ref("siv_dbus_subscription")), "The subscription."),
    }),
    teardown("siv_dbus_subscription_destroy", "Stops the subscription (RemoveMatch) and runs its destroy-notify.", &.{p("subscription", ref("siv_dbus_subscription"), "The subscription.")}),
    call("siv_dbus_own_name", "Asks the bus for a well-known name; callback reports the outcome and later changes (lost to a replacement). Owning a name is how a service becomes reachable, such as org.freedesktop.FileManager1.", &.{
        dbus_param,
        p("name", .string, "The name, copied."),
        p("flags", ref("siv_dbus_name_flags"), "How to ask."),
        p("callback", ref("siv_dbus_name_fn"), "Receives the state; may be NULL."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data when the request goes; may be NULL."),
        p("user_data", .user_data, "Passed to both."),
        p("request", out(ref("siv_dbus_name")), "The request."),
    }),
    teardown("siv_dbus_name_release", "Gives the name up, or leaves the queue, and runs the destroy-notify.", &.{p("request", ref("siv_dbus_name"), "The request.")}),
    call("siv_dbus_watch_name", "Follows who owns a bus name: callback reports the owner once it is known and whenever it changes.", &.{
        dbus_param,
        p("name", .string, "The name, copied."),
        p("callback", ref("siv_dbus_name_watch_fn"), "Receives the owner."),
        p("destroy", ref("siv_destroy_fn"), "Releases user_data when the watch goes; may be NULL."),
        p("user_data", .user_data, "Passed to both."),
        p("watch", out(ref("siv_dbus_name_watch")), "The watch."),
    }),
    teardown("siv_dbus_name_watch_destroy", "Stops watching and runs the destroy-notify.", &.{p("watch", ref("siv_dbus_name_watch"), "The watch.")}),
    call("siv_dbus_export", "Exports an object: calls to its methods reach on_call, Properties calls get_property and set_property, and it shows in introspection. SIV_ERROR_BUSY if the connection exports an object at that path already.", &.{
        dbus_param,
        p("desc", .{ .desc = "siv_dbus_object_desc" }, "The object."),
        p("object", out(ref("siv_dbus_object")), "The object."),
    }),
    teardown("siv_dbus_object_destroy", "Stops exporting the object, answers its pending invocations with an error, and runs its destroy-notify.", &.{p("object", ref("siv_dbus_object"), "The object.")}),
    call("siv_dbus_object_emit_properties_changed", "Emits PropertiesChanged for a property of the object, with its value from get_property.", &.{
        p("object", ref("siv_dbus_object"), "The object."),
        p("name", .string, "The property."),
    }),
    call("siv_dbus_invocation_reply_error", "Answers an invocation with an error.", &.{
        p("invocation", ref("siv_dbus_invocation"), "The call to answer."),
        p("name", .string, "The error's name, such as org.freedesktop.DBus.Error.Failed."),
        p("message", .string, "A message for people."),
    }),
};
