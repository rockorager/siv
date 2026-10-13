/* A single-instance application for the lifecycle integration tests
 * (src/abi/integration_tests.zig): it runs on the headless backend with
 * the application id org.siv.Test.Lifecycle, logs every activation and
 * action to the file named by --log=PATH, and quits on the "quit"
 * action. --service marks a launch by D-Bus activation; other arguments
 * are URIs to open. */

#include <siv.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *log_file;
static siv_app app;

static void on_activate(void *user_data, siv_app a, const siv_activation *act) {
    (void)user_data;
    (void)a;
    fprintf(log_file, "%s %s token=%.*s", act->type == SIV_ACTIVATION_TYPE_OPEN ? "open" : "activate",
            act->source == SIV_ACTIVATION_SOURCE_REMOTE ? "remote" : "launch", (int)act->activation_token_len,
            act->activation_token ? act->activation_token : "");
    for (size_t i = 0; i < act->uris_count; i++) fprintf(log_file, " %.*s", (int)act->uris[i].uri_len, act->uris[i].uri);
    fputc('\n', log_file);
    fflush(log_file);
}

static void on_action(void *user_data, const siv_action_event *e) {
    (void)user_data;
    fprintf(log_file, "action %.*s %.*s\n", (int)e->name_len, e->name, (int)e->target_len, e->target ? e->target : "");
    fflush(log_file);
    if (e->name_len == 4 && memcmp(e->name, "quit", 4) == 0 && siv_app_quit(app) != SIV_OK) fprintf(log_file, "quit failed\n");
}

int main(int argc, char **argv) {
    const char *log_path = NULL;
    int service = 0;
    siv_uri uris[8];
    size_t uri_count = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--service") == 0) {
            service = 1;
        } else if (strncmp(argv[i], "--log=", 6) == 0) {
            log_path = argv[i] + 6;
        } else if (uri_count < 8) {
            uris[uri_count++] = (siv_uri){ .uri = argv[i], .uri_len = strlen(argv[i]) };
        }
    }
    if (!log_path) return 2;
    log_file = fopen(log_path, "a");
    if (!log_file) return 2;

    const char *id = "org.siv.Test.Lifecycle";
    if (siv_app_create(SIV_DESC(siv_app_desc, .backend = SIV_BACKEND_HEADLESS, .flags = SIV_APP_NO_SYSTEM_FONTS, .app_id = id, .app_id_len = strlen(id)), &app) != SIV_OK) return 3;
    if (siv_app_add_action(app, "quit", 4, on_action, NULL, NULL) != SIV_OK) return 4;
    if (siv_app_launch(app, SIV_DESC(siv_launch_desc, .uris = uris, .uris_count = uri_count, .on_activate = on_activate,
                                     .flags = service ? SIV_LAUNCH_SERVICE : 0, .idle_timeout_ms = 20000)) != SIV_OK) return 5;
    siv_result r = siv_app_run(app);
    siv_instance instance = SIV_INSTANCE_NONE;
    if (siv_app_get_instance(app, &instance) != SIV_OK) return 6;
    fprintf(log_file, "exit %s %s\n", instance == SIV_INSTANCE_PRIMARY ? "primary" : instance == SIV_INSTANCE_SECONDARY ? "secondary" : "other",
            siv_result_name(r));
    fclose(log_file);
    siv_app_destroy(app);
    return 0;
}
