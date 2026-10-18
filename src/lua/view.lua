-- require("siv.view"): a fine-grained reactive layer over siv's retained
-- tree, in the style of SolidJS (D45). It is plain Lua over the generated
-- binding (D23): signals, memos, and effects; components that run once
-- and build real nodes through the ui table; properties given as
-- functions become bindings that update one node's property in the
-- window's transaction when the signals they read change; and keyed
-- lists and conditionals that insert, move, and remove only what
-- changed. There is no second tree and no diffing outside view.each,
-- view.show, and view.switch.
--
-- Signal writes made during a callback are flushed when the outermost
-- callback returns to the binding (internal.set_after), in one
-- transaction per window; writes outside callbacks and batches flush at
-- once.

local siv, internal = ...
local methods = siv.methods
local txn_methods = methods.txn

local error, ipairs, next, pairs, setmetatable, tostring, type =
	error, ipairs, next, pairs, setmetatable, tostring, type
local sort = table.sort

local view = {}
local ui = {}
view.ui = ui

-- State ---------------------------------------------------------------

local CLEAN, CHECK, DIRTY, DISPOSED = 0, 1, 2, 3

local listener -- the computation tracking reads now
local owner -- the scope that new computations and cleanups belong to
local ctx -- where builders put nodes: { win, txn, parent, block, path, mount }
local building = 0 -- > 0 while components run
local untracked = 0 -- > 0 inside view.untrack
local batching = 0 -- > 0 inside view.batch and builds
local flushing = false
local render_queue, effect_queue = {}, {}
local next_id = 0
local counts = { computations = 0, subscriptions = 0 }
local run_owner -- owns what top-level code creates outside components

-- Saving and restoring the state around a build, untrack, or batch, by
-- a to-be-closed value, so that an error leaves it as it was.
local frames, nframes = {}, 0

local function push_frame()
	nframes = nframes + 1
	local f = frames[nframes]
	if not f then
		f = {}
		frames[nframes] = f
	end
	f[1], f[2], f[3], f[4], f[5], f[6] = listener, owner, ctx, building, untracked, batching
	f[7] = nil
	return f
end

local dispose

-- f[7], if set, is a scope that an error disposes: a half-built block.
local restore = setmetatable({}, {
	__close = function(_, err)
		local f = frames[nframes]
		nframes = nframes - 1
		listener, owner, ctx, building, untracked, batching = f[1], f[2], f[3], f[4], f[5], f[6]
		local o = f[7]
		f[1], f[2], f[3], f[7] = nil, nil, nil, nil
		if err ~= nil and o then
			dispose(o)
		end
	end,
})

local function default_equals(a, b)
	return a == b
end

local function equals_of(opts)
	if opts == nil or opts.equals == nil then
		return default_equals
	elseif opts.equals == false then
		return nil
	end
	return opts.equals
end

-- Ownership -----------------------------------------------------------

local function adopt(o, parent)
	o.parent = parent
	if parent then
		local children = parent.children
		if not children then
			children = {}
			parent.children = children
		end
		children[o] = true
	end
end

local function new_owner(parent)
	local o = { state = CLEAN }
	adopt(o, parent)
	return o
end

-- Disposes what a computation or owner made during its last run, runs
-- its cleanups, and drops its subscriptions.
local function clean(o)
	local children = o.children
	if children then
		o.children = nil
		for child in pairs(children) do
			child.parent = nil
			dispose(child)
		end
	end
	local cleanups = o.cleanups
	if cleanups then
		o.cleanups = nil
		for i = #cleanups, 1, -1 do
			cleanups[i]()
		end
	end
	local sources = o.sources
	if sources and next(sources) then
		local n = 0
		for src in pairs(sources) do
			src.observers[o] = nil
			sources[src] = nil
			n = n + 1
		end
		counts.subscriptions = counts.subscriptions - n
	end
end

function dispose(o)
	if o.state == DISPOSED then
		return
	end
	o.state = DISPOSED
	local parent = o.parent
	if parent then
		o.parent = nil
		if parent.children then
			parent.children[o] = nil
		end
	end
	clean(o)
	if o.fn then
		counts.computations = counts.computations - 1
	end
end

-- Tracking ------------------------------------------------------------

local eager = "a signal was read while building nodes, outside a function, so nothing would " ..
	"update when it changes: pass a function instead (text = function() return count() end, " ..
	"or text = count), or read its current value on purpose with view.peek(count)"

local function read(src)
	local l = listener
	if l then
		local sources = l.sources
		if not sources[src] then
			sources[src] = true
			src.observers[l] = true
			counts.subscriptions = counts.subscriptions + 1
		end
	elseif building > 0 and untracked == 0 then
		error("siv.view: " .. eager, 3)
	end
end

-- Marks c (and what depends on it) out of date, queueing effects.
local function stale(c, state)
	local prev = c.state
	if prev < state then
		c.state = state
		if prev == CLEAN then
			local kind = c.kind
			if kind == "render" then
				render_queue[#render_queue + 1] = c
			elseif kind == "effect" then
				effect_queue[#effect_queue + 1] = c
			end
			local observers = c.observers
			if observers then
				for o in pairs(observers) do
					stale(o, CHECK)
				end
			end
		end
	end
end

local function run(c)
	clean(c)
	local l, o = listener, owner
	listener, owner = c, c
	local v = c.fn(c.value)
	listener, owner = l, o
	if c.state == DISPOSED then
		return
	end
	c.state = CLEAN
	if c.observers then
		-- A memo: what reads it runs again only if its value changed.
		local eq = c.eq
		if not (eq and eq(c.value, v)) then
			c.value = v
			for obs in pairs(c.observers) do
				stale(obs, DIRTY)
			end
		end
	else
		c.value = v
	end
end

-- Brings c up to date: memos it read that changed run first, and c runs
-- only if one of them (or a signal) did.
local function update(c)
	if c.state == CHECK then
		for src in pairs(c.sources) do
			if src.fn and src.state ~= CLEAN and src.state ~= DISPOSED then
				update(src)
				if c.state == DIRTY then
					break
				end
			end
		end
		if c.state == CHECK then
			c.state = CLEAN
		end
	end
	if c.state == DIRTY then
		run(c)
	end
end

local function computation(fn, kind, value)
	next_id = next_id + 1
	local c = { fn = fn, kind = kind, value = value, state = CLEAN, sources = {}, id = next_id }
	adopt(c, owner or run_owner)
	counts.computations = counts.computations + 1
	return c
end

-- Flushing ------------------------------------------------------------

local txns = {} -- window -> transaction, while a flush or build holds one
local opened = {} -- windows whose transaction the flush opened, in order
local retry = {} -- computations whose window was busy
local dead_window = false -- a window went: sweep its mounts after the flush
local flush

local function by_id(a, b)
	return a.id < b.id
end

-- The transaction for the window: the build's, the flush's, or a new
-- one the flush commits. nil when the window is gone; false when it has
-- a transaction of the application's open (the computation retries).
local function txn_for(win)
	local t = txns[win]
	if t then
		return t
	end
	local ok, res = pcall(win.txn_begin, win)
	if ok then
		txns[win] = res
		opened[#opened + 1] = win
		return res
	end
	if siv.is_error(res) and res.code == "invalid_handle" then
		dead_window = true
		return nil
	elseif siv.is_error(res) and res.code == "busy" then
		return false
	end
	error(res, 0)
end

local function busy(c, win)
	retry[#retry + 1] = c
	retry.app = retry.app or win:get_app()
end

local function run_render()
	while render_queue[1] do
		local q = render_queue
		render_queue = {}
		if q[2] then
			sort(q, by_id)
		end
		for i = 1, #q do
			local c = q[i]
			if c.state ~= DISPOSED then
				update(c)
			end
		end
	end
end

local function commit_opened()
	for i = 1, #opened do
		local win = opened[i]
		local t = txns[win]
		opened[i] = nil
		txns[win] = nil
		t:commit()
	end
end

local function run_effects()
	local q = effect_queue
	effect_queue = {}
	if q[2] then
		sort(q, by_id)
	end
	for i = 1, #q do
		local c = q[i]
		if c.state ~= DISPOSED then
			update(c)
		end
	end
end

local function post_retry()
	local app = retry.app
	local list = retry
	retry = {}
	app:post(function()
		for _, c in ipairs(list) do
			if c.state ~= DISPOSED then
				stale(c, DIRTY)
			end
		end
		flush()
	end)
end

-- On an error, the flush's transactions abort, what was queued is
-- dropped, and the error goes on with its traceback.
local saved_listener, saved_owner
local sweep_mounts

local flush_guard = setmetatable({}, {
	__close = function(_, err)
		flushing = false
		if err == nil then
			return
		end
		listener, owner = saved_listener, saved_owner
		for i = #opened, 1, -1 do
			local win = opened[i]
			pcall(txns[win].abort, txns[win])
			txns[win] = nil
			opened[i] = nil
		end
		for _, q in ipairs{ render_queue, effect_queue } do
			for i = #q, 1, -1 do
				if q[i].state ~= DISPOSED then
					q[i].state = CLEAN
				end
				q[i] = nil
			end
		end
	end,
})

function flush()
	if flushing or batching > 0 then
		return
	end
	flushing = true
	local _ <close> = flush_guard
	saved_listener, saved_owner = listener, owner
	listener, owner = nil, nil
	local rounds = 0
	repeat
		run_render()
		commit_opened()
		run_effects()
		rounds = rounds + 1
		if rounds > 1000 then
			error("siv.view: effects keep changing the signals they read", 0)
		end
	until not render_queue[1] and not effect_queue[1]
	listener, owner = saved_listener, saved_owner
	saved_listener, saved_owner = nil, nil
	if retry[1] then
		post_retry()
	end
	if dead_window then
		dead_window = false
		sweep_mounts()
	end
end

-- After a write: flush now, or when the callback running returns.
local function schedule()
	if batching > 0 or flushing then
		return
	end
	if internal.in_callback() then
		internal.defer()
		return
	end
	flush()
end

internal.set_after(function()
	flush()
end)

-- Reactive primitives -------------------------------------------------

--- A signal: returns its getter and setter. Reading the getter inside a
--- function the view runs (a binding, memo, or effect) subscribes it;
--- setting a value that equals the current one (==, or opts.equals)
--- does nothing. opts.equals = false makes every set notify, for a table
--- changed in place.
function view.signal(value, opts)
	local s = { value = value, observers = {}, eq = equals_of(opts) }
	local function get()
		read(s)
		return s.value
	end
	local function set(v)
		local eq = s.eq
		if eq == default_equals then
			if s.value == v then
				return
			end
		elseif eq and eq(s.value, v) then
			return
		end
		s.value = v
		local observers = s.observers
		if next(observers) == nil then
			return
		end
		for o in pairs(observers) do
			stale(o, DIRTY)
		end
		schedule()
	end
	return get, set
end

--- A derived value: fn() runs now and again when what it read changes;
--- readers update only when its result changes (==, or opts.equals).
function view.memo(fn, opts)
	local c = computation(fn, "memo")
	c.observers = {}
	c.eq = equals_of(opts)
	local l, o = listener, owner
	listener, owner = c, c
	c.value = fn()
	listener, owner = l, o
	return function()
		local state = c.state
		if state == CHECK or state == DIRTY then
			update(c)
		end
		read(c)
		return c.value
	end
end

--- An effect: fn(previous) runs after the transactions of the flush that
--- made it are committed, and again whenever what it read changes, with
--- what it returned last time.
function view.effect(fn, value)
	local c = computation(fn, "effect", value)
	stale(c, DIRTY)
	schedule()
end

--- Runs fn once, untracked, after the nodes built with it are committed:
--- to focus a node or start something that needs the tree.
function view.on_mount(fn)
	view.effect(function()
		view.untrack(fn)
	end)
end

--- Runs fn when the current scope is disposed or its computation runs
--- again.
function view.on_cleanup(fn)
	local o = listener or owner or run_owner
	local cleanups = o.cleanups
	if not cleanups then
		cleanups = {}
		o.cleanups = cleanups
	end
	cleanups[#cleanups + 1] = fn
end

--- Runs fn(...) with every signal write in it flushed together at the end.
function view.batch(fn, ...)
	push_frame()
	local _ <close> = restore
	batching = batching + 1
	local function finish(...)
		batching = batching - 1
		if batching == 0 then
			schedule()
		end
		return ...
	end
	return finish(fn(...))
end

--- Runs fn(...) without subscribing to what it reads; reading signals
--- in it while building is fine.
function view.untrack(fn, ...)
	push_frame()
	local _ <close> = restore
	listener = nil
	untracked = untracked + 1
	return fn(...)
end

--- The current value of a getter (signal or memo), without subscribing.
function view.peek(get)
	return view.untrack(get)
end

--- Runs fn(dispose) in a new scope that lives until dispose() is called:
--- for effects and memos made outside components.
function view.root(fn)
	local o = new_owner(nil)
	push_frame()
	local _ <close> = restore
	listener, owner = nil, o
	return fn(function()
		dispose(o)
	end)
end

--- Live computations and subscriptions, to check that removed subtrees
--- leave none behind.
function view.stats()
	return { computations = counts.computations, subscriptions = counts.subscriptions }
end

run_owner = new_owner(nil)

-- Blocks: the nodes a component put directly under its parent, and the
-- regions (view.show, view.each) among them, in order. Regions find
-- where to insert from the parts after them, so no marker nodes exist.
-- Parts are nodes (userdata) or regions (tables).

local function block_first(b)
	local parts = b.parts
	for i = 1, #parts do
		local p = parts[i]
		if type(p) == "userdata" then
			return p
		end
		local n = p:first()
		if n then
			return n
		end
	end
end

-- The first node after part i of block b, looking past the block's end
-- into its region's later rows and on; nil to append.
local function after_part(b, i)
	local parts = b.parts
	for j = i + 1, #parts do
		local p = parts[j]
		if type(p) == "userdata" then
			return p
		end
		local n = p:first()
		if n then
			return n
		end
	end
	local r = b.region
	if r then
		return r:after_block(b)
	end
end

-- Calls fn(node, t, x, y) for each node of block b, in order.
local function block_nodes(b, fn, t, x, y)
	local parts = b.parts
	for i = 1, #parts do
		local p = parts[i]
		if type(p) == "userdata" then
			fn(p, t, x, y)
		else
			p:nodes(fn, t, x, y)
		end
	end
end

local function remove_node(n, t)
	txn_methods.remove(t, n)
end

local function move_node(n, t, parent, before)
	txn_methods.move(t, n, parent, before)
end

local function remove_block(t, b)
	block_nodes(b, remove_node, t)
end

local function move_block(t, b, parent, before)
	local parts = b.parts
	local p = parts[1]
	if parts[2] == nil and type(p) == "userdata" then
		txn_methods.move(t, p, parent, before)
	else
		block_nodes(b, move_node, t, parent, before)
	end
end

-- Builds fn(...) as a new block under parent in a new scope, untracked.
local function build_block(win, t, parent, scope, path, mount, fn, ...)
	local o = new_owner(scope)
	local b = { parts = {} }
	push_frame()[7] = o
	local _ <close> = restore
	ctx = { win = win, txn = t, parent = parent, block = b, path = path, mount = mount }
	listener, owner = nil, o
	building = building + 1
	batching = batching + 1
	fn(...)
	return o, b
end

-- A region at the current position of the build.
local function new_region(kind)
	local c = ctx
	if not c then
		error("siv.view: view." .. kind .. " outside a component (view.mount)", 3)
	end
	local b = c.block
	if not b then
		b = { parts = {} }
		c.block = b
	end
	local r = { win = c.win, parent = c.parent, container = b, pos = #b.parts + 1, scope = owner, path = c.path, mount = c.mount }
	b.parts[r.pos] = r
	return r
end

-- Conditionals --------------------------------------------------------

local Branch = {}
Branch.__index = Branch

function Branch:first()
	return self.block and block_first(self.block)
end

function Branch:after_block()
	return after_part(self.container, self.pos)
end

function Branch:nodes(fn, t, x, y)
	if self.block then
		block_nodes(self.block, fn, t, x, y)
	end
end

local function branch_region(kind, select_fn, build_fn)
	local r = setmetatable(new_region(kind), Branch)
	local built = false
	local c = computation(function()
		local k, comp, arg = select_fn()
		if built and k == r.key then
			return
		end
		local t = txn_for(r.win)
		if t == false then
			return busy(r.c, r.win)
		elseif t == nil then
			return
		end
		if r.block then
			remove_block(t, r.block)
			dispose(r.owner)
			r.block, r.owner = nil, nil
		end
		r.key = k
		if comp then
			r.owner, r.block = build_block(r.win, t, r.parent, r.scope, r.path, r.mount, build_fn, comp, arg)
			r.block.region = r
			if built then
				local before = after_part(r.container, r.pos)
				if before then
					move_block(t, r.block, r.parent, before)
				end
			end
		end
		built = true
	end, "render")
	r.c = c
	run(c)
end

--- Shows Then(when) while when() is truthy, else Else(when) if given,
--- swapping the subtrees (and their effects) when its truthiness
--- changes. Then gets the getter, to read the value inside functions.
function view.show(when, Then, Else)
	branch_region("show", function()
		local v = when()
		if v ~= nil and v ~= false then
			return true, Then, when
		end
		return false, Else, when
	end, function(comp, arg)
		comp(arg)
	end)
end

--- Shows cases[key()](key) (or fallback(key)), swapping subtrees when
--- key() changes.
function view.switch(key, cases, fallback)
	branch_region("switch", function()
		local k = key()
		return k, cases[k] or fallback, k
	end, function(comp, arg)
		comp(arg)
	end)
end

-- Keyed lists ---------------------------------------------------------

local Each = {}
Each.__index = Each

function Each:first()
	local rows = self.rows
	for i = 1, #rows do
		local n = block_first(rows[i].block)
		if n then
			return n
		end
	end
end

function Each:after_block(b)
	local rows = self.rows
	for i = b.row.index + 1, #rows do
		local n = block_first(rows[i].block)
		if n then
			return n
		end
	end
	return after_part(self.container, self.pos)
end

function Each:nodes(fn, t, x, y)
	for _, row in ipairs(self.rows) do
		block_nodes(row.block, fn, t, x, y)
	end
end

local function row_segment(key, i)
	local tk = type(key)
	if tk == "string" or tk == "number" or tk == "boolean" then
		return tostring(key)
	end
	return "#" .. i
end

-- A row's position, which the row reads with its index getter: a
-- signal made on the first read, so rows that never read it cost nothing
-- when rows before them come and go.
local function set_row_index(row, i)
	row.index = i
	local set = row.set_index
	if set then
		set(i)
	end
end

local function build_row(r, t, item, key, i)
	local row = { key = key, item = item, index = i }
	local get
	local function index()
		if not get then
			get, row.set_index = view.signal(row.index)
		end
		return get()
	end
	local path = r.path and (r.path .. "/" .. row_segment(key, i))
	row.owner, row.block = build_block(r.win, t, r.parent, r.scope, path, r.mount, r.Row, item, index)
	row.block.region = r
	row.block.row = row
	return row
end

-- The indices in seq[1..n] (old positions, 0 for new rows) that form a
-- longest increasing subsequence: those rows keep their places. Mostly
-- sorted input appends without searching.
local function lis(seq, n)
	local tails, prev, keep = {}, {}, {}
	local len = 0
	for i = 1, n do
		local v = seq[i]
		if v > 0 then
			if len == 0 or seq[tails[len]] < v then
				prev[i] = tails[len]
				len = len + 1
				tails[len] = i
			else
				local lo, hi = 1, len
				while lo < hi do
					local mid = (lo + hi) // 2
					if seq[tails[mid]] < v then
						lo = mid + 1
					else
						hi = mid
					end
				end
				prev[i] = tails[lo - 1]
				tails[lo] = i
			end
		end
	end
	local i = tails[len]
	while i do
		keep[i] = true
		i = prev[i]
	end
	return keep
end

local empty_block = { parts = {} }

local function reconcile(r, t, items, initial)
	local old = r.rows
	local n_old, n_new = #old, #items
	local key_of = r.key_of
	local rows = {}
	if initial or n_old == 0 then
		local before = not initial and after_part(r.container, r.pos) or nil
		for i = 1, n_new do
			local item = items[i]
			local row = build_row(r, t, item, key_of and key_of(item) or item, i)
			rows[i] = row
			if before then
				move_block(t, row.block, r.parent, before)
			end
		end
		r.rows = rows
		return
	end
	-- Rows that stay at the start and at the end need nothing.
	local first, lim = 1, n_old < n_new and n_old or n_new
	while first <= lim and old[first].item == items[first] do
		rows[first] = old[first]
		first = first + 1
	end
	local old_last, new_last = n_old, n_new
	while old_last >= first and new_last >= first and old[old_last].item == items[new_last] do
		local row = old[old_last]
		rows[new_last] = row
		if row.index ~= new_last then
			set_row_index(row, new_last)
		end
		old_last, new_last = old_last - 1, new_last - 1
	end
	-- The rest: old positions by key (equal keys queue in order).
	local map, dups = {}, nil
	for i = first, old_last do
		local k = old[i].key
		if map[k] == nil then
			map[k] = i
		else
			dups = dups or {}
			local q = dups[k]
			if not q then
				q = {}
				dups[k] = q
			end
			q[#q + 1] = i
		end
	end
	local seq, taken = {}, {}
	for i = first, new_last do
		local item = items[i]
		local k = key_of and key_of(item) or item
		local o = map[k]
		-- The same key with another value builds the row again.
		if o and old[o].item == item then
			local q = dups and dups[k]
			map[k] = q and table.remove(q, 1) or false
			taken[o] = true
			rows[i] = old[o]
			seq[i - first + 1] = o
		else
			rows[i] = { key = k, item = item, block = empty_block }
			seq[i - first + 1] = 0
		end
	end
	for i = first, old_last do
		if not taken[i] then
			local row = old[i]
			remove_block(t, row.block)
			dispose(row.owner)
		end
	end
	local keep = lis(seq, new_last - first + 1)
	r.rows = rows
	-- Placed from the end: each row that moves goes before the first
	-- node after it: the first node of the row placed last, or when that
	-- starts with a region, found by looking on from it.
	local before, known, next_row = nil, false, new_last + 1
	for i = new_last, first, -1 do
		local row = rows[i]
		local j = i - first + 1
		local fresh = seq[j] == 0
		if fresh then
			row = build_row(r, t, row.item, row.key, i)
			rows[i] = row
		elseif row.index ~= i then
			set_row_index(row, i)
		end
		if fresh or not keep[j] then
			if not known then
				before = nil
				for k = next_row, n_new do
					before = block_first(rows[k].block)
					if before then
						break
					end
				end
				if not before then
					before = after_part(r.container, r.pos)
				end
				known = true
			end
			move_block(t, row.block, r.parent, before)
		end
		local p1 = row.block.parts[1]
		if p1 then
			if type(p1) == "userdata" then
				before, known = p1, true
			else
				known, next_row = false, i
			end
		end
	end
end

--- Builds Row(item, index) for each item of list() (a getter for an
--- array), keyed by opts.key(item) or the item itself: when the list
--- changes, rows of new keys are built, rows of keys gone are removed
--- with their effects, and rows that stay keep their nodes, moved only
--- where the order changed. index is a getter. A key whose item changed
--- builds its row again; keep what changes in place in signals.
function view.each(list, Row, opts)
	local r = setmetatable(new_region("each"), Each)
	r.rows = {}
	r.Row = Row
	r.key_of = opts and opts.key
	local built = false
	local c = computation(function()
		local items = list() or {}
		local t = txn_for(r.win)
		if t == false then
			return busy(r.c, r.win)
		elseif t == nil then
			return
		end
		view.untrack(reconcile, r, t, items, not built)
		built = true
	end, "render")
	r.c = c
	run(c)
end

-- Builders --------------------------------------------------------------

local widget_setters = {
	label = function(t, node, v)
		t:widget_set_label(node, v)
	end,
	icon = function(t, node, v)
		t:widget_set_icon(node, v)
	end,
	disabled = function(t, node, v)
		t:widget_set_disabled(node, v and true or false)
	end,
	value = function(t, node, v)
		t:widget_set_value(node, v)
	end,
	range = function(t, node, v)
		t:widget_set_range(node, v.min or v[1], v.max or v[2], v.step or v[3] or 0)
	end,
}

local editors = { editor = true, text_field = true }

local function text_setter(editor)
	if editor then
		-- Editors are uncontrolled: their text is the user's, and setting
		-- it drops the undo history (D15), so only a different text is set.
		return function(t, node, v)
			if node:get_text() ~= v then
				t:set_text(node, v)
			end
		end
	end
	return function(t, node, v)
		t:set_text(node, v)
	end
end

local function setter_for(key, name)
	local w = widget_setters[key]
	if w then
		return w
	end
	if key == "text" then
		return text_setter(editors[name])
	end
	local set = txn_methods["set_" .. key]
	if not set then
		error(("siv.view: ui.%s: unknown property '%s'"):format(name, key), 5)
	end
	return function(t, node, v)
		set(t, node, v)
	end
end

local function as_text(v)
	if type(v) == "number" then
		return tostring(v)
	end
	return v
end

-- A binding: get() runs now, and when what it read changes, apply(txn,
-- node, value) sets the new value on the node in its window's
-- transaction. Returns it with its first value; .node is set once built.
local function binding(get, apply, win, convert)
	local b
	b = computation(function(last)
		local v = get()
		if convert then
			v = convert(v)
		end
		local node = b.node
		if node and v ~= last then
			if node:get_window() == nil then
				-- The application removed the node itself (txn:remove):
				-- the binding goes with it rather than fail the flush's
				-- transaction.
				dispose(b)
				return last
			end
			local t = txn_for(win)
			if t == false then
				busy(b, win)
				return last
			elseif t == nil then
				return last
			end
			apply(t, node, v)
		end
		return v
	end, "render")
	run(b)
	return b, b.value
end

local view_keys = { key = true }

-- Splits a properties table into what the builder applies and what the
-- view does: bindings, widget properties, and the key.
local function split(name, props, c)
	local plain = true
	for k, v in pairs(props) do
		if type(v) == "function" or widget_setters[k] or view_keys[k] then
			plain = false
			break
		end
	end
	if plain then
		return props
	end
	local out, binds, widget = {}, nil, nil
	for k, v in pairs(props) do
		if view_keys[k] then
			-- Handled by the builder.
		elseif type(v) == "function" then
			local b, first = binding(v, setter_for(k, name), c.win, k == "text" and as_text or nil)
			binds = binds or {}
			binds[#binds + 1] = b
			if widget_setters[k] then
				widget = widget or {}
				widget[k] = first
			else
				out[k] = first
			end
		elseif widget_setters[k] then
			widget = widget or {}
			widget[k] = v
		else
			out[k] = v
		end
	end
	return out, binds, widget
end

local function no_ctx(name)
	error(("siv.view: ui.%s outside a component (view.mount)"):format(name), 3)
end

-- Records a keyed node for hot reload: focus, an editor's text and
-- selection, and a scroll node's offset survive a remount by key path.
local function register_key(c, name, key, node)
	local m = c.mount
	if not m or not c.path then
		return c.path
	end
	local path = c.path .. "/" .. tostring(key)
	local rec = { node = node, editor = editors[name], scroll = name == "scroll" }
	m.keyed[path] = rec
	view.on_cleanup(function()
		if m.keyed[path] == rec then
			m.keyed[path] = nil
		end
	end)
	return path
end

-- A scroll node with a key reports its offset to the view, so that a
-- remount scrolls the new one there.
local function track_viewport(c, key, props)
	local m = c.mount
	if not m or not c.path then
		return props
	end
	local path = c.path .. "/" .. tostring(key)
	local on = props.on or {}
	local user = on.viewport
	local copy = {}
	for k, v in pairs(props) do
		copy[k] = v
	end
	local handlers = {}
	for k, v in pairs(on) do
		handlers[k] = v
	end
	handlers.viewport = function(node, ev)
		local rec = m.keyed[path]
		if rec then
			rec.x, rec.y = ev.x, ev.y
		end
		if user then
			return user(node, ev)
		end
	end
	copy.on = handlers
	return copy
end

local function make_builder(name, nargs)
	local build = txn_methods[name]
	local set_arg = txn_methods["set_" .. name]
	local function make(c, args, props, children)
		local t = c.txn
		local arg_bind
		if nargs >= 1 and type(args[1]) == "function" then
			if not set_arg then
				error(("siv.view: ui.%s: its first argument cannot be a function; bind its widget properties " ..
					"(label, value, disabled, ...) in the properties table instead"):format(name), 3)
			end
			local apply = name == "text" and text_setter(false) or function(tt, node, v)
				set_arg(tt, node, v)
			end
			local first
			arg_bind, first = binding(args[1], apply, c.win, name == "text" and as_text or nil)
			args[1] = first
		elseif name == "text" then
			args[1] = as_text(args[1])
		end
		local key = props and props.key
		if key ~= nil and name == "scroll" then
			props = track_viewport(c, key, props)
		end
		local out, binds, widget
		if props then
			out, binds, widget = split(name, props, c)
		end
		local node
		if nargs == 0 then
			node = build(t, c.parent, out)
		elseif nargs == 1 then
			node = build(t, c.parent, args[1], out)
		else
			args[nargs + 1] = out
			node = build(t, c.parent, table.unpack(args, 1, nargs + 1))
		end
		if arg_bind then
			arg_bind.node = node
		end
		if binds then
			for i = 1, #binds do
				binds[i].node = node
			end
		end
		local b = c.block
		if b then
			b.parts[#b.parts + 1] = node
		end
		local path = c.path
		if key ~= nil then
			path = register_key(c, name, key, node)
		end
		if children then
			push_frame()
			local _ <close> = restore
			ctx = { win = c.win, txn = t, parent = node, path = path, mount = c.mount }
			children(node)
		end
		-- After the children: a radio group's value needs its radios.
		if widget then
			for k, v in pairs(widget) do
				widget_setters[k](t, node, v)
			end
		end
		return node
	end
	if nargs == 0 then
		return function(props, children)
			local c = ctx or no_ctx(name)
			if type(props) == "function" then
				props, children = nil, props
			end
			return make(c, nil, props, children)
		end
	elseif nargs == 1 then
		return function(a, props, children)
			local c = ctx or no_ctx(name)
			if type(props) == "function" then
				props, children = nil, props
			end
			return make(c, { a }, props, children)
		end
	end
	return function(...)
		local c = ctx or no_ctx(name)
		local args = { ... }
		local props, children = args[nargs + 1], args[nargs + 2]
		if type(props) == "function" then
			props, children = nil, props
		end
		return make(c, args, props, children)
	end
end

for name, nargs in pairs(internal.builders) do
	ui[name] = make_builder(name, nargs)
end

-- Virtualized views stay data sources: desc.row(item, index, depth)
-- builds a row's content once per row node, with item and index as
-- getters, and a recycled row only gets new values for them, so its
-- bindings update in place. desc.items, a getter for an array, sets the
-- count and passes items[index + 1] as the item.
local function virtual(name)
	local plain = ui[name]
	ui[name] = function(desc, props, children)
		local c = ctx or no_ctx(name)
		if type(desc) ~= "table" or desc.row == nil then
			return plain(desc, props, children)
		end
		local row_fn, items = desc.row, desc.items
		local d = {}
		for k, v in pairs(desc) do
			if k ~= "row" and k ~= "items" then
				d[k] = v
			end
		end
		local win, scope, mount = c.win, owner, c.mount
		local rows, live, swept = {}, 0, 16
		local function value_of(item)
			if items then
				return view.peek(items)[item + 1]
			end
			return item
		end
		local function sweep()
			for node, rec in pairs(rows) do
				if node:get_window() == nil then
					dispose(rec.owner)
					rows[node] = nil
					live = live - 1
				end
			end
			swept = live * 2 + 16
		end
		d.bind = function(t, row, item, index, depth, recycled)
			local rec = rows[row]
			local value = value_of(item)
			push_frame()
			local _ <close> = restore
			local mine = txns[win] == nil
			if mine then
				txns[win] = t
			end
			if rec and recycled then
				batching = batching + 1
				rec.set_item(value)
				rec.set_index(index)
				rec.set_depth(depth)
				batching = batching - 1
			else
				if rec then
					dispose(rec.owner)
					live = live - 1
				end
				rec = {}
				local get_item, get_index, get_depth
				get_item, rec.set_item = view.signal(value)
				get_index, rec.set_index = view.signal(index)
				get_depth, rec.set_depth = view.signal(depth)
				rec.owner = build_block(win, t, row, scope, nil, mount, row_fn, get_item, get_index, get_depth)
				rows[row] = rec
				live = live + 1
				if live > swept then
					sweep()
				end
			end
			-- This row's bindings update inside the view's transaction.
			local l, o = listener, owner
			listener, owner = nil, nil
			run_render()
			listener, owner = l, o
			if mine then
				txns[win] = nil
			end
			internal.defer()
		end
		local user_destroy = d.destroy
		d.destroy = function()
			for _, rec in pairs(rows) do
				dispose(rec.owner)
			end
			rows = {}
			if user_destroy then
				user_destroy()
			end
		end
		if items then
			d.count = #view.peek(items)
		end
		local node = plain(d, props, children)
		if items then
			local n = d.count
			local b
			b = computation(function()
				local list = items()
				if not b or not b.node then
					return
				end
				local t = txn_for(win)
				if t == false then
					return busy(b, win)
				elseif t == nil then
					return
				end
				if #list ~= n then
					n = #list
					t:view_set_count(b.node, n)
				else
					t:view_refresh(b.node)
				end
			end, "render")
			run(b)
			b.node = node
		end
		return node
	end
end

for _, name in ipairs{ "list_view", "tree_view", "table_view", "grid_view" } do
	if ui[name] then
		virtual(name)
	end
end

-- Mounting ------------------------------------------------------------

local mounts = {} -- parent node -> mount

local function alive(m)
	return m.parent:get_window() ~= nil
end

local function dispose_mount(m)
	if m.disposed then
		return
	end
	m.disposed = true
	if mounts[m.parent] == m then
		mounts[m.parent] = nil
	end
	dispose(m.owner)
end

function sweep_mounts()
	for _, m in pairs(mounts) do
		if not alive(m) then
			dispose_mount(m)
		end
	end
end

-- What a remount carries over from the tree it replaces, by key path.
local function capture(m)
	local saved = {}
	local by_node = {}
	for path, rec in pairs(m.keyed) do
		by_node[rec.node] = path
		local s = {}
		if rec.editor then
			local ok, text = pcall(rec.node.get_text, rec.node)
			if ok then
				s.text = text
				s.caret, s.anchor = rec.node:get_selection()
			end
		end
		if rec.scroll and rec.x then
			s.x, s.y = rec.x, rec.y
		end
		saved[path] = s
	end
	local focus = m.win:get_focus()
	while focus do
		local path = by_node[focus]
		if path then
			saved[path].focus = true
			break
		end
		focus = focus:get_related("parent")
	end
	return saved
end

local function apply_saved(m, t, saved)
	local focus
	for path, s in pairs(saved) do
		local rec = m.keyed[path]
		if rec then
			if s.text and rec.editor then
				if rec.node:get_text() ~= s.text then
					t:set_text(rec.node, s.text)
				end
				t:set_selection(rec.node, s.caret, s.anchor)
			end
			if s.x and rec.scroll then
				t:scroll_to(rec.node, s.x, s.y)
			end
			if s.focus then
				focus = rec.node
			end
		end
	end
	return focus
end

local function resolve(target)
	local _, kind = siv.handle(target)
	if kind == "window" then
		return target, target:get_root()
	elseif kind == "node" then
		return target:get_window(), target
	end
	error("siv.view.mount: a window or a node expected", 3)
end

--- Builds Component(...) under target (a window's root, or a node) in
--- one transaction, and returns a function that removes it and disposes
--- its effects. Mounting again on the same target replaces the previous
--- mount, keeping focus, editors' text and selection, and scroll offsets
--- of nodes with the same key path (props.key, under the keys of their
--- keyed ancestors and rows): how a hot reload rebuilds a kept window.
function view.mount(target, Component, ...)
	local win, parent = resolve(target)
	local prev = mounts[parent]
	local saved = prev and not prev.disposed and capture(prev) or nil
	local m = { win = win, parent = parent, keyed = {} }
	local t = txns[win]
	local own = t == nil
	if own then
		local ok, res = pcall(win.txn_begin, win)
		if not ok then
			if siv.is_error(res) and res.code == "busy" then
				error("siv.view.mount: the window has a transaction open; mount outside window:update", 2)
			end
			error(res, 2)
		end
		t = res
	end
	local focus
	do
		local txn_guard <close> = own and t or nil
		push_frame()
		local _ <close> = restore
		batching = batching + 1
		txns[win] = t
		local guard <close> = setmetatable({}, { __close = function()
			if own then
				txns[win] = nil
			end
		end })
		m.owner, m.block = build_block(win, t, parent, owner, "", m, Component, ...)
		if prev and not prev.disposed then
			remove_block(t, prev.block)
		end
		-- Writes made while building land in this transaction too.
		local l, o = listener, owner
		listener, owner = nil, nil
		run_render()
		listener, owner = l, o
		if saved then
			focus = apply_saved(m, t, saved)
		end
		if own then
			t:commit()
		end
	end
	if prev then
		dispose_mount(prev)
	end
	mounts[parent] = m
	schedule()
	if focus then
		focus:focus()
	end
	return function()
		if m.disposed then
			return
		end
		if alive(m) then
			local tt = txns[win]
			if tt then
				remove_block(tt, m.block)
			else
				win:update(function(u)
					remove_block(u, m.block)
				end)
			end
		end
		dispose_mount(m)
	end
end

-- Hot reload: what top-level code made in the previous run goes once the
-- new run succeeds, with the mounts of windows that went with it; if it
-- fails, what the new run made goes instead.
local old_run
internal.reload_hooks[#internal.reload_hooks + 1] = function(phase)
	if phase == "begin" then
		old_run = run_owner
		run_owner = new_owner(nil)
	elseif phase == "done" then
		if old_run then
			dispose(old_run)
		end
		old_run = nil
		sweep_mounts()
	else
		dispose(run_owner)
		run_owner = old_run or new_owner(nil)
		old_run = nil
		sweep_mounts()
	end
end

return view
