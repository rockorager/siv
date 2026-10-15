/* The siv side of a web view: its frame slot and node, the node's input
 * handlers, its events to the application, and the public calls, which
 * an engine (swv_engine) carries out. */
#define _GNU_SOURCE
#include "swv.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

swv_handles swv_webviews;
swv_handles swv_requests;
static swv_app *apps;

/* ---------- handles ---------- */

uint64_t swv_handle_insert(swv_handles *h, void *p) {
    uint32_t i = 0;
    while (i < h->len && h->items[i]) i++;
    if (i == h->len) {
        if (h->len == h->cap) {
            uint32_t cap = h->cap ? h->cap * 2 : 16;
            void **items = realloc(h->items, cap * sizeof *items);
            if (!items) return 0;
            h->items = items;
            uint32_t *gens = realloc(h->gens, cap * sizeof *gens);
            if (!gens) return 0;
            h->gens = gens;
            for (uint32_t k = h->cap; k < cap; k++) h->items[k] = NULL, h->gens[k] = 0;
            h->cap = cap;
        }
        h->len++;
    }
    h->items[i] = p;
    h->gens[i]++;
    return ((uint64_t)h->gens[i] << 32) | (uint64_t)(i + 1);
}

void *swv_handle_get(const swv_handles *h, uint64_t handle) {
    uint32_t i = (uint32_t)handle;
    if (i == 0 || i > h->len) return NULL;
    if (h->gens[i - 1] != (uint32_t)(handle >> 32)) return NULL;
    return h->items[i - 1];
}

void swv_handle_remove(swv_handles *h, uint64_t handle) {
    if (!swv_handle_get(h, handle)) return;
    h->items[(uint32_t)handle - 1] = NULL;
}

/* ---------- applications ---------- */

static const swv_engine *engines[] = {&swv_engine_wpe};

static const swv_engine *pick_engine(siv_webview_engine want) {
    for (size_t i = 0; i < sizeof engines / sizeof *engines; i++) {
        if (want != SIV_WEBVIEW_ENGINE_AUTO && engines[i]->id != want) continue;
        if (engines[i]->available() == SIV_OK) return engines[i];
    }
    return NULL;
}

swv_app *swv_app_get(siv_app app, bool create) {
    for (swv_app *a = apps; a; a = a->next)
        if (a->app == app) return a;
    if (!create) return NULL;
    swv_app *a = calloc(1, sizeof *a);
    if (!a) return NULL;
    a->app = app;
    a->next = apps;
    apps = a;
    return a;
}

/* Frees an application's state once it has no web views and no schemes
 * (schemes keep it, so they apply to web views created later). */
void swv_app_release(swv_app *a) {
    if (a->webviews > 0 || a->schemes) return;
    if (a->engine) a->engine->app_fini(a);
    swv_glib_loop_stop(a->loop);
    for (swv_app **p = &apps; *p; p = &(*p)->next)
        if (*p == a) {
            *p = a->next;
            break;
        }
    free(a);
}

static siv_result app_engine(swv_app *a, siv_webview_engine want) {
    if (a->engine) return want == SIV_WEBVIEW_ENGINE_AUTO || a->engine->id == want ? SIV_OK : SIV_ERROR_UNSUPPORTED;
    const swv_engine *e = pick_engine(want);
    if (!e) return SIV_ERROR_UNSUPPORTED;
    if (!a->loop) a->loop = swv_glib_loop_start(a->app);
    siv_result r = e->app_init(a);
    if (r != SIV_OK) return r;
    a->engine = e;
    for (swv_scheme *s = a->schemes; s; s = s->next) e->scheme_added(a, s);
    return SIV_OK;
}

/* ---------- events ---------- */

bool swv_emit(swv_webview *wv, const siv_webview_event *event) {
    if (!wv->on_event || wv->dead) return false;
    siv_webview_event e = *event;
    e.size = sizeof e;
    return wv->on_event(wv->user_data, wv->handle, &e);
}

/* ---------- the node ---------- */

static swv_webview *get(siv_webview handle) { return swv_handle_get(&swv_webviews, handle); }

/* What the slot's callbacks need, fixed at creation: the compositor
 * thread reads it, so it never changes, and the slot's destroy-notify
 * frees it after the last frame came back. */
struct slot_ctx {
    siv_app app;
    siv_webview handle;
};

struct released {
    siv_webview handle;
    uint64_t key;
};

static void released_on_main(void *user_data) {
    struct released *r = user_data;
    swv_webview *wv = get(r->handle);
    if (wv && wv->engine) wv->engine->released(wv, r->key);
}

/* siv's compositor thread: a frame came back; the engine takes it back on
 * the application's thread. */
static void on_release(void *user_data, siv_external slot, uint64_t key) {
    (void)slot;
    struct slot_ctx *c = user_data;
    struct released *r = malloc(sizeof *r);
    if (!r) return;
    *r = (struct released){.handle = c->handle, .key = key};
    if (siv_post(c->app, released_on_main, free, r) != SIV_OK) free(r);
}

static void on_slot_event(void *user_data, siv_external slot, const siv_external_event *e) {
    (void)slot;
    struct slot_ctx *c = user_data;
    swv_webview *wv = get(c->handle);
    if (!wv || !wv->engine) return;
    if (e->type == SIV_EXTERNAL_EVENT_TYPE_CONFIGURE) wv->engine->configure(wv, e->width, e->height, e->scale);
    else if (e->type == SIV_EXTERNAL_EVENT_TYPE_PRESENTED) wv->engine->presented(wv, e->key);
    else if (e->type == SIV_EXTERNAL_EVENT_TYPE_RELEASED) wv->engine->released(wv, e->key);
}

static siv_event_result on_input(void *user_data, siv_node node, const siv_event *e) {
    (void)node;
    swv_webview *wv = get((siv_webview)(uintptr_t)user_data);
    if (!wv || !wv->engine) return SIV_EVENT_RESULT_PASS;
    return wv->engine->input(wv, e);
}

siv_result swv_submit(swv_webview *wv, const siv_external_frame_desc *frame) {
    return wv->slot ? siv_external_submit(wv->slot, frame) : SIV_ERROR_UNAVAILABLE;
}

void swv_set_cursor(swv_webview *wv, siv_cursor cursor) {
    if (!wv->node || cursor == wv->cursor) return;
    siv_txn txn;
    if (siv_txn_begin(wv->window, &txn) != SIV_OK) return;
    siv_set_cursor(txn, wv->node, cursor);
    if (siv_txn_commit(txn) == SIV_OK) wv->cursor = cursor;
}

void swv_set_text_input(swv_webview *wv, const siv_text_input_desc *desc) {
    if (!wv->node) return;
    siv_txn txn;
    if (siv_txn_begin(wv->window, &txn) != SIV_OK) return;
    siv_set_text_input(txn, wv->node, desc);
    (void)siv_txn_commit(txn);
}

void swv_set_accessible_embed(swv_webview *wv, const char *plug) {
    if (!wv->node) return;
    siv_txn txn;
    if (siv_txn_begin(wv->window, &txn) != SIV_OK) return;
    siv_set_accessible_embed(txn, wv->node, plug ? plug : "", plug ? strlen(plug) : 0);
    (void)siv_txn_commit(txn);
}

bool swv_theme_dark(swv_webview *wv) {
    siv_color bg;
    if (siv_window_get_color(wv->window, SIV_COLOR_TOKEN_WINDOW_BG, &bg) != SIV_OK) return false;
    /* Relative luminance of the sRGB background, roughly. */
    return 0.2126f * bg.r + 0.7152f * bg.g + 0.0722f * bg.b < 0.5f;
}

/* ---------- public calls ---------- */

uint32_t siv_webview_version(void) {
    return SIV_MAKE_VERSION(SIV_WEBVIEW_VERSION_MAJOR, SIV_WEBVIEW_VERSION_MINOR, SIV_WEBVIEW_VERSION_PATCH);
}

siv_result siv_webview_engine_available(siv_webview_engine engine) {
    return pick_engine(engine) ? SIV_OK : SIV_ERROR_UNSUPPORTED;
}

static char *dup_str(const char *s, size_t len) {
    char *d = malloc(len + 1);
    if (!d) return NULL;
    if (len) memcpy(d, s, len);
    d[len] = 0;
    return d;
}

siv_result siv_webview_create(siv_window window, const siv_webview_desc *desc, siv_webview *out) {
    siv_webview_desc d = {0};
    if (desc) {
        if (desc->size < offsetof(siv_webview_desc, flags)) return SIV_ERROR_INVALID_ARGUMENT;
        memcpy(&d, desc, desc->size < sizeof d ? desc->size : sizeof d);
    }
    d.size = sizeof d;
    if (!out) {
        if (d.destroy) d.destroy(d.user_data);
        return SIV_ERROR_INVALID_ARGUMENT;
    }
    *out = 0;
    siv_app app = siv_window_get_app(window);
    swv_app *a = app ? swv_app_get(app, true) : NULL;
    siv_result r = a ? app_engine(a, d.engine) : SIV_ERROR_INVALID_HANDLE;
    swv_webview *wv = r == SIV_OK ? calloc(1, sizeof *wv) : NULL;
    if (r == SIV_OK && !wv) r = SIV_ERROR_OUT_OF_MEMORY;
    if (r != SIV_OK) {
        if (a) swv_app_release(a);
        if (d.destroy) d.destroy(d.user_data);
        return r;
    }
    wv->app = a;
    wv->window = window;
    wv->engine = a->engine;
    wv->on_event = d.on_event;
    wv->destroy = d.destroy;
    wv->user_data = d.user_data;
    wv->flags = d.flags;
    wv->background = d.background;
    wv->scheme = SIV_COLOR_SCHEME_FOLLOW;
    wv->handle = swv_handle_insert(&swv_webviews, wv);
    a->webviews++;
    struct slot_ctx *ctx = wv->handle ? malloc(sizeof *ctx) : NULL;
    if (ctx) *ctx = (struct slot_ctx){.app = app, .handle = wv->handle};
    r = ctx ? siv_external_create(window, SIV_DESC(siv_external_desc, .user_data = ctx, .on_event = on_slot_event, .destroy = free, .release = on_release), &wv->slot) : SIV_ERROR_OUT_OF_MEMORY;
    if (r == SIV_OK) r = wv->engine->create(wv, &d);
    if (r != SIV_OK) {
        wv->engine = NULL;
        siv_webview_destroy(wv->handle);
        return r;
    }
    wv->dark = swv_theme_dark(wv);
    if (!(wv->flags & SIV_WEBVIEW_NO_THEME)) wv->engine->set_dark(wv, wv->dark);
    *out = wv->handle;
    return SIV_OK;
}

void siv_webview_destroy(siv_webview webview) {
    swv_webview *wv = get(webview);
    if (!wv) return;
    wv->dead = true;
    if (wv->engine) wv->engine->destroy(wv);
    swv_handle_remove(&swv_webviews, webview);
    if (wv->slot) siv_external_destroy(wv->slot);
    if (wv->destroy) wv->destroy(wv->user_data);
    swv_app *a = wv->app;
    a->webviews--;
    free(wv);
    swv_app_release(a);
}

siv_node siv_webview_view(siv_txn txn, siv_node parent, siv_webview webview) {
    swv_webview *wv = get(webview);
    if (!wv) {
        siv_txn_fail(txn, SIV_ERROR_INVALID_HANDLE);
        return 0;
    }
    siv_color bg = wv->background;
    if (bg.a <= 0) (void)siv_window_get_color(wv->window, SIV_COLOR_TOKEN_WINDOW_BG, &bg);
    siv_node n = siv_external_view(txn, parent, SIV_DESC(siv_external_view_desc, .external = wv->slot, .fit = SIV_FIT_FILL, .background = bg));
    if (!n) return 0;
    void *id = (void *)(uintptr_t)wv->handle;
    siv_set_semantics(txn, n, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_DOCUMENT, .label = SIV_STR("Web page"), .flags = SIV_SEMANTICS_FOCUSABLE));
    static const siv_event_type kinds[] = {SIV_EVENT_TYPE_POINTER, SIV_EVENT_TYPE_SCROLL, SIV_EVENT_TYPE_KEY, SIV_EVENT_TYPE_FOCUS, SIV_EVENT_TYPE_TOUCH, SIV_EVENT_TYPE_TEXT_INPUT, SIV_EVENT_TYPE_GESTURE};
    for (size_t i = 0; i < sizeof kinds / sizeof *kinds; i++) siv_on(txn, n, kinds[i], on_input, NULL, id);
    if (wv->node && wv->node != n) siv_remove(txn, wv->node);
    wv->node = n;
    wv->cursor = SIV_CURSOR_AUTO;
    return n;
}

siv_node siv_webview_get_node(siv_webview webview) {
    swv_webview *wv = get(webview);
    return wv ? wv->node : 0;
}

#define WV(h)                                       \
    swv_webview *wv = get(h);                       \
    if (!wv || !wv->engine) return SIV_ERROR_INVALID_HANDLE

siv_result siv_webview_load_uri(siv_webview webview, const char *uri, size_t uri_len) {
    WV(webview);
    if (!uri || !uri_len) return SIV_ERROR_INVALID_ARGUMENT;
    char *s = dup_str(uri, uri_len);
    if (!s) return SIV_ERROR_OUT_OF_MEMORY;
    wv->engine->load_uri(wv, s);
    free(s);
    return SIV_OK;
}

siv_result siv_webview_load_html(siv_webview webview, const char *html, size_t html_len, const char *base_uri, size_t base_uri_len) {
    WV(webview);
    if (!html && html_len) return SIV_ERROR_INVALID_ARGUMENT;
    char *base = base_uri_len ? dup_str(base_uri, base_uri_len) : NULL;
    if (base_uri_len && !base) return SIV_ERROR_OUT_OF_MEMORY;
    wv->engine->load_html(wv, html ? html : "", html_len, base);
    free(base);
    return SIV_OK;
}

siv_result siv_webview_go_back(siv_webview webview) {
    WV(webview);
    wv->engine->go_back(wv);
    return SIV_OK;
}

siv_result siv_webview_go_forward(siv_webview webview) {
    WV(webview);
    wv->engine->go_forward(wv);
    return SIV_OK;
}

siv_result siv_webview_reload(siv_webview webview) {
    WV(webview);
    wv->engine->reload(wv);
    return SIV_OK;
}

siv_result siv_webview_stop(siv_webview webview) {
    WV(webview);
    wv->engine->stop(wv);
    return SIV_OK;
}

static siv_result copy_out(const char *s, char *text, size_t cap, size_t *len) {
    size_t n = s ? strlen(s) : 0;
    if (!len) return SIV_ERROR_INVALID_ARGUMENT;
    *len = n;
    if (text && cap) memcpy(text, s ? s : "", n < cap ? n : cap);
    return SIV_OK;
}

siv_result siv_webview_get_uri(siv_webview webview, char *text, size_t text_cap, size_t *len) {
    WV(webview);
    return copy_out(wv->engine->get_uri(wv), text, text_cap, len);
}

siv_result siv_webview_get_title(siv_webview webview, char *text, size_t text_cap, size_t *len) {
    WV(webview);
    return copy_out(wv->engine->get_title(wv), text, text_cap, len);
}

siv_result siv_webview_get_state(siv_webview webview, siv_webview_state *state) {
    WV(webview);
    if (!state) return SIV_ERROR_INVALID_ARGUMENT;
    siv_webview_state s = {.size = sizeof s};
    wv->engine->get_state(wv, &s);
    size_t n = state->size && state->size < sizeof s ? state->size : sizeof s;
    memcpy(state, &s, n);
    state->size = n;
    return SIV_OK;
}

siv_result siv_webview_set_zoom(siv_webview webview, double zoom) {
    WV(webview);
    if (!(zoom > 0) || zoom > 100) return SIV_ERROR_INVALID_ARGUMENT;
    wv->engine->set_zoom(wv, zoom);
    return SIV_OK;
}

siv_result siv_webview_set_color_scheme(siv_webview webview, siv_color_scheme scheme) {
    WV(webview);
    if (scheme != SIV_COLOR_SCHEME_FOLLOW && scheme != SIV_COLOR_SCHEME_LIGHT && scheme != SIV_COLOR_SCHEME_DARK) return SIV_ERROR_INVALID_ARGUMENT;
    wv->scheme = scheme;
    bool dark = scheme == SIV_COLOR_SCHEME_DARK || (scheme == SIV_COLOR_SCHEME_FOLLOW && swv_theme_dark(wv));
    wv->engine->set_dark(wv, dark);
    return SIV_OK;
}

siv_result siv_webview_run_script(siv_webview webview, const char *script, size_t script_len, siv_webview_script_fn callback, siv_destroy_fn destroy, void *user_data) {
    swv_webview *wv = get(webview);
    if (!wv || !wv->engine || !script) {
        if (destroy) destroy(user_data);
        return !wv || !wv->engine ? SIV_ERROR_INVALID_HANDLE : SIV_ERROR_INVALID_ARGUMENT;
    }
    return wv->engine->run_script(wv, script, script_len, callback, destroy, user_data);
}

siv_result siv_webview_add_message_handler(siv_webview webview, const char *name, size_t name_len) {
    WV(webview);
    if (!name || !name_len || name_len > 64) return SIV_ERROR_INVALID_ARGUMENT;
    for (size_t i = 0; i < name_len; i++) {
        char c = name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) return SIV_ERROR_INVALID_ARGUMENT;
    }
    char *s = dup_str(name, name_len);
    if (!s) return SIV_ERROR_OUT_OF_MEMORY;
    siv_result r = wv->engine->add_message_handler(wv, s);
    free(s);
    return r;
}

siv_result siv_webview_post_message(siv_webview webview, const char *json, size_t json_len) {
    WV(webview);
    if (!json || !json_len) return SIV_ERROR_INVALID_ARGUMENT;
    return wv->engine->post_message(wv, json, json_len);
}

siv_result siv_webview_register_scheme(siv_app app, const char *scheme, size_t scheme_len, siv_webview_scheme_fn callback, siv_destroy_fn destroy, void *user_data) {
    siv_result r = SIV_OK;
    if (!callback || !scheme || !scheme_len || scheme_len > 32) r = SIV_ERROR_INVALID_ARGUMENT;
    for (size_t i = 0; r == SIV_OK && i < scheme_len; i++) {
        char c = scheme[i];
        bool ok = (c >= 'a' && c <= 'z') || (i > 0 && ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'));
        if (!ok) r = SIV_ERROR_INVALID_ARGUMENT;
    }
    static const char *const reserved[] = {"http", "https", "file", "about", "data", "blob", "javascript", "ws", "wss"};
    for (size_t i = 0; r == SIV_OK && i < sizeof reserved / sizeof *reserved; i++)
        if (strlen(reserved[i]) == scheme_len && !memcmp(reserved[i], scheme, scheme_len)) r = SIV_ERROR_INVALID_ARGUMENT;
    swv_app *a = r == SIV_OK ? swv_app_get(app, true) : NULL;
    for (swv_scheme *s = a ? a->schemes : NULL; s; s = s->next)
        if (strlen(s->name) == scheme_len && !memcmp(s->name, scheme, scheme_len)) r = SIV_ERROR_INVALID_ARGUMENT;
    swv_scheme *s = r == SIV_OK ? calloc(1, sizeof *s) : NULL;
    if (r == SIV_OK && (!s || !(s->name = dup_str(scheme, scheme_len)))) r = SIV_ERROR_OUT_OF_MEMORY;
    if (r != SIV_OK) {
        if (s) free(s);
        if (a) swv_app_release(a);
        if (destroy) destroy(user_data);
        return r;
    }
    s->app = a;
    s->callback = callback;
    s->destroy = destroy;
    s->user_data = user_data;
    s->next = a->schemes;
    a->schemes = s;
    if (a->engine) a->engine->scheme_added(a, s);
    return SIV_OK;
}

siv_result siv_webview_request_finish(siv_webview_request request, uint32_t status, const char *content_type, size_t content_type_len, const uint8_t *data, size_t data_len) {
    void *req = swv_handle_get(&swv_requests, request);
    if (!req) return SIV_ERROR_INVALID_HANDLE;
    if ((!data && data_len) || (!content_type && content_type_len)) return SIV_ERROR_INVALID_ARGUMENT;
    char *type = dup_str(content_type ? content_type : "", content_type_len);
    if (!type) return SIV_ERROR_OUT_OF_MEMORY;
    swv_handle_remove(&swv_requests, request);
    siv_result r = engines[0]->request_finish(req, status ? status : 200, type, data, data_len);
    free(type);
    return r;
}

siv_result siv_webview_request_fail(siv_webview_request request) {
    void *req = swv_handle_get(&swv_requests, request);
    if (!req) return SIV_ERROR_INVALID_HANDLE;
    swv_handle_remove(&swv_requests, request);
    return engines[0]->request_fail(req);
}

siv_result siv_webview_permission_reply(siv_webview webview, uint64_t id, bool allow) {
    WV(webview);
    return wv->engine->permission_reply(wv, id, allow);
}

siv_result siv_webview_download_cancel(siv_webview webview, uint64_t id) {
    WV(webview);
    return wv->engine->download_cancel(wv, id);
}
