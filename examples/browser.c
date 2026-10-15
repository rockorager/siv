/* A small browser: an address bar, back, forward, and reload, and a web
 * view below them.
 *
 *     siv-webview-browser [URL]
 *
 * Ctrl+L focuses the address bar; the page's title is the window's. */
#include <siv-webview.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct browser {
    siv_app app;
    siv_window window;
    siv_webview webview;
    siv_node address, back, forward, reload, page;
};

static void set_address(struct browser *b, const char *uri, size_t len) {
    siv_txn txn;
    if (siv_txn_begin(b->window, &txn) != SIV_OK) return;
    siv_set_text(txn, b->address, uri, len);
    if (siv_txn_commit(txn) != SIV_OK) fprintf(stderr, "browser: cannot set the address\n");
}

static void set_history(struct browser *b, siv_webview_event_flags flags) {
    siv_txn txn;
    if (siv_txn_begin(b->window, &txn) != SIV_OK) return;
    siv_widget_set_disabled(txn, b->back, !(flags & SIV_WEBVIEW_CAN_GO_BACK));
    siv_widget_set_disabled(txn, b->forward, !(flags & SIV_WEBVIEW_CAN_GO_FORWARD));
    if (siv_txn_commit(txn) != SIV_OK) fprintf(stderr, "browser: cannot update the buttons\n");
}

static bool on_webview(void *user_data, siv_webview webview, const siv_webview_event *e) {
    (void)webview;
    struct browser *b = user_data;
    switch (e->type) {
    case SIV_WEBVIEW_EVENT_TITLE:
        if (e->text_len && siv_window_set_title(b->window, e->text, e->text_len) != SIV_OK) fprintf(stderr, "browser: cannot set the title\n");
        return false;
    case SIV_WEBVIEW_EVENT_URI:
        set_address(b, e->uri, e->uri_len);
        return false;
    case SIV_WEBVIEW_EVENT_HISTORY:
        set_history(b, e->flags);
        return false;
    case SIV_WEBVIEW_EVENT_LOAD_FAILED:
        fprintf(stderr, "browser: %.*s: %.*s\n", (int)e->uri_len, e->uri, (int)e->text_len, e->text);
        return false;
    case SIV_WEBVIEW_EVENT_PERMISSION:
        /* A real browser would ask; this one says no. */
        return false;
    default:
        return false;
    }
}

static void go(struct browser *b, const char *text, size_t len) {
    if (!len) return;
    char *uri;
    if (memmem(text, len, "://", 3) || (len > 6 && !memcmp(text, "about:", 6))) {
        uri = strndup(text, len);
    } else if (len && text[0] == '/') {
        uri = malloc(len + 8);
        if (uri) memcpy(uri, "file://", 7), memcpy(uri + 7, text, len), uri[len + 7] = 0;
    } else {
        uri = malloc(len + 9);
        if (uri) memcpy(uri, "https://", 8), memcpy(uri + 8, text, len), uri[len + 8] = 0;
    }
    if (!uri) return;
    if (siv_webview_load_uri(b->webview, uri, strlen(uri)) != SIV_OK) fprintf(stderr, "browser: cannot load %s\n", uri);
    free(uri);
    if (siv_node_focus(b->page) != SIV_OK) fprintf(stderr, "browser: cannot focus the page\n");
}

static siv_event_result on_address_key(void *user_data, siv_node node, const siv_event *e) {
    struct browser *b = user_data;
    if (!(e->flags & SIV_EVENT_PRESSED) || (e->keysym != SIV_KEY_RETURN && e->keysym != SIV_KEY_KP_ENTER)) return SIV_EVENT_RESULT_PASS;
    char text[4096];
    size_t len = 0;
    if (siv_node_get_text(node, text, sizeof text, &len) == SIV_OK && len <= sizeof text) go(b, text, len);
    return SIV_EVENT_RESULT_HANDLED;
}

/* Window-wide shortcuts, before the page or the field sees the key. */
static siv_event_result on_capture_key(void *user_data, siv_node node, const siv_event *e) {
    (void)node;
    struct browser *b = user_data;
    if (!(e->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
    bool ctrl = e->modifiers & SIV_MODIFIERS_CTRL, alt = e->modifiers & SIV_MODIFIERS_ALT;
    if (ctrl && (e->keysym == 'l' || e->keysym == 'L')) {
        if (siv_node_focus(b->address) != SIV_OK) fprintf(stderr, "browser: cannot focus the address\n");
        return SIV_EVENT_RESULT_HANDLED;
    }
    if ((alt && e->keysym == SIV_KEY_LEFT) || e->keysym == SIV_KEY_BACK) return siv_webview_go_back(b->webview) == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
    if ((alt && e->keysym == SIV_KEY_RIGHT) || e->keysym == SIV_KEY_FORWARD) return siv_webview_go_forward(b->webview) == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
    if ((ctrl && (e->keysym == 'r' || e->keysym == 'R')) || e->keysym == SIV_KEY_F5) return siv_webview_reload(b->webview) == SIV_OK ? SIV_EVENT_RESULT_HANDLED : SIV_EVENT_RESULT_PASS;
    return SIV_EVENT_RESULT_PASS;
}

static siv_event_result on_button(void *user_data, siv_node node, const siv_event *e) {
    (void)e;
    struct browser *b = user_data;
    siv_result r = node == b->back ? siv_webview_go_back(b->webview) : node == b->forward ? siv_webview_go_forward(b->webview) : siv_webview_reload(b->webview);
    if (r != SIV_OK) fprintf(stderr, "browser: %s\n", siv_result_name(r));
    return SIV_EVENT_RESULT_HANDLED;
}

static siv_result build(struct browser *b) {
    siv_txn txn;
    siv_result r = siv_txn_begin(b->window, &txn);
    if (r != SIV_OK) return r;
    siv_node root = siv_window_get_root(b->window);
    siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
    siv_on_capture(txn, root, SIV_EVENT_TYPE_KEY, on_capture_key, NULL, b);
    siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN));
    siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
    siv_node bar = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_ROW, .gap = 6, .align_items = SIV_ALIGN_CENTER));
    siv_set_layout(txn, bar, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .padding = {6, 6, 6, 6}));
    b->back = siv_push_button(txn, bar, SIV_DESC(siv_button_desc, .label = SIV_STR("Back"), .icon = SIV_STR("go-previous-symbolic"), .flags = SIV_WIDGET_ICON_ONLY | SIV_WIDGET_DISABLED));
    b->forward = siv_push_button(txn, bar, SIV_DESC(siv_button_desc, .label = SIV_STR("Forward"), .icon = SIV_STR("go-next-symbolic"), .flags = SIV_WIDGET_ICON_ONLY | SIV_WIDGET_DISABLED));
    b->reload = siv_push_button(txn, bar, SIV_DESC(siv_button_desc, .label = SIV_STR("Reload"), .icon = SIV_STR("view-refresh-symbolic"), .flags = SIV_WIDGET_ICON_ONLY));
    siv_on(txn, b->back, SIV_EVENT_TYPE_ACTIVATE, on_button, NULL, b);
    siv_on(txn, b->forward, SIV_EVENT_TYPE_ACTIVATE, on_button, NULL, b);
    siv_on(txn, b->reload, SIV_EVENT_TYPE_ACTIVATE, on_button, NULL, b);
    b->address = siv_text_field(txn, bar, SIV_DESC(siv_text_field_desc, .placeholder = SIV_STR("Search or enter address"), .label = SIV_STR("Address")));
    siv_set_layout(txn, b->address, SIV_DESC(siv_layout_desc, .grow = 1));
    siv_on(txn, b->address, SIV_EVENT_TYPE_KEY, on_address_key, NULL, b);
    b->page = siv_webview_view(txn, column, b->webview);
    siv_set_layout(txn, b->page, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .basis = {SIV_UNIT_PX, 0}, .grow = 1));
    return siv_txn_commit(txn);
}

int main(int argc, char **argv) {
    struct browser b = {0};
    const char *url = argc > 1 ? argv[1] : "https://example.com";
    siv_result r = siv_app_create(SIV_DESC(siv_app_desc, .app_id = SIV_STR("dev.siv.WebviewBrowser")), &b.app);
    if (r == SIV_OK) r = siv_window_create(b.app, SIV_DESC(siv_window_desc, .title = SIV_STR("Browser"), .app_id = SIV_STR("dev.siv.WebviewBrowser"), .width = 1280, .height = 800), &b.window);
    if (r == SIV_OK) r = siv_webview_create(b.window, SIV_DESC(siv_webview_desc, .user_data = &b, .on_event = on_webview, .flags = getenv("BROWSER_INSPECTOR") ? SIV_WEBVIEW_DEVELOPER_EXTRAS : 0, .inspector_port = 9222), &b.webview);
    if (r == SIV_OK) r = build(&b);
    if (r == SIV_OK) r = siv_webview_load_uri(b.webview, url, strlen(url));
    if (r == SIV_OK && siv_node_focus(b.page) != SIV_OK) fprintf(stderr, "browser: cannot focus the page\n");
    if (r == SIV_OK) r = siv_app_run(b.app);
    if (r != SIV_OK) fprintf(stderr, "browser: %s\n", siv_result_name(r));
    siv_app_destroy(b.app);
    return r == SIV_OK ? 0 : 1;
}
