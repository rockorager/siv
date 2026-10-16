/* siv-webview against siv's headless backend: no compositor, the real
 * engine (its web and network processes run). Each check drives the page
 * through the public API and siv_test_* input, and waits on events.
 *
 *     siv-webview-test [FILTER]
 *
 * The engine renders in software (LIBGL_ALWAYS_SOFTWARE=1: shared memory
 * frames the headless backend can read, and no GPU needed) unless
 * SIV_WEBVIEW_TEST_GPU is set. */
#define _GNU_SOURCE
#include <siv-webview.h>

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int failures;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                          \
            return;                                                              \
        }                                                                        \
    } while (0)

/* What the web view reported. */
struct seen {
    char title[256];
    char uri[512];
    char message_name[64];
    char message[256];
    int messages;
    int loads_finished;
    char blocked[512];
    int navigations;
    char new_window[512];
    int new_windows;
    int load_failed;
    int crashed;
    const char *block; /* NAVIGATE: block URLs containing this */
};

static void copy(char *dst, size_t cap, const char *s, size_t len) {
    if (len >= cap) len = cap - 1;
    memcpy(dst, s ? s : "", s ? len : 0);
    dst[s ? len : 0] = 0;
}

static bool on_event(void *user_data, siv_webview webview, const siv_webview_event *e) {
    (void)webview;
    struct seen *s = user_data;
    switch (e->type) {
    case SIV_WEBVIEW_EVENT_TITLE: copy(s->title, sizeof s->title, e->text, e->text_len); break;
    case SIV_WEBVIEW_EVENT_URI: copy(s->uri, sizeof s->uri, e->uri, e->uri_len); break;
    case SIV_WEBVIEW_EVENT_LOAD:
        if (e->load_state == SIV_WEBVIEW_LOAD_FINISHED) s->loads_finished++;
        break;
    case SIV_WEBVIEW_EVENT_LOAD_FAILED: s->load_failed++; break;
    case SIV_WEBVIEW_EVENT_CRASHED: s->crashed++; break;
    case SIV_WEBVIEW_EVENT_MESSAGE:
        copy(s->message_name, sizeof s->message_name, e->name, e->name_len);
        copy(s->message, sizeof s->message, e->text, e->text_len);
        s->messages++;
        break;
    case SIV_WEBVIEW_EVENT_NAVIGATE:
        s->navigations++;
        if (s->block && e->uri && memmem(e->uri, e->uri_len, s->block, strlen(s->block))) {
            copy(s->blocked, sizeof s->blocked, e->uri, e->uri_len);
            return true;
        }
        break;
    case SIV_WEBVIEW_EVENT_NEW_WINDOW:
        copy(s->new_window, sizeof s->new_window, e->uri, e->uri_len);
        s->new_windows++;
        return true;
    default: break;
    }
    return false;
}

/* One application and window per check, with a web view filling it. */
struct fixture {
    siv_app app;
    siv_window window;
    siv_webview webview;
    siv_node node;
    struct seen seen;
};

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Dispatches until *flag is nonzero or 30 s pass. */
static bool wait_for(struct fixture *f, const int *flag) {
    double end = now() + 30;
    while (!*flag && now() < end)
        if (siv_app_dispatch(f->app, 20) != SIV_OK) return false;
    return *flag != 0;
}

static bool wait_title(struct fixture *f, const char *title) {
    double end = now() + 30;
    while (strcmp(f->seen.title, title) && now() < end)
        if (siv_app_dispatch(f->app, 20) != SIV_OK) return false;
    if (strcmp(f->seen.title, title)) fprintf(stderr, "title: want \"%s\", have \"%s\"\n", title, f->seen.title);
    return !strcmp(f->seen.title, title);
}

static void pump(struct fixture *f, int ms) {
    double end = now() + ms / 1000.0;
    while (now() < end) (void)siv_app_dispatch(f->app, 10);
}

static bool start(struct fixture *f, siv_webview_flags flags, const char *data_dir) {
    memset(f, 0, sizeof *f);
    if (siv_app_create(SIV_DESC(siv_app_desc, .backend = SIV_BACKEND_HEADLESS, .app_id = SIV_STR("dev.siv.webview.test")), &f->app) != SIV_OK) return false;
    if (siv_window_create(f->app, SIV_DESC(siv_window_desc, .title = SIV_STR("test"), .width = 400, .height = 300), &f->window) != SIV_OK) return false;
    if (siv_webview_create(f->window, SIV_DESC(siv_webview_desc, .on_event = on_event, .user_data = &f->seen, .flags = flags, .data_dir = data_dir, .data_dir_len = data_dir ? strlen(data_dir) : 0), &f->webview) != SIV_OK) return false;
    siv_txn txn;
    if (siv_txn_begin(f->window, &txn) != SIV_OK) return false;
    siv_node root = siv_window_get_root(f->window);
    f->node = siv_webview_view(txn, root, f->webview);
    siv_set_layout(txn, f->node, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
    if (siv_txn_commit(txn) != SIV_OK || !f->node) return false;
    bool settled;
    return siv_test_settle(f->app, 1000, &settled) == SIV_OK;
}

static void stop(struct fixture *f) {
    siv_webview_destroy(f->webview);
    siv_app_destroy(f->app);
}

static bool load(struct fixture *f, const char *html, const char *base) {
    int before = f->seen.loads_finished;
    if (siv_webview_load_html(f->webview, html, strlen(html), base, base ? strlen(base) : 0) != SIV_OK) return false;
    double end = now() + 30;
    while (f->seen.loads_finished == before && now() < end) (void)siv_app_dispatch(f->app, 20);
    return f->seen.loads_finished > before;
}

/* run_script's answer. */
struct answer {
    int done;
    siv_result result;
    char json[256];
};

static void on_answer(void *user_data, siv_result result, const char *json, size_t len) {
    struct answer *a = user_data;
    a->result = result;
    copy(a->json, sizeof a->json, json, len);
    a->done = 1;
}

static bool eval(struct fixture *f, const char *script, struct answer *a) {
    memset(a, 0, sizeof *a);
    if (siv_webview_run_script(f->webview, script, strlen(script), on_answer, NULL, a) != SIV_OK) return false;
    return wait_for(f, &a->done);
}

/* ---------- checks ---------- */

static void check_load_and_title(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f, "<title>Hello</title><p>hi", "https://example.test/"));
    CHECK(wait_title(&f, "Hello"));
    char buf[64];
    size_t len = 0;
    CHECK(siv_webview_get_title(f.webview, buf, sizeof buf, &len) == SIV_OK);
    CHECK(len == 5 && !memcmp(buf, "Hello", 5));
    CHECK(siv_webview_get_uri(f.webview, buf, sizeof buf, &len) == SIV_OK);
    CHECK(len == strlen("https://example.test/") && !memcmp(buf, "https://example.test/", len));
    /* The title follows the page. */
    struct answer a;
    CHECK(eval(&f, "document.title = 'Changed'", &a));
    CHECK(wait_title(&f, "Changed"));
    stop(&f);
}

static void check_run_script(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f, "<p>x", NULL));
    struct answer a;
    CHECK(eval(&f, "[1 + 2, 'two', {a: null}]", &a));
    CHECK(a.result == SIV_OK);
    CHECK(!strcmp(a.json, "[3,\"two\",{\"a\":null}]"));
    CHECK(eval(&f, "throw new Error('nope')", &a));
    CHECK(a.result == SIV_ERROR_UNAVAILABLE);
    CHECK(strstr(a.json, "nope") != NULL);
    stop(&f);
}

static void check_messages(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(siv_webview_add_message_handler(f.webview, SIV_STR("echo")) == SIV_OK);
    CHECK(load(&f,
               "<script>"
               "siv.addEventListener('message', e => webkit.messageHandlers.echo.postMessage(e.data.n * 2));"
               "siv.postMessage({ready: true});"
               "</script>",
               NULL));
    CHECK(wait_for(&f, &f.seen.messages));
    CHECK(!strcmp(f.seen.message_name, "siv"));
    CHECK(!strcmp(f.seen.message, "{\"ready\":true}"));
    CHECK(siv_webview_post_message(f.webview, SIV_STR("{\"n\": 21}")) == SIV_OK);
    double end = now() + 30;
    while (f.seen.messages < 2 && now() < end) (void)siv_app_dispatch(f.app, 20);
    CHECK(f.seen.messages == 2);
    CHECK(!strcmp(f.seen.message_name, "echo"));
    CHECK(!strcmp(f.seen.message, "42"));
    /* Not JSON: refused before the page sees it. */
    CHECK(siv_webview_post_message(f.webview, SIV_STR("{oops")) == SIV_ERROR_INVALID_ARGUMENT);
    stop(&f);
}

static int scheme_requests;

static void serve(void *user_data, siv_webview_request request, const char *uri, size_t uri_len, const char *method, size_t method_len) {
    (void)user_data, (void)method, (void)method_len;
    scheme_requests++;
    const char *page = "<title>from app</title><script>fetch('app://res/data.json').then(r => r.json()).then(d => document.title = d.title)</script>";
    const char *data = "{\"title\": \"fetched\"}";
    if (uri_len == strlen("app://res/index.html") && !memcmp(uri, "app://res/index.html", uri_len))
        (void)siv_webview_request_finish(request, 200, SIV_STR("text/html"), (const uint8_t *)page, strlen(page));
    else if (uri_len == strlen("app://res/data.json") && !memcmp(uri, "app://res/data.json", uri_len))
        (void)siv_webview_request_finish(request, 0, SIV_STR("application/json"), (const uint8_t *)data, strlen(data));
    else if (uri_len == strlen("app://res/second.html") && !memcmp(uri, "app://res/second.html", uri_len))
        (void)siv_webview_request_finish(request, 0, SIV_STR("text/html"), (const uint8_t *)"<title>second</title>", 21);
    else
        (void)siv_webview_request_fail(request);
}

static void check_scheme(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    scheme_requests = 0;
    CHECK(siv_webview_register_scheme(f.app, SIV_STR("app"), serve, NULL, NULL) == SIV_OK);
    CHECK(siv_webview_load_uri(f.webview, SIV_STR("app://res/index.html")) == SIV_OK);
    CHECK(wait_title(&f, "fetched"));
    CHECK(scheme_requests == 2);
    /* Unknown paths fail like a network error. */
    CHECK(siv_webview_load_uri(f.webview, SIV_STR("app://res/missing")) == SIV_OK);
    CHECK(wait_for(&f, &f.seen.load_failed));
    stop(&f);
}

static void check_navigation_policy(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    f.seen.block = "blocked";
    CHECK(siv_webview_register_scheme(f.app, SIV_STR("app"), serve, NULL, NULL) == SIV_OK);
    CHECK(siv_webview_load_uri(f.webview, SIV_STR("app://res/index.html")) == SIV_OK);
    CHECK(wait_title(&f, "fetched"));
    int before = f.seen.loads_finished;
    struct answer a;
    CHECK(eval(&f, "location.href = 'app://res/blocked.html'; 1", &a));
    double end = now() + 5;
    while (!f.seen.blocked[0] && now() < end) (void)siv_app_dispatch(f.app, 20);
    CHECK(!strcmp(f.seen.blocked, "app://res/blocked.html"));
    pump(&f, 300);
    CHECK(f.seen.loads_finished == before);
    CHECK(!strcmp(f.seen.uri, "app://res/index.html"));
    stop(&f);
}

/* A press on the page's link (target=_blank) reaches the engine as a user
 * gesture: input routed through the node. */
static void check_input_and_new_window(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f,
               "<style>body{margin:0} a{display:block;height:100px;background:#00f} input{display:block;width:300px}</style>"
               "<a href='https://example.test/new' target='_blank'>new</a><input id=f>",
               "https://example.test/"));
    pump(&f, 200);
    CHECK(siv_test_click(f.window, 50, 50, SIV_POINTER_BUTTON_PRIMARY) == SIV_OK);
    CHECK(wait_for(&f, &f.seen.new_windows));
    CHECK(!strcmp(f.seen.new_window, "https://example.test/new"));
    /* Typing reaches the focused field. */
    CHECK(siv_test_click(f.window, 50, 110, SIV_POINTER_BUTTON_PRIMARY) == SIV_OK);
    pump(&f, 200);
    CHECK(siv_test_type(f.window, SIV_STR("héllo")) == SIV_OK);
    struct answer a;
    double end = now() + 10;
    do {
        CHECK(eval(&f, "document.getElementById('f').value", &a));
    } while (strcmp(a.json, "\"héllo\"") && now() < end);
    CHECK(!strcmp(a.json, "\"héllo\""));
    stop(&f);
}

/* Frames reach the window: the page's color in a capture. Frames go on a
 * subsurface, which a capture of the window leaves out, unless they are
 * translucent and covered (a small box over the corner): then siv
 * composites them into the window. */
static void check_frames(void) {
    /* GPU frames are dma-bufs the headless backend's CPU renderer cannot
     * read. */
    if (getenv("SIV_WEBVIEW_TEST_GPU")) return;
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    siv_txn txn;
    CHECK(siv_txn_begin(f.window, &txn) == SIV_OK);
    siv_node stack = siv_stack(txn, siv_window_get_root(f.window), SIV_DESC(siv_stack_desc));
    siv_set_layout(txn, stack, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
    siv_node node = siv_webview_view(txn, stack, f.webview);
    siv_set_layout(txn, node, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
    siv_set_opacity(txn, node, 0.99f);
    siv_node cover = siv_box(txn, stack);
    siv_set_layout(txn, cover, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 8}, .height = {SIV_UNIT_PX, 8}, .flags = SIV_LAYOUT_INSET_START | SIV_LAYOUT_INSET_TOP));
    siv_set_visual(txn, cover, SIV_DESC(siv_visual_desc, .background = {0, 0, 1, 1}));
    CHECK(siv_txn_commit(txn) == SIV_OK && node);
    CHECK(load(&f, "<body style='background:#ff0000'>", NULL));
    static uint8_t px[400 * 300 * 4 * 4];
    double end = now() + 10;
    bool red = false;
    while (!red && now() < end) {
        pump(&f, 100);
        size_t len = 0;
        uint32_t w = 0, h = 0;
        siv_result cr = siv_test_capture(f.window, px, sizeof px, &len, &w, &h);
        if (cr != SIV_OK || !w) continue;
        const uint8_t *p = px + ((size_t)(h / 2) * w + w / 2) * 4;
        red = p[0] > 200 && p[1] < 40 && p[2] < 40;
    }
    CHECK(red);
    stop(&f);
}

/* A data directory keeps local storage between web views; ephemeral ones
 * keep nothing there. */
static void check_data_dir(void) {
    char dir[] = "/tmp/siv-webview-test-XXXXXX";
    CHECK(mkdtemp(dir) != NULL);
    struct fixture f;
    struct answer a;
    CHECK(start(&f, 0, dir));
    CHECK(load(&f, "<p>x", "https://example.test/"));
    CHECK(eval(&f, "localStorage.setItem('k', 'kept'); 1", &a));
    stop(&f);
    CHECK(start(&f, 0, dir));
    CHECK(load(&f, "<p>x", "https://example.test/"));
    CHECK(eval(&f, "localStorage.getItem('k')", &a));
    CHECK(!strcmp(a.json, "\"kept\""));
    stop(&f);
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, dir));
    CHECK(load(&f, "<p>x", "https://example.test/"));
    CHECK(eval(&f, "localStorage.getItem('k')", &a));
    CHECK(!strcmp(a.json, "null"));
    stop(&f);
    char cmd[128];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
    CHECK(system(cmd) == 0);
}

/* Whether a file in dir whose name starts with prefix contains needle. */
static bool dir_has(const char *dir, const char *prefix, const char *needle) {
    char cmd[256];
    snprintf(cmd, sizeof cmd, "grep -qs -F '%s' '%s'/%s*", needle, dir, prefix);
    return system(cmd) == 0;
}

/* A data directory keeps persistent cookies after the application exits
 * (WebKit keeps them only in memory unless told where to store them); an
 * ephemeral web view stores none. */
static void check_cookies(void) {
    char dir[] = "/tmp/siv-webview-test-XXXXXX";
    char eph[] = "/tmp/siv-webview-test-XXXXXX";
    CHECK(mkdtemp(dir) != NULL);
    CHECK(mkdtemp(eph) != NULL);
    struct fixture f;
    struct answer a;
    CHECK(start(&f, 0, dir));
    CHECK(load(&f, "<p>x", "https://example.test/"));
    CHECK(eval(&f, "document.cookie = 'siv=kept-across-exits; Max-Age=3600; Path=/'; document.cookie", &a));
    CHECK(!strcmp(a.json, "\"siv=kept-across-exits\""));
    /* The network process stores it in the background. */
    double end = now() + 10;
    while (!dir_has(dir, "cookies.sqlite", "kept-across-exits") && now() < end) pump(&f, 50);
    stop(&f);
    CHECK(start(&f, 0, dir));
    CHECK(load(&f, "<p>x", "https://example.test/"));
    CHECK(eval(&f, "document.cookie", &a));
    if (strcmp(a.json, "\"siv=kept-across-exits\"")) fprintf(stderr, "document.cookie after a restart: %s\n", a.json);
    CHECK(!strcmp(a.json, "\"siv=kept-across-exits\""));
    stop(&f);
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, eph));
    CHECK(load(&f, "<p>x", "https://example.test/"));
    CHECK(eval(&f, "document.cookie = 'siv=ephemeral; Max-Age=3600; Path=/'; document.cookie", &a));
    CHECK(!strcmp(a.json, "\"siv=ephemeral\""));
    pump(&f, 500);
    stop(&f);
    char db[64];
    snprintf(db, sizeof db, "%s/cookies.sqlite", eph);
    CHECK(access(db, F_OK) != 0);
    char cmd[128];
    snprintf(cmd, sizeof cmd, "rm -rf '%s' '%s'", dir, eph);
    CHECK(system(cmd) == 0);
}

static void check_zoom_and_scheme(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f, "<p>x", NULL));
    CHECK(siv_webview_set_zoom(f.webview, 2) == SIV_OK);
    siv_webview_state st = {.size = sizeof st};
    CHECK(siv_webview_get_state(f.webview, &st) == SIV_OK);
    CHECK(st.zoom == 2);
    CHECK(siv_webview_set_color_scheme(f.webview, SIV_COLOR_SCHEME_DARK) == SIV_OK);
    struct answer a;
    double end = now() + 5;
    do CHECK(eval(&f, "matchMedia('(prefers-color-scheme: dark)').matches", &a));
    while (strcmp(a.json, "true") && now() < end);
    CHECK(!strcmp(a.json, "true"));
    CHECK(siv_webview_set_color_scheme(f.webview, SIV_COLOR_SCHEME_LIGHT) == SIV_OK);
    end = now() + 5;
    do CHECK(eval(&f, "matchMedia('(prefers-color-scheme: dark)').matches", &a));
    while (strcmp(a.json, "false") && now() < end);
    CHECK(!strcmp(a.json, "false"));
    stop(&f);
}

/* The page sees the headless seat's pointer: hover-only controls (Tailwind's
 * pointer-fine:group-hover:...) show. */
static void check_input_devices(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f, "<p>x", NULL));
    struct answer a;
    CHECK(eval(&f, "['(pointer: fine)', '(hover: hover)', '(any-pointer: fine)', '(any-hover: hover)', '(any-pointer: coarse)'].map(q => matchMedia(q).matches)", &a));
    if (strcmp(a.json, "[true,true,true,true,false]")) fprintf(stderr, "media queries: %s\n", a.json);
    CHECK(!strcmp(a.json, "[true,true,true,true,false]"));
    stop(&f);
}

static void check_history(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(siv_webview_register_scheme(f.app, SIV_STR("app"), serve, NULL, NULL) == SIV_OK);
    CHECK(siv_webview_go_back(f.webview) == SIV_ERROR_BUSY);
    CHECK(siv_webview_load_uri(f.webview, SIV_STR("app://res/index.html")) == SIV_OK);
    CHECK(wait_title(&f, "fetched"));
    CHECK(siv_webview_load_uri(f.webview, SIV_STR("app://res/second.html")) == SIV_OK);
    CHECK(wait_title(&f, "second"));
    CHECK(siv_webview_go_back(f.webview) == SIV_OK);
    CHECK(wait_title(&f, "fetched"));
    siv_webview_state st = {.size = sizeof st};
    CHECK(siv_webview_get_state(f.webview, &st) == SIV_OK);
    CHECK(st.flags & SIV_WEBVIEW_CAN_GO_FORWARD);
    CHECK(siv_webview_go_forward(f.webview) == SIV_OK);
    CHECK(wait_title(&f, "second"));
    stop(&f);
}

/* Text and URLs dropped on the node reach the page as DOM drag events;
 * editable elements take text a page does not handle. */
static void check_drop(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f,
               "<style>body{margin:0} #z{height:100px} input{display:block;width:300px}</style>"
               "<div id=z></div><input id=f>"
               "<script>z.addEventListener('dragover', e => e.preventDefault());"
               "z.addEventListener('drop', e => { e.preventDefault(); document.title = e.dataTransfer.getData('text/plain') + ' ' + e.dataTransfer.getData('text/uri-list'); });</script>",
               "https://example.test/"));
    bool settled;
    const char *uris = "# comment\r\nhttps://example.test/a\r\nhttps://example.test/b\r\n";
    CHECK(siv_test_drop(f.window, 50, 50, SIV_STR("text/uri-list"), (const uint8_t *)uris, strlen(uris)) == SIV_OK);
    CHECK(siv_test_settle(f.app, 1000, &settled) == SIV_OK);
    /* (The title collapses the list's line break.) */
    CHECK(wait_title(&f, "https://example.test/a https://example.test/a https://example.test/b"));
    CHECK(siv_test_drop(f.window, 50, 110, SIV_STR("text/plain;charset=utf-8"), (const uint8_t *)"dropped", 7) == SIV_OK);
    CHECK(siv_test_settle(f.app, 1000, &settled) == SIV_OK);
    struct answer a;
    double end = now() + 10;
    do CHECK(eval(&f, "document.getElementById('f').value", &a));
    while (strcmp(a.json, "\"dropped\"") && now() < end);
    CHECK(!strcmp(a.json, "\"dropped\""));
    stop(&f);
}

/* A wheel that sends only a distance (no value120: Hyprland's virtual
 * pointers, older compositors) scrolls the page: by line steps, 15 per
 * detent, so 45 is three of them. */
static void check_wheel(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f, "<body style='margin:0;height:5000px'>", NULL));
    CHECK(siv_test_pointer_move(f.window, 100, 100) == SIV_OK);
    CHECK(siv_test_scroll(f.window, 0, 45) == SIV_OK);
    bool settled;
    CHECK(siv_test_settle(f.app, 1000, &settled) == SIV_OK);
    struct answer a;
    double end = now() + 10;
    int y = 0;
    do {
        pump(&f, 50);
        CHECK(eval(&f, "scrollY", &a));
        y = atoi(a.json);
    } while (y < 100 && now() < end);
    CHECK(y >= 100);
    stop(&f);
}

/* Pages for the user script check: the inline script reads what the user
 * scripts left, and the frame reports to its parent. */
static void serve_user(void *user_data, siv_webview_request request, const char *uri, size_t uri_len, const char *method, size_t method_len) {
    (void)user_data, (void)method, (void)method_len;
    const char *page = NULL;
    if (uri_len == strlen("app://u/one.html") && !memcmp(uri, "app://u/one.html", uri_len))
        page = "<iframe src='app://u/frame.html'></iframe>"
               "<script>document.title = ['one', document.documentElement.dataset.shell, window.order].join(' ')</script>";
    else if (uri_len == strlen("app://u/two.html") && !memcmp(uri, "app://u/two.html", uri_len))
        page = "<script>document.title = ['two', document.documentElement.dataset.shell, window.order].join(' ')</script>";
    else if (uri_len == strlen("app://u/frame.html") && !memcmp(uri, "app://u/frame.html", uri_len))
        page = "<script>parent.frameReport = [document.documentElement.dataset.shell, window.allFrames].join(',')</script>";
    if (page) (void)siv_webview_request_finish(request, 0, SIV_STR("text/html"), (const uint8_t *)page, strlen(page));
    else (void)siv_webview_request_fail(request);
}

/* User scripts: at document start before the page's own scripts (after
 * window.siv, in the order added), at document end after them, in the main
 * frame unless all frames are asked for, again after a navigation, and
 * gone after removal. */
static void check_user_scripts(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(siv_webview_register_scheme(f.app, SIV_STR("app"), serve_user, NULL, NULL) == SIV_OK);
    uint64_t shell = 0, second = 0, end = 0, frames = 0;
    CHECK(siv_webview_add_user_script(f.webview, SIV_STR("document.documentElement.dataset.shell = 'siv'; window.order = typeof siv + ',start'"), 0, &shell) == SIV_OK);
    CHECK(siv_webview_add_user_script(f.webview, SIV_STR("window.order += ',second'"), 0, &second) == SIV_OK);
    CHECK(siv_webview_add_user_script(f.webview, SIV_STR("document.title += ' end'"), SIV_WEBVIEW_SCRIPT_DOCUMENT_END, &end) == SIV_OK);
    CHECK(siv_webview_add_user_script(f.webview, SIV_STR("window.allFrames = 'all'"), SIV_WEBVIEW_SCRIPT_ALL_FRAMES, &frames) == SIV_OK);
    CHECK(shell && second && end && frames && shell != second && end != frames);
    CHECK(siv_webview_add_user_script(f.webview, SIV_STR("1"), 1u << 2, NULL) == SIV_ERROR_INVALID_ARGUMENT);

    CHECK(siv_webview_load_uri(f.webview, SIV_STR("app://u/one.html")) == SIV_OK);
    CHECK(wait_title(&f, "one siv object,start,second end"));
    /* The frame got the all-frames script only. */
    struct answer a;
    double until = now() + 30;
    do {
        CHECK(eval(&f, "window.frameReport || ''", &a));
        if (strcmp(a.json, "\"\"")) break;
        pump(&f, 20);
    } while (now() < until);
    CHECK(!strcmp(a.json, "\",all\""));
    /* Added scripts wait for the next load. */
    CHECK(siv_webview_add_user_script(f.webview, SIV_STR("window.late = 1"), 0, NULL) == SIV_OK);
    CHECK(eval(&f, "typeof window.late", &a));
    CHECK(!strcmp(a.json, "\"undefined\""));

    /* A navigation by the page runs them again. */
    CHECK(eval(&f, "location.href = 'app://u/two.html'; 1", &a));
    CHECK(wait_title(&f, "two siv object,start,second end"));
    CHECK(eval(&f, "window.late", &a));
    CHECK(!strcmp(a.json, "1"));

    /* Removed scripts stay out from the next load on. */
    CHECK(siv_webview_remove_user_script(f.webview, second) == SIV_OK);
    CHECK(siv_webview_remove_user_script(f.webview, end) == SIV_OK);
    CHECK(siv_webview_remove_user_script(f.webview, end) == SIV_ERROR_INVALID_ARGUMENT);
    CHECK(siv_webview_remove_user_script(f.webview, 0) == SIV_ERROR_INVALID_ARGUMENT);
    CHECK(!strcmp(f.seen.title, "two siv object,start,second end"));
    CHECK(siv_webview_reload(f.webview) == SIV_OK);
    CHECK(wait_title(&f, "two siv object,start"));
    stop(&f);
}

/* SIV_WEBVIEW_NO_SCRIPTS: neither the page's scripts nor run_script's
 * run. */
static void check_no_scripts(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL | SIV_WEBVIEW_NO_SCRIPTS, NULL));
    CHECK(load(&f, "<title>static</title><script>document.title = 'ran'</script>", NULL));
    CHECK(wait_title(&f, "static"));
    pump(&f, 200);
    CHECK(!strcmp(f.seen.title, "static"));
    struct answer a;
    CHECK(eval(&f, "typeof window.siv", &a));
    CHECK(a.result == SIV_ERROR_UNAVAILABLE);
    stop(&f);
}

/* A page that plays audio, from markup and from script. */
#define WAV "data:audio/wav;base64,UklGRiwAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQgAAAAAAAAAAAAAAA=="
static const char audio_page[] =
    "<title>audio</title><audio autoplay src='" WAV "'></audio><script>"
    "new Audio('" WAV "').play().catch(function () {});"
    "var a = document.createElement('audio'); a.src = '" WAV "'; document.body.appendChild(a); a.play();"
    "</script>";

/* The no-audio-sink check's child: the page loads, and its web process
 * lives on. */
static void check_audio_page(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f, audio_page, NULL));
    pump(&f, 1000);
    CHECK(f.seen.crashed == 0);
    struct answer a;
    CHECK(eval(&f, "document.title", &a));
    CHECK(a.result == SIV_OK && !strcmp(a.json, "\"audio\""));
    stop(&f);
}

/* Without GStreamer's autoaudiosink (gst-plugins-good), WebKit's web
 * process aborts when a page plays audio: siv-webview says what to install
 * and turns media off, and the page loads. check_audio_page runs in a
 * child whose GStreamer sees the system's plugins except autodetect's,
 * since the environment must be set before GStreamer starts (in the test
 * and in the web process). The plugins are next to libgstreamer, which
 * WebKit loaded. */
static void check_no_audio_sink(void) {
    void *gst = dlopen("libgstreamer-1.0.so.0", RTLD_NOW | RTLD_NOLOAD);
    Dl_info info = {0};
    if (gst) (void)dladdr(dlsym(gst, "gst_init"), &info);
    const char *slash = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
    char plugins[512] = "";
    if (slash) snprintf(plugins, sizeof plugins, "%.*s/gstreamer-1.0", (int)(slash - info.dli_fname), info.dli_fname);
    if (gst) dlclose(gst);
    struct stat st;
    if (!*plugins || stat(plugins, &st) != 0) {
        printf("     no GStreamer plugins beside WebKit's libgstreamer; skipped\n");
        return;
    }
    char exe[512];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    CHECK(n > 0);
    exe[n] = 0;
    char dir[] = "/tmp/siv-webview-test-XXXXXX";
    CHECK(mkdtemp(dir) != NULL);
    char cmd[4096];
    snprintf(cmd, sizeof cmd,
             "mkdir '%s/plugins' && for p in '%s'/*.so; do [ \"${p##*/}\" = libgstautodetect.so ] || ln -s \"$p\" '%s/plugins/'; done && "
             "env -u GST_PLUGIN_PATH -u GST_PLUGIN_PATH_1_0 -u GST_PLUGIN_SYSTEM_PATH_1_0 -u GST_REGISTRY_1_0 "
             "GST_PLUGIN_SYSTEM_PATH='%s/plugins' GST_REGISTRY='%s/registry.bin' SIV_WEBVIEW_TEST_AUDIO_PAGE=1 '%s' 2>'%s/stderr'",
             dir, plugins, dir, dir, dir, exe, dir);
    int status = system(cmd);
    char err[16384] = "";
    snprintf(cmd, sizeof cmd, "%s/stderr", dir);
    FILE *file = fopen(cmd, "r");
    if (file) err[fread(err, 1, sizeof err - 1, file)] = 0, fclose(file);
    bool told = strstr(err, "autoaudiosink") && strstr(err, "gst-plugins-good");
    if (status != 0 || !told) fprintf(stderr, "the child's stderr:\n%s\n", err);
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
    CHECK(system(cmd) == 0);
    CHECK(status == 0);
    CHECK(told);
}

/* Waits until the script's JSON answer is `want`. */
static bool wait_eval(struct fixture *f, const char *script, const char *want) {
    struct answer a = {0};
    double end = now() + 10;
    while (now() < end) {
        if (!eval(f, script, &a)) return false;
        if (!strcmp(a.json, want)) return true;
        pump(f, 20);
    }
    fprintf(stderr, "%s: want %s, have %s\n", script, want, a.json);
    return false;
}

static long eval_long(struct fixture *f, const char *script) {
    struct answer a;
    if (!eval(f, script, &a) || a.result != SIV_OK) return -1;
    return atol(a.json);
}

/* The page is hidden, and its animation frames stop, while the window is
 * suspended or the node is hidden; both come back after. */
static void check_visibility(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f, "<script>window.n = 0; (function tick() { n++; requestAnimationFrame(tick); })();</script>", NULL));
    CHECK(wait_eval(&f, "document.visibilityState", "\"visible\""));
    long a = eval_long(&f, "n");
    pump(&f, 300);
    CHECK(eval_long(&f, "n") > a + 3);

    CHECK(siv_test_set_states(f.window, SIV_WINDOW_STATES_SUSPENDED) == SIV_OK);
    CHECK(wait_eval(&f, "document.visibilityState", "\"hidden\""));
    a = eval_long(&f, "n");
    pump(&f, 500);
    CHECK(eval_long(&f, "n") == a);
    CHECK(siv_test_set_states(f.window, 0) == SIV_OK);
    CHECK(wait_eval(&f, "document.visibilityState", "\"visible\""));
    a = eval_long(&f, "n");
    pump(&f, 300);
    CHECK(eval_long(&f, "n") > a + 3);

    siv_txn txn;
    CHECK(siv_txn_begin(f.window, &txn) == SIV_OK);
    siv_set_hidden(txn, f.node, true);
    CHECK(siv_txn_commit(txn) == SIV_OK);
    CHECK(wait_eval(&f, "document.visibilityState", "\"hidden\""));
    a = eval_long(&f, "n");
    pump(&f, 500);
    CHECK(eval_long(&f, "n") == a);
    CHECK(siv_txn_begin(f.window, &txn) == SIV_OK);
    siv_set_hidden(txn, f.node, false);
    CHECK(siv_txn_commit(txn) == SIV_OK);
    CHECK(wait_eval(&f, "document.visibilityState", "\"visible\""));
    a = eval_long(&f, "n");
    pump(&f, 300);
    CHECK(eval_long(&f, "n") > a + 3);
    stop(&f);
}

/* The page has focus while the window is activated (the user's
 * attention), not otherwise. */
static void check_window_active(void) {
    struct fixture f;
    CHECK(start(&f, SIV_WEBVIEW_EPHEMERAL, NULL));
    CHECK(load(&f, "<input autofocus>", NULL));
    CHECK(siv_test_click(f.window, 10, 10, SIV_POINTER_BUTTON_PRIMARY) == SIV_OK);
    CHECK(siv_test_set_states(f.window, SIV_WINDOW_STATES_ACTIVATED) == SIV_OK);
    CHECK(wait_eval(&f, "document.hasFocus()", "true"));
    CHECK(siv_test_set_states(f.window, 0) == SIV_OK);
    CHECK(wait_eval(&f, "document.hasFocus()", "false"));
    CHECK(siv_test_set_states(f.window, SIV_WINDOW_STATES_ACTIVATED) == SIV_OK);
    CHECK(wait_eval(&f, "document.hasFocus()", "true"));
    stop(&f);
}

static const struct {
    const char *name;
    void (*fn)(void);
} checks[] = {
    {"load and title", check_load_and_title},
    {"run script", check_run_script},
    {"messages", check_messages},
    {"user scripts", check_user_scripts},
    {"scheme", check_scheme},
    {"navigation policy", check_navigation_policy},
    {"input and new window", check_input_and_new_window},
    {"frames", check_frames},
    {"data dir", check_data_dir},
    {"cookies", check_cookies},
    {"zoom and color scheme", check_zoom_and_scheme},
    {"input devices", check_input_devices},
    {"history", check_history},
    {"drop", check_drop},
    {"wheel", check_wheel},
    {"no scripts", check_no_scripts},
    {"visibility", check_visibility},
    {"window active", check_window_active},
    {"no audio sink", check_no_audio_sink},
};

int main(int argc, char **argv) {
    if (!getenv("SIV_WEBVIEW_TEST_GPU")) setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    if (siv_webview_engine_available(SIV_WEBVIEW_ENGINE_AUTO) != SIV_OK) {
        fprintf(stderr, "siv-webview-test: no engine available; skipped\n");
        return 77;
    }
    if (getenv("SIV_WEBVIEW_TEST_AUDIO_PAGE")) {
        check_audio_page();
        return failures ? 1 : 0;
    }
    int ran = 0;
    for (size_t i = 0; i < sizeof checks / sizeof checks[0]; i++) {
        if (argc > 1 && !strstr(checks[i].name, argv[1])) continue;
        int before = failures;
        double t = now();
        checks[i].fn();
        ran++;
        printf("%s %s (%.0f ms)\n", failures == before ? "ok  " : "FAIL", checks[i].name, (now() - t) * 1000);
        fflush(stdout);
    }
    printf("%d of %d passed\n", ran - failures, ran);
    return failures ? 1 : 0;
}
