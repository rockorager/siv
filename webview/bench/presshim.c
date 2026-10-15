/* presshim: an LD_PRELOAD library that records, for every wl_surface commit
 * of the process, when it was committed and when the compositor presented
 * it (wp_presentation feedback), whatever toolkit or Vulkan driver made the
 * commit. The same instrument measures every program (copied from siv's
 * bench/gpui-compare/harness).
 *
 * It wraps libwayland's request marshalling: the variadic and array entry
 * points C code and Mesa's WSI call through the PLT, and, through dlsym,
 * the ones Rust's wayland-backend looks up after dlopen. Before each
 * commit it requests feedback for that surface on a private event queue,
 * which a thread dispatches every 20 ms (it never reads the socket itself;
 * the application's own reads queue the events).
 *
 * Output (PRESSHIM_LOG; nothing is recorded without it), one record per
 * line, times in CLOCK_MONOTONIC nanoseconds:
 *   A <surface> <t>               attach of a non-null buffer
 *   C <surface> <t> <seq>         commit, with feedback number seq
 *   P <seq> <t> <refresh_ns> <flags>  presented
 *   D <seq>                       discarded
 *   K <xdg_surface> <t>           ack_configure
 *   X <xdg_surface> <surface>     get_xdg_surface
 *   T <xdg_surface>               get_toplevel
 *   O <xdg_surface>               get_popup
 *   Z <clock_id>                  the presentation clock
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <wayland-client-core.h>

#include "presentation-time-client-protocol.h"

typedef struct wl_proxy *(*marshal_array_flags_fn)(struct wl_proxy *, uint32_t, const struct wl_interface *, uint32_t, uint32_t, union wl_argument *);
typedef void (*marshal_array_fn)(struct wl_proxy *, uint32_t, union wl_argument *);
typedef struct wl_proxy *(*marshal_array_ctor_versioned_fn)(struct wl_proxy *, uint32_t, union wl_argument *, const struct wl_interface *, uint32_t);

static void *(*real_dlsym)(void *, const char *);
static marshal_array_flags_fn real_marshal_array_flags;
static marshal_array_fn real_marshal_array;
static marshal_array_ctor_versioned_fn real_marshal_array_ctor_versioned;

static int log_fd = -1;
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
/* Per connection: Mesa's device-select layer opens a connection of its own
 * that never creates surfaces. */
struct conn {
	struct wl_display *display;
	struct wl_event_queue *queue;
	struct wp_presentation *presentation;
};
static struct conn conns[4];
static int conn_count;
static uint64_t next_seq = 1;
static __thread int in_shim;
/* libwayland's own entry points call each other through the PLT, so only
 * the outermost call records. */
static __thread int depth;

static uint64_t now_ns(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static void emit(const char *fmt, ...) {
	char buf[160];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	if (n > 0 && log_fd >= 0) (void)!write(log_fd, buf, (size_t)n);
}

static void resolve(void) {
	if (!real_dlsym) {
		real_dlsym = dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.34");
		if (!real_dlsym) real_dlsym = dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.2.5");
	}
	if (!real_marshal_array_flags) real_marshal_array_flags = (marshal_array_flags_fn)real_dlsym(RTLD_NEXT, "wl_proxy_marshal_array_flags");
	if (!real_marshal_array) real_marshal_array = (marshal_array_fn)real_dlsym(RTLD_NEXT, "wl_proxy_marshal_array");
	if (!real_marshal_array_ctor_versioned)
		real_marshal_array_ctor_versioned = (marshal_array_ctor_versioned_fn)real_dlsym(RTLD_NEXT, "wl_proxy_marshal_array_constructor_versioned");
}

static void init(void) {
	resolve();
	const char *path = getenv("PRESSHIM_LOG");
	if (path && *path) log_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
}

/* Feedback ------------------------------------------------------------------ */

static void answered(void);

static void fb_sync_output(void *data, struct wp_presentation_feedback *fb, struct wl_output *output) {
	(void)data, (void)fb, (void)output;
}

static void fb_presented(void *data, struct wp_presentation_feedback *fb, uint32_t sec_hi, uint32_t sec_lo, uint32_t nsec, uint32_t refresh,
                         uint32_t seq_hi, uint32_t seq_lo, uint32_t flags) {
	(void)seq_hi, (void)seq_lo;
	uint64_t t = (((uint64_t)sec_hi << 32) | sec_lo) * 1000000000u + nsec;
	emit("P %llu %llu %u %u\n", (unsigned long long)(uintptr_t)data, (unsigned long long)t, refresh, flags);
	wp_presentation_feedback_destroy(fb);
	answered();
}

static void fb_discarded(void *data, struct wp_presentation_feedback *fb) {
	emit("D %llu\n", (unsigned long long)(uintptr_t)data);
	wp_presentation_feedback_destroy(fb);
	answered();
}

static const struct wp_presentation_feedback_listener fb_listener = {fb_sync_output, fb_presented, fb_discarded};

static void pres_clock_id(void *data, struct wp_presentation *p, uint32_t clk) {
	(void)data, (void)p;
	emit("Z %u\n", clk);
}

static const struct wp_presentation_listener pres_listener = {pres_clock_id};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
	(void)version;
	struct conn *c = data;
	if (strcmp(iface, wp_presentation_interface.name) == 0) {
		c->presentation = wl_registry_bind(reg, name, &wp_presentation_interface, 1);
		wp_presentation_add_listener(c->presentation, &pres_listener, NULL);
	}
}

static void reg_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
	(void)data, (void)reg, (void)name;
}

static const struct wl_registry_listener reg_listener = {reg_global, reg_global_remove};

/* Feedback requested and not yet answered: the dispatch thread sleeps on
 * the condition while there is none, so an idle application sees no
 * wakeups from the shim. */
static int outstanding;
static pthread_cond_t outstanding_cond = PTHREAD_COND_INITIALIZER;

static void *dispatch_thread(void *arg) {
	(void)arg;
	for (;;) {
		pthread_mutex_lock(&mu);
		while (outstanding == 0) pthread_cond_wait(&outstanding_cond, &mu);
		pthread_mutex_unlock(&mu);
		struct timespec ts = {0, 10 * 1000 * 1000};
		nanosleep(&ts, NULL);
		in_shim = 1;
		pthread_mutex_lock(&mu);
		int n = conn_count;
		pthread_mutex_unlock(&mu);
		for (int i = 0; i < n; i++) wl_display_dispatch_queue_pending(conns[i].display, conns[i].queue);
		in_shim = 0;
	}
	return NULL;
}

static struct conn *find_conn(struct wl_proxy *p) {
	struct wl_display *d = wl_proxy_get_display(p);
	for (int i = 0; i < conn_count; i++)
		if (conns[i].display == d) return &conns[i];
	return NULL;
}

/* Runs on the dispatch thread, which does not hold mu while dispatching. */
static void answered(void) {
	pthread_mutex_lock(&mu);
	if (outstanding > 0) outstanding--;
	pthread_mutex_unlock(&mu);
}

/* Called from a connection's first wl_compositor.create_surface. */
static void bind_presentation(struct wl_proxy *any) {
	if (find_conn(any) || conn_count == 4) return;
	struct conn *c = &conns[conn_count];
	c->display = wl_proxy_get_display(any);
	c->queue = wl_display_create_queue(c->display);
	struct wl_display *wrapper = wl_proxy_create_wrapper(c->display);
	wl_proxy_set_queue((struct wl_proxy *)wrapper, c->queue);
	struct wl_registry *reg = wl_display_get_registry(wrapper);
	wl_proxy_wrapper_destroy(wrapper);
	wl_registry_add_listener(reg, &reg_listener, c);
	wl_display_roundtrip_queue(c->display, c->queue);
	wl_display_roundtrip_queue(c->display, c->queue);
	if (conn_count++ == 0) {
		pthread_t th;
		pthread_create(&th, NULL, dispatch_thread, NULL);
		pthread_detach(th);
	}
}

/* Interception ---------------------------------------------------------------- */

static int is(struct wl_proxy *p, const char *name) {
	const char *c = wl_proxy_get_class(p);
	return c && strcmp(c, name) == 0;
}

/* Before the request goes out. */
static void before(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args) {
	pthread_once(&init_once, init);
	if (log_fd < 0 || in_shim) return;
	in_shim = 1;
	pthread_mutex_lock(&mu);
	if (opcode == 0 && is(proxy, "wl_compositor")) {
		bind_presentation(proxy);
	} else if (is(proxy, "wl_surface")) {
		uint32_t id = wl_proxy_get_id(proxy);
		if (opcode == 1 && args[0].o) {
			emit("A %u %llu\n", id, (unsigned long long)now_ns());
		} else if (opcode == 6) {
			uint64_t seq = next_seq++;
			struct conn *c = find_conn(proxy);
			if (c && c->presentation) {
				struct wp_presentation_feedback *fb = wp_presentation_feedback(c->presentation, (struct wl_surface *)proxy);
				wp_presentation_feedback_add_listener(fb, &fb_listener, (void *)(uintptr_t)seq);
				if (outstanding++ == 0) pthread_cond_signal(&outstanding_cond);
			}
			emit("C %u %llu %llu\n", id, (unsigned long long)now_ns(), (unsigned long long)seq);
		}
	} else if (is(proxy, "xdg_surface")) {
		uint32_t id = wl_proxy_get_id(proxy);
		if (opcode == 4) emit("K %u %llu\n", id, (unsigned long long)now_ns());
		else if (opcode == 1) emit("T %u\n", id);
		else if (opcode == 2) emit("O %u\n", id);
	}
	pthread_mutex_unlock(&mu);
	in_shim = 0;
}

/* After a constructor request: record xdg_surface -> wl_surface. */
static void after(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args, struct wl_proxy *made) {
	if (log_fd < 0 || in_shim || !made) return;
	if (opcode == 2 && is(proxy, "xdg_wm_base") && args[1].o)
		emit("X %u %u\n", wl_proxy_get_id(made), wl_proxy_get_id((struct wl_proxy *)args[1].o));
}

struct wl_proxy *wl_proxy_marshal_array_flags(struct wl_proxy *proxy, uint32_t opcode, const struct wl_interface *interface, uint32_t version, uint32_t flags,
                                              union wl_argument *args) {
	if (depth > 0) return real_marshal_array_flags(proxy, opcode, interface, version, flags, args);
	before(proxy, opcode, args);
	depth++;
	struct wl_proxy *made = real_marshal_array_flags(proxy, opcode, interface, version, flags, args);
	depth--;
	after(proxy, opcode, args, made);
	return made;
}

void wl_proxy_marshal_array(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args) {
	if (depth > 0) return real_marshal_array(proxy, opcode, args);
	before(proxy, opcode, args);
	depth++;
	real_marshal_array(proxy, opcode, args);
	depth--;
}

struct wl_proxy *wl_proxy_marshal_array_constructor_versioned(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args, const struct wl_interface *interface,
                                                              uint32_t version) {
	if (depth > 0) return real_marshal_array_ctor_versioned(proxy, opcode, args, interface, version);
	before(proxy, opcode, args);
	depth++;
	struct wl_proxy *made = real_marshal_array_ctor_versioned(proxy, opcode, args, interface, version);
	depth--;
	after(proxy, opcode, args, made);
	return made;
}

/* libwayland's wl_argument_from_va_list. */
static void args_from_va(const char *sig, union wl_argument *args, int count, va_list ap) {
	int i = 0;
	for (const char *s = sig; *s && i < count; s++) {
		switch (*s) {
		case 'i': args[i++].i = va_arg(ap, int32_t); break;
		case 'u': args[i++].u = va_arg(ap, uint32_t); break;
		case 'f': args[i++].f = va_arg(ap, wl_fixed_t); break;
		case 's': args[i++].s = va_arg(ap, const char *); break;
		case 'o': args[i++].o = va_arg(ap, struct wl_object *); break;
		case 'n': args[i++].o = va_arg(ap, struct wl_object *); break;
		case 'a': args[i++].a = va_arg(ap, struct wl_array *); break;
		case 'h': args[i++].h = va_arg(ap, int32_t); break;
		default: break;
		}
	}
}

#define MAX_ARGS 20

struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *proxy, uint32_t opcode, const struct wl_interface *interface, uint32_t version, uint32_t flags, ...) {
	pthread_once(&init_once, init);
	union wl_argument args[MAX_ARGS];
	memset(args, 0, sizeof args);
	const struct wl_interface *iface = wl_proxy_get_interface(proxy);
	va_list ap;
	va_start(ap, flags);
	args_from_va(iface->methods[opcode].signature, args, MAX_ARGS, ap);
	va_end(ap);
	return wl_proxy_marshal_array_flags(proxy, opcode, interface, version, flags, args);
}

void *dlsym(void *handle, const char *name) {
	pthread_once(&init_once, init);
	if (strcmp(name, "wl_proxy_marshal_array_flags") == 0) return (void *)wl_proxy_marshal_array_flags;
	if (strcmp(name, "wl_proxy_marshal_flags") == 0) return (void *)wl_proxy_marshal_flags;
	if (strcmp(name, "wl_proxy_marshal_array") == 0) return (void *)wl_proxy_marshal_array;
	if (strcmp(name, "wl_proxy_marshal_array_constructor_versioned") == 0) return (void *)wl_proxy_marshal_array_constructor_versioned;
	return real_dlsym(handle, name);
}
