#!/bin/sh
# Sends input lines to one long-lived injector, so the seat keeps its
# virtual devices: a new device per command makes clients rebind
# wl_pointer and the compositor drops the first press.
#   inj.sh 'move 10 10' press release
#   inj.sh --stop
FIFO=$XDG_RUNTIME_DIR/swv-inject.fifo
INJECT=$(cd "$(dirname "$0")/../bench/out" && pwd)/inject
if [ "$1" = --stop ]; then
	pkill -f "^$INJECT" ; pkill -f "^sleep 2147483646"; rm -f "$FIFO"; exit 0
fi
if [ ! -p "$FIFO" ] || ! pgrep -f "^$INJECT" >/dev/null; then
	rm -f "$FIFO"; mkfifo "$FIFO"
	setsid sleep 2147483646 > "$FIFO" 2>/dev/null < /dev/null &
	setsid "$INJECT" < "$FIFO" > /dev/null 2>&1 &
	sleep 0.5
fi
for l in "$@"; do printf '%s\n' "$l"; done > "$FIFO"
