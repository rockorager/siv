#!/bin/sh
# Records the phase-4 demo on a running sway: typing, an input method's
# composition, <select>, the context menu, scrolling, and a video.
#   spike/demo.sh OUT.mp4 BROWSER
set -e
OUT=$1 B=$2
J=$(dirname "$0")/inj.sh
F=$XDG_RUNTIME_DIR/ime.fifo
rm -f "$F"; mkfifo "$F"
setsid sleep 120 > "$F" < /dev/null 2>&1 &
setsid "$(dirname "$0")/../bench/out/ime" < "$F" > "$XDG_RUNTIME_DIR/ime.log" 2>&1 &
$J 'move 1200 780'
setsid nice wf-recorder -y -f "$OUT" -c libx264 -p preset=veryfast -p crf=26 > "$XDG_RUNTIME_DIR/rec.log" 2>&1 &
REC=$!
sleep 1
setsid "$B" http://127.0.0.1:8765/test.html > "$XDG_RUNTIME_DIR/demo-browser.log" 2>&1 &
sleep 2.5
$J 'move 200 276' press release 'sleep 300' 'typeburst 70 Hello from siv-webview '
sleep 2
echo 'preedit n~' > "$F"; sleep 0.8
echo 'preedit nan~' > "$F"; sleep 0.8
echo 'commit ñandú' > "$F"; sleep 1
$J 'move 58 322' press release; sleep 1.2
$J 'move 70 412'; sleep 0.6; $J press release; sleep 1.2
$J 'move 500 520' rpress rrelease; sleep 1.5
$J 'key Escape'; sleep 0.5
$J 'move 640 500' 'scrollburst 7.5 120 240'; sleep 1
$J 'scrollburst -7.5 120 240'; sleep 1
$J 'key ctrl+l' 'sleep 200' 'typeburst 30 http://127.0.0.1:8765/video.html' 'key Return'
sleep 5
kill -INT $REC; sleep 1.5
pkill -x siv-webview-bro || true
pkill -x ime || true
