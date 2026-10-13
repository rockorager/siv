/* inject: scripted input for the benchmark, as a Wayland client of sway
 * through the virtual keyboard and wlroots virtual pointer protocols, so
 * both toolkits receive identical events through the compositor's seat.
 *
 * Reads commands from stdin, one per line, and answers each with the
 * CLOCK_MONOTONIC time (ns) at which its first event was flushed to the
 * compositor, as "t <ns>", or "ok" for sync:
 *   move X Y                 absolute pointer motion (output coordinates)
 *   press | release          left button
 *   key [ctrl+]CHAR|Return|BackSpace|Escape|Down|Up|Home|End|F3  press and release
 *   wheel N                  N wheel notches (positive: down)
 *   scroll DY                touchpad scroll of DY logical pixels
 *   scrollburst DY HZ COUNT  COUNT touchpad scrolls at HZ, one "t" per event
 *   typeburst MS TEXT        types TEXT, one key every MS ms, one "t" per key
 *   sync                     round trip
 */
#define _GNU_SOURCE
#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *kbd_mgr;
static struct zwlr_virtual_pointer_manager_v1 *ptr_mgr;
static struct zwp_virtual_keyboard_v1 *kbd;
static struct zwlr_virtual_pointer_v1 *ptr;
static struct wl_output *output;
static int out_w = 1280, out_h = 800;

static uint64_t now_ns(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static uint32_t ms(void) { return (uint32_t)(now_ns() / 1000000u); }

static void sleep_until(uint64_t t) {
	struct timespec ts = {(time_t)(t / 1000000000u), (long)(t % 1000000000u)};
	clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
}

static void flushed(void) {
	wl_display_flush(display);
	printf("t %llu\n", (unsigned long long)now_ns());
	fflush(stdout);
}

static void out_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp, const char *make, const char *model, int32_t tr) {
	(void)d, (void)o, (void)x, (void)y, (void)pw, (void)ph, (void)sp, (void)make, (void)model, (void)tr;
}
static void out_mode(void *d, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t r) {
	(void)d, (void)o, (void)r;
	if (flags & WL_OUTPUT_MODE_CURRENT) out_w = w, out_h = h;
}
static void out_done(void *d, struct wl_output *o) { (void)d, (void)o; }
static void out_scale(void *d, struct wl_output *o, int32_t s) { (void)d, (void)o, (void)s; }
static const struct wl_output_listener out_listener = {out_geometry, out_mode, out_done, out_scale, NULL, NULL};

static void global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
	(void)data, (void)version;
	if (strcmp(iface, wl_seat_interface.name) == 0 && !seat) seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
	else if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) kbd_mgr = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
	else if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) ptr_mgr = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
	else if (strcmp(iface, wl_output_interface.name) == 0 && !output) {
		output = wl_registry_bind(reg, name, &wl_output_interface, 2);
		wl_output_add_listener(output, &out_listener, NULL);
	}
}
static void global_remove(void *data, struct wl_registry *reg, uint32_t name) { (void)data, (void)reg, (void)name; }
static const struct wl_registry_listener reg_listener = {global, global_remove};

static void upload_keymap(void) {
	struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_rule_names names = {.layout = "us"};
	struct xkb_keymap *km = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
	char *s = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
	size_t len = strlen(s) + 1;
	int fd = memfd_create("keymap", MFD_CLOEXEC);
	if (ftruncate(fd, (off_t)len) != 0) exit(1);
	void *p = mmap(NULL, len, PROT_WRITE, MAP_SHARED, fd, 0);
	memcpy(p, s, len);
	munmap(p, len);
	zwp_virtual_keyboard_v1_keymap(kbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)len);
	close(fd);
	free(s);
	xkb_keymap_unref(km);
	xkb_context_unref(ctx);
}

/* evdev code and whether Shift is needed. */
static int keycode(const char *name, int *shift) {
	static const char row1[] = "qwertyuiop", row2[] = "asdfghjkl", row3[] = "zxcvbnm";
	*shift = 0;
	if (strcmp(name, "Return") == 0) return KEY_ENTER;
	if (strcmp(name, "BackSpace") == 0) return KEY_BACKSPACE;
	if (strcmp(name, "Escape") == 0) return KEY_ESC;
	if (strcmp(name, "Down") == 0) return KEY_DOWN;
	if (strcmp(name, "Up") == 0) return KEY_UP;
	if (strcmp(name, "space") == 0) return KEY_SPACE;
	if (strcmp(name, "Home") == 0) return KEY_HOME;
	if (strcmp(name, "End") == 0) return KEY_END;
	if (strcmp(name, "F3") == 0) return KEY_F3;
	if (strlen(name) != 1) return -1;
	char c = name[0];
	if (c >= 'A' && c <= 'Z') *shift = 1, c = (char)(c - 'A' + 'a');
	if (c == ' ') return KEY_SPACE;
	if (c == '.') return KEY_DOT;
	if (c == ',') return KEY_COMMA;
	const char *p;
	if ((p = strchr(row1, c))) return KEY_Q + (int)(p - row1);
	if ((p = strchr(row2, c))) return KEY_A + (int)(p - row2);
	if ((p = strchr(row3, c))) return KEY_Z + (int)(p - row3);
	return -1;
}

/* Shift and Control in the keymap's modifier mask. */
static void mods(int shift, int ctrl) {
	zwp_virtual_keyboard_v1_modifiers(kbd, (shift ? 1u : 0u) | (ctrl ? 4u : 0u), 0, 0, 0);
}

/* Presses and releases a key; the reported time is the press's. */
static void key(const char *name) {
	int shift;
	int ctrl = strncmp(name, "ctrl+", 5) == 0;
	if (ctrl) name += 5;
	int code = keycode(name, &shift);
	if (code < 0) {
		printf("error unknown key %s\n", name);
		fflush(stdout);
		return;
	}
	if (shift || ctrl) mods(shift, ctrl);
	zwp_virtual_keyboard_v1_key(kbd, ms(), (uint32_t)code, WL_KEYBOARD_KEY_STATE_PRESSED);
	flushed();
	zwp_virtual_keyboard_v1_key(kbd, ms(), (uint32_t)code, WL_KEYBOARD_KEY_STATE_RELEASED);
	if (shift || ctrl) mods(0, 0);
	wl_display_flush(display);
}

static void scroll(double dy) {
	zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_FINGER);
	zwlr_virtual_pointer_v1_axis(ptr, ms(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_double(dy));
	zwlr_virtual_pointer_v1_frame(ptr);
}

int main(void) {
	display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "inject: no Wayland display\n");
		return 1;
	}
	struct wl_registry *reg = wl_display_get_registry(display);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(display);
	wl_display_roundtrip(display);
	if (!seat || !kbd_mgr || !ptr_mgr) {
		fprintf(stderr, "inject: compositor lacks virtual input protocols\n");
		return 1;
	}
	kbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(kbd_mgr, seat);
	ptr = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(ptr_mgr, seat);
	upload_keymap();
	wl_display_roundtrip(display);
	printf("ready\n");
	fflush(stdout);

	char line[4096];
	while (fgets(line, sizeof line, stdin)) {
		line[strcspn(line, "\n")] = 0;
		char *arg = strchr(line, ' ');
		if (arg) *arg++ = 0;
		if (strcmp(line, "move") == 0) {
			int x = 0, y = 0;
			sscanf(arg, "%d %d", &x, &y);
			zwlr_virtual_pointer_v1_motion_absolute(ptr, ms(), (uint32_t)x, (uint32_t)y, (uint32_t)out_w, (uint32_t)out_h);
			zwlr_virtual_pointer_v1_frame(ptr);
			flushed();
		} else if (strcmp(line, "press") == 0 || strcmp(line, "release") == 0) {
			zwlr_virtual_pointer_v1_button(ptr, ms(), BTN_LEFT, line[0] == 'p' ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
			zwlr_virtual_pointer_v1_frame(ptr);
			flushed();
		} else if (strcmp(line, "key") == 0) {
			key(arg);
		} else if (strcmp(line, "wheel") == 0) {
			int n = atoi(arg);
			zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_WHEEL);
			zwlr_virtual_pointer_v1_axis_discrete(ptr, ms(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(15 * n), n);
			zwlr_virtual_pointer_v1_frame(ptr);
			flushed();
		} else if (strcmp(line, "scroll") == 0) {
			scroll(atof(arg));
			flushed();
		} else if (strcmp(line, "scrollburst") == 0) {
			double dy = 0, hz = 120;
			int count = 0;
			sscanf(arg, "%lf %lf %d", &dy, &hz, &count);
			uint64_t period = (uint64_t)(1e9 / hz), t = now_ns();
			for (int i = 0; i < count; i++, t += period) {
				sleep_until(t);
				scroll(dy);
				flushed();
			}
		} else if (strcmp(line, "typeburst") == 0) {
			int interval = atoi(arg);
			char *text = strchr(arg, ' ');
			if (!text) continue;
			text++;
			uint64_t period = (uint64_t)interval * 1000000u, t = now_ns();
			for (char *c = text; *c; c++, t += period) {
				char name[2] = {*c, 0};
				sleep_until(t);
				key(name);
			}
		} else if (strcmp(line, "sync") == 0) {
			wl_display_roundtrip(display);
			printf("ok\n");
			fflush(stdout);
		}
	}
	return 0;
}
