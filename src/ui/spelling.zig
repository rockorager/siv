//! Spell checking in editors (D37): the application's dictionaries and
//! word lists (`Spelling`, which its windows share), and each window's
//! check-as-you-type state, brought up to date at the start of every
//! frame (`update`) before layout and paint.
//!
//! An editor with spell checking on keeps the text it last checked (a
//! retained rope, D15) and its misspelled words as sorted byte ranges.
//! Each frame diffs the editor's text against it: misspellings before the
//! change stay, those after it move, those it touches go, and the change
//! widened to whitespace on both sides is dirty. Dirty text up to
//! `sync_bytes` is checked in the frame, on the UI thread (a keystroke
//! checks a word or two); more, such as a document just loaded, goes to
//! the worker pool in chunks (D6), whose results are moved through the
//! edits made meanwhile when they arrive. Word boundaries are the text
//! engine's (UAX #29, D13).
//!
//! While the user types a word it is not marked: a misspelled word whose
//! end is the caret of the focused editor, found by a check that a text
//! change caused, is held back until the caret leaves it.
//!
//! Dictionaries are the system's Hunspell dictionaries (spell.files),
//! read on the pool's blocking lane when an editor first needs one, and
//! those the application adds. Words added to the personal dictionary go
//! to Enchant's file for the dictionary, so GNOME applications and siv
//! share them; ignored words last for the run.

const std = @import("std");
const spell = @import("spell");
const text = @import("text");
const loop = @import("loop");
const Window = @import("Window.zig");
const node_mod = @import("node.zig");

const Allocator = std.mem.Allocator;
const NodeId = node_mod.NodeId;
const Pool = loop.Pool;
const Rope = text.Rope;

const Spelling = @This();

/// Dirty text up to this many bytes is checked on the UI thread in the
/// frame; a word in German costs about 15 µs, so this is under 2 ms.
const sync_bytes = 512;
/// Text a checking job takes, and without a pool what a frame checks.
const chunk_bytes = 32 << 10;
/// Checking jobs in flight per editor.
const max_jobs = 8;
/// How far a change widens on each side to find whitespace; a longer
/// token is not a word, and its cut ends are not checked.
const max_snap = 256;
const none: u32 = std.math.maxInt(u32);
/// A language waiting for the system's dictionaries to be listed.
const waiting: u32 = none - 1;
/// The language of editors that name none in a window that has none.
pub const default_language = "en";
/// spell's dictionary for tests, for modules that do not import it.
pub const test_dictionary = spell.test_dictionary;

gpa: Allocator,
/// Where loads and checks run; without one they run on the UI thread.
pool: ?*Pool = null,
/// Directories searched for dictionaries; empty without system ones.
dirs: [][]u8 = &.{},
/// Enchant's directory for personal word lists; null keeps added words
/// in memory only (the headless backend).
personal_dir: ?[]u8 = null,
/// The system's dictionary names once listed.
names: ?[][]u8 = null,
langs: std.ArrayList(*Lang) = .empty,
/// Languages asked for (as given) and the dictionary each resolved to:
/// an index into `langs`, `none`, or `waiting`.
tags: std.StringHashMapUnmanaged(u32) = .empty,
loads: std.ArrayList(*Load) = .empty,
checks: std.ArrayList(*Check) = .empty,
/// Tells the owner a dictionary or word list changed, so that windows
/// check again: it requests frames.
notify: ?Notify = null,
/// Makes each editor state's checks distinct from those of an earlier
/// state, so late results of either are dropped.
generations: u32 = 0,

pub const Notify = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque) void,
};

/// A parsed dictionary, shared with the checking jobs that use it and
/// freed with the last reference (counted on the UI thread).
pub const Dict = struct {
    gpa: Allocator,
    dictionary: spell.Dictionary,
    /// Enchant's exclusions (<name>.exc): words wrong though the
    /// dictionary has them. Fixed once loaded, so jobs read it.
    excluded: spell.WordList = .{},
    refs: u32 = 1,

    fn create(gpa: Allocator, dictionary: spell.Dictionary, excluded: ?[]const u8) Allocator.Error!*Dict {
        const d = try gpa.create(Dict);
        d.* = .{ .gpa = gpa, .dictionary = dictionary };
        if (excluded) |bytes| d.excluded.parse(gpa, bytes) catch |err| {
            d.excluded.deinit(gpa);
            gpa.destroy(d);
            return err;
        };
        return d;
    }

    fn ref(d: *Dict) *Dict {
        d.refs += 1;
        return d;
    }

    fn unref(d: *Dict) void {
        d.refs -= 1;
        if (d.refs != 0) return;
        d.dictionary.deinit();
        d.excluded.deinit(d.gpa);
        d.gpa.destroy(d);
    }

    /// Any thread.
    pub fn check(d: *const Dict, word: []const u8) bool {
        if (d.excluded.contains(word)) return false;
        return d.dictionary.check(word);
    }
};

/// A dictionary by name, with the words the user added to it or ignored.
pub const Lang = struct {
    name: []u8,
    /// Null while loading, or when it failed to load.
    dict: ?*Dict = null,
    loading: bool = false,
    /// The application added it (`addDictionary`).
    added: bool = false,
    personal: spell.WordList = .{},
    ignored: spell.WordList = .{},
    /// Count changes of `dict` and of the word lists.
    dict_serial: u32 = 0,
    list_serial: u32 = 0,

    /// Whether a word is right by the user's word lists.
    pub fn accepts(l: *const Lang, word: []const u8) bool {
        return l.personal.contains(word) or l.ignored.contains(word);
    }

    /// Whether a word is right: not excluded, and in a word list or the
    /// dictionary. A missing dictionary accepts everything.
    pub fn check(l: *const Lang, word: []const u8) bool {
        const d = l.dict orelse return true;
        if (d.excluded.contains(word)) return false;
        return l.accepts(word) or d.dictionary.check(word);
    }
};

pub const Options = struct {
    pool: ?*Pool = null,
    /// Read the system's dictionaries and Enchant's personal word lists,
    /// found through `env` (null: the process's environment); off, only
    /// added dictionaries exist and added words are not saved.
    system: bool = true,
    env: ?spell.files.Environment = null,
};

pub fn init(gpa: Allocator, options: Options) Allocator.Error!Spelling {
    var s: Spelling = .{ .gpa = gpa, .pool = options.pool };
    errdefer s.deinit();
    if (options.system) {
        const env = options.env orelse spell.files.Environment.current();
        s.dirs = try spell.files.searchDirs(gpa, env);
        s.personal_dir = try spell.files.personalDir(gpa, env);
    } else s.names = try gpa.alloc([]u8, 0);
    return s;
}

/// Loads and checks still in flight finish without touching this object.
pub fn deinit(s: *Spelling) void {
    for (s.loads.items) |load| {
        if (s.pool) |pool| if (pool.cancel(&load.job)) {
            load.destroy();
            continue;
        };
        load.spelling = null;
    }
    s.loads.deinit(s.gpa);
    for (s.checks.items) |c| c.spelling = null;
    s.checks.deinit(s.gpa);
    for (s.langs.items) |l| {
        if (l.dict) |d| d.unref();
        l.personal.deinit(s.gpa);
        l.ignored.deinit(s.gpa);
        s.gpa.free(l.name);
        s.gpa.destroy(l);
    }
    s.langs.deinit(s.gpa);
    var it = s.tags.keyIterator();
    while (it.next()) |k| s.gpa.free(k.*);
    s.tags.deinit(s.gpa);
    freeNames(s.gpa, s.dirs);
    if (s.names) |n| freeNames(s.gpa, n);
    if (s.personal_dir) |p| s.gpa.free(p);
    s.* = undefined;
}

fn freeNames(gpa: Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

fn changed(s: *Spelling) void {
    if (s.notify) |n| n.func(n.ctx);
}

/// Whether a dictionary load or a check is in flight.
pub fn busy(s: *const Spelling) bool {
    return s.loads.items.len != 0 or s.checks.items.len != 0;
}

// Languages ------------------------------------------------------------------

/// The dictionary for a language (a BCP 47 tag or locale name), as an
/// index into `langs`; its `dict` is null while it loads. Null when no
/// dictionary is for it, or until the system's are listed. Starts
/// listing and loading on the pool as needed.
pub fn langFor(s: *Spelling, tag: []const u8) ?u32 {
    const v = s.tags.get(tag) orelse blk: {
        const r = s.resolve(tag) catch return null;
        const key = s.gpa.dupe(u8, tag) catch return null;
        s.tags.put(s.gpa, key, r) catch {
            s.gpa.free(key);
            return null;
        };
        break :blk r;
    };
    return if (v >= waiting) null else v;
}

/// The loaded dictionary for a language, loading it on this thread if it
/// is not loaded yet (for the application's own checks, which return a
/// result). Null when there is none.
pub fn langNow(s: *Spelling, tag: []const u8) Allocator.Error!?*Lang {
    if (s.names == null) {
        s.names = try spell.files.listDictionaries(s.gpa, s.dirs);
        try s.namesKnown();
    }
    const i = s.langFor(tag) orelse return null;
    const l = s.langs.items[i];
    if (l.loading) {
        var load: Load = .{ .gpa = s.gpa, .spelling = s, .name = l.name, .dirs = s.dirs, .personal_dir = s.personal_dir };
        defer load.freeResults();
        load.work();
        try s.install(l, &load);
    }
    return if (l.dict != null) l else null;
}

fn resolve(s: *Spelling, tag: []const u8) Allocator.Error!u32 {
    var buf: [64][]const u8 = undefined;
    var idx: [64]u32 = undefined;
    var n: usize = 0;
    for (s.langs.items, 0..) |l, i| if (l.added and n < buf.len) {
        buf[n] = l.name;
        idx[n] = @intCast(i);
        n += 1;
    };
    if (spell.files.pick(buf[0..n], tag)) |i| return idx[i];
    if (s.names == null) try s.list();
    const names = s.names orelse return waiting;
    const i = spell.files.pick(@ptrCast(names), tag) orelse return none;
    return s.langNamed(names[i]);
}

/// The language named `name`, loading it from the system if it is new.
fn langNamed(s: *Spelling, name: []const u8) Allocator.Error!u32 {
    for (s.langs.items, 0..) |l, i| if (std.mem.eql(u8, l.name, name)) return @intCast(i);
    const l = try s.gpa.create(Lang);
    errdefer s.gpa.destroy(l);
    l.* = .{ .name = try s.gpa.dupe(u8, name), .loading = true };
    errdefer s.gpa.free(l.name);
    try s.langs.append(s.gpa, l);
    s.submit(l.name) catch |err| {
        _ = s.langs.pop();
        return err;
    };
    return @intCast(s.langs.items.len - 1);
}

/// Lists the system's dictionaries on the pool, once.
fn list(s: *Spelling) Allocator.Error!void {
    for (s.loads.items) |load| if (load.name == null) return;
    try s.submit(null);
}

fn submit(s: *Spelling, name: ?[]const u8) Allocator.Error!void {
    const load = try s.gpa.create(Load);
    load.* = .{ .gpa = s.gpa, .spelling = s, .owned = true };
    errdefer load.destroy();
    if (name) |n| load.name = try s.gpa.dupe(u8, n);
    const dirs = try s.gpa.alloc([]u8, s.dirs.len);
    for (dirs) |*d| d.* = &.{};
    load.dirs = dirs;
    for (s.dirs, dirs) |d, *copy| copy.* = try s.gpa.dupe(u8, d);
    if (s.personal_dir) |p| load.personal_dir = try s.gpa.dupe(u8, p);
    const pool = s.pool orelse {
        try s.loads.append(s.gpa, load);
        load.work();
        Load.done(&load.job);
        return;
    };
    try s.loads.append(s.gpa, load);
    pool.submit(&load.job) catch {
        _ = s.loads.pop();
        return error.OutOfMemory;
    };
}

/// The system's names arrived: languages that waited for them resolve.
fn namesKnown(s: *Spelling) Allocator.Error!void {
    var it = s.tags.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == waiting) kv.value_ptr.* = try s.resolve(kv.key_ptr.*);
    }
}

fn install(s: *Spelling, l: *Lang, load: *Load) Allocator.Error!void {
    l.loading = false;
    if (load.dictionary) |d| {
        load.dictionary = null;
        var dict = d;
        const new = Dict.create(s.gpa, dict, load.excluded) catch |err| {
            dict.deinit();
            return err;
        };
        if (l.dict) |old| old.unref();
        l.dict = new;
        l.dict_serial +%= 1;
    }
    if (load.personal) |bytes| {
        try l.personal.parse(s.gpa, bytes);
        l.list_serial +%= 1;
    }
}

/// Reads a dictionary (or lists them) on the pool's blocking lane.
const Load = struct {
    job: Pool.Job = .{ .run = run, .done = done, .cancel = cancel, .class = .blocking },
    gpa: Allocator,
    spelling: ?*Spelling,
    /// The dictionary to read, or null to list the system's.
    name: ?[]const u8 = null,
    dirs: []const []const u8 = &.{},
    personal_dir: ?[]const u8 = null,
    /// Whether the strings above are copies this owns (a pool job's).
    owned: bool = false,
    names: ?[][]u8 = null,
    dictionary: ?spell.Dictionary = null,
    personal: ?[]u8 = null,
    excluded: ?[]u8 = null,

    fn destroy(load: *Load) void {
        load.freeResults();
        if (load.owned) {
            if (load.name) |n| load.gpa.free(n);
            for (load.dirs) |d| load.gpa.free(d);
            load.gpa.free(load.dirs);
            if (load.personal_dir) |p| load.gpa.free(p);
            load.gpa.destroy(load);
        }
    }

    fn freeResults(load: *Load) void {
        if (load.names) |n| freeNames(load.gpa, n);
        if (load.dictionary) |*d| d.deinit();
        if (load.personal) |p| load.gpa.free(p);
        if (load.excluded) |p| load.gpa.free(p);
        load.names = null;
        load.dictionary = null;
        load.personal = null;
        load.excluded = null;
    }

    fn run(job: *Pool.Job) void {
        const load: *Load = @fieldParentPtr("job", job);
        load.work();
    }

    fn work(load: *Load) void {
        const name = load.name orelse {
            load.names = spell.files.listDictionaries(load.gpa, load.dirs) catch null;
            return;
        };
        load.dictionary = spell.load(load.gpa, load.dirs, name) catch null;
        const dir = load.personal_dir orelse return;
        var buf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/{s}.dic", .{ dir, name })) |path| {
            load.personal = spell.files.readFile(load.gpa, path) catch null;
        } else |_| {}
        if (std.fmt.bufPrint(&buf, "{s}/{s}.exc", .{ dir, name })) |path| {
            load.excluded = spell.files.readFile(load.gpa, path) catch null;
        } else |_| {}
    }

    fn done(job: *Pool.Job) void {
        const load: *Load = @fieldParentPtr("job", job);
        defer load.destroy();
        const s = load.spelling orelse return;
        for (s.loads.items, 0..) |l, i| if (l == load) {
            _ = s.loads.swapRemove(i);
            break;
        };
        if (load.name) |name| {
            for (s.langs.items) |l| if (std.mem.eql(u8, l.name, name)) {
                // Loaded meanwhile on the UI thread (`langNow`), or
                // replaced by an added dictionary.
                if (l.loading) s.install(l, load) catch {};
                break;
            };
        } else if (s.names == null) {
            s.names = load.names orelse (s.gpa.alloc([]u8, 0) catch return);
            load.names = null;
            s.namesKnown() catch {};
        }
        s.changed();
    }

    fn cancel(job: *Pool.Job) void {
        const load: *Load = @fieldParentPtr("job", job);
        if (load.spelling) |s| for (s.loads.items, 0..) |l, i| if (l == load) {
            _ = s.loads.swapRemove(i);
            break;
        };
        load.destroy();
    }
};

/// Adds a dictionary from the bytes of its .aff and .dic files, parsed
/// now, under `name` ("en_US"); it takes precedence over the system's of
/// that name and is picked for languages as theirs are.
pub fn addDictionary(s: *Spelling, name: []const u8, aff: []const u8, dic: []const u8) (Allocator.Error || error{InvalidArgument})!void {
    var d = spell.Dictionary.parse(s.gpa, aff, dic) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArgument,
    };
    const dict = Dict.create(s.gpa, d, null) catch |err| {
        d.deinit();
        return err;
    };
    errdefer dict.unref();
    const i = blk: {
        for (s.langs.items, 0..) |l, i| if (std.mem.eql(u8, l.name, name)) break :blk i;
        const l = try s.gpa.create(Lang);
        errdefer s.gpa.destroy(l);
        l.* = .{ .name = try s.gpa.dupe(u8, name) };
        errdefer s.gpa.free(l.name);
        try s.langs.append(s.gpa, l);
        break :blk s.langs.items.len - 1;
    };
    const l = s.langs.items[i];
    if (l.dict) |old| old.unref();
    l.dict = dict;
    l.loading = false;
    l.added = true;
    l.dict_serial +%= 1;
    // Languages resolve again: this one may suit some better.
    var it = s.tags.keyIterator();
    while (it.next()) |k| s.gpa.free(k.*);
    s.tags.clearRetainingCapacity();
    s.changed();
}

/// Every dictionary's name: the application's and the system's, sorted.
/// Lists the system's on this thread if they are not listed yet.
pub fn dictionaryNames(s: *Spelling, gpa: Allocator) Allocator.Error![][]const u8 {
    if (s.names == null) {
        s.names = try spell.files.listDictionaries(s.gpa, s.dirs);
        try s.namesKnown();
    }
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (s.langs.items) |l| if (l.added) try out.append(gpa, l.name);
    outer: for (s.names.?) |n| {
        for (out.items) |o| if (std.mem.eql(u8, o, n)) continue :outer;
        try out.append(gpa, n);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// Adds a word to the personal dictionary of `l`, saved to Enchant's
/// file for it (on the pool's blocking lane). Editors stop marking it.
pub fn addWord(s: *Spelling, l: *Lang, word: []const u8) (Allocator.Error || error{InvalidArgument})!void {
    if (!spell.WordList.valid(std.mem.trim(u8, word, " \t\r"))) return error.InvalidArgument;
    if (!try l.personal.add(s.gpa, word)) return;
    l.list_serial +%= 1;
    s.changed();
    const dir = s.personal_dir orelse return;
    const w = try s.gpa.create(Write);
    w.* = .{ .gpa = s.gpa };
    errdefer s.gpa.destroy(w);
    w.path = try std.fmt.allocPrint(s.gpa, "{s}/{s}.dic", .{ dir, l.name });
    errdefer s.gpa.free(w.path);
    w.line = try s.gpa.dupe(u8, std.mem.trim(u8, word, " \t\r"));
    const pool = s.pool orelse {
        Write.run(&w.job);
        Write.done(&w.job);
        return;
    };
    pool.submit(&w.job) catch Write.done(&w.job);
}

/// Ignores a word in `l` for the rest of the run.
pub fn ignoreWord(s: *Spelling, l: *Lang, word: []const u8) (Allocator.Error || error{InvalidArgument})!void {
    if (!spell.WordList.valid(std.mem.trim(u8, word, " \t\r"))) return error.InvalidArgument;
    if (!try l.ignored.add(s.gpa, word)) return;
    l.list_serial +%= 1;
    s.changed();
}

/// Appends a word to a personal word list file.
const Write = struct {
    job: Pool.Job = .{ .run = run, .done = done, .cancel = done, .class = .blocking },
    gpa: Allocator,
    path: []u8 = &.{},
    line: []u8 = &.{},

    fn run(job: *Pool.Job) void {
        const w: *Write = @fieldParentPtr("job", job);
        spell.files.appendLine(w.path, w.line) catch {};
    }

    fn done(job: *Pool.Job) void {
        const w: *Write = @fieldParentPtr("job", job);
        w.gpa.free(w.path);
        w.gpa.free(w.line);
        w.gpa.destroy(w);
    }
};

/// Suggestions for a word, best first, without excluded words. Free each
/// and the list with `gpa`.
pub fn suggest(l: *const Lang, gpa: Allocator, word: []const u8) Allocator.Error![][]u8 {
    const d = l.dict orelse return gpa.alloc([]u8, 0);
    const all = d.dictionary.suggest(gpa, word) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => gpa.alloc([]u8, 0),
    };
    var n: usize = 0;
    for (all) |w| {
        if (d.excluded.contains(w)) {
            gpa.free(w);
            continue;
        }
        all[n] = w;
        n += 1;
    }
    const out = gpa.alloc([]u8, n) catch |err| {
        for (all[0..n]) |w| gpa.free(w);
        gpa.free(all);
        return err;
    };
    @memcpy(out, all[0..n]);
    gpa.free(all);
    return out;
}

// Editors --------------------------------------------------------------------

/// An editor's spell checking state.
pub const EditorState = struct {
    /// The text `misspelled` and `dirty` index.
    checked: Rope = .{},
    /// The dictionary (index into `langs`) and its serials checked with.
    lang: u32 = none,
    dict_serial: u32 = 0,
    list_serial: u32 = 0,
    /// Misspelled words: sorted, disjoint byte ranges.
    misspelled: std.ArrayList([2]u32) = .empty,
    /// Text to check: sorted, disjoint byte ranges.
    dirty: std.ArrayList([2]u32) = .empty,
    /// The misspelled word being typed, not marked yet.
    held: ?[2]u32 = null,
    generation: u32 = 0,
    in_flight: u32 = 0,

    fn deinit(st: *EditorState, gpa: Allocator) void {
        st.checked.release(gpa);
        st.misspelled.deinit(gpa);
        st.dirty.deinit(gpa);
    }
};

fn wanted(win: *const Window, id: NodeId) bool {
    if (!win.isLive(id)) return false;
    const n = win.node(id);
    return n.kind == .editor and n.data.editor.spell and !n.data.editor.editor.masked;
}

/// Brings every spell-checked editor of the window up to date with its
/// text, dictionary, and word lists. Called at the start of each frame.
pub fn update(win: *Window) Allocator.Error!void {
    const s = win.spelling orelse return;
    if (win.spell_scan) {
        win.spell_scan = false;
        for (0..win.nodes.items.len) |i| {
            const id: NodeId = @enumFromInt(i);
            if (!wanted(win, id) or win.spell.contains(id)) continue;
            const st = try win.gpa.create(EditorState);
            st.* = .{};
            win.spell.put(win.gpa, id, st) catch |err| {
                win.gpa.destroy(st);
                return err;
            };
        }
    }
    if (win.spell.count() == 0) return;
    var gone: std.ArrayList(NodeId) = .empty;
    defer gone.deinit(win.gpa);
    var it = win.spell.iterator();
    while (it.next()) |kv| {
        if (!wanted(win, kv.key_ptr.*)) {
            try gone.append(win.gpa, kv.key_ptr.*);
            continue;
        }
        try updateEditor(s, win, kv.key_ptr.*, kv.value_ptr.*);
    }
    for (gone.items) |id| {
        if (win.isLive(id)) {
            win.markPaint(id);
            win.dirty.semantics = true;
        }
        forget(win, id);
    }
}

/// The language an editor is checked in: its own, else its text's, else
/// the window's (which follows the application's, D21).
fn tagOf(win: *const Window, id: NodeId) []const u8 {
    const e = &win.node(id).data.editor;
    const i = if (e.spell_language != 0) e.spell_language else if (e.text.language != 0) e.text.language else win.language;
    const tag = win.fonts.name(i);
    return if (tag.len == 0) default_language else tag;
}

fn updateEditor(s: *Spelling, win: *Window, id: NodeId, st: *EditorState) Allocator.Error!void {
    const e = &win.node(id).data.editor;
    const content = e.text.content;
    const lang = s.langFor(tagOf(win, id)) orelse none;
    const l: ?*Lang = if (lang != none) s.langs.items[lang] else null;
    const ready = l != null and l.?.dict != null;
    if (lang != st.lang or (ready and l.?.dict_serial != st.dict_serial)) {
        // Another dictionary: the whole text again.
        if (st.misspelled.items.len != 0 or st.held != null) {
            win.markPaint(id);
            win.dirty.semantics = true;
        }
        st.misspelled.clearRetainingCapacity();
        st.dirty.clearRetainingCapacity();
        st.held = null;
        st.in_flight = 0;
        s.generations +%= 1;
        st.generation = s.generations;
        st.lang = lang;
        st.checked.release(win.gpa);
        st.checked = content.retain();
        if (ready) {
            st.dict_serial = l.?.dict_serial;
            st.list_serial = l.?.list_serial;
            if (content.len() != 0) try st.dirty.append(win.gpa, .{ 0, @intCast(content.len()) });
        }
    }
    const lg = l orelse return;
    if (!ready) return;
    if (lg.list_serial != st.list_serial) {
        // Words added or ignored are right now.
        st.list_serial = lg.list_serial;
        var n: usize = 0;
        for (st.misspelled.items) |r| {
            const word = try st.checked.slice(win.scratch.allocator(), r[0], r[1]);
            if (lg.accepts(word)) continue;
            st.misspelled.items[n] = r;
            n += 1;
        }
        if (n != st.misspelled.items.len) {
            st.misspelled.shrinkRetainingCapacity(n);
            win.markPaint(id);
            win.dirty.semantics = true;
        }
    }
    var typed = false;
    if (!st.checked.same(content)) {
        if (diff(st.checked, content)) |c| {
            try applyChange(win, id, st, c, content);
            typed = true;
        }
        const old = st.checked;
        st.checked = content.retain();
        old.release(win.gpa);
    }
    const focused = win.input.focus == id;
    if (st.held) |h| if (!focused or e.caret < h[0] or e.caret > h[1]) {
        st.held = null;
        try addDirty(win.gpa, st, h);
    };
    try process(s, win, id, st, lg, typed and focused);
}

const Change = struct { start: u32, old_end: u32, new_end: u32 };

fn diff(a: Rope, b: Rope) ?Change {
    const la: u32 = @intCast(a.len());
    const lb: u32 = @intCast(b.len());
    const pre: u32 = @intCast(Rope.commonPrefix(a, b));
    if (pre == la and pre == lb) return null;
    const suf: u32 = @intCast(@min(Rope.commonSuffix(a, b), @min(la, lb) - pre));
    return .{ .start = pre, .old_end = la - suf, .new_end = lb - suf };
}

/// A range of the old text in the new one, or null if the change touches
/// it (an edit right at a word's end may extend the word).
fn mapRange(r: [2]u32, c: Change) ?[2]u32 {
    if (r[1] < c.start) return r;
    if (r[0] > c.old_end) return .{ r[0] - c.old_end + c.new_end, r[1] - c.old_end + c.new_end };
    return null;
}

fn mapPoint(p: u32, c: Change, end: bool) u32 {
    if (p <= c.start) return p;
    if (p >= c.old_end) return p - c.old_end + c.new_end;
    return if (end) c.new_end else c.start;
}

fn applyChange(win: *Window, id: NodeId, st: *EditorState, c: Change, content: Rope) Allocator.Error!void {
    var n: usize = 0;
    for (st.misspelled.items) |r| {
        const m = mapRange(r, c) orelse continue;
        st.misspelled.items[n] = m;
        n += 1;
    }
    if (n != st.misspelled.items.len) {
        win.dirty.semantics = true;
        win.markPaint(id);
    }
    // Misspellings after the change moved.
    if (c.old_end != c.new_end and n != 0) win.markPaint(id);
    st.misspelled.shrinkRetainingCapacity(n);
    if (st.held) |h| st.held = mapRange(h, c);
    for (st.dirty.items) |*r| r.* = .{ mapPoint(r[0], c, false), mapPoint(r[1], c, true) };
    try addDirty(win.gpa, st, .{ snapStart(content, c.start), snapEnd(content, c.new_end) });
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0c or b == 0x0b;
}

/// `p` moved back to just after whitespace, or the text's start.
fn snapStart(r: Rope, p: u32) u32 {
    var rd = r.reader();
    var i = p;
    const limit = p -| max_snap;
    while (i > limit and !isSpace(rd.at(i - 1))) i -= 1;
    return @intCast(rd.charStart(i));
}

/// `p` moved forward to whitespace, or the text's end.
fn snapEnd(r: Rope, p: u32) u32 {
    var rd = r.reader();
    const len: u32 = @intCast(r.len());
    var i = p;
    const limit = @min(len, p + max_snap);
    while (i < limit and !isSpace(rd.at(i))) i += 1;
    return @intCast(rd.charStart(i));
}

/// Adds a range to check, keeping the list sorted and merged.
fn addDirty(gpa: Allocator, st: *EditorState, r: [2]u32) Allocator.Error!void {
    if (r[0] >= r[1]) return;
    try st.dirty.append(gpa, r);
    const items = st.dirty.items;
    std.mem.sort([2]u32, items, {}, struct {
        fn lt(_: void, a: [2]u32, b: [2]u32) bool {
            return a[0] < b[0];
        }
    }.lt);
    var n: usize = 0;
    for (items) |x| {
        if (x[0] >= x[1]) continue;
        if (n != 0 and x[0] <= items[n - 1][1]) {
            items[n - 1][1] = @max(items[n - 1][1], x[1]);
        } else {
            items[n] = x;
            n += 1;
        }
    }
    st.dirty.shrinkRetainingCapacity(n);
}

/// Where a check of `r` taking at most `max` bytes ends: at whitespace
/// near the limit when there is some.
fn cut(content: Rope, r: [2]u32, max: usize) u32 {
    if (r[1] - r[0] <= max) return r[1];
    const limit: u32 = @intCast(r[0] + max);
    var rd = content.reader();
    var i = limit;
    while (i > limit - @min(max_snap, max / 2) and !isSpace(rd.at(i - 1))) i -= 1;
    if (!isSpace(rd.at(i - 1))) i = limit;
    return @intCast(@max(r[0] + 1, rd.charStart(i)));
}

/// Whether a range of `content` starts and ends at whitespace or the
/// text's ends, so that the words at its ends are whole.
fn clean(content: Rope, a: u32, b: u32) [2]bool {
    var rd = content.reader();
    return .{ a == 0 or isSpace(rd.at(a - 1)), b == content.len() or isSpace(rd.at(b)) };
}

fn process(s: *Spelling, win: *Window, id: NodeId, st: *EditorState, l: *Lang, typed: bool) Allocator.Error!void {
    if (st.dirty.items.len == 0) return;
    var total: usize = 0;
    for (st.dirty.items) |r| total += r[1] - r[0];
    const content = st.checked;
    if (total <= sync_bytes or s.pool == null) {
        var budget: usize = if (s.pool == null) chunk_bytes else total;
        while (st.dirty.items.len != 0 and budget != 0) {
            const r = st.dirty.items[0];
            const end = cut(content, r, budget);
            if (end == r[1]) _ = st.dirty.orderedRemove(0) else st.dirty.items[0][0] = end;
            budget -|= end - r[0];
            try checkNow(win, id, st, l, r[0], end, typed);
        }
        if (st.dirty.items.len != 0) {
            win.markPaint(id);
            win.requestFrame();
        }
        return;
    }
    while (st.dirty.items.len != 0 and st.in_flight < max_jobs) {
        const r = st.dirty.items[0];
        const end = cut(content, r, chunk_bytes);
        try submitCheck(s, win, id, st, l, r[0], end);
        if (end == r[1]) _ = st.dirty.orderedRemove(0) else st.dirty.items[0][0] = end;
    }
}

/// The misspelled words of `bytes`, relative to it, skipping words at an
/// end that is not `clean` (they may be cut).
fn checkWords(gpa: Allocator, d: *const Dict, bytes: []const u8, ends: [2]bool, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    var words = text.segmentation.words(gpa, bytes) catch return error.OutOfMemory;
    defer words.deinit(gpa);
    const len: u32 = @intCast(bytes.len);
    var at: ?u32 = if (words.starts.isSet(0)) 0 else words.starts.after(0);
    while (at) |a| : (at = words.starts.after(a)) {
        if (a >= len) break;
        const b = words.boundaries.after(a) orelse len;
        if ((a == 0 and !ends[0]) or (b == len and !ends[1])) continue;
        if (!spell.checkable(bytes, a, b)) continue;
        // A dot after the word may make it an abbreviation ("etc.").
        const with_dot = if (b < len and bytes[b] == '.') b + 1 else b;
        if (!d.check(bytes[a..with_dot])) try out.append(gpa, .{ a, b });
    }
}

fn checkNow(win: *Window, id: NodeId, st: *EditorState, l: *Lang, a: u32, b: u32, typed: bool) Allocator.Error!void {
    const scratch = win.scratch.allocator();
    const bytes = try st.checked.slice(scratch, a, b);
    var found: std.ArrayList([2]u32) = .empty;
    try checkWords(scratch, l.dict.?, bytes, clean(st.checked, a, b), &found);
    const caret = win.node(id).data.editor.caret;
    var n: usize = 0;
    for (found.items) |r| {
        if (l.accepts(bytes[r[0]..r[1]])) continue;
        const abs: [2]u32 = .{ a + r[0], a + r[1] };
        // The word being typed waits until the caret leaves it.
        if (typed and abs[1] == caret) {
            st.held = abs;
            continue;
        }
        found.items[n] = abs;
        n += 1;
    }
    try replaceIn(win, id, st, a, b, found.items[0..n]);
}

/// Replaces the misspellings within `a..b` with `found` (sorted, within).
fn replaceIn(win: *Window, id: NodeId, st: *EditorState, a: u32, b: u32, found: []const [2]u32) Allocator.Error!void {
    const items = st.misspelled.items;
    var lo: usize = 0;
    while (lo < items.len and items[lo][0] < a) lo += 1;
    var hi = lo;
    while (hi < items.len and items[hi][1] <= b) hi += 1;
    const same = hi - lo == found.len and std.mem.eql(u8, std.mem.sliceAsBytes(items[lo..hi]), std.mem.sliceAsBytes(found));
    if (same) return;
    try st.misspelled.replaceRange(win.gpa, lo, hi - lo, found);
    win.markPaint(id);
    win.dirty.semantics = true;
}

/// Checks part of an editor's text on a compute worker.
const Check = struct {
    job: Pool.Job = .{ .run = run, .done = done, .cancel = cancel, .priority = -1 },
    gpa: Allocator,
    spelling: ?*Spelling,
    /// Null once the window is gone.
    win: ?*Window,
    id: NodeId,
    generation: u32,
    dict: *Dict,
    /// The text checked, to move the results through later edits.
    rope: Rope,
    start: u32,
    bytes: []u8,
    ends: [2]bool,
    found: std.ArrayList([2]u32) = .empty,
    failed: bool = false,

    fn destroy(c: *Check) void {
        c.rope.release(c.gpa);
        c.dict.unref();
        c.gpa.free(c.bytes);
        c.found.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    fn run(job: *Pool.Job) void {
        const c: *Check = @fieldParentPtr("job", job);
        checkWords(c.gpa, c.dict, c.bytes, c.ends, &c.found) catch {
            c.failed = true;
        };
    }

    fn cancel(job: *Pool.Job) void {
        const c: *Check = @fieldParentPtr("job", job);
        c.unlist();
        c.destroy();
    }

    fn unlist(c: *Check) void {
        const s = c.spelling orelse return;
        for (s.checks.items, 0..) |x, i| if (x == c) {
            _ = s.checks.swapRemove(i);
            break;
        };
    }

    fn done(job: *Pool.Job) void {
        const c: *Check = @fieldParentPtr("job", job);
        defer c.destroy();
        c.unlist();
        const s = c.spelling orelse return;
        const win = c.win orelse return;
        const st = win.spell.get(c.id) orelse return;
        if (st.generation != c.generation) return;
        st.in_flight -= 1;
        win.requestFrame();
        c.apply(s, win, st) catch {
            // Check it again rather than lose it.
            addDirty(win.gpa, st, .{ c.start, c.start + @as(u32, @intCast(c.bytes.len)) }) catch {};
        };
    }

    fn apply(c: *Check, s: *Spelling, win: *Window, st: *EditorState) Allocator.Error!void {
        const end = c.start + @as(u32, @intCast(c.bytes.len));
        if (c.failed) return addDirty(win.gpa, st, .{ c.start, end });
        const l = s.langs.items[st.lang];
        var found: std.ArrayList([2]u32) = .empty;
        defer found.deinit(win.gpa);
        const ch = diff(c.rope, st.checked) orelse {
            for (c.found.items) |r| {
                if (l.accepts(c.bytes[r[0]..r[1]])) continue;
                try found.append(win.gpa, .{ c.start + r[0], c.start + r[1] });
            }
            try replaceIn(win, c.id, st, c.start, end, found.items);
            return process(s, win, c.id, st, l, false);
        };
        const ms = mapPoint(c.start, ch, false);
        const me = mapPoint(end, ch, true);
        for (c.found.items) |r| {
            if (l.accepts(c.bytes[r[0]..r[1]])) continue;
            const m = mapRange(.{ c.start + r[0], c.start + r[1] }, ch) orelse continue;
            try found.append(win.gpa, m);
        }
        // The parts of the checked text no edit touched since take the
        // results; what was edited meanwhile is checked again.
        var split: usize = 0;
        while (split < found.items.len and found.items[split][1] < ch.start) split += 1;
        if (c.start < ch.start) try replaceIn(win, c.id, st, ms, @min(me, ch.start), found.items[0..split]);
        if (end > ch.old_end) try replaceIn(win, c.id, st, @max(ms, ch.new_end), me, found.items[split..]);
        if (c.start <= ch.old_end and end >= ch.start) {
            const lo = @max(ms, ch.start);
            const hi = @max(lo, @min(me, ch.new_end));
            try addDirty(win.gpa, st, .{ snapStart(st.checked, lo), snapEnd(st.checked, hi) });
        }
        try process(s, win, c.id, st, l, false);
    }
};

fn submitCheck(s: *Spelling, win: *Window, id: NodeId, st: *EditorState, l: *Lang, a: u32, b: u32) Allocator.Error!void {
    const pool = s.pool.?;
    const c = try win.gpa.create(Check);
    errdefer win.gpa.destroy(c);
    const bytes = try win.gpa.alloc(u8, b - a);
    errdefer win.gpa.free(bytes);
    st.checked.read(a, bytes);
    try s.checks.ensureUnusedCapacity(s.gpa, 1);
    c.* = .{
        .gpa = win.gpa,
        .spelling = s,
        .win = win,
        .id = id,
        .generation = st.generation,
        .dict = l.dict.?.ref(),
        .rope = st.checked.retain(),
        .start = a,
        .bytes = bytes,
        .ends = clean(st.checked, a, b),
    };
    pool.submit(&c.job) catch {
        c.rope.release(win.gpa);
        c.dict.unref();
        return error.OutOfMemory;
    };
    s.checks.appendAssumeCapacity(c);
    st.in_flight += 1;
}

/// A dictionary or word list changed: a frame checks the window's
/// editors again.
pub fn wake(win: *Window) void {
    var it = win.spell.keyIterator();
    while (it.next()) |id| win.markPaint(id.*);
    win.requestFrame();
}

/// Drops an editor's state: its node is gone or no longer checked.
pub fn forget(win: *Window, id: NodeId) void {
    const kv = win.spell.fetchRemove(id) orelse return;
    kv.value.deinit(win.gpa);
    win.gpa.destroy(kv.value);
}

/// Frees the window's states; checks in flight finish without it.
pub fn deinitWindow(win: *Window) void {
    if (win.spelling) |s| for (s.checks.items) |c| {
        if (c.win == win) c.win = null;
    };
    var it = win.spell.valueIterator();
    while (it.next()) |st| {
        st.*.deinit(win.gpa);
        win.gpa.destroy(st.*);
    }
    win.spell.deinit(win.gpa);
}

/// An editor's misspelled words as of the last frame: sorted byte ranges
/// into its text, empty if spell checking is off or the text changed
/// since.
pub fn misspellings(win: *const Window, id: NodeId) []const [2]u32 {
    const st = win.spell.get(id) orelse return &.{};
    if (!win.isLive(id) or win.node(id).kind != .editor) return &.{};
    if (!st.checked.same(win.node(id).data.editor.text.content)) return &.{};
    return st.misspelled.items;
}

pub const Find = enum { at, next, previous };

/// The misspelled word containing `offset` (at either end included),
/// the first starting after it, or the last ending before it.
pub fn find(win: *const Window, id: NodeId, offset: u32, how: Find) ?[2]u32 {
    const items = misspellings(win, id);
    switch (how) {
        .at => for (items) |r| {
            if (r[0] <= offset and offset <= r[1]) return r;
        },
        .next => for (items) |r| {
            if (r[0] > offset) return r;
        },
        .previous => {
            var i = items.len;
            while (i > 0) : (i -= 1) if (items[i - 1][1] < offset) return items[i - 1];
        },
    }
    return null;
}

/// The dictionary an editor is checked with, or null when spell checking
/// is off or there is no dictionary for its language (yet).
pub fn langOf(win: *Window, id: NodeId) ?*Lang {
    const s = win.spelling orelse return null;
    if (!wanted(win, id)) return null;
    const i = s.langFor(tagOf(win, id)) orelse return null;
    const l = s.langs.items[i];
    return if (l.dict != null) l else null;
}

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    const linux = std.os.linux;
    if (std.fs.path.dirname(path)) |dir| {
        var i: usize = 1;
        while (i <= dir.len) : (i += 1) {
            if (i != dir.len and dir[i] != '/') continue;
            var zb: [256]u8 = undefined;
            _ = linux.mkdir(try std.fmt.bufPrintSentinel(&zb, "{s}", .{dir[0..i]}, 0), 0o700);
        }
    }
    var zb: [256]u8 = undefined;
    const rc = linux.open(try std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var done_bytes: usize = 0;
    while (done_bytes < bytes.len) {
        const n = linux.write(fd, bytes[done_bytes..].ptr, bytes.len - done_bytes);
        if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
        done_bytes += n;
    }
}

test "system dictionaries load on the pool; added words go to Enchant's file" {
    const linux = std.os.linux;
    const gpa = std.testing.allocator;
    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/siv-spell-{d}", .{linux.getpid()});
    var bufs: [6][128]u8 = undefined;
    const dicts = try std.fmt.bufPrint(&bufs[0], "{s}/dicts", .{root});
    const config = try std.fmt.bufPrint(&bufs[1], "{s}/config", .{root});
    const files = [_][]const u8{
        try std.fmt.bufPrint(&bufs[2], "{s}/en_ZZ.aff", .{dicts}),
        try std.fmt.bufPrint(&bufs[3], "{s}/en_ZZ.dic", .{dicts}),
        try std.fmt.bufPrint(&bufs[4], "{s}/enchant/en_ZZ.dic", .{config}),
        try std.fmt.bufPrint(&bufs[5], "{s}/enchant/en_ZZ.exc", .{config}),
    };
    defer {
        var zb: [256]u8 = undefined;
        for (files) |f| _ = linux.unlink(std.fmt.bufPrintSentinel(&zb, "{s}", .{f}, 0) catch unreachable);
        for ([_][]const u8{ "/config/enchant", "/config", "/dicts", "" }) |d|
            _ = linux.rmdir(std.fmt.bufPrintSentinel(&zb, "{s}{s}", .{ root, d }, 0) catch unreachable);
    }
    try writeTestFile(files[0], spell.test_dictionary.aff);
    try writeTestFile(files[1], spell.test_dictionary.dic);
    try writeTestFile(files[2], "siv\n");
    try writeTestFile(files[3], "lazy\n");

    var lp = try loop.Loop.init(std.heap.smp_allocator);
    defer lp.deinit();
    var pool = Pool.init(&lp, gpa, 2);
    defer pool.deinit();
    const env: spell.files.Environment = .{ .dicpath = dicts, .xdg_config_home = config, .xdg_data_dirs = "/nonexistent" };
    var s = try Spelling.init(gpa, .{ .pool = &pool, .env = env });
    defer s.deinit();
    const Count = struct {
        n: usize = 0,
        fn bump(ctx: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.n += 1;
        }
    };
    var count: Count = .{};
    s.notify = .{ .ctx = &count, .func = Count.bump };
    // The system's dictionaries are listed, then the one picked loads.
    try std.testing.expectEqual(null, s.langFor("en-ZZ"));
    while (s.busy()) try lp.dispatch(-1);
    const l = s.langs.items[s.langFor("en-ZZ").?];
    try std.testing.expectEqual(2, count.n);
    try std.testing.expectEqualStrings("en_ZZ", l.name);
    try std.testing.expect(l.check("quick") and !l.check("quikc"));
    // Enchant's personal list and exclusions.
    try std.testing.expect(l.check("siv") and l.check("Siv"));
    try std.testing.expect(!l.check("lazy"));
    const sug = try suggest(l, gpa, "lazyy");
    defer {
        for (sug) |w| gpa.free(w);
        gpa.free(sug);
    }
    for (sug) |w| try std.testing.expect(!std.mem.eql(u8, w, "lazy"));
    // Added words are saved where GNOME applications read them.
    try s.addWord(l, "zig");
    try std.testing.expect(l.check("zig"));
    try lp.dispatch(-1);
    const saved = try spell.files.readFile(gpa, files[2]);
    defer gpa.free(saved);
    try std.testing.expectEqualStrings("siv\nzig\n", saved);
    try s.ignoreWord(l, "quikc");
    try std.testing.expect(l.check("quikc"));
    try std.testing.expectError(error.InvalidArgument, s.addWord(l, "two\nwords"));

    // Without a pool, on this thread; the application's checks load now.
    var s2 = try Spelling.init(gpa, .{ .env = env });
    defer s2.deinit();
    const l2 = (try s2.langNow("en-ZZ")).?;
    try std.testing.expectEqualStrings("en_ZZ", l2.name);
    try std.testing.expect(l2.check("zig") and !l2.check("quikc"));
    try std.testing.expectEqual(null, try s2.langNow("xx"));
    const names = try s2.dictionaryNames(gpa);
    defer gpa.free(names);
    for (names) |n| {
        if (std.mem.eql(u8, n, "en_ZZ")) break;
    } else return error.TestUnexpectedResult;
}
