/* A custom widget built from primitives, the way siv's stock widgets are:
 * a segmented control (one of a few options, side by side). Its behavior
 * is in default handlers, so the application's own siv_on handlers stay
 * free and can override it; its state is node data; it reports changes
 * with siv_node_emit; it answers the generic siv_widget_* calls through a
 * widget interface; and it tells assistive technology what it is.
 *
 *     zig build guide && ./zig-out/bin/guide-segmented
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

/* A node's neighbor, or 0. */
static siv_node related(siv_node node, siv_relation which) {
	return siv_node_get_related(node, which);
}

/* The widget ---------------------------------------------------------- */

/* State lives with the widget's root node: node data under a key of the
 * widget's own, freed with the node. */
static char segmented_key;

struct segmented {
	siv_node root;
	uint32_t count;
	int32_t selected;
};

static siv_node segment_at(siv_node root, int32_t index) {
	siv_node node = related(root, SIV_RELATION_FIRST_CHILD);
	for (int32_t i = 0; node && i < index; i++) node = related(node, SIV_RELATION_NEXT);
	return node;
}

/* Restyles every segment for the selection. Only the selected segment is
 * focusable (roving focus), so the control is one Tab stop. */
static void restyle(siv_txn txn, struct segmented *s) {
	siv_node seg = segment_at(s->root, 0);
	for (int32_t i = 0; seg; i++) {
		bool on = i == s->selected;
		siv_set_visual(txn, seg, SIV_DESC(siv_visual_desc, .background_token = on ? SIV_COLOR_TOKEN_ACCENT : SIV_COLOR_TOKEN_CONTROL_BG, .radius = {6, 6, 6, 6}));
		siv_set_text_style(txn, related(seg, SIV_RELATION_FIRST_CHILD), SIV_DESC(siv_text_style_desc, .color_token = on ? SIV_COLOR_TOKEN_ACCENT_FG : SIV_COLOR_TOKEN_CONTROL_FG));
		siv_set_semantics(txn, seg, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_RADIO, .checked = on ? SIV_TOGGLE_ON : SIV_TOGGLE_OFF, .position = (uint32_t)i + 1, .set_size = s->count, .flags = on ? SIV_SEMANTICS_FOCUSABLE : 0));
		seg = related(seg, SIV_RELATION_NEXT);
	}
}

/* Selects an option as the user did: restyles, moves focus along, and
 * reports SIV_EVENT_CHANGE to the root's handlers. A screen reader
 * chooses an option by activating it, as a click does. */
static void choose(siv_window window, struct segmented *s, int32_t index) {
	if (index < 0 || (uint32_t)index >= s->count || index == s->selected) return;
	siv_txn txn;
	if (siv_txn_begin(window, &txn) != SIV_OK) return;
	s->selected = index;
	restyle(txn, s);
	if (siv_txn_commit(txn) != SIV_OK) return;
	if (siv_node_focus(segment_at(s->root, index)) != SIV_OK) return;
	siv_event change = {.size = sizeof change, .type = SIV_EVENT_TYPE_CHANGE, .value = index, .index = (uint32_t)index, .target = s->root};
	bool handled;
	if (siv_node_emit(s->root, &change, &handled) != SIV_OK) fprintf(stderr, "segmented: cannot report the change\n");
}

static siv_event_result segment_activate(void *user_data, siv_node seg, const siv_event *event) {
	struct segmented *s = user_data;
	int32_t index = 0;
	for (siv_node before = related(seg, SIV_RELATION_PREVIOUS); before; before = related(before, SIV_RELATION_PREVIOUS)) index++;
	choose(event->window, s, index);
	return SIV_EVENT_RESULT_HANDLED;
}

/* Arrow keys follow WAI-ARIA's radio group, mirrored right to left. */
static siv_event_result root_key(void *user_data, siv_node root, const siv_event *event) {
	struct segmented *s = user_data;
	if (!(event->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
	bool rtl = false;
	if (siv_node_is_rtl(root, &rtl) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	int32_t step = 0;
	if (event->keysym == SIV_KEY_RIGHT || event->keysym == SIV_KEY_DOWN) step = 1;
	if (event->keysym == SIV_KEY_LEFT || event->keysym == SIV_KEY_UP) step = -1;
	if (event->keysym == SIV_KEY_LEFT || event->keysym == SIV_KEY_RIGHT) step = rtl ? -step : step;
	if (step == 0) return SIV_EVENT_RESULT_PASS;
	choose(event->window, s, s->selected + step);
	return SIV_EVENT_RESULT_HANDLED;
}

/* The widget interface: what siv_widget_set_value, siv_widget_get_value,
 * siv_widget_set_label, and siv_node_focus do on the widget's root, as
 * they do on a stock widget's. Setters run in the caller's transaction
 * and report no change; a value the widget refuses fails it. */
static void widget_set_value(void *user_data, siv_txn txn, siv_node root, double value) {
	(void)root;
	struct segmented *s = user_data;
	if (value < 0 || value >= s->count || value != (int32_t)value) {
		siv_txn_fail(txn, SIV_ERROR_INVALID_ARGUMENT);
		return;
	}
	s->selected = (int32_t)value;
	restyle(txn, s);
}

static double widget_get_value(void *user_data, siv_node root) {
	(void)root;
	return ((struct segmented *)user_data)->selected;
}

/* The label is the group's accessible name: it has no visible text. */
static void widget_set_label(void *user_data, siv_txn txn, siv_node root, const char *label, size_t label_len) {
	(void)user_data;
	siv_set_semantics(txn, root, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_GROUP, .label = label, .label_len = label_len));
}

/* siv_node_focus on the widget focuses the selected option. */
static siv_node widget_focus(void *user_data, siv_node root) {
	(void)root;
	struct segmented *s = user_data;
	return segment_at(s->root, s->selected);
}

/* Builds the control in the caller's transaction and returns its root, or
 * 0 once the transaction has failed, like every builder. */
static siv_node segmented(siv_txn txn, siv_node parent, const char *label, const char *const *options, uint32_t count) {
	if (count == 0) {
		siv_txn_fail(txn, SIV_ERROR_INVALID_ARGUMENT);
		return 0;
	}
	siv_node root = siv_flex(txn, parent, SIV_DESC(siv_flex_desc, .gap = 2));
	struct segmented *s = NULL;
	if (siv_set_data(txn, root, &segmented_key, sizeof *s, (void **)&s) != SIV_OK) return 0;
	*s = (struct segmented){.root = root, .count = count, .selected = 0};
	/* Metrics go in the default layout, so the application's own
	 * siv_set_layout adds to them instead of replacing them. */
	siv_set_default_layout(txn, root, SIV_DESC(siv_layout_desc, .padding = {3, 3, 3, 3}));
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_CONTROL_BG, .border_token = SIV_COLOR_TOKEN_BORDER, .border_width = 1, .radius = {8, 8, 8, 8}));
	siv_set_semantics(txn, root, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_GROUP, .label = label, strlen(label)));
	siv_on_default(txn, root, SIV_EVENT_TYPE_KEY, root_key, NULL, s);
	siv_set_widget(txn, root, SIV_DESC(siv_widget_desc, .user_data = s, .set_value = widget_set_value, .get_value = widget_get_value, .set_label = widget_set_label, .focus = widget_focus));
	for (uint32_t i = 0; i < count; i++) {
		siv_node seg = siv_box(txn, root);
		siv_set_default_layout(txn, seg, SIV_DESC(siv_layout_desc, .padding = {14, 14, 5, 5}));
		siv_on_default(txn, seg, SIV_EVENT_TYPE_ACTIVATE, segment_activate, NULL, s);
		siv_text(txn, seg, options[i], strlen(options[i]));
	}
	restyle(txn, s);
	return root;
}

/* The application ------------------------------------------------------ */

struct calendar {
	siv_node shown;
};

static siv_event_result on_range(void *user_data, siv_node control, const siv_event *event) {
	(void)control;
	struct calendar *cal = user_data;
	static const char *const text[] = {"Showing today", "Showing this week", "Showing this month"};
	siv_txn txn;
	if (siv_txn_begin(event->window, &txn) != SIV_OK) return SIV_EVENT_RESULT_PASS;
	siv_set_text(txn, cal->shown, text[event->index], strlen(text[event->index]));
	commit(txn);
	return SIV_EVENT_RESULT_HANDLED;
}

int main(void) {
	siv_app app;
	siv_result r = siv_app_create(NULL, &app);
	if (r != SIV_OK) {
		fprintf(stderr, "segmented: %s\n", siv_result_name(r));
		return 1;
	}
	siv_window window;
	struct calendar cal = {0};
	r = siv_window_create(app, SIV_DESC(siv_window_desc, .title = SIV_STR("Calendar"), .width = 340, .height = 140), &window);
	siv_txn txn;
	if (r == SIV_OK) r = siv_txn_begin(window, &txn);
	if (r == SIV_OK) {
		siv_node root = siv_window_get_root(window);
		siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background_token = SIV_COLOR_TOKEN_WINDOW_BG));
		siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 14, .align_items = SIV_ALIGN_START));
		siv_set_layout(txn, column, SIV_DESC(siv_layout_desc, .padding = {20, 20, 20, 20}));
		const char *const options[] = {"Day", "Week", "Month"};
		siv_node range = segmented(txn, column, "Range", options, 3);
		/* The generic calls drive it like a stock widget. */
		siv_widget_set_value(txn, range, 1);
		siv_on(txn, range, SIV_EVENT_TYPE_CHANGE, on_range, NULL, &cal);
		cal.shown = siv_text(txn, column, SIV_STR("Showing this week"));
		siv_set_text_style(txn, cal.shown, SIV_DESC(siv_text_style_desc, .color_token = SIV_COLOR_TOKEN_WINDOW_FG));
		r = siv_txn_commit(txn);
	}
	if (r == SIV_OK) r = siv_app_run(app);
	if (r != SIV_OK) fprintf(stderr, "segmented: %s\n", siv_result_name(r));
	siv_app_destroy(app);
	return r == SIV_OK ? 0 : 1;
}
