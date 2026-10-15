/* Included by wpe.c: the WebKit side of the WPE engine. Web views, their
 * signals turned into siv-webview events and siv popups, input from the
 * node turned into WPE events, and the engine table. */

/* ---------- applications ---------- */

static siv_result wpe_available(void) {
    return webkit_get_major_version() >= 2 && webkit_get_minor_version() >= 50 ? SIV_OK : SIV_ERROR_UNSUPPORTED;
}

static siv_result wpe_app_init(swv_app *a) {
    wpe_app *wa = calloc(1, sizeof *wa);
    if (!wa) return SIV_ERROR_OUT_OF_MEMORY;
    wa->app = a;
    SwvDisplay *display = g_object_new(swv_display_get_type(), NULL);
    display->app = wa;
    wa->display = WPE_DISPLAY(display);
    GError *err = NULL;
    if (!wpe_display_connect(wa->display, &err)) {
        fprintf(stderr, "siv-webview: %s\n", err ? err->message : "cannot connect the WPE display");
        g_clear_error(&err);
        g_object_unref(wa->display);
        free(wa);
        return SIV_ERROR_UNAVAILABLE;
    }
    wa->sessions = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
    wa->clip = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_bytes_unref);
    a->engine_data = wa;
    return SIV_OK;
}

static void wpe_app_fini(swv_app *a) {
    wpe_app *wa = a->engine_data;
    if (!wa) return;
    g_clear_object(&wa->context);
    g_hash_table_unref(wa->sessions);
    g_hash_table_unref(wa->clip);
    g_clear_object(&wa->display);
    free(wa);
    a->engine_data = NULL;
}

/* ---------- schemes ---------- */

static void on_scheme_request(WebKitURISchemeRequest *request, gpointer user_data) {
    swv_scheme *s = user_data;
    siv_webview_request handle = swv_handle_insert(&swv_requests, g_object_ref(request));
    if (!handle) {
        GError *err = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_NO_SPACE, "out of memory");
        webkit_uri_scheme_request_finish_error(request, err);
        g_error_free(err);
        g_object_unref(request);
        return;
    }
    const char *uri = webkit_uri_scheme_request_get_uri(request);
    const char *method = webkit_uri_scheme_request_get_http_method(request);
    if (!method) method = "GET";
    s->callback(s->user_data, handle, uri, strlen(uri), method, strlen(method));
}

static void register_scheme(wpe_app *wa, swv_scheme *s) {
    webkit_web_context_register_uri_scheme(wa->context, s->name, on_scheme_request, s, NULL);
    WebKitSecurityManager *sec = webkit_web_context_get_security_manager(wa->context);
    webkit_security_manager_register_uri_scheme_as_secure(sec, s->name);
    webkit_security_manager_register_uri_scheme_as_cors_enabled(sec, s->name);
}

static void wpe_scheme_added(swv_app *a, swv_scheme *s) {
    wpe_app *wa = a->engine_data;
    if (wa && wa->context) register_scheme(wa, s);
}

static siv_result wpe_request_finish(void *req, uint32_t status, const char *content_type, const uint8_t *data, size_t len) {
    WebKitURISchemeRequest *request = req;
    GBytes *bytes = g_bytes_new(data, len);
    GInputStream *stream = g_memory_input_stream_new_from_bytes(bytes);
    WebKitURISchemeResponse *response = webkit_uri_scheme_response_new(stream, (gint64)len);
    webkit_uri_scheme_response_set_status(response, status, NULL);
    if (*content_type) webkit_uri_scheme_response_set_content_type(response, content_type);
    webkit_uri_scheme_request_finish_with_response(request, response);
    g_object_unref(response);
    g_object_unref(stream);
    g_bytes_unref(bytes);
    g_object_unref(request);
    return SIV_OK;
}

static siv_result wpe_request_fail(void *req) {
    WebKitURISchemeRequest *request = req;
    GError *err = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "not found");
    webkit_uri_scheme_request_finish_error(request, err);
    g_error_free(err);
    g_object_unref(request);
    return SIV_OK;
}

/* ---------- events from WebKit ---------- */

static void emit_simple(wpe_wv *w, siv_webview_event_type type) {
    swv_emit(w->wv, &(siv_webview_event){.type = type});
}

static void set_str(char **slot, const char *v) {
    g_free(*slot);
    *slot = g_strdup(v ? v : "");
}

static void on_load_changed(WebKitWebView *web_view, WebKitLoadEvent ev, wpe_wv *w) {
    const char *uri = webkit_web_view_get_uri(web_view);
    set_str(&w->uri, uri);
    static const siv_webview_load_state states[] = {SIV_WEBVIEW_LOAD_STARTED, SIV_WEBVIEW_LOAD_REDIRECTED, SIV_WEBVIEW_LOAD_COMMITTED, SIV_WEBVIEW_LOAD_FINISHED};
    siv_webview_event e = {.type = SIV_WEBVIEW_EVENT_LOAD, .load_state = states[ev], .uri = w->uri, .uri_len = strlen(w->uri)};
    if (ev != WEBKIT_LOAD_FINISHED) e.flags |= SIV_WEBVIEW_LOADING;
    swv_emit(w->wv, &e);
}

static gboolean on_load_failed(WebKitWebView *web_view, WebKitLoadEvent ev, const char *uri, GError *error, wpe_wv *w) {
    (void)web_view, (void)ev;
    /* A load the application stopped or replaced is not a failure. */
    if (g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED) || g_error_matches(error, WEBKIT_POLICY_ERROR, WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE)) return FALSE;
    const char *msg = error ? error->message : "";
    swv_emit(w->wv, &(siv_webview_event){.type = SIV_WEBVIEW_EVENT_LOAD_FAILED, .uri = uri, .uri_len = uri ? strlen(uri) : 0, .text = msg, .text_len = strlen(msg)});
    return FALSE;
}

static void on_title(WebKitWebView *web_view, GParamSpec *p, wpe_wv *w) {
    (void)p;
    set_str(&w->title, webkit_web_view_get_title(web_view));
    swv_emit(w->wv, &(siv_webview_event){.type = SIV_WEBVIEW_EVENT_TITLE, .text = w->title, .text_len = strlen(w->title)});
}

static void on_uri(WebKitWebView *web_view, GParamSpec *p, wpe_wv *w) {
    (void)p;
    set_str(&w->uri, webkit_web_view_get_uri(web_view));
    swv_emit(w->wv, &(siv_webview_event){.type = SIV_WEBVIEW_EVENT_URI, .uri = w->uri, .uri_len = strlen(w->uri)});
}

static void on_progress(WebKitWebView *web_view, GParamSpec *p, wpe_wv *w) {
    (void)p;
    swv_emit(w->wv, &(siv_webview_event){.type = SIV_WEBVIEW_EVENT_PROGRESS, .progress = webkit_web_view_get_estimated_load_progress(web_view)});
}

static siv_webview_event_flags history_flags(wpe_wv *w) {
    siv_webview_event_flags f = 0;
    if (webkit_web_view_can_go_back(w->web_view)) f |= SIV_WEBVIEW_CAN_GO_BACK;
    if (webkit_web_view_can_go_forward(w->web_view)) f |= SIV_WEBVIEW_CAN_GO_FORWARD;
    if (webkit_web_view_is_loading(w->web_view)) f |= SIV_WEBVIEW_LOADING;
    return f;
}

static void on_history(WebKitBackForwardList *list, WebKitBackForwardListItem *added, gpointer removed, wpe_wv *w) {
    (void)list, (void)added, (void)removed;
    swv_emit(w->wv, &(siv_webview_event){.type = SIV_WEBVIEW_EVENT_HISTORY, .flags = history_flags(w)});
}

static void on_close(WebKitWebView *web_view, wpe_wv *w) {
    (void)web_view;
    emit_simple(w, SIV_WEBVIEW_EVENT_CLOSE);
}

static void on_terminated(WebKitWebView *web_view, WebKitWebProcessTerminationReason reason, wpe_wv *w) {
    (void)web_view;
    const char *why = reason == WEBKIT_WEB_PROCESS_CRASHED ? "crashed" : reason == WEBKIT_WEB_PROCESS_EXCEEDED_MEMORY_LIMIT ? "exceeded its memory limit" : "terminated by the application";
    swv_emit(w->wv, &(siv_webview_event){.type = SIV_WEBVIEW_EVENT_CRASHED, .text = why, .text_len = strlen(why)});
}

static bool new_window(wpe_wv *w, WebKitNavigationAction *action) {
    WebKitURIRequest *req = webkit_navigation_action_get_request(action);
    const char *uri = req ? webkit_uri_request_get_uri(req) : NULL;
    siv_webview_event e = {.type = SIV_WEBVIEW_EVENT_NEW_WINDOW, .uri = uri, .uri_len = uri ? strlen(uri) : 0};
    if (webkit_navigation_action_is_user_gesture(action)) e.flags |= SIV_WEBVIEW_USER_GESTURE;
    if (swv_emit(w->wv, &e)) return true;
    if (uri && *uri) webkit_web_view_load_uri(w->web_view, uri);
    return true;
}

static gboolean on_decide_policy(WebKitWebView *web_view, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type, wpe_wv *w) {
    (void)web_view;
    switch (type) {
    case WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION: {
        WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        WebKitURIRequest *req = webkit_navigation_action_get_request(action);
        const char *uri = req ? webkit_uri_request_get_uri(req) : "";
        siv_webview_event e = {.type = SIV_WEBVIEW_EVENT_NAVIGATE, .uri = uri, .uri_len = strlen(uri), .flags = SIV_WEBVIEW_MAIN_FRAME};
        if (webkit_navigation_action_is_user_gesture(action)) e.flags |= SIV_WEBVIEW_USER_GESTURE;
        if (webkit_navigation_action_is_redirect(action)) e.flags |= SIV_WEBVIEW_REDIRECT;
        if (swv_emit(w->wv, &e)) webkit_policy_decision_ignore(decision);
        else webkit_policy_decision_use(decision);
        return TRUE;
    }
    case WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION: {
        WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        new_window(w, action);
        webkit_policy_decision_ignore(decision);
        return TRUE;
    }
    case WEBKIT_POLICY_DECISION_TYPE_RESPONSE:
        if (!webkit_response_policy_decision_is_mime_type_supported(WEBKIT_RESPONSE_POLICY_DECISION(decision))) {
            webkit_policy_decision_download(decision);
            return TRUE;
        }
        return FALSE;
    default:
        return FALSE;
    }
}

static WebKitWebView *on_create(WebKitWebView *web_view, WebKitNavigationAction *action, wpe_wv *w) {
    (void)web_view;
    new_window(w, action);
    return NULL;
}

static siv_webview_permission permission_kind(WebKitPermissionRequest *r) {
    if (WEBKIT_IS_GEOLOCATION_PERMISSION_REQUEST(r)) return SIV_WEBVIEW_PERMISSION_GEOLOCATION;
    if (WEBKIT_IS_NOTIFICATION_PERMISSION_REQUEST(r)) return SIV_WEBVIEW_PERMISSION_NOTIFICATIONS;
    if (WEBKIT_IS_USER_MEDIA_PERMISSION_REQUEST(r)) return SIV_WEBVIEW_PERMISSION_MEDIA;
    return SIV_WEBVIEW_PERMISSION_OTHER;
}

static gboolean on_permission(WebKitWebView *web_view, WebKitPermissionRequest *request, wpe_wv *w) {
    uint64_t id = ++w->app->next_id;
    g_hash_table_insert(w->permissions, GSIZE_TO_POINTER(id), g_object_ref(request));
    const char *uri = webkit_web_view_get_uri(web_view);
    siv_webview_event e = {.type = SIV_WEBVIEW_EVENT_PERMISSION, .permission = permission_kind(request), .id = id, .uri = uri, .uri_len = uri ? strlen(uri) : 0};
    if (!swv_emit(w->wv, &e) && g_hash_table_contains(w->permissions, GSIZE_TO_POINTER(id))) {
        webkit_permission_request_deny(request);
        g_hash_table_remove(w->permissions, GSIZE_TO_POINTER(id));
    }
    return TRUE;
}

static gboolean on_notification(WebKitWebView *web_view, WebKitNotification *n, wpe_wv *w) {
    (void)web_view;
    const char *title = webkit_notification_get_title(n), *body = webkit_notification_get_body(n);
    siv_webview_event e = {.type = SIV_WEBVIEW_EVENT_NOTIFICATION, .name = title, .name_len = title ? strlen(title) : 0, .text = body, .text_len = body ? strlen(body) : 0};
    if (!swv_emit(w->wv, &e))
        (void)siv_notification_send(w->app->app->app, SIV_DESC(siv_notification_desc, .title = title, .title_len = title ? strlen(title) : 0, .body = body, .body_len = body ? strlen(body) : 0));
    return TRUE;
}

static gboolean on_fullscreen(WebKitWebView *web_view, wpe_wv *w) {
    (void)web_view;
    (void)siv_window_set_fullscreen(w->wv->window, true);
    return TRUE;
}

static gboolean on_unfullscreen(WebKitWebView *web_view, wpe_wv *w) {
    (void)web_view;
    (void)siv_window_set_fullscreen(w->wv->window, false);
    return TRUE;
}

/* ---------- downloads ---------- */

static wpe_wv *download_owner(WebKitDownload *d) {
    WebKitWebView *web_view = webkit_download_get_web_view(d);
    if (!web_view) return NULL;
    return g_object_get_data(G_OBJECT(web_view), "siv-webview");
}

static void download_event(wpe_wv *w, WebKitDownload *d, siv_webview_download_phase phase, const char *text) {
    uint64_t id = GPOINTER_TO_SIZE(g_object_get_data(G_OBJECT(d), "siv-webview-id"));
    WebKitURIRequest *req = webkit_download_get_request(d);
    const char *uri = req ? webkit_uri_request_get_uri(req) : NULL;
    const char *dest = webkit_download_get_destination(d);
    siv_webview_event e = {.type = SIV_WEBVIEW_EVENT_DOWNLOAD, .download_phase = phase, .id = id, .uri = uri, .uri_len = uri ? strlen(uri) : 0, .path = dest, .path_len = dest ? strlen(dest) : 0, .progress = webkit_download_get_estimated_progress(d), .text = text, .text_len = text ? strlen(text) : 0};
    if (swv_emit(w->wv, &e) && phase == SIV_WEBVIEW_DOWNLOAD_STARTED) webkit_download_cancel(d);
}

static gboolean on_decide_destination(WebKitDownload *d, const char *suggested, wpe_wv *w) {
    const char *dir = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD);
    char *fallback = dir ? NULL : g_build_filename(g_get_home_dir(), "Downloads", NULL);
    if (!dir) dir = fallback;
    g_mkdir_with_parents(dir, 0755);
    char *base = g_path_get_basename(suggested && *suggested ? suggested : "download");
    char *path = g_build_filename(dir, base, NULL);
    for (int i = 1; g_file_test(path, G_FILE_TEST_EXISTS) && i < 1000; i++) {
        g_free(path);
        char *name = g_strdup_printf("%d-%s", i, base);
        path = g_build_filename(dir, name, NULL);
        g_free(name);
    }
    webkit_download_set_destination(d, path);
    g_free(path);
    g_free(base);
    g_free(fallback);
    download_event(w, d, SIV_WEBVIEW_DOWNLOAD_STARTED, NULL);
    return TRUE;
}

static void on_download_progress(WebKitDownload *d, GParamSpec *p, wpe_wv *w) {
    (void)p;
    download_event(w, d, SIV_WEBVIEW_DOWNLOAD_PROGRESS, NULL);
}

static void on_download_finished(WebKitDownload *d, wpe_wv *w) {
    if (!g_object_get_data(G_OBJECT(d), "siv-webview-failed")) download_event(w, d, SIV_WEBVIEW_DOWNLOAD_FINISHED, NULL);
    g_hash_table_remove(w->downloads, g_object_get_data(G_OBJECT(d), "siv-webview-id"));
}

static void on_download_failed(WebKitDownload *d, GError *error, wpe_wv *w) {
    g_object_set_data(G_OBJECT(d), "siv-webview-failed", GINT_TO_POINTER(1));
    download_event(w, d, SIV_WEBVIEW_DOWNLOAD_FAILED, error ? error->message : NULL);
}

static void on_download_started(WebKitNetworkSession *session, WebKitDownload *d, gpointer data) {
    (void)session, (void)data;
    wpe_wv *w = download_owner(d);
    if (!w) return;
    uint64_t id = ++w->app->next_id;
    g_object_set_data(G_OBJECT(d), "siv-webview-id", GSIZE_TO_POINTER(id));
    g_hash_table_insert(w->downloads, GSIZE_TO_POINTER(id), g_object_ref(d));
    g_signal_connect(d, "decide-destination", G_CALLBACK(on_decide_destination), w);
    g_signal_connect(d, "notify::estimated-progress", G_CALLBACK(on_download_progress), w);
    g_signal_connect(d, "finished", G_CALLBACK(on_download_finished), w);
    g_signal_connect(d, "failed", G_CALLBACK(on_download_failed), w);
}

/* ---------- menus: <select> and the context menu as siv menus ---------- */

static void close_menu(wpe_wv *w) {
    if (w->option_menu) {
        WebKitOptionMenu *m = w->option_menu;
        w->option_menu = NULL;
        webkit_option_menu_close(m);
        g_object_unref(m);
    }
    g_clear_pointer(&w->option_items, g_array_unref);
    g_clear_object(&w->context_menu);
    if (w->menu) {
        siv_txn txn;
        if (siv_txn_begin(w->wv->window, &txn) == SIV_OK) {
            siv_remove(txn, w->menu);
            (void)siv_txn_commit(txn);
        }
        w->menu = 0;
    }
}

static siv_event_result on_menu_select(void *user_data, siv_node node, const siv_event *e) {
    (void)node;
    swv_webview *wv = swv_handle_get(&swv_webviews, (siv_webview)(uintptr_t)user_data);
    if (!wv || !wv->engine_data) return SIV_EVENT_RESULT_HANDLED;
    wpe_wv *w = of(wv);
    if (e->type == SIV_EVENT_TYPE_SELECT && w->option_menu && w->option_items && e->index < w->option_items->len) {
        guint item = g_array_index(w->option_items, guint, e->index);
        WebKitOptionMenu *m = w->option_menu;
        w->option_menu = NULL;
        webkit_option_menu_activate_item(m, item);
        webkit_option_menu_close(m);
        g_object_unref(m);
    } else if (e->type == SIV_EVENT_TYPE_SELECT && w->context_menu && e->index < webkit_context_menu_get_n_items(w->context_menu)) {
        WebKitContextMenuItem *item = webkit_context_menu_get_item_at_position(w->context_menu, e->index);
        GAction *action = item ? webkit_context_menu_item_get_gaction(item) : NULL;
        if (action) g_action_activate(action, webkit_context_menu_item_get_gaction_target(item));
    }
    close_menu(w);
    return SIV_EVENT_RESULT_HANDLED;
}

/* A siv menu of `n` items, by label, opened at (x, y) in the node. */
static void open_menu(wpe_wv *w, guint n, const char *(*label)(wpe_wv *, guint, siv_menu_item_flags *), float x, float y) {
    siv_txn txn;
    if (!w->wv->node || siv_txn_begin(w->wv->window, &txn) != SIV_OK) return;
    /* Menus take no space; the root holds them (an external node cannot). */
    siv_node menu = siv_menu(txn, siv_window_get_root(w->wv->window), SIV_DESC(siv_menu_desc, .label = SIV_STR("Menu")));
    for (guint i = 0; i < n; i++) {
        siv_menu_item_flags flags = 0;
        const char *l = label(w, i, &flags);
        siv_menu_item(txn, menu, SIV_DESC(siv_menu_item_desc, .label = l ? l : "", .label_len = l ? strlen(l) : 0, .flags = flags));
    }
    void *id = (void *)(uintptr_t)w->wv->handle;
    siv_on(txn, menu, SIV_EVENT_TYPE_SELECT, on_menu_select, NULL, id);
    siv_on(txn, menu, SIV_EVENT_TYPE_CLOSE, on_menu_select, NULL, id);
    siv_result cr = siv_txn_commit(txn);
    if (getenv("SWV_DEBUG")) fprintf(stderr, "siv-webview: menu of %u items at %g,%g: commit %s\n", n, x, y, siv_result_name(cr));
    if (cr != SIV_OK) return;
    w->menu = menu;
    siv_result orr = siv_menu_open_at(menu, w->wv->node, x, y);
    if (getenv("SWV_DEBUG")) fprintf(stderr, "siv-webview: open %s\n", siv_result_name(orr));
    if (orr != SIV_OK) close_menu(w);
}

static const char *option_label(wpe_wv *w, guint i, siv_menu_item_flags *flags) {
    WebKitOptionMenuItem *item = webkit_option_menu_get_item(w->option_menu, g_array_index(w->option_items, guint, i));
    if (!webkit_option_menu_item_is_enabled(item)) *flags |= SIV_MENU_ITEM_DISABLED;
    if (webkit_option_menu_item_is_selected(item)) *flags |= SIV_MENU_ITEM_CHECKABLE | SIV_MENU_ITEM_CHECKED;
    return webkit_option_menu_item_get_label(item);
}

static void on_option_menu_close(WebKitOptionMenu *menu, wpe_wv *w) {
    if (menu == w->option_menu) {
        g_clear_object(&w->option_menu);
        close_menu(w);
    }
}

static gboolean on_show_option_menu(WebKitWebView *web_view, WebKitOptionMenu *menu, WebKitRectangle *rect, wpe_wv *w) {
    (void)web_view;
    if (getenv("SWV_DEBUG")) fprintf(stderr, "siv-webview: option menu\n");
    close_menu(w);
    w->option_menu = g_object_ref(menu);
    w->option_items = g_array_new(FALSE, FALSE, sizeof(guint));
    guint n = webkit_option_menu_get_n_items(menu);
    for (guint i = 0; i < n; i++)
        if (!webkit_option_menu_item_is_group_label(webkit_option_menu_get_item(menu, i))) g_array_append_val(w->option_items, i);
    g_signal_connect(menu, "close", G_CALLBACK(on_option_menu_close), w);
    open_menu(w, w->option_items->len, option_label, (float)rect->x, (float)(rect->y + rect->height));
    return TRUE;
}

static const char *context_label(wpe_wv *w, guint i, siv_menu_item_flags *flags) {
    WebKitContextMenuItem *item = webkit_context_menu_get_item_at_position(w->context_menu, i);
    if (webkit_context_menu_item_is_separator(item)) {
        *flags |= SIV_MENU_ITEM_SEPARATOR;
        return "";
    }
    GAction *a = webkit_context_menu_item_get_gaction(item);
    if (a && !g_action_get_enabled(a)) *flags |= SIV_MENU_ITEM_DISABLED;
    return webkit_context_menu_item_get_title(item);
}

static gboolean on_context_menu(WebKitWebView *web_view, WebKitContextMenu *menu, WebKitHitTestResult *hit, wpe_wv *w) {
    (void)web_view, (void)hit;
    if (w->wv->flags & SIV_WEBVIEW_NO_CONTEXT_MENU) return TRUE;
    close_menu(w);
    if (!webkit_context_menu_get_n_items(menu)) return TRUE;
    w->context_menu = g_object_ref(menu);
    open_menu(w, webkit_context_menu_get_n_items(menu), context_label, (float)w->px, (float)w->py);
    return TRUE;
}

/* ---------- file inputs through siv's portal file chooser ---------- */

struct choose {
    siv_webview webview;
    WebKitFileChooserRequest *request;
    siv_file_chooser chooser;
};

static void choose_free(void *p) {
    struct choose *c = p;
    if (c->request) {
        webkit_file_chooser_request_cancel(c->request);
        g_object_unref(c->request);
    }
    if (c->chooser) siv_file_chooser_destroy(c->chooser);
    g_free(c);
}

static void on_chosen(void *user_data, const siv_portal_result *result) {
    struct choose *c = user_data;
    if (result->response != SIV_PORTAL_RESPONSE_SUCCESS) return; /* choose_free cancels */
    uint32_t n = 0;
    if (siv_file_chooser_get_uri_count(c->chooser, &n) != SIV_OK || !n) return;
    GPtrArray *files = g_ptr_array_new_with_free_func(g_free);
    for (uint32_t i = 0; i < n; i++) {
        char buf[4096];
        size_t len = 0;
        if (siv_file_chooser_get_path(c->chooser, i, buf, sizeof buf - 1, &len) == SIV_OK && len < sizeof buf) {
            buf[len] = 0;
            g_ptr_array_add(files, g_strdup(buf));
        }
    }
    g_ptr_array_add(files, NULL);
    if (files->len > 1) {
        webkit_file_chooser_request_select_files(c->request, (const char *const *)files->pdata);
        g_clear_object(&c->request);
    }
    g_ptr_array_unref(files);
}

static gboolean on_run_file_chooser(WebKitWebView *web_view, WebKitFileChooserRequest *request, wpe_wv *w) {
    (void)web_view;
    struct choose *c = g_new0(struct choose, 1);
    c->webview = w->wv->handle;
    c->request = g_object_ref(request);
    bool multiple = webkit_file_chooser_request_get_select_multiple(request);
    siv_result r = siv_file_chooser_create(w->app->app->app, SIV_DESC(siv_file_chooser_desc, .title = multiple ? "Open Files" : "Open File", .title_len = multiple ? 10 : 9, .mode = SIV_FILE_CHOOSER_MODE_OPEN, .flags = multiple ? SIV_FILE_CHOOSER_MULTIPLE : 0), &c->chooser);
    const char *const *mimes = webkit_file_chooser_request_get_mime_types(request);
    if (r == SIV_OK && mimes && mimes[0]) {
        if (siv_file_chooser_add_filter(c->chooser, SIV_STR("Accepted files")) == SIV_OK)
            for (size_t i = 0; mimes[i]; i++) (void)siv_file_chooser_add_pattern(c->chooser, SIV_FILE_PATTERN_KIND_MIME, mimes[i], strlen(mimes[i]));
        if (siv_file_chooser_add_filter(c->chooser, SIV_STR("All files")) == SIV_OK) (void)siv_file_chooser_add_pattern(c->chooser, SIV_FILE_PATTERN_KIND_GLOB, SIV_STR("*"));
    }
    if (r == SIV_OK) r = siv_file_chooser_show(c->chooser, w->wv->window, on_chosen, choose_free, c);
    else choose_free(c);
    return TRUE;
}

/* ---------- messages ---------- */

/* Every page gets window.siv: postMessage to the application, and
 * "message" events (and onmessage) from siv_webview_post_message. */
static const char siv_script[] =
    "(() => {\n"
    "  if (window.siv) return;\n"
    "  const t = new EventTarget();\n"
    "  const siv = {\n"
    "    postMessage(value) { window.webkit.messageHandlers.siv.postMessage(value); },\n"
    "    addEventListener: t.addEventListener.bind(t),\n"
    "    removeEventListener: t.removeEventListener.bind(t),\n"
    "    onmessage: null,\n"
    "    _receive(data) {\n"
    "      const e = new MessageEvent('message', { data });\n"
    "      if (typeof siv.onmessage === 'function') siv.onmessage(e);\n"
    "      t.dispatchEvent(e);\n"
    "    },\n"
    "  };\n"
    "  Object.defineProperty(window, 'siv', { value: siv, enumerable: false });\n"
    "})();\n";

static void on_script_message(WebKitUserContentManager *m, JSCValue *value, wpe_wv *w) {
    (void)m;
    char *json = jsc_value_to_json(value, 0);
    swv_emit(w->wv, &(siv_webview_event){.type = SIV_WEBVIEW_EVENT_MESSAGE, .name = "siv", .name_len = 3, .text = json ? json : "null", .text_len = json ? strlen(json) : 4});
    g_free(json);
}

struct handler_ctx {
    wpe_wv *w;
    char *name;
};

static void handler_ctx_free(gpointer p, GClosure *c) {
    (void)c;
    struct handler_ctx *h = p;
    g_free(h->name);
    g_free(h);
}

static void on_named_message(WebKitUserContentManager *m, JSCValue *value, struct handler_ctx *h) {
    (void)m;
    char *json = jsc_value_to_json(value, 0);
    swv_emit(h->w->wv, &(siv_webview_event){.type = SIV_WEBVIEW_EVENT_MESSAGE, .name = h->name, .name_len = strlen(h->name), .text = json ? json : "null", .text_len = json ? strlen(json) : 4});
    g_free(json);
}

static siv_result wpe_add_message_handler(swv_webview *wv, const char *name) {
    wpe_wv *w = of(wv);
    if (!webkit_user_content_manager_register_script_message_handler(w->content, name, NULL)) return SIV_ERROR_INVALID_ARGUMENT;
    struct handler_ctx *h = g_new0(struct handler_ctx, 1);
    h->w = w;
    h->name = g_strdup(name);
    char *signal = g_strdup_printf("script-message-received::%s", name);
    g_signal_connect_data(w->content, signal, G_CALLBACK(on_named_message), h, handler_ctx_free, 0);
    g_free(signal);
    return SIV_OK;
}

struct script {
    siv_webview_script_fn callback;
    siv_destroy_fn destroy;
    void *user_data;
};

static void on_script_done(GObject *source, GAsyncResult *res, gpointer data) {
    struct script *s = data;
    GError *err = NULL;
    JSCValue *v = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(source), res, &err);
    if (s->callback) {
        if (v) {
            char *json = jsc_value_is_undefined(v) ? NULL : jsc_value_to_json(v, 0);
            const char *out = json ? json : "null";
            s->callback(s->user_data, SIV_OK, out, strlen(out));
            g_free(json);
        } else {
            const char *msg = err ? err->message : "script failed";
            s->callback(s->user_data, SIV_ERROR_UNAVAILABLE, msg, strlen(msg));
        }
    }
    if (s->destroy) s->destroy(s->user_data);
    g_clear_error(&err);
    g_clear_object(&v);
    g_free(s);
}

static siv_result wpe_run_script(swv_webview *wv, const char *script, size_t len, siv_webview_script_fn cb, siv_destroy_fn destroy, void *user_data) {
    struct script *s = g_new0(struct script, 1);
    s->callback = cb, s->destroy = destroy, s->user_data = user_data;
    webkit_web_view_evaluate_javascript(of(wv)->web_view, script, (gssize)len, NULL, NULL, NULL, on_script_done, s);
    return SIV_OK;
}

static siv_result wpe_post_message(swv_webview *wv, const char *json, size_t len) {
    /* JSON is a JavaScript expression; the page parses nothing. */
    GString *s = g_string_new("window.siv && window.siv._receive(");
    g_string_append_len(s, json, (gssize)len);
    g_string_append(s, "); undefined");
    webkit_web_view_evaluate_javascript(of(wv)->web_view, s->str, (gssize)s->len, NULL, NULL, NULL, NULL, NULL);
    g_string_free(s, TRUE);
    return SIV_OK;
}

static siv_result wpe_permission_reply(swv_webview *wv, uint64_t id, bool allow) {
    wpe_wv *w = of(wv);
    WebKitPermissionRequest *r = g_hash_table_lookup(w->permissions, GSIZE_TO_POINTER(id));
    if (!r) return SIV_ERROR_INVALID_ARGUMENT;
    if (allow) webkit_permission_request_allow(r);
    else webkit_permission_request_deny(r);
    g_hash_table_remove(w->permissions, GSIZE_TO_POINTER(id));
    return SIV_OK;
}

static siv_result wpe_download_cancel(swv_webview *wv, uint64_t id) {
    WebKitDownload *d = g_hash_table_lookup(of(wv)->downloads, GSIZE_TO_POINTER(id));
    if (!d) return SIV_ERROR_INVALID_ARGUMENT;
    webkit_download_cancel(d);
    return SIV_OK;
}

/* ---------- web views ---------- */

static char *dir_or_default(const char *dir, size_t len, const char *base) {
    if (dir && len) return g_strndup(dir, len);
    const char *prg = g_get_prgname();
    return g_build_filename(base, prg && *prg ? prg : "siv", "webview", NULL);
}

static WebKitNetworkSession *session_for(wpe_app *wa, const siv_webview_desc *d) {
    if (d->flags & SIV_WEBVIEW_EPHEMERAL) {
        WebKitNetworkSession *s = webkit_network_session_new_ephemeral();
        g_signal_connect(s, "download-started", G_CALLBACK(on_download_started), NULL);
        return s;
    }
    char *data = dir_or_default(d->data_dir, d->data_dir_len, g_get_user_data_dir());
    WebKitNetworkSession *s = g_hash_table_lookup(wa->sessions, data);
    if (s) {
        g_free(data);
        return g_object_ref(s);
    }
    char *cache = dir_or_default(d->cache_dir, d->cache_dir_len, g_get_user_cache_dir());
    s = webkit_network_session_new(data, cache);
    g_signal_connect(s, "download-started", G_CALLBACK(on_download_started), NULL);
    g_hash_table_insert(wa->sessions, data, g_object_ref(s));
    g_free(cache);
    return s;
}

static siv_result wpe_create(swv_webview *wv, const siv_webview_desc *d) {
    wpe_app *wa = wv->app->engine_data;
    if (!wa->context) {
        /* The inspector's server starts with the first context. */
        if ((d->flags & SIV_WEBVIEW_DEVELOPER_EXTRAS) && d->inspector_port && !getenv("WEBKIT_INSPECTOR_HTTP_SERVER")) {
            char addr[32];
            snprintf(addr, sizeof addr, "127.0.0.1:%u", (unsigned)d->inspector_port);
            setenv("WEBKIT_INSPECTOR_HTTP_SERVER", addr, 0);
        }
        wa->context = webkit_web_context_new();
        for (swv_scheme *s = wv->app->schemes; s; s = s->next) register_scheme(wa, s);
    }
    wpe_wv *w = calloc(1, sizeof *w);
    if (!w) return SIV_ERROR_OUT_OF_MEMORY;
    w->wv = wv;
    w->app = wa;
    w->held = g_hash_table_new(NULL, NULL);
    w->awaiting = g_ptr_array_new();
    w->permissions = g_hash_table_new_full(NULL, NULL, NULL, g_object_unref);
    w->downloads = g_hash_table_new_full(NULL, NULL, NULL, g_object_unref);
    w->title = g_strdup("");
    w->uri = g_strdup("");
    w->content = webkit_user_content_manager_new();
    WebKitUserScript *script = webkit_user_script_new(siv_script, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
    webkit_user_content_manager_add_script(w->content, script);
    webkit_user_script_unref(script);
    webkit_user_content_manager_register_script_message_handler(w->content, "siv", NULL);
    g_signal_connect(w->content, "script-message-received::siv", G_CALLBACK(on_script_message), w);
    WebKitSettings *settings = webkit_settings_new();
    webkit_settings_set_enable_developer_extras(settings, (d->flags & SIV_WEBVIEW_DEVELOPER_EXTRAS) != 0);
    if (d->user_agent_len) {
        char *ua = g_strndup(d->user_agent, d->user_agent_len);
        webkit_settings_set_user_agent(settings, ua);
        g_free(ua);
    }
    WebKitNetworkSession *session = session_for(wa, d);
    w->web_view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", wa->display, "web-context", wa->context, "network-session", session, "user-content-manager", w->content, "settings", settings, NULL);
    g_object_unref(session);
    g_object_unref(settings);
    g_object_set_data(G_OBJECT(w->web_view), "siv-webview", w);
    w->view = webkit_web_view_get_wpe_view(w->web_view);
    SWV_VIEW(w->view)->w = w;
    w->toplevel = wpe_display_create_toplevel(wa->display, 1);
    wpe_view_set_toplevel(w->view, w->toplevel);
    wv->engine_data = w;
    if (d->zoom > 0) webkit_web_view_set_zoom_level(w->web_view, d->zoom);
    WebKitColor bg = {d->background.r, d->background.g, d->background.b, d->background.a > 0 ? d->background.a : 1};
    if (d->background.a > 0) webkit_web_view_set_background_color(w->web_view, &bg);

    GObject *o = G_OBJECT(w->web_view);
    g_signal_connect(o, "load-changed", G_CALLBACK(on_load_changed), w);
    g_signal_connect(o, "load-failed", G_CALLBACK(on_load_failed), w);
    g_signal_connect(o, "notify::title", G_CALLBACK(on_title), w);
    g_signal_connect(o, "notify::uri", G_CALLBACK(on_uri), w);
    g_signal_connect(o, "notify::estimated-load-progress", G_CALLBACK(on_progress), w);
    g_signal_connect(o, "close", G_CALLBACK(on_close), w);
    g_signal_connect(o, "web-process-terminated", G_CALLBACK(on_terminated), w);
    g_signal_connect(o, "decide-policy", G_CALLBACK(on_decide_policy), w);
    g_signal_connect(o, "create", G_CALLBACK(on_create), w);
    g_signal_connect(o, "permission-request", G_CALLBACK(on_permission), w);
    g_signal_connect(o, "show-notification", G_CALLBACK(on_notification), w);
    g_signal_connect(o, "enter-fullscreen", G_CALLBACK(on_fullscreen), w);
    g_signal_connect(o, "leave-fullscreen", G_CALLBACK(on_unfullscreen), w);
    g_signal_connect(o, "show-option-menu", G_CALLBACK(on_show_option_menu), w);
    g_signal_connect(o, "context-menu", G_CALLBACK(on_context_menu), w);
    g_signal_connect(o, "run-file-chooser", G_CALLBACK(on_run_file_chooser), w);
    g_signal_connect(webkit_web_view_get_back_forward_list(w->web_view), "changed", G_CALLBACK(on_history), w);
    return SIV_OK;
}

static void wpe_destroy(swv_webview *wv) {
    wpe_wv *w = of(wv);
    if (!w) return;
    close_menu(w);
    g_signal_handlers_disconnect_by_data(w->web_view, w);
    g_signal_handlers_disconnect_by_data(webkit_web_view_get_back_forward_list(w->web_view), w);
    g_signal_handlers_disconnect_by_data(w->content, w);
    GHashTableIter it;
    gpointer k, v;
    g_hash_table_iter_init(&it, w->downloads);
    while (g_hash_table_iter_next(&it, &k, &v)) g_signal_handlers_disconnect_by_data(v, w);
    /* siv keeps its own descriptors of frames it still shows; WebKit's
     * buffers go now. */
    g_hash_table_iter_init(&it, w->held);
    while (g_hash_table_iter_next(&it, &k, &v))
        for (guint n = GPOINTER_TO_UINT(v); n > 0; n--) g_object_unref(k);
    g_hash_table_unref(w->held);
    g_ptr_array_unref(w->awaiting);
    g_hash_table_iter_init(&it, w->permissions);
    while (g_hash_table_iter_next(&it, &k, &v)) webkit_permission_request_deny(v);
    g_hash_table_unref(w->permissions);
    g_hash_table_unref(w->downloads);
    SWV_VIEW(w->view)->w = NULL;
    if (w->app->focus == wv->handle) w->app->focus = 0;
    g_object_unref(w->web_view);
    g_clear_object(&w->toplevel);
    g_object_unref(w->content);
    g_free(w->title);
    g_free(w->uri);
    free(w);
    wv->engine_data = NULL;
}

static void wpe_set_dark(swv_webview *wv, bool dark) {
    wv->dark = dark;
    wpe_settings_set_boolean(wpe_display_get_settings(of(wv)->app->display), WPE_SETTING_DARK_MODE, dark, WPE_SETTINGS_SOURCE_APPLICATION, NULL);
}

static void wpe_configure(swv_webview *wv, uint32_t width, uint32_t height, double scale) {
    wpe_wv *w = of(wv);
    if (scale > 0 && scale != w->scale) {
        w->scale = scale;
        wpe_screen_set_scale(wpe_display_get_screen(w->app->display, 0), scale);
        wpe_toplevel_scale_changed(w->toplevel, scale);
    }
    if ((int)width != w->width || (int)height != w->height) {
        w->width = (int)width, w->height = (int)height;
        wpe_toplevel_resized(w->toplevel, w->width, w->height);
        wpe_view_resized(w->view, w->width, w->height);
    }
    if (!w->mapped) {
        w->mapped = true;
        wpe_toplevel_state_changed(w->toplevel, WPE_TOPLEVEL_STATE_ACTIVE);
        wpe_view_map(w->view);
    }
    /* The theme may have changed since: follow it. */
    if (wv->scheme == SIV_COLOR_SCHEME_FOLLOW && !(wv->flags & SIV_WEBVIEW_NO_THEME)) {
        bool dark = swv_theme_dark(wv);
        if (dark != wv->dark) wpe_set_dark(wv, dark);
    }
}

static void wpe_presented(swv_webview *wv, uint64_t key) {
    wpe_wv *w = of(wv);
    WPEBuffer *b = (WPEBuffer *)(uintptr_t)key;
    if (g_ptr_array_remove(w->awaiting, b)) wpe_view_buffer_rendered(w->view, b);
}

static void wpe_released(swv_webview *wv, uint64_t key) {
    wpe_wv *w = of(wv);
    WPEBuffer *b = (WPEBuffer *)(uintptr_t)key;
    guint n = GPOINTER_TO_UINT(g_hash_table_lookup(w->held, b));
    if (!n) return;
    if (n == 1) g_hash_table_remove(w->held, b);
    else g_hash_table_insert(w->held, b, GUINT_TO_POINTER(n - 1));
    /* Replaced before it showed: WebKit still waits for it to render. */
    if (g_ptr_array_remove(w->awaiting, b)) wpe_view_buffer_rendered(w->view, b);
    wpe_view_buffer_released(w->view, b);
    g_object_unref(b);
}

/* ---------- input ---------- */

static WPEModifiers mods(wpe_wv *w, siv_modifiers m) {
    unsigned r = w->buttons;
    if (m & SIV_MODIFIERS_SHIFT) r |= WPE_MODIFIER_KEYBOARD_SHIFT;
    if (m & SIV_MODIFIERS_CTRL) r |= WPE_MODIFIER_KEYBOARD_CONTROL;
    if (m & SIV_MODIFIERS_ALT) r |= WPE_MODIFIER_KEYBOARD_ALT;
    if (m & SIV_MODIFIERS_SUPER) r |= WPE_MODIFIER_KEYBOARD_META;
    if (m & SIV_MODIFIERS_CAPS_LOCK) r |= WPE_MODIFIER_KEYBOARD_CAPS_LOCK;
    return (WPEModifiers)r;
}

static void send(wpe_wv *w, WPEEvent *e) {
    wpe_view_event(w->view, e);
    wpe_event_unref(e);
}

static void send_key(wpe_wv *w, const siv_event *e) {
    bool pressed = e->flags & SIV_EVENT_PRESSED;
    send(w, wpe_event_keyboard_new(pressed ? WPE_EVENT_KEYBOARD_KEY_DOWN : WPE_EVENT_KEYBOARD_KEY_UP, w->view, WPE_INPUT_SOURCE_KEYBOARD, e->time, mods(w, e->modifiers), e->keycode, (guint)e->keysym));
}

static bool is_paste(const siv_event *e) {
    if (!(e->flags & SIV_EVENT_PRESSED)) return false;
    bool ctrl = e->modifiers & SIV_MODIFIERS_CTRL, shift = e->modifiers & SIV_MODIFIERS_SHIFT;
    unsigned k = (unsigned)e->keysym;
    return (ctrl && (k == 'v' || k == 'V')) || (shift && k == SIV_KEY_INSERT) || k == SIV_KEY_PASTE;
}

/* Reading the clipboard ahead of a paste: WPE reads it synchronously, siv
 * asynchronously. Text first, then HTML or an image; the held key goes to
 * the page once both are in. */
struct paste {
    siv_webview webview;
    int step;
};

static void paste_done(wpe_wv *w) {
    GPtrArray *formats = g_ptr_array_new();
    GHashTableIter it;
    gpointer k, v;
    g_hash_table_iter_init(&it, w->app->clip);
    while (g_hash_table_iter_next(&it, &k, &v)) g_ptr_array_add(formats, (gpointer)g_intern_string(k));
    WPEClipboard *clip = wpe_display_get_clipboard(w->app->display);
    WPE_CLIPBOARD_CLASS(swv_clipboard_parent_class)->changed(clip, formats, FALSE, NULL);
    g_ptr_array_unref(formats);
    if (w->paste_pending) {
        w->paste_pending = false;
        siv_event e = w->held_key;
        send_key(w, &e);
    }
}

static void read_clip(siv_webview webview, int step);

static void clip_read(void *user_data, const siv_clipboard_data *data) {
    struct paste *p = user_data;
    swv_webview *wv = swv_handle_get(&swv_webviews, p->webview);
    if (!wv || !wv->engine_data) return;
    wpe_wv *w = of(wv);
    if (data->result == SIV_OK && data->mime_len) {
        char *mime = g_strndup(data->mime, data->mime_len);
        g_hash_table_insert(w->app->clip, mime, g_bytes_new(data->data, data->data_count));
        if (g_str_has_prefix(mime, "text/plain")) {
            g_hash_table_insert(w->app->clip, g_strdup("text/plain"), g_bytes_new(data->data, data->data_count));
            g_hash_table_insert(w->app->clip, g_strdup("text/plain;charset=utf-8"), g_bytes_new(data->data, data->data_count));
        }
    }
    if (p->step == 0) read_clip(p->webview, 1);
    else paste_done(w);
}

static void read_clip(siv_webview webview, int step) {
    swv_webview *wv = swv_handle_get(&swv_webviews, webview);
    if (!wv) return;
    struct paste *p = g_new0(struct paste, 1);
    p->webview = webview, p->step = step;
    static const char text[] = "text/plain;charset=utf-8\ntext/plain\nUTF8_STRING";
    static const char rich[] = "text/html\nimage/png";
    const char *mimes = step == 0 ? text : rich;
    if (siv_clipboard_read_data(wv->window, SIV_SELECTION_CLIPBOARD, mimes, strlen(mimes), clip_read, g_free, p) != SIV_OK && step == 0) {
        if (wv->engine_data) paste_done(of(wv));
    }
}

static void prefetch_clipboard(wpe_wv *w) {
    g_hash_table_remove_all(w->app->clip);
    read_clip(w->wv->handle, 0);
}

static guint button_of(const siv_event *e) {
    switch (e->button) {
    case SIV_POINTER_BUTTON_PRIMARY: return WPE_BUTTON_PRIMARY;
    case SIV_POINTER_BUTTON_SECONDARY: return WPE_BUTTON_SECONDARY;
    case SIV_POINTER_BUTTON_MIDDLE: return WPE_BUTTON_MIDDLE;
    default: return e->button_code >= 0x110 ? e->button_code - 0x110 + 1 : 0;
    }
}

static siv_event_result wpe_input(swv_webview *wv, const siv_event *e) {
    wpe_wv *w = of(wv);
    switch (e->type) {
    case SIV_EVENT_TYPE_POINTER: {
        w->px = e->x, w->py = e->y;
        switch (e->phase) {
        case SIV_POINTER_PHASE_MOVE:
        case SIV_POINTER_PHASE_ENTER:
        case SIV_POINTER_PHASE_LEAVE: {
            WPEEventType t = e->phase == SIV_POINTER_PHASE_MOVE ? WPE_EVENT_POINTER_MOVE : e->phase == SIV_POINTER_PHASE_ENTER ? WPE_EVENT_POINTER_ENTER : WPE_EVENT_POINTER_LEAVE;
            send(w, wpe_event_pointer_move_new(t, w->view, WPE_INPUT_SOURCE_MOUSE, e->time, mods(w, e->modifiers), e->x, e->y, 0, 0));
            return SIV_EVENT_RESULT_HANDLED;
        }
        case SIV_POINTER_PHASE_DOWN:
        case SIV_POINTER_PHASE_UP:
        case SIV_POINTER_PHASE_CANCEL: {
            guint button = button_of(e);
            unsigned bit = button >= 1 && button <= 5 ? WPE_MODIFIER_POINTER_BUTTON1 << (button - 1) : 0;
            bool down = e->phase == SIV_POINTER_PHASE_DOWN;
            if (down) w->buttons |= bit;
            else w->buttons &= ~bit;
            /* Its context menu may offer Paste. */
            if (down && button == WPE_BUTTON_SECONDARY) prefetch_clipboard(w);
            guint count = down ? wpe_view_compute_press_count(w->view, e->x, e->y, button, e->time) : 0;
            send(w, wpe_event_pointer_button_new(down ? WPE_EVENT_POINTER_DOWN : WPE_EVENT_POINTER_UP, w->view, WPE_INPUT_SOURCE_MOUSE, e->time, mods(w, e->modifiers), button, e->x, e->y, count));
            /* A press still focuses the node (siv's default action). */
            return down ? SIV_EVENT_RESULT_STOP : SIV_EVENT_RESULT_HANDLED;
        }
        default:
            return SIV_EVENT_RESULT_PASS;
        }
    }
    case SIV_EVENT_TYPE_SCROLL: {
        WPEModifiers m = mods(w, e->modifiers);
        if (e->steps_x != 0 || e->steps_y != 0) {
            /* Wheel detents: the engine's own line steps. */
            send(w, wpe_event_scroll_new(w->view, WPE_INPUT_SOURCE_MOUSE, e->time, m, -e->steps_x, -e->steps_y, FALSE, FALSE, w->px, w->py));
        } else if (e->scroll_source == SIV_SCROLL_SOURCE_FINGER || e->scroll_source == SIV_SCROLL_SOURCE_CONTINUOUS) {
            /* Touchpad pixels as sent, and the stop that starts the
             * engine's own kinetic scrolling. */
            bool stop = (e->flags & SIV_EVENT_STOP) && e->raw_dx == 0 && e->raw_dy == 0;
            send(w, wpe_event_scroll_new(w->view, WPE_INPUT_SOURCE_TOUCHPAD, e->time, m, -e->raw_dx, -e->raw_dy, TRUE, stop, w->px, w->py));
        } else if (e->dx != 0 || e->dy != 0) {
            send(w, wpe_event_scroll_new(w->view, WPE_INPUT_SOURCE_MOUSE, e->time, m, -e->dx, -e->dy, TRUE, FALSE, w->px, w->py));
        }
        return SIV_EVENT_RESULT_HANDLED;
    }
    case SIV_EVENT_TYPE_KEY:
        if (is_paste(e)) {
            w->held_key = *e;
            size_t n = MIN(e->text_len, sizeof w->held_text - 1);
            if (n) memcpy(w->held_text, e->text, n);
            w->held_text[n] = 0;
            w->held_key.text = w->held_text;
            w->held_key.text_len = n;
            w->paste_pending = true;
            prefetch_clipboard(w);
            return SIV_EVENT_RESULT_HANDLED;
        }
        send_key(w, e);
        return SIV_EVENT_RESULT_HANDLED;
    case SIV_EVENT_TYPE_FOCUS:
        if (e->flags & SIV_EVENT_GAINED) {
            w->app->focus = wv->handle;
            wpe_view_focus_in(w->view);
        } else {
            wpe_view_focus_out(w->view);
        }
        return SIV_EVENT_RESULT_HANDLED;
    case SIV_EVENT_TYPE_TOUCH: {
        WPEEventType t = e->phase == SIV_POINTER_PHASE_DOWN ? WPE_EVENT_TOUCH_DOWN : e->phase == SIV_POINTER_PHASE_MOVE ? WPE_EVENT_TOUCH_MOVE : e->phase == SIV_POINTER_PHASE_UP ? WPE_EVENT_TOUCH_UP : WPE_EVENT_TOUCH_CANCEL;
        send(w, wpe_event_touch_new(t, w->view, WPE_INPUT_SOURCE_TOUCHSCREEN, e->time, mods(w, e->modifiers), (guint32)e->touch_id, e->x, e->y));
        return SIV_EVENT_RESULT_HANDLED;
    }
    case SIV_EVENT_TYPE_TEXT_INPUT: {
        WPEInputMethodContext *im = SWV_VIEW(w->view)->im;
        if (im) im_apply(SWV_IM(im), e);
        return SIV_EVENT_RESULT_HANDLED;
    }
    default:
        return SIV_EVENT_RESULT_PASS;
    }
}

/* ---------- navigation and state ---------- */

static void wpe_load_uri(swv_webview *wv, const char *uri) { webkit_web_view_load_uri(of(wv)->web_view, uri); }

static void wpe_load_html(swv_webview *wv, const char *html, size_t len, const char *base_uri) {
    GBytes *b = g_bytes_new(html, len);
    webkit_web_view_load_bytes(of(wv)->web_view, b, "text/html", "UTF-8", base_uri);
    g_bytes_unref(b);
}

static void wpe_go_back(swv_webview *wv) { webkit_web_view_go_back(of(wv)->web_view); }
static void wpe_go_forward(swv_webview *wv) { webkit_web_view_go_forward(of(wv)->web_view); }
static void wpe_reload(swv_webview *wv) { webkit_web_view_reload(of(wv)->web_view); }
static void wpe_stop(swv_webview *wv) { webkit_web_view_stop_loading(of(wv)->web_view); }

static const char *wpe_get_uri(swv_webview *wv) {
    wpe_wv *w = of(wv);
    set_str(&w->uri, webkit_web_view_get_uri(w->web_view));
    return w->uri;
}

static const char *wpe_get_title(swv_webview *wv) {
    wpe_wv *w = of(wv);
    set_str(&w->title, webkit_web_view_get_title(w->web_view));
    return w->title;
}

static void wpe_get_state(swv_webview *wv, siv_webview_state *s) {
    wpe_wv *w = of(wv);
    s->flags = history_flags(w);
    s->progress = webkit_web_view_get_estimated_load_progress(w->web_view);
    s->zoom = webkit_web_view_get_zoom_level(w->web_view);
}

static void wpe_set_zoom(swv_webview *wv, double zoom) { webkit_web_view_set_zoom_level(of(wv)->web_view, zoom); }

const swv_engine swv_engine_wpe = {
    .name = "wpe",
    .id = SIV_WEBVIEW_ENGINE_WPE,
    .available = wpe_available,
    .app_init = wpe_app_init,
    .app_fini = wpe_app_fini,
    .scheme_added = wpe_scheme_added,
    .create = wpe_create,
    .destroy = wpe_destroy,
    .configure = wpe_configure,
    .presented = wpe_presented,
    .released = wpe_released,
    .input = wpe_input,
    .load_uri = wpe_load_uri,
    .load_html = wpe_load_html,
    .go_back = wpe_go_back,
    .go_forward = wpe_go_forward,
    .reload = wpe_reload,
    .stop = wpe_stop,
    .get_uri = wpe_get_uri,
    .get_title = wpe_get_title,
    .get_state = wpe_get_state,
    .set_zoom = wpe_set_zoom,
    .set_dark = wpe_set_dark,
    .run_script = wpe_run_script,
    .add_message_handler = wpe_add_message_handler,
    .post_message = wpe_post_message,
    .permission_reply = wpe_permission_reply,
    .download_cancel = wpe_download_cancel,
    .request_finish = wpe_request_finish,
    .request_fail = wpe_request_fail,
};
