/* siv.webview: the Lua module (Lua 5.5).
 *
 *     local siv = require("siv")
 *     local webview = require("siv.webview")
 *     local wv = webview.create(win, { on = { title = function(wv, ev) ... end } })
 *     win:update(function(txn, root) wv:view(txn, root, { layout = ... }) end)
 *     wv:load_uri("https://example.com")
 *
 * Windows, transactions, and nodes are siv's userdata; this module turns
 * them into C handles and back with siv.handle and siv.wrap (siv's D23),
 * so it needs no symbol from siv's Lua binding and loads beside siv.so or
 * inside siv-webview-lua. Callbacks run under lua_pcall; an error in one is
 * printed with a traceback and the event gets the default answer. */
#include <siv-webview.h>

#include <lauxlib.h>
#include <lua.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WEBVIEW_MT "siv.webview"
#define REQUEST_MT "siv.webview.request"
/* Registry keys: the siv module, and a table of web views by handle
 * holding each one's userdata and callbacks. */
static const char siv_module_key = 0, views_key = 0;

typedef struct {
    siv_webview handle;
} webview_ud;

typedef struct {
    siv_webview_request handle;
} request_ud;

/* What a C callback needs to reach Lua again. */
typedef struct {
    lua_State *L; /* the main thread */
    siv_webview handle;
    int ref; /* a function, for scripts and schemes */
} cb_ctx;

static lua_State *main_thread(lua_State *L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
    lua_State *m = lua_tothread(L, -1);
    lua_pop(L, 1);
    return m;
}

static int fail(lua_State *L, const char *what, siv_result r) {
    return luaL_error(L, "%s: %s", what, siv_result_name(r));
}

/* siv.<name>, pushed. */
static void push_siv_fn(lua_State *L, const char *name) {
    lua_rawgetp(L, LUA_REGISTRYINDEX, &siv_module_key);
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
}

/* The C handle of the siv userdata at idx, checked to be of `type`. */
static uint64_t check_handle(lua_State *L, int idx, const char *type) {
    idx = lua_absindex(L, idx);
    push_siv_fn(L, "handle");
    lua_pushvalue(L, idx);
    lua_call(L, 1, 2);
    const char *got = lua_tostring(L, -1);
    if (!lua_isinteger(L, -2) || !got || strcmp(got, type)) {
        lua_pop(L, 2);
        return (uint64_t)luaL_typeerror(L, idx, type);
    }
    uint64_t h = (uint64_t)lua_tointeger(L, -2);
    lua_pop(L, 2);
    return h;
}

static void push_handle(lua_State *L, const char *type, uint64_t h) {
    push_siv_fn(L, "wrap");
    lua_pushstring(L, type);
    lua_pushinteger(L, (lua_Integer)h);
    lua_call(L, 2, 1);
}

static siv_webview check_webview(lua_State *L, int idx) {
    webview_ud *u = luaL_checkudata(L, idx, WEBVIEW_MT);
    if (!u->handle) luaL_argerror(L, idx, "destroyed web view");
    return u->handle;
}

static const char *opt_lstring(lua_State *L, int table, const char *field, size_t *len) {
    lua_getfield(L, table, field);
    const char *s = luaL_optlstring(L, -1, NULL, len);
    lua_pop(L, 1);
    if (!s) *len = 0;
    return s;
}

/* Calls the function under the arguments on the stack with a traceback;
 * on error prints it. Leaves nresults values (nil on error). */
static int traceback(lua_State *L) {
    const char *msg = lua_tostring(L, 1);
    luaL_traceback(L, L, msg ? msg : luaL_tolstring(L, 1, NULL), 1);
    return 1;
}

static bool protected_call(lua_State *L, int nargs, int nresults) {
    int base = lua_gettop(L) - nargs;
    lua_pushcfunction(L, traceback);
    lua_insert(L, base);
    int st = lua_pcall(L, nargs, nresults, base);
    lua_remove(L, base);
    if (st != LUA_OK) {
        fprintf(stderr, "siv.webview: error in a callback: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
        for (int i = 0; i < nresults; i++) lua_pushnil(L);
        return false;
    }
    return true;
}

/* ---------- events ---------- */

static const char *const event_names[] = {"load", "progress", "title", "uri", "history", "message", "navigate", "new_window", "permission", "download", "notification", "close", "crashed", "load_failed"};
static const char *const load_states[] = {"started", "redirected", "committed", "finished"};
static const char *const permissions[] = {"other", "geolocation", "notifications", "media", "clipboard", "pointer_lock"};
static const char *const download_phases[] = {"started", "progress", "finished", "failed"};

static void set_lstring(lua_State *L, const char *field, const char *s, size_t len) {
    if (!s) return;
    lua_pushlstring(L, s, len);
    lua_setfield(L, -2, field);
}

static void set_bool(lua_State *L, const char *field, bool v) {
    lua_pushboolean(L, v);
    lua_setfield(L, -2, field);
}

static void push_event(lua_State *L, const siv_webview_event *e) {
    lua_createtable(L, 0, 12);
    lua_pushstring(L, event_names[e->type]);
    lua_setfield(L, -2, "type");
    set_lstring(L, "uri", e->uri, e->uri_len);
    set_lstring(L, "text", e->text, e->text_len);
    set_lstring(L, "name", e->name, e->name_len);
    set_lstring(L, "path", e->path, e->path_len);
    switch (e->type) {
    case SIV_WEBVIEW_EVENT_LOAD:
        lua_pushstring(L, load_states[e->load_state]);
        lua_setfield(L, -2, "load_state");
        break;
    case SIV_WEBVIEW_EVENT_PROGRESS:
        lua_pushnumber(L, e->progress);
        lua_setfield(L, -2, "progress");
        break;
    case SIV_WEBVIEW_EVENT_PERMISSION:
        lua_pushstring(L, permissions[e->permission]);
        lua_setfield(L, -2, "permission");
        lua_pushinteger(L, (lua_Integer)e->id);
        lua_setfield(L, -2, "id");
        break;
    case SIV_WEBVIEW_EVENT_DOWNLOAD:
        lua_pushstring(L, download_phases[e->download_phase]);
        lua_setfield(L, -2, "phase");
        lua_pushnumber(L, e->progress);
        lua_setfield(L, -2, "progress");
        lua_pushinteger(L, (lua_Integer)e->id);
        lua_setfield(L, -2, "id");
        break;
    default: break;
    }
    if (e->type == SIV_WEBVIEW_EVENT_NAVIGATE || e->type == SIV_WEBVIEW_EVENT_NEW_WINDOW) {
        set_bool(L, "main_frame", e->flags & SIV_WEBVIEW_MAIN_FRAME);
        set_bool(L, "user_gesture", e->flags & SIV_WEBVIEW_USER_GESTURE);
        set_bool(L, "redirect", e->flags & SIV_WEBVIEW_REDIRECT);
    }
    if (e->type == SIV_WEBVIEW_EVENT_HISTORY) {
        set_bool(L, "can_go_back", e->flags & SIV_WEBVIEW_CAN_GO_BACK);
        set_bool(L, "can_go_forward", e->flags & SIV_WEBVIEW_CAN_GO_FORWARD);
    }
}

/* Pushes views[handle] (a table: ud, on), or nil. */
static int push_entry(lua_State *L, siv_webview h) {
    lua_rawgetp(L, LUA_REGISTRYINDEX, &views_key);
    lua_rawgeti(L, -1, (lua_Integer)h);
    lua_remove(L, -2);
    return lua_type(L, -1);
}

static bool on_event(void *user_data, siv_webview webview, const siv_webview_event *e) {
    cb_ctx *c = user_data;
    lua_State *L = c->L;
    if ((size_t)e->type >= sizeof event_names / sizeof event_names[0]) return false;
    int top = lua_gettop(L);
    if (push_entry(L, webview) != LUA_TTABLE) goto done;
    lua_getfield(L, -1, "on");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, event_names[e->type]);
        lua_remove(L, -2);
    }
    if (!lua_isfunction(L, -1)) goto done;
    lua_getfield(L, -2, "ud");
    push_event(L, e);
    protected_call(L, 2, 1);
    bool answer = lua_toboolean(L, -1);
    lua_settop(L, top);
    return answer;
done:
    lua_settop(L, top);
    return false;
}

static void on_destroy(void *user_data) {
    cb_ctx *c = user_data;
    lua_State *L = c->L;
    if (push_entry(L, c->handle) == LUA_TTABLE) {
        lua_getfield(L, -1, "ud");
        webview_ud *u = lua_touserdata(L, -1);
        if (u) u->handle = 0;
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &views_key);
    lua_pushnil(L);
    lua_rawseti(L, -2, (lua_Integer)c->handle);
    lua_pop(L, 1);
    free(c);
}

/* ---------- web views ---------- */

static const struct {
    const char *name;
    siv_webview_flags flag;
} flag_names[] = {
    {"ephemeral", SIV_WEBVIEW_EPHEMERAL},
    {"developer_extras", SIV_WEBVIEW_DEVELOPER_EXTRAS},
    {"no_theme", SIV_WEBVIEW_NO_THEME},
    {"no_context_menu", SIV_WEBVIEW_NO_CONTEXT_MENU},
};

static siv_webview_flags check_flags(lua_State *L, int table) {
    siv_webview_flags flags = 0;
    lua_getfield(L, table, "flags");
    if (lua_isstring(L, -1)) {
        lua_createtable(L, 1, 0);
        lua_insert(L, -2);
        lua_rawseti(L, -2, 1);
    }
    if (lua_istable(L, -1)) {
        for (lua_Integer i = 1; lua_rawgeti(L, -1, i) != LUA_TNIL; i++) {
            const char *n = luaL_checkstring(L, -1);
            size_t k = 0;
            while (k < sizeof flag_names / sizeof flag_names[0] && strcmp(flag_names[k].name, n)) k++;
            if (k == sizeof flag_names / sizeof flag_names[0]) luaL_error(L, "siv.webview: unknown flag '%s'", n);
            flags |= flag_names[k].flag;
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    } else if (!lua_isnil(L, -1)) luaL_error(L, "siv.webview: flags is a string or a list of strings");
    lua_pop(L, 1);
    return flags;
}

/* webview.create(window, desc) */
static int l_create(lua_State *L) {
    siv_window window = check_handle(L, 1, "window");
    int has_desc = !lua_isnoneornil(L, 2);
    if (has_desc) luaL_checktype(L, 2, LUA_TTABLE);
    siv_webview_desc d = {.size = sizeof d};
    if (has_desc) {
        d.flags = check_flags(L, 2);
        d.data_dir = opt_lstring(L, 2, "data_dir", &d.data_dir_len);
        d.cache_dir = opt_lstring(L, 2, "cache_dir", &d.cache_dir_len);
        d.user_agent = opt_lstring(L, 2, "user_agent", &d.user_agent_len);
        lua_getfield(L, 2, "on");
        if (!lua_isnil(L, -1) && !lua_istable(L, -1) && !lua_isfunction(L, -1)) return luaL_error(L, "siv.webview: on is a table of functions by event name");
        lua_pop(L, 1);
        lua_getfield(L, 2, "zoom");
        d.zoom = luaL_optnumber(L, -1, 0);
        lua_getfield(L, 2, "inspector_port");
        d.inspector_port = (uint16_t)luaL_optinteger(L, -1, 0);
        lua_pop(L, 2);
    }
    cb_ctx *c = calloc(1, sizeof *c);
    if (!c) return fail(L, "siv.webview.create", SIV_ERROR_OUT_OF_MEMORY);
    c->L = main_thread(L);
    d.on_event = on_event;
    d.destroy = on_destroy;
    d.user_data = c;
    siv_webview h = 0;
    siv_result r = siv_webview_create(window, &d, &h);
    if (r != SIV_OK) {
        free(c);
        return fail(L, "siv.webview.create", r);
    }
    c->handle = h;
    webview_ud *u = lua_newuserdatauv(L, sizeof *u, 0);
    u->handle = h;
    luaL_setmetatable(L, WEBVIEW_MT);
    /* views[h] = { ud = u, on = desc.on } */
    lua_rawgetp(L, LUA_REGISTRYINDEX, &views_key);
    lua_createtable(L, 0, 2);
    lua_pushvalue(L, -3);
    lua_setfield(L, -2, "ud");
    if (has_desc) {
        lua_getfield(L, 2, "on");
        lua_setfield(L, -2, "on");
    }
    lua_rawseti(L, -2, (lua_Integer)h);
    lua_pop(L, 1);
    return 1;
}

/* wv:view(txn, parent) -> node */
static int l_view(lua_State *L) {
    siv_webview h = check_webview(L, 1);
    siv_txn txn = check_handle(L, 2, "txn");
    siv_node parent = check_handle(L, 3, "node");
    siv_node node = siv_webview_view(txn, parent, h);
    if (!node) return luaL_error(L, "siv.webview: view: the transaction failed");
    push_handle(L, "node", node);
    return 1;
}

static int l_node(lua_State *L) {
    siv_node n = siv_webview_get_node(check_webview(L, 1));
    if (n) push_handle(L, "node", n);
    else lua_pushnil(L);
    return 1;
}

static int l_destroy(lua_State *L) {
    webview_ud *u = luaL_checkudata(L, 1, WEBVIEW_MT);
    if (u->handle) siv_webview_destroy(u->handle);
    u->handle = 0;
    return 0;
}

static int l_load_uri(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 2, &len);
    siv_result r = siv_webview_load_uri(check_webview(L, 1), s, len);
    return r == SIV_OK ? 0 : fail(L, "load_uri", r);
}

static int l_load_html(lua_State *L) {
    size_t len, blen = 0;
    const char *s = luaL_checklstring(L, 2, &len);
    const char *base = luaL_optlstring(L, 3, NULL, &blen);
    siv_result r = siv_webview_load_html(check_webview(L, 1), s, len, base, base ? blen : 0);
    return r == SIV_OK ? 0 : fail(L, "load_html", r);
}

/* back, forward: return whether there was somewhere to go. */
static int l_go_back(lua_State *L) {
    siv_result r = siv_webview_go_back(check_webview(L, 1));
    if (r != SIV_OK && r != SIV_ERROR_BUSY) return fail(L, "go_back", r);
    lua_pushboolean(L, r == SIV_OK);
    return 1;
}

static int l_go_forward(lua_State *L) {
    siv_result r = siv_webview_go_forward(check_webview(L, 1));
    if (r != SIV_OK && r != SIV_ERROR_BUSY) return fail(L, "go_forward", r);
    lua_pushboolean(L, r == SIV_OK);
    return 1;
}

static int l_reload(lua_State *L) {
    siv_result r = siv_webview_reload(check_webview(L, 1));
    return r == SIV_OK ? 0 : fail(L, "reload", r);
}

static int l_stop(lua_State *L) {
    siv_result r = siv_webview_stop(check_webview(L, 1));
    return r == SIV_OK ? 0 : fail(L, "stop", r);
}

static int get_text(lua_State *L, siv_result (*get)(siv_webview, char *, size_t, size_t *), const char *what) {
    siv_webview h = check_webview(L, 1);
    char buf[1024];
    size_t len = 0;
    siv_result r = get(h, buf, sizeof buf, &len);
    if (r != SIV_OK) return fail(L, what, r);
    if (len <= sizeof buf) {
        lua_pushlstring(L, buf, len);
        return 1;
    }
    char *big = malloc(len);
    if (!big) return fail(L, what, SIV_ERROR_OUT_OF_MEMORY);
    r = get(h, big, len, &len);
    if (r == SIV_OK) lua_pushlstring(L, big, len);
    free(big);
    return r == SIV_OK ? 1 : fail(L, what, r);
}

static int l_uri(lua_State *L) { return get_text(L, siv_webview_get_uri, "uri"); }
static int l_title(lua_State *L) { return get_text(L, siv_webview_get_title, "title"); }

static int l_state(lua_State *L) {
    siv_webview_state st = {.size = sizeof st};
    siv_result r = siv_webview_get_state(check_webview(L, 1), &st);
    if (r != SIV_OK) return fail(L, "state", r);
    lua_createtable(L, 0, 5);
    set_bool(L, "can_go_back", st.flags & SIV_WEBVIEW_CAN_GO_BACK);
    set_bool(L, "can_go_forward", st.flags & SIV_WEBVIEW_CAN_GO_FORWARD);
    set_bool(L, "loading", st.flags & SIV_WEBVIEW_LOADING);
    lua_pushnumber(L, st.progress);
    lua_setfield(L, -2, "progress");
    lua_pushnumber(L, st.zoom);
    lua_setfield(L, -2, "zoom");
    return 1;
}

static int l_set_zoom(lua_State *L) {
    siv_result r = siv_webview_set_zoom(check_webview(L, 1), luaL_checknumber(L, 2));
    return r == SIV_OK ? 0 : fail(L, "set_zoom", r);
}

static int l_set_color_scheme(lua_State *L) {
    static const char *const names[] = {"follow", "light", "dark", NULL};
    static const siv_color_scheme schemes[] = {SIV_COLOR_SCHEME_FOLLOW, SIV_COLOR_SCHEME_LIGHT, SIV_COLOR_SCHEME_DARK};
    siv_result r = siv_webview_set_color_scheme(check_webview(L, 1), schemes[luaL_checkoption(L, 2, NULL, names)]);
    return r == SIV_OK ? 0 : fail(L, "set_color_scheme", r);
}

static void ctx_free(void *p) {
    cb_ctx *c = p;
    luaL_unref(c->L, LUA_REGISTRYINDEX, c->ref);
    free(c);
}

static cb_ctx *ref_function(lua_State *L, int idx) {
    cb_ctx *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->L = main_thread(L);
    lua_pushvalue(L, idx);
    c->ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return c;
}

/* fn(json) on success, fn(nil, message) on an exception. */
static void on_script(void *user_data, siv_result result, const char *json, size_t len) {
    cb_ctx *c = user_data;
    lua_State *L = c->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, c->ref);
    if (result == SIV_OK) {
        lua_pushlstring(L, json, len);
        lua_pushnil(L);
    } else {
        lua_pushnil(L);
        if (json) lua_pushlstring(L, json, len);
        else lua_pushstring(L, siv_result_name(result));
    }
    protected_call(L, 2, 0);
}

/* wv:run_script(js [, fn(json, err)]) */
static int l_run_script(lua_State *L) {
    siv_webview h = check_webview(L, 1);
    size_t len;
    const char *js = luaL_checklstring(L, 2, &len);
    cb_ctx *c = NULL;
    if (!lua_isnoneornil(L, 3)) {
        luaL_checktype(L, 3, LUA_TFUNCTION);
        if (!(c = ref_function(L, 3))) return fail(L, "run_script", SIV_ERROR_OUT_OF_MEMORY);
    }
    siv_result r = siv_webview_run_script(h, js, len, c ? on_script : NULL, c ? ctx_free : NULL, c);
    if (r != SIV_OK) {
        if (c) ctx_free(c);
        return fail(L, "run_script", r);
    }
    return 0;
}

static int l_add_message_handler(lua_State *L) {
    size_t len;
    const char *n = luaL_checklstring(L, 2, &len);
    siv_result r = siv_webview_add_message_handler(check_webview(L, 1), n, len);
    return r == SIV_OK ? 0 : fail(L, "add_message_handler", r);
}

static int l_post_message(lua_State *L) {
    size_t len;
    const char *json = luaL_checklstring(L, 2, &len);
    siv_result r = siv_webview_post_message(check_webview(L, 1), json, len);
    return r == SIV_OK ? 0 : fail(L, "post_message", r);
}

static int l_permission_reply(lua_State *L) {
    siv_webview h = check_webview(L, 1);
    lua_Integer id = luaL_checkinteger(L, 2);
    luaL_checkany(L, 3);
    siv_result r = siv_webview_permission_reply(h, (uint64_t)id, lua_toboolean(L, 3));
    return r == SIV_OK ? 0 : fail(L, "permission_reply", r);
}

static int l_download_cancel(lua_State *L) {
    siv_result r = siv_webview_download_cancel(check_webview(L, 1), (uint64_t)luaL_checkinteger(L, 2));
    return r == SIV_OK ? 0 : fail(L, "download_cancel", r);
}

static int l_tostring(lua_State *L) {
    webview_ud *u = luaL_checkudata(L, 1, WEBVIEW_MT);
    lua_pushfstring(L, "siv.webview: %I", (lua_Integer)u->handle);
    return 1;
}

/* ---------- schemes ---------- */

static int request_check(lua_State *L, request_ud **out) {
    request_ud *u = luaL_checkudata(L, 1, REQUEST_MT);
    if (!u->handle) return luaL_argerror(L, 1, "request already answered");
    *out = u;
    return 0;
}

/* req:finish(body [, content_type [, status]]) */
static int l_request_finish(lua_State *L) {
    request_ud *u;
    request_check(L, &u);
    size_t len, tlen = 0;
    const char *body = luaL_checklstring(L, 2, &len);
    const char *type = luaL_optlstring(L, 3, "text/html", &tlen);
    lua_Integer status = luaL_optinteger(L, 4, 200);
    siv_result r = siv_webview_request_finish(u->handle, (uint32_t)status, type, tlen, (const uint8_t *)body, len);
    u->handle = 0;
    return r == SIV_OK ? 0 : fail(L, "finish", r);
}

static int l_request_fail(lua_State *L) {
    request_ud *u;
    request_check(L, &u);
    siv_result r = siv_webview_request_fail(u->handle);
    u->handle = 0;
    return r == SIV_OK ? 0 : fail(L, "fail", r);
}

/* fn(request, uri, method) */
static void on_scheme(void *user_data, siv_webview_request request, const char *uri, size_t uri_len, const char *method, size_t method_len) {
    cb_ctx *c = user_data;
    lua_State *L = c->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, c->ref);
    request_ud *u = lua_newuserdatauv(L, sizeof *u, 0);
    u->handle = request;
    luaL_setmetatable(L, REQUEST_MT);
    lua_pushlstring(L, uri, uri_len);
    lua_pushlstring(L, method, method_len);
    if (!protected_call(L, 3, 0)) (void)siv_webview_request_fail(request);
}

/* webview.register_scheme(app, scheme, fn(req, uri, method)) */
static int l_register_scheme(lua_State *L) {
    siv_app app = check_handle(L, 1, "app");
    size_t len;
    const char *scheme = luaL_checklstring(L, 2, &len);
    luaL_checktype(L, 3, LUA_TFUNCTION);
    cb_ctx *c = ref_function(L, 3);
    if (!c) return fail(L, "register_scheme", SIV_ERROR_OUT_OF_MEMORY);
    siv_result r = siv_webview_register_scheme(app, scheme, len, on_scheme, ctx_free, c);
    if (r != SIV_OK) {
        ctx_free(c);
        return fail(L, "register_scheme", r);
    }
    return 0;
}

static int l_available(lua_State *L) {
    lua_pushboolean(L, siv_webview_engine_available(SIV_WEBVIEW_ENGINE_AUTO) == SIV_OK);
    return 1;
}

static const luaL_Reg webview_methods[] = {
    {"view", l_view},
    {"node", l_node},
    {"destroy", l_destroy},
    {"load_uri", l_load_uri},
    {"load_html", l_load_html},
    {"go_back", l_go_back},
    {"go_forward", l_go_forward},
    {"reload", l_reload},
    {"stop", l_stop},
    {"uri", l_uri},
    {"title", l_title},
    {"state", l_state},
    {"set_zoom", l_set_zoom},
    {"set_color_scheme", l_set_color_scheme},
    {"run_script", l_run_script},
    {"add_message_handler", l_add_message_handler},
    {"post_message", l_post_message},
    {"permission_reply", l_permission_reply},
    {"download_cancel", l_download_cancel},
    {NULL, NULL},
};

static const luaL_Reg request_methods[] = {
    {"finish", l_request_finish},
    {"fail", l_request_fail},
    {NULL, NULL},
};

static const luaL_Reg module_fns[] = {
    {"create", l_create},
    {"register_scheme", l_register_scheme},
    {"available", l_available},
    {NULL, NULL},
};

int luaopen_siv_webview(lua_State *L) {
    lua_getglobal(L, "require");
    lua_pushliteral(L, "siv");
    lua_call(L, 1, 1);
    lua_getfield(L, -1, "wrap");
    if (!lua_isfunction(L, -1)) return luaL_error(L, "siv.webview needs a siv with siv.handle and siv.wrap");
    lua_pop(L, 1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &siv_module_key);
    lua_newtable(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &views_key);

    luaL_newmetatable(L, WEBVIEW_MT);
    luaL_newlib(L, webview_methods);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, l_tostring);
    lua_setfield(L, -2, "__tostring");
    lua_pop(L, 1);
    luaL_newmetatable(L, REQUEST_MT);
    luaL_newlib(L, request_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    luaL_newlib(L, module_fns);
    lua_pushinteger(L, (lua_Integer)siv_webview_version());
    lua_setfield(L, -2, "version");
    return 1;
}
