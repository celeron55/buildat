#!/bin/bash
# [FOCUS_LOG]: the mouse's capture follows the window's focus. A client in
# devtest, the mouse hidden by the first placement; then ten times the
# window loses focus (minimized) and gets it back (activated) through
# xdotool, and after every regain the log has to say the cursor was
# hidden and captured again. Prints the count and PASS or FAIL.
#
#   builtin/luanti/test/focus.sh
#
# Wants an X display and xdotool; the window is found by the client's pid.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
cd "$here/Build"
rm -rf ../user/games/vanilla/saves/buildat_test_focus
srv=""; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
port=$(( 29500 + (RANDOM % 90) ))
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_focus \
	bin/buildat_server -m ../games/vanilla -D ../user -P "$port" 2>&1 \
	| sed -u -e 's/\x1b\[[0-9;]*m//g' > "$tmp/srv.log" &
for i in $(seq 1 200); do
	grep -q "Mods loaded" "$tmp/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 3
srv=$(pgrep -x buildat_server | head -1)
# Not a scripted client: one under -c keeps the cursor visible and its
# focus forced, which is the opposite of what is tested. Killed at the end.
bin/buildat -s "localhost:$port" -w 640x360 -l 3 \
	2>&1 | sed -u -e 's/\x1b\[[0-9;]*m//g' > "$tmp/cli.log" &
cli=$!
for i in $(seq 1 60); do
	grep -aq "the first placement" "$tmp/cli.log" && break
	sleep 1
done
sleep 2
# This run's client and no other window: by the client's pid, never by a
# title, which another buildat or an editor may carry
pid=$(pgrep -n -x buildat)
win=""
for i in $(seq 1 20); do
	win=$(xdotool search --pid "$pid" --onlyvisible 2>/dev/null | head -1)
	[ -n "$win" ] && break
	sleep 1
done
[ -n "$win" ] || { echo "FAIL: no window for the client pid $pid"; exit 1; }
for i in $(seq 1 10); do
	xdotool windowminimize "$win"; sleep 1
	xdotool windowactivate --sync "$win" 2>/dev/null; sleep 1
done
sleep 1
kill "$pid" 2>/dev/null
lost=$(grep -ac "mouse visible (focus lost)" "$tmp/cli.log")
regained=$(grep -ac "mouse hidden (focus regained)" "$tmp/cli.log")
last=$(grep -a "mouse hidden\|mouse visible" "$tmp/cli.log" | tail -1 | sed 's/^.*Urho3D INFO: //')
echo "focus: lost $lost, regained $regained; last: $last"
echo "logs in $tmp"
if [ "$regained" -ge 10 ] && [ "$last" = "mouse hidden (focus regained)" ]; then
	echo PASS
else
	echo FAIL
	exit 1
fi
