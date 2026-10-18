//! require("siv.view") (D45) on the headless backend: reactivity,
//! ownership, keyed lists, batching into one transaction per window,
//! editors' undo, virtualized views, and hot reload. The scripts drive
//! windows through siv's public test API, so nothing depends on timing.

const std = @import("std");
const root = @import("lua");
const lua = root.helpers;
const c = lua.c;

const testing = std.testing;

fn run(script: []const u8) !void {
    const L = root.siv_lua_new(~@as(c_int, 0)) orelse return error.OutOfMemory;
    defer c.lua_close(L);
    lua.pushcfunction(L, struct {
        fn tb(Lq: ?*lua.State) callconv(.c) c_int {
            const Ls = Lq.?;
            c.luaL_traceback(Ls, Ls, c.luaL_tolstring(Ls, 1, null), 1);
            return 1;
        }
    }.tb);
    if (c.luaL_loadbufferx(L, script.ptr, script.len, "=test", "t") != lua.ok) {
        std.debug.print("{s}\n", .{lua.toString(L, -1).?});
        return error.LuaSyntax;
    }
    if (lua.pcall(L, 0, 0, 1) != lua.ok) {
        std.debug.print("{s}\n", .{lua.toString(L, -1) orelse "(error)"});
        return error.LuaError;
    }
}

const prologue =
    \\local siv = require("siv")
    \\local view = require("siv.view")
    \\local ui = view.ui
    \\local app <close> = siv.app_create{ backend = "headless", flags = { "no_system_fonts", "reduced_motion" } }
    \\local font = assert(io.open("src/text/testdata/DroidSans.ttf", "rb"))
    \\app:add_font("Droid", font:read("a"))
    \\font:close()
    \\app:set_default_font("Droid")
    \\local function settle() assert(app:test_settle(5000), "did not settle") end
    \\-- Transactions begun per window, and moves.
    \\local begins, moves = {}, 0
    \\local txn_begin, move = siv.methods.window.txn_begin, siv.methods.txn.move
    \\siv.methods.window.txn_begin = function(w)
    \\  begins[w] = (begins[w] or 0) + 1
    \\  return txn_begin(w)
    \\end
    \\siv.methods.txn.move = function(...)
    \\  moves = moves + 1
    \\  return move(...)
    \\end
    \\local function texts(node)
    \\  local out = {}
    \\  for child in node:children() do out[#out + 1] = child:get_text() end
    \\  return table.concat(out, " ")
    \\end
    \\
;

test "view: signals, memos, effects, and batches" {
    try run(prologue ++
        \\local a, set_a = view.signal(1)
        \\local b, set_b = view.signal(2)
        \\local sums = 0
        \\local sum = view.memo(function() sums = sums + 1; return a() + b() end)
        \\local parity = view.memo(function() return sum() % 2 end)
        \\local seen = {}
        \\view.effect(function() seen[#seen + 1] = parity() end)
        \\assert(#seen == 1 and seen[1] == 1)
        \\-- The sum changes, its parity does not: the effect stays.
        \\set_a(3)
        \\assert(sums == 2 and #seen == 1)
        \\-- Two writes in a batch: one run of each.
        \\view.batch(function() set_a(2); set_b(2) end)
        \\assert(sums == 3 and #seen == 2 and seen[2] == 0, sums .. " " .. #seen)
        \\-- A diamond runs its effect once per change, with consistent values.
        \\local double = view.memo(function() return a() * 2 end)
        \\local triple = view.memo(function() return a() * 3 end)
        \\local runs, last = 0, nil
        \\view.effect(function() runs = runs + 1; last = double() + triple() end)
        \\set_a(10)
        \\assert(runs == 2 and last == 50, runs .. " " .. last)
        \\-- An equal value notifies nothing; equals = false notifies always.
        \\set_a(10)
        \\assert(runs == 2)
        \\local t, set_t = view.signal({}, { equals = false })
        \\local tables = 0
        \\view.effect(function() t(); tables = tables + 1 end)
        \\set_t(t())
        \\assert(tables == 2)
        \\-- Cleanups run before an effect runs again and when its root goes.
        \\local cleaned = 0
        \\view.root(function(dispose)
        \\  view.effect(function()
        \\    a()
        \\    view.on_cleanup(function() cleaned = cleaned + 1 end)
        \\  end)
        \\  set_a(11)
        \\  assert(cleaned == 1)
        \\  dispose()
        \\  assert(cleaned == 2)
        \\  set_a(12)
        \\  assert(cleaned == 2)
        \\end)
        \\-- Untracked reads subscribe to nothing.
        \\local untracked = 0
        \\view.effect(function() untracked = untracked + 1; view.peek(b) end)
        \\set_b(99)
        \\assert(untracked == 1)
    );
}

test "view: reading a signal while building is an error, not a silent constant" {
    try run(prologue ++
        \\local win = app:window_create{ width = 100, height = 60 }
        \\local count = view.signal(1)
        \\local ok, err = pcall(view.mount, win, function() ui.text("Count: " .. count()) end)
        \\assert(not ok and err:find("^test:%d+: siv.view: a signal was read while building"), err)
        \\assert(err:find("view.peek"), err)
        \\-- The failed mount left nothing behind.
        \\assert(win:get_root():get_related("first_child") == nil)
        \\assert(view.stats().computations == 0 and view.stats().subscriptions == 0)
        \\-- On purpose, it is fine; outside a build too.
        \\view.mount(win, function() ui.text("Count: " .. view.peek(count)) end)
        \\assert(texts(win:get_root()) == "Count: 1")
        \\assert(count() == 1)
    );
}

test "view: bindings and control flow update the tree in place" {
    try run(prologue ++
        \\local win = app:window_create{ width = 200, height = 200 }
        \\local count, set_count = view.signal(0)
        \\local column, label
        \\view.mount(win, function()
        \\  column = ui.flex({ axis = "column" }, function()
        \\    label = ui.text(function() return "Count: " .. count() end)
        \\    view.show(function() return count() > 1 and count() end, function(v)
        \\      ui.text(function() return "big " .. v() end)
        \\    end, function() ui.text("small") end)
        \\    view.switch(function() return count() % 3 end, {
        \\      [0] = function() ui.text("zero") end,
        \\      [1] = function() ui.text("one"); ui.text("uno") end,
        \\    })
        \\    ui.text("end", { hidden = function() return count() == 4 end })
        \\  end)
        \\end)
        \\assert(texts(column) == "Count: 0 small zero end", texts(column))
        \\local first = label
        \\set_count(1)
        \\assert(texts(column) == "Count: 1 small one uno end", texts(column))
        \\set_count(2)
        \\assert(texts(column) == "Count: 2 big 2 end", texts(column))
        \\set_count(3)
        \\assert(texts(column) == "Count: 3 big 3 zero end", texts(column))
        \\set_count(4)
        \\assert(texts(column) == "Count: 4 big 4 one uno end", texts(column))
        \\assert(column:get_related("last_child"):is_hidden())
        \\-- The label is the same node all along.
        \\assert(rawequal(first, column:get_related("first_child")))
        \\-- Numbers are text.
        \\view.mount(win, function() ui.text(count) end)
        \\assert(texts(win:get_root()) == "4")
    );
}

test "view: writes during a callback land in one transaction per window" {
    try run(prologue ++
        \\local w1 = app:window_create{ width = 200, height = 100 }
        \\local w2 = app:window_create{ width = 200, height = 100 }
        \\local count, set_count = view.signal(0)
        \\local name, set_name = view.signal("a")
        \\local button, l1, l2, l3
        \\view.mount(w1, function()
        \\  ui.flex({ axis = "column" }, function()
        \\    l1 = ui.text(function() return "count " .. count() end)
        \\    button = ui.push_button({ label = "Add" }, {
        \\      label = function() return "Add to " .. count() end,
        \\      on = { activate = function()
        \\        set_count(count() + 1)
        \\        set_name(name() .. "b")
        \\        set_count(count() + 1)
        \\        -- Signals read their new values at once; the tree updates
        \\        -- when the callback returns.
        \\        assert(l1:get_text() == "count " .. (count() - 2))
        \\        return true
        \\      end },
        \\    })
        \\  end)
        \\end)
        \\view.mount(w2, function()
        \\  ui.flex({ axis = "column" }, function()
        \\    l2 = ui.text(function() return name() .. count() end)
        \\    l3 = ui.text(name)
        \\  end)
        \\end)
        \\begins = {}
        \\assert(button:emit{ type = "activate" } == true)
        \\assert(begins[w1] == 1 and begins[w2] == 1, tostring(begins[w1]) .. " " .. tostring(begins[w2]))
        \\assert(l1:get_text() == "count 2" and l2:get_text() == "ab2" and l3:get_text() == "ab")
        \\-- From a click through the test API.
        \\settle()
        \\local _, node = w1:test_find{ role = "button" }
        \\local r = node.bounds
        \\begins = {}
        \\w1:test_click(r.x + r.width / 2, r.y + r.height / 2, "primary")
        \\settle()
        \\assert(begins[w1] == 1 and begins[w2] == 1)
        \\assert(l1:get_text() == "count 4" and w1:test_get_name{ role = "button" } == "Add to 4")
        \\-- Timers, posts, and coroutines that wait flush when they return.
        \\begins = {}
        \\local fired = false
        \\app:timer_start(1, function() set_count(10); set_name("t"); fired = true end)
        \\while not fired do app:dispatch(10) end
        \\assert(begins[w1] == 1 and begins[w2] == 1 and l2:get_text() == "t10")
        \\begins = {}
        \\local posted = false
        \\app:post(function() set_count(11); set_count(12); posted = true end)
        \\while not posted do app:dispatch(10) end
        \\assert(begins[w1] == 1 and begins[w2] == 1 and l1:get_text() == "count 12")
        \\begins = {}
        \\local woke = false
        \\siv.spawn(function() app:sleep(1); set_count(13); set_name("s"); woke = true end)
        \\while not woke do app:dispatch(10) end
        \\assert(begins[w1] == 1 and begins[w2] == 1 and l2:get_text() == "s13")
        \\-- Outside callbacks a write flushes at once; a batch flushes once.
        \\begins = {}
        \\set_count(14)
        \\assert(begins[w1] == 1 and l1:get_text() == "count 14")
        \\begins = {}
        \\view.batch(function() set_count(15); set_name("x") end)
        \\assert(begins[w1] == 1 and begins[w2] == 1)
        \\-- Inside the application's own transaction the window is busy:
        \\-- the other window updates now, this one at the next dispatch.
        \\w1:update(function() set_count(16) end)
        \\assert(l2:get_text() == "x16" and l1:get_text() == "count 15")
        \\for _ = 1, 10 do app:dispatch(0) end
        \\assert(l1:get_text() == "count 16", l1:get_text())
    );
}

test "view: removing a subtree disposes its effects and subscriptions" {
    try run(prologue ++
        \\local win = app:window_create{ width = 200, height = 200 }
        \\local on, set_on = view.signal(true)
        \\local items, set_items = view.signal({})
        \\local tick, set_tick = view.signal(0)
        \\local cleaned = 0
        \\local function Panel()
        \\  ui.box(function()
        \\    ui.text(function() return "tick " .. tick() end)
        \\    view.effect(function() tick() end)
        \\    view.on_cleanup(function() cleaned = cleaned + 1 end)
        \\    view.show(function() return tick() >= 0 end, function() ui.text(tick) end)
        \\  end)
        \\end
        \\local dispose = view.mount(win, function()
        \\  ui.flex({ axis = "column" }, function()
        \\    view.show(on, Panel)
        \\    view.each(items, function(item)
        \\      Panel()
        \\      ui.text(function() return item .. tick() end)
        \\    end)
        \\  end)
        \\end)
        \\local base = view.stats()
        \\for i = 1, 20 do
        \\  set_on(false)
        \\  set_on(true)
        \\  set_items({ 1, 2, 3, 4, 5 })
        \\  set_tick(i)
        \\  set_items({ 2, 4 })
        \\  set_items({})
        \\end
        \\local now = view.stats()
        \\assert(now.computations == base.computations and now.subscriptions == base.subscriptions,
        \\  ("%d/%d computations, %d/%d subscriptions"):format(now.computations, base.computations, now.subscriptions, base.subscriptions))
        \\-- Each Panel that went ran its cleanup: 20 shows and 20 * 5 rows.
        \\assert(cleaned == 20 + 100, cleaned)
        \\dispose()
        \\assert(view.stats().computations == 0 and view.stats().subscriptions == 0)
        \\assert(win:get_root():get_related("first_child") == nil)
        \\-- Nothing listens any more.
        \\set_tick(100)
        \\set_on(false)
        \\assert(cleaned == 121)
    );
}

test "view: a node the application removes itself drops its bindings, not the flush" {
    try run(prologue ++
        \\local win = app:window_create{ width = 200, height = 200 }
        \\local label, set_label = view.signal("a")
        \\local other, set_other = view.signal("x")
        \\local doomed, kept
        \\view.mount(win, function()
        \\  ui.flex({ axis = "column" }, function()
        \\    doomed = ui.text(label)
        \\    kept = ui.text(other)
        \\  end)
        \\end)
        \\settle()
        \\local base = view.stats()
        \\win:update(function(t) t:remove(doomed) end)
        \\-- One flush updates both: the removed node's binding goes, and the
        \\-- live one still lands.
        \\view.batch(function()
        \\  set_label("b")
        \\  set_other("y")
        \\end)
        \\settle()
        \\assert(kept:get_text() == "y", kept:get_text())
        \\local now = view.stats()
        \\assert(now.computations == base.computations - 1 and now.subscriptions == base.subscriptions - 1,
        \\  ("%d/%d computations, %d/%d subscriptions"):format(now.computations, base.computations, now.subscriptions, base.subscriptions))
        \\set_label("c")
        \\assert(view.stats().computations == now.computations)
    );
}

test "view: keyed lists keep their nodes and move only what changed" {
    try run(prologue ++
        \\local win = app:window_create{ width = 200, height = 300 }
        \\local function list(...) local t = {}; for _, n in ipairs{ ... } do t[#t + 1] = n end; return t end
        \\local rows, builds = {}, 0
        \\local items, set_items = view.signal(list("a", "b", "c", "d", "e", "f"))
        \\local column
        \\view.mount(win, function()
        \\  column = ui.flex({ axis = "column" }, function()
        \\    ui.text("[")
        \\    view.each(items, function(item, index)
        \\      builds = builds + 1
        \\      rows[item] = ui.text(function() return item .. index() end)
        \\    end)
        \\    ui.text("]")
        \\  end)
        \\end)
        \\assert(texts(column) == "[ a1 b2 c3 d4 e5 f6 ]", texts(column))
        \\local before = {}
        \\for k, v in pairs(rows) do before[k] = v end
        \\local function same()
        \\  for k, v in pairs(before) do
        \\    if rows[k] and not rawequal(rows[k], v) then return false end
        \\  end
        \\  return true
        \\end
        \\local function check(want, want_moves, want_builds)
        \\  moves, builds = 0, 0
        \\  set_items(want[1])
        \\  assert(texts(column) == want[2], texts(column))
        \\  assert(moves == want_moves, ("%d moves, not %d"):format(moves, want_moves))
        \\  assert(builds == want_builds, ("%d builds, not %d"):format(builds, want_builds))
        \\  assert(same(), "a kept row got a new node")
        \\end
        \\-- Reversed: all but one move.
        \\check({ list("f", "e", "d", "c", "b", "a"), "[ f1 e2 d3 c4 b5 a6 ]" }, 5, 0)
        \\-- One row to the front: one move.
        \\check({ list("a", "f", "e", "d", "c", "b"), "[ a1 f2 e3 d4 c5 b6 ]" }, 1, 0)
        \\-- Two swapped: two moves.
        \\check({ list("a", "c", "e", "d", "f", "b"), "[ a1 c2 e3 d4 f5 b6 ]" }, 2, 0)
        \\-- Removed: nothing moves; inserted: one new row placed.
        \\check({ list("a", "e", "d", "b"), "[ a1 e2 d3 b4 ]" }, 0, 0)
        \\check({ list("a", "x", "e", "d", "b"), "[ a1 x2 e3 d4 b5 ]" }, 1, 1)
        \\-- Appended at the end of the list, before the "]".
        \\check({ list("a", "x", "e", "d", "b", "y"), "[ a1 x2 e3 d4 b5 y6 ]" }, 1, 1)
        \\check({ list(), "[ ]" }, 0, 0)
        \\check({ list("p", "q"), "[ p1 q2 ]" }, 2, 2)
        \\-- Equal keys queue in order; keys from opts.key.
        \\check({ list("p", "p", "q"), "[ p1 p2 q3 ]" }, 1, 1)
        \\local people, set_people = view.signal({ { id = 1, n = "ann" }, { id = 2, n = "bob" } })
        \\local nodes = {}
        \\view.mount(win, function()
        \\  column = ui.flex({ axis = "column" }, function()
        \\    view.each(people, function(p) nodes[p.id] = ui.text(p.n) end, { key = function(p) return p.id end })
        \\  end)
        \\end)
        \\local bob = nodes[2]
        \\set_people({ people()[2], { id = 1, n = "ada" } })
        \\assert(texts(column) == "bob ada", texts(column))
        \\assert(rawequal(nodes[2], bob))
    );
}

test "view: a bound editor keeps its undo history" {
    try run(prologue ++
        \\local win = app:window_create{ width = 240, height = 80 }
        \\local sets = 0
        \\local set_text = siv.methods.txn.set_text
        \\siv.methods.txn.set_text = function(...) sets = sets + 1; return set_text(...) end
        \\local draft, set_draft = view.signal("")
        \\local field
        \\view.mount(win, function()
        \\  field = ui.text_field({ placeholder = "Name" }, {
        \\    text = draft,
        \\    on = { change = function(_, ev) set_draft(ev.text) return true end },
        \\  })
        \\end)
        \\field:focus()
        \\settle()
        \\win:test_type("hello world")
        \\settle()
        \\assert(draft() == "hello world" and field:get_text() == "hello world")
        \\-- The draft followed the editor, and the binding set nothing back.
        \\assert(sets == 0, sets)
        \\-- So Ctrl+Z still has the typing to undo.
        \\win:test_key(0x7a, "ctrl", "")
        \\settle()
        \\assert(field:get_text() == "hello" and draft() == "hello", field:get_text())
        \\-- A real change from the application sets the text once.
        \\set_draft("cleared")
        \\assert(field:get_text() == "cleared" and sets == 1, sets)
        \\set_draft("cleared")
        \\assert(sets == 1)
    );
}

test "view: virtualized lists build rows once and rebind them in place" {
    try run(prologue ++
        \\local win = app:window_create{ width = 200, height = 100 }
        \\local items, set_items = view.signal({})
        \\local all = {}
        \\for i = 1, 1000 do all[i] = { name = "item " .. i } end
        \\set_items(all)
        \\local built = 0
        \\local list
        \\view.mount(win, function()
        \\  list = ui.list_view({
        \\    label = "Items", item_height = 20, items = items,
        \\    row = function(item, index)
        \\      built = built + 1
        \\      ui.text(function() return item().name .. " @" .. index() end)
        \\    end,
        \\  }, { layout = { width = { "fraction", 1 }, height = { "fraction", 1 } } })
        \\end)
        \\settle()
        \\assert(win:test_find{ name = "item 1 @0" } and win:test_find{ name = "item 3 @2" }, win:test_dump())
        \\-- Only the rows in view exist; their bindings are all there is.
        \\assert(built > 0 and built < 20, built)
        \\local live = view.stats().computations
        \\assert(live < 30, live)
        \\-- A new array: the rows in view rebind in place, without building.
        \\local changed = { { name = "first" } }
        \\for i = 2, 1000 do changed[i] = all[i] end
        \\local was = built
        \\set_items(changed)
        \\settle()
        \\assert(built == was and win:test_find{ name = "first @0" }, win:test_dump())
        \\-- A shorter list sets the count.
        \\set_items({ { name = "only" } })
        \\settle()
        \\assert(win:test_find{ name = "only @0" } and not win:test_find{ name = "item 2 @1" }, win:test_dump())
        \\assert(view.stats().computations <= live)
    );
}

test "view: hot reload rebuilds components and keeps signals, focus, and editors" {
    const io = testing.io;
    const dir = ".zig-cache/lua-view-reload";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/main.lua", .data = 
        \\local path = ...
        \\local siv = require("siv")
        \\local view = require("siv.view")
        \\local ui = view.ui
        \\local app = siv.app_create{ backend = "headless", flags = { "no_system_fonts", "reduced_motion" } }
        \\local win = siv.keep("window", function() return app:window_create{ width = 240, height = 160 } end)
        \\local count, set_count = siv.keep("count", function() return view.signal(0) end)
        \\local state = siv.keep("state", function() return { runs = 0 } end)
        \\local other = app:window_create{ width = 50, height = 50 }
        \\state.others = state.others or {}
        \\state.others[#state.others + 1] = other
        \\local heading = "first"
        \\state.runs = state.runs + 1
        \\view.effect(function() state.seen = count() end)
        \\view.mount(other, function() ui.text(count) end)
        \\view.mount(win, function()
        \\  state.column = ui.flex({ axis = "column" }, function()
        \\    ui.text(heading)
        \\    ui.text(function() return "count " .. count() end)
        \\    ui.box({ key = "form" }, function()
        \\      state.field = ui.text_field({}, { key = "name" })
        \\    end)
        \\    state.plain = ui.text_field({})
        \\  end)
        \\end)
        \\if state.runs == 1 then
        \\  set_count(5)
        \\  state.field:focus()
        \\  assert(app:test_settle(5000))
        \\  win:test_type("hello")
        \\  win:test_key("left", 0, "")
        \\  assert(app:test_settle(5000))
        \\  local stats = view.stats()
        \\  local f = assert(io.open(path, "r"))
        \\  local source = f:read("a")
        \\  f:close()
        \\  f = assert(io.open(path, "w"))
        \\  f:write((source:gsub('local heading = "first"', 'local heading = "second"')))
        \\  f:close()
        \\  siv.reload()
        \\  assert(state.runs == 2)
        \\  local first = state.column:get_related("first_child")
        \\  assert(first:get_text() == "second" and first:get_related("next"):get_text() == "count 5")
        \\  -- The keyed editor kept its text, caret, and focus.
        \\  assert(state.field:get_text() == "hello", state.field:get_text())
        \\  local caret, anchor = state.field:get_selection()
        \\  assert(caret == 4 and anchor == 4, caret .. " " .. anchor)
        \\  assert(rawequal(win:get_focus(), state.field))
        \\  -- What the first run made is gone, but for the mount of its
        \\  -- other window, which only siv-lua --watch destroys.
        \\  local now = view.stats()
        \\  assert(now.computations == stats.computations + 1 and now.subscriptions == stats.subscriptions + 1,
        \\    ("%d/%d computations, %d/%d subscriptions"):format(now.computations, stats.computations, now.subscriptions, stats.subscriptions))
        \\  -- A window that goes takes its mount along at the next flush.
        \\  state.others[1]:destroy()
        \\  set_count(6)
        \\  now = view.stats()
        \\  assert(now.computations == stats.computations and now.subscriptions == stats.subscriptions)
        \\  assert(state.seen == 6)
        \\  assert(state.column:get_related("first_child"):get_related("next"):get_text() == "count 6")
        \\  -- A failed reload keeps the running tree alive.
        \\  f = assert(io.open(path, "w"))
        \\  f:write((source:gsub('local heading = "first"', 'error("broken")')))
        \\  f:close()
        \\  siv.set_error_handler(function(err) state.err = tostring(err) end)
        \\  siv.reload()
        \\  assert(state.err and state.err:find("broken"), state.err)
        \\  set_count(7)
        \\  assert(state.seen == 7 and state.column:get_related("first_child"):get_related("next"):get_text() == "count 7")
        \\end
    });
    const L = root.siv_lua_new(~@as(c_int, 0)) orelse return error.OutOfMemory;
    defer c.lua_close(L);
    const args = [_:null]?[*:0]const u8{dir ++ "/main.lua"};
    try testing.expectEqual(0, root.siv_lua_run(L, dir ++ "/main.lua", 1, &args, 0));
}
