# Embedding siv in another event loop

`siv_app_run` owns the thread's loop. A program with a loop of its own (GLib,
libuv, Qt, a game loop, a server) drives siv instead with two calls (D6):

- `siv_app_get_fd` returns a file descriptor that is readable whenever siv has
  work: input, timers, posted work, or a frame to draw.
- `siv_app_dispatch(app, 0)` does that work without waiting.

Poll the descriptor with your others and dispatch when it is readable.
That is all siv needs: an idle siv leaves it unreadable and makes no
wakeups. [examples/embed.c](examples/embed.c) is a `poll` loop with a timer
of the host's own:

```c
/* The host's loop. siv's descriptor stays readable while siv has work
 * pending, so dispatching with a timeout of 0 when it is readable is
 * all siv needs. */
struct pollfd fds[] = {{.fd = siv_fd, .events = POLLIN}, {.fd = timer, .events = POLLIN}};
while (host.open) {
	if (poll(fds, 2, -1) < 0) break;
	if (fds[0].revents & POLLIN) {
		r = siv_app_dispatch(app, 0);
		if (r != SIV_OK) break;
	}
	if (fds[1].revents & POLLIN) {
		uint64_t expirations;
		if (read(timer, &expirations, sizeof expirations) == sizeof expirations) tick(&host);
	}
}
```

![A small window reading Host ticks: 0](images/embed.png)

The host's own handlers may call siv freely, since they run on the thread
that created the application, between dispatches:

```c
/* The host's own work. It may call siv freely: it runs on the thread that
 * created the application, between dispatches. */
static void tick(struct host *host) {
	char text[32];
	snprintf(text, sizeof text, "Host ticks: %u", ++host->count);
	siv_txn txn;
	if (siv_txn_begin(host->window, &txn) != SIV_OK) return;
	siv_set_text(txn, host->ticks, text, strlen(text));
	siv_result r = siv_txn_commit(txn);
	if (r != SIV_OK) fprintf(stderr, "embed: %s\n", siv_result_name(r));
}
```

The same rules hold as under `siv_app_run`: call siv only from that thread
(other threads use `siv_post`), and never call `siv_app_dispatch` from
inside a siv callback (`SIV_ERROR_BUSY`). With GLib, wrap the descriptor
in a `GSource` (or `g_unix_fd_add`) whose callback calls
`siv_app_dispatch(app, 0)`; with libuv, a `uv_poll_t`. A loop that wants
to block in siv instead passes a timeout: `siv_app_dispatch(app, -1)`
waits for work.

`siv_app_dispatch` returns `SIV_ERROR_UNAVAILABLE` once the connection to
the compositor is lost; the application should then end. Ending is the
host's business here: siv does not stop when the last window closes, so
the sample watches for its window's close request.

The opposite direction, your descriptors in siv's loop, is
`siv_app_watch_fd` (see [Work off the UI thread](09-async.md#file-descriptors)).

## Lua in a C program

A C program that wants Lua scripting without a Lua of its own links
libsiv-lua (`pkg-config siv-lua`). `siv_lua_new` makes a Lua state with
`require("siv")` and the standard libraries you allow (pass a mask to
leave out `io` and `os` for untrusted scripts), and `siv_lua_run` runs a
file as an application, optionally with hot reload. A program that embeds
Lua 5.5 already loads `siv.so` with `require` instead and keeps its own
Lua.
