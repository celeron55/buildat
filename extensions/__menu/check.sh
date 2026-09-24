#!/bin/bash
# tier: quick
# cost: 104s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [MENU_FALLBACK]: **every launch UI boots**. Nothing started
# `launch_menu` in any check, so the quick tier signed off version one
# while `-m launch_menu` was aborting the client (user, 2026-09-23) --
# a launcher nobody drives is a launcher nobody notices breaking.
#
#   extensions/__menu/check.sh
#
# Every extension that ships a launch_ui.txt is booted by name, plus
# `launch_menu`, which has no marker of its own -- it is the menu's
# screens and boots `__menu` -- and is what [TWO_AUDIENCES] promises is
# a supported way to use buildat.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/launch_uis"; mkdir -p "$out"
cd "$here/Build"
if pgrep -x buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
{ echo "delay 2500"; echo "quit"; } > "$out/cmds.txt"
names="launch_menu"
for f in "$here"/extensions/*/launch_ui.txt; do
	[ -e "$f" ] || continue
	n=$(basename "$(dirname "$f")")
	# The hostile one is a launch UI on purpose and reaches nothing; it
	# has its own check and boots no screen
	[ "$n" = sandbox_test ] && continue
	names="$names $n"
done
bad=0
for n in $names; do
	# **Under a timeout** (2026-09-24, twice in one hour): a client can
	# hang in X11_ShowWindow waiting for the window manager to map its
	# window, and a boot check that waits forever on the desk's weather
	# reports nothing at all
	timeout 90 bin/buildat -m "$n" -D ../user -w 640x360 -l 3 \
		-c @"$out/cmds.txt" 2>&1 |
		sed -u -e 's/\x1b\[[0-9;]*m//g' > "$out/$n.log"
	why=""
	grep -aq "Crash: SIG" "$out/$n.log" && why="crashed"
	grep -aq "did not load; falling back" "$out/$n.log" &&
		why="${why:+$why, }raised and fell back"
	grep -aq "could not start a launch UI" "$out/$n.log" &&
		why="${why:+$why, }left the client with no launcher"
	grep -aq "Command sequence complete" "$out/$n.log" ||
		why="${why:+$why, }never got to the end of its sequence"
	if [ -n "$why" ]; then
		echo "  $n: $why"
		bad=$((bad + 1))
	else
		echo "  $n: up"
	fi
done
echo "$(echo "$names" | wc -w) launch UIs booted, $bad of them badly"

# **And the grid can be left.** A launcher that cannot be gone back to
# leaves a client with no server and no menu, and nothing short of
# [FIRST_RUN]'s twenty minutes was driving it: `__menu` had no
# `leave_game` at all, so a game started from the default launcher was
# a one-way trip (2026-09-24). This boots the grid straight into a
# game's own screen (-a runs one launch action), clicks that screen's
# "< back to the launcher", and asks the client to describe itself
# afterwards -- a dead client answers nothing.
{ echo "delay 25000"; echo "event scan 8 a"; echo "delay 1500"
	# The row at the bottom of vanilla's menu panel, at this window size
	echo "mouse_pos 639 608"; echo "delay 300"; echo "mouse_click left"
	echo "delay 6000"; echo "event scan 8 b"
	echo "delay 2000"; echo "quit"; } > "$out/cmds_back.txt"
timeout 180 bin/buildat -o launch_ui=__menu -a game/vanilla/contentdb -D ../user 	-w 1280x720 -l 3 -L "$out/back.log" -c @"$out/cmds_back.txt" 	> /dev/null 2>&1
grid=$(grep -ac "back to the grid" "$out/back.log")
lost=$(grep -ac "leave: no launcher to go back to" "$out/back.log")
alive=$(grep -ac "scan b: ui" "$out/back.log")
echo "leaving a game: back to the grid $grid times, $alive elements" 		"drawn after it"
if [ "$grid" -lt 1 ] || [ "$lost" -gt 0 ] || [ "$alive" -lt 10 ]; then
	echo "FAIL: a game started from the grid cannot be left -- the client" 			"is left with no server and no menu"
	grep -a "leave:\|Failed to run function" "$out/back.log" | head -3
	exit 1
fi
# **And the console opens over the grid** ([LAUNCH_CONSOLE] offers its
# screen to every launch UI, and the room had it first). The selection
# starts on the first tile, "Engine settings"; one right is the console,
# Return opens it and Escape hands the grid back.
# **The pointer goes to a corner first**: a tile under the mouse takes the
# selection as the grid appears (HoverBegin), and the run then arrowed
# from whichever game happened to sit in the middle of the window.
{ echo "delay 600"; echo "mouse_pos 2 2"
	echo "delay 4000"; echo "keypress Right"; echo "delay 400"
	echo "keypress Return"; echo "delay 2500"
	echo "keypress Escape"; echo "delay 1500"; echo "quit"; } \
	> "$out/cmds_console.txt"
rm -f "$out/console.log"
timeout 120 bin/buildat -m __menu -D ../user -w 1024x640 -l 3 \
	-L "$out/console.log" -c @"$out/cmds_console.txt" > /dev/null 2>&1
copened=$(grep -ac "console: .* lines of the API document" "$out/console.log")
cclosed=$(grep -ac "console: closed" "$out/console.log")
echo "the grid's console opened $copened times, closed $cclosed"
if [ "$copened" -lt 1 ] || [ "$cclosed" -lt 1 ]; then
	echo "FAIL: the grid cannot open the developer console"
	grep -a "Menu entry\|console:" "$out/console.log" | tail -3
	exit 1
fi

if [ "$bad" -gt 0 ]; then
	echo "FAIL: a launch UI does not start"
	exit 1
fi
# **And a server that dies is shown, not swallowed** ([START_PROGRESS]).
# When the local server goes, the client asks the launcher to say so --
# the last lines of its log and where the whole of it is, so a crash's
# backtrace is on the screen rather than gone. That path reads the
# launcher through the same lookup that had nothing in it for a
# sandboxed launch UI, so it is worth driving beside the one above.
{ echo "delay 40000"; echo "event scan 8 d"; echo "delay 3000"
	echo "quit"; } > "$out/cmds_dead.txt"
# **Last run's log is not this run's** (2026-09-24: the pid read out of
# it was the run before's, so the kill took nothing and the assertion
# failed on a server that was never touched)
rm -f "$out/dead.log" "$out/dead_server.log"
bin/buildat -o launch_ui=__menu -a game/vanilla/contentdb -D ../user \
	-w 1280x720 -l 3 -L "$out/dead.log" -c @"$out/cmds_dead.txt" \
	> /dev/null 2>&1 &
client=$!
# The server the client started, by the pid it logged: pkill would take
# any server on this desk with it
srv=""
for i in $(seq 1 40); do
	srv=$(grep -a "Started pid [0-9]*: .*buildat_server" "$out/dead.log" 2>/dev/null |
		tail -1 | sed -n 's/.*Started pid \([0-9]*\):.*/\1/p')
	[ -n "$srv" ] && break
	sleep 1
done
if [ -n "$srv" ]; then
	# Twenty seconds after it started is after the screen it serves is
	# drawn and well before this sequence's own scan: what is being
	# driven is a server that goes away under a client that is using
	# it, not one that fails to start
	sleep 20
	kill -9 "$srv" 2>/dev/null
fi
wait "$client" 2>/dev/null
said=$(grep -ac 'scan d: .*text "The server exited' "$out/dead.log")
cannot=$(grep -ac "the launcher cannot show a dead server" "$out/dead.log")
echo "a server that died (pid ${srv:-none}): the launcher said so" \
		"$said times"
if [ -z "$srv" ] || [ "$said" -lt 1 ] || [ "$cannot" -gt 0 ]; then
	echo "FAIL: a local server that dies is not shown by the launcher"
	grep -a "cannot show a dead server\|Disconnected" "$out/dead.log" |
		head -3
	exit 1
fi

# vim: set noet ts=4 sw=4:
echo "PASS: every launch UI this tree ships starts, a game can be left," \
		"and a dead server is shown"
exit 0
