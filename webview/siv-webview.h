/* siv-webview: a web view for siv, built on siv's public C ABI.
 *
 * A web view is an object of its window (siv_webview_create) that shows
 * its page in a node of the window's tree (siv_webview_view), the way an
 * external node shows a frame slot (siv's D17): the engine renders in its
 * own processes and hands finished frames to siv, which puts them on a
 * subsurface without a copy. Input to the node goes to the page; the
 * page's state comes back as events (siv_webview_desc.on_event).
 *
 *     siv_webview wv;
 *     siv_webview_create(window, SIV_DESC(siv_webview_desc, .on_event = on_event), &wv);
 *     siv_txn txn;
 *     siv_txn_begin(window, &txn);
 *     siv_node page = siv_webview_view(txn, root, wv);
 *     siv_set_layout(txn, page, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .grow = 1));
 *     siv_txn_commit(txn);
 *     siv_webview_load_uri(wv, SIV_STR("https://example.com"));
 *
 * Conventions are siv's (D2): functions return siv_result, descriptors
 * start with their size (SIV_DESC), strings are pointer and length,
 * callbacks take user_data and a destroy-notify, and every call is for
 * the application's thread. The engine's own event loop (GLib, for WPE
 * WebKit) runs inside siv's loop (siv_app_add_prepare), whether the
 * application runs siv_app_run or embeds siv's loop.
 *
 * Engines: WPE WebKit through its platform API (WPEPlatform, 2.50 or
 * later). The engine interface inside the library keeps room for others;
 * SIV_WEBVIEW_ENGINE_AUTO picks the first available. */
#ifndef SIV_WEBVIEW_H
#define SIV_WEBVIEW_H

#include <siv.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SIV_WEBVIEW_VERSION_MAJOR 0
#define SIV_WEBVIEW_VERSION_MINOR 1
#define SIV_WEBVIEW_VERSION_PATCH 0

/** A web view: a page, its history, and its engine state. Valid until
 *  siv_webview_destroy or its window's destruction. */
typedef uint64_t siv_webview;

/** A request for a URL of a scheme the application serves
 *  (siv_webview_register_scheme). Valid until finished or failed. */
typedef uint64_t siv_webview_request;

/** Engines. */
typedef enum siv_webview_engine {
    /** The first engine available. */
    SIV_WEBVIEW_ENGINE_AUTO = 0,
    /** WPE WebKit through WPEPlatform. */
    SIV_WEBVIEW_ENGINE_WPE = 1,
    SIV_WEBVIEW_ENGINE_MAX_ENUM = 0x7fffffff
} siv_webview_engine;

/** Web view options. */
typedef uint32_t siv_webview_flags;
/** Keep nothing on disk: cookies, storage, and caches last as long as the
 *  web view (a private window). */
#define SIV_WEBVIEW_EPHEMERAL ((siv_webview_flags)1u << 0)
/** Enable developer tools: the context menu's Inspect Element and the
 *  remote inspector (siv_webview_desc.inspector_port). */
#define SIV_WEBVIEW_DEVELOPER_EXTRAS ((siv_webview_flags)1u << 1)
/** Do not pass the window's theme on to the page as prefers-color-scheme;
 *  siv_webview_set_color_scheme decides. */
#define SIV_WEBVIEW_NO_THEME ((siv_webview_flags)1u << 2)
/** Do not show the engine's context menu. */
#define SIV_WEBVIEW_NO_CONTEXT_MENU ((siv_webview_flags)1u << 3)
/** Run no JavaScript: neither the page's nor siv_webview_run_script's
 *  (WebKit's enable-javascript setting off), so window.siv is absent. */
#define SIV_WEBVIEW_NO_SCRIPTS ((siv_webview_flags)1u << 4)

/** What a siv_webview_event reports. */
typedef enum siv_webview_event_type {
    /** The main frame's load progressed: load_state says how far; uri. */
    SIV_WEBVIEW_EVENT_LOAD = 0,
    /** The estimated load progress changed: progress, 0 to 1. */
    SIV_WEBVIEW_EVENT_PROGRESS = 1,
    /** The page's title changed: text. */
    SIV_WEBVIEW_EVENT_TITLE = 2,
    /** The page's URL changed (a load, a redirect, a fragment, the history
     *  API): uri. */
    SIV_WEBVIEW_EVENT_URI = 3,
    /** Back and forward became possible or not: flags
     *  (SIV_WEBVIEW_CAN_GO_BACK, SIV_WEBVIEW_CAN_GO_FORWARD). */
    SIV_WEBVIEW_EVENT_HISTORY = 4,
    /** The page posted a message to a handler the application added
     *  (siv_webview_add_message_handler), or with siv.postMessage: name
     *  is the handler's name ("siv" for siv.postMessage), text the message
     *  as JSON. */
    SIV_WEBVIEW_EVENT_MESSAGE = 5,
    /** A navigation is about to start: uri, flags (main frame, user
     *  gesture, redirect). Return true to block it. */
    SIV_WEBVIEW_EVENT_NAVIGATE = 6,
    /** The page asks for a new window (target="_blank", window.open): uri,
     *  flags (user gesture). Return true when the application handled it
     *  (opened its own window or tab, or refused); otherwise the URL loads
     *  in this web view. */
    SIV_WEBVIEW_EVENT_NEW_WINDOW = 7,
    /** The page asks for a permission: permission, id, uri (the page).
     *  Answer with siv_webview_permission_reply and return true, now or
     *  later; returning false denies it. */
    SIV_WEBVIEW_EVENT_PERMISSION = 8,
    /** A download: download_phase, id, uri, path (the destination),
     *  progress. Return true at SIV_WEBVIEW_DOWNLOAD_STARTED to cancel it;
     *  by default it goes to the user's download folder. */
    SIV_WEBVIEW_EVENT_DOWNLOAD = 9,
    /** The page shows a notification: name (title), text (body). Return
     *  true when the application showed it; otherwise it goes to the
     *  desktop's notifications (siv_notification_send). */
    SIV_WEBVIEW_EVENT_NOTIFICATION = 10,
    /** The page called window.close(). */
    SIV_WEBVIEW_EVENT_CLOSE = 11,
    /** The engine's process for the page ended: text says why. Reload to
     *  continue. */
    SIV_WEBVIEW_EVENT_CRASHED = 12,
    /** A load failed: uri, text (the error). */
    SIV_WEBVIEW_EVENT_LOAD_FAILED = 13,
    SIV_WEBVIEW_EVENT_MAX_ENUM = 0x7fffffff
} siv_webview_event_type;

/** How far a load got. */
typedef enum siv_webview_load_state {
    SIV_WEBVIEW_LOAD_STARTED = 0,
    SIV_WEBVIEW_LOAD_REDIRECTED = 1,
    /** The first data arrived: the new page replaces the old one. */
    SIV_WEBVIEW_LOAD_COMMITTED = 2,
    SIV_WEBVIEW_LOAD_FINISHED = 3,
    SIV_WEBVIEW_LOAD_MAX_ENUM = 0x7fffffff
} siv_webview_load_state;

/** A permission a page asks for. */
typedef enum siv_webview_permission {
    SIV_WEBVIEW_PERMISSION_OTHER = 0,
    SIV_WEBVIEW_PERMISSION_GEOLOCATION = 1,
    SIV_WEBVIEW_PERMISSION_NOTIFICATIONS = 2,
    /** Camera, microphone, or both. */
    SIV_WEBVIEW_PERMISSION_MEDIA = 3,
    SIV_WEBVIEW_PERMISSION_CLIPBOARD = 4,
    SIV_WEBVIEW_PERMISSION_POINTER_LOCK = 5,
    SIV_WEBVIEW_PERMISSION_MAX_ENUM = 0x7fffffff
} siv_webview_permission;

/** A download's progress. */
typedef enum siv_webview_download_phase {
    SIV_WEBVIEW_DOWNLOAD_STARTED = 0,
    SIV_WEBVIEW_DOWNLOAD_PROGRESS = 1,
    SIV_WEBVIEW_DOWNLOAD_FINISHED = 2,
    SIV_WEBVIEW_DOWNLOAD_FAILED = 3,
    SIV_WEBVIEW_DOWNLOAD_MAX_ENUM = 0x7fffffff
} siv_webview_download_phase;

/** Event and state details. */
typedef uint32_t siv_webview_event_flags;
#define SIV_WEBVIEW_MAIN_FRAME ((siv_webview_event_flags)1u << 0)
#define SIV_WEBVIEW_USER_GESTURE ((siv_webview_event_flags)1u << 1)
#define SIV_WEBVIEW_REDIRECT ((siv_webview_event_flags)1u << 2)
#define SIV_WEBVIEW_CAN_GO_BACK ((siv_webview_event_flags)1u << 3)
#define SIV_WEBVIEW_CAN_GO_FORWARD ((siv_webview_event_flags)1u << 4)
#define SIV_WEBVIEW_LOADING ((siv_webview_event_flags)1u << 5)

/** A web view's event. Filled by the library; fields that do not apply are
 *  zero; strings are valid during the call. */
typedef struct siv_webview_event {
    size_t size;
    siv_webview_event_type type;
    siv_webview_load_state load_state;
    siv_webview_event_flags flags;
    siv_webview_permission permission;
    siv_webview_download_phase download_phase;
    uint32_t reserved0;
    const char *uri;
    size_t uri_len;
    const char *text;
    size_t text_len;
    const char *name;
    size_t name_len;
    const char *path;
    size_t path_len;
    double progress;
    /** Permission requests and downloads: what siv_webview_permission_reply
     *  and siv_webview_download_cancel take. */
    uint64_t id;
} siv_webview_event;

/** Receives a web view's events on the application's thread (siv's D5).
 *  The return value matters for some events (see siv_webview_event_type);
 *  return false otherwise. */
typedef bool (*siv_webview_event_fn)(void *user_data, siv_webview webview, const siv_webview_event *event);

/** Options for siv_webview_create. */
typedef struct siv_webview_desc {
    size_t size;
    /** Passed to on_event and destroy. */
    void *user_data;
    siv_webview_event_fn on_event;
    /** Releases user_data when the web view is destroyed. */
    siv_destroy_fn destroy;
    siv_webview_flags flags;
    siv_webview_engine engine;
    /** Where cookies, storage, and the like live; empty is
     *  $XDG_DATA_HOME/<program>/webview. Web views with the same directory
     *  share them. Ignored with SIV_WEBVIEW_EPHEMERAL. */
    const char *data_dir;
    size_t data_dir_len;
    /** Where caches live; empty is $XDG_CACHE_HOME/<program>/webview. */
    const char *cache_dir;
    size_t cache_dir_len;
    /** The User-Agent string; empty is the engine's. */
    const char *user_agent;
    size_t user_agent_len;
    /** Page zoom; 0 is 1. */
    double zoom;
    /** With SIV_WEBVIEW_DEVELOPER_EXTRAS: serve the remote inspector over
     *  HTTP on 127.0.0.1 at this port (open it in a browser); 0 for none.
     *  The first web view of the process decides. */
    uint16_t inspector_port;
    /** The color behind the page before its first frame, and where the
     *  page is transparent; default the window's background. */
    siv_color background;
} siv_webview_desc;

/** Receives the result of siv_webview_run_script. */
typedef void (*siv_webview_script_fn)(void *user_data, siv_result result, const char *json, size_t json_len);

/** Receives a request for a URL of a scheme the application registered:
 *  answer it with siv_webview_request_finish or siv_webview_request_fail,
 *  now or later (for example after a job). */
typedef void (*siv_webview_scheme_fn)(void *user_data, siv_webview_request request, const char *uri, size_t uri_len, const char *method, size_t method_len);

/** A web view's state, as of the latest event. */
typedef struct siv_webview_state {
    size_t size;
    siv_webview_event_flags flags;
    uint32_t reserved0;
    double progress;
    double zoom;
} siv_webview_state;

/** The version of the loaded library, as SIV_MAKE_VERSION encodes it. */
uint32_t siv_webview_version(void);

/** Whether an engine can run here (its libraries load and its processes
 *  are installed): SIV_OK, or SIV_ERROR_UNSUPPORTED. */
SIV_NODISCARD siv_result siv_webview_engine_available(siv_webview_engine engine);

/** Creates a web view for a window. It shows nothing until a node shows
 *  it (siv_webview_view) and a page loads. */
SIV_NODISCARD siv_result siv_webview_create(siv_window window, const siv_webview_desc *desc, siv_webview *webview);

/** Destroys a web view: its page, its node's content, and its engine
 *  state; the destroy-notify runs. */
void siv_webview_destroy(siv_webview webview);

/** Creates the node that shows the web view, in a transaction of its
 *  window: an external node (focusable, with the page's input handlers,
 *  cursors, input method, and accessibility tree) that the application
 *  lays out like any other. A web view has one node; creating another
 *  moves the page there. Returns 0 if the transaction failed.
 *
 *  The node is a drop target for text and URLs, which reach the page as
 *  DOM dragenter, dragover, and drop events (or are inserted into an
 *  editable element). WPE WebKit has no drag and drop of its own, so files
 *  cannot be dropped into a page and drags do not start from one. */
siv_node siv_webview_view(siv_txn txn, siv_node parent, siv_webview webview);

/** The node showing the web view, or 0. */
siv_node siv_webview_get_node(siv_webview webview);

/** Loads a URL. */
SIV_NODISCARD siv_result siv_webview_load_uri(siv_webview webview, const char *uri, size_t uri_len);

/** Loads a page from a string, resolving relative URLs against base_uri
 *  (empty for about:blank). */
SIV_NODISCARD siv_result siv_webview_load_html(siv_webview webview, const char *html, size_t html_len, const char *base_uri, size_t base_uri_len);

/** Goes back or forward in the history; SIV_ERROR_BUSY with nowhere to go
 *  (SIV_WEBVIEW_CAN_GO_BACK, SIV_WEBVIEW_CAN_GO_FORWARD). */
SIV_NODISCARD siv_result siv_webview_go_back(siv_webview webview);
SIV_NODISCARD siv_result siv_webview_go_forward(siv_webview webview);
SIV_NODISCARD siv_result siv_webview_reload(siv_webview webview);
/** Stops a load in progress. */
SIV_NODISCARD siv_result siv_webview_stop(siv_webview webview);

/** Copies the page's URL (len gets its full length; the copy is cut at
 *  text_cap bytes, not NUL-terminated). */
SIV_NODISCARD siv_result siv_webview_get_uri(siv_webview webview, char *text, size_t text_cap, size_t *len);
/** Copies the page's title, like siv_webview_get_uri. */
SIV_NODISCARD siv_result siv_webview_get_title(siv_webview webview, char *text, size_t text_cap, size_t *len);
SIV_NODISCARD siv_result siv_webview_get_state(siv_webview webview, siv_webview_state *state);

/** Sets the page zoom (1 for 100%). */
SIV_NODISCARD siv_result siv_webview_set_zoom(siv_webview webview, double zoom);

/** Sets the page's prefers-color-scheme: follow (the window's theme, the
 *  default), light, or dark. WPE WebKit has one appearance per process:
 *  the last web view to change it decides for all. */
SIV_NODISCARD siv_result siv_webview_set_color_scheme(siv_webview webview, siv_color_scheme scheme);

/** Runs JavaScript in the page's main frame; callback gets the completion
 *  value as JSON (SIV_OK), or the exception's message
 *  (SIV_ERROR_UNAVAILABLE). Promises are not awaited. */
SIV_NODISCARD siv_result siv_webview_run_script(siv_webview webview, const char *script, size_t script_len, siv_webview_script_fn callback, siv_destroy_fn destroy, void *user_data);

/** Where and when a user script runs (siv_webview_add_user_script). The
 *  default, 0, is the main frame at document start: before any of the
 *  page's own scripts, with document.documentElement already there. */
typedef uint32_t siv_webview_script_flags;
/** Run in every frame, iframes included, not only the main frame. */
#define SIV_WEBVIEW_SCRIPT_ALL_FRAMES ((siv_webview_script_flags)1u << 0)
/** Run at document end (the document parsed, before subresources such as
 *  images finish loading) instead of document start. */
#define SIV_WEBVIEW_SCRIPT_DOCUMENT_END ((siv_webview_script_flags)1u << 1)

/** Adds JavaScript that runs in every page the web view loads from the
 *  next load on (loads, reloads, navigations) until removed. It runs in
 *  the page's own JavaScript world (it sees and changes what the page's
 *  scripts see), after window.siv is set up, and user scripts run in the
 *  order they were added. It does not run in the current page
 *  (siv_webview_run_script does), nor with SIV_WEBVIEW_NO_SCRIPTS. id, if
 *  not NULL, gets what siv_webview_remove_user_script takes.
 *  SIV_ERROR_INVALID_ARGUMENT for unknown flags. */
SIV_NODISCARD siv_result siv_webview_add_user_script(siv_webview webview, const char *source, size_t source_len, siv_webview_script_flags flags, uint64_t *id);

/** Removes a user script, from the next load on (the current page keeps
 *  what it ran). SIV_ERROR_INVALID_ARGUMENT if id is not one of the web
 *  view's user scripts. */
SIV_NODISCARD siv_result siv_webview_remove_user_script(siv_webview webview, uint64_t id);

/** Lets the page post messages to the application:
 *  window.webkit.messageHandlers[name].postMessage(value) arrives as
 *  SIV_WEBVIEW_EVENT_MESSAGE with value as JSON. siv.postMessage(value),
 *  which every page has, arrives with name "siv". */
SIV_NODISCARD siv_result siv_webview_add_message_handler(siv_webview webview, const char *name, size_t name_len);

/** Posts a message to the page: json (a JSON value) arrives as the data of
 *  a "message" event on window.siv (siv.addEventListener("message", e =>
 *  e.data), or siv.onmessage). SIV_ERROR_INVALID_ARGUMENT if it is not
 *  JSON. */
SIV_NODISCARD siv_result siv_webview_post_message(siv_webview webview, const char *json, size_t json_len);

/** Serves URLs of `scheme` (such as "app") from the application, for every
 *  web view of the application, including those created earlier. The
 *  scheme is secure (like https) and CORS-enabled. */
SIV_NODISCARD siv_result siv_webview_register_scheme(siv_app app, const char *scheme, size_t scheme_len, siv_webview_scheme_fn callback, siv_destroy_fn destroy, void *user_data);

/** Answers a scheme request with a response (status 0 is 200), its
 *  content type, and its body (copied). */
SIV_NODISCARD siv_result siv_webview_request_finish(siv_webview_request request, uint32_t status, const char *content_type, size_t content_type_len, const uint8_t *data, size_t data_len);

/** Fails a scheme request (the page sees a network error). */
SIV_NODISCARD siv_result siv_webview_request_fail(siv_webview_request request);

/** Answers a permission request (SIV_WEBVIEW_EVENT_PERMISSION). */
SIV_NODISCARD siv_result siv_webview_permission_reply(siv_webview webview, uint64_t id, bool allow);

/** Cancels a download in progress. */
SIV_NODISCARD siv_result siv_webview_download_cancel(siv_webview webview, uint64_t id);

#ifdef __cplusplus
}
#endif

#endif
