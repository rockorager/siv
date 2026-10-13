/* Images and icons: a file decoded on a worker thread at the size it is
 * shown, pixels the application makes, and themed icons by name.
 *
 *     zig build guide && ./zig-out/bin/guide-images   (from the repository root)
 */
#include <siv.h>

#include <stdio.h>
#include <string.h>


/* Commits a transaction made in a handler. There is nothing to undo when
 * one fails (siv discarded it), so report it and go on. */
static void commit(siv_txn txn) {
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "siv_txn_commit: %s\n", siv_result_name(r));
}

struct gallery {
	siv_window window;
	siv_node photo;
	siv_node caption;
};

/* Runs on the application's thread once the file is decoded. The image
 * node takes its own reference, so the handle can go at once. */
static void on_loaded(void *user_data, siv_result result, siv_image image) {
	struct gallery *g = user_data;
	char text[64];
	siv_size size = {0};
	if (result == SIV_OK) result = siv_image_get_size(image, &size);
	if (result == SIV_OK) snprintf(text, sizeof text, "landscape.png, %.0f × %.0f", size.width, size.height);
	else snprintf(text, sizeof text, "Cannot load landscape.png: %s", siv_result_name(result));
	siv_txn txn;
	if (siv_txn_begin(g->window, &txn) == SIV_OK) {
		if (result == SIV_OK) siv_set_image_view(txn, g->photo, SIV_DESC(siv_image_view_desc, .image = image, .fit = SIV_FIT_COVER));
		siv_set_text(txn, g->caption, text, strlen(text));
		commit(txn);
	}
	if (result == SIV_OK) siv_image_destroy(image);
}

/* An 8 × 8 checkerboard, drawn scaled up without smoothing. */
static siv_image checkerboard(siv_app app) {
	uint8_t pixels[8 * 8 * 4];
	for (int y = 0; y < 8; y++)
		for (int x = 0; x < 8; x++) {
			uint8_t v = (x + y) % 2 ? 0x2b : 0xe2;
			uint8_t *p = &pixels[(y * 8 + x) * 4];
			p[0] = v, p[1] = v, p[2] = (uint8_t)(v + 0x10), p[3] = 0xff;
		}
	siv_image image = 0;
	siv_result r = siv_image_create(app, SIV_DESC(siv_image_desc, .pixels = pixels, .pixels_count = sizeof pixels, .width = 8, .height = 8), &image);
	if (r != SIV_OK) fprintf(stderr, "images: %s\n", siv_result_name(r));
	return image;
}

static void icon(siv_txn txn, siv_node parent, const char *name, siv_color_token color) {
	siv_image_view(txn, parent, SIV_DESC(siv_image_view_desc, .icon = name, strlen(name), .icon_size = 32, .color_token = color));
}

static siv_result build(struct gallery *g, siv_app app) {
	siv_txn txn;
	siv_result r = siv_txn_begin(g->window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_get_root(g->window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 12, .align_items = SIV_ALIGN_START));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {20, 20, 16, 16}));

	/* Empty until the file arrives; its size keeps its place meanwhile.
	 * A frame that clips its children to its rounded corners rounds the
	 * photo. */
	siv_node frame = siv_box(txn, column);
	siv_set_visual(txn, frame, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_VIEW_BG, .radius = {10, 10, 10, 10}, .flags = SIV_VISUAL_CLIP));
	g->photo = siv_image_view(txn, frame, NULL);
	siv_set_layout(txn, g->photo, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 240}, .height = {SIV_UNIT_PX, 150}));
	siv_set_semantics(txn, g->photo, SIV_DESC(siv_semantics_desc, .label = SIV_STR("Hills at sunset")));
	g->caption = siv_text(txn, column, SIV_STR("Loading…"));
	siv_set_text_style(txn, g->caption, SIV_DESC(siv_text_style_desc, .size_role = SIV_SIZE_ROLE_CAPTION, .color_token = SIV_COLOR_TOKEN_MUTED_FG));

	siv_node row = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 16, .align_items = SIV_ALIGN_CENTER));
	siv_image board = checkerboard(app);
	siv_node pixels = siv_image_view(txn, row, SIV_DESC(siv_image_view_desc, .image = board, .flags = SIV_IMAGE_NEAREST));
	siv_set_layout(txn, pixels, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 48}, .height = {SIV_UNIT_PX, 48}));
	siv_set_semantics(txn, pixels, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_NONE));
	siv_image_destroy(board);

	/* Themed icons by name: the node follows the desktop's icon theme
	 * and loads the icon on a worker thread. Symbolic icons take a
	 * color. */
	icon(txn, row, "folder", SIV_COLOR_TOKEN_NONE);
	icon(txn, row, "document-new", SIV_COLOR_TOKEN_NONE);
	icon(txn, row, "emblem-ok-symbolic", SIV_COLOR_TOKEN_SUCCESS);
	icon(txn, row, "dialog-warning-symbolic", SIV_COLOR_TOKEN_WARNING);
	siv_push_button(txn, column, SIV_DESC(siv_button_desc, .label = SIV_STR("Copy"), .icon = SIV_STR("edit-copy-symbolic")));
	r = siv_txn_commit(txn);
	if (r != SIV_OK) return r;

	/* Decoded straight to the size it is shown at, in device pixels. The
	 * request could cancel the load or change its priority. */
	double scale = 1;
	if (siv_window_get_scale(g->window, &scale) != SIV_OK) scale = 1;
	siv_image_request request;
	return siv_image_load(app, SIV_DESC(siv_image_load_desc, .path = SIV_STR("docs/guide/examples/data/landscape.png"), .max_width = 240, .max_height = 150, .scale = (float)scale), on_loaded, NULL, g, &request);
}

int main(void) {
	struct gallery g = {0};
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "images: %s\n", siv_result_name(r));
		return 1;
	}
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Images"), .width = 300, .height = 340), &g.window);
	if (r == SIV_OK) r = build(&g, app);
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "images: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
