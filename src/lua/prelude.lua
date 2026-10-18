-- The part of require("siv") written in Lua (D23). It runs once per Lua
-- state with the module the binding generated from the schema and the
-- binding's internals, and returns the module. Nothing here reaches the
-- global table.

local siv, internal = ...
local methods = siv.methods

local coroutine, table, math, string, package = coroutine, table, math, string, package
local error, ipairs, pairs, pcall, select, setmetatable, tostring, type, loadfile =
	error, ipairs, pairs, pcall, select, setmetatable, tostring, type, loadfile

-- Errors --------------------------------------------------------------

--- Whether `v` is an error raised for a siv result code.
function siv.is_error(v)
	return internal.is_error(v)
end

--- Sets the function that hears errors raised by callbacks, or with nil
--- restores the default: the error ends app:run (or the binding call that
--- ran the callback) and is raised from it.
function siv.set_error_handler(fn)
	internal.set_error_handler(fn)
end

-- An error from coroutine `co` with its traceback.
local function coerror(co, err)
	if siv.is_error(err) then
		if err.traceback == nil then
			err.traceback = internal.traceback(co, nil)
		end
		return err
	end
	return internal.traceback(co, tostring(err))
end

-- Transactions --------------------------------------------------------

--- Runs fn(txn, root, ...) in a transaction on the window and commits it;
--- if fn raises, the transaction is aborted and the error goes on.
function methods.window.update(window, fn, ...)
	local txn <close> = window:txn_begin()
	local r = table.pack(fn(txn, window:get_root(), ...))
	txn:commit()
	return table.unpack(r, 1, r.n)
end

-- Tree ----------------------------------------------------------------

--- Iterates over a node's children, first to last, as of the latest
--- operation. Removing the child just returned is fine.
function methods.node.children(node)
	local next_child = node:get_related("first_child")
	return function()
		local child = next_child
		if child then
			next_child = child:get_related("next")
		end
		return child
	end
end

--- Removes every child of `node`.
function methods.txn.clear(txn, node)
	for child in node:children() do
		txn:remove(child)
	end
end

-- Coroutines ----------------------------------------------------------

--- Runs fn(...) in a new coroutine, in which asynchronous calls wait for
--- their results. Returns the coroutine.
function siv.spawn(fn, ...)
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(coerror(co, err), 0)
	end
	return co
end

local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		internal.report(coerror(co, err))
	end
end

local function needCoroutine(what, level)
	local _, main = coroutine.running()
	if main or not coroutine.isyieldable() then
		error(what .. ": pass a callback, or call from a coroutine (siv.spawn)", level + 1)
	end
end

-- Calls raw with a completion at argument `pos` and waits for it.
local function await(name, raw, pos, ...)
	needCoroutine(name, 3)
	local co = coroutine.running()
	local n = math.max(select("#", ...), pos)
	local args = table.pack(...)
	local state, results = "calling", nil
	args[pos] = function(...)
		if state == "waiting" then
			state = "done"
			resume(co, ...)
		else
			state = "done"
			results = table.pack(...)
		end
	end
	raw(table.unpack(args, 1, n))
	if state ~= "done" then
		state = "waiting"
		results = table.pack(coroutine.yield())
	end
	-- A failed result arrives as a trailing error.
	local last = results[results.n]
	if results.n > 0 and siv.is_error(last) then
		error(last, 0)
	end
	return table.unpack(results, 1, results.n)
end

-- Asynchronous calls take a callback, or in a coroutine wait for their
-- result when given none: local image = app:image_load{ path = p }.
for _, a in ipairs(internal.async) do
	local raw = siv[a.name]
	local function call(...)
		if type((select(a.pos, ...))) == "function" then
			return raw(...)
		end
		return await(a.name, raw, a.pos, ...)
	end
	siv[a.name] = call
	if a.owner then
		methods[a.owner][a.method] = call
	end
end

--- Waits `ms` milliseconds in a coroutine.
function methods.app.sleep(app, ms)
	needCoroutine("sleep", 2)
	local co = coroutine.running()
	app:timer_start(ms, function()
		resume(co)
	end)
	return coroutine.yield()
end
siv.sleep = methods.app.sleep

-- Jobs ------------------------------------------------------------------

local function wantsCompute(flags)
	if flags == nil then
		return false
	elseif flags == "compute" then
		return true
	elseif type(flags) == "table" then
		if flags.compute then
			return true
		end
		for _, f in ipairs(flags) do
			if f == "compute" then
				return true
			end
		end
		return false
	elseif type(flags) == "number" then
		return flags & 1 ~= 0
	end
	error("job_start: flags must be nil, \"compute\", or a list or set of names", 3)
end

--- Runs work(table.unpack(args)) on siv's worker pool (siv_job_start, D6):
--- "compute" for CPU-bound work, nil for blocking work. work runs in a
--- Lua state of its own on the worker, with the base, string, table,
--- math, and utf8 libraries and nothing of siv's; it may not use locals
--- from outside it (upvalues), and its arguments and results are copied:
--- nil, booleans, numbers, strings, and tables of them. done(true,
--- results...) or done(false, message) runs on the application's thread
--- at a safe point. Without done, it waits in the running coroutine and
--- returns the results, raising the job's error.
function methods.app.job_start(app, flags, work, args, done)
	local compute = wantsCompute(flags)
	if type(work) ~= "function" then
		error("job_start: work must be a function", 2)
	end
	if done ~= nil then
		internal.job_start(app, compute, work, args, done)
		return
	end
	needCoroutine("job_start", 2)
	local co = coroutine.running()
	internal.job_start(app, compute, work, args, function(...)
		resume(co, ...)
	end)
	local results = table.pack(coroutine.yield())
	if not results[1] then
		error(results[2], 0)
	end
	return table.unpack(results, 2, results.n)
end
siv.job_start = methods.app.job_start

-- Hot reload ----------------------------------------------------------
--
-- siv-lua --watch runs the main chunk again when it or a Lua module it
-- required changes. The chunk runs inside the running application:
-- siv.app_create returns that application and app:run returns at once.
-- Windows the previous run created are destroyed once the new run
-- succeeds, except those made inside siv.keep, which keeps any value
-- across runs. If the new run fails, its windows go and the old ones
-- stay.

local main -- { path, args, watch }
local reloading = false
local first_app
local kept = {}
local keeping = 0
local windows = {} -- windows of the current run, not kept
local file_modules = {} -- modules required from files: name -> path
-- Functions told about each reload: hook("begin") before the chunk runs,
-- hook("done") or hook("failed") after its windows were sorted out
-- (siv.view disposes what the previous run made, D45).
local reload_hooks = {}
internal.reload_hooks = reload_hooks

--- Returns the values kept under `key`, making them with make() the
--- first time: every value it returns, so a signal's getter and setter
--- keep together (siv.view, D45). Values survive hot reloads; windows
--- created inside make() are kept with them.
function siv.keep(key, make)
	local v = kept[key]
	if v == nil then
		keeping = keeping + 1
		local guard <close> = setmetatable({}, { __close = function()
			keeping = keeping - 1
		end })
		v = table.pack(make())
		kept[key] = v
	end
	return table.unpack(v, 1, v.n)
end

local function watching()
	return main ~= nil and main.watch
end

local app_create = siv.app_create
function siv.app_create(desc)
	if reloading and first_app then
		return first_app
	end
	local app = app_create(desc)
	if first_app == nil then
		first_app = app
		if watching() then
			internal.watch_start(app)
			internal.watch_add(main.path)
			for _, path in pairs(file_modules) do
				internal.watch_add(path)
			end
		end
	end
	return app
end

local run = siv.app_run
local function run_app(app)
	if reloading then
		return
	end
	return run(app)
end
siv.app_run = run_app
methods.app.run = run_app

local window_create = siv.window_create
local function create_window(app, desc)
	local w = window_create(app, desc)
	if watching() and keeping == 0 then
		windows[#windows + 1] = w
	end
	return w
end
siv.window_create = create_window
methods.app.window_create = create_window

local function destroy_windows(list)
	for _, w in ipairs(list) do
		pcall(w.destroy, w)
	end
end

local function load_main()
	local chunk, err = loadfile(main.path, "t")
	if not chunk then
		error(err, 0)
	end
	return chunk(table.unpack(main.args, 1, main.args.n))
end

--- Runs the main chunk again (siv-lua --watch calls this when a file
--- changes; an application may call it too, from a key binding say).
function siv.reload()
	if main == nil then
		error("siv.reload: no main chunk (run the application with siv-lua)", 2)
	end
	if reloading then
		return
	end
	for name in pairs(file_modules) do
		package.loaded[name] = nil
	end
	local old = windows
	windows = {}
	reloading = true
	for _, hook in ipairs(reload_hooks) do
		hook("begin")
	end
	local ok, err = xpcall(load_main, internal.traceback)
	reloading = false
	if ok then
		destroy_windows(old)
	else
		destroy_windows(windows)
		windows = old
	end
	for _, hook in ipairs(reload_hooks) do
		hook(ok and "done" or "failed")
	end
	if not ok then
		internal.report(err)
	end
end
internal.reload = siv.reload

local function format_error(err)
	if type(err) == "table" and err.traceback then
		return tostring(err) .. "\n" .. err.traceback
	end
	return tostring(err)
end

-- siv_lua_run: runs `path` as the main chunk with `...` as its arguments.
function internal.run_main(path, watch, ...)
	main = { path = path, args = table.pack(...), watch = watch }
	local dir = path:match("^(.*)/[^/]*$") or "."
	package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path
	if watch then
		-- Errors in callbacks are reported and the application goes on.
		siv.set_error_handler(function(err)
			io.stderr:write(format_error(err), "\n")
		end)
		local search = package.searchers[2]
		package.searchers[2] = function(name)
			local loader, where = search(name)
			if type(loader) == "function" then
				file_modules[name] = where
				if first_app then
					internal.watch_add(where)
				end
			end
			return loader, where
		end
	end
	load_main()
end

return siv
