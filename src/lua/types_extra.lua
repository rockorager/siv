-- What the prelude (src/lua/prelude.lua) adds to the generated module.

---An error raised for a siv result code.
---@class siv.error
---@field code string The result without its error_ prefix: "busy", "invalid_handle", ...
---@field result integer The siv_result value.
---@field func string The C function that failed.
---@field message string Where and what: "app.lua:12: siv_txn_begin: SIV_ERROR_BUSY".
---@field traceback? string Added when the error passes through a callback or coroutine.

---Whether `v` is an error raised for a siv result code.
---@param v any
---@return boolean
function siv.is_error(v) end

---Sets the function that hears errors raised by callbacks, or with nil restores
---the default: the error ends app:run (or the binding call that ran the
---callback) and is raised from it.
---@param fn? fun(err: siv.error|string)
function siv.set_error_handler(fn) end

---Runs fn(...) in a new coroutine, in which asynchronous calls given no callback
---wait for their results. Returns the coroutine.
---@param fn async fun(...)
---@return thread
function siv.spawn(fn, ...) end

---Waits `ms` milliseconds in a coroutine.
---@async
---@param app siv.app
---@param ms integer
function siv.sleep(app, ms) end

---Waits `ms` milliseconds in a coroutine.
---@async
---@param ms integer
function app:sleep(ms) end

---Runs work(table.unpack(args)) on siv's worker pool: flags "compute" for
---CPU-bound work, nil for blocking work. work runs in a Lua state of its own
---with the base, string, table, math, and utf8 libraries and nothing of siv's;
---it may not use locals from outside it, and its arguments and results are
---copied (nil, booleans, numbers, strings, and tables of them). done(true,
---results...) or done(false, message) runs at a safe point on the
---application's thread; without done, it waits in the running coroutine and
---returns the results, raising the job's error.
---@param flags? "compute"|string[]|table<string, boolean>
---@param work fun(...): ...
---@param args? any[]
---@param done? fun(ok: boolean, ...)
---@return ...
function app:job_start(flags, work, args, done) end

---app:job_start as a function of the application.
---@param app siv.app
---@param flags? "compute"|string[]|table<string, boolean>
---@param work fun(...): ...
---@param args? any[]
---@param done? fun(ok: boolean, ...)
---@return ...
function siv.job_start(app, flags, work, args, done) end

---Runs fn(txn, root, ...) in a transaction on the window and commits it; if fn
---raises, the transaction is aborted and the error goes on. Returns what fn
---returns.
---@param fn fun(txn: siv.txn, root: siv.node, ...): ...
---@return ...
function window:update(fn, ...) end

---Returns the value kept under `key`, making it with make() the first time.
---Values survive hot reloads (siv-lua --watch); windows created inside make()
---are kept with them.
---@generic T
---@param key any
---@param make fun(): T
---@return T
function siv.keep(key, make) end

---Runs the main chunk again inside the running application (siv-lua --watch
---does when a file changes). Windows the previous run created are destroyed
---once the new run succeeds, except those made in siv.keep.
function siv.reload() end

---The methods of each handle type, by type name ("node", "window", ...), for
---extending them.
---@type table<string, table<string, function>>
siv.methods = {}

---Iterates over a node's children, first to last, as of the latest operation.
---@return fun(): siv.node?
function node:children() end

---Removes every child of `node`.
---@param node siv.node
function txn:clear(node) end
