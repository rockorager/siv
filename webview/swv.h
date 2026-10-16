/* siv-webview internals: the application and web view state shared by the
 * siv side (webview.c), the GLib loop integration (glib_loop.c), and the
 * engines (an engine is a table of functions, swv_engine; wpe.c is the
 * only one so far). */
#ifndef SWV_H
#define SWV_H

#include "siv-webview.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct swv_app;
struct swv_webview;

/* Handles: generation-checked slots, as siv's are (D20). */
typedef struct swv_handles {
    void **items;
    uint32_t *gens;
    uint32_t len, cap;
} swv_handles;

uint64_t swv_handle_insert(swv_handles *h, void *p);
void *swv_handle_get(const swv_handles *h, uint64_t handle);
void swv_handle_remove(swv_handles *h, uint64_t handle);

/* An application's registered scheme. */
typedef struct swv_scheme {
    struct swv_app *app;
    char *name;
    siv_webview_scheme_fn callback;
    siv_destroy_fn destroy;
    void *user_data;
    struct swv_scheme *next;
} swv_scheme;

/* An engine: what the siv side needs from it. Engines keep their own state
 * in swv_webview.engine_data and swv_app.engine_data. */
typedef struct swv_engine {
    const char *name;
    siv_webview_engine id;
    /* SIV_OK if the engine can run in this process. */
    siv_result (*available)(void);
    siv_result (*app_init)(struct swv_app *app);
    void (*app_fini)(struct swv_app *app);
    void (*scheme_added)(struct swv_app *app, swv_scheme *scheme);
    siv_result (*create)(struct swv_webview *wv, const siv_webview_desc *desc);
    void (*destroy)(struct swv_webview *wv);
    /* The node is shown: its size in logical pixels and the window's scale
     * (siv's configure for frame slots). */
    void (*configure)(struct swv_webview *wv, uint32_t width, uint32_t height, double scale);
    /* A frame (by key) reached the screen, or siv let go of it. */
    void (*presented)(struct swv_webview *wv, uint64_t key);
    void (*released)(struct swv_webview *wv, uint64_t key);
    /* Whether the node can be seen (siv's shown and hidden: a node that
     * shows it, in a window that is not suspended and draws), and the
     * window's states. */
    void (*set_shown)(struct swv_webview *wv, bool shown);
    void (*set_states)(struct swv_webview *wv, siv_window_states states);
    /* The window draws the frame swv_request_frame asked for. */
    void (*frame)(struct swv_webview *wv);
    /* Input on the node; returns what siv's handler returns. */
    siv_event_result (*input)(struct swv_webview *wv, const siv_event *event);
    /* Text or URLs (a URI list) dropped on the node at (x, y), logical
     * pixels. */
    void (*drop)(struct swv_webview *wv, float x, float y, bool uri_list, const char *data, size_t len);
    void (*load_uri)(struct swv_webview *wv, const char *uri);
    void (*load_html)(struct swv_webview *wv, const char *html, size_t len, const char *base_uri);
    void (*go_back)(struct swv_webview *wv);
    void (*go_forward)(struct swv_webview *wv);
    void (*reload)(struct swv_webview *wv);
    void (*stop)(struct swv_webview *wv);
    /* Owned by the engine, valid until the next call. */
    const char *(*get_uri)(struct swv_webview *wv);
    const char *(*get_title)(struct swv_webview *wv);
    void (*get_state)(struct swv_webview *wv, siv_webview_state *state);
    void (*set_zoom)(struct swv_webview *wv, double zoom);
    void (*set_dark)(struct swv_webview *wv, bool dark);
    siv_result (*run_script)(struct swv_webview *wv, const char *script, size_t len, siv_webview_script_fn cb, siv_destroy_fn destroy, void *user_data);
    /* Flags checked by the siv side; *id is nonzero and unique within the
     * web view. */
    siv_result (*add_user_script)(struct swv_webview *wv, const char *source, size_t len, siv_webview_script_flags flags, uint64_t *id);
    siv_result (*remove_user_script)(struct swv_webview *wv, uint64_t id);
    siv_result (*add_message_handler)(struct swv_webview *wv, const char *name);
    siv_result (*post_message)(struct swv_webview *wv, const char *json, size_t len);
    siv_result (*permission_reply)(struct swv_webview *wv, uint64_t id, bool allow);
    siv_result (*download_cancel)(struct swv_webview *wv, uint64_t id);
    siv_result (*request_finish)(void *request, uint32_t status, const char *content_type, const uint8_t *data, size_t len);
    siv_result (*request_fail)(void *request);
} swv_engine;

extern const swv_engine swv_engine_wpe;

/* One per siv application with web views. */
typedef struct swv_app {
    siv_app app;
    const swv_engine *engine;
    void *engine_data;
    swv_scheme *schemes;
    int webviews;
    struct swv_glib_loop *loop;
    struct swv_app *next;
} swv_app;

typedef struct swv_webview {
    swv_app *app;
    siv_webview handle;
    siv_window window;
    siv_external slot;
    siv_node node;
    const swv_engine *engine;
    void *engine_data;
    siv_webview_event_fn on_event;
    siv_destroy_fn destroy;
    void *user_data;
    siv_webview_flags flags;
    siv_color background;
    siv_color_scheme scheme;
    bool dark;
    bool dead;
    /* The node's cursor, as last set. */
    siv_cursor cursor;
} swv_webview;

/* Library-wide state (one thread: the application's). */
extern swv_handles swv_webviews;
extern swv_handles swv_requests;

swv_app *swv_app_get(siv_app app, bool create);
void swv_app_release(swv_app *a);

/* Calls the application's on_event. */
bool swv_emit(swv_webview *wv, const siv_webview_event *event);

/* The siv side, for engines. */
void swv_set_cursor(swv_webview *wv, siv_cursor cursor);
/* The page's text field for the input method: enabled with its state, or
 * disabled (desc NULL). */
void swv_set_text_input(swv_webview *wv, const siv_text_input_desc *desc);
void swv_set_accessible_embed(swv_webview *wv, const char *plug);
/* Submits a frame to the node's slot. */
siv_result swv_submit(swv_webview *wv, const siv_external_frame_desc *frame);
/* Asks for the engine's frame call at the window's next frame that shows
 * the node: siv's frame callback. */
void swv_request_frame(swv_webview *wv);
/* Whether the window's theme is dark. */
bool swv_theme_dark(swv_webview *wv);

/* GLib's default main context inside siv's loop (glib_loop.c). */
struct swv_glib_loop *swv_glib_loop_start(siv_app app);
void swv_glib_loop_stop(struct swv_glib_loop *loop);

#endif
