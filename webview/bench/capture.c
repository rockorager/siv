/* capture: records what the screen shows, frame by frame, through
 * ext-image-copy-capture-v1 on the first output, so that "rows are on
 * screen" is judged from pixels, the same way for every program.
 *
 *   capture OUT
 *
 * Asks for a frame, waits for it (the compositor answers the first at once
 * and each later one when the output next changes), and asks again, until
 * stdin closes. Prints "ready" after the first frame. Writes to OUT:
 *   header  "CAP1", u32 width, u32 height (of the reduced image)
 *   frames  u64 presentation time (CLOCK_MONOTONIC ns), then width*height
 *           bytes: the darkest luma of each 4x4 block of the output, so a
 *           glyph's thin strokes survive the reduction.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

#define POOL 4

static struct wl_shm *shm;
static struct wl_output *output;
static struct ext_output_image_capture_source_manager_v1 *source_mgr;
static struct ext_image_copy_capture_manager_v1 *copy_mgr;
static struct ext_image_copy_capture_session_v1 *session;
static struct wl_buffer *buffer;
static uint8_t *pixels, *reduced;
static uint32_t width, height, format = WL_SHM_FORMAT_XRGB8888, rw, rh;
static int constraints_done, frames;
static uint64_t frame_time;
static FILE *out;

static void global(void *d, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
	(void)d, (void)version;
	if (strcmp(iface, wl_shm_interface.name) == 0) shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	else if (strcmp(iface, wl_output_interface.name) == 0 && !output) output = wl_registry_bind(reg, name, &wl_output_interface, 1);
	else if (strcmp(iface, ext_output_image_capture_source_manager_v1_interface.name) == 0)
		source_mgr = wl_registry_bind(reg, name, &ext_output_image_capture_source_manager_v1_interface, 1);
	else if (strcmp(iface, ext_image_copy_capture_manager_v1_interface.name) == 0)
		copy_mgr = wl_registry_bind(reg, name, &ext_image_copy_capture_manager_v1_interface, 1);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d, (void)r, (void)n; }
static const struct wl_registry_listener reg_listener = {global, global_remove};

static void s_size(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t w, uint32_t h) { (void)d, (void)s, width = w, height = h; }
static void s_shm(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t f) {
	(void)d, (void)s;
	if (f == WL_SHM_FORMAT_XRGB8888 || f == WL_SHM_FORMAT_ARGB8888) format = f;
}
static void s_dev(void *d, struct ext_image_copy_capture_session_v1 *s, struct wl_array *a) { (void)d, (void)s, (void)a; }
static void s_dmabuf(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t f, struct wl_array *m) { (void)d, (void)s, (void)f, (void)m; }
static void s_done(void *d, struct ext_image_copy_capture_session_v1 *s) { (void)d, (void)s, constraints_done = 1; }
static void s_stopped(void *d, struct ext_image_copy_capture_session_v1 *s) {
	(void)d, (void)s;
	fprintf(stderr, "capture: session stopped\n");
	exit(1);
}
static const struct ext_image_copy_capture_session_v1_listener session_listener = {s_size, s_shm, s_dev, s_dmabuf, s_done, s_stopped};

static void request_frame(void);

static void f_transform(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t t) { (void)d, (void)f, (void)t; }
static void f_damage(void *d, struct ext_image_copy_capture_frame_v1 *f, int32_t x, int32_t y, int32_t w, int32_t h) {
	(void)d, (void)f, (void)x, (void)y, (void)w, (void)h;
}
static void f_time(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t hi, uint32_t lo, uint32_t ns) {
	(void)d, (void)f;
	frame_time = (((uint64_t)hi << 32) | lo) * 1000000000u + ns;
}
static void f_ready(void *d, struct ext_image_copy_capture_frame_v1 *f) {
	(void)d;
	ext_image_copy_capture_frame_v1_destroy(f);
	for (uint32_t by = 0; by < rh; by++) {
		for (uint32_t bx = 0; bx < rw; bx++) {
			uint32_t m = 255;
			for (uint32_t y = by * POOL; y < by * POOL + POOL; y++) {
				const uint8_t *p = pixels + (size_t)y * width * 4 + (size_t)bx * POOL * 4;
				for (int x = 0; x < POOL; x++, p += 4) {
					uint32_t l = (p[2] + 2u * p[1] + p[0]) / 4; /* B G R X in memory */
					if (l < m) m = l;
				}
			}
			reduced[by * rw + bx] = (uint8_t)m;
		}
	}
	fwrite(&frame_time, 8, 1, out);
	fwrite(reduced, 1, (size_t)rw * rh, out);
	if (frames++ == 0) {
		fflush(out);
		printf("ready\n");
		fflush(stdout);
	}
	request_frame();
}
static void f_failed(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason) {
	(void)d;
	ext_image_copy_capture_frame_v1_destroy(f);
	if (reason == EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED) exit(1);
	request_frame();
}
static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {f_transform, f_damage, f_time, f_ready, f_failed};

static void request_frame(void) {
	struct ext_image_copy_capture_frame_v1 *f = ext_image_copy_capture_session_v1_create_frame(session);
	ext_image_copy_capture_frame_v1_add_listener(f, &frame_listener, NULL);
	ext_image_copy_capture_frame_v1_attach_buffer(f, buffer);
	ext_image_copy_capture_frame_v1_damage_buffer(f, 0, 0, (int32_t)width, (int32_t)height);
	ext_image_copy_capture_frame_v1_capture(f);
}

int main(int argc, char **argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: capture OUT\n");
		return 2;
	}
	struct wl_display *display = wl_display_connect(NULL);
	if (!display) return fprintf(stderr, "capture: no Wayland display\n"), 1;
	struct wl_registry *reg = wl_display_get_registry(display);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(display);
	if (!shm || !output || !source_mgr || !copy_mgr) return fprintf(stderr, "capture: no ext-image-copy-capture\n"), 1;
	struct ext_image_capture_source_v1 *src = ext_output_image_capture_source_manager_v1_create_source(source_mgr, output);
	session = ext_image_copy_capture_manager_v1_create_session(copy_mgr, src, 0);
	ext_image_copy_capture_session_v1_add_listener(session, &session_listener, NULL);
	while (!constraints_done && wl_display_dispatch(display) >= 0) {}
	size_t size = (size_t)width * height * 4;
	int fd = memfd_create("capture", MFD_CLOEXEC);
	if (ftruncate(fd, (off_t)size) != 0) return 1;
	pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
	buffer = wl_shm_pool_create_buffer(pool, 0, (int32_t)width, (int32_t)height, (int32_t)width * 4, format);
	rw = width / POOL, rh = height / POOL;
	reduced = malloc((size_t)rw * rh);
	out = fopen(argv[1], "wb");
	if (!out) return perror("capture"), 1;
	fwrite("CAP1", 1, 4, out);
	fwrite(&rw, 4, 1, out);
	fwrite(&rh, 4, 1, out);
	request_frame();
	struct pollfd fds[2] = {{wl_display_get_fd(display), POLLIN, 0}, {0, POLLIN, 0}};
	for (;;) {
		while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
		wl_display_flush(display);
		if (poll(fds, 2, -1) < 0) break;
		if (fds[0].revents & POLLIN) wl_display_read_events(display);
		else wl_display_cancel_read(display);
		wl_display_dispatch_pending(display);
		if (fds[1].revents & (POLLIN | POLLHUP)) {
			char buf[64];
			if (read(0, buf, sizeof buf) <= 0) break;
		}
	}
	fclose(out);
	return 0;
}
