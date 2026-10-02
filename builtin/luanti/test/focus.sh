#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 0s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FOCUS_LOG]: the mouse's capture follows the window's focus. A client in
# devtest, the mouse hidden by the first placement; then ten times the
# window loses focus (minimized) and gets it back (activated) through
# xdotool, and after every regain the log has to say the cursor was
# hidden and captured again. Prints the count and PASS or FAIL.
#
#   builtin/luanti/test/focus.sh
#
# Wants a display of its own and xdotool; the window is found by the
# client's pid. See the skip below: it is not run on a display in use.
set -u
# **Never on a display someone is using** (user, 2026-09-23: this check
# injected alt+Tab into the session they were working in). It minimizes
# windows, activates them and sends keys through the X server, and no
# amount of --window keeps that to itself -- a window manager grabs
# alt+Tab globally, and an activate steals focus from whatever the
# person was typing in. So it runs on a display of its own and skips
# otherwise: BUILDAT_FOCUS_DISPLAY=:N names an Xephyr or Xvfb started
# for it, and BUILDAT_FOCUS_X11=1 says the session is nobody's.
if [ -n "${BUILDAT_FOCUS_DISPLAY:-}" ]; then
	export DISPLAY="$BUILDAT_FOCUS_DISPLAY"
elif [ -z "${BUILDAT_FOCUS_X11:-}" ]; then
	echo "SKIP: focus.sh drives a real X session (alt+Tab, minimize," \
			"activate); give it a display of its own with" \
			"BUILDAT_FOCUS_DISPLAY=:N, or say the session is nobody's" \
			"with BUILDAT_FOCUS_X11=1"
	exit 77
fi
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_focus.XXXXXX")
cd "$here/Build"
rm -rf ../user/apps/vanilla/saves/buildat_test_focus
srv=""; cli=""
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
port=$(( 29500 + (RANDOM % 90) ))
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_focus \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D ../user -P "$port" 2>&1 \
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
# And an alt+tab as the keys, to this window: the Tab under Alt reaches
# the client before the window manager acts, and it must not be taken
# as the game's mouse key (which is Tab)
xdotool keydown --window "$win" alt; sleep 0.2
xdotool key --window "$win" Tab; sleep 0.2
xdotool keyup --window "$win" alt; sleep 1
xdotool windowminimize "$win"; sleep 1
xdotool windowactivate --sync "$win" 2>/dev/null; sleep 1
kill "$pid" 2>/dev/null
lost=$(grep -ac "mouse visible (focus lost)" "$tmp/cli.log")
regained=$(grep -ac "mouse hidden (focus regained)" "$tmp/cli.log")
last=$(grep -a "mouse hidden\|mouse visible" "$tmp/cli.log" | tail -1 | sed 's/^.*Urho3D INFO: //')
echo "focus: lost $lost, regained $regained; last: $last"
echo "logs in $tmp"
mouse_key=$(grep -ac "mouse visible (the mouse key)" "$tmp/cli.log")
echo "focus: the mouse key under alt+tab freed the mouse $mouse_key times"
if [ "$regained" -ge 11 ] && [ "$mouse_key" = 0 ] &&
		[ "$last" = "mouse hidden (focus regained)" ]; then
	echo PASS
else
	echo FAIL
	exit 1
fi
