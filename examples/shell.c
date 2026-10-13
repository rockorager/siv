/* A desktop shell built on siv's shell module (D31): a bar on every
 * output, with the workspaces on that output, a task list of the windows
 * on it, a clock, and a lock button; and a lock screen, also after five
 * idle minutes, that checks the password with PAM.
 *
 *     zig build examples && ./zig-out/bin/shell           on sway, Hyprland, niri, KWin, ...
 *     ./zig-out/bin/shell --lock                          just the lock screen
 *
 * siv makes the surfaces, delivers the desktop's state as events at safe
 * points, and keeps the password in locked memory; checking it is the
 * application's job, done here on a worker thread (siv_job_start) so the
 * lock screen stays responsive while PAM waits. PAM is loaded at run time
 * (libpam.so.0), so the example builds without its headers; the service
 * is "login" unless SIV_SHELL_PAM_SERVICE names another.
 */
#define _DEFAULT_SOURCE
#include <siv.h>

#include <dlfcn.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define MAX_OUTPUTS 8
#define MAX_ITEMS 64
#define IDLE_LOCK_MS (5 * 60 * 1000)

struct shell;

/* A toplevel or workspace as the last event described it. */
struct item {
	bool used;
	uint64_t handle;
	char name[96];
	size_t name_len;
	uint32_t states;
	siv_output outputs[MAX_OUTPUTS];
	size_t output_count;
};

struct bar {
	struct shell *shell;
	bool used;
	siv_output output;
	siv_window window;
	siv_node row, workspaces, tasks, clock;
};

struct shell {
	siv_app app;
	bool lock_only;
	siv_capabilities caps;
	struct bar bars[MAX_OUTPUTS];
	struct item toplevels[MAX_ITEMS];
	struct item workspaces[MAX_ITEMS];
	siv_toplevel_list toplevel_list;
	siv_workspace_list workspace_list;
	siv_idle_watch idle;
	siv_lock lock;
	/* The lock windows, and their password fields and messages. */
	siv_window lock_windows[MAX_OUTPUTS];
	siv_node lock_fields[MAX_OUTPUTS], lock_messages[MAX_OUTPUTS], lock_clocks[MAX_OUTPUTS];
	bool authenticating;
	char clock[16];
};

static const siv_color fg = {0.93f, 0.94f, 0.96f, 1};
static const siv_color dim = {0.62f, 0.64f, 0.70f, 1};

/* Clock --------------------------------------------------------------------- */

static void update_clock_text(struct shell *s) {
	time_t now = time(NULL);
	struct tm tm;
	localtime_r(&now, &tm);
	strftime(s->clock, sizeof s->clock, "%H:%M", &tm);
}

static void set_text(siv_window window, siv_node node, const char *text) {
	siv_txn txn;
	if (!window || !node || siv_txn_begin(window, &txn) != SIV_OK) return;
	siv_set_text(txn, node, text, strlen(text));
	(void)siv_txn_commit(txn);
}

static void tick(void *user_data);

static void schedule_tick(struct shell *s) {
	/* Again at the start of the next minute. */
	time_t now = time(NULL);
	unsigned delay = (unsigned)(60 - now % 60) * 1000;
	(void)siv_timer_start(s->app, delay, tick, NULL, s, NULL);
}

static void tick(void *user_data) {
	struct shell *s = user_data;
	update_clock_text(s);
	for (int i = 0; i < MAX_OUTPUTS; i++) {
		if (s->bars[i].used) set_text(s->bars[i].window, s->bars[i].clock, s->clock);
		if (s->lock_windows[i]) set_text(s->lock_windows[i], s->lock_clocks[i], s->clock);
	}
	schedule_tick(s);
}

/* PAM, loaded at run time ------------------------------------------------------ */

struct pam_message { int msg_style; const char *msg; };
struct pam_response { char *resp; int resp_retcode; };
struct pam_conv {
	int (*conv)(int, const struct pam_message **, struct pam_response **, void *);
	void *appdata_ptr;
};
#define PAM_SUCCESS 0
#define PAM_BUF_ERR 5
#define PAM_CONV_ERR 19
#define PAM_PROMPT_ECHO_OFF 1
#define PAM_PROMPT_ECHO_ON 2

/* A password check in flight: the password is a copy in locked memory,
 * wiped once PAM has it. */
struct auth {
	struct shell *shell;
	char *password;
	size_t len, cap;
	bool ok;
};

static int conversation(int n, const struct pam_message **msgs, struct pam_response **out, void *data) {
	struct auth *a = data;
	struct pam_response *r = calloc((size_t)n, sizeof *r);
	if (!r) return PAM_BUF_ERR;
	for (int i = 0; i < n; i++) {
		int style = msgs[i]->msg_style;
		if (style == PAM_PROMPT_ECHO_OFF || style == PAM_PROMPT_ECHO_ON) {
			r[i].resp = strndup(a->password, a->len);
			if (!r[i].resp) {
				for (int j = 0; j < i; j++) free(r[j].resp);
				free(r);
				return PAM_CONV_ERR;
			}
		}
	}
	*out = r;
	return PAM_SUCCESS;
}

/* On a worker thread: siv calls nothing back until auth_done. */
static void auth_work(void *user_data) {
	struct auth *a = user_data;
	void *pam = dlopen("libpam.so.0", RTLD_NOW | RTLD_LOCAL);
	if (pam) {
		int (*start)(const char *, const char *, const struct pam_conv *, void **) = (int (*)(const char *, const char *, const struct pam_conv *, void **))dlsym(pam, "pam_start");
		int (*authenticate)(void *, int) = (int (*)(void *, int))dlsym(pam, "pam_authenticate");
		int (*end)(void *, int) = (int (*)(void *, int))dlsym(pam, "pam_end");
		struct passwd *pw = getpwuid(getuid());
		const char *service = getenv("SIV_SHELL_PAM_SERVICE");
		struct pam_conv conv = {conversation, a};
		void *handle = NULL;
		if (start && authenticate && end && pw && start(service ? service : "login", pw->pw_name, &conv, &handle) == PAM_SUCCESS) {
			a->ok = authenticate(handle, 0) == PAM_SUCCESS;
			end(handle, PAM_SUCCESS);
		}
		dlclose(pam);
	} else {
		fprintf(stderr, "shell: cannot load libpam.so.0: %s\n", dlerror());
	}
	explicit_bzero(a->password, a->cap);
}

static void clear_lock_fields(struct shell *s, const char *message) {
	for (int i = 0; i < MAX_OUTPUTS; i++) {
		if (!s->lock_windows[i]) continue;
		siv_txn txn;
		if (siv_txn_begin(s->lock_windows[i], &txn) != SIV_OK) continue;
		siv_set_text(txn, s->lock_fields[i], "", 0);
		siv_set_text(txn, s->lock_messages[i], message, strlen(message));
		(void)siv_txn_commit(txn);
	}
}

/* Back on the application's thread. */
static void auth_done(void *user_data) {
	struct auth *a = user_data;
	struct shell *s = a->shell;
	s->authenticating = false;
	if (!s->lock) return;
	if (a->ok) {
		(void)siv_lock_unlock(s->lock);
		s->lock = 0;
		memset(s->lock_windows, 0, sizeof s->lock_windows);
	} else {
		clear_lock_fields(s, "Wrong password");
	}
}

static void auth_free(void *user_data) {
	struct auth *a = user_data;
	explicit_bzero(a->password, a->cap);
	munlock(a->password, a->cap);
	free(a->password);
	free(a);
}

static siv_event_result on_password_key(void *user_data, siv_node node, const siv_event *event) {
	struct shell *s = user_data;
	if (event->keysym != SIV_KEY_RETURN || !(event->flags & SIV_EVENT_PRESSED)) return SIV_EVENT_RESULT_PASS;
	if (s->authenticating) return SIV_EVENT_RESULT_HANDLED;
	struct auth *a = calloc(1, sizeof *a);
	if (!a) return SIV_EVENT_RESULT_HANDLED;
	a->shell = s;
	a->cap = 512;
	a->password = malloc(a->cap);
	/* Kept out of swap; siv's own copy is in locked memory already. */
	if (!a->password || mlock(a->password, a->cap) != 0) {
		free(a->password);
		free(a);
		return SIV_EVENT_RESULT_HANDLED;
	}
	size_t len = 0;
	if (siv_node_get_text(node, a->password, a->cap, &len) != SIV_OK || len == 0 || len >= a->cap) {
		auth_free(a);
		return SIV_EVENT_RESULT_HANDLED;
	}
	a->len = len;
	s->authenticating = true;
	clear_lock_fields(s, "Checking…");
	if (siv_job_start(s->app, 0, auth_work, auth_done, auth_free, a) != SIV_OK) s->authenticating = false;
	return SIV_EVENT_RESULT_HANDLED;
}

/* The lock screen -------------------------------------------------------------- */

/* A lock window: the clock, who is locked out, and the password field. */
static void build_lock_window(struct shell *s, siv_window window) {
	int i = 0;
	while (i < MAX_OUTPUTS && s->lock_windows[i]) i++;
	if (i == MAX_OUTPUTS) return;
	siv_txn txn;
	if (siv_txn_begin(window, &txn) != SIV_OK) return;
	siv_node root = siv_window_get_root(window);
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {0.07f, 0.08f, 0.11f, 1}));
	siv_set_semantics(txn, root, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_DIALOG, .label = "Locked", .label_len = 6));
	siv_node column = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .axis = SIV_AXIS_COLUMN, .gap = 16, .align_items = SIV_ALIGN_CENTER, .justify = SIV_JUSTIFY_CENTER));
	siv_node clock = siv_text(txn, column, s->clock, strlen(s->clock));
	siv_set_text_style(txn, clock, SIV_DESC(siv_text_style_desc, .font_size = 64, .weight = SIV_FONT_WEIGHT_LIGHT, .color = fg));
	struct passwd *pw = getpwuid(getuid());
	const char *user = pw ? pw->pw_name : "";
	siv_node who = siv_text(txn, column, user, strlen(user));
	siv_set_text_style(txn, who, SIV_DESC(siv_text_style_desc, .font_size = 16, .color = dim));
	siv_node field = siv_editor(txn, column, SIV_EDITOR_MASKED);
	siv_set_layout(txn, field, SIV_DESC(siv_layout_desc, .width = {SIV_UNIT_PX, 280}, .padding = {10, 10, 8, 8}));
	siv_set_visual(txn, field, SIV_DESC(siv_visual_desc, .background = {1, 1, 1, 0.08f}, .border_color = {1, 1, 1, 0.25f}, .border_width = 1, .radius = {8, 8, 8, 8}));
	siv_set_text_style(txn, field, SIV_DESC(siv_text_style_desc, .font_size = 16, .color = fg));
	siv_set_semantics(txn, field, SIV_DESC(siv_semantics_desc, .label = "Password", .label_len = 8));
	siv_on(txn, field, SIV_EVENT_TYPE_KEY, on_password_key, NULL, s);
	siv_node message = siv_text(txn, column, "", 0);
	siv_set_text_style(txn, message, SIV_DESC(siv_text_style_desc, .font_size = 14, .color = {0.98f, 0.55f, 0.55f, 1}));
	siv_set_semantics(txn, message, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_STATUS, .flags = SIV_SEMANTICS_LIVE_ASSERTIVE));
	if (siv_txn_commit(txn) != SIV_OK) return;
	(void)siv_node_focus(field);
	s->lock_windows[i] = window;
	s->lock_fields[i] = field;
	s->lock_messages[i] = message;
	s->lock_clocks[i] = clock;
}

static void forget_lock_window(struct shell *s, siv_window window) {
	for (int i = 0; i < MAX_OUTPUTS; i++)
		if (s->lock_windows[i] == window) s->lock_windows[i] = 0;
}

static bool on_lock_window_event(void *user_data, siv_window window, const siv_window_event *event) {
	if (event->type == SIV_WINDOW_EVENT_TYPE_CLOSED) forget_lock_window(user_data, window);
	return false;
}

static void on_lock_event(void *user_data, siv_lock lock, const siv_lock_event *event) {
	struct shell *s = user_data;
	switch (event->type) {
	case SIV_LOCK_EVENT_TYPE_WINDOW: build_lock_window(s, event->window); break;
	case SIV_LOCK_EVENT_TYPE_LOCKED: break;
	case SIV_LOCK_EVENT_TYPE_DENIED:
	case SIV_LOCK_EVENT_TYPE_FINISHED:
		fprintf(stderr, "shell: the lock %s\n", event->type == SIV_LOCK_EVENT_TYPE_DENIED ? "was refused" : "ended");
		siv_lock_destroy(lock);
		s->lock = 0;
		memset(s->lock_windows, 0, sizeof s->lock_windows);
		break;
	default: break;
	}
}

static void lock_session(struct shell *s) {
	if (s->lock) return;
	siv_result r = siv_lock_create(s->app, SIV_DESC(siv_lock_desc, .on_event = on_lock_event, .on_window_event = on_lock_window_event, .user_data = s), &s->lock);
	if (r != SIV_OK) {
		fprintf(stderr, "shell: cannot lock: %s\n", siv_result_name(r));
		s->lock = 0;
	}
}

static void on_idle(void *user_data, siv_idle_watch watch, bool idle) {
	(void)watch;
	if (idle) lock_session(user_data);
}

/* The bar ---------------------------------------------------------------------- */

static bool on_output(const struct item *it, siv_output output) {
	/* A compositor that does not say where something is shows it everywhere. */
	if (it->output_count == 0) return true;
	for (size_t i = 0; i < it->output_count; i++)
		if (it->outputs[i] == output) return true;
	return false;
}

/* What a bar button acts on. */
struct target {
	struct shell *shell;
	bool workspace;
	uint64_t handle;
};

static void free_target(void *user_data) { free(user_data); }

static siv_event_result on_item_click(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	(void)event;
	struct target *t = user_data;
	if (t->workspace) {
		(void)siv_workspace_activate((siv_workspace)t->handle);
		return SIV_EVENT_RESULT_HANDLED;
	}
	/* The focused window minimizes; any other comes to the front. */
	for (int i = 0; i < MAX_ITEMS; i++) {
		struct item *it = &t->shell->toplevels[i];
		if (!it->used || it->handle != t->handle) continue;
		if (it->states & SIV_TOPLEVEL_STATES_ACTIVATED) (void)siv_toplevel_set_minimized((siv_toplevel)t->handle, true);
		else (void)siv_toplevel_activate((siv_toplevel)t->handle);
	}
	return SIV_EVENT_RESULT_HANDLED;
}

static void add_button(siv_txn txn, siv_node parent, struct shell *s, const struct item *it, bool workspace, bool current) {
	siv_node b = siv_push_button(txn, parent, SIV_DESC(siv_button_desc, .label = it->name, .label_len = it->name_len, .style = current ? SIV_BUTTON_STYLE_PRIMARY : SIV_BUTTON_STYLE_FLAT));
	if (!workspace) siv_set_layout(txn, b, SIV_DESC(siv_layout_desc, .max_width = 220));
	struct target *t = malloc(sizeof *t);
	if (!t) return;
	*t = (struct target){s, workspace, it->handle};
	siv_on(txn, b, SIV_EVENT_TYPE_ACTIVATE, on_item_click, free_target, t);
}

/* Rebuilds a bar's workspaces and tasks from the latest events. */
static void refresh_bar(struct bar *b) {
	struct shell *s = b->shell;
	siv_txn txn;
	if (siv_txn_begin(b->window, &txn) != SIV_OK) return;
	siv_remove(txn, b->workspaces);
	siv_remove(txn, b->tasks);
	b->workspaces = siv_flex(txn, b->row, SIV_DESC(siv_flex_desc, .gap = 2));
	siv_set_semantics(txn, b->workspaces, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_GROUP, .label = "Workspaces", .label_len = 10));
	b->tasks = siv_flex(txn, b->row, SIV_DESC(siv_flex_desc, .gap = 2));
	siv_set_layout(txn, b->tasks, SIV_DESC(siv_layout_desc, .grow = 1));
	siv_set_semantics(txn, b->tasks, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_GROUP, .label = "Windows", .label_len = 7));
	siv_move(txn, b->workspaces, b->row, b->clock);
	siv_move(txn, b->tasks, b->row, b->clock);
	for (int i = 0; i < MAX_ITEMS; i++) {
		const struct item *ws = &s->workspaces[i];
		if (ws->used && on_output(ws, b->output) && !(ws->states & SIV_WORKSPACE_STATES_HIDDEN))
			add_button(txn, b->workspaces, s, ws, true, ws->states & SIV_WORKSPACE_STATES_ACTIVE);
	}
	for (int i = 0; i < MAX_ITEMS; i++) {
		const struct item *t = &s->toplevels[i];
		if (t->used && on_output(t, b->output)) add_button(txn, b->tasks, s, t, false, t->states & SIV_TOPLEVEL_STATES_ACTIVATED);
	}
	(void)siv_txn_commit(txn);
}

static void refresh_bars(struct shell *s) {
	for (int i = 0; i < MAX_OUTPUTS; i++)
		if (s->bars[i].used) refresh_bar(&s->bars[i]);
}

/* Keeps an item as an event described it, or forgets it. */
static void record(struct item *items, uint64_t handle, bool removed, const char *name, size_t name_len, uint32_t states, const siv_output *outputs, size_t output_count) {
	struct item *slot = NULL;
	for (int i = 0; i < MAX_ITEMS; i++)
		if (items[i].used && items[i].handle == handle) slot = &items[i];
	if (removed) {
		if (slot) slot->used = false;
		return;
	}
	for (int i = 0; !slot && i < MAX_ITEMS; i++)
		if (!items[i].used) slot = &items[i];
	if (!slot) return;
	slot->used = true;
	slot->handle = handle;
	slot->name_len = name_len < sizeof slot->name ? name_len : sizeof slot->name;
	memcpy(slot->name, name, slot->name_len);
	slot->states = states;
	slot->output_count = output_count < MAX_OUTPUTS ? output_count : MAX_OUTPUTS;
	memcpy(slot->outputs, outputs, slot->output_count * sizeof *outputs);
}

static void on_toplevel(void *user_data, siv_toplevel_list list, const siv_toplevel_event *e) {
	(void)list;
	struct shell *s = user_data;
	record(s->toplevels, (uint64_t)e->toplevel, e->type == SIV_TOPLEVEL_EVENT_TYPE_REMOVED, e->title, e->title_len, e->states, e->outputs, e->outputs_count);
	refresh_bars(s);
}

static void on_workspace(void *user_data, siv_workspace_list list, const siv_workspace_event *e) {
	(void)list;
	struct shell *s = user_data;
	record(s->workspaces, (uint64_t)e->workspace, e->type == SIV_WORKSPACE_EVENT_TYPE_REMOVED, e->name, e->name_len, e->states, e->outputs, e->outputs_count);
	refresh_bars(s);
}

static siv_event_result on_lock_click(void *user_data, siv_node node, const siv_event *event) {
	(void)node;
	(void)event;
	lock_session(user_data);
	return SIV_EVENT_RESULT_HANDLED;
}

static void free_bar(void *user_data) {
	struct bar *b = user_data;
	b->used = false;
}

/* A bar along the top of an output: translucent and blurred where the
 * compositor blurs, nearly opaque where it cannot. */
static void create_bar(struct shell *s, siv_output output) {
	struct bar *b = NULL;
	for (int i = 0; !b && i < MAX_OUTPUTS; i++)
		if (!s->bars[i].used) b = &s->bars[i];
	if (!b) return;
	*b = (struct bar){.shell = s, .used = true, .output = output};
	siv_result r = siv_layer_create(s->app, SIV_DESC(siv_layer_desc, .output = output, .namespace = "bar", .namespace_len = 3, .anchor = SIV_LAYER_ANCHOR_TOP | SIV_LAYER_ANCHOR_LEFT | SIV_LAYER_ANCHOR_RIGHT, .height = 34, .flags = SIV_LAYER_AUTO_EXCLUSIVE, .destroy = free_bar, .user_data = b), &b->window);
	if (r != SIV_OK) {
		fprintf(stderr, "shell: cannot create a bar: %s\n", siv_result_name(r));
		b->used = false;
		return;
	}
	siv_txn txn;
	if (siv_txn_begin(b->window, &txn) != SIV_OK) return;
	siv_node root = siv_window_get_root(b->window);
	bool blur = s->caps & SIV_CAPABILITIES_BLUR;
	siv_set_visual(txn, root, SIV_DESC(siv_visual_desc, .background = {0.09f, 0.10f, 0.13f, blur ? 0.55f : 0.94f}, .flags = blur ? SIV_VISUAL_WINDOW_BLUR : 0));
	siv_set_semantics(txn, root, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_TOOLBAR, .label = "Panel", .label_len = 5));
	b->row = siv_flex(txn, root, SIV_DESC(siv_flex_desc, .gap = 12, .align_items = SIV_ALIGN_CENTER));
	siv_set_layout(txn, b->row, SIV_DESC(siv_layout_desc, .padding = {6, 6, 2, 2}));
	b->workspaces = siv_box(txn, b->row);
	b->tasks = siv_box(txn, b->row);
	b->clock = siv_text(txn, b->row, s->clock, strlen(s->clock));
	siv_set_text_style(txn, b->clock, SIV_DESC(siv_text_style_desc, .font_size = 15, .weight = SIV_FONT_WEIGHT_SEMIBOLD, .color = fg));
	siv_set_semantics(txn, b->clock, SIV_DESC(siv_semantics_desc, .role = SIV_ROLE_STATUS, .label = "Clock", .label_len = 5));
	if (s->caps & SIV_CAPABILITIES_LOCK) {
		siv_node lock = siv_push_button(txn, b->row, SIV_DESC(siv_button_desc, .label = "Lock", .label_len = 4, .icon = "system-lock-screen-symbolic", .icon_len = 27, .style = SIV_BUTTON_STYLE_FLAT));
		siv_on(txn, lock, SIV_EVENT_TYPE_ACTIVATE, on_lock_click, NULL, s);
	}
	if (siv_txn_commit(txn) == SIV_OK) refresh_bar(b);
}

static void on_output_event(void *user_data, const siv_output_event *e) {
	struct shell *s = user_data;
	/* Every output gets a bar, also one plugged in again after the last
	 * went away (a laptop lid closed with only an external monitor, a dock
	 * or KVM switch): the output watch keeps siv_app_run going meanwhile.
	 * A removed output's bar is closed by the compositor and freed by its
	 * destroy-notify. */
	if (e->type == SIV_OUTPUT_EVENT_TYPE_ADDED) create_bar(s, e->output);
}

int main(int argc, char **argv) {
	struct shell s = {0};
	s.lock_only = argc > 1 && strcmp(argv[1], "--lock") == 0;
	siv_result r = siv_app_create(SIV_DESC(siv_app_desc, .app_id = "dev.siv.examples.shell", .app_id_len = 22, .name = "Shell", .name_len = 5), &s.app);
	if (r != SIV_OK) {
		fprintf(stderr, "siv_app_create: %s\n", siv_result_name(r));
		return 1;
	}
	(void)siv_app_get_capabilities(s.app, &s.caps);
	/* Light text on the dark bar and lock screen, stock buttons included. */
	(void)siv_app_set_theme(s.app, SIV_DESC(siv_theme_desc, .scheme = SIV_COLOR_SCHEME_DARK));
	update_clock_text(&s);
	schedule_tick(&s);
	if (s.lock_only) {
		lock_session(&s);
		if (!s.lock) {
			siv_app_destroy(s.app);
			return 1;
		}
	} else {
		if (!(s.caps & SIV_CAPABILITIES_LAYERS)) {
			fprintf(stderr, "shell: the compositor has no layer shell (GNOME has none)\n");
			siv_app_destroy(s.app);
			return 1;
		}
		(void)siv_app_watch_outputs(s.app, on_output_event, NULL, &s);
		if (siv_toplevel_list_create(s.app, SIV_DESC(siv_toplevel_list_desc, .on_event = on_toplevel, .user_data = &s), &s.toplevel_list) != SIV_OK) s.toplevel_list = 0;
		if (siv_workspace_list_create(s.app, SIV_DESC(siv_workspace_list_desc, .on_event = on_workspace, .user_data = &s), &s.workspace_list) != SIV_OK) s.workspace_list = 0;
		if (siv_idle_watch_create(s.app, SIV_DESC(siv_idle_watch_desc, .timeout_ms = IDLE_LOCK_MS, .flags = SIV_IDLE_IGNORE_INHIBITORS, .on_event = on_idle, .user_data = &s), &s.idle) != SIV_OK) s.idle = 0;
	}
	/* The bars run until the shell is killed (the output watch keeps
	 * siv_app_run going with no output); --lock returns once the session
	 * unlocks. */
	r = siv_app_run(s.app);
	if (r != SIV_OK) fprintf(stderr, "siv_app_run: %s\n", siv_result_name(r));
	siv_app_destroy(s.app);
	return r == SIV_OK ? 0 : 1;
}
