-- What src/lua/view.lua defines, besides the builders generated below.

---Fine-grained reactive UI over siv's retained tree (D45), in the style of
---SolidJS. Components are functions that run once and build real nodes with
---the ui table; a property given as a function is a binding that sets that
---node's property again when the signals it read change. Read signals inside
---functions: a read while building, outside one, raises an error rather than
---leaving a value that never updates (view.peek reads one on purpose).
---@class siv.view
local view = {}

---Builders, one per siv builder (txn:flex(parent, desc, props) is
---ui.flex(desc, props, children)): they build under the component's current
---parent, in its transaction. children(node) builds the new node's children.
---@class siv.view.ui
local ui = {}
view.ui = ui

---@class siv.view.signal_options
---@field equals? false|fun(a: any, b: any): boolean When a new value counts as unchanged: == by default; false notifies on every set.

---A signal: its getter and setter. Reading the getter in a binding, memo, or
---effect subscribes it; setting a value equal to the current one does nothing.
---@generic T
---@param value T
---@param opts? siv.view.signal_options
---@return fun(): T get
---@return fun(value: T) set
function view.signal(value, opts) end

---A derived value: fn runs now and again when what it read changes; what
---reads the memo updates only when its value changes.
---@generic T
---@param fn fun(): T
---@param opts? siv.view.signal_options
---@return fun(): T
function view.memo(fn, opts) end

---Runs fn(previous) after the current flush's transactions commit, and again
---whenever what it read changes, with what it returned last time.
---@param fn fun(previous: any): any
---@param value? any The first `previous`.
function view.effect(fn, value) end

---Runs fn once, untracked, after the nodes built with it are committed.
---@param fn fun()
function view.on_mount(fn) end

---Runs fn when the current scope is disposed, or before its computation runs
---again.
---@param fn fun()
function view.on_cleanup(fn) end

---Runs fn(...) with the signal writes in it flushed together when it returns.
---Callbacks are batches already.
---@return ...
function view.batch(fn, ...) end

---Runs fn(...) without subscribing to what it reads.
---@return ...
function view.untrack(fn, ...) end

---The current value of a getter, without subscribing: for reading a signal
---once while building, on purpose.
---@generic T
---@param get fun(): T
---@return T
function view.peek(get) end

---Runs fn(dispose) in a scope that lives until dispose() is called.
---@generic T
---@param fn fun(dispose: fun()): T
---@return T
function view.root(fn) end

---Live computations and subscriptions, to check that removed subtrees leave
---none behind.
---@return { computations: integer, subscriptions: integer }
function view.stats() end

---Builds Component(...) under target (a window's root, or a node) in one
---transaction; returns a function that removes it and disposes its effects.
---Mounting again on the same target replaces the previous mount, keeping
---focus, editors' text and selection, and scroll offsets of nodes with the
---same key path (props.key): how a hot reload rebuilds a kept window.
---@param target siv.window|siv.node
---@param Component fun(...)
---@return fun() dispose
function view.mount(target, Component, ...) end

---Shows Then(when) while when() is truthy, else Else(when), swapping the
---subtrees and their effects when its truthiness changes.
---@param when fun(): any
---@param Then fun(when: fun(): any)
---@param Else? fun(when: fun(): any)
function view.show(when, Then, Else) end

---Shows cases[key()](key) or fallback(key), swapping subtrees when key()
---changes.
---@param key fun(): any
---@param cases table<any, fun(key: any)>
---@param fallback? fun(key: any)
function view.switch(key, cases, fallback) end

---@class siv.view.each_options
---@field key? fun(item: any): any The row's key; the item itself by default.

---Builds Row(item, index) for each item of list(), keyed: rows of new keys
---are built, rows of keys gone are removed with their effects, and the rest
---keep their nodes, moved only where the order changed.
---@generic T
---@param list fun(): T[]
---@param Row fun(item: T, index: fun(): integer)
---@param opts? siv.view.each_options
function view.each(list, Row, opts) end

---A virtualized view's descriptor with a row builder: row(item, index, depth)
---builds each row node's content once, with getters, and recycled rows only
---get new values. items, a getter for an array, sets the count and passes
---items[index + 1] as the item.
---@class siv.view.view_desc: siv.view_desc
---@field row? fun(item: fun(): any, index: fun(): integer, depth: fun(): integer)
---@field items? fun(): any[]
