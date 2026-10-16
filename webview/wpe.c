/* The WPE WebKit engine, through WPEPlatform (WebKit 2.50+): a WPEDisplay,
 * WPEView, WPEToplevel, and WPEScreen backed by siv, plus the input
 * method, clipboard, and accessibility objects WebKit asks the display
 * for. WebKit hands each finished frame to render_buffer as a dma-buf
 * (or shared memory when it renders on the CPU); it goes to the web
 * view's frame slot with its rendering fence, and WebKit hears
 * buffer_rendered when siv reports it presented and buffer_released when
 * siv lets go of it. The view is mapped while siv shows the web view's
 * node and its window can be seen, which WebKit takes as the page being
 * visible: unmapped, the page is hidden (document.visibilityState), its
 * requestAnimationFrame callbacks stop, and so does WebKit's display
 * link. */
#define _GNU_SOURCE
#include "swv.h"

#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

struct wpe_app;

/* One web view's engine state. */
typedef struct wpe_wv {
    swv_webview *wv;
    struct wpe_app *app;
    WebKitWebView *web_view;
    WPEView *view;
    WPEToplevel *toplevel;
    WebKitUserContentManager *content;
    /* Buffers siv holds (one reference each), and those submitted and not
     * yet reported presented. */
    GHashTable *held;
    GPtrArray *awaiting;
    /* siv shows the node (the view is mapped). */
    bool shown;
    double scale;
    int width, height;
    unsigned buttons;
    double px, py;
    char *title, *uri;
    /* Permission requests and downloads by id. */
    GHashTable *permissions;
    GHashTable *downloads;
    /* The application's user scripts by id (WebKitUserScript). */
    GHashTable *user_scripts;
    /* The open option or context menu and its siv node. */
    siv_node menu;
    WebKitOptionMenu *option_menu;
    GArray *option_items;
    WebKitContextMenu *context_menu;
    /* A paste shortcut waits for the clipboard's contents. */
    bool paste_pending;
    siv_event held_key;
    char held_text[32];
} wpe_wv;

typedef struct wpe_app {
    swv_app *app;
    WPEDisplay *display;
    WebKitWebContext *context;
    GHashTable *sessions; /* data dir -> WebKitNetworkSession */
    /* The web view that last had focus: clipboard writes go to its window. */
    siv_webview focus;
    GHashTable *clip; /* format -> GBytes, the clipboard as last read */
    uint64_t next_id;
} wpe_app;

static wpe_wv *of(swv_webview *wv) { return wv->engine_data; }

/* ---------- DRM device ---------- */

static bool software(void) {
    const char *s = getenv("LIBGL_ALWAYS_SOFTWARE");
    return s && *s && strcmp(s, "0");
}

/* The first render node, and its primary node from sysfs. */
static bool find_drm(char *render, size_t rlen, char *primary, size_t plen) {
    const char *env = getenv("SIV_WEBVIEW_DRM_DEVICE");
    DIR *d = NULL;
    if (env && *env) {
        snprintf(render, rlen, "%s", env);
    } else {
        d = opendir("/dev/dri");
        if (!d) return false;
        struct dirent *e;
        char best[64] = "";
        while ((e = readdir(d)))
            if (!strncmp(e->d_name, "renderD", 7) && (!best[0] || strcmp(e->d_name, best) < 0)) snprintf(best, sizeof best, "%s", e->d_name);
        closedir(d);
        if (!best[0]) return false;
        snprintf(render, rlen, "/dev/dri/%s", best);
    }
    primary[0] = 0;
    const char *base = strrchr(render, '/');
    char sys[128];
    snprintf(sys, sizeof sys, "/sys/class/drm/%s/device/drm", base ? base + 1 : render);
    d = opendir(sys);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)))
            if (!strncmp(e->d_name, "card", 4)) {
                snprintf(primary, plen, "/dev/dri/%s", e->d_name);
                break;
            }
        closedir(d);
    }
    return true;
}

/* ---------- WPEScreen, WPEToplevel ---------- */

/* WebKit's display link (requestAnimationFrame, animations, scrolling)
 * ticks on the screen's sync observer, or else on a 60 Hz timer that runs
 * whether or not anything is drawn. siv's frames drive it instead: while
 * WebKit observes, each shown web view asks siv for a frame
 * (siv_external_request_frame), and each frame siv draws for one ticks
 * the display link once. The compositor sends frame callbacks only while
 * it draws the window, so a covered window, a lock screen, or an output
 * turned off stops the ticks, and the display's own refresh rate paces
 * them. */
G_DECLARE_FINAL_TYPE(SwvSync, swv_sync, SWV, SYNC, WPEScreenSyncObserver)
struct _SwvSync {
    WPEScreenSyncObserver parent;
    /* WebKit observes (atomic: it may stop from the tick thread). */
    gint active;
    /* The tick thread waits for `due`, as WebKit's own vblank monitors
     * tick from a thread of their own: the display link expects it, and
     * sends its messages from there. */
    GMutex lock;
    GCond cond;
    bool due;
    GThread *thread;
    gint64 last_tick_us;
};
G_DEFINE_FINAL_TYPE(SwvSync, swv_sync, WPE_TYPE_SCREEN_SYNC_OBSERVER)

static void request_frames(void);

static gpointer sync_thread(gpointer data) {
    SwvSync *s = data;
    for (;;) {
        g_mutex_lock(&s->lock);
        while (!s->due) g_cond_wait(&s->cond, &s->lock);
        s->due = false;
        g_mutex_unlock(&s->lock);
        if (g_atomic_int_get(&s->active)) WPE_SCREEN_SYNC_OBSERVER_CLASS(swv_sync_parent_class)->sync(WPE_SCREEN_SYNC_OBSERVER(s));
    }
    return NULL;
}

/* WebKit starts observing on the application's thread (DisplayLink's
 * addObserver), so the web views can ask siv for frames from here. */
static void swv_sync_start(WPEScreenSyncObserver *observer) {
    SwvSync *s = SWV_SYNC(observer);
    if (!s->thread) s->thread = g_thread_new("siv-webview-sync", sync_thread, s);
    g_atomic_int_set(&s->active, 1);
    request_frames();
}

static void swv_sync_stop(WPEScreenSyncObserver *observer) { g_atomic_int_set(&SWV_SYNC(observer)->active, 0); }

static void swv_sync_class_init(SwvSyncClass *klass) {
    WPE_SCREEN_SYNC_OBSERVER_CLASS(klass)->start = swv_sync_start;
    WPE_SCREEN_SYNC_OBSERVER_CLASS(klass)->stop = swv_sync_stop;
}

static void swv_sync_init(SwvSync *self) {
    g_mutex_init(&self->lock);
    g_cond_init(&self->cond);
}

static bool sync_active(SwvSync *s) { return s && g_atomic_int_get(&s->active); }

/* A frame siv draws for a web view: one tick of the display link however
 * many windows draw at that refresh. */
static void sync_tick(SwvSync *s) {
    gint64 now = g_get_monotonic_time();
    if (now - s->last_tick_us < 2000) return;
    s->last_tick_us = now;
    g_mutex_lock(&s->lock);
    s->due = true;
    g_cond_signal(&s->cond);
    g_mutex_unlock(&s->lock);
}

G_DECLARE_FINAL_TYPE(SwvScreen, swv_screen, SWV, SCREEN, WPEScreen)
struct _SwvScreen { WPEScreen parent; };
G_DEFINE_FINAL_TYPE(SwvScreen, swv_screen, WPE_TYPE_SCREEN)

/* One for the process: WebKit keeps the display link of a screen id for
 * as long as it runs, across siv applications and their displays. */
static SwvSync *the_sync;

/* WebKit adopts the reference it gets (2.50 to 2.54), though the call is
 * documented as transfer none: one for each caller. */
static WPEScreenSyncObserver *swv_screen_get_sync_observer(WPEScreen *screen) {
    (void)screen;
    if (!the_sync) the_sync = g_object_new(swv_sync_get_type(), NULL);
    return g_object_ref(WPE_SCREEN_SYNC_OBSERVER(the_sync));
}

static void swv_screen_class_init(SwvScreenClass *klass) { WPE_SCREEN_CLASS(klass)->get_sync_observer = swv_screen_get_sync_observer; }
static void swv_screen_init(SwvScreen *self) { (void)self; }

G_DECLARE_FINAL_TYPE(SwvToplevel, swv_toplevel, SWV, TOPLEVEL, WPEToplevel)
struct _SwvToplevel { WPEToplevel parent; };
G_DEFINE_FINAL_TYPE(SwvToplevel, swv_toplevel, WPE_TYPE_TOPLEVEL)
static WPEScreen *swv_toplevel_get_screen(WPEToplevel *t) { return wpe_display_get_screen(wpe_toplevel_get_display(t), 0); }
static void swv_toplevel_class_init(SwvToplevelClass *klass) { WPE_TOPLEVEL_CLASS(klass)->get_screen = swv_toplevel_get_screen; }
static void swv_toplevel_init(SwvToplevel *self) { (void)self; }

/* ---------- accessibility: the page's AT-SPI tree under the node ---------- */

G_DECLARE_FINAL_TYPE(SwvAccessible, swv_accessible, SWV, ACCESSIBLE, GObject)
struct _SwvAccessible {
    GObject parent;
    siv_webview webview;
};
static void swv_accessible_bind(WPEViewAccessible *accessible, const char *plug_id) {
    swv_webview *wv = swv_handle_get(&swv_webviews, SWV_ACCESSIBLE(accessible)->webview);
    if (wv) swv_set_accessible_embed(wv, plug_id);
}
static void swv_accessible_iface_init(WPEViewAccessibleInterface *iface) { iface->bind = swv_accessible_bind; }
G_DEFINE_FINAL_TYPE_WITH_CODE(SwvAccessible, swv_accessible, G_TYPE_OBJECT, G_IMPLEMENT_INTERFACE(WPE_TYPE_VIEW_ACCESSIBLE, swv_accessible_iface_init))
static void swv_accessible_class_init(SwvAccessibleClass *klass) { (void)klass; }
static void swv_accessible_init(SwvAccessible *self) { (void)self; }

/* ---------- WPEView ---------- */

G_DECLARE_FINAL_TYPE(SwvView, swv_view, SWV, VIEW, WPEView)
struct _SwvView {
    WPEView parent;
    wpe_wv *w;
    SwvAccessible *accessible;
    /* The input method context WebKit made for it (it asks the display
     * while the web view is being constructed). */
    WPEInputMethodContext *im;
};
G_DEFINE_FINAL_TYPE(SwvView, swv_view, WPE_TYPE_VIEW)

struct shm_copy {
    int fd;
    size_t size;
    void *map;
};

static void shm_copy_free(gpointer p) {
    struct shm_copy *c = p;
    if (c->map && c->map != MAP_FAILED) munmap(c->map, c->size);
    if (c->fd >= 0) close(c->fd);
    g_free(c);
}

static gboolean swv_view_render_buffer(WPEView *view, WPEBuffer *buffer, const WPERectangle *damage, guint n_damage, GError **error) {
    (void)damage, (void)n_damage;
    wpe_wv *w = SWV_VIEW(view)->w;
    if (!w) {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "web view gone");
        return FALSE;
    }
    siv_external_frame_desc f = {.size = sizeof f, .key = (uint64_t)(uintptr_t)buffer, .width = (uint32_t)wpe_buffer_get_width(buffer), .height = (uint32_t)wpe_buffer_get_height(buffer)};
    siv_external_plane planes[3];
    int fence = -1;
    if (WPE_IS_BUFFER_DMA_BUF(buffer)) {
        WPEBufferDMABuf *d = WPE_BUFFER_DMA_BUF(buffer);
        guint n = wpe_buffer_dma_buf_get_n_planes(d);
        f.memory = SIV_EXTERNAL_MEMORY_DMABUF;
        f.fd = wpe_buffer_dma_buf_get_fd(d, 0);
        f.offset = wpe_buffer_dma_buf_get_offset(d, 0);
        f.stride = wpe_buffer_dma_buf_get_stride(d, 0);
        f.modifier = wpe_buffer_dma_buf_get_modifier(d);
        f.drm_format = wpe_buffer_dma_buf_get_format(d);
        for (guint i = 1; i < n && i < 4; i++)
            planes[i - 1] = (siv_external_plane){.fd = wpe_buffer_dma_buf_get_fd(d, i), .offset = wpe_buffer_dma_buf_get_offset(d, i), .stride = wpe_buffer_dma_buf_get_stride(d, i)};
        f.planes = planes;
        f.planes_count = n > 1 ? n - 1 : 0;
        fence = wpe_buffer_take_rendering_fence(buffer);
        if (fence >= 0) f.flags = SIV_EXTERNAL_FRAME_FENCE, f.fence = fence;
    } else if (WPE_IS_BUFFER_SHM(buffer)) {
        /* siv maps a descriptor; WPE's shared-memory buffer is bytes: a
         * copy into a memfd kept with the buffer. */
        WPEBufferSHM *s = WPE_BUFFER_SHM(buffer);
        gsize len;
        const void *src = g_bytes_get_data(wpe_buffer_shm_get_data(s), &len);
        struct shm_copy *c = wpe_buffer_get_user_data(buffer);
        if (!c) {
            c = g_new0(struct shm_copy, 1);
            c->size = len;
            c->fd = memfd_create("siv-webview", MFD_CLOEXEC);
            if (c->fd < 0 || ftruncate(c->fd, (off_t)len) != 0 || (c->map = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, c->fd, 0)) == MAP_FAILED) {
                shm_copy_free(c);
                g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "memfd");
                return FALSE;
            }
            wpe_buffer_set_user_data(buffer, c, shm_copy_free);
        }
        memcpy(c->map, src, MIN(len, c->size));
        f.fd = c->fd;
        f.stride = wpe_buffer_shm_get_stride(s);
    } else {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "unknown buffer type");
        return FALSE;
    }
    siv_result r = swv_submit(w->wv, &f);
    if (fence >= 0) close(fence);
    if (r != SIV_OK) {
        g_set_error(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "siv_external_submit: %s", siv_result_name(r));
        return FALSE;
    }
    /* One reference per submission, given back at its release. */
    g_hash_table_insert(w->held, buffer, GUINT_TO_POINTER(GPOINTER_TO_UINT(g_hash_table_lookup(w->held, buffer)) + 1));
    g_object_ref(buffer);
    g_ptr_array_add(w->awaiting, buffer);
    return TRUE;
}

static const struct {
    const char *name;
    siv_cursor cursor;
} cursors[] = {
    {"default", SIV_CURSOR_DEFAULT}, {"context-menu", SIV_CURSOR_CONTEXT_MENU}, {"help", SIV_CURSOR_HELP}, {"pointer", SIV_CURSOR_POINTER},
    {"progress", SIV_CURSOR_PROGRESS}, {"wait", SIV_CURSOR_WAIT}, {"cell", SIV_CURSOR_CELL}, {"crosshair", SIV_CURSOR_CROSSHAIR},
    {"text", SIV_CURSOR_TEXT}, {"vertical-text", SIV_CURSOR_VERTICAL_TEXT}, {"alias", SIV_CURSOR_ALIAS}, {"copy", SIV_CURSOR_COPY},
    {"move", SIV_CURSOR_MOVE}, {"no-drop", SIV_CURSOR_NO_DROP}, {"not-allowed", SIV_CURSOR_NOT_ALLOWED}, {"grab", SIV_CURSOR_GRAB},
    {"grabbing", SIV_CURSOR_GRABBING}, {"e-resize", SIV_CURSOR_E_RESIZE}, {"n-resize", SIV_CURSOR_N_RESIZE}, {"ne-resize", SIV_CURSOR_NE_RESIZE},
    {"nw-resize", SIV_CURSOR_NW_RESIZE}, {"s-resize", SIV_CURSOR_S_RESIZE}, {"se-resize", SIV_CURSOR_SE_RESIZE}, {"sw-resize", SIV_CURSOR_SW_RESIZE},
    {"w-resize", SIV_CURSOR_W_RESIZE}, {"ew-resize", SIV_CURSOR_EW_RESIZE}, {"ns-resize", SIV_CURSOR_NS_RESIZE}, {"nesw-resize", SIV_CURSOR_NESW_RESIZE},
    {"nwse-resize", SIV_CURSOR_NWSE_RESIZE}, {"col-resize", SIV_CURSOR_COL_RESIZE}, {"row-resize", SIV_CURSOR_ROW_RESIZE}, {"all-scroll", SIV_CURSOR_ALL_SCROLL},
    {"zoom-in", SIV_CURSOR_ZOOM_IN}, {"zoom-out", SIV_CURSOR_ZOOM_OUT}, {"none", SIV_CURSOR_HIDDEN},
};

static void swv_view_set_cursor_from_name(WPEView *view, const char *name) {
    wpe_wv *w = SWV_VIEW(view)->w;
    if (!w) return;
    siv_cursor c = SIV_CURSOR_DEFAULT;
    for (size_t i = 0; i < G_N_ELEMENTS(cursors); i++)
        if (!strcmp(cursors[i].name, name)) c = cursors[i].cursor;
    swv_set_cursor(w->wv, c);
}

static gboolean swv_view_can_be_mapped(WPEView *view) {
    (void)view;
    return TRUE;
}

static WPEViewAccessible *swv_view_get_accessible(WPEView *view) {
    SwvView *v = SWV_VIEW(view);
    if (!v->accessible && v->w) {
        v->accessible = g_object_new(swv_accessible_get_type(), NULL);
        v->accessible->webview = v->w->wv->handle;
    }
    return v->accessible ? WPE_VIEW_ACCESSIBLE(v->accessible) : NULL;
}

static void swv_view_dispose(GObject *object) {
    g_clear_object(&SWV_VIEW(object)->accessible);
    G_OBJECT_CLASS(swv_view_parent_class)->dispose(object);
}

static void swv_view_class_init(SwvViewClass *klass) {
    WPEViewClass *v = WPE_VIEW_CLASS(klass);
    v->render_buffer = swv_view_render_buffer;
    v->set_cursor_from_name = swv_view_set_cursor_from_name;
    v->can_be_mapped = swv_view_can_be_mapped;
    v->get_accessible = swv_view_get_accessible;
    G_OBJECT_CLASS(klass)->dispose = swv_view_dispose;
}
static void swv_view_init(SwvView *self) { (void)self; }

/* ---------- input method: siv_set_text_input and text_input events ---------- */

G_DECLARE_FINAL_TYPE(SwvIM, swv_im, SWV, IM, WPEInputMethodContext)

struct _SwvIM {
    WPEInputMethodContext parent;
    bool active;
    char *surrounding;
    guint cursor, anchor;
    int x, y, w, h;
    char *preedit;
    int preedit_cursor;
};
G_DEFINE_FINAL_TYPE(SwvIM, swv_im, WPE_TYPE_INPUT_METHOD_CONTEXT)

static wpe_wv *im_owner(SwvIM *im) {
    WPEView *view = wpe_input_method_context_get_view(WPE_INPUT_METHOD_CONTEXT(im));
    return view && SWV_IS_VIEW(view) ? SWV_VIEW(view)->w : NULL;
}

static siv_text_input_purpose purpose_of(WPEInputPurpose p) {
    switch (p) {
    case WPE_INPUT_PURPOSE_ALPHA: return SIV_TEXT_INPUT_PURPOSE_ALPHA;
    case WPE_INPUT_PURPOSE_DIGITS: return SIV_TEXT_INPUT_PURPOSE_DIGITS;
    case WPE_INPUT_PURPOSE_NUMBER: return SIV_TEXT_INPUT_PURPOSE_NUMBER;
    case WPE_INPUT_PURPOSE_PHONE: return SIV_TEXT_INPUT_PURPOSE_PHONE;
    case WPE_INPUT_PURPOSE_URL: return SIV_TEXT_INPUT_PURPOSE_URL;
    case WPE_INPUT_PURPOSE_EMAIL: return SIV_TEXT_INPUT_PURPOSE_EMAIL;
    case WPE_INPUT_PURPOSE_NAME: return SIV_TEXT_INPUT_PURPOSE_NAME;
    case WPE_INPUT_PURPOSE_PASSWORD: return SIV_TEXT_INPUT_PURPOSE_PASSWORD;
    case WPE_INPUT_PURPOSE_PIN: return SIV_TEXT_INPUT_PURPOSE_PIN;
    case WPE_INPUT_PURPOSE_TERMINAL: return SIV_TEXT_INPUT_PURPOSE_TERMINAL;
    default: return SIV_TEXT_INPUT_PURPOSE_NORMAL;
    }
}

static void im_push(SwvIM *im) {
    wpe_wv *w = im_owner(im);
    if (!w) return;
    if (!im->active) {
        swv_set_text_input(w->wv, NULL);
        return;
    }
    WPEInputMethodContext *ctx = WPE_INPUT_METHOD_CONTEXT(im);
    WPEInputHints hints = wpe_input_method_context_get_input_hints(ctx);
    siv_text_input_hints h = 0;
    if (hints & WPE_INPUT_HINT_SPELLCHECK) h |= SIV_TEXT_INPUT_HINTS_SPELLCHECK;
    if (hints & WPE_INPUT_HINT_LOWERCASE) h |= SIV_TEXT_INPUT_HINTS_LOWERCASE;
    if (hints & WPE_INPUT_HINT_UPPERCASE_CHARS) h |= SIV_TEXT_INPUT_HINTS_UPPERCASE;
    if (hints & WPE_INPUT_HINT_UPPERCASE_WORDS) h |= SIV_TEXT_INPUT_HINTS_TITLECASE;
    if (hints & WPE_INPUT_HINT_UPPERCASE_SENTENCES) h |= SIV_TEXT_INPUT_HINTS_AUTO_CAPITALIZATION;
    const char *text = im->surrounding ? im->surrounding : "";
    size_t len = strlen(text);
    siv_text_input_desc d = {
        .size = sizeof d,
        .surrounding = text,
        .surrounding_len = len,
        .cursor = MIN(im->cursor, (guint)len),
        .anchor = MIN(im->anchor, (guint)len),
        .cursor_rect = {(float)im->x, (float)im->y, (float)MAX(im->w, 1), (float)MAX(im->h, 1)},
        .purpose = purpose_of(wpe_input_method_context_get_input_purpose(ctx)),
        .hints = h,
    };
    swv_set_text_input(w->wv, &d);
}

static void swv_im_get_preedit_string(WPEInputMethodContext *ctx, gchar **text, GList **underlines, guint *cursor_offset) {
    SwvIM *im = SWV_IM(ctx);
    const char *p = im->preedit ? im->preedit : "";
    if (text) *text = g_strdup(p);
    if (underlines) *underlines = *p ? g_list_prepend(NULL, wpe_input_method_underline_new(0, (guint)g_utf8_strlen(p, -1))) : NULL;
    if (cursor_offset) *cursor_offset = im->preedit_cursor >= 0 ? (guint)g_utf8_pointer_to_offset(p, p + MIN((size_t)im->preedit_cursor, strlen(p))) : 0;
}

static gboolean swv_im_filter_key_event(WPEInputMethodContext *ctx, WPEEvent *event) {
    (void)ctx, (void)event;
    return FALSE; /* text-input-v3: the compositor's input method sees keys first */
}

static void swv_im_focus_in(WPEInputMethodContext *ctx) {
    SWV_IM(ctx)->active = true;
    im_push(SWV_IM(ctx));
}

static void swv_im_focus_out(WPEInputMethodContext *ctx) {
    SWV_IM(ctx)->active = false;
    im_push(SWV_IM(ctx));
}

static void swv_im_set_cursor_area(WPEInputMethodContext *ctx, int x, int y, int width, int height) {
    SwvIM *im = SWV_IM(ctx);
    im->x = x, im->y = y, im->w = width, im->h = height;
    im_push(im);
}

static void swv_im_set_surrounding(WPEInputMethodContext *ctx, const gchar *text, guint length, guint cursor_index, guint selection_index) {
    SwvIM *im = SWV_IM(ctx);
    g_free(im->surrounding);
    /* At most 4000 bytes around the cursor, cut at characters (siv takes
     * the protocol's limit). */
    guint start = 0, end = length;
    if (length > 3800) {
        start = cursor_index > 1900 ? cursor_index - 1900 : 0;
        end = MIN(length, start + 3800);
        while (start > 0 && (text[start] & 0xc0) == 0x80) start++;
        while (end < length && (text[end] & 0xc0) == 0x80) end--;
    }
    im->surrounding = g_strndup(text + start, end - start);
    im->cursor = CLAMP(cursor_index, start, end) - start;
    im->anchor = CLAMP(selection_index, start, end) - start;
    im_push(im);
}

static void swv_im_reset(WPEInputMethodContext *ctx) {
    SwvIM *im = SWV_IM(ctx);
    g_clear_pointer(&im->preedit, g_free);
}

static void swv_im_finalize(GObject *object) {
    SwvIM *im = SWV_IM(object);
    g_free(im->surrounding);
    g_free(im->preedit);
    G_OBJECT_CLASS(swv_im_parent_class)->finalize(object);
}

static void swv_im_class_init(SwvIMClass *klass) {
    WPEInputMethodContextClass *c = WPE_INPUT_METHOD_CONTEXT_CLASS(klass);
    c->get_preedit_string = swv_im_get_preedit_string;
    c->filter_key_event = swv_im_filter_key_event;
    c->focus_in = swv_im_focus_in;
    c->focus_out = swv_im_focus_out;
    c->set_cursor_area = swv_im_set_cursor_area;
    c->set_surrounding = swv_im_set_surrounding;
    c->reset = swv_im_reset;
    G_OBJECT_CLASS(klass)->finalize = swv_im_finalize;
}
static void swv_im_init(SwvIM *self) { self->preedit_cursor = -1; }

/* An input method's edit from siv (text_input event): deletion around the
 * cursor, the commit, then the preedit, as WPE's signals. */
static void im_apply(SwvIM *im, const siv_event *e) {
    if (e->delete_before || e->delete_after) {
        const char *s = im->surrounding ? im->surrounding : "";
        size_t len = strlen(s), cur = MIN(im->cursor, len);
        size_t before = MIN((size_t)e->delete_before, cur), after = MIN((size_t)e->delete_after, len - cur);
        glong cb = g_utf8_pointer_to_offset(s + cur - before, s + cur);
        glong ca = g_utf8_pointer_to_offset(s + cur, s + cur + after);
        g_signal_emit_by_name(im, "delete-surrounding", (gint)-cb, (guint)(cb + ca));
    }
    if (e->text_len) {
        char *commit = g_strndup(e->text, e->text_len);
        g_signal_emit_by_name(im, "committed", commit);
        g_free(commit);
    }
    bool had = im->preedit && *im->preedit;
    g_clear_pointer(&im->preedit, g_free);
    if (e->preedit_len) {
        im->preedit = g_strndup(e->preedit, e->preedit_len);
        im->preedit_cursor = e->preedit_cursor_begin;
        if (!had) g_signal_emit_by_name(im, "preedit-started");
        g_signal_emit_by_name(im, "preedit-changed");
    } else if (had) {
        g_signal_emit_by_name(im, "preedit-changed");
        g_signal_emit_by_name(im, "preedit-finished");
    }
}

/* ---------- clipboard: siv's, read ahead of a paste ---------- */

G_DECLARE_FINAL_TYPE(SwvClipboard, swv_clipboard, SWV, CLIPBOARD, WPEClipboard)
struct _SwvClipboard {
    WPEClipboard parent;
    wpe_app *app;
};
G_DEFINE_FINAL_TYPE(SwvClipboard, swv_clipboard, WPE_TYPE_CLIPBOARD)

static GBytes *swv_clipboard_read(WPEClipboard *clipboard, const char *format) {
    wpe_app *a = SWV_CLIPBOARD(clipboard)->app;
    GBytes *b = a && a->clip ? g_hash_table_lookup(a->clip, format) : NULL;
    return b ? g_bytes_ref(b) : NULL;
}

/* The page copied: the formats go to siv's clipboard on the focused web
 * view's window. */
static void swv_clipboard_changed(WPEClipboard *clipboard, GPtrArray *formats, gboolean is_local, WPEClipboardContent *content) {
    WPE_CLIPBOARD_CLASS(swv_clipboard_parent_class)->changed(clipboard, formats, is_local, content);
    wpe_app *a = SWV_CLIPBOARD(clipboard)->app;
    if (!is_local || !content || !formats || !a) return;
    swv_webview *wv = swv_handle_get(&swv_webviews, a->focus);
    if (!wv) return;
    GString *mimes = g_string_new(NULL);
    GByteArray *data = g_byte_array_new();
    GArray *lengths = g_array_new(FALSE, FALSE, sizeof(size_t));
    for (guint i = 0; i < formats->len; i++) {
        const char *fmt = g_ptr_array_index(formats, i);
        GBytes *b = NULL;
        const char *text = wpe_clipboard_content_get_text(content);
        if (g_str_has_prefix(fmt, "text/plain") && text) b = g_bytes_new(text, strlen(text));
        else b = wpe_clipboard_content_get_bytes(content, fmt) ? g_bytes_ref(wpe_clipboard_content_get_bytes(content, fmt)) : NULL;
        if (!b) continue;
        gsize n;
        const guint8 *p = g_bytes_get_data(b, &n);
        if (mimes->len) g_string_append_c(mimes, '\n');
        g_string_append(mimes, fmt);
        g_byte_array_append(data, p, (guint)n);
        size_t len = n;
        g_array_append_val(lengths, len);
        g_bytes_unref(b);
    }
    if (mimes->len)
        (void)siv_clipboard_write_data(wv->window, SIV_SELECTION_CLIPBOARD, SIV_DESC(siv_clipboard_desc, .mimes = mimes->str, .mimes_len = mimes->len, .data = data->data, .data_count = data->len, .lengths = (const size_t *)(void *)lengths->data, .lengths_count = lengths->len));
    g_string_free(mimes, TRUE);
    g_byte_array_unref(data);
    g_array_unref(lengths);
}

static void swv_clipboard_class_init(SwvClipboardClass *klass) {
    WPE_CLIPBOARD_CLASS(klass)->read = swv_clipboard_read;
    WPE_CLIPBOARD_CLASS(klass)->changed = swv_clipboard_changed;
}
static void swv_clipboard_init(SwvClipboard *self) { (void)self; }

/* ---------- WPEDisplay ---------- */

G_DECLARE_FINAL_TYPE(SwvDisplay, swv_display, SWV, DISPLAY, WPEDisplay)
struct _SwvDisplay {
    WPEDisplay parent;
    wpe_app *app;
    WPEDRMDevice *drm;
    char render[64];
    int gbm_fd;
    struct gbm_device *gbm;
    EGLDisplay egl;
    WPEKeymap *keymap;
    WPEScreen *screen;
    SwvClipboard *clipboard;
};
G_DEFINE_FINAL_TYPE(SwvDisplay, swv_display, WPE_TYPE_DISPLAY)

static gboolean swv_display_connect(WPEDisplay *display, GError **error) {
    (void)error;
    SwvDisplay *self = SWV_DISPLAY(display);
    char primary[64];
    if (!software() && find_drm(self->render, sizeof self->render, primary, sizeof primary)) self->drm = wpe_drm_device_new(primary[0] ? primary : NULL, self->render);
    self->screen = g_object_new(swv_screen_get_type(), "id", 1, NULL);
    wpe_screen_set_scale(self->screen, 1.0);
    wpe_screen_set_refresh_rate(self->screen, 60000);
    /* WebKit answers the pointer, hover, any-pointer, and any-hover media
     * queries from the primary display's input devices, which it reads as
     * it starts a web process; without any, pages see (pointer: none) and
     * hide their hover-only controls. siv's API does not say which devices
     * the seat has, and siv is a desktop toolkit: a mouse and a keyboard,
     * set here, before the first web view. Not a touchscreen, which would
     * make (any-pointer: coarse) true and pages enlarge their targets on
     * every desktop. */
    wpe_display_set_available_input_devices(display, WPE_AVAILABLE_INPUT_DEVICE_MOUSE | WPE_AVAILABLE_INPUT_DEVICE_KEYBOARD);
    return TRUE;
}

static WPEView *swv_display_create_view(WPEDisplay *display) { return g_object_new(swv_view_get_type(), "display", display, NULL); }
static WPEToplevel *swv_display_create_toplevel(WPEDisplay *display, guint max_views) { return g_object_new(swv_toplevel_get_type(), "display", display, "max-views", max_views, NULL); }

static gpointer swv_display_get_egl_display(WPEDisplay *display, GError **error) {
    SwvDisplay *self = SWV_DISPLAY(display);
    if (self->egl) return self->egl;
    if (!self->drm) {
        g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE, "no DRM device");
        return NULL;
    }
    self->gbm_fd = open(self->render, O_RDWR | O_CLOEXEC);
    if (self->gbm_fd < 0 || !(self->gbm = gbm_create_device(self->gbm_fd))) {
        g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE, "no GBM device");
        return NULL;
    }
    PFNEGLGETPLATFORMDISPLAYEXTPROC get = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    self->egl = get ? get(EGL_PLATFORM_GBM_KHR, self->gbm, NULL) : EGL_NO_DISPLAY;
    if (self->egl == EGL_NO_DISPLAY) {
        self->egl = NULL;
        g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE, "no EGL display");
        return NULL;
    }
    return self->egl;
}

static WPEDRMDevice *swv_display_get_drm_device(WPEDisplay *display) { return SWV_DISPLAY(display)->drm; }

static WPEKeymap *swv_display_get_keymap(WPEDisplay *display) {
    SwvDisplay *self = SWV_DISPLAY(display);
    if (!self->keymap) self->keymap = wpe_keymap_xkb_new();
    return self->keymap;
}

static WPEClipboard *swv_display_get_clipboard(WPEDisplay *display) {
    SwvDisplay *self = SWV_DISPLAY(display);
    if (!self->clipboard) {
        self->clipboard = g_object_new(swv_clipboard_get_type(), "display", display, NULL);
        self->clipboard->app = self->app;
    }
    return WPE_CLIPBOARD(self->clipboard);
}

static guint swv_display_get_n_screens(WPEDisplay *display) {
    (void)display;
    return 1;
}
static WPEScreen *swv_display_get_screen(WPEDisplay *display, guint index) { return index == 0 ? SWV_DISPLAY(display)->screen : NULL; }
static gboolean swv_display_use_explicit_sync(WPEDisplay *display) {
    (void)display;
    return TRUE;
}
static WPEInputMethodContext *swv_display_create_input_method_context(WPEDisplay *display, WPEView *view) {
    (void)display;
    WPEInputMethodContext *ctx = g_object_new(swv_im_get_type(), "view", view, NULL);
    if (SWV_IS_VIEW(view)) SWV_VIEW(view)->im = ctx;
    return ctx;
}

static void swv_display_dispose(GObject *object) {
    SwvDisplay *self = SWV_DISPLAY(object);
    g_clear_object(&self->clipboard);
    g_clear_object(&self->keymap);
    g_clear_object(&self->screen);
    g_clear_pointer(&self->drm, wpe_drm_device_unref);
    if (self->gbm) gbm_device_destroy(self->gbm), self->gbm = NULL;
    if (self->gbm_fd >= 0) close(self->gbm_fd), self->gbm_fd = -1;
    G_OBJECT_CLASS(swv_display_parent_class)->dispose(object);
}

static void swv_display_class_init(SwvDisplayClass *klass) {
    WPEDisplayClass *d = WPE_DISPLAY_CLASS(klass);
    d->connect = swv_display_connect;
    d->create_view = swv_display_create_view;
    d->create_toplevel = swv_display_create_toplevel;
    d->get_egl_display = swv_display_get_egl_display;
    d->get_drm_device = swv_display_get_drm_device;
    d->get_keymap = swv_display_get_keymap;
    d->get_clipboard = swv_display_get_clipboard;
    d->get_n_screens = swv_display_get_n_screens;
    d->get_screen = swv_display_get_screen;
    d->use_explicit_sync = swv_display_use_explicit_sync;
    d->create_input_method_context = swv_display_create_input_method_context;
    G_OBJECT_CLASS(klass)->dispose = swv_display_dispose;
}
static void swv_display_init(SwvDisplay *self) { self->gbm_fd = -1; }

/* The WebKit side: web views, their signals, and the engine table. */
#include "wpe_webkit.inc"
