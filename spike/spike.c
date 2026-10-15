/* Phase 1 spike: WPE WebKit's platform API (WPEPlatform, 2.52) rendering
 * into a siv window through siv's public C ABI only.
 *
 *   spike [URL]
 *
 * Environment: SPIKE_FULL=1 drops the toolbar so the page covers the whole
 * window (reproduces siv's frame-callback stall), SPIKE_IMPLICIT=1 turns
 * WPE's explicit sync off, SPIKE_PACE=presented paces WebKit on siv's
 * window PRESENTED event instead of an idle after each submit,
 * SPIKE_LOG=1 logs frames and keys.
 *
 * What siv lacks, and how the spike bridges it (see NOTES.md):
 *   - GLib integration: GLib drives; siv's loop fd is a GSource (D6).
 *   - Node size and scale: polled with siv_node_get_rect and
 *     siv_window_get_scale after every siv dispatch.
 *   - Frame pacing: no event says when a slot's frame reached the screen;
 *     wpe_view_buffer_rendered is called on idle after each submit.
 *   - A fully covering opaque subsurface stops the window's frame callbacks
 *     on wlroots, which stalls siv: the toolbar keeps part of the window
 *     visible.
 *   - Input: siv_on pointer/scroll/key/focus on the external node. No
 *     hardware keycode, scroll arrives after siv's own wheel policy (no
 *     value120, source, or stop), no raw touch, no IME, no cursor images.
 */
#define _GNU_SOURCE
#include <siv.h>

#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>
#include <glib-unix.h>

#include <epoxy/egl.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define RENDER_NODE "/dev/dri/renderD128"
#define PRIMARY_NODE "/dev/dri/card1"

static uint64_t now_ns(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static struct spike {
	uint64_t t0;
	bool log, pace_presented;
	siv_app app;
	siv_window window;
	siv_external slot;
	siv_node node, address, back, forward, reload;
	GMainLoop *loop;
	WebKitWebView *web_view;
	WPEView *view;
	WPEToplevel *toplevel;
	float width, height;
	double scale;
	uint32_t buttons; /* WPE pointer button modifiers held */
	double px, py;
	GPtrArray *awaiting; /* submitted, not yet reported rendered */
	guint rendered_idle;
	uint64_t first_render_ns, first_submit_ns;
	unsigned frames;
	siv_cursor cursor;
	unsigned in_flight, max_in_flight;
	uint64_t held_ns, held_n;
	GHashTable *submit_time;
} S;

/* ---------- WPEScreen, WPEToplevel ---------- */

G_DECLARE_FINAL_TYPE(SivScreen, siv_screen, SIV, SCREEN, WPEScreen)
struct _SivScreen { WPEScreen parent; };
G_DEFINE_FINAL_TYPE(SivScreen, siv_screen, WPE_TYPE_SCREEN)
static void siv_screen_class_init(SivScreenClass *klass) { (void)klass; }
static void siv_screen_init(SivScreen *self) { (void)self; }

G_DECLARE_FINAL_TYPE(SivToplevel, siv_toplevel, SIV, TOPLEVEL, WPEToplevel)
struct _SivToplevel { WPEToplevel parent; };
G_DEFINE_FINAL_TYPE(SivToplevel, siv_toplevel, WPE_TYPE_TOPLEVEL)
static WPEScreen *siv_toplevel_get_screen(WPEToplevel *toplevel) { return wpe_display_get_screen(wpe_toplevel_get_display(toplevel), 0); }
static void siv_toplevel_class_init(SivToplevelClass *klass) { WPE_TOPLEVEL_CLASS(klass)->get_screen = siv_toplevel_get_screen; }
static void siv_toplevel_init(SivToplevel *self) { (void)self; }

/* ---------- WPEView ---------- */

G_DECLARE_FINAL_TYPE(SivView, siv_view, SIV, VIEW, WPEView)
struct _SivView { WPEView parent; };
G_DEFINE_FINAL_TYPE(SivView, siv_view, WPE_TYPE_VIEW)

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

static gboolean report_rendered(gpointer data) {
	(void)data;
	S.rendered_idle = 0;
	for (guint i = 0; i < S.awaiting->len; i++) wpe_view_buffer_rendered(S.view, g_ptr_array_index(S.awaiting, i));
	g_ptr_array_set_size(S.awaiting, 0);
	return G_SOURCE_REMOVE;
}

static gboolean siv_view_render_buffer(WPEView *view, WPEBuffer *buffer, const WPERectangle *damage, guint n_damage, GError **error) {
	(void)view, (void)damage, (void)n_damage;
	if (!S.first_render_ns) {
		S.first_render_ns = now_ns();
		fprintf(stderr, "spike: first render_buffer at %.1f ms\n", (S.first_render_ns - S.t0) / 1e6);
	}
	int width = wpe_buffer_get_width(buffer), height = wpe_buffer_get_height(buffer);
	siv_external_frame_desc f = {.size = sizeof f, .key = (uint64_t)(uintptr_t)buffer, .width = (uint32_t)width, .height = (uint32_t)height};
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
		if (S.log && S.frames < 2)
			fprintf(stderr, "spike: dma-buf %dx%d %.4s modifier 0x%llx planes %u fence %d\n", width, height, (char *)&f.drm_format, (unsigned long long)f.modifier, n, fence);
	} else if (WPE_IS_BUFFER_SHM(buffer)) {
		/* siv maps an fd; WPE's SHM buffer is bytes: copy into a memfd kept
		 * on the buffer. */
		WPEBufferSHM *s = WPE_BUFFER_SHM(buffer);
		gsize len;
		const void *src = g_bytes_get_data(wpe_buffer_shm_get_data(s), &len);
		struct shm_copy *c = wpe_buffer_get_user_data(buffer);
		if (!c) {
			c = g_new0(struct shm_copy, 1);
			c->size = len;
			c->fd = memfd_create("wpe-shm", MFD_CLOEXEC);
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
	siv_result r = siv_external_submit(S.slot, &f);
	if (fence >= 0) close(fence);
	if (r != SIV_OK) {
		g_set_error(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "siv_external_submit: %s", siv_result_name(r));
		return FALSE;
	}
	if (!S.first_submit_ns) S.first_submit_ns = now_ns();
	S.frames++;
	g_object_ref(buffer); /* until siv releases its key */
	S.in_flight++;
	if (S.in_flight > S.max_in_flight) S.max_in_flight = S.in_flight;
	g_hash_table_insert(S.submit_time, buffer, GSIZE_TO_POINTER((gsize)now_ns()));
	g_ptr_array_add(S.awaiting, g_object_ref(buffer));
	if (!S.pace_presented && !S.rendered_idle) S.rendered_idle = g_idle_add(report_rendered, NULL);
	return TRUE;
}

static const struct {
	const char *name;
	siv_cursor cursor;
} cursor_names[] = {
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

static void siv_view_set_cursor_from_name(WPEView *view, const char *name) {
	(void)view;
	siv_cursor c = SIV_CURSOR_DEFAULT;
	for (size_t i = 0; i < G_N_ELEMENTS(cursor_names); i++)
		if (!strcmp(cursor_names[i].name, name)) c = cursor_names[i].cursor;
	if (c == S.cursor) return;
	S.cursor = c;
	siv_txn txn;
	if (siv_txn_begin(S.window, &txn) != SIV_OK) return;
	siv_set_cursor(txn, S.node, c);
	if (siv_txn_commit(txn) != SIV_OK) fprintf(stderr, "spike: cursor commit failed\n");
}

static gboolean siv_view_can_be_mapped(WPEView *view) {
	(void)view;
	return TRUE;
}

static void siv_view_class_init(SivViewClass *klass) {
	WPEViewClass *v = WPE_VIEW_CLASS(klass);
	v->render_buffer = siv_view_render_buffer;
	v->set_cursor_from_name = siv_view_set_cursor_from_name;
	v->can_be_mapped = siv_view_can_be_mapped;
}
static void siv_view_init(SivView *self) { (void)self; }

/* ---------- WPEDisplay ---------- */

G_DECLARE_FINAL_TYPE(SivDisplay, siv_display, SIV, DISPLAY, WPEDisplay)
struct _SivDisplay {
	WPEDisplay parent;
	WPEDRMDevice *drm;
	int gbm_fd;
	struct gbm_device *gbm;
	EGLDisplay egl;
	WPEKeymap *keymap;
	WPEScreen *screen;
};
G_DEFINE_FINAL_TYPE(SivDisplay, siv_display, WPE_TYPE_DISPLAY)

static gboolean siv_display_connect(WPEDisplay *display, GError **error) {
	(void)error;
	SivDisplay *self = SIV_DISPLAY(display);
	self->drm = wpe_drm_device_new(PRIMARY_NODE, RENDER_NODE);
	self->screen = g_object_new(siv_screen_get_type(), "id", 1, NULL);
	wpe_screen_set_size(self->screen, 1280, 800);
	wpe_screen_set_scale(self->screen, 1.0);
	wpe_screen_set_refresh_rate(self->screen, 60000);
	return TRUE;
}

static WPEView *siv_display_create_view(WPEDisplay *display) { return g_object_new(siv_view_get_type(), "display", display, NULL); }
static WPEToplevel *siv_display_create_toplevel(WPEDisplay *display, guint max_views) { return g_object_new(siv_toplevel_get_type(), "display", display, "max-views", max_views, NULL); }

static gpointer siv_display_get_egl_display(WPEDisplay *display, GError **error) {
	SivDisplay *self = SIV_DISPLAY(display);
	if (self->egl) return self->egl;
	self->gbm_fd = open(RENDER_NODE, O_RDWR | O_CLOEXEC);
	if (self->gbm_fd < 0 || !(self->gbm = gbm_create_device(self->gbm_fd))) {
		g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE, "no GBM device");
		return NULL;
	}
	self->egl = eglGetPlatformDisplayEXT(EGL_PLATFORM_GBM_KHR, self->gbm, NULL);
	if (self->egl == EGL_NO_DISPLAY) {
		g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE, "no EGL display");
		return NULL;
	}
	return self->egl;
}

static WPEDRMDevice *siv_display_get_drm_device(WPEDisplay *display) { return SIV_DISPLAY(display)->drm; }

static WPEKeymap *siv_display_get_keymap(WPEDisplay *display) {
	SivDisplay *self = SIV_DISPLAY(display);
	if (!self->keymap) self->keymap = wpe_keymap_xkb_new();
	return self->keymap;
}

static guint siv_display_get_n_screens(WPEDisplay *display) {
	(void)display;
	return 1;
}
static WPEScreen *siv_display_get_screen(WPEDisplay *display, guint index) { return index == 0 ? SIV_DISPLAY(display)->screen : NULL; }
static gboolean siv_display_use_explicit_sync(WPEDisplay *display) {
	(void)display;
	return getenv("SPIKE_IMPLICIT") ? FALSE : TRUE;
}

static void siv_display_class_init(SivDisplayClass *klass) {
	WPEDisplayClass *d = WPE_DISPLAY_CLASS(klass);
	d->connect = siv_display_connect;
	d->create_view = siv_display_create_view;
	d->create_toplevel = siv_display_create_toplevel;
	d->get_egl_display = siv_display_get_egl_display;
	d->get_drm_device = siv_display_get_drm_device;
	d->get_keymap = siv_display_get_keymap;
	d->get_n_screens = siv_display_get_n_screens;
	d->get_screen = siv_display_get_screen;
	d->use_explicit_sync = siv_display_use_explicit_sync;
}
static void siv_display_init(SivDisplay *self) { self->gbm_fd = -1; }

/* ---------- siv side ---------- */

static void released_on_main(void *user_data) {
	WPEBuffer *buffer = user_data;
	S.in_flight--;
	gsize t = GPOINTER_TO_SIZE(g_hash_table_lookup(S.submit_time, buffer));
	if (t) S.held_ns += now_ns() - t, S.held_n++;
	if (S.view) wpe_view_buffer_released(S.view, buffer);
	g_object_unref(buffer);
}

/* siv's compositor thread: hand the buffer back on the main thread. */
static void on_release(void *user_data, siv_external slot, uint64_t key) {
	(void)user_data, (void)slot;
	if (siv_post(S.app, released_on_main, NULL, (void *)(uintptr_t)key) != SIV_OK) fprintf(stderr, "spike: cannot post a release\n");
}

static void sync_geometry(void) {
	siv_rect rect;
	if (siv_node_get_rect(S.node, &rect) != SIV_OK) return;
	double scale = 1;
	if (siv_window_get_scale(S.window, &scale) != SIV_OK) scale = 1;
	if (scale != S.scale) {
		S.scale = scale;
		wpe_screen_set_scale(wpe_display_get_screen(wpe_view_get_display(S.view), 0), scale);
		wpe_toplevel_scale_changed(S.toplevel, scale);
	}
	if (rect.width > 0 && rect.height > 0 && (rect.width != S.width || rect.height != S.height)) {
		S.width = rect.width, S.height = rect.height;
		if (S.log) fprintf(stderr, "spike: view %gx%g scale %g\n", rect.width, rect.height, scale);
		wpe_toplevel_resized(S.toplevel, (int)rect.width, (int)rect.height);
		wpe_view_resized(S.view, (int)rect.width, (int)rect.height);
	}
}

static gboolean on_siv_fd(gint fd, GIOCondition cond, gpointer data) {
	(void)fd, (void)cond, (void)data;
	siv_result r = siv_app_dispatch(S.app, 0);
	if (r != SIV_OK) {
		fprintf(stderr, "spike: dispatch: %s\n", siv_result_name(r));
		g_main_loop_quit(S.loop);
		return G_SOURCE_REMOVE;
	}
	if (S.view) sync_geometry();
	return G_SOURCE_CONTINUE;
}

static bool on_window_event(void *user_data, siv_window window, const siv_window_event *event) {
	(void)user_data, (void)window;
	if (event->type == SIV_WINDOW_EVENT_TYPE_CLOSE_REQUESTED) {
		g_main_loop_quit(S.loop);
		return true;
	}
	if (event->type == SIV_WINDOW_EVENT_TYPE_PRESENTED && S.pace_presented) report_rendered(NULL);
	return false;
}

static WPEModifiers wpe_mods(siv_modifiers m) {
	unsigned w = S.buttons;
	if (m & SIV_MODIFIERS_SHIFT) w |= WPE_MODIFIER_KEYBOARD_SHIFT;
	if (m & SIV_MODIFIERS_CTRL) w |= WPE_MODIFIER_KEYBOARD_CONTROL;
	if (m & SIV_MODIFIERS_ALT) w |= WPE_MODIFIER_KEYBOARD_ALT;
	if (m & SIV_MODIFIERS_SUPER) w |= WPE_MODIFIER_KEYBOARD_META;
	if (m & SIV_MODIFIERS_CAPS_LOCK) w |= WPE_MODIFIER_KEYBOARD_CAPS_LOCK;
	return (WPEModifiers)w;
}

static void send(WPEEvent *e) {
	wpe_view_event(S.view, e);
	wpe_event_unref(e);
}

static siv_event_result on_pointer(void *user_data, siv_node node, const siv_event *e) {
	(void)user_data, (void)node;
	S.px = e->x, S.py = e->y;
	switch (e->phase) {
	case SIV_POINTER_PHASE_MOVE:
	case SIV_POINTER_PHASE_ENTER:
	case SIV_POINTER_PHASE_LEAVE: {
		WPEEventType t = e->phase == SIV_POINTER_PHASE_MOVE ? WPE_EVENT_POINTER_MOVE : e->phase == SIV_POINTER_PHASE_ENTER ? WPE_EVENT_POINTER_ENTER : WPE_EVENT_POINTER_LEAVE;
		send(wpe_event_pointer_move_new(t, S.view, WPE_INPUT_SOURCE_MOUSE, e->time, wpe_mods(e->modifiers), e->x, e->y, 0, 0));
		return SIV_EVENT_RESULT_HANDLED;
	}
	case SIV_POINTER_PHASE_DOWN:
	case SIV_POINTER_PHASE_UP: {
		guint button = e->button == SIV_POINTER_BUTTON_PRIMARY ? WPE_BUTTON_PRIMARY : e->button == SIV_POINTER_BUTTON_SECONDARY ? WPE_BUTTON_SECONDARY : e->button == SIV_POINTER_BUTTON_MIDDLE ? WPE_BUTTON_MIDDLE : (e->button_code >= 0x110 ? e->button_code - 0x110 + 1 : 0);
		unsigned mod = button >= 1 && button <= 5 ? WPE_MODIFIER_POINTER_BUTTON1 << (button - 1) : 0;
		bool down = e->phase == SIV_POINTER_PHASE_DOWN;
		if (down) S.buttons |= mod;
		else S.buttons &= ~mod;
		guint count = down ? wpe_view_compute_press_count(S.view, e->x, e->y, button, e->time) : 0;
		send(wpe_event_pointer_button_new(down ? WPE_EVENT_POINTER_DOWN : WPE_EVENT_POINTER_UP, S.view, WPE_INPUT_SOURCE_MOUSE, e->time, wpe_mods(e->modifiers), button, e->x, e->y, count));
		/* A press still focuses the view (siv's default action). */
		return down ? SIV_EVENT_RESULT_STOP : SIV_EVENT_RESULT_HANDLED;
	}
	default:
		return SIV_EVENT_RESULT_PASS;
	}
}

static siv_event_result on_scroll(void *user_data, siv_node node, const siv_event *e) {
	(void)user_data, (void)node;
	/* siv's dx/dy have its wheel policy applied (D16), in logical pixels;
	 * WPE's precise deltas are pixels, positive up and left. */
	send(wpe_event_scroll_new(S.view, WPE_INPUT_SOURCE_MOUSE, e->time, wpe_mods(e->modifiers), -e->dx, -e->dy, TRUE, FALSE, S.px, S.py));
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_key(void *user_data, siv_node node, const siv_event *e) {
	(void)user_data, (void)node;
	bool pressed = e->flags & SIV_EVENT_PRESSED;
	/* siv_event has no hardware keycode: 0. */
	send(wpe_event_keyboard_new(pressed ? WPE_EVENT_KEYBOARD_KEY_DOWN : WPE_EVENT_KEYBOARD_KEY_UP, S.view, WPE_INPUT_SOURCE_KEYBOARD, e->time, wpe_mods(e->modifiers), 0, (guint)e->keysym));
	if (S.log) fprintf(stderr, "spike: key %s 0x%x '%.*s'\n", pressed ? "down" : "up", (unsigned)e->keysym, (int)e->text_len, e->text ? e->text : "");
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_focus(void *user_data, siv_node node, const siv_event *e) {
	(void)user_data, (void)node;
	if (e->flags & SIV_EVENT_GAINED) wpe_view_focus_in(S.view);
	else wpe_view_focus_out(S.view);
	return SIV_EVENT_RESULT_HANDLED;
}

/* ---------- toolbar ---------- */

static void set_address(const char *uri) {
	siv_txn txn;
	if (!uri || siv_txn_begin(S.window, &txn) != SIV_OK) return;
	siv_set_text(txn, S.address, uri, strlen(uri));
	siv_widget_set_disabled(txn, S.back, !webkit_web_view_can_go_back(S.web_view));
	siv_widget_set_disabled(txn, S.forward, !webkit_web_view_can_go_forward(S.web_view));
	if (siv_txn_commit(txn) != SIV_OK) fprintf(stderr, "spike: toolbar commit failed\n");
}

static siv_event_result on_address_key(void *user_data, siv_node node, const siv_event *e) {
	(void)user_data;
	if (!(e->flags & SIV_EVENT_PRESSED) || (e->keysym != SIV_KEY_RETURN && e->keysym != SIV_KEY_KP_ENTER)) return SIV_EVENT_RESULT_PASS;
	char text[2048];
	size_t len = 0;
	if (siv_node_get_text(node, text, sizeof text - 1, &len) != SIV_OK) return SIV_EVENT_RESULT_HANDLED;
	text[len] = 0;
	char *uri = strstr(text, "://") || !strncmp(text, "about:", 6) ? g_strdup(text) : g_strconcat("https://", text, NULL);
	webkit_web_view_load_uri(S.web_view, uri);
	g_free(uri);
	if (siv_node_focus(S.node) != SIV_OK) fprintf(stderr, "spike: cannot focus the page\n");
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_button(void *user_data, siv_node node, const siv_event *e) {
	(void)user_data, (void)e;
	if (node == S.back) webkit_web_view_go_back(S.web_view);
	else if (node == S.forward) webkit_web_view_go_forward(S.web_view);
	else if (node == S.reload) webkit_web_view_reload(S.web_view);
	return SIV_EVENT_RESULT_HANDLED;
}

static void on_title(WebKitWebView *wv, GParamSpec *p, gpointer d) {
	(void)p, (void)d;
	const char *title = webkit_web_view_get_title(wv);
	if (title && *title && siv_window_set_title(S.window, title, strlen(title)) != SIV_OK) fprintf(stderr, "spike: cannot set the title\n");
}

static void on_load_changed(WebKitWebView *wv, WebKitLoadEvent ev, gpointer d) {
	(void)d;
	static const char *names[] = {"started", "redirected", "committed", "finished"};
	fprintf(stderr, "spike: load %s %s at %.1f ms\n", names[ev], webkit_web_view_get_uri(wv), (now_ns() - S.t0) / 1e6);
	if (ev == WEBKIT_LOAD_COMMITTED || ev == WEBKIT_LOAD_FINISHED) set_address(webkit_web_view_get_uri(wv));
}

static gboolean on_term(gpointer data) {
	(void)data;
	g_main_loop_quit(S.loop);
	return G_SOURCE_REMOVE;
}

static siv_result build(void) {
	siv_result r = siv_external_create(S.window, SIV_DESC(siv_external_desc, .release = on_release), &S.slot);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(S.window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(S.window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .height = {SIV_UNIT_FRACTION, 1}));
	if (!getenv("SPIKE_FULL")) {
		siv_node bar = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_ROW, .gap = 6, .align_items = SIV_ALIGN_CENTER));
		siv_set_layout(txn, bar, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .padding = {6, 6, 6, 6}));
		S.back = siv_push_button(txn, bar, SIV_DESC(siv_button_desc, .label = SIV_STR("Back"), .icon = SIV_STR("go-previous-symbolic"), .flags = SIV_WIDGET_ICON_ONLY | SIV_WIDGET_DISABLED));
		S.forward = siv_push_button(txn, bar, SIV_DESC(siv_button_desc, .label = SIV_STR("Forward"), .icon = SIV_STR("go-next-symbolic"), .flags = SIV_WIDGET_ICON_ONLY | SIV_WIDGET_DISABLED));
		S.reload = siv_push_button(txn, bar, SIV_DESC(siv_button_desc, .label = SIV_STR("Reload"), .icon = SIV_STR("view-refresh-symbolic"), .flags = SIV_WIDGET_ICON_ONLY));
		siv_on(txn, S.back, SIV_EVENT_TYPE_ACTIVATE, on_button, NULL, NULL);
		siv_on(txn, S.forward, SIV_EVENT_TYPE_ACTIVATE, on_button, NULL, NULL);
		siv_on(txn, S.reload, SIV_EVENT_TYPE_ACTIVATE, on_button, NULL, NULL);
		S.address = siv_text_field(txn, bar, SIV_DESC(siv_text_field_desc, .placeholder = SIV_STR("Address"), .label = SIV_STR("Address")));
		siv_set_layout(txn, S.address, SIV_DESC(siv_layout_desc, .grow = 1));
		siv_on(txn, S.address, SIV_EVENT_TYPE_KEY, on_address_key, NULL, NULL);
	}
	S.node = siv_external_view(txn, column, SIV_DESC(siv_external_view_desc, .external = S.slot, .fit = SIV_FIT_FILL, .background = {1, 1, 1, 1}));
	siv_set_layout(txn, S.node, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_FRACTION, 1}, .basis = {SIV_UNIT_PX, 0}, .grow = 1));
	siv_set_semantics(txn, S.node, SIV_DESC(siv_semantics_desc, .label = SIV_STR("Web page"), .flags = SIV_SEMANTICS_FOCUSABLE));
	siv_on(txn, S.node, SIV_EVENT_TYPE_POINTER, on_pointer, NULL, NULL);
	siv_on(txn, S.node, SIV_EVENT_TYPE_SCROLL, on_scroll, NULL, NULL);
	siv_on(txn, S.node, SIV_EVENT_TYPE_KEY, on_key, NULL, NULL);
	siv_on(txn, S.node, SIV_EVENT_TYPE_FOCUS, on_focus, NULL, NULL);
	return siv_txn_commit(txn);
}

int main(int argc, char **argv) {
	S.t0 = now_ns();
	const char *url = argc > 1 ? argv[1] : "https://example.com";
	S.log = getenv("SPIKE_LOG") != NULL;
	S.pace_presented = getenv("SPIKE_PACE") && !strcmp(getenv("SPIKE_PACE"), "presented");
	S.awaiting = g_ptr_array_new_with_free_func(g_object_unref);
	S.submit_time = g_hash_table_new(NULL, NULL);
	S.loop = g_main_loop_new(NULL, FALSE);

	siv_result r = siv_app_create(NULL, &S.app);
	if (r == SIV_OK) r = siv_window_create(S.app, SIV_DESC(siv_window_desc, .title = SIV_STR("siv-webview spike"), .app_id = SIV_STR("dev.siv.WebviewSpike"), .on_event = on_window_event, .width = 1280, .height = 800), &S.window);
	if (r == SIV_OK) r = build();
	if (r != SIV_OK) return fprintf(stderr, "spike: %s\n", siv_result_name(r)), 1;

	WPEDisplay *display = g_object_new(siv_display_get_type(), NULL);
	GError *err = NULL;
	if (!wpe_display_connect(display, &err)) return fprintf(stderr, "spike: connect: %s\n", err->message), 1;
	S.web_view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", display, NULL);
	S.view = webkit_web_view_get_wpe_view(S.web_view);
	S.toplevel = wpe_view_get_toplevel(S.view);
	if (!S.toplevel) {
		S.toplevel = wpe_display_create_toplevel(display, 1);
		wpe_view_set_toplevel(S.view, S.toplevel);
	}
	g_signal_connect(S.web_view, "notify::title", G_CALLBACK(on_title), NULL);
	g_signal_connect(S.web_view, "load-changed", G_CALLBACK(on_load_changed), NULL);
	wpe_toplevel_state_changed(S.toplevel, WPE_TOPLEVEL_STATE_ACTIVE);
	wpe_view_map(S.view);
	if (siv_node_focus(S.node) != SIV_OK) fprintf(stderr, "spike: cannot focus the page\n");
	fprintf(stderr, "spike: pid %d\n", getpid());
	webkit_web_view_load_uri(S.web_view, url);

	int fd;
	if (siv_app_get_fd(S.app, &fd) != SIV_OK) return 1;
	g_unix_fd_add(fd, G_IO_IN, on_siv_fd, NULL);
	g_unix_signal_add(SIGTERM, on_term, NULL);
	g_unix_signal_add(SIGINT, on_term, NULL);
	on_siv_fd(fd, G_IO_IN, NULL);
	g_main_loop_run(S.loop);

	fprintf(stderr, "spike: %u frames in %.1f s, at most %u buffers held by siv, %.1f ms held on average\n", S.frames, (now_ns() - S.t0) / 1e9, S.max_in_flight, S.held_n ? S.held_ns / 1e6 / S.held_n : 0.0);
	g_clear_object(&S.web_view);
	siv_app_destroy(S.app);
	return 0;
}
