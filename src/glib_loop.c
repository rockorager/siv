/* GLib's default main context inside siv's loop: siv's prepare phase runs
 * GLib's check and dispatch for what became ready, then its prepare and
 * query, keeps a siv watch on every descriptor GLib polls, and bounds
 * siv's wait by GLib's timeout (siv_app_add_prepare, siv's D6). The
 * context is acquired by the application's thread for good, so sources
 * that other threads (WebKit's IPC) attach wake its wakeup descriptor.
 *
 * siv watches a duplicate of each descriptor, closed after its watch:
 * GLib closes a source's descriptor before the next query says so, and
 * epoll keeps reporting a closed descriptor whose file lives on (in a
 * child process, say) for a watch that no longer exists. */
#include "swv.h"

#include <glib.h>
#include <fcntl.h>
#include <linux/kcmp.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

struct watch {
    int fd;
    /* The duplicate siv watches. */
    int dup;
    siv_watch handle;
    gushort events;
    gushort revents;
    bool seen;
};

struct swv_glib_loop {
    siv_app app;
    GMainContext *ctx;
    siv_prepare prepare;
    GPollFD *fds;
    gint n_fds, cap_fds;
    gint max_prio;
    bool prepared;
    bool dispatching;
    bool stopping;
    struct watch *watches;
    int n_watches, cap_watches;
};

static struct watch *find_watch(struct swv_glib_loop *l, int fd) {
    for (int i = 0; i < l->n_watches; i++)
        if (l->watches[i].fd == fd) return &l->watches[i];
    return NULL;
}

static void on_ready(void *user_data, siv_watch watch, siv_watch_flags events) {
    struct swv_glib_loop *l = user_data;
    for (int i = 0; i < l->n_watches; i++) {
        struct watch *w = &l->watches[i];
        if (w->handle != watch) continue;
        if (events & SIV_WATCH_READABLE) w->revents |= G_IO_IN | (w->events & G_IO_PRI);
        if (events & SIV_WATCH_WRITABLE) w->revents |= G_IO_OUT;
        if (events & SIV_WATCH_HANGUP) w->revents |= G_IO_HUP;
        if (events & SIV_WATCH_ERROR) w->revents |= G_IO_ERR;
        /* GLib's check and dispatch run in this iteration's prepare phase. */
        return;
    }
}

/* Whether two descriptors name the same open file. */
static bool same_file(int a, int b) {
    long r = syscall(SYS_kcmp, (long)getpid(), (long)getpid(), (long)KCMP_FILE, (long)a, (long)b);
    if (r >= 0) return r == 0;
    struct stat sa, sb;
    return fstat(a, &sa) == 0 && fstat(b, &sb) == 0 && sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

static void unwatch(struct watch *w) {
    if (w->handle) siv_watch_destroy(w->handle);
    if (w->dup >= 0) close(w->dup);
    w->handle = 0;
    w->dup = -1;
}

static siv_watch_flags siv_flags(gushort events) {
    siv_watch_flags f = 0;
    if (events & (G_IO_IN | G_IO_PRI)) f |= SIV_WATCH_READABLE;
    if (events & G_IO_OUT) f |= SIV_WATCH_WRITABLE;
    return f;
}

/* Keeps one siv watch per descriptor GLib polls, asking for what any of
 * its GPollFDs ask for. */
static void sync_watches(struct swv_glib_loop *l) {
    for (int i = 0; i < l->n_watches; i++) l->watches[i].seen = false;
    for (gint i = 0; i < l->n_fds; i++) {
        int fd = l->fds[i].fd;
        struct watch *w = find_watch(l, fd);
        /* The number now names another file: watch that one instead. */
        if (w && !w->seen && w->dup >= 0 && !same_file(fd, w->dup)) {
            unwatch(w);
            *w = l->watches[--l->n_watches];
            w = NULL;
        }
        if (!w) {
            if (l->n_watches == l->cap_watches) {
                int cap = l->cap_watches ? l->cap_watches * 2 : 16;
                struct watch *grown = realloc(l->watches, (size_t)cap * sizeof *grown);
                if (!grown) continue;
                l->watches = grown, l->cap_watches = cap;
            }
            w = &l->watches[l->n_watches++];
            *w = (struct watch){.fd = fd, .dup = fcntl(fd, F_DUPFD_CLOEXEC, 0), .events = 0, .seen = true};
            siv_result wr = w->dup >= 0 ? siv_app_watch_fd(l->app, w->dup, siv_flags(l->fds[i].events), on_ready, NULL, l, &w->handle) : SIV_ERROR_INVALID_ARGUMENT;
            if (wr != SIV_OK) {
                w->handle = 0;
                if (w->dup >= 0) close(w->dup);
                w->dup = -1;
            }
            if (getenv("SWV_DEBUG_LOOP")) fprintf(stderr, "glib-loop: watch fd %d events 0x%x: %s\n", fd, l->fds[i].events, siv_result_name(wr));
            w->events = l->fds[i].events;
            continue;
        }
        if (!w->seen) {
            w->seen = true;
            if (w->events != l->fds[i].events) {
                w->events = l->fds[i].events;
                if (w->handle) (void)siv_watch_set_events(w->handle, siv_flags(w->events));
            }
        } else if ((w->events | l->fds[i].events) != w->events) {
            w->events |= l->fds[i].events;
            if (w->handle) (void)siv_watch_set_events(w->handle, siv_flags(w->events));
        }
    }
    for (int i = 0; i < l->n_watches;) {
        if (l->watches[i].seen) {
            i++;
            continue;
        }
        if (getenv("SWV_DEBUG_LOOP")) fprintf(stderr, "glib-loop: unwatch fd %d\n", l->watches[i].fd);
        unwatch(&l->watches[i]);
        l->watches[i] = l->watches[--l->n_watches];
    }
}

static void free_loop(struct swv_glib_loop *l) {
    for (int i = 0; i < l->n_watches; i++) unwatch(&l->watches[i]);
    free(l->watches);
    free(l->fds);
    g_main_context_release(l->ctx);
    g_main_context_unref(l->ctx);
    free(l);
}

static int32_t on_prepare(void *user_data, siv_prepare prepare) {
    (void)prepare;
    struct swv_glib_loop *l = user_data;
    if (l->prepared) {
        for (gint i = 0; i < l->n_fds; i++) {
            struct watch *w = find_watch(l, l->fds[i].fd);
            /* A descriptor siv could not watch (a regular file) is always
             * ready, as poll(2) says. */
            l->fds[i].revents = w && w->handle ? (w->revents & (l->fds[i].events | G_IO_ERR | G_IO_HUP | G_IO_NVAL)) : l->fds[i].events;
        }
        for (int i = 0; i < l->n_watches; i++) l->watches[i].revents = 0;
        l->dispatching = true;
        if (g_main_context_check(l->ctx, l->max_prio, l->fds, l->n_fds)) g_main_context_dispatch(l->ctx);
        l->dispatching = false;
        if (l->stopping) {
            siv_prepare_destroy(l->prepare);
            free_loop(l);
            return -1;
        }
    }
    gint timeout = -1;
    gboolean ready = g_main_context_prepare(l->ctx, &l->max_prio);
    for (;;) {
        gint n = g_main_context_query(l->ctx, l->max_prio, &timeout, l->fds, l->cap_fds);
        if (n <= l->cap_fds) {
            l->n_fds = n;
            break;
        }
        GPollFD *grown = realloc(l->fds, (size_t)n * sizeof *grown);
        if (!grown) {
            l->n_fds = l->cap_fds;
            break;
        }
        l->fds = grown, l->cap_fds = n;
    }
    sync_watches(l);
    l->prepared = true;
    return ready ? 0 : timeout;
}

struct swv_glib_loop *swv_glib_loop_start(siv_app app) {
    struct swv_glib_loop *l = calloc(1, sizeof *l);
    if (!l) return NULL;
    l->app = app;
    l->ctx = g_main_context_ref(g_main_context_default());
    if (!g_main_context_acquire(l->ctx)) {
        /* Another thread runs the default context: GLib drives itself. */
        g_main_context_unref(l->ctx);
        free(l);
        return NULL;
    }
    if (siv_app_add_prepare(app, on_prepare, NULL, l, &l->prepare) != SIV_OK) {
        g_main_context_release(l->ctx);
        g_main_context_unref(l->ctx);
        free(l);
        return NULL;
    }
    return l;
}

void swv_glib_loop_stop(struct swv_glib_loop *l) {
    if (!l) return;
    if (l->dispatching) {
        l->stopping = true;
        return;
    }
    siv_prepare_destroy(l->prepare);
    free_loop(l);
}
