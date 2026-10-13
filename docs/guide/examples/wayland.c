/* Extending a siv window with a Wayland protocol siv does not support
 * itself: content-type-v1 tells the compositor that the window shows
 * video, so that it may pick a matching display mode (D17, D27). It is
 * bound on siv's own connection, through an event queue of its own.
 *
 *     zig build guide && ./zig-out/bin/guide-wayland
 */
#include <siv.h>

#include <stdio.h>
#include <string.h>
#include <wayland-client.h>

#include "content-type-v1-client-protocol.h"


struct player {
	siv_window window;
	struct wl_event_queue *queue;
	struct wp_content_type_manager_v1 *manager;
	struct wp_content_type_v1 *content_type;
};

static void on_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
	(void)version;
	struct player *p = data;
	if (strcmp(interface, wp_content_type_manager_v1_interface.name) == 0)
		p->manager = wl_registry_bind(registry, name, &wp_content_type_manager_v1_interface, 1);
}

static void on_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
	(void)data, (void)registry, (void)name;
}

static const struct wl_registry_listener registry_listener = {on_global, on_global_remove};

/* siv's compositor thread dispatches the connection's default queue, so
 * the registry goes on a queue of our own, through a proxy wrapper of the
 * display, and only that queue is round-tripped. */
static void bind_globals(struct player *p, struct wl_display *display) {
	p->queue = wl_display_create_queue(display);
	struct wl_display *wrapper = wl_proxy_create_wrapper(display);
	wl_proxy_set_queue((struct wl_proxy *)wrapper, p->queue);
	struct wl_registry *registry = wl_display_get_registry(wrapper);
	wl_proxy_wrapper_destroy(wrapper);
	wl_registry_add_listener(registry, &registry_listener, p);
	wl_display_roundtrip_queue(display, p->queue);
	wl_registry_destroy(registry);
}

/* Extra double-buffered state on siv's surface, never a commit of our
 * own: siv's next commit of the window applies it. */
static const char *mark_as_video(struct player *p, siv_app app) {
	void *display = NULL, *surface = NULL;
	if (siv_app_get_wayland(app, &display) != SIV_OK || display == NULL) return "No Wayland compositor to tell";
	if (siv_window_get_wayland(p->window, &surface, NULL) != SIV_OK) return "No surface";
	bind_globals(p, display);
	if (p->manager == NULL) return "The compositor has no content types";
	p->content_type = wp_content_type_manager_v1_get_surface_content_type(p->manager, surface);
	wp_content_type_v1_set_content_type(p->content_type, WP_CONTENT_TYPE_V1_TYPE_VIDEO);
	if (siv_window_request_commit(p->window) != SIV_OK) return "No commit";
	return "Told the compositor: video";
}

/* Objects on siv's surface go before the window does. */
static void unbind(struct player *p) {
	if (p->content_type) wp_content_type_v1_destroy(p->content_type);
	if (p->manager) wp_content_type_manager_v1_destroy(p->manager);
	if (p->queue) wl_event_queue_destroy(p->queue);
	p->content_type = NULL;
	p->manager = NULL;
	p->queue = NULL;
}

static bool on_window_event(void *user_data, siv_window window, const siv_window_event *event) {
	(void)window;
	if (event->type == SIV_WINDOW_EVENT_TYPE_CLOSE_REQUESTED) unbind(user_data);
	return false;
}

int main(void) {
	struct player p = {0};
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "wayland: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Player"), .width = 320, .height = 120, .on_event = on_window_event, .user_data = &p), &p.window);
	const char *status = r == SIV_OK ? mark_as_video(&p, app) : "";
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(p.window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_get_root(p.window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
		siv_node text = siv_text(txn, root, status, strlen(status));
		siv_set_layout(txn, text, SIV_DESC(siv_layout_desc, .align_x = SIV_ALIGN_CENTER, .align_y = SIV_ALIGN_CENTER));
		siv_set_text_style(txn, text, SIV_DESC(siv_text_style_desc, .size_role = SIV_SIZE_ROLE_HEADING, .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
		r = siv_txn_commit(txn);
	}
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "wayland: %s\n", siv_result_name(r));
	unbind(&p);
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
