/* A custom widget on a canvas: a dial that shows a value as an arc with a
 * gradient and a centered label, and changes it by dragging, with the
 * arrow keys, or from assistive technology. Only the canvas redraws when
 * the value changes.
 *
 * It is a widget like the stock ones (D22): its behavior is in default
 * handlers, it reports the user's changes with SIV_EVENT_CHANGE, and its
 * widget interface (siv_set_widget) makes siv_widget_set_value,
 * siv_widget_get_value, siv_widget_set_label, and siv_widget_set_disabled
 * work on it as on a slider.
 *
 *     zig build examples && ./zig-out/bin/gauge
 */
#include <siv.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

#define PI 3.14159265f

struct gauge {
	siv_window window;
	siv_node canvas;
	float value; /* 0 to 1 */
	bool dragging;
	bool disabled;
	char label[64];
	size_t label_len;
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

/* Shows the state in the caller's transaction: what assistive technology
 * sees, and a redraw. */
static void apply(siv_txn txn, struct gauge *g) {
	siv_semantics_flags flags = SIV_SEMANTICS_HAS_VALUE | (g->disabled ? SIV_SEMANTICS_DISABLED : SIV_SEMANTICS_FOCUSABLE);
	siv_set_semantics(txn, g->canvas, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_SLIDER, .label = g->label, .label_len = g->label_len, .flags = flags, .value_max = 1, .value_step = 0.05, .value_now = g->value));
	siv_invalidate(txn, g->canvas);
}

static float clamp01(double v) {
	return (float)fmin(1, fmax(0, v));
}

/* The widget interface: what the generic siv_widget_* calls do on the dial.
 * They run inside the caller's transaction and report no change event. */
static void widget_set_value(void *user_data, siv_txn txn, siv_node node, double value) {
	(void)node;
	struct gauge *g = user_data;
	g->value = clamp01(value);
	apply(txn, g);
}

static double widget_get_value(void *user_data, siv_node node) {
	(void)node;
	struct gauge *g = user_data;
	return g->value;
}

static void widget_set_label(void *user_data, siv_txn txn, siv_node node, const char *text, size_t len) {
	(void)node;
	struct gauge *g = user_data;
	if (len > sizeof g->label) {
		siv_txn_fail(txn, SIV_ERROR_INVALID_ARGUMENT);
		return;
	}
	memcpy(g->label, text, len);
	g->label_len = len;
	apply(txn, g);
}

static void widget_set_disabled(void *user_data, siv_txn txn, siv_node node, bool disabled) {
	(void)node;
	struct gauge *g = user_data;
	g->disabled = disabled;
	g->dragging = false;
	apply(txn, g);
}

/* The user changed the value: commit it in a transaction of the widget's
 * own, then report it, as stock widgets do. */
static void user_set(struct gauge *g, float v) {
	v = clamp01(v);
	if (v == g->value || g->disabled) return;
	siv_txn txn;
	if (siv_txn_begin(g->window, &txn) != SIV_OK) return;
	g->value = v;
	apply(txn, g);
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) {
		fprintf(stderr, "gauge: %s\n", siv_result_name(r));
		return;
	}
	bool handled;
	(void)siv_node_emit(g->canvas, SIV_DESC(siv_event, .type = SIV_EVENT_TYPE_CHANGE, .value = v), &handled);
}

/* The angle of the pointer around the center sets the value. */
static siv_event_result on_pointer(void *user_data, siv_node node, const siv_event *e) {
	struct gauge *g = user_data;
	if (e->phase == SIV_POINTER_PHASE_DOWN && !g->disabled) g->dragging = true;
	if (e->phase == SIV_POINTER_PHASE_UP || e->phase == SIV_POINTER_PHASE_CANCEL) g->dragging = false;
	if (!g->dragging) return SIV_EVENT_RESULT_PASS;
	siv_rect box;
	if (siv_node_get_rect(node, &box) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	float a = atan2f(e->y - box.height / 2, e->x - box.width / 2) - 0.75f * PI;
	while (a < 0) a += 2 * PI;
	if (a > 1.5f * PI) a = a > 1.75f * PI ? 0 : 1.5f * PI;
	user_set(g, a / (1.5f * PI));
	return SIV_EVENT_RESULT_HANDLED;
}

static siv_event_result on_key(void *user_data, siv_node node, const siv_event *e) {
	(void)node;
	struct gauge *g = user_data;
	if (!(e->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
	if (e->keysym == SIV_KEY_LEFT) user_set(g, g->value - 0.05f);
	else if (e->keysym == SIV_KEY_RIGHT) user_set(g, g->value + 0.05f);
	else return SIV_EVENT_RESULT_PASS;
	return SIV_EVENT_RESULT_HANDLED;
}

/* Assistive technology sets the value through AT-SPI's Value interface. */
static siv_event_result on_set_value(void *user_data, siv_node node, const siv_event *e) {
	(void)node;
	user_set(user_data, (float)e->value);
	return SIV_EVENT_RESULT_HANDLED;
}

/* Builds the dial under parent: a widget the generic calls drive. */
static siv_node gauge(siv_txn txn, siv_node parent, struct gauge *g) {
	g->canvas = siv_canvas(txn, parent, SIV_DESC(siv_canvas_desc, .draw = draw_gauge, .user_data = g, .width = 220, .height = 220));
	/* Behavior goes in the default slots, so the application's siv_on
	 * handlers can override it (D22). */
	siv_on_default(txn, g->canvas, SIV_EVENT_TYPE_POINTER, on_pointer, NULL, g);
	siv_on_default(txn, g->canvas, SIV_EVENT_TYPE_KEY, on_key, NULL, g);
	siv_on_default(txn, g->canvas, SIV_EVENT_TYPE_SET_VALUE, on_set_value, NULL, g);
	siv_set_widget(txn, g->canvas, SIV_DESC(siv_widget_desc, .user_data = g, .set_value = widget_set_value, .get_value = widget_get_value, .set_label = widget_set_label, .set_disabled = widget_set_disabled));
	apply(txn, g);
	return g->canvas;
}

/* The application hears the user's changes as from any stock widget. */
static siv_event_result on_change(void *user_data, siv_node node, const siv_event *e) {
	(void)node;
	struct gauge *g = user_data;
	char title[32];
	int n = snprintf(title, sizeof title, "Gauge: %d%%", (int)lround(e->value * 100));
	siv_result r = siv_window_set_title(g->window, title, (size_t)n);
	if (r != SIV_OK) fprintf(stderr, "gauge: %s\n", siv_result_name(r));
	return SIV_EVENT_RESULT_HANDLED;
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	struct gauge g = {0};
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = "Gauge", .title_len = 5, .width = 260, .height = 260), &g.window);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(g.window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_root(g.window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {1, 1, 1, 1}));
		siv_set_stack(txn, root, SIV_DESC(siv_stack_desc, .align_x = SIV_ALIGN_CENTER, .align_y = SIV_ALIGN_CENTER));
		siv_node dial = gauge(txn, root, &g);
		/* From here on it is driven like any stock widget. */
		siv_widget_set_label(txn, dial, "Volume", 6);
		siv_widget_set_value(txn, dial, 0.4);
		siv_on(txn, dial, SIV_EVENT_TYPE_CHANGE, on_change, NULL, &g);
		r = siv_txn_commit(txn);
	}
	if (r == SIV_OK) r = siv_node_focus(g.canvas);
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "gauge: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
