/* libsiv-lua: siv for Lua 5.5 (D23).
 *
 * libsiv-lua embeds Lua 5.5 and exports its C API (lua.h, lauxlib.h, and
 * lualib.h next to this header), so a host program uses Lua through it.
 * Lua code reaches siv only through require("siv"); nothing is added to
 * the global table.
 *
 *     lua_State *L = siv_lua_new(~0);
 *     int status = siv_lua_run(L, "app.lua", argc - 1, argv + 1, 0);
 *     lua_close(L);
 *
 * Only the core and an allowlist of standard libraries are compiled in:
 * base, package, coroutine, table, string, math, utf8, os, and io. The
 * debug library is not, and `require` loads Lua source only: loading C
 * modules is disabled. */
#ifndef SIV_LUA_H
#define SIV_LUA_H

#include <lua.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opens the siv module and returns it. siv_lua_new makes require("siv")
 * call it; a state created otherwise can set it in package.preload. */
int luaopen_siv(lua_State *L);

/* A new Lua state with the compiled-in standard libraries whose bits are
 * set in `libs` (LUA_GLIBK, LUA_LOADLIBK, ... from lualib.h; ~0 for all
 * of them) and require("siv"). NULL when memory runs out. Close it with
 * lua_close, which destroys every siv application it still holds. */
lua_State *siv_lua_new(int libs);

/* Reload the main chunk when it or a Lua module it required changes. */
#define SIV_LUA_WATCH 1u

/* Runs the Lua file at `path` as an application's main chunk, with the
 * `argc` strings of `argv` as its arguments (`...`), on the calling
 * thread. With SIV_LUA_WATCH, a change to a watched file runs the chunk
 * again inside the running application (see siv.reload in the Lua
 * reference), and errors in callbacks are reported without ending the
 * application. Returns 0 on success; otherwise prints the error with a
 * traceback to stderr and returns 1. */
int siv_lua_run(lua_State *L, const char *path, int argc, const char *const *argv, unsigned flags);

#ifdef __cplusplus
}
#endif

#endif
