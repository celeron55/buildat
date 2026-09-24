#!/bin/bash
# tier: quick
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
	bin/buildat -m "$n" -D ../user -w 640x360 -l 3 \
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
bin/buildat -o launch_ui=__menu -a game/vanilla/contentdb -D ../user 	-w 1280x720 -l 3 -L "$out/back.log" -c @"$out/cmds_back.txt" 	> /dev/null 2>&1
grid=$(grep -ac "back to the grid" "$out/back.log")
lost=$(grep -ac "leave: no launcher to go back to" "$out/back.log")
alive=$(grep -ac "scan b: ui" "$out/back.log")
echo "leaving a game: back to the grid $grid times, $alive elements" 		"drawn after it"
if [ "$grid" -lt 1 ] || [ "$lost" -gt 0 ] || [ "$alive" -lt 10 ]; then
	echo "FAIL: a game started from the grid cannot be left -- the client" 			"is left with no server and no menu"
	grep -a "leave:\|Failed to run function" "$out/back.log" | head -3
	exit 1
fi
if [ "$bad" -gt 0 ]; then
	echo "FAIL: a launch UI does not start"
	exit 1
fi
# vim: set noet ts=4 sw=4:
echo "PASS: every launch UI this tree ships starts, and a game can be left"
exit 0
