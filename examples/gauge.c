/* A custom widget on a canvas: a dial that shows a value as an arc with a
 * gradient and a centered label, and changes it by dragging or with the
 * arrow keys. Only the canvas redraws when the value changes.
 *
 *     zig build examples && ./zig-out/bin/gauge
 */
#include <siv.h>

#include <math.h>
#include <stdio.h>

#define PI 3.14159265f

struct gauge {
	siv_window window;
	siv_node canvas;
	float value; /* 0 to 1 */
	bool dragging;
};

static void draw_gauge(void *user_data, siv_node node, siv_draw d, float w, float h) {
	(void)node;
	struct gauge *g = user_data;
	float cx = w / 2, cy = h / 2, r = fminf(w, h) / 2 - 12;
	float start = 0.75f * PI, sweep = 1.5f * PI;

	/* The track. */
	siv_draw_arc(d, cx, cy, r, start, start + sweep);
	siv_draw_stroke(d, SIV_DESC(siv_stroke_desc, .width = 14, .cap = SIV_LINE_CAP_ROUND), SIV_DESC(siv_paint_desc, .color = {0.89f, 0.89f, 0.91f, 1}));
	/* The value, with a sweep gradient around the dial. */
	if (g->value > 0) {
		siv_gradient_stop stops[] = {{0, {0.15f, 0.39f, 0.92f, 1}}, {1, {0.86f, 0.15f, 0.47f, 1}}};
		siv_draw_arc(d, cx, cy, r, start, start + sweep * g->value);
		siv_draw_stroke(d, SIV_DESC(siv_stroke_desc, .width = 14, .cap = SIV_LINE_CAP_ROUND),
		                SIV_DESC(siv_paint_desc, .type = SIV_PAINT_TYPE_SWEEP, .stops = stops, .stops_count = 2, .x0 = cx, .y0 = cy, .start_angle = start, .end_angle = start + sweep));
	}
	char label[8];
	int n = snprintf(label, sizeof label, "%d%%", (int)lroundf(g->value * 100));
	siv_draw_text(d, 0, cy - 18, w, label, (size_t)n, SIV_DESC(siv_text_style_desc, .font_size = 28, .weight = SIV_FONT_WEIGHT_SEMIBOLD, .align = SIV_TEXT_ALIGN_CENTER));
}

static void set_value(struct gauge *g, float v) {
	v = fminf(1, fmaxf(0, v));
	if (v == g->value) return;
	g->value = v;
	siv_txn txn;
	if (siv_txn_begin(g->window, &txn) != SIV_OK) return;
	siv_set_semantics(txn, g->canvas, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_SLIDER, .label = "Volume", .label_len = 6, .flags = SIV_SEMANTICS_FOCUSABLE | SIV_SEMANTICS_HAS_VALUE, .value_max = 1, .value_now = v));
	siv_invalidate(txn, g->canvas);
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "gauge: %s\n", siv_result_name(r));
}

/* The angle of the pointer around the center sets the value. */
static bool on_pointer(void *user_data, siv_node node, const siv_event *e) {
	struct gauge *g = user_data;
	if (e->phase == SIV_POINTER_PHASE_DOWN) g->dragging = true;
	if (e->phase == SIV_POINTER_PHASE_UP || e->phase == SIV_POINTER_PHASE_CANCEL) g->dragging = false;
	if (!g->dragging) return false;
	siv_rect box;
	if (siv_node_get_rect(node, &box) != SIV_OK) return false;
	float a = atan2f(e->y - box.height / 2, e->x - box.width / 2) - 0.75f * PI;
	while (a < 0) a += 2 * PI;
	if (a > 1.5f * PI) a = a > 1.75f * PI ? 0 : 1.5f * PI;
	set_value(g, a / (1.5f * PI));
	return true;
}

static bool on_key(void *user_data, siv_node node, const siv_event *e) {
	(void)node;
	struct gauge *g = user_data;
	if (!(e->flags & SIV_EVENT_PRESSED)) return false;
	if (e->keysym == SIV_KEY_LEFT) set_value(g, g->value - 0.05f);
	else if (e->keysym == SIV_KEY_RIGHT) set_value(g, g->value + 0.05f);
	else return false;
	return true;
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	struct gauge g = {.value = 0};
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = "Gauge", .title_len = 5, .width = 260, .height = 260), &g.window);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(g.window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(g.window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {1, 1, 1, 1}));
		siv_set_stack(txn, root, SIV_DESC(siv_stack_desc, .align_x = SIV_ALIGN_CENTER, .align_y = SIV_ALIGN_CENTER));
		g.canvas = siv_canvas(txn, root, SIV_DESC(siv_canvas_desc, .draw = draw_gauge, .user_data = &g, .width = 220, .height = 220));
		siv_on(txn, g.canvas, SIV_EVENT_TYPE_POINTER, on_pointer, NULL, &g);
		siv_on(txn, g.canvas, SIV_EVENT_TYPE_KEY, on_key, NULL, &g);
		r = siv_txn_commit(txn);
	}
	if (r == SIV_OK) {
		set_value(&g, 0.4f);
		r = siv_node_focus(g.canvas);
	}
	if (r == SIV_OK) r = siv_run(app);
	if (r != SIV_OK) fprintf(stderr, "gauge: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
