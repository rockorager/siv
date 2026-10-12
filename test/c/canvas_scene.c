/* Canvases drawn from C (D28): paths, fills, strokes, gradients, images,
 * text, clips, layers, transforms, and blend modes, plus a canvas that
 * measures its text. Linked into the headless tests (test/abi/canvas.zig),
 * which present the scene and compare it with golden images. */
#include <siv.h>

#include <math.h>
#include <string.h>

#define PI 3.14159265f

enum { SHAPES, LAYERS, PICTURE, LABEL, BROKEN, CANVASES };

static struct {
	siv_app app;
	siv_window window;
	siv_node nodes[CANVASES];
	siv_node image_node;
	siv_image image;
	int draws[CANVASES];
	int measures;
	float hue;
	char label[64];
	siv_result busy_result;
	siv_result broken_status;
	siv_result picture_status;
	siv_draw stale;
} scene;

static const siv_color ink = {0.09f, 0.09f, 0.11f, 1};

static void shapes(void *user_data, siv_node node, siv_draw d, float w, float h) {
	(void)user_data;
	(void)node;
	scene.draws[SHAPES]++;
	scene.stale = d;
	/* A rounded rectangle with a linear gradient, outlined with a dashed
	 * stroke. */
	siv_gradient_stop stops[] = {{0, {0.15f, 0.39f, 0.92f, 1}}, {1, {scene.hue, 0.73f, 0.51f, 1}}};
	siv_draw_rounded_rect(d, (siv_rect){4, 4, w - 8, h - 8}, (siv_radii){12, 12, 12, 12});
	siv_draw_fill(d, SIV_DESC(siv_paint_desc, .type = SIV_PAINT_TYPE_LINEAR, .stops = stops, .stops_count = 2, .x0 = 0, .y0 = 0, .x1 = w, .y1 = h), SIV_FILL_KEEP_PATH);
	float dashes[] = {6, 3};
	siv_draw_stroke(d, SIV_DESC(siv_stroke_desc, .width = 2, .dashes = dashes, .dashes_count = 2, .join = SIV_LINE_JOIN_ROUND), SIV_DESC(siv_paint_desc, .color = ink));
	/* Three quarters of a ring with round caps and a sweep gradient. */
	siv_draw_arc(d, w / 2, h / 2, w / 4, -PI / 2, PI);
	siv_gradient_stop sweep[] = {{0, {0.98f, 0.6f, 0.1f, 1}}, {1, {0.86f, 0.15f, 0.47f, 1}}};
	siv_draw_stroke(d, SIV_DESC(siv_stroke_desc, .width = 5, .cap = SIV_LINE_CAP_ROUND),
	                SIV_DESC(siv_paint_desc, .type = SIV_PAINT_TYPE_SWEEP, .stops = sweep, .stops_count = 2, .x0 = w / 2, .y0 = h / 2, .start_angle = -PI / 2, .end_angle = PI));
	/* A radial highlight. */
	siv_gradient_stop glow[] = {{0, {1, 1, 1, 0.9f}}, {1, {1, 1, 1, 0}}};
	siv_draw_ellipse(d, (siv_rect){w / 2 - 10, h / 2 - 10, 20, 20});
	siv_draw_fill(d, SIV_DESC(siv_paint_desc, .type = SIV_PAINT_TYPE_RADIAL, .stops = glow, .stops_count = 2, .x0 = w / 2, .y0 = h / 2, .x1 = w / 2, .y1 = h / 2, .r1 = 10), 0);
}

static void layers(void *user_data, siv_node node, siv_draw d, float w, float h) {
	(void)user_data;
	(void)node;
	scene.draws[LAYERS]++;
	/* Changing the tree from a draw callback is refused. */
	siv_txn txn = 0;
	scene.busy_result = siv_txn_begin(scene.window, &txn);
	/* Stripes, rotated about the center, clipped to a circle. */
	siv_draw_ellipse(d, (siv_rect){0, 0, w, h});
	siv_draw_push_clip(d, 0);
	float c = cosf(0.5f), s = sinf(0.5f);
	siv_draw_push_transform(d, (siv_affine){c, s, -s, c, w / 2 - c * w / 2 + s * h / 2, h / 2 - s * w / 2 - c * h / 2});
	for (int i = -2; i < 8; i++) {
		siv_draw_rect(d, (siv_rect){(float)i * 12, -20, 6, h + 40});
	}
	siv_draw_fill(d, SIV_DESC(siv_paint_desc, .color = {0.06f, 0.73f, 0.51f, 1}), 0);
	siv_draw_pop(d);
	/* A translucent group and a multiplied square over it. */
	siv_draw_push_opacity(d, 0.5f);
	siv_draw_rect(d, (siv_rect){10, 10, 40, 40});
	siv_draw_fill(d, SIV_DESC(siv_paint_desc, .color = {0.86f, 0.15f, 0.15f, 1}), 0);
	siv_draw_pop(d);
	siv_draw_push_blend(d, SIV_BLEND_MODE_MULTIPLY);
	siv_draw_rect(d, (siv_rect){30, 30, 40, 40});
	siv_draw_fill(d, SIV_DESC(siv_paint_desc, .color = {1, 0.85f, 0.2f, 1}), 0);
	siv_draw_pop(d);
	/* The clip layer is left open: closed when the callback returns. */
}

static void picture(void *user_data, siv_node node, siv_draw d, float w, float h) {
	(void)user_data;
	(void)node;
	(void)h;
	scene.draws[PICTURE]++;
	siv_draw_image(d, scene.image, (siv_rect){0, 0, 36, 36}, (siv_rect){0}, 1, SIV_IMAGE_NEAREST);
	siv_draw_image(d, scene.image, (siv_rect){w - 36, 0, 36, 36}, (siv_rect){0, 0, 2, 2}, 0.75f, 0);
	siv_draw_text(d, 0, 40, w, "Image", 5, SIV_DESC(siv_text_style_desc, .font_size = 12, .color = ink, .align = SIV_TEXT_ALIGN_CENTER));
	scene.picture_status = siv_draw_status(d);
}

static siv_text_style_desc label_style(void) {
	return (siv_text_style_desc){.size = sizeof(siv_text_style_desc), .font_size = 15, .color = {1, 1, 1, 1}};
}

static siv_size label_measure(void *user_data, siv_node node, const siv_constraints *c) {
	(void)user_data;
	(void)node;
	(void)c;
	scene.measures++;
	siv_text_style_desc style = label_style();
	siv_text_metrics m = {0};
	if (siv_app_measure_text(scene.app, scene.label, strlen(scene.label), 0, &style, &m) != SIV_OK) return (siv_size){0, 0};
	return (siv_size){ceilf(m.width) + 16, ceilf(m.height) + 8};
}

static void label_draw(void *user_data, siv_node node, siv_draw d, float w, float h) {
	(void)user_data;
	(void)node;
	scene.draws[LABEL]++;
	siv_draw_rounded_rect(d, (siv_rect){0, 0, w, h}, (siv_radii){h / 2, h / 2, h / 2, h / 2});
	siv_draw_fill(d, SIV_DESC(siv_paint_desc, .color = ink), 0);
	siv_text_style_desc style = label_style();
	siv_draw_text(d, 8, 4, 0, scene.label, strlen(scene.label), &style);
}

static void broken(void *user_data, siv_node node, siv_draw d, float w, float h) {
	(void)user_data;
	(void)node;
	scene.draws[BROKEN]++;
	siv_draw_rect(d, (siv_rect){0, 0, w, h});
	siv_draw_fill(d, NULL, 0);
	/* An unmatched pop fails the drawing: the canvas shows nothing. */
	siv_draw_pop(d);
	siv_draw_rect(d, (siv_rect){0, 0, w, h});
	siv_draw_fill(d, NULL, 0);
	scene.broken_status = siv_draw_status(d);
}

int canvas_scene_build(siv_app app, siv_window window) {
	memset(&scene, 0, sizeof scene);
	scene.app = app;
	scene.window = window;
	scene.hue = 0.06f;
	strcpy(scene.label, "Label");

	/* A 2x2 checkerboard, rows padded to 12 bytes. */
	const uint8_t px[] = {
		0x25, 0x63, 0xeb, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0,
		0xff, 0xff, 0xff, 0xff, 0xdc, 0x26, 0x26, 0xff, 0, 0, 0, 0,
	};
	siv_result r = siv_image_create(app, SIV_DESC(siv_image_desc, .pixels = px, .pixels_count = sizeof px, .width = 2, .height = 2, .stride = 12), &scene.image);
	if (r != SIV_OK) return r;

	siv_txn txn;
	r = siv_txn_begin(window, &txn);
	if (r != SIV_OK) return r;
	siv_node root = siv_window_root(window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {1, 1, 1, 1}));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 8, .align_items = SIV_ALIGN_START));
	siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {10, 10, 10, 10}));

	siv_node row = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 8));
	scene.nodes[SHAPES] = siv_canvas(txn, row, SIV_DESC(siv_canvas_desc, .draw = shapes, .width = 80, .height = 80));
	scene.nodes[LAYERS] = siv_canvas(txn, row, SIV_DESC(siv_canvas_desc, .draw = layers, .width = 80, .height = 80));
	scene.nodes[PICTURE] = siv_canvas(txn, row, SIV_DESC(siv_canvas_desc, .draw = picture, .width = 80, .height = 60));

	siv_node row2 = siv_flex(txn, column, SIV_DESC(siv_flex_desc, .gap = 8, .align_items = SIV_ALIGN_CENTER));
	scene.nodes[LABEL] = siv_canvas(txn, row2, SIV_DESC(siv_canvas_desc, .draw = label_draw, .measure = label_measure));
	siv_set_semantics(txn, scene.nodes[LABEL], SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_LABEL, .label = "Label", .label_len = 5));
	scene.image_node = siv_image_view(txn, row2, SIV_DESC(siv_image_view_desc, .image = scene.image, .fit = SIV_FIT_CONTAIN, .flags = SIV_IMAGE_NEAREST));
	siv_set_layout(txn, scene.image_node, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 24}, .height = {SIV_UNIT_PX, 24}));
	scene.nodes[BROKEN] = siv_canvas(txn, row2, SIV_DESC(siv_canvas_desc, .draw = broken, .width = 24, .height = 24));
	/* The picture canvas draws the image by handle, so the scene keeps
	 * it; the image node holds a reference of its own. */
	return siv_txn_commit(txn);
}

/* Changes the gradient and redraws only the shapes canvas. */
int canvas_scene_recolor(void) {
	scene.hue = 0.55f;
	siv_txn txn;
	siv_result r = siv_txn_begin(scene.window, &txn);
	if (r != SIV_OK) return r;
	siv_invalidate(txn, scene.nodes[SHAPES]);
	return siv_txn_commit(txn);
}

/* Changes the label's text, which changes its size. */
int canvas_scene_relabel(const char *text) {
	strncpy(scene.label, text, sizeof scene.label - 1);
	siv_txn txn;
	siv_result r = siv_txn_begin(scene.window, &txn);
	if (r != SIV_OK) return r;
	siv_invalidate_size(txn, scene.nodes[LABEL]);
	return siv_txn_commit(txn);
}

int canvas_scene_draws(int which) { return scene.draws[which]; }
int canvas_scene_measures(void) { return scene.measures; }
siv_node canvas_scene_node(int which) { return scene.nodes[which]; }
siv_result canvas_scene_busy_result(void) { return scene.busy_result; }
siv_result canvas_scene_broken_status(void) { return scene.broken_status; }
siv_result canvas_scene_picture_status(void) { return scene.picture_status; }
siv_draw canvas_scene_stale_draw(void) { return scene.stale; }
