//! The undo part of the API schema (D35): undo stacks an application
//! pushes its own steps onto, attached to nodes so that Ctrl+Z,
//! Ctrl+Shift+Z, and Ctrl+Y reach them. api.zig appends these
//! declarations and functions to its own; the conventions are
//! schema.zig's. Implemented in undo.zig.

const schema = @import("schema.zig");
const ref = schema.ref;
const out = schema.out;
const Decl = schema.Decl;
const Param = schema.Param;
const Function = schema.Function;

const v0_1: schema.Version = .{ .major = 0, .minor = 1 };

fn handle(comptime name: []const u8, comptime doc: []const u8) Decl {
    return .{ .handle = .{ .name = name, .doc = doc, .since = v0_1 } };
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
    return .{ .name = name, .doc = doc, .since = v0_1, .params = &([_]Param{undo_param} ++ params[0..params.len].*), .ret = ref("siv_result") };
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

const undo_param = p("undo", ref("siv_undo"), "The undo stack.");
const busy = " SIV_ERROR_BUSY from a callback of this stack (a step's undo or redo, or on_change)";
const busy_group = busy ++ ", or while a group is open (siv_undo_begin_group).";

pub const decls = [_]Decl{
    handle("siv_undo", "An undo stack (D35): steps the application pushed, the position between those done and those undone, and a clean mark. It belongs to the application, not to a window: attach it to nodes with siv_set_undo so that the undo keys reach it, to the window's root for the whole window or to a tab's content for one document, and to nodes of several windows that show one document. Valid until siv_undo_destroy or the application goes."),
    callback("siv_undo_step_fn", "Undoes or redoes one step's change, at a safe point on the application's thread (D5). It may change anything, the tree included, except this stack: its calls fail with SIV_ERROR_BUSY until the callback returns.", &.{
        p("undo", ref("siv_undo"), "The stack."),
    }),
    descriptor("siv_undo_step_desc", "A step for siv_undo_push: a change the application has already made, and how to take it back and make it again.", &.{
        f("user_data", .user_data, "Passed to undo and redo, and released by destroy when the step is dropped: when the stack is cleared or destroyed, when pushing drops it from the redo list or past the limit, or when it merges into the step before it."),
        f("undo", ref("siv_undo_step_fn"), "Takes the change back. Required."),
        f("redo", ref("siv_undo_step_fn"), "Makes the change again after an undo. Required."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data exactly once. A step that merged into the one before keeps the earlier step's user_data for undo and its own for redo, so both stay until the merged step is dropped."),
        f("label", .string, "What the step did, for \"Undo Rename\" and \"Redo Rename\" (\"Rename\"), copied; may be empty."),
        f("merge", .u64, "Nonzero: merges into the last step when that one has the same key, so a run of changes undoes as one (a slider's drag, typing into a field of a form). The merged step keeps the earlier step's undo, which goes back before the run, and takes this step's redo and label. It does not merge into a step that is the clean state (siv_undo_set_clean), into a group, or out of one: inside a group it merges with the group's last step. 0 never merges; use a new key to start a new run (each drag its own)."),
    }),
    flags("siv_undo_event_flags", "States of an undo stack in a siv_undo_event.", &.{
        .{ .name = "clean", .bit = 0, .doc = "The stack is at the position siv_undo_set_clean marked (\"saved\"), as siv_undo_is_clean tells. Without the flag the document is modified." },
    }),
    descriptor("siv_undo_event", "What an undo stack can do after it changed, for siv_undo_desc.on_change. Filled by siv; strings are valid during the call.", &.{
        f("undo_label", .string, "The label of the step undo would take back (siv_undo_get_label); empty when there is none or it has no label."),
        f("redo_label", .string, "The label of the step redo would make again; empty when there is none or it has no label."),
        f("flags", ref("siv_undo_event_flags"), "States."),
        f("undo_count", .u32, "Steps that can be undone (siv_undo_get_count): nonzero when undo does something, \"can undo\"."),
        f("redo_count", .u32, "Steps that can be redone: nonzero when redo does something, \"can redo\"."),
        reserved("reserved0"),
    }),
    callback("siv_undo_change_fn", "Tells that an undo stack changed, at a safe point on the application's thread (D5): once per loop iteration after any number of changes, so buttons, menu items, and actions follow whether undo and redo do something, their labels, and the clean state. It may query the stack and destroy it, but calls that change it fail with SIV_ERROR_BUSY.", &.{
        p("undo", ref("siv_undo"), "The stack."),
        p("event", .{ .desc = "siv_undo_event" }, "What it can do now, valid during the call."),
    }),
    descriptor("siv_undo_desc", "Options for siv_undo_create.", &.{
        f("user_data", .user_data, "Passed to on_change and destroy."),
        f("on_change", ref("siv_undo_change_fn"), "Follows the stack's state; may be NULL."),
        f("destroy", ref("siv_destroy_fn"), "Releases user_data when the stack is destroyed."),
        f("limit", .u32, "Most steps kept: pushing past it drops the oldest (a group counts once). 0 keeps every step."),
        reserved("reserved0"),
    }),
};

pub const functions = [_]Function{
    .{ .name = "siv_undo_create", .doc = "Creates an empty undo stack. It does nothing until the application pushes steps and calls siv_undo_undo, or attaches it to nodes for the keys (siv_set_undo). On failure, desc's destroy runs at once.", .since = v0_1, .ret = ref("siv_result"), .params = &.{
        p("app", ref("siv_app"), "The application."),
        p("desc", .{ .desc = "siv_undo_desc" }, "Options; NULL for defaults."),
        p("undo", out(ref("siv_undo")), "Receives the stack."),
    } },
    .{ .name = "siv_undo_destroy", .doc = "Destroys an undo stack: every step's destroy-notify runs, then the stack's; nodes it was attached to no longer reach it. From one of its callbacks, the stack goes when the callback returns. A stale handle does nothing.", .since = v0_1, .params = &.{undo_param} },
    call("siv_undo_push", "Records a change the application has just made as the newest step, done: the steps undone before it can no longer be redone and are dropped, and the oldest is dropped past the limit. Inside a group the step joins the group. On failure the step's destroy runs at once." ++ busy ++ "; SIV_ERROR_INVALID_ARGUMENT without undo and redo.", &.{
        p("desc", .{ .desc = "siv_undo_step_desc" }, "The step."),
    }),
    call("siv_undo_undo", "Undoes the newest step that is done: calls its undo (a group's steps' undo, newest first), which can then be redone. Does nothing when nothing can be undone. Ctrl+Z calls it for a stack attached to the focused node or an ancestor (siv_set_undo)." ++ busy_group, &.{}),
    call("siv_undo_redo", "Redoes the oldest step that was undone: calls its redo (a group's steps' redo, oldest first). Does nothing when nothing can be redone. Ctrl+Shift+Z and Ctrl+Y call it like Ctrl+Z calls siv_undo_undo." ++ busy_group, &.{}),
    call("siv_undo_begin_group", "Opens a group: the steps pushed until siv_undo_end_group become one step, undone and redone together, as one command that changes several things (moving ten files). Groups nest; an inner group joins the outer one and its label is not used." ++ busy ++ ".", &.{
        p("label", .string, "The group's label, copied; may be empty."),
    }),
    call("siv_undo_end_group", "Closes the group siv_undo_begin_group opened. When the outermost group closes with steps in it, they become one step; with none, nothing changes." ++ busy ++ "; SIV_ERROR_INVALID_ARGUMENT when no group is open.", &.{}),
    call("siv_undo_set_clean", "Marks the current position clean, as when the document is saved: the clean flag holds here and after undoing and redoing back to it, and is lost for good when the step it follows is dropped (past the limit, or from the redo list by a push) until it is marked again." ++ busy_group, &.{}),
    call("siv_undo_clear", "Drops every step, running their destroy-notifies, as when the application loads another document. The stack stays clean if it was; otherwise it is not clean until siv_undo_set_clean." ++ busy_group, &.{}),
    call("siv_undo_get_count", "How many steps can be undone, or redone: nonzero when siv_undo_undo (siv_undo_redo) does something, for a button's or menu item's enabled state. A group counts once, and an open group's steps not yet.", &.{
        p("redo", .bool, "Count the steps that can be redone rather than undone."),
        p("count", out(.u32), "Receives the count."),
    }),
    call("siv_undo_is_clean", "Whether the stack is at the position siv_undo_set_clean marked: every step since was undone, or every step undone since redone, and no open group has steps in it. A document whose stack is not clean is modified.", &.{
        p("clean", out(.bool), "Receives whether it is clean."),
    }),
    call("siv_undo_get_label", "Copies the label of the step undo would take back, or redo would make again: \"Rename\" for an \"Undo Rename\" menu item. Empty when there is no such step.", &.{
        p("redo", .bool, "The redo label rather than the undo label."),
        p("label", schema.text_buffer, "Receives at most label_cap bytes; may be NULL with label_cap 0."),
        p("len", out(.usize), "The label's full length."),
    }),
    .{ .name = "siv_set_undo", .doc = "Attaches an undo stack to a node, or with 0 detaches it. Ctrl+Z, Ctrl+Shift+Z, and Ctrl+Y that no handler prevented and no editor took (D35) undo or redo the stack attached nearest the focused node, at or above it (the window's root when nothing has focus), but not above the active modal node. A focused editor keeps the keys for its own history (D15), unless it has SIV_EDITOR_NO_UNDO. A node has one stack; several nodes, in several windows, may share one. A failure is the transaction's (see siv_txn_commit).", .since = v0_1, .params = &.{
        p("txn", ref("siv_txn"), "An open transaction."),
        p("node", ref("siv_node"), "A node of the transaction's window."),
        p("undo", ref("siv_undo"), "A stack of the window's application, or 0."),
    } },
};
