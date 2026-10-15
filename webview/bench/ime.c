/* A test input method (input-method-unstable-v2): reports what the
 * focused text field tells it and composes on command.
 *
 *     ime < commands
 *
 * Commands, one per line:
 *     preedit TEXT      show TEXT as the composition (cursor at its end)
 *     commit TEXT       commit TEXT, ending the composition
 * It prints "activate", "deactivate", "surrounding <text> cursor anchor",
 * "content hint purpose", and "cursor-rect x y w h" (from the popup
 * surface's text_input_rectangle) as the client sends them. */
#define _GNU_SOURCE
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

#include "input-method-unstable-v2-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_input_method_manager_v2 *manager;
static struct zwp_input_method_v2 *im;
static struct wl_compositor *compositor;
static uint32_t serial;
static int active;

static void registry_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
	(void)data, (void)version;
	if (!strcmp(iface, wl_seat_interface.name) && !seat) seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
	else if (!strcmp(iface, wl_compositor_interface.name)) compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	else if (!strcmp(iface, zwp_input_method_manager_v2_interface.name)) manager = wl_registry_bind(reg, name, &zwp_input_method_manager_v2_interface, 1);
}
static void registry_remove(void *data, struct wl_registry *reg, uint32_t name) { (void)data, (void)reg, (void)name; }
static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};

static int pending_active = -1;

static void im_activate(void *d, struct zwp_input_method_v2 *m) { (void)d, (void)m; pending_active = 1; }
static void im_deactivate(void *d, struct zwp_input_method_v2 *m) { (void)d, (void)m; pending_active = 0; }
static void im_surrounding(void *d, struct zwp_input_method_v2 *m, const char *text, uint32_t cursor, uint32_t anchor) {
	(void)d, (void)m;
	printf("surrounding \"%s\" %u %u\n", text, cursor, anchor);
}
static void im_change_cause(void *d, struct zwp_input_method_v2 *m, uint32_t cause) { (void)d, (void)m, (void)cause; }
static void im_content_type(void *d, struct zwp_input_method_v2 *m, uint32_t hint, uint32_t purpose) {
	(void)d, (void)m;
	printf("content %u %u\n", hint, purpose);
}
static void im_done(void *d, struct zwp_input_method_v2 *m) {
	(void)d, (void)m;
	serial++;
	if (pending_active >= 0) {
		active = pending_active;
		printf("%s\n", active ? "activate" : "deactivate");
		pending_active = -1;
	}
	fflush(stdout);
}
static void im_unavailable(void *d, struct zwp_input_method_v2 *m) {
	(void)d, (void)m;
	printf("unavailable (another input method is running)\n");
	exit(1);
}
static const struct zwp_input_method_v2_listener im_listener = {im_activate, im_deactivate, im_surrounding, im_change_cause, im_content_type, im_done, im_unavailable};

static void popup_rect(void *d, struct zwp_input_popup_surface_v2 *p, int32_t x, int32_t y, int32_t w, int32_t h) {
	(void)d, (void)p;
	printf("cursor-rect %d %d %d %d\n", x, y, w, h);
	fflush(stdout);
}
static const struct zwp_input_popup_surface_v2_listener popup_listener = {popup_rect};

int main(void) {
	struct wl_display *display = wl_display_connect(NULL);
	if (!display) return fprintf(stderr, "ime: no display\n"), 1;
	struct wl_registry *reg = wl_display_get_registry(display);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_roundtrip(display);
	if (!seat || !manager) return fprintf(stderr, "ime: no zwp_input_method_manager_v2\n"), 1;
	im = zwp_input_method_manager_v2_get_input_method(manager, seat);
	zwp_input_method_v2_add_listener(im, &im_listener, NULL);
	/* A popup surface reports the text cursor's rectangle (shown only
	 * once it has a buffer; the rectangle comes without one). */
	if (compositor) {
		struct wl_surface *s = wl_compositor_create_surface(compositor);
		struct zwp_input_popup_surface_v2 *p = zwp_input_method_v2_get_input_popup_surface(im, s);
		zwp_input_popup_surface_v2_add_listener(p, &popup_listener, NULL);
	}
	wl_display_roundtrip(display);
	printf("ready\n");
	fflush(stdout);

	char line[4096];
	struct pollfd fds[2] = {{.fd = wl_display_get_fd(display), .events = POLLIN}, {.fd = 0, .events = POLLIN}};
	for (;;) {
		wl_display_flush(display);
		if (poll(fds, 2, -1) < 0) break;
		if (fds[0].revents & POLLIN) {
			if (wl_display_dispatch(display) < 0) break;
		}
		if (fds[1].revents & (POLLIN | POLLHUP)) {
			if (!fgets(line, sizeof line, stdin)) break;
			line[strcspn(line, "\n")] = 0;
			char *arg = strchr(line, ' ');
			if (arg) *arg++ = 0;
			else arg = "";
			if (!strcmp(line, "preedit")) {
				zwp_input_method_v2_set_preedit_string(im, arg, (int32_t)strlen(arg), (int32_t)strlen(arg));
				zwp_input_method_v2_commit(im, serial);
			} else if (!strcmp(line, "commit")) {
				zwp_input_method_v2_set_preedit_string(im, "", 0, 0);
				zwp_input_method_v2_commit_string(im, arg);
				zwp_input_method_v2_commit(im, serial);
			}
			printf("sent %s %s (active %d)\n", line, arg, active);
			fflush(stdout);
		}
	}
	return 0;
}
