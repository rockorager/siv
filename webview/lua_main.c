/* siv-webview-lua: siv-lua with require("siv.webview").
 *
 *     siv-webview-lua [--watch] app.lua [ARGS...]
 *
 * libsiv-lua's states load Lua source only (no C modules), so this runner
 * puts the module in package.preload. A program with its own Lua 5.5
 * loads lib/lua/5.5/siv/webview.so beside siv.so instead. */
#include <siv_lua.h>

#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>
#include <string.h>

int luaopen_siv_webview(lua_State *L);

int main(int argc, char **argv) {
    unsigned flags = 0;
    int first = 1;
    if (argc > 1 && !strcmp(argv[1], "--watch")) flags |= SIV_LUA_WATCH, first = 2;
    if (argc <= first) {
        fprintf(stderr, "usage: %s [--watch] app.lua [ARGS...]\n", argv[0]);
        return 2;
    }
    lua_State *L = siv_lua_new(~0);
    if (!L) {
        fprintf(stderr, "siv-webview-lua: out of memory\n");
        return 1;
    }
    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L, luaopen_siv_webview);
    lua_setfield(L, -2, "siv.webview");
    lua_pop(L, 1);
    int status = siv_lua_run(L, argv[first], argc - first - 1, (const char *const *)argv + first + 1, flags);
    lua_close(L);
    return status;
}
